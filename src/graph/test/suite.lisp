;;;
;;; Main test runner
;;;

(defpackage #:loom-graph-test
  (:use #:cl #:fiveam #:loom-ontology #:loom-graph)
  (:export #:test-runner #:all-tests))

(in-package :loom-graph-test)

(def-suite all-tests
  :description "Master suite of all loom-graph tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
