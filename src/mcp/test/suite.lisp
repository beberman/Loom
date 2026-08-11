;;;
;;; Main test runner
;;;
;;; The acceptor fixture, the port and the drakma helpers come from
;;; LOOM-SERVE-TEST, for the reason PLAN-0005 gives: one fixture macro rather
;;; than three, because a leaked acceptor fails the next run.
;;;

(defpackage #:loom-mcp-test
  (:use #:cl #:fiveam #:loom-workspace #:loom-serve #:loom-mcp #:loom-serve-test)
  (:export #:test-runner #:all-tests))

(in-package :loom-mcp-test)

(def-suite all-tests
  :description "Master suite of all loom-mcp tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
