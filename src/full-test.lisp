;;;; Run every system's test suite in one go.
;;;;
;;;;   (load "src/full-test.lisp")
;;;;   (synoptik-test:full-test)
;;;;
;;;; Each system owns its own ALL-TESTS suite and its own TEST-RUNNER, so this
;;;; is a driver and not a suite: it loads each test system, calls its runner,
;;;; and reports which ones passed. A system that fails to load is reported and
;;;; skipped rather than stopping the run, because the common reason to run
;;;; this is that something is broken and the useful answer is how much.

(defpackage #:synoptik-test
  (:use #:cl)
  (:export #:full-test))

(in-package :synoptik-test)

(defparameter *test-systems*
  '((:synoptik-utils/test     . "SYNOPTIK-UTILS-TEST")
    (:synoptik-embed/test     . "SYNOPTIK-EMBED-TEST")
    (:synoptik-docstore/test  . "SYNOPTIK-DOCSTORE-TEST")
    (:synoptik-ontology/test  . "ROOT-ONTOLOGY-TEST")
    (:synoptik-analyzer/test  . "SYNOPTIK-ANALYZER-TEST")
    (:synoptik-graph/test     . "SYNOPTIK-GRAPH-TEST")
    (:synoptik-workspace/test . "SYNOPTIK-WORKSPACE-TEST")
    (:synoptik-knowledge/test . "SYNOPTIK-KNOWLEDGE-TEST")
    (:synoptik-process/test   . "SYNOPTIK-PROCESS-TEST")
    (:synoptik-serve/test     . "SYNOPTIK-SERVE-TEST")
    (:synoptik-rest/test      . "SYNOPTIK-REST-TEST")
    (:synoptik-mcp/test       . "SYNOPTIK-MCP-TEST"))
  "Each test system and the package its TEST-RUNNER lives in.
The two are listed rather than derived because the names do not correspond:
SYNOPTIK-ONTOLOGY/TEST's runner is in ROOT-ONTOLOGY-TEST.")

(defun find-test (system)
  (assoc system *test-systems* :test #'eql))

(defun run-test (system)
  "Load SYSTEM and call TEST-PACKAGE's TEST-RUNNER. True when everything passed.

The runner is looked up with FIND-SYMBOL rather than written as
TEST-PACKAGE:TEST-RUNNER, because the package is a value that arrives at
runtime: a package prefix is resolved by the *reader*, so the prefix form names
a package literally called TEST-PACKAGE and fails to read before this file ever
runs."
  (let ((pair (find-test system)))
    (if (null pair)
        ;; An early return, not a message and then the lookup anyway: with PAIR
        ;; NIL the rest of this function has no package to look a runner up in.
        (progn (format t "~&  no suite registered for ~a~%" system) nil)
        (let ((test-package (cdr pair)))
          (handler-case
              (progn
                (format t "~&~%===== ~a =====~%" system)
                (funcall (read-from-string "ql:quickload") system :silent t)
                ;; FIND-PACKAGE before FIND-SYMBOL: FIND-SYMBOL signals on a
                ;; package that does not exist, which is the very case the
                ;; first clause is trying to report.
                (cond ((null (find-package test-package))
                       (format t "~&  no package ~a after loading ~a~%"
                               test-package system)
                       nil)
                      ((null (find-symbol "TEST-RUNNER" test-package))
                       (format t "~&  ~a has no TEST-RUNNER~%" test-package)
                       nil)
                      (t (and (funcall (find-symbol "TEST-RUNNER" test-package)) t))))
            ;; SERIOUS-CONDITION rather than ERROR: a library whose conditions
            ;; are not ERROR subtypes -- cl-yaml's are not -- would otherwise
            ;; take the whole run down at the first malformed fixture.
            (serious-condition (condition)
              (format t "~&  ~a did not run: ~a~%" system condition)
              nil))))))


(defun full-test ()
  "Run every system's suite. Returns T only when all of them passed."
  (let ((results (loop for (system . nil) in *test-systems*
                       collect (cons system (run-test system)))))
    (format t "~&~%===== summary =====~%")
    (loop for (system . passed) in results
          do (format t "~&  ~:[FAIL~;ok  ~]  ~a~%" passed system))
    (let ((failed (remove-if #'cdr results)))
      (format t "~&~%~d of ~d system~:p passed.~%"
              (- (length results) (length failed)) (length results))
      (null failed))))
