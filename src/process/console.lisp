;;;; The command loop.
;;;; Implements Phase 1 Software Architecture (Revision 2) SS3.1 - SS3.3.
;;;;
;;;; SS3.2: "The console reads a line, splits it into a command and quoted
;;;; arguments, and dispatches through a command table. It is deliberately not
;;;; the Lisp reader: the syntax is documentable, forgiving of Windows paths,
;;;; and usable by someone who does not write Lisp."
;;;;
;;;; That last clause is the whole design. `watch "C:\src\loom"` has to work
;;;; without anyone thinking about backslash escapes, and `impact resolve-calls`
;;;; has to work without parentheses. Every command is one line of prose with
;;;; optionally-quoted arguments, and the table is the documentation.

(in-package :loom-process)

;;;; ==================================================================
;;;; Logging and supervision (SS3.3)
;;;; ==================================================================

(defvar *log* '()
  "Recent events, most recent first: (timestamp label text).
SS3.2's log command reads this. Bounded, because it is a convenience for a
developer at a console and not a durable record of anything -- under
files-as-truth nothing recovers from it.")

(defparameter *log-limit* 200)

(defun log-event (label format &rest arguments)
  (push (list (get-universal-time) label (apply #'format nil format arguments)) *log*)
  (when (> (length *log*) *log-limit*)
    (setf *log* (subseq *log* 0 *log-limit*)))
  (values))

(defun install-debugger-hook ()
  "Make sure no non-interactive thread can block on a debugger prompt.

SS3.3: \"The image sets *debugger-hook* to that same logging path, so no
non-interactive thread can block on a debugger prompt even if a condition
escapes a handler.\" A process waiting on a debugger nobody can see is
indistinguishable, from the outside, from a process doing nothing."
  (setf *debugger-hook*
        (lambda (condition hook)
          (declare (ignore hook))
          (log-event "error" "~a: ~a" (type-of condition) condition)
          (format *error-output* "~&[loom] unhandled ~a: ~a~%" (type-of condition) condition)
          (finish-output *error-output*)
          (abort))))

;;;; ==================================================================
;;;; Parsing a command line
;;;; ==================================================================

(defun split-command-line (line)
  "LINE as a list of tokens, honouring double quotes.

Quotes group, and nothing else does: no escape characters, because the reason
they would be needed is Windows paths and the reason quotes exist is to make
those work without escaping. A backslash is just a character here."
  (let ((tokens '())
        (current (make-string-output-stream))
        (in-quotes nil)
        (any nil))
    (flet ((finish ()
             (let ((token (get-output-stream-string current)))
               (when (or any (plusp (length token)))
                 (push token tokens))
               (setf any nil))))
      (loop for char across line
            do (cond ((char= char #\") (setf in-quotes (not in-quotes) any t))
                     ((and (not in-quotes) (member char '(#\Space #\Tab))) (finish))
                     (t (write-char char current)))
            finally (finish)))
    ;; No (REMOVE "" ...) here. FINISH already declines to push an empty token
    ;; unless ANY says quotes were seen, so the only empty string that can
    ;; reach this point is a deliberate one -- `find ""' -- and removing it
    ;; would undo the single thing the ANY flag exists to do.
    (nreverse tokens)))

;;;; ==================================================================
;;;; The command table
;;;; ==================================================================

(defstruct (command (:conc-name command-))
  (name "")
  (usage "")
  (summary "")
  (handler nil :type (or null function)))

(defvar *commands* '()
  "Commands in declaration order, which is the order HELP prints them.")

(defmacro define-command (name (&rest lambda-list) usage summary &body body)
  "Declare a console command.

Declarative for the same reason DEFENTITY is: the table is what HELP prints,
so a command whose usage line is wrong is a visible bug rather than a stale
comment."
  (let ((string-name (string-downcase (string name))))
    `(progn
       (setf *commands*
             (append (remove ,string-name *commands* :key #'command-name :test #'string=)
                     (list (make-command
                            :name ,string-name
                            :usage ,usage
                            :summary ,summary
                            :handler (lambda (,@lambda-list) ,@body)))))
       ,string-name)))

(defun find-command (name)
  (find name *commands* :key #'command-name :test #'string-equal))

;;;; ==================================================================
;;;; Choosing what to operate on
;;;; ==================================================================

(defun current-repository (&optional designator)
  "The repository a command should act on.

With one repository watched, naming it every time is friction for no benefit,
so it is implied. With several, an ambiguous command is refused rather than
guessed at."
  (cond (designator (or (find-repository designator)
                        (error "No repository named ~a. Try: status" designator)))
        ((null (all-repositories))
         (error "Nothing is being watched yet. Try: watch \"/path/to/repo\""))
        ((rest (all-repositories))
         (error "Several repositories are watched; name one. Try: status"))
        (t (first (all-repositories)))))

(defun current-graph (&optional designator)
  (repository-graph (current-repository designator)))

(defun resolve-entity (graph term)
  "The entity TERM names: an id if it is one, otherwise the best name match.

Agents and humans both name things rather than quoting ids, and a command that
demanded an id would send the developer to `find` first every single time."
  (or (get-entity graph term)
      (let ((hits (search-entities graph :name term :limit 1)))
        (when hits (get-entity graph (getf (first hits) :id))))
      (error "Nothing in the index matches ~s." term)))

(defun resolve-count (text what)
  "TEXT as a non-negative integer, or an error naming WHAT and what was typed.

`parse-integer :junk-allowed t' returns NIL for an unparseable argument rather
than signalling, so the NIL travelled on into arithmetic and surfaced as \"The
value NIL is not of type REAL\" -- a message that names neither the command nor
the argument that was wrong. SS3.3 asks for the opposite: a mistyped command
tells the developer what to type instead. Run-command prints the condition, so
the text here is what they read.

Junk after the digits is refused rather than silently truncated. `impact foo
3x' meaning depth 3 is a guess about intent, and a wrong guess about a bound is
invisible in the output -- the report is simply smaller than the caller asked
for. REV-0001 finding 4 is about exactly that class of quiet dishonesty in this
command."
  (multiple-value-bind (n end) (parse-integer text :junk-allowed t)
    (unless (and n (= end (length text)) (not (minusp n)))
      (error "~a must be a non-negative integer, not ~s." what text))
    n))

;;;; ==================================================================
;;;; Output helpers
;;;; ==================================================================

(defun print-summary-line (summary &optional (indent 0))
  ;; The indent is a string rather than a ~v@{ ~} directive: that form takes
  ;; INDENT as the iteration limit and then reads the *following* argument as
  ;; the list to iterate, so every remaining argument shifted one place left
  ;; and `find' printed the placeholder as the type, the type as the name, and
  ;; the location as the staleness flag -- "dummy function [foo] (stale)" for
  ;; an entity that is a function named foo, freshly indexed and not stale.
  (format t "~&~a~(~a~) ~a~@[  [~a]~]~@[  (stale)~]~%"
          (make-string indent :initial-element #\Space)
          (getf summary :type) (getf summary :name)
          (getf summary :location) (getf summary :stale)))

(defun print-status (status)
  (format t "~&~a  ~a~%" (getf status :name) (getf status :root))
  (format t "  index      : ~d files, ~d entities, ~d relationships~%"
          (getf status :files) (getf status :entities) (getf status :relationships))
  (format t "  documents  : ~d~@[, ~d uncategorized~]~%"
          (getf status :documents)
          (let ((n (getf status :uncategorized-documents))) (and (plusp n) n)))
  ;; Printed unconditionally, zero included. A count that vanishes when it is
  ;; nought cannot be told from a count nobody computes, and these three exist
  ;; precisely to be read as zero-or-not (ARCH-0002 R10).
  (format t "  tests      : ~d test~:p covering ~d unit~:p~%"
          (getf status :test-entities) (getf status :tested-units))
  (format t "  watcher    : ~(~a~)~%" (getf status :monitor))
  (format t "  rules      : ~d violation~:p, ~d unenforced~%"
          (getf status :violations) (getf status :unenforced-rules))
  (format t "  unresolved : ~d document reference~:p, ~d definer macro~:p~%"
          (getf status :unresolved-references)
          (getf status :unhandled-definer-macros))
  ;; ARCH-0011. "never run" is spelled out rather than left as three zeroes,
  ;; because enrichment is optional and on demand: a reader who sees zeroes
  ;; cannot tell a tree the image agreed with completely from one nobody has
  ;; asked about, and only one of those is worth doing something about.
  (if (plusp (getf status :enrichment-runs))
      (format t "  enrichment : ~d unit~:p loaded, ~d gap~:p, ~d run~:p~%"
              (getf status :enriched-units) (getf status :enrichment-gaps)
              (getf status :enrichment-runs))
      (format t "  enrichment : never run~%"))
  (when (plusp (getf status :errors))
    (format t "  errors     : ~d, last: ~a~%"
            (getf status :errors) (cdr (getf status :last-error)))))

;;;; ==================================================================
;;;; Commands (SS3.2)
;;;; ==================================================================

(define-command help (&optional name)
    "help [command]"
    "This table, or one command in detail."
  (let ((one (and name (find-command name))))
    (cond (one (format t "~&~a~%    ~a~%" (command-usage one) (command-summary one)))
          (t (format t "~&Loom console. Commands:~%")
             (dolist (c *commands*)
               (format t "  ~24a ~a~%" (command-usage c) (command-summary c)))))))

(define-command watch (path)
    "watch \"<directory>\""
    "Register a repository, index it, and begin watching. Resumes a paused one."
  (let ((repository (watch-repository path)))
    (log-event "watch" "~a" (repository-root repository))
    (print-status (repository-status repository))))

(define-command pause (&optional designator)
    "pause [<name>]"
    "Stop watching but keep the index. Resume with watch."
  ;; DEC-0004: a console session and an index have different lifetimes, so
  ;; there has to be a way to stop the polling that does not spend the seconds
  ;; the graph cost to build.
  (let ((repository (pause-repository
                     (repository-name (current-repository designator)))))
    (log-event "pause" "~a" (repository-root repository))
    (print-status (repository-status repository))))

(define-command unwatch (&optional designator)
    "unwatch [<name>]"
    "Stop watching and drop the index."
  (let ((repository (unwatch-repository (repository-name (current-repository designator)))))
    (format t "~&Dropped ~a.~%" (repository-name repository))))

(define-command status (&optional designator)
    "status [<name>]"
    "Index size, watcher health, unresolved references, rule violations."
  (if designator
      (print-status (repository-status (current-repository designator)))
      (let ((all (all-repositories)))
        (if (null all)
            (format t "~&Nothing is being watched. Try: watch \"/path/to/repo\"~%")
            (dolist (repository all) (print-status (repository-status repository)))))))

(define-command reindex (&optional designator)
    "reindex [<name>]"
    "Discard and rebuild the index from disk. Always safe."
  (let ((repository (current-repository designator)))
    (reindex-repository repository)
    (print-status (repository-status repository))))

(define-command enrich (&optional designator)
    "enrich [<name>]"
    "Ask each language's toolchain to enrich the index. On demand only."
  ;; On demand and nowhere else (ARCH-0011 R9). Nothing in POLL-ONCE, the
  ;; monitor, watch or reindex reaches ENRICH-REPOSITORY: a run loads the whole
  ;; target in a fresh process, which is seconds to minutes against a poll cycle
  ;; designed to cost milliseconds. ARCH-0008 is the precedent and BUG-0008 is
  ;; the trap.
  (let* ((repository (current-repository designator))
         (report (enrich-repository repository)))
    (log-event "enrich" "~a" (repository-root repository))
    (print-enrichment report)
    (print-status (repository-status repository))))

(defun print-enrichment (report)
  "What one enrichment run did, zeros included.

The per-unit lines are the primary output and the counts are secondary, which
is the inverse of what it looks like. A pass whose child died on its first unit
adds nothing, drops nothing and signals nothing -- indistinguishable from a
tree the image agrees with completely -- so what has to be printed
unconditionally is which units were attempted and what became of them
(REQ-0018 R4, and ARCH-0002 R10's precedent for printing a nought)."
  (format t "~&enriched in ~,1fs~%" (getf report :duration))
  (dolist (unit (getf report :units))
    (format t "  ~(~a~) ~a~@[: ~a~]~%"
            (getf unit :status) (getf unit :unit) (getf unit :error)))
  (dolist (absence (getf report :absences))
    (format t "  absent ~(~a~): ~a~%"
            (getf absence :language) (getf absence :reason)))
  (format t "  entities   : ~d added, ~d confirmed~%"
          (getf report :added) (getf report :confirmed))
  (format t "  edges      : ~d added, ~d confirmed~%"
          (getf report :edges-added) (getf report :edges-confirmed))
  (format t "  dropped    : ~d without a location, ~d outside the root, ~
~d of an unknown kind, ~d edge~:p with an unresolved endpoint~%"
          (getf report :dropped-no-location)
          (getf report :dropped-not-under-root)
          (getf report :dropped-unknown-kind)
          (getf report :edges-dropped)))

(define-command find (term &optional type)
    "find <name> [<type>]"
    "Where something is defined. The entry point for \"where is X\"."
  (let ((hits (search-entities (current-graph) :name term
                               :type (and type (intern (string-upcase type) :keyword))
                               :limit 20)))
    (if (null hits)
        (format t "~&Nothing matches ~s.~%" term)
        (dolist (hit hits) (print-summary-line hit)))))

(define-command describe (term)
    "describe <name>"
    "Full detail for one entity, with its neighbours grouped by edge type."
  (let* ((graph (current-graph))
         (entity (resolve-entity graph term))
         (detail (describe-entity graph (id entity))))
    (print-summary-line (getf detail :entity))
    ;; A document's :BODY is its author's whole concatenation, so printing it
    ;; put the neighbours below an unbounded amount of prose, and for a
    ;; decision printed the rationale twice -- once under its own key and once
    ;; buried inside :BODY. One named, labelled, budgeted field instead. The
    ;; full text is still one Read of the path already named on the line above.
    (let ((doc (getf detail :document)))
      ;; NIL for a code entity, so this branch does not exist for a function,
      ;; class or file rather than happening to print nothing there.
      (when doc
        (format t "~&~@[title: ~a~%~]~@[status: ~(~a~)~%~]"
                (getf doc :title) (getf doc :status))
        (if (getf doc :text)
            ;; ", truncated" is a two-clause ~:[~;~] and not a ~@[~]: an ~@[
            ;; whose clause contains no directive does not use up the argument
            ;; it tested, so the flag survived into the following ~a and the
            ;; summary of every truncated document printed as "T".
            (format t "~&summary~@[ (via ~(~a~))~] (~d~@[/~d~] tokens~:[~;, truncated~]):~%  ~a~%"
                    ;; Labelled only when it is a fallback: naming the field on
                    ;; an author's real summary would be noise, and not naming
                    ;; it on a fallback would be a fabrication.
                    (and (not (eq (getf doc :field) :summary)) (getf doc :field))
                    (estimate-tokens (getf doc :text))
                    ;; The full size prints only when something was cut;
                    ;; "(24/24 tokens)" reads as though something happened.
                    (and (getf doc :truncated) (getf doc :full-tokens))
                    (getf doc :truncated)
                    (getf doc :text))
            (format t "~&summary: (none written)~%"))))
    (dolist (group (getf detail :neighbors))
      (format t "~&  ~a ~(~a~): ~{~a~^, ~}~%"
              (if (eq :out (getf group :direction)) "->" "<-")
              (getf group :rel-type)
              (mapcar (lambda (e) (getf e :name)) (getf group :entities))))))

(define-command impact (term &optional depth)
    "impact <name> [<depth>]"
    ;; Built from the variable rather than written out, because the number in a
    ;; docstring is the first thing to go stale: REQ-0005 R5 records that every
    ;; example in CLAUDE.md and the agent definitions passes 3, and that the
    ;; default was believed to be 3 for exactly as long as nothing printed it.
    (format nil "What may need attention if this changes, with paths and ~
                 depths. Depth defaults to ~d."
            *default-impact-depth*)
  (let* ((graph (current-graph))
         (entity (resolve-entity graph term))
         (report (impact-report graph (id entity)
                                :max-depth (if depth
                                               (resolve-count depth "depth")
                                               *default-impact-depth*))))
    (format t "~&~a~@[  [~a]~]~%"
            (getf (getf report :seed) :name) (getf (getf report :seed) :location))
    (format t "~&~d impacted~@[ (truncated)~]:~%"
            (getf report :count) (getf report :truncated))
    (dolist (e (getf report :impacted))
      (format t "  d~a ~(~a~) ~a~30t~a~%"
              (getf e :depth) (getf e :type) (getf e :name) (getf e :via)))
    (dolist (field '(:tests :documents :decisions))
      (let ((entries (getf report field)))
        (when entries
          (format t "~&~(~a~): ~{~a~^, ~}~%"
                  field (mapcar (lambda (e) (getf e :name)) entries)))))
    (let ((maybe (getf report :possibly-affected)))
      (when maybe
        (format t "~&possibly affected (reached only through a stale edge): ~{~a~^, ~}~%"
                (mapcar (lambda (e) (getf e :name)) maybe))))))

(define-command context (&rest words)
    "context <task description>"
    "A budgeted context bundle for a task: what to know before editing."
  (let ((task (format nil "~{~a~^ ~}" words)))
    (write-string (render-context (build-context (current-graph) task)))))

(define-command check (&optional designator)
    "check [<name>]"
    "Run the rule checks from docs/rules and print violations."
  (let* ((graph (current-graph designator))
         (violations (entities-of-type graph :rule-violation))
         (unenforced (unenforced-rules graph)))
    (if (null violations)
        (format t "~&No violations.~%")
        (dolist (v violations)
          (format t "~&~(~a~) ~a: ~a~%"
                  (getp v :severity) (getp v :rule-id) (getp v :detail))))
    (when unenforced
      (format t "~&~d active rule~:p not enforceable as a check: ~{~a~^, ~}~%"
              (length unenforced) (mapcar (lambda (r) (getp r :doc-id)) unenforced)))
    (let ((unresolved (unresolved-references graph)))
      (when unresolved
        (format t "~&~d unresolved document reference~:p:~%" (length unresolved))
        (dolist (pair unresolved)
          (format t "  ~a -> ~a~%" (car pair) (cdr pair)))))
    ;; ARCH-0002 R6/R10, reported the way an unresolved reference is and for
    ;; the same reason: a definer Loom cannot characterise is a definition the
    ;; index knows it is missing, and it should be visible here rather than
    ;; only after a suite run.
    (let ((unhandled (unhandled-definer-macros graph))
          (collisions (generated-definition-collisions graph *macro-generators*)))
      (when unhandled
        (format t "~&~d definer macro~:p whose expansion could not be read:~%"
                (length unhandled))
        (dolist (macro unhandled)
          (format t "  ~a  [~a:~a]~%" (name macro) (getp macro :file)
                  (getp macro :start-line))))
      (when collisions
        (format t "~&~d definer call site~:p left alone:~%" (length collisions))
        (dolist (pair collisions)
          (format t "  ~a -> ~a~%" (car pair) (cdr pair)))))))

(define-command rules (&optional designator)
    "rules [<name>]"
    "Active rules and what they constrain."
  (dolist (rule (active-rules (current-graph designator)))
    (format t "~&~a ~a~@[  (~(~a~))~]~@[  [prose only]~]~%"
            (getp rule :doc-id) (getp rule :title) (getp rule :severity)
            (not (enforceable-rule-p rule)))))

(define-command log (&optional count)
    "log [n]"
    "Recent events and errors."
  ;; The same parse as `impact', and it failed the other way: the NIL from an
  ;; unparseable count was swallowed by the OR, so `log abc' quietly printed the
  ;; default twenty as though that had been asked for.
  (let ((n (if count (resolve-count count "count") 20)))
    (dolist (entry (subseq *log* 0 (min n (length *log*))))
      (destructuring-bind (at label text) entry
        (multiple-value-bind (second minute hour) (decode-universal-time at)
          (format t "~&~2,'0d:~2,'0d:~2,'0d ~a ~a~%" hour minute second label text))))))

(define-command repl ()
    "repl"
    "Drop into the Lisp REPL in this image. (loom-process:console) returns."
  (format t "~&Lisp REPL. (loom-process:console) or EOF returns to the console.~%")
  ;; SS3.2: "Sessions started with repl bind *debugger-hook* to nil for their
  ;; own dynamic extent, so the developer keeps the real debugger where it is
  ;; useful."
  (let ((*debugger-hook* nil))
    #+sbcl (sb-impl::toplevel-repl nil)
    #-sbcl (loop (format t "~&* ") (finish-output)
                 (let ((form (read *standard-input* nil :eof)))
                   (when (eq form :eof) (return))
                   (format t "~&~s~%" (eval form))))))

(define-command stop ()
    "stop"
    "Pause every repository and leave the console. Indexes are kept."
  ;; The behaviour has not changed; the description has. DEC-0004: what this
  ;; always did was pause, and calling it "stop watchers" is what made the
  ;; state it left behind read as a fault.
  (dolist (repository (all-repositories)) (stop-monitor repository))
  (throw 'quit-console t))

;;;; ==================================================================
;;;; The loop
;;;; ==================================================================

(defun run-command (line)
  "Parse and run one console line. Returns T unless it asked to quit.

Every condition is caught and reported. SS3.3's argument applies to the console
as much as to the watcher: a mistyped command should print a message, not drop
the developer somewhere they have to know Lisp to escape."
  (let ((tokens (split-command-line line)))
    (when tokens
      (let ((command (find-command (first tokens))))
        (cond ((null command)
               (format t "~&Unknown command ~s. Try: help~%" (first tokens)))
              (t (handler-case (apply (command-handler command) (rest tokens))
                   (error (condition)
                     (log-event "error" "~a: ~a" (first tokens) condition)
                     (format t "~&~a~%" condition))))))))
  t)

(defun console ()
  "Read, dispatch, print. Returns when told to stop or on EOF."
  (catch 'quit-console
    (loop
      (format t "~&loom> ")
      (finish-output)
      (let ((line (read-line *standard-input* nil :eof)))
        (when (eq line :eof) (return))
        (run-command line))))
  (values))

(defun main (&rest arguments)
  "Process entry point. Any arguments are treated as repositories to watch.

SS3.1: the process is \"started by the developer and pointed at a
repository\", so `loom /path/to/repo` indexes it and hands over a prompt."
  (install-debugger-hook)
  (format t "~&Loom -- engineering knowledge graph. Type help.~%")
  (dolist (path arguments)
    (handler-case (run-command (format nil "watch ~s" path))
      (error (condition) (format t "~&~a~%" condition))))
  (console)
  (dolist (repository (all-repositories)) (stop-monitor repository))
  (format t "~&Paused ~d repositor~:@p; indexes kept.~%" (length (all-repositories)))
  (values))
