;;;
;;; Main test runner for :synoptik-embed.
;;;

(defpackage #:synoptik-embed-test
  (:use #:cl #:fiveam #:synoptik-embed)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-embed-test)

(def-suite all-tests
  :description "The embedder protocol: identity, normalisation, and the
stand-in every system above this one tests against.")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))
