;;;
;;; Main test runner
;;; Copyright Brian Eberman, Ten Factor Growth 2022
;;;

(defpackage #:root-ontology-test
  (:use #:cl #:fiveam #:loom-ontology)
  (:export #:test-runner #:all-tests))

(in-package :root-ontology-test)

(def-suite all-tests
  :description "Master suite of all root-ontology tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))





