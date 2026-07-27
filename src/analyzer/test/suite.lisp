;;;
;;; Main test runner
;;;

(defpackage #:loom-analyzer-test
  (:use #:cl #:fiveam #:loom-ontology #:loom-graph #:loom-analyzer)
  (:export #:test-runner #:all-tests))

(in-package :loom-analyzer-test)

(def-suite all-tests
  :description "Master suite of all loom-analyzer tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
