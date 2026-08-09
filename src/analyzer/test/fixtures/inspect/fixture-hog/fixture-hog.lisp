;;;; Exhausts the heap at load time.
;;;;
;;;; This is RULE-0004's measured instance, and the reason the child's per-unit
;;;; guard names SERIOUS-CONDITION and not ERROR. Measured 2026-08-07 under
;;;; /usr/bin/sbcl with --dynamic-space-size 96: inside
;;;; (handler-case ... (error (c) ...)) the child is NOT saved -- it prints the
;;;; heap-exhaustion table and dies with "unhandled condition in
;;;; --disable-debugger mode", exit 1 -- while inside
;;;; (handler-case ... (storage-condition (c) ...)) it catches
;;;; HEAP-EXHAUSTED-ERROR, records the gap and carries on to the next unit.
;;;;
;;;; The size is a T-element vector, so eight bytes each: well past any cap a
;;;; test would set and still far short of anything a real machine would try to
;;;; satisfy before refusing.

(defpackage #:fixture-hog
  (:use #:cl))

(in-package #:fixture-hog)

(defvar *hog* nil)

(setf *hog* (make-array (expt 10 9) :initial-element 0))
