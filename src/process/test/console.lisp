;;;
;;; Tests for src/process/console.lisp -- the command loop of SS3.2.
;;;
;;; Parsing and dispatch only. What the commands print is exercised by driving
;;; the real thing (level 2); what is worth unit-testing is that a line becomes
;;; the right call, and that a bad line becomes a message rather than a
;;; debugger prompt.
;;;

(in-package :loom-process-test)

(def-suite console
  :in all-tests
  :description "Command-line splitting, the command table, and error containment.")

(in-suite console)

;;; ------------------------------------------------------------------
;;; Splitting (SS3.2: "deliberately not the Lisp reader")
;;; ------------------------------------------------------------------

(test a-plain-line-splits-on-whitespace
  (is (equal '("impact" "resolve-calls")
             (loom-process::split-command-line "impact resolve-calls")))
  (is (equal '("status") (loom-process::split-command-line "  status  ")))
  (is (null (loom-process::split-command-line "   "))))

(test quotes-group-and-nothing-else-does
  ;; The reason quotes exist is Windows paths, so a backslash inside them has
  ;; to be a backslash and not an escape.
  (is (equal '("watch" "C:\\src\\my project")
             (loom-process::split-command-line "watch \"C:\\src\\my project\"")))
  (is (equal '("watch" "/home/b/lisp/Loom")
             (loom-process::split-command-line "watch \"/home/b/lisp/Loom\""))))

(test an-empty-quoted-argument-survives
  ;; Without this an empty string collapses and the argument count shifts,
  ;; which turns a clear error into a wrong call.
  (is (equal '("find" "") (loom-process::split-command-line "find \"\""))))

(test a-trailing-quote-does-not-lose-the-argument
  (is (equal '("context" "make the analyzer emit ops")
             (loom-process::split-command-line "context \"make the analyzer emit ops\""))))

;;; ------------------------------------------------------------------
;;; The command table
;;; ------------------------------------------------------------------

(test every-documented-command-is-registered
  ;; SS3.2's table, minus the two that need the HTTP listener.
  (dolist (name '("watch" "unwatch" "status" "reindex" "impact" "check"
                  "log" "repl" "stop" "help" "find" "describe" "context" "rules"
                  "enrich"))
    (is (not (null (loom-process::find-command name)))
        "~a must be a command" name)))

(test every-command-documents-itself
  ;; The table is what HELP prints, so a blank usage line is a visible bug.
  (dolist (command *commands*)
    (is (plusp (length (command-usage command)))
        "~a has no usage line" (command-name command))
    (is (plusp (length (command-summary command)))
        "~a has no summary" (command-name command))))

(test defining-a-command-twice-replaces-it
  ;; Redefining a command in a live image is the point of being in Lisp; two
  ;; entries with the same name would make dispatch depend on table order.
  (let ((before (length *commands*)))
    (define-command help (&optional name) "help [command]" "replaced"
      (declare (ignore name)))
    (is (= before (length *commands*)))
    (is (string= "replaced" (command-summary (loom-process::find-command "help"))))))

;;; ------------------------------------------------------------------
;;; Error containment (SS3.3)
;;; ------------------------------------------------------------------

(test an-unknown-command-is-a-message-not-a-condition
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "frobnicate everything"))))
    (is (search "Unknown command" output))))

(test a-command-that-signals-prints-and-continues
  ;; No repository is watched, so this one has nothing to act on. The
  ;; developer should be told, and the loop should still be running.
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "find alpha"))))
    (is (search "Nothing is being watched" output))))

(test a-blank-line-does-nothing
  (is (string= "" (with-output-to-string (*standard-output*)
                    (run-command "")))))

