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
;;; What `describe' prints (ARCH-0005)
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
  (write-console-fixture-file "src/code.lisp" "(defun alpha (x) (+ x 1))
")
  (write-console-fixture-file "docs/design/DEC-0001.yaml"
                              "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
rationale: |
  Keeping alpha free of side effects makes it testable.
consequences: |
  Zarquon is what nobody should be reading here.
")
  (write-console-fixture-file "docs/arch/ARCH-0001.yaml"
                              "id: ARCH-0001
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
                    (run-command "describe ARCH-0001"))))
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
                      (run-command "describe ARCH-0001")))))
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

;;; ------------------------------------------------------------------
;;; enrich (ARCH-0011)
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
