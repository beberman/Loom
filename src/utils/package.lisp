;;;; Package definition for Loom's leaf utilities.
;;;;
;;;; REV-0002. Everything exported here was two or more copies before it moved,
;;;; and each copy lived in a system that could not reach the other. The file
;;;; split is by what the code is about rather than by which system asked for
;;;; it first: a reader looking for the refusal condition should not have to
;;;; know that the console and the REST skin were the two callers that forced
;;;; it down here.

(defpackage #:loom-utils
  (:use #:cl)
  (:export
   ;; errors.lisp -- the refusal vocabulary
   #:refusal
   #:refusal-message
   #:refuse

   ;; logging.lisp -- the bounded event log and the debugger hook
   #:*log*
   #:*log-limit*
   #:log-event
   #:recent-log
   #:install-debugger-hook

   ;; parsing.lisp -- reading a scalar a human or a query parameter typed
   #:is-integer-p
   #:to-integer
   #:is-boolean-p
   #:to-boolean
   #:to-cosine
   #:distribution-name-key
   #:*true-tokens*
   #:*false-tokens*

   ;; paths.lisp
   #:path-segments
   #:dot-prefixed-p

   ;; plists.lisp
   #:filter-plist
   #:strip-plist

   ;; threads.lisp
   #:await-thread
   #:sleep-until))