(test a-numeric-argument-that-is-not-a-number-names-itself
  ;; REV-0001 finding 4: `impact <name> abc' printed "The value NIL is not of
  ;; type REAL", because parse-integer :junk-allowed returns NIL instead of
  ;; signalling and the NIL reached MIN. The message names neither the command
  ;; nor the argument, which is the whole of what the developer needs.
  (is (= 3 (loom-process::resolve-count "3" "depth")))
  (is (= 0 (loom-process::resolve-count "0" "depth")))
  (dolist (bad '("abc" "" "-1" "3x" "1.5"))
    (let ((condition (handler-case (progn (loom-process::resolve-count bad "depth") nil)
                       (error (c) c))))
      (is-true condition "resolve-count accepted ~s" bad)
      (when condition
        (let ((text (princ-to-string condition)))
          (is (search "depth" text) "~s: message does not name the argument" bad)
          (is (search (prin1-to-string bad) text)
              "~s: message does not quote what was typed" bad))))))

(test an-unparseable-count-is-refused-rather-than-defaulted
  ;; The same parse in `log' failed the other way: the NIL was swallowed by an
  ;; OR, so a typo silently printed the default twenty as though it had been
  ;; asked for. Quietly doing something else is worse than a message.
  (let* ((*log* '())
         (output (progn (log-event "test" "an event")
                        (with-output-to-string (*standard-output*)
                          (run-command "log abc")))))
    (is (search "non-negative integer" output))
    (is-false (search "an event" output)
              "log ran with a defaulted count instead of refusing")))

(test a-failed-command-is-logged
  (let ((*log* '()))
    (with-output-to-string (*standard-output*) (run-command "impact whatever"))
    (is (= 1 (length *log*)))
    (is (string= "error" (second (first *log*))))))

;;; ------------------------------------------------------------------
;;; The context log switch
;;; ------------------------------------------------------------------

(test context-log-reports-what-it-is-not-doing
  ;; The log is off unless an operator turns it on (DES-0030 D1), and an
  ;; operator who sees no records needs the command to say which of the two
  ;; reasons applies. Silence is the state this reports on.
  (let ((loom-workspace:*context-log-directory* nil)
        (loom-workspace:*context-log-failure* nil))
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "context-log"))))
      (is (search "off" output)))))

(test context-log-on-and-off-move-the-directory
  (let ((loom-workspace:*context-log-directory* nil)
        (loom-workspace:*context-log-failure* nil)
        (*log* '()))
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "context-log on /tmp/loom-console-test-log"))))
      (is (equal (uiop:ensure-directory-pathname "/tmp/loom-console-test-log")
                 loom-workspace:*context-log-directory*))
      (is (search "/tmp/loom-console-test-log" output)))
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "context-log off"))))
      (is (null loom-workspace:*context-log-directory*))
      (is (search "off" output)))))

(test context-log-on-with-no-directory-takes-the-default
  (let ((loom-workspace:*context-log-directory* nil)
        (loom-workspace:*context-log-failure* nil)
        (*log* '()))
    (with-output-to-string (*standard-output*) (run-command "context-log on"))
    (is (equal (loom-workspace:default-context-log-directory)
               loom-workspace:*context-log-directory*))))

(test an-unrecognised-context-log-argument-changes-nothing
  ;; A typo that turned the log off would lose the records the operator
  ;; believes they are collecting, which is the failure no later count reveals.
  (let ((loom-workspace:*context-log-directory*
          (uiop:ensure-directory-pathname "/tmp/loom-console-test-log"))
        (loom-workspace:*context-log-failure* nil))
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "context-log maybe"))))
      (is (search "Usage" output))
      (is (equal (uiop:ensure-directory-pathname "/tmp/loom-console-test-log")
                 loom-workspace:*context-log-directory*)))))

;;; ------------------------------------------------------------------
;;; Logging
;;; ------------------------------------------------------------------

