;;;
;;; Main test runner
;;;

(defpackage #:loom-process-test
  (:use #:cl #:fiveam #:loom-process)
  (:export #:test-runner #:all-tests))

(in-package :loom-process-test)

(def-suite all-tests
  :description "Master suite of all loom-process tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
