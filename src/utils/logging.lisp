;;;; The bounded event log, and the debugger hook that writes to it.
;;;;
;;;; REV-0002 A1. *LOG*, *LOG-LIMIT* and LOG-EVENT were three definitions
;;;; duplicated byte for byte between src/process/console.lisp and
;;;; src/serve/server.lisp. Neither system may depend on the other -- DES-0006
;;;; R5 makes the peer property structural and tools/test/load-test.lisp is its
;;;; instrument -- so there was no home for them below both until this system
;;;; existed. server.lisp's own docstring recorded the copy and its reason:
;;;; "Its own, three lines of it, rather than synoptik-process's LOG-EVENT. That
;;;; function lives in the system this one may not depend on."
;;;;
;;;; ONE LOG, WHERE THERE WERE TWO. This is a behaviour change and not a merge.
;;;; The two *LOG*s were separate specials, so in the combined console-plus-
;;;; listener process that `sbcl --script synoptik-serve.lisp' without --headless
;;;; starts, the console's `log' command printed console events and no service
;;;; events -- a request that errored inside Hunchentoot was logged where
;;;; nobody at that console could read it. It now prints both, in one
;;;; timestamped order. The label is what tells them apart, which is what the
;;;; label was always for.

(in-package :synoptik-utils)

(defvar *log* '()
  "Recent events, most recent first: (timestamp label text).

Bounded, because it is a convenience for a developer at a console and not a
durable record of anything -- under DEC-0001 nothing recovers from it.")

(defparameter *log-limit* 200)

(defun log-event (label format &rest arguments)
  "Record one event under LABEL, dropping the oldest past *LOG-LIMIT*."
  (push (list (get-universal-time) label (apply #'format nil format arguments)) *log*)
  (when (> (length *log*) *log-limit*)
    (setf *log* (subseq *log* 0 *log-limit*)))
  (values))

(defun recent-log (count)
  "The COUNT most recent events, newest first."
  (subseq *log* 0 (min count (length *log*))))

(defun install-debugger-hook (&key (prefix "synoptik") (on-unwind #'abort))
  "Make sure no non-interactive thread can block on a debugger prompt.

A process waiting on a debugger nobody can see is indistinguishable, from the
outside, from a process doing nothing. The hook logs the condition, writes it to
*ERROR-OUTPUT* under PREFIX, and calls ON-UNWIND.

ON-UNWIND is called with the condition, and is the argument rather than a
constant because the two callers differ in one respect that matters.
synoptik-process passes #'ABORT, whose optional condition argument this supplies,
and which assumes an ABORT restart exists. In a Hunchentoot worker thread it may
not, and a hook that assumed one would turn an unhandled condition into a
second, different error inside the handler for the first -- so synoptik-serve passes
a function that looks for the restart and returns when there is none. The
condition is passed because FIND-RESTART narrows to the restarts associated with
it, and a hook that dropped it could invoke an ABORT belonging to something
else. Both behaviours stay visible at the call site instead of being buried in
two near-identical hooks."
  (setf *debugger-hook*
        (lambda (condition hook)
          (declare (ignore hook))
          (log-event "error" "~a: ~a" (type-of condition) condition)
          (format *error-output* "~&[~a] unhandled ~a: ~a~%"
                  prefix (type-of condition) condition)
          (finish-output *error-output*)
          (funcall on-unwind condition))))
