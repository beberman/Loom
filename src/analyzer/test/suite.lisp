;;;
;;; Main test runner
;;;

(defpackage #:synoptik-analyzer-test
  (:use #:cl #:fiveam #:synoptik-ontology #:synoptik-graph #:synoptik-analyzer)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-analyzer-test)

(def-suite all-tests
  :description "Master suite of all synoptik-analyzer tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
