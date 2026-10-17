;;;
;;; Main test runner
;;;
;;; The acceptor fixture, the port and the drakma helpers come from
;;; SYNOPTIK-SERVE-TEST, for the reason PLAN-0005 gives: one fixture macro rather
;;; than three, because a leaked acceptor fails the next run.
;;;

(defpackage #:synoptik-mcp-test
  (:use #:cl #:fiveam #:synoptik-workspace #:synoptik-serve #:synoptik-mcp #:synoptik-serve-test)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-mcp-test)

(def-suite all-tests
  :description "Master suite of all synoptik-mcp tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
