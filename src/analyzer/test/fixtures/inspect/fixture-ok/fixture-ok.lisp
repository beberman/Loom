;;;; The four shapes the inspector has to report, one file each of them.
;;;;
;;;; A DEFUN calling a DEFUN, so there is a call fact both passes can see. A
;;;; DEFGENERIC with an inline (:method ...) clause whose body calls it too, so
;;;; SBCL reports a caller under its compound (FAST-METHOD ...) key -- the
;;;; parsing obligation REQ-0018 R8 puts on the inspector. And a DEFMACRO whose
;;;; expansion defines a function, which is the DEFENTITY-accessor case in
;;;; miniature.
;;;;
;;;; Line numbers here are asserted against by src/analyzer/test/inspector.lisp.
;;;; Editing this file means re-measuring them.

(defpackage #:fixture-ok
  (:use #:cl))

(in-package #:fixture-ok)

(defun inner-callee (x)
  (list x))

(defun outer-caller (x)
  (inner-callee x))

(defgeneric shape-area (shape)
  (:method ((shape integer))
    (inner-callee shape)))

(defmacro define-reader (name)
  `(defun ,name (x)
     (inner-callee x)))

(define-reader generated-reader)
