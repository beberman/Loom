;;;
;;; Main test runner
;;;

(defpackage #:loom-serve-test
  (:use #:cl #:fiveam #:loom-ontology #:loom-graph #:loom-analyzer #:loom-workspace
        #:loom-knowledge #:loom-serve)
  (:export #:test-runner #:all-tests
           ;; The acceptor fixture and the drakma helpers, exported because
           ;; loom-rest's and loom-mcp's suites reuse them. PLAN-0005 asks for
           ;; one fixture macro rather than three: a leaked acceptor fails the
           ;; *next* run in a way that looks like a code defect, so port
           ;; discipline belongs in one place.
           #:with-test-server
           #:with-saved-handlers
           #:with-operations-fixture
           #:http-call
           #:test-url
           #:*test-port*))

(in-package :loom-serve-test)

(def-suite all-tests
  :description "Master suite of all loom-serve tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
