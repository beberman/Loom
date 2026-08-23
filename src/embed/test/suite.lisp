;;;
;;; Main test runner for :loom-embed.
;;;

(defpackage #:loom-embed-test
  (:use #:cl #:fiveam #:loom-embed)
  (:export #:test-runner #:all-tests))

(in-package :loom-embed-test)

(def-suite all-tests
  :description "The embedder protocol: identity, normalisation, and the
stand-in every system above this one tests against.")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
