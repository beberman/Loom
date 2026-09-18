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
  ref address text (version 1) created changed (removed nil) (unreadable nil))

(defclass memory-docstore ()
  ((documents :initform '() :accessor memory-docstore-documents
              :documentation "Every document ever put, newest first, removed ones included.")
   (next-ref :initform 0 :accessor memory-docstore-next-ref
             :documentation "The counter a ref is minted from. Never reused.")
   (sequence :initform 0 :accessor memory-docstore-sequence
             :documentation "Advanced by every change. A token is a value of it.")
   (terminal-p :initarg :terminal-p :initform nil :reader memory-docstore-terminal-p
               :documentation "As the file store's: a function of a category
string and a status keyword, or NIL for a store where nothing is terminal.

Placement is the store's and the vocabulary is not (DES-0051 N3). This store
has no directories, so the move is a change of address and nothing else -- and
that it is a change of address at all is the point, because a caller that read
the new address out of the returned record works on both stores and one that
computed docs/<category>/completed/ for itself works on neither.")
   (category-prefix :initarg :category-prefix :initform nil
                    :reader memory-docstore-category-prefix
                    :documentation "As the file store's: a function of a
category returning the id prefix its documents carry, or NIL."))
  (:documentation "Documents held in memory, for the suite. DES-0051 D6."))

(defun make-memory-docstore (&key terminal-p category-prefix)
  "An empty in-memory store."
  (make-instance 'memory-docstore :terminal-p terminal-p
                                  :category-prefix category-prefix))

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

(defun memory-docstore-break (store ref reason)
  "Make reads of the document REF names fail with REASON, and count that as a
change. The store still holds the document and still lists it.

A read that fails is a change kind of its own, and the file store has one --
a document it can stat and cannot open. Without this the in-memory store has
none, and the workspace's retry of a failed document (DES-0051 D7) is
exercised on the file store alone, where CHANGED-SINCE re-reports the document
anyway because a failure leaves it out of the token. Here the sequence number
moves past it, so the retry is the only way back."
  (let ((document (find-document-or-signal store ref)))
    (setf (memory-document-unreadable document) reason
          (memory-document-changed document) (advance store))
    nil))

(defun memory-docstore-repair (store ref)
  "Let reads of the document REF names succeed again, without advancing the
sequence. A caller that recovers the document has read it again itself, which
is what the retry is for."
  (let ((document (find-document-or-signal store ref)))
    (setf (memory-document-unreadable document) nil)
    nil))

;;;; ==================================================================
;;;; Phase 1, read
;;;; ==================================================================

(defmethod docstore-enumerate ((store memory-docstore))
  (mapcar #'document-record (live-documents store)))

(defmethod docstore-read ((store memory-docstore) ref)
  (let ((document (find-document-or-signal store ref)))
    (when (memory-document-unreadable document)
      (error "~a" (memory-document-unreadable document)))
    (values (copy-seq (memory-document-text document))
            (memory-document-version document))))

(defmethod docstore-changed-since ((store memory-docstore) token &key (contents t) known-only)
  "Every document whose last change is later than TOKEN, newest first.

A document removed after TOKEN is :REMOVED only if it existed when TOKEN was
taken. One put and removed in between was never seen, and reporting its
removal would name a document the caller never had. With KNOWN-ONLY, a
document put after TOKEN is not reported at all.

A document MEMORY-DOCSTORE-BREAK has made unreadable is :FAILED rather than
:CHANGED."
  (let ((since (or token 0))
        (changes '()))
    (dolist (document (memory-docstore-documents store))
      (when (and (> (memory-document-changed document) since)
                 (not (and known-only (> (memory-document-created document) since))))
        (cond ((and (not (memory-document-removed document))
                    (memory-document-unreadable document)
                    contents)
               ;; :FAILED only where text was asked for. With :CONTENTS NIL the
               ;; caller is counting what moved, and a document that moved and
               ;; cannot be read has still moved.
               (push (list :failed (document-record document)
                           (memory-document-unreadable document))
                     changes))
              ((not (memory-document-removed document))
               (push (list :changed (document-record document)
                           (and contents (copy-seq (memory-document-text document))))
                     changes))
              ((<= (memory-document-created document) since)
               (push (list :removed (memory-document-ref document)
                           (memory-document-address document))
                     changes)))))
    (values (nreverse changes)
            (and contents (memory-docstore-sequence store)))))


;;;; ==================================================================
;;;; Phase 2, write
;;;; ==================================================================
;;;;
;;;; :ATOMIC, and it is free rather than clever: every entry is planned first,
;;;; and an in-memory apply has nothing left that can fail. The file store's
;;;; :PLANNED is the weaker guarantee, so a caller written against :PLANNED is
;;;; correct here and one written against :ATOMIC is not correct there.

(defun memory-address (store category name)
  (declare (ignore store))
  (format nil "docs/~a/~a.yaml" category name))

(defun terminal-memory-address (store address status)
  "ADDRESS with completed/ added or taken away, as STATUS requires."
  (let* ((terminal (let ((terminal-p (memory-docstore-terminal-p store)))
                     (and terminal-p
                          (funcall terminal-p (address-category address) status)
                          t)))
         (segments (address-segments address))
         (directories (butlast segments))
         (file (car (last segments))))
    (when (and directories
               (string-equal *completed-directory* (car (last directories))))
      (setf directories (butlast directories)))
    (format nil "~{~a/~}~@[~a/~]~a"
            directories (and terminal *completed-directory*) file)))

(defun address-taken-p (store address)
  (find address (live-documents store)
        :key #'memory-document-address :test #'string=))

(defstruct (memory-write (:conc-name memory-write-))
  "One planned change: the document to change, its new address and new text.
DOCUMENT is NIL for a create, which has none yet."
  document category address text)

(defun plan-memory-operation (store operation taken)
  "Three values: the MEMORY-WRITE for OPERATION, a problem, and its kind.
The same three the file store\'s planner returns, and the same sentences."
  (ecase (first operation)
    (:create
     (destructuring-bind (category name text) (rest operation)
       (let ((address (memory-address store category name)))
         (cond ((gethash address taken)
                (values nil (format nil "~a: ~a is where another document in this ~
command lands." address address)
                        :refused))
               ((address-taken-p store address)
                (values nil (format nil "~a: ~a already exists." address address) :refused))
               (t (values (make-memory-write :category category :address address :text text)
                          nil nil))))))
    ((:write :transition)
     (destructuring-bind (ref argument &key expected-version) (rest operation)
       (let ((document (find-document store ref)))
         (cond
           ((null document)
            (values nil (format nil "The document store holds nothing under ~a." ref)
                    :missing))
           ((and expected-version
                 (not (equalp expected-version (memory-document-version document))))
            (values nil
                    (format nil "~a changed after it was read. The write was refused ~
and the document is unchanged." ref)
                    :conflict))
           ((eq :write (first operation))
            (values (make-memory-write :document document
                                       :address (memory-document-address document)
                                       :text argument)
                    nil nil))
           (t
            (multiple-value-bind (start end current)
                (top-level-status-line (memory-document-text document))
              (cond
                ((null start)
                 (values nil (format nil "~a has no top-level status: line." ref) :refused))
                (t
                 (let ((address (terminal-memory-address
                                 store (memory-document-address document) argument)))
                   (cond
                     ((and (not (string= address (memory-document-address document)))
                           (or (gethash address taken) (address-taken-p store address)))
                      (values nil (format nil "~a: ~a already exists." ref address) :refused))
                     (t
                      (values (make-memory-write
                               :document document :address address
                               :text (unless (eq current argument)
                                       (replace-status-line
                                        (memory-document-text document)
                                        start end argument)))
                              nil nil)))))))))))))) 

(defun perform-memory-write (store plan)
  "Carry out PLAN. Returns the new record."
  (let ((document (memory-write-document plan))
        (sequence (advance store)))
    (cond
      ((null document)
       (let ((new (make-memory-document
                   :ref (format nil "mem:~d" (incf (memory-docstore-next-ref store)))
                   :address (memory-write-address plan)
                   :text (copy-seq (memory-write-text plan))
                   :created sequence
                   :changed sequence)))
         (push new (memory-docstore-documents store))
         (document-record new)))
      (t
       (when (memory-write-text plan)
         (setf (memory-document-text document) (copy-seq (memory-write-text plan)))
         (incf (memory-document-version document)))
       (setf (memory-document-address document) (memory-write-address plan)
             (memory-document-changed document) sequence)
       (document-record document)))))

(defun apply-one-memory-operation (store operation ref)
  (multiple-value-bind (plan problem kind) (plan-memory-operation store operation
                                                                  (make-hash-table :test #'equal))
    (when problem (signal-refusal problem kind store ref))
    (perform-memory-write store plan)))

(defmethod docstore-write ((store memory-docstore) ref text &key expected-version)
  (apply-one-memory-operation store (list :write ref text :expected-version expected-version) ref))

(defmethod docstore-create ((store memory-docstore) category name text)
  (apply-one-memory-operation store (list :create category name text) name))

(defmethod docstore-transition ((store memory-docstore) ref status &key expected-version)
  (apply-one-memory-operation store (list :transition ref status :expected-version expected-version)
                              ref))

(defmethod docstore-apply-batch ((store memory-docstore) operations)
  "Plan every entry, then apply. Atomic: a refusal writes nothing, and nothing
in the applying can fail."
  (let ((taken (make-hash-table :test #'equal))
        (plans '())
        (problems '()))
    (dolist (operation operations)
      (multiple-value-bind (plan problem) (plan-memory-operation store operation taken)
        (cond (problem (push problem problems))
              (t (setf (gethash (memory-write-address plan) taken) t)
                 (push plan plans)))))
    (if problems
        (values nil (nreverse problems))
        (values (mapcar (lambda (plan) (perform-memory-write store plan))
                        (nreverse plans))
                nil))))


;;;; ==================================================================
;;;; Phase 3, workflow
;;;; ==================================================================
;;;;
;;;; Two of the four. This store has no history and nowhere a person could open,
;;;; and says so by having no method: DOCSTORE-CAPABILITIES reads :ABSENT for
;;;; both, which is DES-0051 D3's recorded gap rather than an operation that
;;;; appears to work.

(defmethod docstore-allocate-id ((store memory-docstore) category)
  "The highest id in CATEGORY plus one, from the documents the store holds.

The file store\'s rule, over a list instead of a directory -- and removed
documents count, because reusing a retired number makes an old reference point
silently at new content."
  (let ((prefix (and (memory-docstore-category-prefix store)
                     (funcall (memory-docstore-category-prefix store) category))))
    (unless prefix
      (error 'docstore-refused :store store :ref category
             :reason (format nil "This store was not told what id prefix ~a documents ~
carry, so it cannot allocate one." category)))
    (let ((highest 0))
      (dolist (document (memory-docstore-documents store))
        (when (string-equal category (address-category (memory-document-address document)))
          (let* ((name (pathname-name (memory-document-address document)))
                 (dash (position #\- name :from-end t)))
            (when (and dash (string-equal prefix (subseq name 0 dash)))
              (let ((n (parse-integer name :start (1+ dash) :junk-allowed t)))
                (when (and n (> n highest)) (setf highest n)))))))
      (format nil "~a-~4,\'0d" prefix (1+ highest)))))

(defmethod docstore-may-transition ((store memory-docstore) ref status actor)
  "Always, as on the file store. This store has no permission model either."
  (declare (ignore store ref status actor))
  (values t nil))

(defmethod docstore-capabilities ((store memory-docstore))
  "The default, with the batch guarantee this store actually gives, and
ALLOCATE-ID as weak as the file store\'s: highest plus one is right for one
writer."
  (let ((capabilities (call-next-method)))
    (setf (getf capabilities :batch) :atomic
          (getf capabilities :allocate-id) :single-writer)
    capabilities))

;;;; ==================================================================
;;;; The kind (DES-0052)
;;;; ==================================================================

(defparameter *memory-docstore-config-keys* '(:kind)
  "An in-memory store declares nothing but that it is one. It has no root, no
extension and nowhere to put a document but in itself.")

(defun memory-docstore-from-config (config services)
  "An in-memory store from a declaration that says only which kind it is.

Registered so that a tree can be run against this store by declaring it, which
is the only way to reach it without a Lisp caller. It keeps nothing across a
restart, which is what makes it a demonstration and a test double rather than
a store anybody should declare in earnest."
  (check-config-keys config *memory-docstore-config-keys* :memory)
  (destructuring-bind (&key terminal-p category-prefix &allow-other-keys) services
    (make-memory-docstore :terminal-p terminal-p :category-prefix category-prefix)))

(register-docstore-kind :memory #'memory-docstore-from-config)