(test the-log-is-bounded
  ;; It is a console convenience, not a durable record -- under files-as-truth
  ;; nothing recovers from it, so it must not grow without limit.
  (let ((*log* '()))
    (dotimes (i (+ loom-process::*log-limit* 50))
      (log-event "test" "event ~d" i))
    (is (= loom-process::*log-limit* (length *log*)))
    (is (search (format nil "event ~d" (+ loom-process::*log-limit* 49))
                (third (first *log*)))
        "and it keeps the newest, not the oldest")))

;;; ------------------------------------------------------------------
;;; What `describe' prints (DES-0005)
;;;
;;; These are at the END of the file deliberately: FiveAM runs a suite in
;;; definition order, and a-command-that-signals-prints-and-continues asserts
;;; the output contains "Nothing is being watched". A fixture that leaked a
;;; watched repository would turn that test red rather than these, so the
;;; UNWIND-PROTECT below is what keeps the failure legible.
;;;
;;; Every name from loom-workspace is qualified: this package :uses only :cl,
;;; :fiveam and :loom-process.
;;; ------------------------------------------------------------------

(defvar *console-fixture-root* nil)

(defun write-console-fixture-file (relative contents)
  (let ((path (merge-pathnames relative *console-fixture-root*)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    path))

(defun make-console-fixture-repository ()
  "One source file and two documents, in a fresh temp directory.
Modelled on src/workspace/test/workspace.lisp, which is the working copy of
this pattern. Each document carries a sentinel phrase in a field `describe'
must NOT print, so the negative assertions below cannot pass by accident."
  (setf *console-fixture-root*
        (merge-pathnames (format nil "loom-console-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *console-fixture-root*)
  ;; Not src/alpha.lisp: SIGNIFICANT-NAME strips a file's directory and
  ;; extension, so a file of that name would answer to `describe alpha' too and
  ;; the code-entity test would be describing the file it meant to exclude.
  ;; FROBNICATE is defined nowhere and is deliberate: it is the only way this
  ;; fixture exercises :UNRESOLVED-CALLS, which is the record that a definition
  ;; calls a name no definition in the tree answers (REQ-0055). The arithmetic
  ;; is unchanged, and the Lisp analyzer does not record `+' as a call name, so
  ;; without a foreign callee the property is always empty here.
  (write-console-fixture-file "src/code.lisp" "(defun alpha (x) (frobnicate (+ x 1)))
")
  (write-console-fixture-file "docs/decisions/DEC-0001.yaml"
                              "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
rationale: |
  Keeping alpha free of side effects makes it testable.
consequences: |
  Zarquon is what nobody should be reading here.
")
  (write-console-fixture-file "docs/design/DES-0001.yaml"
                              "id: DES-0001
type: document
title: The shape of alpha
status: implemented
summary: |
  Arithmetic only, checked at the boundary.
body: |
  Blimflark is the body nobody asked for.
")
  (loom-workspace:watch-repository *console-fixture-root* :monitor nil :quiet t))

(defmacro with-console-fixture (&body body)
  ;; No variable is bound for the repository: every test here reaches it
  ;; through RUN-COMMAND, which finds the watched one for itself, and the
  ;; cleanup is the only thing that needs the handle.
  `(let ((repository (make-console-fixture-repository)))
     (unwind-protect (progn ,@body)
       (loom-workspace:unwatch-repository (loom-workspace:repository-name repository))
       (ignore-errors (uiop:delete-directory-tree *console-fixture-root* :validate t))
       (setf *console-fixture-root* nil))))

(test describe-of-a-document-summarises-instead-of-reprinting-it
  ;; The negative is the witness: before this, :BODY printed in full and the
  ;; sentinel was in it, however long the document was.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "describe DES-0001"))))
      (is (search "The shape of alpha" output))
      (is (search "implemented" output)
          "and the status is printed, which needed the vocabulary widening
before an already-landed document had one to print")
      (is (search "Arithmetic only" output))
      (is-false (search "Blimflark" output)
                "the body is no longer dumped"))))

(test describe-of-a-decision-labels-the-field-it-fell-back-to
  ;; Also the fix for the rationale-printed-twice defect: today it appears
  ;; once under its own key and once inside :BODY.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "describe DEC-0001"))))
      (is (search "via rationale" output)
          "an unlabelled fallback is indistinguishable from an author's own
summary, which is the fabrication CON-0001 forbids")
      (is (search "free of side effects" output))
      (is-false (search "Zarquon" output)))))

(test describe-says-when-it-cut-something
  ;; Rebinding the budget beats writing a 500-word fixture summary, and tests
  ;; the boundary the console is what reports.
  (with-console-fixture
    ;; 4 tokens is ~16 characters by ESTIMATE-TOKENS' four-to-the-token, which
    ;; lands mid-way through the fixture summary's second word and so backs off
    ;; to leave the first one whole. A budget of 2 cuts inside the first word,
    ;; where there is no preceding whitespace to back off to.
    (let ((output (let ((loom-knowledge:*summary-token-budget* 4))
                    (with-output-to-string (*standard-output*)
                      (run-command "describe DES-0001")))))
      (is (search "truncated" output))
      (is (search "Arithmetic" output)
          "the head of the summary is still printed: a truncated summary that
prints no summary at all passes every negative assertion, and that is how the
misused conditional directive hid, printing the flag itself as the text")
      (is-false (search "checked at the boundary" output)
                "and the tail was actually cut, not merely labelled"))))

(test describe-of-a-function-is-unchanged
  ;; REQ-0007's not-a-regression line as a guard. Passes before and after --
  ;; deliberately not this step's CON-0003 evidence.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "describe alpha"))))
      (is-false (search "title:" output))
      (is-false (search "summary" output))
      (is (search "function alpha" output)
          "the first line is PRINT-SUMMARY-LINE's form, as it is today"))))

(test a-neighbour-line-marks-an-edge-the-resolver-guessed-at
  ;; BUG-0055. NEIGHBOR-LINE is unit-tested rather than driven through a
  ;; console fixture because the fixture is a Lisp tree with no member calls in
  ;; it: producing a real inferred edge would mean writing a JavaScript file
  ;; and a live node, and what is being tested is the printing.
  (is (string= "ingestPartition"
               (loom-process::neighbor-line
                (list :name "ingestPartition" :edge-source :structural
                      :edge-confidence 1.0)))
      "a resolved edge prints the name and nothing else")
  (is (string= "BiMap.get (inferred 0.33)"
               (loom-process::neighbor-line
                (list :name "BiMap.get" :edge-source :inferred
                      :edge-confidence 0.3333)))
      "and a guess says how much of one it is")
  ;; Both annotations, which is the case DES-0014's call sites make reachable:
  ;; an ambiguous site fanned out is a call site AND an inferred edge.
  (is (string= "alpha@src/x.lisp:9 (ambiguous, inferred 0.50)"
               (loom-process::neighbor-line
                (list :name "alpha@src/x.lisp:9" :referrer-kind :ambiguous
                      :edge-source :inferred :edge-confidence 0.5))))
  (is (string= "alpha (definer-call)"
               (loom-process::neighbor-line
                (list :name "alpha" :referrer-kind :definer-call
                      :edge-source :structural :edge-confidence 1.0)))
      "DES-0014 R7's kind still prints on its own"))

(test describe-shows-the-names-that-reached-nothing
  ;; REQ-0055, and the opposite of what it asked for. :UNRESOLVED-CALLS is
  ;; written by one line of RESOLVE-CALLS, read by no pass and printed by
  ;; nothing, which is why it read as leftover bookkeeping -- and it is the only
  ;; record that a definition calls a name no definition in the tree answers.
  ;; BUG-0055 used exactly that record as its evidence for the defect it fixed.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "describe alpha"))))
      (is (search "external:" output)
          "alpha calls +, which this tree does not define: ~a" output)))
  ;; The control: a definition every one of whose calls resolved prints no such
  ;; band, so the line means something when it is there.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "describe DEC-0001"))))
      (is-false (search "external:" output)
                "a document calls nothing and must not carry an empty band"))))

(test an-impact-row-prints-the-location-that-tells-two-of-one-name-apart
  ;; BUG-0050 F1. The REST answer has carried `location' throughout and the
  ;; console printed neither it nor the id, so eight methods of one generic
  ;; printed as `d2 method dhandler-copy' eight times with nothing on them
  ;; saying which. `find' and `describe' both print it, in the bracket form
  ;; asserted here.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "impact alpha"))))
      (is (search "src/code.lisp" output)
          "the row locates its definition: ~a" output)
      (is (search "[src/code.lisp" output)
          "in PRINT-SUMMARY-LINE's bracket form, so the three commands agree"))))

(test a-file-row-does-not-print-its-own-path-twice
  ;; A :FILE entity is named by its path and locates to the same path. The
  ;; bracket is what made a method row legible; on a file row it repeats the
  ;; name and spends the width that bought the legibility.
  (with-console-fixture
    (let* ((output (with-output-to-string (*standard-output*)
                     (run-command "impact alpha")))
           (file-line (find-if (lambda (line) (search " file " line))
                               (uiop:split-string output :separator '(#\Newline)))))
      (is-true file-line "the file containing alpha is impacted by it")
      (when file-line
        (is-false (search "[src/code.lisp]" file-line)
                  "and does not repeat itself: ~a" file-line)))))

;;; ------------------------------------------------------------------
;;; enrich (DES-0011)
;;; ------------------------------------------------------------------
;;;
;;; Driven against the real registered LISP-INSPECTOR rather than a stub, and
;;; no child process is spawned by either test: the console fixture is a
;;; directory with no .asd file in it, so INSPECTOR-AVAILABLE-P answers NIL
;;; before anything is run. That makes REQ-0018 R2's recorded absence the case
;;; the console is tested on, which is the one a developer pointing Loom at an
;;; arbitrary tree will actually meet.

(test enrich-reports-a-recorded-absence-rather-than-failing
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "enrich"))))
      (is (search "absent" output))
      (is (search "no .asd files" output)
          "the reason, not merely the fact: \"no\" alone is unactionable")
      (is (search "0 added" output)
          "the zeros print, or a pass that did nothing looks like no pass")
      (is (search "enrichment :" output)
          "and status carries the run forward"))))

