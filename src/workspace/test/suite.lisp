;;;
;;; Main test runner
;;;

(defpackage #:synoptik-workspace-test
  (:use #:cl #:fiveam #:synoptik-ontology #:synoptik-graph #:synoptik-workspace #:synoptik-knowledge)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-workspace-test)

(def-suite all-tests
  :description "Master suite of all synoptik-workspace tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
