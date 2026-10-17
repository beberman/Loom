;;;; Loading Synoptik's systems from a script, and saying so when it cannot.
;;;;
;;;;   (load (merge-pathnames "harness.lisp"
;;;;                          (make-pathname :name nil :type nil
;;;;                                         :defaults *load-truename*)))
;;;;   (synoptik-harness:load-systems "tools/test/whatever.lisp"
;;;;                              :systems '("ontology/" "graph/")
;;;;                              :libraries '("cl-yaml")
;;;;                              :load :synoptik-workspace)
;;;;
;;;; The `../' is because every caller lives in tools/test/ and this file stays
;;;; in tools/: it is shared infrastructure rather than a test of anything, and
;;;; TREE-ROOT resolves through the `..' so the root it reports is unchanged.
;;;;
;;;; REQ-0050 R5. Every instrument under tools/ opens with the same twelve
;;;; lines -- require asdf, load quicklisp, push a registry, quickload some
;;;; libraries, load a system -- and every one of them reported a failure in
;;;; those lines as a backtrace. tools/test/call-site-census.lisp could not load at
;;;; all for as long as PLAN-0043 had been landed: its registry predated
;;;; synoptik-embed, which synoptik-knowledge has depended on since, so the instrument
;;;; that *CALL-SITE-CEILING*'s own failure message tells a developer to re-run
;;;; had been broken for days and nothing said so.
;;;;
;;;; A backtrace is not the failure mode worth fixing. The failure mode is that
;;;; a measurement which did not happen must not read like one that returned
;;;; nothing to say -- the same rule CON-0001 states for the graph, applied to
;;;; Synoptik's own instruments. So this exits 1 with a sentence naming the
;;;; instrument, the system, the condition, and what is therefore unmeasured.

(require :asdf)
(load (merge-pathnames "../../quicklisp-setup.lisp" *load-truename*))

(defpackage #:synoptik-harness
  (:use #:cl)
  (:export #:load-systems #:tree-root))

(in-package #:synoptik-harness)

(defparameter *root*
  (merge-pathnames "../../" (make-pathname :name nil :type nil
                                           :defaults (or *load-truename* *default-pathname-defaults*)))
  "The tree this file was loaded from, up two: <synoptik>/.

Two rather than one because this file lives in tools/test/. When it moved there
the registry pushed <synoptik>/tools/src/graph/ and every system stopped resolving
-- and what a reader saw was REFUSED's sentence naming the system that would
not load, which is the failure this file exists to produce.

Captured at load time because *LOAD-TRUENAME* is this file only while this file
is loading, and every caller wants the same answer.")

(defun tree-root () *root*)

(defun refused (instrument system condition)
  "Say that INSTRUMENT did not run, and exit non-zero."
  (format *error-output*
          "~&~a did not run.~%~
             ~2t~a failed to load: ~a~%~
             ~2tNothing was measured. This is not a result of zero -- it is the~%~
             ~2tinstrument being broken, and whatever it measures is unknown~%~
             ~2tuntil it loads.~%"
          instrument system condition)
  (finish-output *error-output*)
  (sb-ext:exit :code 1))

(defun load-systems (instrument &key systems libraries load)
  "Put SYSTEMS on the registry, quickload LIBRARIES, load system LOAD.

INSTRUMENT is this script's own path, for the message. SYSTEMS are directory
names under src/, so \"graph/\" rather than :synoptik-graph -- a registry entry is
a directory and the distinction matters when one is missing.

A directory that does not exist is skipped rather than pushed, which is what
tools/load-test.lisp did by hand: a script has to be runnable at the step that
introduces the system it names."
  (dolist (system systems)
    (let ((directory (merge-pathnames (concatenate 'string "src/" system) *root*)))
      (when (probe-file directory)
        (pushnew directory asdf:*central-registry* :test #'equal))))
  (handler-case
      (handler-bind ((warning #'muffle-warning))
        (when libraries
          (funcall (read-from-string "ql:quickload") libraries :silent t))
        (when load
          (funcall (read-from-string "ql:quickload") load :silent t)))
    (error (condition)
      (refused instrument (or load "a library") condition)))
  (values))