(test status-says-never-run-before-any-enrichment
  ;; Three zeroes would read as "the image agreed with everything", which is
  ;; the one thing a tree nobody has enriched has not been shown to be.
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "status"))))
      (is (search "enrichment : never run" output)))))

(test enrich-on-a-repository-that-is-not-watched-says-so
  (with-console-fixture
    (let ((output (with-output-to-string (*standard-output*)
                    (run-command "enrich no-such-repository"))))
      (is (search "no-such-repository" output)
          "the message CURRENT-REPOSITORY already produces, unchanged"))))

;;; ------------------------------------------------------------------
;;; Naming a repository (REQ-0023, DES-0021)
;;;
;;; A second fixture repository, because everything above runs against one and
;;; the whole point of this mechanism only exists when two are watched. Built
;;; beside the first rather than replacing it, so the single-repository tests
;;; keep testing the case they were written for -- that case is the one
;;; DES-0021 promises is unchanged, and a guard whose fixture moved guards
;;; nothing.
;;; ------------------------------------------------------------------

(defvar *second-fixture-root* nil)

(defun make-second-fixture-repository ()
  "A second repository with a differently-named definition in it.
The name is what the tests key on: asking for `beta' can only be answered by
this repository, so an answer proves which graph was consulted."
  (setf *second-fixture-root*
        (merge-pathnames (format nil "loom-console2-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *second-fixture-root*)
  (let ((path (merge-pathnames "src/other.lisp" *second-fixture-root*)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string "(defun beta (x) (* x 2))
" out)))
  (loom-workspace:watch-repository *second-fixture-root* :monitor nil :quiet t))

(defmacro with-two-console-fixtures (&body body)
  `(let ((first-repository (make-console-fixture-repository)))
     (unwind-protect
          (let ((second-repository (make-second-fixture-repository)))
            (unwind-protect (progn ,@body)
              (loom-workspace:unwatch-repository
               (loom-workspace:repository-name second-repository))
              (ignore-errors (uiop:delete-directory-tree *second-fixture-root*
                                                        :validate t))
              (setf *second-fixture-root* nil)))
       (loom-workspace:unwatch-repository
        (loom-workspace:repository-name first-repository))
       (ignore-errors (uiop:delete-directory-tree *console-fixture-root* :validate t))
       (setf *console-fixture-root* nil))))

