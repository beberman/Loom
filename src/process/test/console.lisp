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

(test check-reports-an-imported-call-whose-module-no-longer-holds-the-name
  ;; DES-0053 D6. The heading is absent on a tree with nothing missing and
  ;; present, naming the call, when RESOLVE-CALLS recorded a
  ;; :MISSING-IN-TARGET. The other causes are counted gaps and print nothing.
  (with-console-fixture
    (is (not (search "imported call" (run-to-string "check")))
        "a tree with no Python prints no such heading")
    (loom-graph:add-entity
     (loom-workspace:repository-graph repository)
     (make-instance 'loom-ontology:function-entity :name "run"
                    :origin-file "app/main.py"
                    :properties (loom-ontology:properties-table
                                 (list :file "app/main.py" :start-line 1 :end-line 4
                                       :language :python
                                       :unresolved-imported-calls
                                       '((:specifier "sheets" :path ("upsert_tab")
                                          :line 7 :cause :missing-in-target)
                                         (:specifier "pytest" :path ("raises")
                                          :line 9 :cause :external)
                                         (:specifier "." :path ("dates")
                                          :line 11 :cause :missing-in-target))))))
    (let ((output (run-to-string "check")))
      (is (search "2 imported calls naming something the module no longer holds" output)
          "~s" output)
      (is (search "sheets.upsert_tab" output))
      ;; REV-0003 item 10: the specifier `.' already ends in a dot.
      (is (search "]  .dates" output) "~s" output)
      (is (not (search "..dates" output)) "which is not a two-level climb")
      (is (not (search "pytest" output)) "an external library is not an error"))))

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

;;; ------------------------------------------------------------------
;;; A domain in the @token (PLAN-0050 S12)
;;; ------------------------------------------------------------------

(test a-token-with-no-slash-names-a-repository-and-binds-no-domain
  ;; The ordinary case, and the one that must not change. Nothing is watched
  ;; here, so the command refuses -- what is asserted is that it refuses as an
  ;; unknown repository rather than as an unknown domain.
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "find @nosuchrepo alpha"))))
    (is-true (or (search "No repository named" output)
                 (search "Nothing is being watched" output))
             "~a" output)
    (is (not (search "declares no domain" output))
        "a token with no slash is not read as a domain")))

(test the-domain-token-does-not-outlive-its-command
  ;; *COMMAND-DOMAIN* is bound for one command's dynamic extent, for the reason
  ;; *COMMAND-REPOSITORY* is: a session that remembered a selection would answer
  ;; a later query about the wrong part of the tree with nothing saying so.
  (run-command "find @nosuchrepo alpha")
  (is (null loom-process::*command-domain*)
      "the binding is gone once the command returns"))

(test an-index-command-refuses-a-domain-token
  ;; A domain partitions an index rather than being one, so there is nothing
  ;; `reindex @repo/domain' could mean that is not a lie.
  (let ((loom-process::*command-domain* (list :name :server)))
    (let ((output (with-output-to-string (*standard-output*)
                    (handler-case (loom-process::refuse-domain "reindex")
                      (error (e) (format t "~a" e))))))
      (is-true (search "reindex" output) "~a" output)
      (is-true (search "server" output) "it names the domain that was given")
      (is-true (search "partitions an index" output)
               "and says why, rather than only refusing"))))

(test no-domain-token-means-no-filter
  ;; The filter is NIL rather than an empty one, so a command that names no
  ;; domain takes the query path it has always taken.
  ;;
  ;; DOMAIN-PROPERTY-FILTER is loom-workspace's. It was written twice, once
  ;; here and once in loom-serve, and the call-site census caught that: two
  ;; same-named functions in two packages made every call to the name
  ;; ambiguous, and the ambiguous population went from 20 to 21.
  (is (null (loom-workspace:domain-property-filter nil)))
  (is (equal (list :domain :server) (loom-workspace:domain-property-filter (list :name :server)))
      "and a keyword, because :DOMAIN is one"))

;;; ------------------------------------------------------------------
;;; The family flag (PLAN-0054 S3)
;;; ------------------------------------------------------------------

