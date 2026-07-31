;;;
;;; Main test runner
;;;

(defpackage #:loom-workspace-test
  (:use #:cl #:fiveam #:loom-ontology #:loom-graph #:loom-workspace #:loom-knowledge)
  (:export #:test-runner #:all-tests))

(in-package :loom-workspace-test)

(def-suite all-tests
  :description "Master suite of all loom-workspace tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
