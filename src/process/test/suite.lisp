;;;
;;; Main test runner
;;;

(defpackage #:synoptik-process-test
  (:use #:cl #:fiveam #:synoptik-process)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-process-test)

(def-suite all-tests
  :description "Master suite of all synoptik-process tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