(test the-family-flag-is-stripped-from-wherever-it-is-written
  ;; Both orders are what somebody types and neither is wrong, so the flag is
  ;; found anywhere and the term is read from what is left. A flag mistaken for
  ;; the term would search for "--code".
  (multiple-value-bind (kind rest) (loom-process::kind-flag '("repository" "--code"))
    (is (eq :code kind))
    (is (equal '("repository") rest)))
  (multiple-value-bind (kind rest) (loom-process::kind-flag '("--doc" "repository"))
    (is (eq :documentation kind))
    (is (equal '("repository") rest)))
  (multiple-value-bind (kind rest)
      (loom-process::kind-flag '("repository" "--documentation" "class"))
    (is (eq :documentation kind))
    (is (equal '("repository" "class") rest)
        "the type positional survives with the flag between the two")))

(test no-flag-is-no-family
  (multiple-value-bind (kind rest) (loom-process::kind-flag '("repository"))
    (is (null kind))
    (is (equal '("repository") rest))))

(test find-with-no-name-says-what-to-type
  ;; The lambda list is &rest now, so a bare `find' no longer fails on arity.
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "find"))))
    (is-true (search "find needs a name" output) "~a" output)))

;;; ------------------------------------------------------------------
;;; DES-0054 D8: entry points in find, describe, impact and status
;;; ------------------------------------------------------------------

(defun add-console-entity (repository type name file &rest properties)
  "A TYPE entity named NAME in FILE, added straight to REPOSITORY's graph."
  (let ((entity (make-instance (ecase type
                                 (:function 'loom-ontology:function-entity)
                                 (:variable 'loom-ontology:variable-entity)
                                 (:setting 'loom-ontology:setting-entity)
                                 (:file 'loom-ontology:file-entity))
                               :name name :origin-file file
                               :properties (loom-ontology:properties-table
                                            (if (eq type :setting)
                                                ;; Closed: only what it declares.
                                                (append (list :name name) properties)
                                                (append (list :file file :start-line 1
                                                              :end-line 5 :path file
                                                              :language :python)
                                                        properties))))))
    (loom-graph:add-entity (loom-workspace:repository-graph repository) entity)
    entity))

(defun add-entry-point (repository name trigger &rest properties)
  (apply #'add-console-entity repository :function name "functions/main.py"
         :trigger trigger
         :entry-point (list (list :framework "firebase-functions" :trigger trigger
                                  :options '(("schedule" . "every 1 hours")
                                             ("memory" :dotted "options.MemoryOption.MB_512"
                                              :specifier "firebase_functions"
                                              :path ("options"))
                                             ("secrets" :list (:name "K" :binding :local)))
                                  :codebase "default" :runtime "python312" :deployed :yes))
         properties))

(test find-trigger-lists-what-carries-it-and-nothing-else
  (with-console-fixture
    (add-entry-point repository "sync_zeffy" :schedule)
    (add-entry-point repository "sync_ledger" :schedule)
    (add-entry-point repository "serve_api" :https)
    (let ((output (run-to-string "find --trigger schedule")))
      (is (search "sync_zeffy" output))
      (is (search "sync_ledger" output))
      (is (not (search "serve_api" output)))
      (is (not (search "alpha" output))))
    (is (search "serve_api" (run-to-string "find --trigger https")))
    (is (not (search "sync_zeffy" (run-to-string "find sync --trigger https"))))))

(test an-unknown-trigger-finds-nothing-and-interns-no-keyword
  (with-console-fixture
    (add-entry-point repository "sync_zeffy" :schedule)
    (let ((name "ZZQXV-NO-SUCH-TRIGGER"))
      (is (null (find-symbol name :keyword)))
      (let ((output (run-to-string (format nil "find --trigger ~a" (string-downcase name)))))
        (is (search "No entity has the trigger" output))
        (is (not (search "sync_zeffy" output))))
      (is (null (find-symbol name :keyword))
          "console input does not widen the keyword package"))))

(test describe-prints-the-entry-point-and-impact-suffixes-the-row
  (with-console-fixture
    (let ((entry (add-entry-point repository "sync_zeffy" :schedule))
          (helper (add-console-entity repository :function "_sync" "functions/main.py")))
      (loom-graph:add-relationship
       (loom-workspace:repository-graph repository)
       (make-instance 'loom-ontology:relationship :rel-type :calls
                      :from-id (loom-ontology:id entry) :to-id (loom-ontology:id helper)
                      :origin-file "functions/main.py"))
      (let ((described (run-to-string "describe sync_zeffy")))
        (is (search "entry point: firebase-functions schedule" described))
        (is (search "schedule=\"every 1 hours\"" described))
        (is (search "memory=options.MemoryOption.MB_512" described)
            "a dotted value prints as its text")
        (is (search "secrets=[K]" described))
        (is (search "codebase default (python312), deployed" described)))
      (is (search "[entry: schedule]" (run-to-string "impact _sync 3"))))))

(test status-says-what-a-firebase-json-deploys-and-what-is-missing
  (with-console-fixture
    (add-console-entity repository :file "firebase.json" "firebase.json"
                        :codebases '((:source "functions" :codebase "default"
                                      :runtime "python312" :ignore nil :defaulted nil)))
    (add-console-entity repository :file ".firebaserc" ".firebaserc"
                        :project-aliases '(("default" . "lfia-accounting")))
    (add-entry-point repository "sync_zeffy" :schedule)
    (let ((without (run-to-string "status")))
      (is (search "deploys    : codebase default at functions (python312), 1 entry point" without))
      (is (search "project default=lfia-accounting" without))
      (is (search "no entry-points. `init' proposes them" without)
          "declared codebases with no declaration is a recorded gap"))
    (setf (loom-workspace::repository-frameworks
           (first (loom-workspace:all-repositories)))
          '(:entry-points ((:framework "f" :trigger :https :module "m" :names ("x")))))
    (is (not (search "proposes them" (run-to-string "status"))))))

(test status-counts-default-exported-registrations-in-covered-files-only
  ;; PLAN-0058 step 5. The count sits on the :FILE; a file outside every codebase
  ;; (a React tree's memo() default export) is not a registration anyone deploys.
  (with-console-fixture
    (add-console-entity repository :file "firebase.json" "firebase.json"
                        :codebases '((:source "functions" :codebase "default"
                                      :runtime nil :ignore nil :defaulted nil)))
    (add-console-entity repository :file "functions/hello.js" "functions/hello.js"
                        :unnamed-registrations 1)
    (add-console-entity repository :file "src/ui/Memo.js" "src/ui/Memo.js"
                        :unnamed-registrations 5)
    (let ((out (run-to-string "status")))
      (is (search "deploys    : 1 registration in a default export carries no name; a re-export decides it" out)
          "only the covered file counts: ~a" out))
    (add-console-entity repository :file "functions/other.js" "functions/other.js"
                        :unnamed-registrations 1)
    (is (search "deploys    : 2 registrations in a default export carry no name"
                (run-to-string "status")))))

(test a-zero-unnamed-registration-count-prints-no-line
  (with-console-fixture
    (add-console-entity repository :file "firebase.json" "firebase.json"
                        :codebases '((:source "functions" :codebase "default"
                                      :runtime nil :ignore nil :defaulted nil)))
    (is (not (search "default export" (run-to-string "status"))))))

(test a-tree-with-no-firebase-json-prints-no-deploys-line
  (with-console-fixture
    (is (not (search "deploys" (run-to-string "status"))))))

(test a-name-shared-by-a-setting-and-the-variable-reading-it-resolves-to-the-setting
  ;; The F3 rule of PLAN-0056, applied where a person types the name. A variable
  ;; of the same name that reads something else keeps it ambiguous.
  (with-console-fixture
    (add-console-entity repository :setting "ZEFFY_API_KEY" "functions/main.py"
                        :sources '(:secret))
    (add-console-entity repository :variable "ZEFFY_API_KEY" "functions/main.py"
                        :environment-reads '("ZEFFY_API_KEY"))
    (let ((output (run-to-string "describe ZEFFY_API_KEY")))
      (is (not (search "things are named" output)))
      (is (search "setting ZEFFY_API_KEY" output)))
    (add-console-entity repository :variable "ZEFFY_API_KEY" "functions/other.py"
                        :environment-reads '("SOMETHING_ELSE"))
    (is (search "things are named" (run-to-string "describe ZEFFY_API_KEY")))))

;;; ------------------------------------------------------------------
;;; DES-0055 R8: dependencies in status and describe
;;; ------------------------------------------------------------------

(defun status-text (&rest plist)
  (with-output-to-string (*standard-output*)
    (loom-process::print-status (append plist (list :name "t" :root "/t/" :uncategorized-documents 0
                                                       :enrichment-runs 0 :errors 0)))))

(defparameter *pypi-dependencies*
  '((:ecosystem :pypi :declared 5 :manifests 2 :unmapped 2
     :joined 4 :stdlib 1 :undeclared 1 :ambiguous 0)))

(test status-prints-a-dependencies-line-per-ecosystem
  (let ((out (status-text :dependencies *pypi-dependencies*)))
    (is (search "dependencies: pypi 5 declared in 2 manifests, 2 unmapped; imports 4 joined, 1 stdlib, 1 undeclared"
                out)
        "~a" out)))

(test status-prints-no-dependencies-line-without-the-key
  (is (not (search "dependencies" (status-text)))))

(test status-says-stdlib-unknown-when-no-import-carried-a-mark
  ;; PLAN-0059 risk 7. A zero here would read as measured.
  (let ((out (status-text :dependencies
                          (list (list :ecosystem :pypi :declared 0 :manifests 0
                                      :unmapped 0 :joined 0 :stdlib nil
                                      :undeclared 3 :ambiguous 0)))))
    (is (search "stdlib unknown" out) "~a" out)
    (is (not (search "0 stdlib" out)))))

(test status-says-when-frameworks-yaml-is-not-tracked
  (is (search ".loom/frameworks.yaml is not tracked by git"
              (status-text :dependencies *pypi-dependencies* :frameworks-untracked t)))
  (is (not (search "not tracked by git"
                   (status-text :dependencies *pypi-dependencies*)))))

(defun add-console-module (repository name &rest properties)
  (let ((module (make-instance 'loom-ontology:module-entity
                               :name name :origin-file "requirements.txt"
                               :properties (loom-ontology:properties-table
                                            (append (list :qualified-name name
                                                          :file "requirements.txt"
                                                          :ecosystem :pypi)
                                                    properties)))))
    (loom-graph:add-entity (loom-workspace:repository-graph repository) module)
    module))

(test describe-prints-a-modules-manifest-specs-and-provides
  (with-console-fixture
    (add-console-module repository "google-auth" :specs '(">=2.29")
                        :provides '("google.auth" "google.oauth2"))
    (let ((out (run-to-string "describe google-auth")))
      (is (search "dependency : pypi, declared in requirements.txt >=2.29; provides google.auth, google.oauth2"
                  out)
          "~a" out))))

(test describe-says-how-to-map-an-unmapped-module
  (with-console-fixture
    (add-console-module repository "tzdata" :specs '(">=2024.1"))
    (is (search "unmapped -- declare it under dependency-modules:"
                (run-to-string "describe tzdata")))))

;;; PLAN-0059 step 7, DES-0055 D7. `init' shows the dependency-modules: block it
;;; proposes and writes none. The scratch tree has no venv, so the entry is
;;; commented and no python3 is needed.

(defmacro with-init-tree ((root) &body body)
  `(let ((,root (ensure-directories-exist
                 (merge-pathnames (format nil "loom-console-init-~a/" (random 100000))
                                  (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun write-init-file (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string contents out))))

(test init-prints-the-dependency-proposal-and-says-it-is-not-written
  (with-init-tree (root)
    (write-init-file root "requirements.txt" "tzdata
")
    (let ((output (run-to-string (format nil "init ~s" (namestring root)))))
      (is (search "dependency-modules: proposed, not written" output) "~a" output)
      (is (search "  # - distribution: tzdata" output))
      (is (not (probe-file (merge-pathnames ".loom/frameworks.yaml" root)))))
    ;; The second run takes the already-prepared branch, which prints it too.
    (let ((output (run-to-string (format nil "init ~s" (namestring root)))))
      (is (search "is already prepared" output))
      (is (search "dependency-modules: proposed, not written" output) "~a" output))))

(test init-prints-no-dependency-heading-without-requirements
  (with-init-tree (root)
    (is (not (search "dependency-modules"
                     (run-to-string (format nil "init ~s" (namestring root))))))))
