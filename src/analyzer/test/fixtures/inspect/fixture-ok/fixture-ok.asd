;;;; A target system for the inspector's child process (ARCH-0011).
;;;;
;;;; Loaded only by a child SBCL the LISP-INSPECTOR spawns, and never by Loom's
;;;; own build: nothing pushes this directory into ASDF:*CENTRAL-REGISTRY* in
;;;; this image. DISCOVER-UNITS excludes it from a real repository's unit set
;;;; because it lives under a directory named "test".

(in-package :asdf-user)

(defsystem :fixture-ok
  :description "Loads clean. The definition shapes ARCH-0011 R10 names, in miniature."
  :serial t
  :components ((:file "fixture-ok")))
