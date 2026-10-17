;;;
;;; Main test runner
;;;

(defpackage #:synoptik-graph-test
  (:use #:cl #:fiveam #:synoptik-ontology #:synoptik-graph)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-graph-test)

(def-suite all-tests
  :description "Master suite of all synoptik-graph tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