(defun run-to-string (line)
  (with-output-to-string (*standard-output*) (run-command line)))

(test with-two-watched-a-query-refuses-and-says-how-to-ask
  ;; The refusal is correct -- answering from an arbitrary repository would be
  ;; CON-0001's fabricated fact -- but it has to name the mechanism. The old
  ;; message said "name one" and gave no way to, so a developer ran `status'
  ;; first and then the command they meant.
  ;; `describe' rather than `find' since REQ-0051: `find' with no designator
  ;; now searches every watched tree, because the question it answers is which
  ;; of them owns a name. The refusal is still correct for every command whose
  ;; answer is about one entity, and `describe' is the exemplar.
  (with-two-console-fixtures
    (let ((output (run-to-string "describe alpha")))
      (is (search "Several repositories are watched" output))
      (is (search "@" output)
          "the refusal names the mechanism, not just the problem: ~s" output))))

(test find-with-no-token-searches-every-watched-repository
  ;; REQ-0051 R1 and R2, on the surface the measurement was taken through. Both
  ;; fixtures define ALPHA; before this the command refused and the answer was
  ;; four grep calls.
  (with-two-console-fixtures
    (let ((first-name (loom-workspace:repository-name first-repository))
          (second-name (loom-workspace:repository-name second-repository)))
      (let ((output (run-to-string "find alpha")))
        (is (not (search "Several repositories" output))
            "the refusal is gone: ~s" output)
        (is (search (format nil "@~a" first-name) output)
            "the first tree's row names its tree")
        (is (search "searched 2 repositories" output)
            "and the cost is reported, because it was not one tree (R5)"))
      ;; R5's other half: naming one tree must still cost one tree.
      (let ((output (run-to-string (format nil "find @~a alpha" second-name))))
        (is (not (search "searched 2 repositories" output))
            "naming a repository searches only it: ~s" output)))))

