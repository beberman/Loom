;;;; The in-memory store: built to differ from the file store wherever a caller
;;;; could come to depend on a document being a file.
;;;;
;;;; DES-0051 D6. A ref is "mem:" and a counter, never reused, and is not the
;;;; address. An address is docs/<category>/<name>.yaml and never exists on
;;;; disk. A version is a per-document counter. A token is one store-wide
;;;; sequence number. Documents enumerate newest first, the reverse of the file
;;;; store's walk order. No disk is touched.
;;;;
;;;; A test that passes on the file store and fails here has found a caller
;;;; that assumes a file.
;;;;
;;;; Nothing here locks. Its one client, loom-workspace, calls a store inside
;;;; WITH-REPOSITORY-LOCK.

(in-package #:loom-docstore)

(defstruct (memory-document (:conc-name memory-document-))
  "One document the in-memory store has held. A removed document stays, marked,
so CHANGED-SINCE can report its removal to a token taken before it."
  ref address text (version 1) created changed (removed nil))

(defclass memory-docstore ()
  ((documents :initform '() :accessor memory-docstore-documents
              :documentation "Every document ever put, newest first, removed ones included.")
   (next-ref :initform 0 :accessor memory-docstore-next-ref
             :documentation "The counter a ref is minted from. Never reused.")
   (sequence :initform 0 :accessor memory-docstore-sequence
             :documentation "Advanced by every change. A token is a value of it."))
  (:documentation "Documents held in memory, for the suite. DES-0051 D6."))

(defun make-memory-docstore ()
  "An empty in-memory store."
  (make-instance 'memory-docstore))

(defun advance (store)
  (incf (memory-docstore-sequence store)))

(defun find-document (store ref)
  "The live document REF names, or NIL."
  (find-if (lambda (document)
             (and (not (memory-document-removed document))
                  (string= ref (memory-document-ref document))))
           (memory-docstore-documents store)))

(defun find-document-or-signal (store ref)
  (or (find-document store ref)
      (error 'docstore-missing :store store :ref ref)))

(defun live-documents (store)
  "Documents not removed, newest first."
  (remove-if #'memory-document-removed (memory-docstore-documents store)))

(defun document-record (document)
  (make-docstore-record (memory-document-ref document)
                        (memory-document-address document)
                        (memory-document-version document)))

;;;; ==================================================================
;;;; Changes from outside the protocol
;;;; ==================================================================
;;;;
;;;; A second writer, as an editor is to the file store. The suite uses these
;;;; to change a store behind its back, and PUT seeds one until DOCSTORE-CREATE
;;;; exists.

(defun memory-docstore-put (store category name text)
  "Add a document named NAME in CATEGORY holding TEXT. Returns its record."
  (let* ((sequence (advance store))
         (document (make-memory-document
                    :ref (format nil "mem:~d" (incf (memory-docstore-next-ref store)))
                    :address (format nil "docs/~a/~a.yaml" category name)
                    :text (copy-seq text)
                    :created sequence
                    :changed sequence)))
    (push document (memory-docstore-documents store))
    (document-record document)))

(defun memory-docstore-replace (store ref text)
  "Replace the text of the document REF names. Returns its new record."
  (let ((document (find-document-or-signal store ref)))
    (setf (memory-document-text document) (copy-seq text)
          (memory-document-changed document) (advance store))
    (incf (memory-document-version document))
    (document-record document)))

(defun memory-docstore-remove (store ref)
  "Remove the document REF names."
  (let ((document (find-document-or-signal store ref)))
    (setf (memory-document-removed document) t
          (memory-document-changed document) (advance store))
    nil))

;;;; ==================================================================
;;;; Phase 1, read
;;;; ==================================================================

(defmethod docstore-enumerate ((store memory-docstore))
  (mapcar #'document-record (live-documents store)))

(defmethod docstore-read ((store memory-docstore) ref)
  (let ((document (find-document-or-signal store ref)))
    (values (copy-seq (memory-document-text document))
            (memory-document-version document))))

(defmethod docstore-changed-since ((store memory-docstore) token &key (contents t))
  "Every document whose last change is later than TOKEN, newest first.

A document removed after TOKEN is :REMOVED only if it existed when TOKEN was
taken. One put and removed in between was never seen, and reporting its
removal would name a document the caller never had."
  (let ((since (or token 0))
        (changes '()))
    (dolist (document (memory-docstore-documents store))
      (when (> (memory-document-changed document) since)
        (cond ((not (memory-document-removed document))
               (push (list :changed (document-record document)
                           (and contents (copy-seq (memory-document-text document))))
                     changes))
              ((<= (memory-document-created document) since)
               (push (list :removed (memory-document-ref document)
                           (memory-document-address document))
                     changes)))))
    (values (nreverse changes)
            (and contents (memory-docstore-sequence store)))))
