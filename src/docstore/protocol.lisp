;;;; The document-store protocol: the record, the conditions, the operations.
;;;;
;;;; DES-0051 D2 and D3. Every operation of all three phases is declared here.
;;;; A store has methods for the operations it answers. DOCSTORE-CAPABILITIES
;;;; reports :ABSENT for the rest, so a store with no write methods says so
;;;; rather than failing on the first write.
;;;;
;;;; A document has three names (D1). The ref is the store's identity for it.
;;;; A caller compares refs with STRING= and passes them back, and never parses
;;;; one. The address is a repository-relative path in the document layout,
;;;; docs/<category>/[completed/]<name>.<ext>. The analyzer reads a category
;;;; from it, and nothing above the protocol opens it. The entity id is the
;;;; analyzer's, and this system never sees one.

(in-package #:loom-docstore)

;;;; ==================================================================
;;;; The record
;;;; ==================================================================

(defstruct (docstore-record (:constructor make-docstore-record (ref address version)))
  "One document, as an operation returned it.

REF is the store's identity for the document. ADDRESS is its path in the
document layout. VERSION describes the bytes the operation read or wrote, never
what the store holds a moment later. A caller passes a version back and never
compares or inspects one (DES-0051 N2)."
  (ref "" :type string :read-only t)
  (address "" :type string :read-only t)
  (version nil :read-only t))

;;;; ==================================================================
;;;; Conditions
;;;; ==================================================================
;;;;
;;;; Both are errors, so a HANDLER-CASE on ERROR catches them (RULE-0004).

(define-condition docstore-error (error)
  ((store :initarg :store :initform nil :reader docstore-error-store)
   (ref :initarg :ref :initform nil :reader docstore-error-ref))
  (:documentation "A document store refused an operation on REF."))

(define-condition docstore-missing (docstore-error) ()
  (:documentation "REF names no document in the store.")
  (:report (lambda (condition stream)
             (format stream "The document store holds nothing under ~a."
                     (docstore-error-ref condition)))))

(define-condition docstore-conflict (docstore-error)
  ((expected :initarg :expected :initform nil :reader docstore-conflict-expected)
   (actual :initarg :actual :initform nil :reader docstore-conflict-actual))
  (:documentation "A write named an EXPECTED-VERSION the document no longer has.

The store is unchanged when this is signalled. That is compare-and-swap: a
document read, then edited by somebody else, then written, is refused rather
than overwritten.")
  (:report (lambda (condition stream)
             (format stream "~a changed after it was read. The write was refused and the document is unchanged."
                     (docstore-error-ref condition)))))

;;;; ==================================================================
;;;; Phase 1, read
;;;; ==================================================================

(defgeneric docstore-enumerate (store)
  (:documentation "Every document STORE holds, as a list of DOCSTORE-RECORDs.

No bytes are read. A record's version may be NIL here, because enumerating
promises only the ref and the address."))

(defgeneric docstore-read (store ref)
  (:documentation "The text of the document REF names, and the version of that text.

Two values: the text, and a version describing exactly that text. Signals
DOCSTORE-MISSING when REF names nothing."))

(defgeneric docstore-changed-since (store token &key contents)
  (:documentation "What changed in STORE since TOKEN. Two values: the changes and a new token.

Each change is (:CHANGED record text) or (:REMOVED ref address). A NIL TOKEN
means since nothing, and every document comes back :CHANGED. That is the
rebuild path.

The call has no side effect. The same token passed twice returns the same
changes if nothing moved. A caller advances by keeping the returned token.

The text travels with the change, and the returned token describes that text.
CON-0002's last paragraph is the reason: the stamp has to describe the bytes
that were analyzed, not whatever is there by the time it is taken.

With CONTENTS NIL, a :CHANGED entry carries NIL for its text and the returned
token is NIL. A token has to describe text somebody read, and this form reads
none. INDEX-DRIFT uses it to count what moved."))

(defparameter *docstore-operations*
  '((:enumerate . docstore-enumerate)
    (:read . docstore-read)
    (:changed-since . docstore-changed-since)
    (:write . docstore-write)
    (:create . docstore-create)
    (:transition . docstore-transition)
    (:apply-batch . docstore-apply-batch)
    (:allocate-id . docstore-allocate-id)
    (:may-transition . docstore-may-transition)
    (:history . docstore-history)
    (:locate . docstore-locate))
  "Each operation as DOCSTORE-CAPABILITIES names it, and its generic function.
In DES-0051 D2's order.")

(defun required-argument-count (function)
  "How many required arguments generic FUNCTION takes."
  (let ((lambda-list (sb-mop:generic-function-lambda-list function)))
    (or (position-if (lambda (element) (member element lambda-list-keywords))
                     lambda-list)
        (length lambda-list))))

(defun answers-p (store operation)
  "True when generic function OPERATION has a method applicable to STORE.

Only the first argument's class is asked about. Every operation takes the store
first, and a store's methods specialize on the store alone."
  (let* ((function (fdefinition operation))
         (classes (cons (class-of store)
                        (make-list (1- (required-argument-count function))
                                   :initial-element (find-class t)))))
    (and (sb-mop:compute-applicable-methods-using-classes function classes) t)))

(defgeneric docstore-capabilities (store)
  (:documentation "What STORE can do, as a plist. DES-0051 D3.

One entry per operation in *DOCSTORE-OPERATIONS*, each one of:

  :NATIVE         the store answers it
  :SINGLE-WRITER  it answers correctly while one writer exists
  :ABSENT         it does not answer, and Loom names the degraded behaviour

and two properties:

  :BATCH          :ATOMIC, :PLANNED, or :ABSENT with no batch method (D4)
  :BRANCH-SCOPED  T when a document revision belongs to a branch

This method derives each entry from whether the store has a method for the
operation. It reads :NATIVE for every method and :PLANNED for a batch, the
weaker guarantee. A store that answers less well, or batches atomically, says
so in its own method over (CALL-NEXT-METHOD).")
  (:method (store)
    (append (loop for (operation . function) in *docstore-operations*
                  append (list operation (if (answers-p store function) :native :absent)))
            (list :batch (if (answers-p store 'docstore-apply-batch) :planned :absent)
                  :branch-scoped nil))))

;;;; ==================================================================
;;;; Phase 2, write
;;;; ==================================================================
;;;;
;;;; Each write takes EXPECTED-VERSION, the version a read returned. A mismatch
;;;; signals DOCSTORE-CONFLICT and leaves the store unchanged.

(defgeneric docstore-write (store ref text &key expected-version)
  (:documentation "Replace the document REF names with TEXT. Returns its new record."))

(defgeneric docstore-create (store category name text)
  (:documentation "Create a document named NAME in CATEGORY holding TEXT. Returns its record.

Refused when the name is taken."))

(defgeneric docstore-transition (store ref status &key expected-version)
  (:documentation "Set the status of the document REF names to STATUS. Returns its new record.

Where the document then lives is the store's business (DES-0051 N3). The
returned record carries the new ref and address, and a caller uses them rather
than predicting them."))

(defgeneric docstore-apply-batch (store operations)
  (:documentation "Apply OPERATIONS as one command. Two values: results and problems.

Each operation is one of

  (:WRITE ref text :EXPECTED-VERSION version)
  (:CREATE category name text)
  (:TRANSITION ref status :EXPECTED-VERSION version)

The store's :BATCH capability says what a failure leaves behind. :ATOMIC: all
land or none do. :PLANNED: every refusal is found before any write, and a
failure during the apply returns the entries that landed. DES-0051 D4."))

;;;; ==================================================================
;;;; Phase 3, workflow
;;;; ==================================================================

(defgeneric docstore-allocate-id (store category)
  (:documentation "A document id in CATEGORY that no document in STORE carries."))

(defgeneric docstore-may-transition (store ref status actor)
  (:documentation "Whether ACTOR may set the document REF names to STATUS.

Two values: a boolean and a reason. This is permission only. Whether STATUS is
a status the document's type takes is CON-0004's vocabulary, which lives in
loom-workspace and is the same on every store."))

(defgeneric docstore-history (store ref)
  (:documentation "The recorded changes to the document REF names.

A list of (when who field from to why), oldest first."))

(defgeneric docstore-locate (store ref)
  (:documentation "A string a person can open to reach the document REF names."))

;;;; ==================================================================
;;;; The materializer (DES-0051 D10)
;;;; ==================================================================

(defgeneric docstore-materialize (store record text)
  (:documentation "Write the working copy of RECORD's document, holding TEXT.

Called after every read and every :CHANGED entry. The working copy is for
editors and agents; Loom never reads a document from it. A store whose
documents already sit at their addresses has nothing to do, and that is this
default method.")
  (:method (store record text)
    (declare (ignore store record text))
    nil))
