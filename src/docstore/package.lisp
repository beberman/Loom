;;;; Package definition for the document-store protocol.
;;;;
;;;; DES-0051. loom-workspace reads and writes YAML documents through these
;;;; operations and never opens a document itself. The file tree is the first
;;;; store; an in-memory store exists so that the suite can prove no caller
;;;; depends on a document being a file.

(defpackage #:loom-docstore
  (:use #:cl)
  (:import-from #:utils #:read-file)
  (:export
   ;; protocol.lisp -- what a store returns
   #:docstore-record
   #:make-docstore-record
   #:docstore-record-p
   #:docstore-record-ref
   #:docstore-record-address
   #:docstore-record-version

   ;; protocol.lisp -- what a store signals
   #:docstore-error
   #:docstore-error-store
   #:docstore-error-ref
   #:docstore-missing
   #:docstore-refused
   #:docstore-refused-reason
   #:docstore-conflict
   #:docstore-conflict-expected
   #:docstore-conflict-actual

   ;; protocol.lisp -- the address
   #:*completed-directory*
   #:address-category

   ;; protocol.lisp -- phase 1, read
   #:docstore-enumerate
   #:docstore-read
   #:docstore-changed-since
   #:docstore-capabilities
   #:*docstore-operations*

   ;; protocol.lisp -- phase 2, write
   #:docstore-write
   #:docstore-create
   #:docstore-transition
   #:docstore-apply-batch

   ;; protocol.lisp -- phase 3, workflow
   #:docstore-allocate-id
   #:docstore-may-transition
   #:docstore-history
   #:docstore-locate

   ;; protocol.lisp -- D10
   #:docstore-materialize

   ;; file-store.lisp
   #:file-docstore
   #:make-file-docstore

   ;; memory-store.lisp
   #:memory-docstore
   #:make-memory-docstore
   #:memory-docstore-put
   #:memory-docstore-replace
   #:memory-docstore-remove
   #:memory-docstore-break
   #:memory-docstore-repair

   ;; status-line.lisp -- one line of a document's text
   #:whitespace-char-p
   #:line-end
   #:status-key-line-p
   #:status-line-value
   #:top-level-status-line
   #:replace-status-line

   ;; file-store.lisp -- where a file belongs
   #:flat-directory
   #:status-destination
   #:probe-writable

   ;; stamps.lisp
   #:*mtime-settle-seconds*
   #:file-stamp
   #:make-file-stamp
   #:file-stamp-write-date
   #:file-stamp-content-hash
   #:stamp-file
   #:stamp-changed-p))
