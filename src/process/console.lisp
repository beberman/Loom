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

;;;; *LOG*, *LOG-LIMIT*, LOG-EVENT and INSTALL-DEBUGGER-HOOK are LOOM-UTILS',
;;;; since REV-0002 A1. All four were duplicated byte for byte in
;;;; src/serve/server.lisp, and neither system may depend on the other, so
;;;; there was nowhere below both to put them until loom-utils existed.
;;;;
;;;; SS3.3's requirement is unchanged and is now met by the shared hook: "The
;;;; image sets *debugger-hook* to that same logging path, so no non-interactive
;;;; thread can block on a debugger prompt even if a condition escapes a
;;;; handler." A process waiting on a debugger nobody can see is
;;;; indistinguishable, from the outside, from a process doing nothing.

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

(defparameter *command-domain* nil
  "The domain a command should act on, as the plist the analyzer parsed.

Bound beside *COMMAND-REPOSITORY* for one command's dynamic extent and never
set, for that variable's reason: a session that remembers a selection answers a
later query about the wrong part of the tree with nothing in the question or the
answer saying so.

NIL means the whole repository, which is every command that names no domain and
every repository that declares none.")

(defun refuse-domain (command)
  "Refuse COMMAND when the token named a domain, and say why.

PLAN-0050 S12. These commands act on the index itself -- they build it, drop
it, or write into the tree. A domain partitions an index; it is not one, so
there is nothing `reindex @repo/domain' could mean that is not either a lie or
a much larger feature.

Refused rather than ignored, which is CON-0001 at the console: a command that
silently acted on the whole repository after being handed part of one would be
answering a question nobody asked."
  (when *command-domain*
    (error "~a acts on a whole index, and ~(~a~) is one domain inside it. A ~
domain partitions an index rather than being one. Drop the domain from the ~
token and run ~a on the repository."
           command (getf *command-domain* :name) command)))

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
    (cond (named (or ;; PLAN-0050 S12. Through the split, so that a designator
                     ;; naming a domain -- `front-end/server' -- finds the
                     ;; repository rather than failing as an unknown name. An
                     ;; unknown domain refuses inside SPLIT-DESIGNATOR, naming
                     ;; what the repository does declare, and that refusal is
                     ;; more useful than this function's.
                     (split-designator named)
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
              ;; A setting and the variables that read it are one fact stated
              ;; twice, and a name reaching exactly those means the setting --
              ;; the rule RESOLVE-ONE applies to a document's reference. A variable
              ;; of that name which reads something else keeps it ambiguous.
              (t (or (setting-with-readers
                      (mapcar (lambda (hit) (get-entity graph (getf hit :id))) exact)
                      graph)
                     (error "~d things are named ~s. Name one:~{~%  ~a~}"
                            (length exact) term
                            (mapcar (lambda (hit)
                                      (format nil "~(~a~) ~a"
                                              (getf hit :type) (getf hit :id)))
                                    exact))))))
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
  (let ((n (to-integer text)))
    (unless (and n (not (minusp n)))
      (error "~a must be a non-negative integer, not ~s." what text))
    n))

;;;; ==================================================================
;;;; Output helpers
;;;; ==================================================================

(defun option-text (value)
  "VALUE, an encoded argument, as the text a reader would write for it. DES-0054
D1: a literal as itself, a name or dotted chain as its spelling, a list in
brackets, and the expression marker as `<expression>'."
  (cond ((stringp value) (format nil "~s" value))
        ((eq value :expression) "<expression>")
        ((eq value :none) "None")
        ((eq value :false) "False")
        ((eq value t) "True")
        ((and (consp value) (member (first value) '(:name :dotted))) (second value))
        ((and (consp value) (eq :list (first value)))
         (format nil "[~{~a~^, ~}]" (mapcar #'option-text (rest value))))
        (t (princ-to-string value))))

(defun print-entry-point (entry)
  "One line for an :ENTRY-POINT plist: framework, trigger, the options as
label=value, then the codebase and whether it deploys."
  (format t "~&  entry point: ~a ~(~a~)~{ ~a~}~@[ ~a~]~%"
          (getf entry :framework) (getf entry :trigger)
          (loop for (label . value) in (getf entry :options)
                collect (format nil "~a=~a" label (option-text value)))
          (when (getf entry :codebase)
            (format nil "codebase ~a~@[ (~a)~], ~(~a~)"
                    (getf entry :codebase) (getf entry :runtime)
                    (case (getf entry :deployed)
                      (:yes "deployed") (:no "not deployed") (t "deployment unknown"))))))

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

(defun print-deploys (deploys)
  "The `deploys' lines of `status', nothing for a tree with no firebase.json.
DES-0054 D8. When codebases are declared and no entry-points are, the line says so
and names `init', so the gap is recorded rather than an empty band."
  (when deploys
    (dolist (codebase (getf deploys :codebases))
      (format t "  deploys    : codebase ~a at ~a~@[ (~a)~], ~d entry point~:p~%"
              (getf codebase :codebase) (getf codebase :source) (getf codebase :runtime)
              (getf codebase :entry-points)))
    (when (getf deploys :aliases)
      (format t "  deploys    : project ~{~a~^, ~}~%" (getf deploys :aliases)))
    (unless (getf deploys :declared)
      (format t "  deploys    : firebase.json declares codebases and .loom/frameworks.yaml has no entry-points. `init' proposes them.~%"))
    (when (plusp (getf deploys :unnamed-registrations 0))
      (format t "  deploys    : ~d registration~:p in a default export ~:[carry~;carries~] no name; a re-export decides it~%"
              (getf deploys :unnamed-registrations)
              (= 1 (getf deploys :unnamed-registrations))))
    (when (plusp (getf deploys :unnamed-declarations 0))
      (format t "  deploys    : ~d setting declaration~:p with no literal first argument name~:[s~;~] nothing~%"
              (getf deploys :unnamed-declarations)
              (= 1 (getf deploys :unnamed-declarations))))))

