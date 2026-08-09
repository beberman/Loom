;;;; Loading is running (REQ-0018), and this is what that costs when it goes
;;;; wrong. The child's per-unit guard has to record this as one unit's gap and
;;;; carry on to the next.

(defpackage #:fixture-boom
  (:use #:cl))

(in-package #:fixture-boom)

(error "fixture-boom refuses to load, deliberately.")
