;;;
;;; Main test runner
;;;
;;; The fixture macro, the port discipline and the drakma helpers come from
;;; SYNOPTIK-SERVE-TEST rather than being written again here: PLAN-0005 asks for
;;; one of each, because a leaked acceptor makes the next run fail in a way
;;; that looks like a code defect and is not. The same *TEST-PORT* is reused
;;; for the same reason -- WITH-TEST-SERVER stops whatever is in *SERVER*
;;; before starting, so one port for the whole run cannot collide with itself.
;;;

(defpackage #:synoptik-rest-test
  (:use #:cl #:fiveam #:synoptik-workspace #:synoptik-serve #:synoptik-rest #:synoptik-serve-test)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-rest-test)

(def-suite all-tests
  :description "Master suite of all synoptik-rest tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
