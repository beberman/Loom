;;;
;;; Main test runner
;;;
;;; The fixture macro, the port discipline and the drakma helpers come from
;;; LOOM-SERVE-TEST rather than being written again here: PLAN-0005 asks for
;;; one of each, because a leaked acceptor makes the next run fail in a way
;;; that looks like a code defect and is not. The same *TEST-PORT* is reused
;;; for the same reason -- WITH-TEST-SERVER stops whatever is in *SERVER*
;;; before starting, so one port for the whole run cannot collide with itself.
;;;

(defpackage #:loom-rest-test
  (:use #:cl #:fiveam #:loom-workspace #:loom-serve #:loom-rest #:loom-serve-test)
  (:export #:test-runner #:all-tests))

(in-package :loom-rest-test)

(def-suite all-tests
  :description "Master suite of all loom-rest tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
