;;;; A hash table guarded by a reentrant lock. DES-0003 R1 and R2.
;;;;
;;;; The lock is a constructor argument rather than a private field the type
;;;; mints for itself, and that one choice is the whole design. Several
;;;; instances sharing one lock is what lets a compound mutation spanning four
;;;; of the graph's seven tables appear atomic to a reader; a type that always
;;;; made its own lock would need a second mechanism layered on top to get
;;;; there, and seven separate locks would force every multi-table operation to
;;;; acquire several in some order -- which is a deadlock waiting for two
;;;; callers to disagree about the order, and a deadlock is silent where the
;;;; crash this replaces at least printed something.
;;;;
;;;; PT-PUSH and PT-DELETE-FROM-LIST are not conveniences. A type whose
;;;; contract stopped at "gethash and setf are each individually safe" would
;;;; still race on the read-modify-write idioms graph-manager.lisp actually
;;;; uses, because two threads each doing a locked read and then a locked write
;;;; of one key can still lose one of the two pushes. The primitive has to be
;;;; the whole read-modify-write, not the pieces around it.
;;;;
;;;; Invariant, and the reason every operation below is this small: no code
;;;; outside this file calls gethash, remhash, clrhash, maphash or push against
;;;; the hash-table a protected-table wraps.

(in-package :loom-graph)

(defstruct (protected-table (:constructor %make-protected-table (table lock)))
  "One hash-table and a reference to the reentrant lock guarding it.
The lock is a reference, not a possession: two protected-tables constructed
with the same :LOCK are guarded together."
  (table (make-hash-table :test #'equal) :type hash-table)
  ;; No :type. bordeaux-threads names no portable type for a recursive lock,
  ;; and declaring the SBCL one here would put an implementation detail in a
  ;; struct definition for nothing.
  (lock nil))

(defun make-protected-table (&key (test #'equal) lock)
  "A protected table guarded by LOCK, or by a fresh lock of its own.
Defaulting rather than requiring it keeps a standalone table usable, but every
table the graph owns is constructed with the graph's lock (DES-0003 R3)."
  (%make-protected-table (make-hash-table :test test)
                         (or lock (bt:make-recursive-lock "loom-protected-table"))))

(defmacro with-pt-lock ((pt) &body body)
  `(bt:with-recursive-lock-held ((protected-table-lock ,pt))
     ,@body))

(defun pt-get (pt key &optional default)
  "Mirrors GETHASH, including the second value."
  (with-pt-lock (pt) (gethash key (protected-table-table pt) default)))

(defun (setf pt-get) (new-value pt key &optional default)
  ;; DEFAULT is accepted and ignored, exactly as (setf gethash) accepts and
  ;; ignores it, so a call site can be rewritten without rearranging it.
  (declare (ignore default))
  (with-pt-lock (pt) (setf (gethash key (protected-table-table pt)) new-value)))

(defun pt-rem (pt key)
  "Mirrors REMHASH."
  (with-pt-lock (pt) (remhash key (protected-table-table pt))))

(defun pt-clear (pt)
  "Mirrors CLRHASH, except in what it returns: PT, never the underlying table.
Handing back the raw hash-table would put it in a caller's hands, which is the
one thing the invariant at the top of this file forbids."
  (with-pt-lock (pt) (clrhash (protected-table-table pt)))
  pt)

(defun pt-count (pt)
  "Mirrors HASH-TABLE-COUNT."
  (with-pt-lock (pt) (hash-table-count (protected-table-table pt))))

(defun pt-keys (pt)
  "A fresh list of every key, built under the lock.
Built under the lock and not merely started under it: the iteration is the
operation SBCL detects colliding with a concurrent write, so a caller that
took a snapshot lazily would have moved the hazard rather than removed it."
  (with-pt-lock (pt)
    (loop for key being the hash-keys of (protected-table-table pt) collect key)))

(defun pt-values (pt)
  "A fresh list of every value, built under the lock."
  (with-pt-lock (pt)
    (loop for value being the hash-values of (protected-table-table pt) collect value)))

(defun pt-push (pt key value)
  "Cons VALUE onto the list at KEY, as one critical section."
  (with-pt-lock (pt)
    (push value (gethash key (protected-table-table pt)))))

(defun pt-delete-from-list (pt key value &key (test #'eql))
  "Remove VALUE from the list at KEY by TEST, as one critical section.
Drops KEY entirely when the list empties, so a table used as a multimap does
not accumulate keys mapped to NIL.

TEST defaults to EQL to match CL:REMOVE, whose default this replaces at the
call sites that had one."
  (with-pt-lock (pt)
    (let* ((table (protected-table-table pt))
           (remaining (remove value (gethash key table) :test test)))
      (if remaining
          (setf (gethash key table) remaining)
          (progn (remhash key table) nil)))))