(defun print-dependencies (status)
  "The `dependencies' lines of `status'. DES-0055 D9. Nothing without :DEPENDENCIES.

A NIL :STDLIB prints `stdlib unknown' and not `0 stdlib': the Python child marks
nothing on an interpreter without sys.stdlib_module_names, and a zero there would
read as measured (PLAN-0059 risk 7)."
  (dolist (d (getf status :dependencies))
    (format t "  dependencies: ~(~a~) ~d declared in ~d manifest~:p, ~d unmapped; ~
imports ~d joined, ~a, ~d undeclared~@[ (~d ambiguous)~]~%"
            (getf d :ecosystem) (getf d :declared) (getf d :manifests)
            (getf d :unmapped) (getf d :joined)
            (if (getf d :stdlib) (format nil "~d stdlib" (getf d :stdlib)) "stdlib unknown")
            (getf d :undeclared)
            (let ((n (getf d :ambiguous))) (and n (plusp n) n))))
  (when (getf status :frameworks-untracked)
    (format t "  dependencies: .loom/frameworks.yaml is not tracked by git, so another ~
checkout of this commit may join differently~%")))

(defun print-dependency (dependency)
  "The `describe' line for a :MODULE: where it is declared and what it provides."
  (when dependency
    (format t "~&  dependency : ~(~a~), declared in ~a~@[ ~{~a~^, ~}~]~@[ (~{~(~a~)~^, ~})~]; ~:[provides ~{~a~^, ~}~;unmapped -- declare it under dependency-modules:~]~%"
            (getf dependency :ecosystem) (getf dependency :manifest)
            (getf dependency :specs) (getf dependency :sections)
            (getf dependency :unmapped) (getf dependency :provides))))

(defun print-status (status)
  (format t "~&~a  ~a~%" (getf status :name) (getf status :root))
  (format t "  index      : ~d files, ~d entities, ~d relationships~%"
          (getf status :files) (getf status :entities) (getf status :relationships))
  ;; REQ-0050 R1 and R3, on the surface a developer actually reads. The plist
  ;; has carried the fingerprint and the drift since R2 landed and this printer
  ;; dropped both, so the console said how big the index was and never what
  ;; tree it was built from.
  ;;
  ;; Drift is printed even when the commit cannot be read, and the asymmetry is
  ;; the point: drift comes from REPOSITORY-STAMPS, which is Loom\'s own record
  ;; of the bytes it analyzed, so it is the one half that answers on a tree with
  ;; no git in it at all. A commit nobody could read is reported as unknown
  ;; with the reason rather than left blank (CON-0001).
  (let ((commit (getf status :commit))
        (drift (getf status :drift)))
    (format t "  built from : ~@[~a ~]~a~@[ ~a~]~%"
            (getf status :branch)
            (cond (commit (subseq commit 0 (min 12 (length commit))))
                  (t (format nil "commit unknown -- ~a"
                             (or (getf status :commit-reason) "no reason recorded"))))
            ;; The diff hash as the one thing a reader can do with it. Sixteen
            ;; hex digits are for comparing two answers; a reader of one answer
            ;; wants to know whether the commit named above is the whole story.
            (let ((diff (getf status :diff)))
              (and diff (not (string= diff (clean-diff-hash)))
                   "+ uncommitted edits")))
    (format t "  freshness  : ~a~@[; ~d file~:p no analyzer has read yet~]~%"
            (cond ((null drift) "unknown -- the index kept no file stamps")
                  ((zerop drift) "index current with the tree")
                  (t (format nil "STALE INDEX: ~d claimed file~:p changed since it was read"
                             drift)))
            ;; The half a stamp walk cannot see: a file created since the last
            ;; poll has no stamp to disagree with. Printed only when there is
            ;; one, because on a watched tree it is nought for all but the
            ;; seconds between a save and the next poll.
            (let ((n (getf status :unindexed))) (and n (plusp n) n))))
  (format t "  documents  : ~d~@[, ~d uncategorized~]~%"
          (getf status :documents)
          (let ((n (getf status :uncategorized-documents))) (and (plusp n) n)))
  ;; Printed unconditionally, zero included. A count that vanishes when it is
  ;; nought cannot be told from a count nobody computes, and these three exist
  ;; precisely to be read as zero-or-not (DES-0002 R10).
  ;; The three REQ-0053 adds are printed only when there is something to
  ;; print, which is the opposite rule and has the opposite reason. Zero tests
  ;; covering zero units is a fact about the tree; zero test files is a fact
  ;; about the language, and a Lisp tree carrying three permanent noughts would
  ;; be reporting that its analyzer does not write a property.
  (format t "  tests      : ~d test~:p covering ~d unit~:p~@[ in ~d test file~:p~]~@[, ~d with no case recognised~]~@[, ~d case~:p unnamed~]~%"
          (getf status :test-entities) (getf status :tested-units)
          (let ((n (getf status :test-files))) (and n (plusp n) n))
          (let ((n (getf status :test-files-without-cases))) (and n (plusp n) n))
          (let ((n (getf status :unnamed-tests))) (and n (plusp n) n)))
  (format t "  watcher    : ~(~a~)~%" (getf status :monitor))
  (format t "  rules      : ~d violation~:p, ~d unenforced~%"
          (getf status :violations) (getf status :unenforced-rules))
  (format t "  unresolved : ~d document reference~:p, ~d ambiguous, ~d definer macro~:p~%"
          (getf status :unresolved-references)
          (getf status :ambiguous-references)
          (getf status :unhandled-definer-macros))
  ;; PLAN-0050 S9. Printed only when the repository holds a module-scoped file,
  ;; because a Common Lisp tree has no import graph and a row of zeroes there
  ;; is a count of a question nobody asked -- REPOSITORY-STATUS answers NIL for
  ;; such a tree rather than five noughts, so the absence is decided there.
  ;;
  ;; Within the line every number prints, zeroes included, which is the rule
  ;; the `tests' line above states: a count that vanishes when it is nought
  ;; cannot be told from a count nobody computed. The four causes are what make
  ;; the number actionable -- 502 external is a healthy tree importing
  ;; libraries, and 502 out-of-domain is a declaration that is wrong.
  (let ((imports (getf status :unresolved-imports)))
    (when imports
      ;; The sixth is DES-0053 D5's: a Python import of a module the tree holds
      ;; but none of the importer's roots reaches, which tells the reader which
      ;; domain declaration is missing where :external would call it a library.
      (format t "  imports    : ~d resolved, ~d external, ~d out-of-domain, ~
~d unresolved, ~d target unclaimed, ~d unrooted~%"
              (getf imports :resolved 0)
              (getf imports :external 0)
              (getf imports :out-of-domain 0)
              (getf imports :unresolved 0)
              (getf imports :unclaimed-target 0)
              (getf imports :unrooted 0))))
  (print-dependencies status)
  ;; Beside the imports line because they are read together: a count that looks
  ;; wrong is usually a declaration that is wrong, and this is where it says so.
  (dolist (problem (getf status :domain-problems))
    (format t "  domains    : ~a~%" problem))
  (print-deploys (getf status :deploys))
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
  ;; REQ-0059, beside `unparsed' because the two are the halves a reader
  ;; confuses: `unparsed' is a file an analyzer claimed and could not read, and
  ;; this is a file no analyzer claimed at all. `files', `unindexed' and
  ;; `unparsed' are three counts about the claimed set, so a language nobody
  ;; analyzes appears in none of them and the tree can be most of the way
  ;; covered while saying nothing about the rest.
  ;;
  ;; The extensions rather than the paths: what a reader acts on is which
  ;; languages are missing, and 48 paths on every `status' is a page. Six
  ;; named, largest first, and the rest summed as `other' -- Loom's unclaimed
  ;; set has .sh fourth behind .json, .md and .py, so a tighter cap would drop
  ;; a whole language, and front-end carries 29 extensions in all, so no cap at
  ;; all would put the tail on the line instead.
  (let* ((unclaimed (getf status :unclaimed))
         (reason (getf status :unclaimed-reason))
         (by-extension (getf status :unclaimed-by-extension))
         (named (subseq by-extension 0 (min 6 (length by-extension))))
         (rest (- (or unclaimed 0)
                  (reduce #'+ named :key (lambda (e) (getf e :files)) :initial-value 0))))
    (cond (reason
           (format t "  unclaimed  : not counted -- ~a~%" reason))
          ((null unclaimed))
          (t
           (format t "  unclaimed  : ~d tracked file~:p no analyzer claims~
~@[ -- ~{~a~^, ~}~]~@[, ~d other~]~%"
                   unclaimed
                   (loop for entry in named
                         collect (format nil "~d ~a" (getf entry :files)
                                         (getf entry :type)))
                   (and (plusp rest) rest)))))
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
  (case (getf status :state)
    (:indexing (format t "  state      : indexing -- still reading the tree, nothing answerable yet~%"))
    (:embedding (format t "  state      : embedding -- answerable now, semantic seeding not yet~%"))
    (t nil))
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
  (refuse-domain "watch")
  (let ((repository (watch-repository path)))
    (log-event "watch" "~a" (repository-root repository))
    (print-status (repository-status repository))))

(define-command pause (&optional designator)
    "pause [<name>]"
    "Stop watching but keep the index. Resume with watch."
  (refuse-domain "pause")
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
  (refuse-domain "unwatch")
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
  (refuse-domain "reindex")
  (let ((repository (current-repository designator)))
    (reindex-repository repository)
    (print-status (repository-status repository))))

(define-command enrich (&optional designator)
    "enrich [<name>]"
    "Ask each language's toolchain to enrich the index. On demand only."
  (refuse-domain "enrich")
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

(define-command embed (&optional designator)
    "embed [<name>]"
    "Build or update the vector store that semantic seeding reads. On demand."
  ;; On demand and in the background, which is two decisions rather than one.
  ;;
  ;; On demand for ENRICH's reason (DES-0011 R9): a build is seconds to minutes
  ;; -- 66 for game-server's 1811 definitions, 183 for front-end's 3457 -- and
  ;; nothing on a poll cycle designed to cost milliseconds may reach it.
  ;;
  ;; In the background because the launcher runs this and must return. A query
  ;; that wants the store waits for the build instead (*VECTOR-BUILD-WAIT*), so
  ;; the cost lands on whoever asks first rather than on everybody who starts
  ;; the service, and on the normal path -- start Loom, read the banner, type a
  ;; question -- it has already been paid.
  (let* ((repository (current-repository designator))
         (before (vector-build-status repository)))
    (start-vector-build repository)
    (log-event "embed" "~a" (repository-root repository))
    (format t "  embedder   : ~a~%" (getf before :embedder))
    (format t "  definitions: ~d~%" (getf before :definitions))
    (if (getf before :vectors)
        (format t "  store      : ~d vector~:p of ~d, ~@[~d to re-embed~]~@[~*up to date~]~%"
                (getf before :vectors) (getf before :dimensions)
                (and (plusp (or (getf before :stale) 0)) (getf before :stale))
                (and (zerop (or (getf before :stale) 0)) t))
        (format t "  store      : none yet, building all ~d~%"
                (getf before :definitions)))
    (format t "  building   : started in the background; a query waits for it~%")))

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

(defun print-find-line (hit)
  "One `find\' row, naming the repository it came from.

REQ-0051 R2, and a printer of its own rather than a column on
PRINT-SUMMARY-LINE, which `describe\', `impact\' and `context\' share and none
of which asked for one. On both forms of the command: a caller who typed
`@game-server\' already knows the answer's tree, and the row still says it,
because the line is what gets pasted into a document and REQ-0050 R1's rule is
that an answer says which tree it came from wherever it is read."
  (format t "~&@~a ~(~a~) ~a~@[  [~a]~]~@[  (stale)~]~%"
          (getf hit :repository)
          (getf hit :type) (getf hit :name)
          (getf hit :location) (getf hit :stale)))

(defun print-find-cost (report)
  "What the search cost, when it was not one repository. REQ-0051 R5.

`find\' over REST is 4.7ms against one tree and this walks nine, so a federated
form that silently cost nine times as much would make the cheapest command Loom
has expensive without saying so. Printed only when more than one tree was
asked, because a line saying how long a single 4.7ms call took is noise on the
command a session issues most.

The skipped list prints whenever it is non-empty, whatever the count. A tree
passed over is what separates `absent from every tree\' from `absent from every
tree I looked at\', and CON-0001 refuses to let the second read as the first."
  (let ((searched (getf report :searched))
        (skipped (getf report :skipped)))
    (when (rest searched)
      (format t "~&searched ~d repositor~:@p in ~,2fs~%"
              (length searched) (getf report :seconds)))
    ;; Ungated by the count above, and deliberately: every tree being skipped
    ;; leaves SEARCHED empty, which is the one case where the rows say
    ;; "nothing matches" and no repository was asked at all.
    (when skipped
      (format t "~&~d not searched: ~{~a~^, ~}~%"
              (length skipped)
              (mapcar (lambda (row)
                        (format nil "~a (~a)" (getf row :repository) (getf row :reason)))
                      skipped)))))

(defun print-find-elsewhere (term elsewhere here)
  "The line REQ-0051 R3 is for: 0 here, and what the other trees hold.

In the same answer rather than a second call, because the first answer is where
the reader decides to reach for grep instead. A name absent from this
repository and present in another is a migration telling you where it went; a
name absent from every watched tree is dead."
  (if elsewhere
      (format t "~&Nothing matches ~s in ~a. 0 here;~{ ~a~^,~}.~%"
              term here
              (mapcar (lambda (row)
                        (format nil "~d in ~a" (getf row :total) (getf row :repository)))
                      elsewhere))
      (format t "~&Nothing matches ~s in ~a, or in any other watched repository.~%"
              term here)))

(defun print-find-occurrences (occurrences)
  "REQ-0054's second band: what the term is, when it is not a definition.

Printed after the elsewhere line and only on a miss, because that is the
sentence a reader is about to act on. `no definition, N occurrences, here they
are' and `no such name anywhere' imply opposite next moves, and until this the
two were one answer.

The count follows the list rather than replacing it. A short list read as the
whole truth is BUG-0002's failure, and a caller deciding whether to grep
properly needs to know the list was cut."
  (let ((rows (getf occurrences :lines))
        (total (getf occurrences :total))
        (reason (getf occurrences :reason)))
    (cond (reason
           (format t "  occurrences: not looked for -- ~a~%" reason))
          ((null rows)
           (format t "  and the text does not contain it either, so the name is dead.~%"))
          (t
           ;; DES-0049 D4. The heading names what the list is before the list
           ;; arrives. A caller who read 3053 occurrence lines as a result set
           ;; is REQ-0062's own instance, and BUG-0002 is the standing rule it
           ;; follows: a cut list says it was cut, and a fallback list says it
           ;; is a fallback.
           (format t "  Not definitions -- the places the string is written:~%")
           (format t "  It occurs in the text ~d time~:p:~%" total)
           (dolist (row rows)
             (format t "    ~a:~d  ~a~%"
                     (getf row :file) (getf row :line) (getf row :text)))
           (when (getf occurrences :truncated)
             (format t "    ~d of ~d shown.~%" (length rows) total))))))

(defun trigger-flag (arguments)
  "The name following --trigger in ARGUMENTS, and ARGUMENTS without the pair.
DES-0054 D8. A flag with nothing after it is an error rather than a flag
silently ignored."
  (let ((position (position "--trigger" arguments :test #'equal)))
    (cond ((null position) (values nil arguments))
          ((>= (1+ position) (length arguments))
           (error "--trigger needs a name. Try: find [<name>] --trigger <kind>"))
          (t (values (nth (1+ position) arguments)
                     (append (subseq arguments 0 position)
                             (subseq arguments (+ position 2))))))))

(defun kind-flag (arguments)
  "The family ARGUMENTS names, and ARGUMENTS without the flag.

  (kind-flag '(\"repository\" \"--code\"))  =>  :code, (\"repository\")

Stripped anywhere among the arguments rather than fixed in a position, because
`find repository --code' and `find --code repository' are both what somebody
types and neither is wrong. The term and the type are read from what is left,
so a flag can never be mistaken for either."
  (let ((kind nil) (rest '()))
    (dolist (argument arguments)
      (cond ((and (stringp argument) (string-equal argument "--code"))
             (setf kind :code))
            ((and (stringp argument)
                  (or (string-equal argument "--documentation")
                      (string-equal argument "--doc")))
             (setf kind :documentation))
            (t (push argument rest))))
    (values kind (nreverse rest))))

(define-command find (&rest arguments)
    "find [<name>] [<type>] [--code|--documentation] [--trigger <kind>]"
    "Where something is defined. Without a repository, every watched one. \
--trigger lists what a declaration marked as an entry point of that kind, and \
then the name may be left out."
  ;; REQ-0051 R1. With no @token and several repositories watched this used to
  ;; reach CURRENT-GRAPH and be refused with "Several repositories are watched.
  ;; Name one" -- which is right for `describe' and `impact', whose answer is
  ;; about one entity, and wrong for the question nine trees generate: which of
  ;; them owns this name. Naming one keeps today's behaviour and today's cost.
  ;;
  ;; The nothing-watched case still goes through CURRENT-REPOSITORY, whose
  ;; message says what to type. REQ-0051 R4's distinction at its most extreme: a
  ;; `find' against an empty registry must not answer "found nowhere".
  (multiple-value-bind (trigger arguments) (trigger-flag arguments)
  (multiple-value-bind (kind rest) (kind-flag arguments)
   (let* ((term (first rest))
          (type (and (second rest) (intern (string-upcase (second rest)) :keyword)))
          (trigger-filter (trigger-property-filter trigger))
          (named (or *command-repository*
                     (and (null (rest (all-repositories))) t))))
    (unless (or term trigger)
      (error "find needs a name. Try: find <name> [<type>] [--code|--documentation]"))
    (when (and trigger (not named) (rest (all-repositories)))
      (error "find --trigger searches one repository. Name one with ~c<name>."
             *repository-sigil*))
    (if (or named (null (all-repositories)))
        (let ((repository (current-repository)))
          (multiple-value-bind (hits total)
              ;; PLAN-0050 S12. The filter is NIL unless the command's token
              ;; named a domain, so a caller who named none gets the query
              ;; path this has always taken.
              (search-entities (repository-graph repository) :name term
                               :type type :kind kind :limit *console-find-limit*
                               :property-filters (append
                                                  (domain-property-filter *command-domain*)
                                                  trigger-filter))
            (cond
              ;; DES-0054 D8. A trigger nothing carries is its own answer: there is
              ;; no name to look for elsewhere or in the text.
              ((and (null hits) trigger)
               (format t "~&No entity has the trigger ~(~a~)~@[ and the name ~s~].~%"
                       trigger term))
              ;; DES-0049. A family that excluded everything is not the same
              ;; miss as a term nothing carries, and must not print the same
              ;; answer. `find repository --documentation' matched twenty code
              ;; definitions and no document, and saying "nothing matches"
              ;; before listing 3482 occurrence lines was wrong twice: the term
              ;; is not absent, and the occurrences are not what the caller
              ;; wants to see.
              ((and (null hits) kind)
               (let ((unfiltered (nth-value 1 (search-entities
                                               (repository-graph repository)
                                               :name term :type type))))
                 (format t "~&No ~(~a~) entity is named ~s.~%" kind term)
                 (when (plusp unfiltered)
                   (format t "  ~d entit~:@p of another kind ~:[is~;are~] -- drop the flag to see ~
~:[it~;them~].~%"
                           unfiltered (> unfiltered 1) (> unfiltered 1)))
                 (when (eq kind :documentation)
                   (format t "  `find' matches names. For documents ABOUT ~s, ask `context'.~%"
                           term))))
              ((null hits)
               (print-find-elsewhere
                term
                (repositories-holding term :type type
                                           :exclude (repository-name repository))
                (repository-name repository))
               (print-find-occurrences
                (textual-occurrences (repository-root repository) term)))
              (t (dolist (hit hits)
                   (print-find-line (list* :repository (repository-name repository) hit)))
                 ;; BUG-0002. Printed only when it happened, and printed as a
                 ;; count rather than a word: twenty rows read as the whole
                 ;; truth, and the number that says otherwise is the one the
                 ;; caller needs to decide whether to narrow the term. `impact'
                 ;; has carried its own "(truncated)" since it was written; this
                 ;; is the same fact in the same interface.
                 (when (> total (length hits))
                   (format t "~&~d of ~d shown. Narrow the term, or name a type.~%"
                           (length hits) total))))))
        ;; The federated branch takes the family too: a caller searching every
        ;; watched tree has as much use for it as one naming a tree.
        (let* ((report (search-repositories term :type type :kind kind
                                                 :limit *console-find-limit*))
               (hits (getf report :entities))
               (total (getf report :total)))
          (cond
            ((and (null hits) kind)
             (format t "~&No ~(~a~) entity is named ~s in any watched repository.~%"
                     kind term))
            ((null hits)
             (format t "~&Nothing matches ~s in any watched repository.~%" term))
            (t (dolist (hit hits) (print-find-line hit))
               (when (> total (length hits))
                 (format t "~&~d of ~d shown. Narrow the term, or name a type.~%"
                         (length hits) total))))
          (print-find-cost report)))))))

(defparameter *call-shape-signatures-shown* 5
  "How many signatures `describe' names in its call-shapes line. DES-0055 D12.")

(defun call-shapes-line (distribution)
  "The `describe' line for CALL-SHAPE-DISTRIBUTION's answer, or NIL for NIL.

The five most common signatures, then how many signatures that left out, then
the sites reached through an ambiguous name (counted apart and not in the site
total), the edges that name no call form, and `pre-expansion' for a macro,
whose forms are as written and not as expanded. DES-0055 D12, PLAN-0060 step 7."
  (when distribution
    (let* ((signatures (getf distribution :signatures))
           (shown (subseq signatures 0 (min *call-shape-signatures-shown*
                                            (length signatures))))
           (hidden (- (length signatures) (length shown)))
           (fan-out (getf distribution :fan-out))
           (without-form (getf distribution :without-form)))
      (format nil "call shapes: ~d site~:p~@[ -- ~{~a~^, ~}~]~@[, ~d more~]~
~@[ (~d more through ambiguous names)~]~@[, ~d without a call form~]~
~:[~;, pre-expansion~]"
              (getf distribution :sites)
              (mapcar (lambda (entry) (format nil "~a ~d" (first entry) (second entry)))
                      shown)
              (and (plusp hidden) hidden)
              (and (plusp fan-out) fan-out)
              (and (plusp without-form) without-form)
              (getf distribution :pre-expansion)))))

(defun print-neighbors (detail)
  "The neighbour bands of `describe', and under the callers the call-shapes line.

A function of its own because each distinct name a DEFINE-COMMAND body calls
is a :CALL-SITE (DES-0014) and the ceiling on them has 2 of headroom. The body
called NEIGHBOR-LINE from this loop and now calls this function, so `describe'
mints the same number of sites as before the call-shapes line was added
(PLAN-0060 step 7)."
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
            (mapcar #'neighbor-line (getf group :entities)))
    ;; DES-0055 D12. Under the callers, since the line is about them.
    (when (and (eq :in (getf group :direction)) (eq :calls (getf group :rel-type)))
      (let ((line (call-shapes-line (getf detail :call-shapes))))
        (when line (format t "~&  ~a~%" line))))))

(define-command describe (term &optional flag)
    "describe <name> [--source]"
    "Full detail for one entity, with its neighbours grouped by edge type. \
--source adds the definition's text."
  (let* ((repository (current-repository))
         (graph (repository-graph repository))
         (entity (resolve-entity graph term))
         (detail (describe-entity graph (id entity)
                                  :provenance (file-provenance
                                               repository (getp entity :file))))
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
    ;; REQ-0050 R1, and printed only when this entity's own file has moved.
    ;; `describe' is issued dozens of times in a session where `structure' is
    ;; read once and pasted into a document, so the two answer the same
    ;; question with different noise budgets: structure says which of the two
    ;; states it is in every time, and this says nothing while there is nothing
    ;; to say.
    ;;
    ;; The file rather than the repository, which is both the precise question
    ;; for an answer about one definition and the cheap one -- a tree-wide
    ;; drift here measured 4.7ms to 25.6ms over REST.
    (when (getf (getf detail :provenance) :file-stale)
      (format t "~&  (this file has changed since the index read it)~%"))
    ;; BUG-0044. `describe find-entities' answered every question about the
    ;; function except what it takes, while :ARGUMENTS held every token. Its own
    ;; line rather than the summary line, because the summary is shared with
    ;; `find' and `impact' and a signature would widen every row of both.
    (when (getf detail :signature)
      (format t "~&  ~a~%" (getf detail :signature)))
    ;; REQ-0049 R2. Below the signature and above the edges, because it is what
    ;; a reader wants after knowing what the thing takes and before knowing
    ;; what it touches.
    (when (getf detail :summary)
      (format t "~&  ~a~%" (getf detail :summary)))
    ;; DES-0055 D9. A :MODULE's declaration; absent for everything else.
    (print-dependency (getf detail :dependency))
    ;; DES-0054 D8. What a framework registered this for, one line per
    ;; registration. A dotted value prints as its text; a name by its spelling.
    (dolist (entry (getf detail :entry-point))
      (print-entry-point entry))
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
    (print-neighbors detail)
    ;; REQ-0055, and the opposite of what that requirement asked for. The
    ;; :UNRESOLVED-CALLS property is written by one line of RESOLVE-CALLS, read
    ;; by no pass, and printed by nothing -- which is why it read as leftover
    ;; bookkeeping. It is not: it is the only record that a definition calls a
    ;; name no definition in this tree answers, and BUG-0055 used exactly that
    ;; record as its evidence.
    ;;
    ;; Beside the neighbour bands because it is their complement. The bands say
    ;; what this reaches, with BUG-0055's marker on the guesses; this says what
    ;; it reaches outside the tree, and a reader judging whether a `calls` band
    ;; is thin needs both. CON-0001's recorded gap, finally shown to somebody.
    (let ((external (getp entity :unresolved-calls)))
      (when external
        (format t "~&  external: ~{~a~^, ~}~%    ~d name~:p no definition in ~
this tree answers.~%"
                external (length external))))
    ;; REQ-0031 R1, last because it is the longest thing printed and the
    ;; neighbours are the survey a reader uses to decide whether they wanted
    ;; this entity at all.
    (when source-wanted
      (print-source (definition-source repository (id entity))))))

(defun neighbor-line (entry)
  "One neighbour: its name, and what is uncertain about reaching it.

Two annotations, either or both, and neither printed when there is nothing to
say. The referrer kind is DES-0014 R7's, and NIL for every type but a call
site. The confidence is BUG-0055's: an edge a resolution pass guessed at is
written `name (inferred 0.33)', so `ingestModel's four outbound calls read as
one callee and three candidates rather than as four callees.

Printed as a number and not as a word. 0.33 says a three-way fan-out and 0.05
says a twenty-way one, and those are different enough that a reader who sees
the second stops reading the row."
  (let ((parts (append (when (getf entry :referrer-kind)
                         (list (format nil "~(~a~)" (getf entry :referrer-kind))))
                       (when (eq :inferred (getf entry :edge-source))
                         (list (format nil "inferred ~,2f"
                                       (getf entry :edge-confidence)))))))
    (format nil "~a~@[ (~{~a~^, ~})~]" (getf entry :name) parts)))

(defun print-sites (term limit)
  "The body of `sites'. A function of its own because the DEFINE-COMMAND body
mints one :CALL-SITE per distinct name it calls (DES-0014), and the ceiling that
guards that count has 2 of headroom (PLAN-0060 step 7). The body makes one call,
and the calls this function makes are ordinary :CALLS edges."
  (let* ((graph (current-graph))
         (entity (resolve-entity graph term))
         (groups (shape-sites graph (id entity)
                              :per-group (if limit (resolve-count limit "limit") 20))))
    (format t "~&~a~@[  [~a]~]~%" (getf (entity-summary entity) :name)
            (getf (entity-summary entity) :location))
    (if (null groups)
        (format t "~&  no call form is recorded for any call to it~%")
        (dolist (group groups)
          (format t "~&~a  ~d site~:p~%" (getf group :signature) (getf group :count))
          (dolist (row (getf group :sites))
            (format t "  ~a:~a  ~a~%" (first row) (second row) (third row)))
          (when (plusp (getf group :more))
            (format t "  ~d more~%" (getf group :more)))))))

(define-command sites (term &optional limit)
    "sites <name> [<limit>]"
    "The calls to one definition grouped by how they are written, the rarest \
group first, with file:line for each. <limit> is the rows shown per group, 20 \
by default."
  ;; DES-0055 D12, REQ-0041 R4: which sites differ. The 5 three-argument
  ;; dict-value calls among 454 are the first group.
  (print-sites term limit))

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
       (format t "~&~%source: this entity names no file.~%"))
      (:missing
       (format t "~&~%source: ~a is gone.~%" (getf result :file)))
      (:short
       (format t "~&~%source: ~a no longer reaches line ~a.~%"
               (getf result :file) (getf result :range)))
      (t
       (format t "~&~%source: unavailable (~(~a~)).~%" status)))))

(defun print-resemblance-row (row &optional (indent 2))
  "One candidate: what it is, where, how close, and why it might be the same.

The cosine leads because it is what ordered the list, and the reasons follow on
their own line because DES-0041 D7 has them point rather than conclude -- five
of the ten pairs REQ-0042 was written from were read on both sides and were not
duplicates."
  (let ((pad (make-string indent :initial-element #\Space))
        (shared-name (getf row :shared-name-words))
        (shared-prose (getf row :shared-prose-words))
        (arity (getf row :arity))
        (subject-arity (getf row :subject-arity)))
    (format t "~&~a~,4f  ~(~a~) ~a~@[  [~a]~]~%"
            pad (getf row :similarity) (getf row :type) (getf row :name)
            (getf row :location))
    (when (or shared-name shared-prose arity subject-arity)
      (format t "~a        ~@[name: ~{~a~^ ~}  ~]~@[prose: ~{~a~^ ~}  ~]~
~@[arity ~a~]~@[ against ~a~]~%"
              pad shared-name shared-prose arity
              (and arity subject-arity (/= arity subject-arity) subject-arity)))))

(defun repository-for-similar (&optional designator)
  "A repository and its vector store, or a refusal naming what is missing.

DES-0041 D10. `context' without a store answers lexically and says nothing,
because it still has an answer. This has no lexical fallback -- REQ-0045 R4 is
why it should not get one -- so an empty result would mean both `nothing
resembles this' and `nothing could have', and the two need telling apart. No
ollama, no store, and a store whose embedder identity does not match are still
one state with one meaning (REQ-0048 R6); the meaning is reported rather than
returned as an empty list."
  (require-repository-vectors (current-repository designator)))

(define-command similar (term &optional against)
    "similar <name> [<repository>]"
    "Definitions that resemble one, by meaning rather than by name."
  ;; REQ-0042 R1 and R2. The question `find' cannot ask: a duplicate is
  ;; precisely the case where the two names differ, so every one of the ten
  ;; pairs PLAN-0036 found by hand was invisible to a name search.
  (multiple-value-bind (source source-store) (repository-for-similar)
    (let* ((subject (resolve-entity (repository-graph source) term)))
      (multiple-value-bind (target target-store)
          (if against
              (repository-for-similar against)
              (values source source-store))
        (let ((rows (resembling subject source-store
                                (repository-graph target) target-store)))
          (print-summary-line (entity-summary subject))
          (format t "~&  resembling, in ~a:~%" (repository-name target))
          (if rows
              (dolist (row rows) (print-resemblance-row row))
              ;; Not an empty list: the store exists, so this is the answer
              ;; rather than the absence of one.
              (format t "~&    Nothing in ~a is close to it.~%"
                      (repository-name target))))))))

(define-command survey (first-repository second-repository &optional cut)
    "survey <repository> <repository> [<cut>]"
    "Definitions in the first that resemble something in the second."
  ;; REQ-0042 R3, the migration survey PLAN-0036 assembled by hand. One row per
  ;; entity carrying its single best match, because every pair above a flat
  ;; threshold reports one fact several ways -- DEFAULT-JSON-KEY-NAME came back
  ;; four times against four different utils entities.
  (multiple-value-bind (source source-store) (repository-for-similar first-repository)
    (multiple-value-bind (target target-store) (repository-for-similar second-repository)
      (let ((floor (if cut
                       (let ((parsed (ignore-errors (read-from-string cut))))
                         (unless (realp parsed)
                           (error "~s is not a number. The cut is a cosine, ~
between 0 and 1." cut))
                         (float parsed 1.0))
                       *survey-cut*)))
        (multiple-value-bind (rows name-equal reached)
            (resemblance-survey (repository-graph source) source-store
                                (repository-graph target) target-store
                                :cut floor)
          (format t "~&~a against ~a, at ~,2f:~%"
                  (repository-name source) (repository-name target) floor)
          (if rows
              (dolist (row rows)
                ;; The subject's location, because two entities in one tree can
                ;; carry one name -- front-end has two makePolygonShape, and
                ;; without the file the two rows read as one row printed twice.
                (format t "~&  ~,4f  ~28a ~~ ~a~%           ~a~%"
                        (getf row :similarity)
                        (getf row :subject-name)
                        (getf row :name)
                        (getf row :subject-location)))
              (format t "~&  No pair reaches ~,2f.~%" floor))
          ;; BUG-0002 in a second place. Forty rows read as the whole truth,
          ;; and the number that says otherwise is what tells a caller to raise
          ;; the cut rather than to believe the table.
          (when (> reached (length rows))
            (format t "~&  ~d of ~d shown. Raise the cut.~%"
                    (length rows) reached))
          ;; DES-0041 D4. Counted rather than listed: these are what `find'
          ;; already answers, and every one of them scores 1.0000, so listing
          ;; them would spend the readable rows on the question that was not
          ;; asked.
          (format t "~&  ~d pair~:p share a name and are not listed; ~
`find' answers those.~%" name-equal))))))

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
    ;; BUG-0055. The `?' is on the row as well as inside the path, because the
    ;; path is the last column and a reader scanning a page of rows for what to
    ;; trust should not have to read to the end of each one.
    ;;
    ;; BUG-0050 F1. The location, in `find' and `describe's own bracket form.
    ;; Without it a generic's methods print as one row repeated: measured on
    ;; game-server 2026-08-24, `impact data-handler 5' returned 822 rows of
    ;; which 45 names occupied more than one, worst case `dhandler-copy' at
    ;; eight -- eight real methods in four files, printing as eight lines
    ;; reading `d2 method dhandler-copy' with nothing on them saying which. The
    ;; REST answer has carried `id' and `location' throughout; the console
    ;; printed neither, so the one field that separates them was the one field
    ;; not shown.
    ;;
    ;; Two spaces rather than a tab column. Locations run from
    ;; `bimap.js:18-20' to `data-api/operator-handler.lisp:137-144', so no
    ;; column aligns for long, and a tab that aligns some rows and not others
    ;; reads worse than one that never does.
    ;;
    ;; The bracket is dropped when it would repeat the name, which is every
    ;; :FILE row: a file entity is named by its path and locates to the same
    ;; path, and printing it twice spends the width that made this legible.
    (dolist (e (getf report :impacted))
      (let ((location (getf e :location)))
        (format t "  d~a~a ~(~a~) ~a~@[  [~a]~]  ~a~@[  [entry: ~(~a~)]~]~%"
                (getf e :depth) (if (getf e :inferred) "?" " ")
                (getf e :type) (getf e :name)
                (unless (equal location (getf e :name)) location)
                (getf e :via) (getf e :trigger))))
    ;; BUG-0050 F2, said once rather than left on every row to be read against
    ;; the depth the caller typed.
    (let ((asked (getf report :depth))
          (deepest (reduce #'max (getf report :impacted)
                           :key (lambda (e) (or (getf e :depth) 0))
                           :initial-value 0)))
      (when (and asked (> deepest asked))
        (format t "~&  d~d is one hop past the ~d asked for, and is the true path ~
length: a one-step edge is followed once from everything already impacted, so a ~
base found at the cap yields a neighbour beyond it.~%"
                deepest asked)))
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

(defun take-budget-flag (words)
    "WORDS with any --budget N removed, and the N, as two values.

A flag rather than a trailing positional, for DESCRIBE's reason one command
over: `context <words>' takes the whole line as the task, so a number on the
end is a task word until something says otherwise -- and `list the top 10
handlers' is a task whose last word is a number. A positional budget would read
that as a budget of 10 and return four lines, with nothing in the output saying
it had done so.

An unrecognised --flag is refused rather than swallowed into the task, because
a typo that silently answers a different question is what this command is least
able to make visible."
  (let ((task '()) (budget nil) (rest words))
    (loop while rest
          for word = (pop rest)
          do (cond ((string-equal word "--budget")
                    (let ((value (pop rest)))
                      (unless value
                        (error "--budget needs a number after it."))
                      (let ((parsed (ignore-errors (parse-integer value))))
                        (unless (and parsed (plusp parsed))
                          (error "~s is not a budget. Give a positive number ~
of tokens." value))
                        (setf budget parsed))))
                   ((and (> (length word) 2) (string= "--" (subseq word 0 2)))
                    (error "Unknown option ~s. Try: --budget <tokens>" word))
                   (t (push word task))))
    (values (nreverse task) budget)))

(define-command context (&rest words)
    "context <task description> [--budget <tokens>]"
    "A budgeted context bundle for a task: what to know before editing."
  (multiple-value-bind (task-words budget) (take-budget-flag words)
   (let ((task (format nil "~{~a~^ ~}" task-words)))
    (let* ((repo (current-repository))
           (started (get-internal-real-time)))
      (multiple-value-bind (bundle instrumentation)
          ;; DEC-0006. Bound here rather than read inside BUILD-CONTEXT for the
          ;; reason the SOURCE-FN comment above gives: loom-knowledge is handed
          ;; a graph and never learns which repository it belongs to, and this
          ;; entry has the repository. REPOSITORY-VECTORS is NIL until somebody
          ;; builds a store, so on an ordinary tree both bindings are NIL and
          ;; SEED-ENTITIES takes the path it has taken since S3.
          (let ((loom-knowledge:*context-vector-store* (repository-vectors repo))
                (loom-knowledge:*context-embedder* (current-embedder)))
            (build-context (repository-graph repo) task
                           :budget (or budget *context-token-budget*)
                           ;; REQ-0050 R1. The bundle is read for an hour after
                           ;; it is printed, so it says which tree it came from
                           ;; rather than leaving that to a `status' call the
                           ;; reader would have to think to make.
                           :provenance (index-provenance repo)
                           :source-fn (lambda (id) (definition-source repo id))))
        (write-string (render-context bundle))
        ;; REQ-0036 R1 is every context call rather than every call over the
        ;; service, so the console records too. Nothing is written and nothing
        ;; is printed unless an operator set the directory.
        (let ((id (record-context-call
                   repo bundle instrumentation
                   :seconds (/ (float (- (get-internal-real-time) started))
                               internal-time-units-per-second))))
          (when id (format t "~&record ~a~%" id))))))))

(defun print-dependency-proposal (report)
  "REPORT's :DEPENDENCY-PROPOSAL, when it has one, under the heading that says
it is a proposal. DES-0055 D7: init shows the block and writes nothing, so
adopting it is a person's edit to .loom/frameworks.yaml."
  (when (getf report :dependency-proposal)
    (format t "~&dependency-modules: proposed, not written. Copy what you ~
confirm into .loom/frameworks.yaml.~%~a"
            (getf report :dependency-proposal))))

(define-command init (path &rest arguments)
    "init \"<directory>\" [<docs-dir>] [claude-md] [<host:port>] [--update] \
[--apply] [--replace-unproven]"
    "Prepare a repository for the Loom workflow. Writes; never commits."
  (refuse-domain "init")
  ;; REQ-0021 R16's consents arrive as arguments rather than as prompts, here as
  ;; much as in the service: this command has to be callable from a script, and
  ;; a prompt in a run with no terminal is a stall nobody sees. Running the
  ;; command at all is the first consent; the literal token `claude-md' is the
  ;; second, and its absence means an existing CLAUDE.md is left exactly as it
  ;; was.
  ;;
  ;; --update and --replace-unproven are flags rather than a fifth and sixth
  ;; positional, for the reason `describe --source' is one: this command's
  ;; positionals are a directory, a directory name and a host:port, and a bare
  ;; `update' in that run reads as one of those. An unrecognised token is
  ;; refused rather than ignored -- a typo that silently prepares a tree instead
  ;; of refreshing it writes eighteen directories into somebody's repository.
  (let ((positional '()) (update nil) (replace-unproven nil) (apply-changes nil))
    (dolist (argument arguments)
      (cond ((string-equal argument "--update") (setf update t))
            ((string-equal argument "--apply") (setf apply-changes t))
            ((string-equal argument "--replace-unproven") (setf replace-unproven t))
            ((and (> (length argument) 1) (string= "--" argument :end2 2))
             (error "Unknown option ~s. Try: --update, --apply, --replace-unproven"
                    argument))
            (t (push argument positional))))
    (setf positional (nreverse positional))
    (destructuring-bind (&optional document-directory claude-md endpoint) positional
      (let ((report (prepare-repository path
                                        :document-directory (or document-directory "docs")
                                        :endpoint (or endpoint *default-endpoint*)
                                        :append-claude-md
                                        (and claude-md (string-equal "claude-md" claude-md))
                                        :update update
                                        :replace-unproven replace-unproven
                                        :apply-changes apply-changes)))
    (cond
      ((getf report :problems)
       (format t "~&Nothing was written. ~d problem~:p:~%"
               (length (getf report :problems)))
       (dolist (problem (getf report :problems)) (format t "  - ~a~%" problem)))
      ((getf report :update)
       ;; REQ-0052 R2's report: what a refresh changed, and every file it did
       ;; not, with the reason on the same line. A skip here is not a failure --
       ;; `already current' is the ordinary answer on a tree nobody has let go
       ;; stale -- so the counts lead and the reasons follow.
       (let ((dry (getf report :dry-run))
             (changed (or (getf report :replaced) (getf report :would-replace))))
         (unless dry (log-event "init" "update ~a" (getf report :root)))
         (format t "~&~:[Refreshed~;Refreshing~] ~a~%" dry (getf report :root))
         (cond ((and changed dry)
                (format t "  would rewrite ~d file~:p:~{~%    ~a~}~%"
                        (length changed) changed))
               (changed
                (format t "  rewrote ~d file~:p:~{~%    ~a~}~%"
                        (length changed) changed))
               (t (format t "  nothing needs rewriting.~%")))
         (dolist (skip (getf report :skipped))
           (format t "  ~a -- ~a~%" (car skip) (cdr skip)))
         ;; REQ-0052 R2. Dry run is the default and the line that says so is the
         ;; one `complete' prints for the same reason: a command that writes into
         ;; somebody else's tree should take two decisions from the caller, not
         ;; one.
         (if dry
             (format t "~&Dry run: nothing written. Add --apply to write it.~%")
             (format t "~&Nothing was committed. `git status' shows exactly what ~
changed.~%"))))
      ((getf report :already-prepared)
       (format t "~&~a is already prepared. Nothing to do.~%" (getf report :root))
       (format t "  documents in ~a/, workflow concept ~a~%"
               (getf (getf report :manifest) :document-directory)
               (getf (getf report :manifest) :workflow-concept))
       ;; DES-0044 D1's discoverability argument, and the reason a second verb
       ;; was not needed: the flag is named where the refusal is printed.
       (format t "  Templates move; run with --update to refresh what Loom wrote.~%")
       (print-dependency-proposal report))
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
       (print-dependency-proposal report)
       (format t "~&Nothing was committed. `git status' shows exactly what was added.~%")))))))

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
  (refuse-domain "architecture")
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
    ;; REQ-0050 R1: the index's fingerprint, not `git rev-parse HEAD' asked
    ;; when the report is built. The two agree on a tree nobody has edited
    ;; since the last poll and on no other.
    (let ((provenance (index-provenance repository)))
      (write-string
       (render-structure
        (apply #'structure-report (repository-graph repository)
               :repository (repository-name repository)
               provenance))))))

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
  ;; The repository rather than the graph alone, since REQ-0056: telling an
  ;; unresolved reference another tree answers from one nobody does is a
  ;; question about the registry, and CURRENT-GRAPH throws the handle away.
  (let* ((repository (current-repository designator))
         (graph (repository-graph repository))
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
    ;; REQ-0056. Three headings rather than one list, because the eight
    ;; game-server reported for PLAN-0002 were three different states and only
    ;; the last is a defect in a document. A plan whose subject is the names it
    ;; moved out of the tree was being told, forever, that its subject is rot.
    (let ((classified (classified-unresolved-references repository)))
      (let ((rot (getf classified :rot)))
        (when rot
          (format t "~&~d unresolved document reference~:p:~%" (length rot))
          (dolist (entry rot)
            (format t "  ~a -> ~a~%" (getf entry :document) (getf entry :reference)))))
      ;; Its own heading and not silence. Which trees the service holds decides
      ;; what lands here, so a reader has to be able to see that the answer was
      ;; federated rather than find a name quietly missing from both lists.
      (let ((elsewhere (getf classified :elsewhere)))
        (when elsewhere
          (format t "~&~d reference~:p another watched repository answers:~%"
                  (length elsewhere))
          (dolist (entry elsewhere)
            (format t "  ~a -> ~a  [~a~@[ ~a~@[:~d~]~]]~%"
                    (getf entry :document) (getf entry :reference)
                    (getf entry :repository) (getf entry :file) (getf entry :line)))))
      ;; R3. A different state with a different repair: the file is gone and no
      ;; tree can ever answer this id again, where the bare name often still
      ;; resolves and is what the author should write instead.
      (let ((qualified (getf classified :qualified)))
        (when qualified
          (format t "~&~d qualified reference~:p naming a file no watched ~
repository has:~%" (length qualified))
          (dolist (entry qualified)
            (format t "  ~a -> ~a~@[  (~a still resolves)~]~%"
                    (getf entry :document) (getf entry :reference)
                    (let ((bare (getf entry :bare)))
                      (when (and bare (repositories-holding bare)) bare)))))))
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
    ;; DES-0053 D6. Its own heading, after the document references: a call
    ;; through an import whose module is here and no longer holds the name it
    ;; calls. The other causes of an unresolved import call are counted gaps and
    ;; are not reported, since a library or a missing domain is not an error.
    (let ((missing (missing-imported-calls graph)))
      (when missing
        (format t "~&~d imported call~:p naming something the module no longer holds:~%"
                (length missing))
        (dolist (entry missing)
          ;; A specifier ending in a dot takes no second one, as PY-DOTTED
          ;; writes it: `.' and (dates) read `.dates', not the two-level climb
          ;; `..dates'.
          (let ((specifier (getf entry :specifier)))
            (format t "  ~a  [~a:~a]  ~a~:[.~;~]~{~a~^.~}~%"
                    (getf entry :caller) (getf entry :file) (getf entry :line)
                    specifier (char= #\. (char specifier (1- (length specifier))))
                    (getf entry :path))))))
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
    (dolist (entry (recent-log n))
      (destructuring-bind (at label text) entry
        (multiple-value-bind (second minute hour) (decode-universal-time at)
          (format t "~&~2,'0d:~2,'0d:~2,'0d ~a ~a~%" hour minute second label text))))))

(defun context-log-record-count ()
  "How many records the log directory holds, or NIL when there is no directory."
  (let ((directory *context-log-directory*))
    (when (and directory (probe-file directory))
      (length (directory (merge-pathnames "*.json" directory))))))

(defun print-context-log-state ()
  "Where context records are being written, or that they are not."
  ;; A record is written on another thread, so a count taken without draining
  ;; misses the call the operator just made -- and on the first one it misses
  ;; the directory too, which had not been created yet.
  (drain-context-log)
  (if *context-log-directory*
      ;; PROBE-FILE for the name, because DEFAULT-CONTEXT-LOG-DIRECTORY builds
      ;; its pathname with a `../../' in it and an operator reading the line
      ;; wants the directory rather than the arithmetic. An unmade directory
      ;; probes to NIL and prints as it was written.
      (format t "~&context-log : on -> ~a~@[ (~d record~:p)~]~%"
              (namestring (or (probe-file *context-log-directory*)
                              *context-log-directory*))
              (context-log-record-count))
      (format t "~&context-log : off. No `context' call is recorded.~%"))
  (when *context-log-failure*
    (format t "  last write failure: ~a~%" *context-log-failure*)))

(define-command context-log (&optional switch directory)
    "context-log [on [<dir>] | off]"
    "Whether `context' calls are recorded, and where. No argument reports."
  ;; The operator's switch, at the console rather than in the environment.
  ;; DES-0030 D1 kept it off the request path -- no operation takes the
  ;; directory as an argument, so a caller cannot turn a :READ into a write --
  ;; and the command table is stdin's, which is the same operator who set
  ;; LOOM_CONTEXT_LOG before starting the process. MAIN reads that variable once
  ;; at startup (REQ-0036 R9); this changes the same place afterwards, so a
  ;; session that wants records for the next few questions does not restart.
  (cond ((null switch)
         (print-context-log-state))
        ((string-equal switch "on")
         (setf *context-log-directory*
               (if (and directory (plusp (length directory)))
                   (uiop:ensure-directory-pathname directory)
                   (default-context-log-directory)))
         (log-event "context-log" "on ~a" (namestring *context-log-directory*))
         (print-context-log-state))
        ((string-equal switch "off")
         ;; Drained before the switch, not after: a record already in flight is
         ;; one the agent asked for, and its writer thread reads
         ;; *CONTEXT-LOG-DIRECTORY* to place the file.
         (drain-context-log)
         (setf *context-log-directory* nil)
         (log-event "context-log" "off")
         (print-context-log-state))
        (t (format t "~&Usage: context-log [on [<dir>] | off]~%"))))

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
                     ;; PLAN-0050 S12. The token may name a domain of a
                     ;; repository as well as a repository. SPLIT-DESIGNATOR
                     ;; decides which, and it looks the whole token up before
                     ;; splitting so a path designator keeps working.
                     ;;
                     ;; Bound for this command's dynamic extent and no longer.
                     (multiple-value-bind (watched domain)
                         (if repository
                             (split-designator repository)
                             (values nil nil))
                       (declare (ignore watched))
                       (let ((*command-repository* repository)
                             (*command-domain* domain))
                         (apply (command-handler command) arguments)))
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
  (install-debugger-hook :prefix "loom" :on-unwind #'abort)
  ;; REQ-0036 R9, DES-0030 D1. The operator's switch, read once at startup:
  ;; LOOM_CONTEXT_LOG names a directory, or is any non-empty value to mean
  ;; <loom>/.loom/context/. Unset -- the default -- and nothing here writes
  ;; anything, which is what keeps :CONTEXT a read for every deployment that
  ;; did not ask otherwise.
  (configure-context-log-from-environment)
  (format t "~&Loom -- engineering knowledge graph. Type help.~%")
  (dolist (path arguments)
    (handler-case (run-command (format nil "watch ~s" path))
      (error (condition) (format t "~&~a~%" condition))))
  (console)
  ;; A record is written on another thread (REQ-0036 R8), and a console process
  ;; that exited immediately would lose the last one. Waited for here rather
  ;; than after each command, which is where waiting would cost the reader.
  (drain-context-log)
  (dolist (repository (all-repositories)) (stop-monitor repository))
  (format t "~&Paused ~d repositor~:@p; indexes kept.~%" (length (all-repositories)))
  (values))
