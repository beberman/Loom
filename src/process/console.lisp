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

(defparameter *repository-sigil* #\@
  "The character that makes a leading token a repository name. DES-0021 D1.

Chosen because nothing else the console reads can begin with it: a designator
is a name or a path, an entity name is a Lisp symbol name, a depth is digits,
and a verdict is DOC=status. Tested at the first character only, so an entity
genuinely named `@foo' is still reachable through the console's quoting rule.")

(defvar *command-repository* nil
  "The repository named by a leading @token, for one command's dynamic extent.

A variable rather than an argument on each command, because two of the commands
that need one are variadic -- `context' takes the task's words and `complete'
takes verdicts -- so there is no trailing position to put a designator in.
RUN-COMMAND strips the token and binds this, which is what lets every command
take a repository without any command's lambda list changing (DES-0021 D2).

Bound per command and never set, which is REQ-0023 R1a and the reason a `use
<repository>' mode was rejected: a session that remembers a selection answers a
later query about the wrong tree with nothing in the question or the answer
saying so. That is CON-0001's fabricated fact arrived at by omission, and
REQ-0021 R8 already calls it worse than a failure.")

(defun repository-token-p (token)
  "True when TOKEN is a leading @name naming a repository."
  (and (stringp token)
       (> (length token) 1)
       (char= *repository-sigil* (char token 0))))

(defun watched-repository-names ()
  (mapcar #'repository-name (all-repositories)))

(defun current-repository (&optional designator)
  "The repository a command should act on.

DES-0021 D2's precedence, most specific first: an explicit designator argument,
then the @token RUN-COMMAND stripped from this command line, then the sole
watched repository, and otherwise a refusal naming what is watched.

The explicit argument wins over the token because a caller who typed one in
that position meant it, and overriding it from a token earlier on the line
would be the surprise this exists to remove. With one repository watched
nothing changes and nothing has to be typed."
  (let ((named (or designator *command-repository*)))
    (cond (named (or (find-repository named)
                     ;; A designator that still carries the sigil got here as a
                     ;; positional argument rather than being stripped, which
                     ;; means it was not first on the line. Found by writing
                     ;; `remove tooling @gs2\' and being told no repository was
                     ;; named @gs2 -- true, unhelpful, and one word short of the
                     ;; thing the caller needed to know.
                     (if (repository-token-p named)
                         (error "The ~c token names a repository and has to come ~
first: try `~c~a ...\' rather than putting it after another argument."
                                *repository-sigil* *repository-sigil* (subseq named 1))
                         (error "No repository named ~a. Watching: ~{~a~^, ~}"
                                named (or (watched-repository-names) '("nothing"))))))
          ((null (all-repositories))
           (error "Nothing is being watched yet. Try: watch \"/path/to/repo\""))
          ((rest (all-repositories))
           ;; Naming the mechanism and the answers, not just the problem. The
           ;; old message said "name one" and gave no way to; a developer who
           ;; has to run `status' first to find out how to ask is a developer
           ;; who ran two commands to ask one question.
           (error "Several repositories are watched. Name one with ~c<name>:~{ ~c~a~}"
                  *repository-sigil*
                  (loop for name in (watched-repository-names)
                        append (list *repository-sigil* name))))
          (t (first (all-repositories))))))

(defun current-graph (&optional designator)
  (repository-graph (current-repository designator)))

(defun exact-name-matches (graph term)
  "Every entity whose name is exactly TERM, ignoring case."
  (remove-if-not (lambda (hit) (string-equal term (getf hit :name)))
                 (search-entities graph :name term :limit 20)))

(defun resolve-entity (graph term)
  "The entity TERM names: an id if it is one, otherwise the best name match.

Agents and humans both name things rather than quoting ids, and a command that
demanded an id would send the developer to `find` first every single time.

Several entities may carry one name, and since DES-0015 that is the normal
case rather than a defect: two same-named definitions in different packages are
two callables. Picking the best of them would answer a question nobody asked --
`describe id' on game-server described the one in :DATA-API-TEST, which has no
callers, while the four that share MPACKAGE/OBJECT's symbol have 64 each. The
answer was not wrong so much as arbitrary, and an arbitrary answer that looks
definite is CON-0001's fabricated fact wearing a different hat. So an exactly
ambiguous name is reported with its candidates and their ids, which is what a
developer needs in order to ask again precisely."
  (or (get-entity graph term)
      (let ((exact (exact-name-matches graph term)))
        (cond ((null (rest exact))
               ;; BEST-NAME-MATCH rather than SEARCH-ENTITIES with a limit of
               ;; one (BUG-0032): where a file and a definition match a name
               ;; equally well, the caller of this function wants the
               ;; definition. `find' is unaffected -- it calls SEARCH-ENTITIES
               ;; directly and still lists the file first.
               ;;
               ;; EXACT is consulted first when it holds exactly one entity,
               ;; which it did not before. The old code computed EXACT, took
               ;; this branch for both nought and one, and then threw it away
               ;; to re-search -- so a single exact match could lose to a
               ;; higher-ranked inexact one. An exact match is the strongest
               ;; evidence this function has and now decides.
               (or (and exact (get-entity graph (getf (first exact) :id)))
                   (let ((hit (best-name-match graph term)))
                     (when hit (get-entity graph (getf hit :id))))))
              ;; The id carries the file, so it is both the disambiguator and
              ;; the thing to type next.
              (t (error "~d things are named ~s. Name one:~{~%  ~a~}"
                        (length exact) term
                        (mapcar (lambda (hit)
                                  (format nil "~(~a~) ~a"
                                          (getf hit :type) (getf hit :id)))
                                exact)))))
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
  ;; precisely to be read as zero-or-not (DES-0002 R10).
  (format t "  tests      : ~d test~:p covering ~d unit~:p~%"
          (getf status :test-entities) (getf status :tested-units))
  (format t "  watcher    : ~(~a~)~%" (getf status :monitor))
  (format t "  rules      : ~d violation~:p, ~d unenforced~%"
          (getf status :violations) (getf status :unenforced-rules))
  (format t "  unresolved : ~d document reference~:p, ~d ambiguous, ~d definer macro~:p~%"
          (getf status :unresolved-references)
          (getf status :ambiguous-references)
          (getf status :unhandled-definer-macros))
  ;; DES-0018 D5. Printed only when git could not be asked, because on a
  ;; healthy tree there is nothing to say and a line reading "ignoring: fine"
  ;; would be noise on every status call. When it does print, it is the
  ;; explanation for a document count that includes somebody else's README.
  (let ((reason (getf status :ignore-reason)))
    (when reason
      (format t "  ignores    : not consulted -- ~a~%" reason)))
  ;; DES-0013 R11, beside `unresolved' because it answers the same question a
  ;; reader is asking there: what does this index know it is missing. Printed
  ;; unconditionally for the reason the tests line above gives -- these are
  ;; meant to be read as zero-or-not, and both read zero on a healthy tree.
  ;; "unread" rather than "skipped": a comment is skipped too, and a reader who
  ;; sees a number here should understand it as source that would have defined
  ;; something and did not.
  ;; BUG-0033, above `unread' because it is the coarser measure of the same
  ;; thing: `unread' counts source that would have defined something and did
  ;; not, and this counts whole files whose every definition is missing. The
  ;; document that prompted it sat in the index for a day and a half with its
  ;; title, its id and its body all absent while `documents' counted it and
  ;; `check' reported a clean tree. `check' names the paths and the parser's
  ;; own message; this is the number.
  (format t "  unparsed   : ~d file~:p the analyzer could not read~%"
          (getf status :unparsed))
  (format t "  unread     : ~d suppressed region~:p, ~d recovered region~:p~%"
          (getf status :suppressed-regions)
          (getf status :recovered-regions))
  ;; BUG-0030 F1, and the same reading as the line above it: an edge whose two
  ;; endpoint types the ontology does not permit is a relationship the index
  ;; knows it is missing. Unconditional, zero included -- a count that vanishes
  ;; at nought cannot be told from a count nobody computes, and until this
  ;; existed such an edge rejected the whole pass instead of being counted.
  ;; `check' names the rel-type and the two types; this is the number.
  (format t "  dropped    : ~d edge~:p the ontology does not permit~%"
          (getf status :dropped-edges))
  ;; DES-0011. "never run" is spelled out rather than left as three zeroes,
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
            (getf status :errors)
            (getf (getf status :last-error) :message))))

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
  ;; On demand and nowhere else (DES-0011 R9). Nothing in POLL-ONCE, the
  ;; monitor, watch or reindex reaches ENRICH-REPOSITORY: a run loads the whole
  ;; target in a fresh process, which is seconds to minutes against a poll cycle
  ;; designed to cost milliseconds. DES-0008 is the precedent and BUG-0008 is
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
(REQ-0018 R4, and DES-0002 R10's precedent for printing a nought)."
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

;;;; ------------------------------------------------------------------
;;;; Document state transitions (REQ-0022, DES-0019)
;;;;
;;;; The two commands that write. Everything else in this table reads an index
;;;; built from files; these edit the files themselves, so the rendering has one
;;;; job the others do not: make it obvious what was written and what was not.
;;;; A report whose :PROBLEMS is non-empty means nothing at all was written, and
;;;; that sentence is printed rather than left to be inferred from the absence
;;;; of a change line.
;;;; ------------------------------------------------------------------

(defun print-transition-problems (report)
  "The refusals, all of them. True when there were any.

Every problem at once rather than the first, because the underlying command
collects them that way for a reason: an agent that has to run a command five
times to discover five problems will stop reading the fifth."
  (let ((problems (getf report :problems)))
    (when problems
      (format t "~&Nothing was written. ~d problem~:p:~%" (length problems))
      (dolist (problem problems) (format t "  - ~a~%" problem))
      t)))

(defun transition-action-note (row)
  "The right-hand column for one document in a transition report."
  (case (getf row :action)
    (:no-status        "no status field -- the walk stops here")
    (:already-finished "already finished")
    (:blocked          (format nil "blocked by ~{~a~^, ~}" (getf row :blocked-by)))
    (:awaiting-verdict "needs a verdict")
    (:unchanged        "already there")
    (t                 nil)))

(defun transition-target (row)
  "The status column on the right of the arrow.
`?' where the caller still owes a verdict, so the gap is visible in the column
rather than only in the note beside it."
  (or (getf row :verdict)
      (case (getf row :action)
        ((:no-status :already-finished) "-")
        (t "?"))))

(defun print-transition-documents (report)
  (dolist (row (getf report :documents))
    (format t "  ~14a ~14a ~(~11a~) -> ~(~13a~)~@[~a~]~%"
            (getf row :doc-id)
            (or (getf row :category) "")
            (or (getf row :status) "-")
            (transition-target row)
            (transition-action-note row))))

(defun print-transition-changes (report)
  (let ((changed (getf report :changed)))
    (dolist (change changed)
      (format t "  ~14a ~(~a~) -> ~(~a~)~@[  moved to ~a~]~%"
              (getf change :doc-id) (or (getf change :from) "-") (getf change :to)
              (and (getf change :moved) (getf change :file))))
    (format t "~&~d document~:p changed, ~d file~:p moved.~%"
            (length changed)
            (count-if (lambda (c) (getf c :moved)) changed))))

(define-command set-status (document status &optional designator)
    "set-status <document> <status> [<name>]"
    "Set one document's status and file it where that status belongs."
  ;; The primitive. It runs no propagation query on purpose -- this is the way
  ;; to say "I know what I am doing" about one document, and files are truth: a
  ;; developer with an editor can always do the same thing, so a command that
  ;; refused would only be telling them to use the editor.
  (let* ((repository (current-repository designator))
         (report (set-document-status repository document status)))
    (unless (print-transition-problems report)
      (log-event "set-status" "~a ~a" document status)
      (if (getf report :changed)
          (print-transition-changes report)
          (format t "~&~a is already ~(~a~), filed at ~a. Nothing to do.~%"
                  (getf report :document) (getf report :status) (getf report :file))))))

(define-command complete (plan &rest verdicts)
    "complete <plan> [<doc>=<status> ...]"
    "Set a plan final and restate every document it implements."
  ;; With no verdicts this writes nothing and shows what it would do. Dry run by
  ;; default rather than behind a flag, which is the right default for a command
  ;; whose failure mode is editing files -- and it means an agent that runs
  ;; `complete PLAN-0019' and walks away has done nothing.
  (let* ((repository (current-repository))
         (report (complete-plan repository plan :verdicts verdicts)))
    (print-transition-documents report)
    (unless (print-transition-problems report)
      (cond ((getf report :dry-run)
             (format t "~&Dry run: nothing written.~%")
             (let ((awaiting (remove-if-not
                              (lambda (row) (eq :awaiting-verdict (getf row :action)))
                              (getf report :documents))))
               (when awaiting
                 ;; The line the caller types next, assembled rather than
                 ;; described. A verdict per document is a judgement Loom cannot
                 ;; make, but which documents need one is not.
                 (format t "~&To apply: complete ~a~{ ~a=<status>~}~%"
                         (getf report :plan)
                         (mapcar (lambda (row) (getf row :doc-id)) awaiting)))))
            (t (log-event "complete" "~a" (getf report :plan))
               (print-transition-changes report))))))

(defparameter *console-find-limit* 20
  "How many rows `find\' prints.

Twenty, unchanged since the command was written. What changed with BUG-0002 is
that the command says when it cut the list: a cap is a reasonable answer to
\"where is X\" and a false one to \"what is there\", and the count is what lets
the reader tell which question they asked.")

(define-command find (term &optional type)
    "find <name> [<type>]"
    "Where something is defined. The entry point for \"where is X\"."
  (multiple-value-bind (hits total)
      (search-entities (current-graph) :name term
                       :type (and type (intern (string-upcase type) :keyword))
                       :limit *console-find-limit*)
    (cond
      ((null hits) (format t "~&Nothing matches ~s.~%" term))
      (t (dolist (hit hits) (print-summary-line hit))
         ;; BUG-0002. Printed only when it happened, and printed as a count
         ;; rather than a word: twenty rows read as the whole truth, and the
         ;; number that says otherwise is the one the caller needs to decide
         ;; whether to narrow the term. `impact' has carried its own
         ;; "(truncated)" since it was written; this is the same fact in the
         ;; same interface.
         (when (> total (length hits))
           (format t "~&~d of ~d shown. Narrow the term, or name a type.~%"
                   (length hits) total))))))

(define-command describe (term &optional flag)
    "describe <name> [--source]"
    "Full detail for one entity, with its neighbours grouped by edge type. \
--source adds the definition's text."
  (let* ((repository (current-repository))
         (graph (repository-graph repository))
         (entity (resolve-entity graph term))
         (detail (describe-entity graph (id entity)))
         ;; REQ-0031 R2: requested rather than assumed. A flag rather than a
         ;; second positional, because `describe <name> <something>' reads as a
         ;; type filter by analogy with `find'. An unrecognised token is
         ;; refused rather than ignored -- a typo that silently returns the
         ;; answer to a different question is the failure this command is least
         ;; able to make visible.
         (source-wanted
           (cond ((null flag) nil)
                 ((string-equal flag "--source") t)
                 ;; Signalled rather than printed: RUN-COMMAND catches every
                 ;; condition and reports it, and DEFINE-COMMAND's body is an
                 ;; anonymous lambda with no block to return from.
                 (t (error "Unknown option ~s. Try: --source" flag)))))
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
    ;; DES-0025 D1. A route is the one property worth printing beside the
    ;; neighbours rather than leaving in the :PROPERTIES table: it is the join
    ;; key two repositories meet in, and a reader checking why a handler did
    ;; not federate needs to see what it actually claims. Absent on everything
    ;; that publishes no endpoint, which is nearly everything.
    (let ((routes (getf (getf detail :properties) :routes)))
      (when routes
        (format t "~&routes: ~{~a~^, ~}~%" routes)))
    ;; DES-0025. Below the routes and above the neighbours: a federated edge
    ;; is what the route is *for*, and it is not a neighbour -- `find' in this
    ;; repository will not answer about it, which the repository name makes
    ;; plain at a glance.
    (dolist (far (getf detail :federated))
      (format t "~&  -> ~(~a~) @~a: ~a ~a [~a~@[:~a~]]~@[ via ~a~]~@[ @~a~]~%"
              (getf far :rel-type) (getf far :repository)
              (getf far :type) (getf far :name)
              (getf far :file) (getf far :line)
              (getf far :via) (getf far :commit)))
    (dolist (group (getf detail :neighbors))
      (format t "~&  ~a ~(~a~): ~{~a~^, ~}~%"
              (if (eq :out (getf group :direction)) "->" "<-")
              (getf group :rel-type)
              ;; A call site's name already carries its file and line, so the
              ;; kind is the only part of DES-0014 R7's "line and kind rather
              ;; than a bare id" still missing here. NIL for every other type,
              ;; so the ~@[ is what keeps this from adding an empty pair of
              ;; parens to every ordinary neighbour -- and its clause contains
              ;; a directive, so it consumes the argument it tested rather than
              ;; leaking it into the next one, which is the trap the document
              ;; summary above this records.
              (mapcar (lambda (e)
                        (format nil "~a~@[ (~(~a~))~]"
                                (getf e :name) (getf e :referrer-kind)))
                      (getf group :entities))))
    ;; REQ-0031 R1, last because it is the longest thing printed and the
    ;; neighbours are the survey a reader uses to decide whether they wanted
    ;; this entity at all.
    (when source-wanted
      (print-source (definition-source repository (id entity))))))

(defun print-source (result)
  "REQ-0031's source block, or why there is none.

Every status prints something. REQ-0031 R5 forbids answering a range that is no
longer there with a shorter region or an empty string, and a caller that asked
for source and got silence cannot tell a refusal from an empty definition --
which is CON-0006's expensive error at the scale of one answer."
  (let ((status (getf result :status)))
    (case status
      ((:current :stale)
       ;; R4: the range served and the generation it was read against, so a
       ;; caller can tell that what it read matches what Loom described. The
       ;; range is what was *served* and may be shorter than the entity's when
       ;; the cap cut it.
       (format t "~&~%source ~a~@[ (~d line~:p withheld)~]~@[ -- ~a~]:~%"
               (getf result :range)
               (and (getf result :truncated) (getf result :withheld))
               (when (eq :stale status)
                 "the file has changed since it was indexed"))
       (write-string (getf result :text)))
      (:unlocated
       (format t "~&~%source: this entity records no line range.~%"))
      (:missing
       (format t "~&~%source: ~a is gone.~%" (getf result :file)))
      (:short
       (format t "~&~%source: ~a no longer reaches line ~a.~%"
               (getf result :file) (getf result :range)))
      (t
       (format t "~&~%source: unavailable (~(~a~)).~%" status)))))

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
    (dolist (field '(:tests :documents :decisions :mentions))
      (let ((entries (getf report field)))
        (when entries
          (format t "~&~(~a~): ~{~a~^, ~}~%"
                  field (mapcar (lambda (e) (getf e :name)) entries)))))
    (let ((maybe (getf report :possibly-affected)))
      (when maybe
        (format t "~&possibly affected (reached only through a stale edge): ~{~a~^, ~}~%"
                (mapcar (lambda (e) (getf e :name)) maybe))))
    ;; DES-0025, and the answer REQ-0027 exists for. Its own heading, naming
    ;; the repository and the commit, because this is a claim about another
    ;; working tree and not about anything deployed -- REQ-0027 R5 and its
    ;; WHAT THIS IS NOT.
    (let ((far (getf report :federated)))
      (when far
        (format t "~&in other repositories:~%")
        (dolist (e far)
          (format t "  @~a ~(~a~) ~a~40t~a~@[  [~a~@[:~a~]]~]~@[ @~a~]~%"
                  (getf e :repository) (getf e :type) (getf e :name)
                  (or (getf e :via) "")
                  (getf e :file) (getf e :line) (getf e :commit)))))))

(define-command federation ()
    "federation"
    "Routes matched across repositories, and the claims that matched nothing."
  (let ((report (federation-report)))
    (format t "~&~d route~:p published, ~d consumed, ~d matched~%"
            (length (getf report :published))
            (length (getf report :consumed))
            (length (getf report :matched)))
    ;; Both halves of the unmatched set, because a count of edges is not
    ;; evidence on its own (REQ-0027 R3). A parameterized route that no client
    ;; spells, and a client call to an endpoint no watched repository serves,
    ;; are different problems and a reader should be able to tell them apart.
    (let ((server-only (getf report :unmatched-published)))
      (when server-only
        (format t "~&served but never called from a watched repository:~%")
        (dolist (route server-only) (format t "  ~a~%" route))))
    (let ((client-only (getf report :unmatched-consumed)))
      (when client-only
        (format t "~&called but served by no watched repository:~%")
        (dolist (route client-only) (format t "  ~a~%" route))))))

(define-command context (&rest words)
    "context <task description>"
    "A budgeted context bundle for a task: what to know before editing."
  (let ((task (format nil "~{~a~^ ~}" words)))
    (let ((repo (current-repository)))
      (write-string
       (render-context
        (build-context (repository-graph repo) task
                       :source-fn (lambda (id) (definition-source repo id))))))))

(define-command init (path &optional document-directory claude-md endpoint)
    "init \"<directory>\" [<docs-dir>] [claude-md] [<host:port>]"
    "Prepare a repository for the Loom workflow. Writes; never commits."
  ;; REQ-0021 R16's two consents arrive as arguments rather than as prompts,
  ;; here as much as in the service: this command has to be callable from a
  ;; script, and a prompt in a run with no terminal is a stall nobody sees.
  ;; Running the command at all is the first consent; the literal token
  ;; `claude-md' is the second, and its absence means an existing CLAUDE.md is
  ;; left exactly as it was.
  (let ((report (prepare-repository path
                                    :document-directory (or document-directory "docs")
                                    :endpoint (or endpoint *default-endpoint*)
                                    :append-claude-md
                                    (and claude-md (string-equal "claude-md" claude-md)))))
    (cond
      ((getf report :problems)
       (format t "~&Nothing was written. ~d problem~:p:~%"
               (length (getf report :problems)))
       (dolist (problem (getf report :problems)) (format t "  - ~a~%" problem)))
      ((getf report :already-prepared)
       (format t "~&~a is already prepared. Nothing to do.~%" (getf report :root))
       (format t "  documents in ~a/, workflow concept ~a~%"
               (getf (getf report :manifest) :document-directory)
               (getf (getf report :manifest) :workflow-concept)))
      (t
       (log-event "init" "~a" (getf report :root))
       (format t "~&Prepared ~a~%" (getf report :root))
       (format t "  documents  : ~a/~%" (getf report :document-directory))
       (format t "  conventions: ~a~%" (getf report :workflow-concept))
       (format t "  service    : ~a~%" (getf report :endpoint))
       (format t "  wrote ~d file~:p:~{~%    ~a~}~%"
               (length (getf report :created)) (getf report :created))
       (dolist (skip (getf report :skipped))
         (format t "  skipped ~a -- ~a~%" (car skip) (cdr skip)))
       ;; The one thing a caller has to do by hand, said rather than buried.
       (unless (find "CLAUDE.md" (getf report :created) :test #'string=)
         (let ((skip (find "CLAUDE.md" (getf report :skipped)
                           :key #'car :test #'string=)))
           (when skip
             (format t "~&Nothing points at the skill yet. Re-run with ~
`claude-md' to append a pointer, or add one by hand.~%"))))
       (format t "~&Nothing was committed. `git status' shows exactly what was added.~%")))))

(define-command drift (&optional designator)
    "drift [<name>]"
    "Where the prose and the index disagree. Candidates, not findings."
  ;; REQ-0021 R7's markdown half. The comments half is the LLM reading files;
  ;; Loom does not index comments and DES-0013 says why.
  (write-string (render-prose
                 (let ((repository (current-repository designator)))
                   (prose-report (repository-graph repository)
                                 :repository (repository-name repository))))))

(define-command remove (&optional mode designator)
    "remove [tooling|all] [<name>]"
    "Take Loom out of a prepared repository. Documents stay unless you say all."
  ;; Two modes because "remove Loom" is two requests. Tooling is the default and
  ;; keeps every document -- they are the point of the exercise, and deleting a
  ;; team's knowledge because the tool is leaving would be the worst outcome
  ;; REQ-0021 could produce.
  (let* ((repository (current-repository designator))
         (mode (if (and mode (string-equal "all" mode)) :all :tooling))
         (report (remove-preparation (repository-root repository) :mode mode)))
    (if (getf report :problems)
        (progn (format t "~&Nothing was deleted. ~d problem~:p:~%"
                       (length (getf report :problems)))
               (dolist (problem (getf report :problems))
                 (format t "  - ~a~%" problem)))
        (progn
          (log-event "remove" "~(~a~) ~a" mode (getf report :root))
          (format t "~&Removed ~(~a~) from ~a~%" mode (getf report :root))
          (format t "  deleted ~d~{~%    ~a~}~%"
                  (length (getf report :deleted)) (getf report :deleted))
          (when (getf report :kept)
            (format t "  kept ~d document~:p~{~%    ~a~}~%"
                    (length (getf report :kept)) (getf report :kept)))
          (format t "~&Nothing was committed.~%")))))

(define-command architecture (&optional designator)
    "architecture [<name>]"
    "Write an ARCH document from the index. Says only what was measured."
  ;; REQ-0021 R5/R6, and the second half of preparing a tree: init makes the
  ;; directories, this puts something in them. Separate from `init' because a
  ;; structural report needs an index and init runs before there is one -- so
  ;; the order is prepare, watch, generate.
  (let* ((repository (current-repository designator))
         (report (generate-architecture repository)))
    (if (getf report :problems)
        (progn (format t "~&Nothing was written. ~d problem~:p:~%"
                       (length (getf report :problems)))
               (dolist (problem (getf report :problems))
                 (format t "  - ~a~%" problem)))
        (progn
          (log-event "architecture" "~a ~a" (getf report :repository)
                     (getf report :document))
          (format t "~&Wrote ~a~%" (getf report :created))
          (format t "  document   : ~a (draft, generated)~%" (getf report :document))
          (format t "  derived at : ~@[~a~]~%" (getf report :commit))
          (format t "  describes  : ~d name~:p~@[, ~d dropped as ambiguous~]~%"
                  (getf report :describes)
                  (let ((n (getf report :dropped))) (and (plusp n) n)))
          ;; Said every time, because the empty section is the one thing a
          ;; reader is most likely to take for an oversight.
          (format t "~&Its invariants section is empty on purpose -- what must remain~%")
          (format t "true is the half no index can derive, and is yours to write.~%")))))

(define-command structure (&optional designator)
    "structure [<name>]"
    "Systems, protocols, entry points and hubs, derived from the index."
  ;; REQ-0021 R5. Everything it prints was derived from the index, so every
  ;; name in it resolved against real code -- which is the property that makes
  ;; a generated architecture document worth writing and a hand-written one
  ;; hard to keep true. What it will not print is an invariant: code being
  ;; consistent with one is not evidence anybody intended it.
  (let ((repository (current-repository designator)))
    (multiple-value-bind (commit reason) (repository-commit repository)
      (write-string
       (render-structure
        (structure-report (repository-graph repository)
                          :commit commit
                          :commit-reason reason
                          :repository (repository-name repository)))))))

(define-command check-document (path &optional designator)
    "check-document <path> [<name>]"
    "Resolve one document's declared references without writing or indexing it."
  ;; REQ-0034. The console half of the operation, and the same function behind
  ;; it: an author drafting a document asks what its affects: and refines: will
  ;; resolve to before the file is written, instead of writing it, waiting for
  ;; the monitor and then subtracting the repository's baseline from `check'.
  (let ((report (check-document-references (current-repository designator) path)))
    (let ((problem (getf report :error)))
      (if problem
          (format t "~&~a: ~a~%" (getf report :path) problem)
          (let ((references (getf report :references)))
            (format t "~&~a  ~a  ~d declared reference~:p~%"
                    (getf report :document) (getf report :path)
                    (length references))
            (dolist (entry references)
              (case (getf entry :status)
                (:resolved
                 (format t "  ~(~a~): ~a -> ~a~%"
                         (getf entry :field) (getf entry :name) (getf entry :target)))
                (:self
                 (format t "  ~(~a~): ~a -> itself, which earns no edge~%"
                         (getf entry :field) (getf entry :name)))
                (:ambiguous
                 (format t "  ~(~a~): ~a -> ambiguous among ~d~%"
                         (getf entry :field) (getf entry :name)
                         (length (getf entry :candidates)))
                 (dolist (candidate (getf entry :candidates))
                   (format t "      ~a~%" candidate)))
                (t
                 (format t "  ~(~a~): ~a -> nothing in the index~%"
                         (getf entry :field) (getf entry :name))))))))))

(define-command check (&optional designator)
    "check [<name>]"
    "Run the rule checks from docs/rules and print violations."
  (let* ((graph (current-graph designator))
         (violations (entities-of-type graph :rule-violation))
         (unenforced (unenforced-rules graph)))
    ;; BUG-0033, and printed before the rule verdict rather than after it. A
    ;; file the analyzer could not read is the largest gap this command
    ;; reports: every other line here describes something the index knows and
    ;; got wrong, and this one describes a file it does not know at all. Under
    ;; "No violations." it would be a footnote to a clean bill of health, which
    ;; is exactly the reading that let PLAN-0032 sit unindexed for a day and a
    ;; half and BUG-0013 for twelve days. The parser's message carries a line
    ;; and a column on a YAML failure, which is the whole distance between "a
    ;; document is missing" and "quote the title".
    (let ((unparsed (unparsed-facts graph)))
      (when unparsed
        (format t "~&~d file~:p the analyzer could not read:~%" (length unparsed))
        (dolist (entry unparsed)
          (format t "  ~a~%    ~a~%" (getf entry :path) (getf entry :error)))))
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
    ;; DES-0029 D4, and a section of its own rather than entries in the list
    ;; above. A document naming db-handler when a class and an interface both
    ;; answer to it has made no mistake; asking an author to fix it is what
    ;; teaches them the list is noise. The candidates print under the name
    ;; because they are what goes back into the field to say which one.
    (let ((ambiguous (ambiguous-references graph)))
      (when ambiguous
        (format t "~&~d ambiguous document reference~:p, each naming several entities:~%"
                (length ambiguous))
        (dolist (entry ambiguous)
          (format t "  ~a -> ~a~%" (getf entry :document) (getf entry :name))
          (dolist (candidate (getf entry :candidates))
            (format t "      ~a~%" candidate)))))
    ;; DES-0025 D6. A backticked token carrying a path separator and a file
    ;; extension is a claim about a file, not an ordinary word, so one that no
    ;; *watched* repository holds is reported. The qualifier is load-bearing and
    ;; is printed rather than assumed: this count is a function of which
    ;; repositories are registered, and a document naming a file in a tree
    ;; nobody watched is reported here when it is merely unwatched.
    (let ((rotten (unresolved-path-references)))
      (when rotten
        (format t "~&~d prose file reference~:p no watched repository holds:~%"
                (length rotten))
        (dolist (entry rotten)
          (format t "  @~a ~a -> ~a~%"
                  (getf entry :repository) (getf entry :document)
                  (getf entry :reference)))))
    ;; BUG-0030 F1. The three keywords are the point of the line: a drop is
    ;; reported so that somebody can decide whether the :TO list of that
    ;; relationship is missing an entry, and rel-type, from-type and to-type
    ;; are exactly what that decision needs. Three types have been added to a
    ;; :TO list reactively, each after a tree went dark; this is the report
    ;; that makes the fourth visible while the tree still indexes.
    (let ((dropped (dropped-edges graph)))
      (when dropped
        (format t "~&~d edge~:p dropped, endpoints the ontology does not permit:~%"
                (length dropped))
        (dolist (drop dropped)
          (format t "  ~a  [~a]~%" (getf drop :problem) (getf drop :origin-file)))))
    ;; DES-0002 R6/R10, reported the way an unresolved reference is and for
    ;; the same reason: a definer Loom cannot characterise is a definition the
    ;; index knows it is missing, and it should be visible here rather than
    ;; only after a suite run.
    (let ((unhandled (unhandled-definer-macros graph))
          (swallowed (body-swallowing-macro-names graph))
          (collisions (generated-definition-collisions graph *macro-generators*)))
      (when unhandled
        (format t "~&~d definer macro~:p whose expansion could not be read:~%"
                (length unhandled))
        ;; The orphan count travels with the name because the list mixes two
        ;; populations (BUG-0016, and BODY-SWALLOWING-MACRO-NAMES' docstring):
        ;; a macro swallowing real call bodies and one whose recorded names are
        ;; keyword heads. Without the number a reader cannot tell which line to
        ;; act on, which is the failure BUG-0009 is made of.
        (dolist (macro unhandled)
          (format t "  ~a  [~a:~a]~@[  ~d call name~:p attached to nothing~]~%"
                  (name macro) (getp macro :file) (getp macro :start-line)
                  (gethash (string-downcase (name macro)) swallowed))))
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
      (let ((command (find-command (first tokens)))
            (arguments (rest tokens))
            (repository nil))
        ;; DES-0021 D1: a leading @name is the repository this one command acts
        ;; on. Stripped here, between the command lookup and the handler, so
        ;; that no command's lambda list has to make room for it -- which is
        ;; what lets the variadic ones take a repository at all, and what makes
        ;; every command added later take one without knowing about it.
        ;;
        ;; Only the first remaining token, and only unquoted-into-existence by
        ;; the sigil test: SPLIT-COMMAND-LINE has already removed the quotes, so
        ;; `find "@foo"' arrives here as @foo and would be stripped. That is the
        ;; known edge, and it is why the sigil is a character no name in these
        ;; trees begins with rather than a general escape grammar.
        (when (and command arguments (repository-token-p (first arguments)))
          (setf repository (subseq (first arguments) 1)
                arguments (rest arguments)))
        (cond ((null command)
               (format t "~&Unknown command ~s. Try: help~%" (first tokens)))
              (t (handler-case
                     ;; Bound for this command's dynamic extent and no longer.
                     (let ((*command-repository* repository))
                       (apply (command-handler command) arguments))
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
