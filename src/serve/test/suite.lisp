;;;
;;; Main test runner
;;;

(defpackage #:synoptik-serve-test
  (:use #:cl #:fiveam #:synoptik-ontology #:synoptik-graph #:synoptik-analyzer #:synoptik-workspace
        #:synoptik-knowledge #:synoptik-serve)
  (:export #:test-runner #:all-tests
           ;; The acceptor fixture and the drakma helpers, exported because
           ;; synoptik-rest's and synoptik-mcp's suites reuse them. PLAN-0005 asks for
           ;; one fixture macro rather than three: a leaked acceptor fails the
           ;; *next* run in a way that looks like a code defect, so port
           ;; discipline belongs in one place.
           #:with-test-server
           #:with-saved-handlers
           #:with-operations-fixture
           #:http-call
           #:test-url
           #:*test-port*))

(in-package :synoptik-serve-test)

(def-suite all-tests
  :description "Master suite of all synoptik-serve tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