(test a-leading-token-names-the-repository-a-command-acts-on
  ;; DES-0021 D1. `find' has no designator argument and gets one anyway,
  ;; because the strip happens in the dispatcher rather than in the command.
  (with-two-console-fixtures
    (let ((first-name (loom-workspace:repository-name first-repository))
          (second-name (loom-workspace:repository-name second-repository)))
      (let ((output (run-to-string (format nil "find alpha @~a" first-name))))
        ;; Since REQ-0051 the witness is the cost line rather than a refusal: a
        ;; trailing token is read as `find''s type argument and leaves the
        ;; command with no designator, so it searches every tree. A stripped
        ;; token would have scoped it to one.
        (is (search "searched 2 repositories" output)
            "a trailing token is not a designator -- only a leading one is"))
      (let ((output (run-to-string (format nil "find @~a alpha" first-name))))
        (is (search "alpha" output))
        (is (not (search "searched 2 repositories" output))))
      (let ((output (run-to-string (format nil "find @~a beta" second-name))))
        (is (search "beta" output)
            "and the second repository answers for its own definition")))))

(test the-token-works-on-a-variadic-command
  ;; The case a per-command designator argument could not have solved, and the
  ;; reason the strip lives in the dispatcher: `context' takes the task's words,
  ;; so a trailing designator is indistinguishable from another word.
  (with-two-console-fixtures
    (let ((second-name (loom-workspace:repository-name second-repository)))
      (let ((output (run-to-string (format nil "context @~a beta" second-name))))
        (is (search "beta" output))
        (is (not (search "Several repositories" output)))))))

(test an-explicit-designator-argument-beats-the-token
  ;; DES-0021 D2's precedence, and the assertion most likely to be written to
  ;; match whatever the code does. A caller who typed a designator in the
  ;; position a command declares for one meant it; a token earlier on the line
  ;; must not silently override it.
  (with-two-console-fixtures
    (let ((first-name (loom-workspace:repository-name first-repository))
          (second-name (loom-workspace:repository-name second-repository)))
      (let ((output (run-to-string (format nil "status @~a ~a" second-name first-name))))
        (is (search first-name output)
            "the explicit argument won: ~s" output)
        (is (not (search second-name output))
            "and the token did not override it")))))

(test the-token-does-not-outlive-the-command-that-carried-it
  ;; REQ-0023 R1a, and the reason a `use <repository>' mode was rejected. A
  ;; selection that survives its command answers a later query about the wrong
  ;; tree with nothing in the question saying so.
  ;; The witness moved with REQ-0051 and the property did not. A token that
  ;; outlived its command would scope the next `find' to one tree; a `find' that
  ;; starts with no repository selected searches every one and says so.
  (with-two-console-fixtures
    (let ((second-name (loom-workspace:repository-name second-repository)))
      (run-to-string (format nil "find @~a beta" second-name))
      (let ((output (run-to-string "find beta")))
        (is (search "searched 2 repositories" output)
            "the next command starts with no repository selected: ~s" output)))))

(test naming-a-repository-that-is-not-watched-says-what-is
  (with-two-console-fixtures
    (let ((output (run-to-string "find @no-such-repository alpha")))
      (is (search "no-such-repository" output))
      (is (search "Watching:" output)
          "the message lists what is watched rather than only what is not"))))

(test a-repository-token-in-the-wrong-position-says-where-it-goes
  ;; DES-0021 D1 strips a *leading* @token, and a caller who writes it after
  ;; another argument gets it as a positional designator instead. "No repository
  ;; named @gs2" is true and one word short of useful; found by writing
  ;; `remove tooling @gs2' and having to work out why.
  (with-two-console-fixtures
    (let* ((second-name (loom-workspace:repository-name second-repository))
           (output (run-to-string (format nil "check ~a" second-name))))
      (is (not (search "has to come first" output))
          "a bare designator in that position is fine and must not be corrected"))
    (let ((output (run-to-string (format nil "check @~a"
                                         (loom-workspace:repository-name
                                          second-repository)))))
      ;; `check' takes a designator, so a leading token is stripped before the
      ;; handler sees it and this is the ordinary success path.
      (is (not (search "has to come first" output))))
    (let ((output (run-to-string "set-status DOC status @somewhere")))
      (is (search "has to come first" output)
          "a token in a later position is told where it goes: ~s" output))))

;;; ------------------------------------------------------------------
;;; The imports line (PLAN-0050 S9)
;;; ------------------------------------------------------------------
