;;;; The file store: every document is a file under the repository root.
;;;;
;;;; DES-0051 D6. The ref and the address are the same string, the path
;;;; relative to the root. A version is the file stamp of the text a read
;;;; returned (CON-0002). A token is a table from address to stamp.
;;;;
;;;; The store cannot compute two facts itself, because it cannot reach the
;;;; analyzer or run git on its own authority (RULE-0010). The CLAIM function
;;;; says which paths are documents. The IGNORE function says which of a list
;;;; of relative paths git ignores. loom-workspace passes both in.

(in-package #:loom-docstore)

(defclass file-docstore ()
  ((root :initarg :root :reader file-docstore-root
         :documentation "The repository root, a directory pathname.")
   (claim :initarg :claim :reader file-docstore-claim
          :documentation "A function of an absolute pathname, true for a document.")
   (ignore :initarg :ignore :initform nil :reader file-docstore-ignore
           :documentation "NIL, or a function of a list of relative paths
returning a hash table (EQUAL) whose keys are the ignored ones.")
   (listing :initarg :listing :initform nil :reader file-docstore-listing
            :documentation "NIL, or a function of no arguments returning every
pathname under ROOT, as DIRECTORY does. loom-workspace passes the listing its
own walk of the tree already paid for, so one poll walks the tree once.")
   (terminal-p :initarg :terminal-p :initform nil :reader file-docstore-terminal-p
               :documentation "NIL, or a function of a category string and a
status keyword, true when that status means the document is finished.

Placement is the store's (DES-0051 N3) and the vocabulary is not. CON-0004's
table says which statuses are terminal, it is the same on every store, and it
stays in loom-workspace -- so the answer is passed in, as the claim and the
ignore functions are. Without one nothing is terminal and no document ever
moves, which is the right answer for a store whose categories the caller has
said nothing about.")
   (document-directory :initarg :document-directory :initform "docs"
                       :reader file-docstore-document-directory
                       :documentation "The directory under ROOT that new
documents are created in. PLAN-0055 step 9 passes the manifest's
:DOCUMENT-DIRECTORY here; until then every caller gets the default.")
   (extension :initarg :extension :initform "yaml"
              :reader file-docstore-extension
              :documentation "The file type a created document gets."))
  (:documentation "Documents as files under ROOT. DES-0051 D6."))

(defun make-file-docstore (root &key claim ignore listing terminal-p
                                     (document-directory "docs") (extension "yaml"))
  "A file store over ROOT. The keywords are the slots above."
  (make-instance 'file-docstore
                 :root (pathname root)
                 :claim (or claim (constantly nil))
                 :ignore ignore
                 :listing listing
                 :terminal-p terminal-p
                 :document-directory document-directory
                 :extension extension))

(defun file-listing (store)
  "Every pathname under STORE's root: the LISTING function's, or a fresh walk."
  (if (file-docstore-listing store)
      (funcall (file-docstore-listing store))
      (directory (merge-pathnames "**/*.*" (file-docstore-root store)))))

(defun dotted-p (name)
  "True when NAME is a string beginning with a dot.

LOOM-UTILS:DOT-PREFIXED-P, restated because this system reaches no other Loom
system (RULE-0010)."
  (and (stringp name) (plusp (length name)) (char= #\. (char name 0))))

(defun relative-address (store path)
  "PATH relative to STORE's root, forward-slashed.

The expression LOOM-ANALYZER:WORKSPACE-RELATIVE-PATH uses, so an address is
byte-identical to the path a document's entities carry as their origin."
  (substitute #\/ #\\ (enough-namestring (pathname path)
                                         (pathname (file-docstore-root store)))))

(defun held-p (store path)
  "True when absolute PATH is a document STORE holds, git aside.

A dot-prefixed name or directory is an editor's or a tool's bookkeeping, and
Emacs's lock file .#foo.yaml is a dangling symlink that keeps its target's
extension. The walk in REPOSITORY-FILES skips both, for the same reasons."
  (and (pathname-name path)
       (not (dotted-p (file-namestring path)))
       (notany #'dotted-p (rest (pathname-directory path)))
       (funcall (file-docstore-claim store) path)))

(defun document-paths (store)
  "Every document under STORE's root, as absolute pathnames, in walk order.

The walk, the dot filter, the claim and then the ignore query, in the order
REPOSITORY-FILES uses. Git is asked about the claimed paths only, and once."
  (let* ((claimed (remove-if-not (lambda (path) (held-p store path))
                                 (file-listing store)))
         (ignored (and claimed
                       (file-docstore-ignore store)
                       (funcall (file-docstore-ignore store)
                                (mapcar (lambda (path) (relative-address store path)) claimed)))))
    (if (or (null ignored) (zerop (hash-table-count ignored)))
        claimed
        (remove-if (lambda (path) (gethash (relative-address store path) ignored))
                   claimed))))

(defun address-record (address version)
  (make-docstore-record address address version))

(defmethod docstore-enumerate ((store file-docstore))
  (mapcar (lambda (path) (address-record (relative-address store path) nil))
          (document-paths store)))

(defmethod docstore-read ((store file-docstore) ref)
  "The file's text and its stamp. Signals DOCSTORE-MISSING for a path that is
not on disk or is not a document."
  (let ((path (merge-pathnames ref (file-docstore-root store))))
    (unless (and (probe-file path) (held-p store path))
      (error 'docstore-missing :store store :ref ref))
    (let ((text (read-file path)))
      (values text (stamp-file path text)))))

(defun walk-changes (store token contents)
  "CHANGED-SINCE by walking the documents and comparing each with TOKEN's stamp.

STAMP-CHANGED-P decides, so a same-second edit is seen (CON-0002). A changed
file is read once, and its new stamp is taken from that text. A path TOKEN
names that the walk no longer finds is :REMOVED. TOKEN is copied, never
changed, so the call has no side effect.

A document the walk finds and a read then fails on comes back as (:FAILED
record reason). DES-0051 D2 names two kinds of change, and a third is needed
because dropping the document would read as a clean tree. INDEX-REPOSITORY
records the same failure today when READ-FILE signals. The document is left
out of the returned token, so it has no stamp until a read succeeds."
  (let ((now (get-universal-time))
        (next (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (changes '()))
    (dolist (path (document-paths store))
      (let* ((address (relative-address store path))
             (known (and token (gethash address token))))
        (setf (gethash address seen) t)
        (cond ((and token (not (stamp-changed-p known path now)))
               ;; Unchanged, or unreadable now: STAMP-CHANGED-P leaves a file
               ;; it cannot stat alone, as the poll always has.
               (when known
                 (setf (gethash address next) known)))
              ((not contents)
               (push (list :changed (address-record address nil) nil) changes))
              (t
               (handler-case
                   (let* ((text (read-file path))
                          (stamp (stamp-file path text)))
                     (setf (gethash address next) stamp)
                     (push (list :changed (address-record address stamp) text) changes))
                 (error (condition)
                   (push (list :failed (address-record address nil)
                               (princ-to-string condition))
                         changes)))))))
    (let ((removed '()))
      (when token
        (maphash (lambda (address stamp)
                   (declare (ignore stamp))
                   (unless (gethash address seen)
                     (push address removed)))
                 token))
      ;; Sorted, because a hash table's order is not a fact about the tree.
      (dolist (address (sort removed #'string<))
        (push (list :removed address address) changes)))
    (values (nreverse changes) (and contents next))))

(defun known-changes (store token contents)
  "CHANGED-SINCE over the documents TOKEN describes, and no others.

One stat per document and no walk, which is why the form exists: INDEX-DRIFT
asks it on every `context' answer. A document gone from disk is :REMOVED, and
one whose stamp disagrees is :CHANGED, which is the question INDEX-DRIFT asked
of REPOSITORY-STAMPS before documents moved here. Sorted by address, because a
hash table's order is not a fact about the tree."
  (let ((now (get-universal-time))
        (next (make-hash-table :test #'equal))
        (changes '()))
    (when token
      (dolist (address (sort (loop for address being the hash-keys of token collect address)
                             #'string<))
        (let ((known (gethash address token))
              (path (merge-pathnames address (file-docstore-root store))))
          (cond ((null (probe-file path))
                 (push (list :removed address address) changes))
                ((not (stamp-changed-p known path now))
                 (setf (gethash address next) known))
                ((not contents)
                 (push (list :changed (address-record address nil) nil) changes))
                (t
                 (handler-case
                     (let* ((text (read-file path))
                            (stamp (stamp-file path text)))
                       (setf (gethash address next) stamp)
                       (push (list :changed (address-record address stamp) text) changes))
                   (error (condition)
                     (push (list :failed (address-record address nil)
                                 (princ-to-string condition))
                           changes))))))))
    (values (nreverse changes) (and contents next))))

(defmethod docstore-changed-since ((store file-docstore) token &key (contents t) known-only)
  "WALK-CHANGES, or KNOWN-CHANGES when KNOWN-ONLY."
  (if known-only
      (known-changes store token contents)
      (walk-changes store token contents)))


;;;; ==================================================================
;;;; Phase 2, write
;;;; ==================================================================
;;;;
;;;; Every write is planned before any byte is written, and the plan is what
;;;; refuses. DOCSTORE-APPLY-BATCH plans every entry and refuses the whole
;;;; batch with every problem in it; the three single operations plan one and
;;;; signal. One planner, so a refusal reads the same either way -- which is
;;;; APPLY-DOCUMENT-EDIT's plan-then-apply split, moved down a system and given
;;;; to every caller rather than to `complete\' alone.

;;;; ==================================================================
;;;; Where the file belongs (RULE-0007, and R3)
;;;; ==================================================================

(defun flat-directory (path)
  "The directory PATH's document lives in when its status is not terminal --
its own directory, or the parent when it is already inside completed/."
  (let ((directory (pathname-directory path)))
    (if (string-equal *completed-directory* (car (last directory)))
        (make-pathname :directory (butlast directory) :name nil :type nil
                       :defaults path)
        (make-pathname :directory directory :name nil :type nil :defaults path))))

(defun status-destination (path terminal)
  "Where the document at PATH belongs, given whether its status is TERMINAL.

Derived from the directory the file is in rather than from a `docs' segment in
its path, so a foreign tree prepared by REQ-0021 -- which may keep its documents
anywhere -- gets the same answer this one does.

Both directions, which is what R3's \"placement and status can no longer
disagree\" means: a status that becomes terminal moves the file in, and one that
stops being terminal moves it back out. A category with no terminal status never
computes a destination different from where the file already is, so decisions,
rules and architecture documents never move."
  (let ((flat (flat-directory path)))
    (merge-pathnames
     (make-pathname :name (pathname-name path) :type (pathname-type path))
     (if terminal
         (merge-pathnames (make-pathname :directory (list :relative *completed-directory*))
                          flat)
         flat))))

(defun probe-writable (path)
  "NIL when PATH can be written, or a sentence saying why not.

Opened for append and closed without writing a byte, which is a real probe
rather than a guess about permissions: the alternatives are reading a mode
bitmask, which says nothing about ACLs or a read-only mount, and finding out
during the write, which is the one thing the plan-then-apply split exists to
prevent."
  (handler-case
      (progn (with-open-file (out path :direction :output :if-exists :append
                                       :if-does-not-exist :error))
             nil)
    (error (condition) (format nil "cannot be written: ~a" condition))))

(defun terminal-address-p (store address status)
  "Whether STATUS means the document at ADDRESS is finished."
  (let ((terminal-p (file-docstore-terminal-p store)))
    (and terminal-p
         (funcall terminal-p (address-category address) status)
         t)))

(defstruct (file-write (:conc-name file-write-))
  "One planned write: the text, where it is written, and where it ends up.

SOURCE is the file the text is written to and DESTINATION where it is then
renamed; they are equal when the document does not move. TEXT is NIL for a
transition that leaves the line as it stands, which is how re-running a
`complete\' that already landed writes nothing."
  ref address source destination text)

(defun file-write-moves-p (plan)
  (not (equal (namestring (file-write-source plan))
              (namestring (file-write-destination plan)))))

(defun plan-move (store address destination-path taken)
  "NIL, or a sentence refusing the move of ADDRESS to DESTINATION-PATH.

TAKEN is the set of destinations earlier entries of this batch already claim.
Two documents whose transitions land on one path is a batch that would lose
one of them, and checking each against the disk alone would not see it."
  (declare (ignore store))
  (let ((name (namestring destination-path)))
    (cond ((gethash name taken)
           (format nil "~a: ~a is where another document in this command lands."
                   address name))
          ((probe-file destination-path)
           (format nil "~a: ~a already exists." address name))
          (t
           (handler-case (progn (ensure-directories-exist destination-path) nil)
             (error (condition)
               (format nil "~a: ~a cannot be created: ~a"
                       address
                       (make-pathname :name nil :type nil :defaults destination-path)
                       condition)))))))

(defun plan-file-operation (store operation taken)
  "Three values: the FILE-WRITE for OPERATION, a problem, and the problem\'s kind.

KIND is :MISSING, :CONFLICT or :REFUSED, which is how a single operation knows
which condition to signal. A batch prints the problem and ignores the kind."
  (let ((root (file-docstore-root store)))
    (flet ((held (ref)
             (let ((path (merge-pathnames ref root)))
               (and (probe-file path) (held-p store path) path))))
      (ecase (first operation)
        (:create
         (destructuring-bind (category name text) (rest operation)
           (let* ((address (format nil "~a/~a/~a.~a"
                                   (file-docstore-document-directory store)
                                   category name (file-docstore-extension store)))
                  (path (merge-pathnames address root))
                  (problem (plan-move store address path taken)))
             (if problem
                 (values nil problem :refused)
                 (values (make-file-write :ref address :address address
                                          :source path :destination path :text text)
                         nil nil)))))
        ((:write :transition)
         (destructuring-bind (ref argument &key expected-version) (rest operation)
           (let ((path (held ref)))
             (cond
               ((null path)
                (values nil (format nil "The document store holds nothing under ~a." ref)
                        :missing))
               (t
                (let ((text (handler-case (read-file path)
                              (error (condition)
                                (return-from plan-file-operation
                                  (values nil (format nil "~a cannot be read: ~a" ref condition)
                                          :refused))))))
                  (cond
                    ((and expected-version
                          (not (equalp expected-version (stamp-file path text))))
                     (values nil
                             (format nil "~a changed after it was read. The write was refused ~
and the document is unchanged." ref)
                             :conflict))
                    ((eq :write (first operation))
                     (let ((unwritable (probe-writable path)))
                       (if unwritable
                           (values nil (format nil "~a ~a" ref unwritable) :refused)
                           (values (make-file-write :ref ref :address ref
                                                    :source path :destination path
                                                    :text argument)
                                   nil nil))))
                    (t
                     (multiple-value-bind (start end current) (top-level-status-line text)
                       (cond
                         ((null start)
                          ;; Refused and not repaired: a document with no
                          ;; top-level status line may be one whose type has no
                          ;; status at all, and writing one in would invent a
                          ;; field its author never wrote.
                          (values nil (format nil "~a has no top-level status: line." ref)
                                  :refused))
                         (t
                          (let* ((destination-address
                                   (relative-address
                                    store
                                    (status-destination
                                     path (terminal-address-p store ref argument))))
                                 (destination (merge-pathnames destination-address root))
                                 (moving (not (equal (namestring path)
                                                     (namestring destination))))
                                 (problem
                                   (or (and moving
                                            (plan-move store ref destination taken))
                                       (let ((unwritable (probe-writable path)))
                                         (and unwritable (format nil "~a ~a" ref unwritable))))))
                            (if problem
                                (values nil problem :refused)
                                (values (make-file-write
                                         :ref destination-address
                                         :address destination-address
                                         :source path :destination destination
                                         :text (unless (eq current argument)
                                                 (replace-status-line text start end argument)))
                                        nil nil))))))))))))))))))

(defun perform-file-write (plan)
  "Carry out PLAN: the text, then the move. Returns the new record."
  (let ((source (file-write-source plan))
        (text (file-write-text plan)))
    (when text
      (ensure-directories-exist source)
      (with-open-file (out source :direction :output :if-exists :supersede
                                  :if-does-not-exist :create)
        (write-string text out)))
    (when (file-write-moves-p plan)
      (ensure-directories-exist (file-write-destination plan))
      (rename-file source (file-write-destination plan)))
    (let ((path (file-write-destination plan)))
      (address-record (file-write-address plan) (stamp-file path (read-file path))))))

(defun signal-refusal (problem kind store ref)
  "Signal the condition KIND names, carrying PROBLEM as its reason."
  (ecase kind
    (:missing (error 'docstore-missing :store store :ref ref))
    (:conflict (error 'docstore-conflict :store store :ref ref))
    (:refused (error 'docstore-refused :store store :ref ref :reason problem))))

(defun apply-one-file-operation (store operation ref)
  "Plan OPERATION, signal its problem, or carry it out. The new record."
  (multiple-value-bind (plan problem kind)
      (plan-file-operation store operation (make-hash-table :test #'equal))
    (when problem (signal-refusal problem kind store ref))
    (perform-file-write plan)))

(defmethod docstore-write ((store file-docstore) ref text &key expected-version)
  (apply-one-file-operation store (list :write ref text :expected-version expected-version) ref))

(defmethod docstore-create ((store file-docstore) category name text)
  (apply-one-file-operation store (list :create category name text) name))

(defmethod docstore-transition ((store file-docstore) ref status &key expected-version)
  (apply-one-file-operation store (list :transition ref status :expected-version expected-version) ref))

(defmethod docstore-apply-batch ((store file-docstore) operations)
  "Plan every entry, then write. DES-0051 D4: :PLANNED.

Nothing is written while any entry is refused, and every refusal is in the
list, because a caller that has to run a command five times to find five
problems stops reading the fifth. A failure during the writing returns the
records that did land beside the sentence that stopped it -- the tree is then
part-way, and re-running the same command finishes it."
  (let ((taken (make-hash-table :test #'equal))
        (plans '())
        (problems '()))
    (dolist (operation operations)
      (multiple-value-bind (plan problem) (plan-file-operation store operation taken)
        (cond (problem (push problem problems))
              (t (setf (gethash (namestring (file-write-destination plan)) taken) t)
                 (push plan plans)))))
    (cond
      (problems (values nil (nreverse problems)))
      (t
       (let ((landed '()))
         (handler-case
             (dolist (plan (nreverse plans))
               (push (perform-file-write plan) landed))
           (error (condition)
             (return-from docstore-apply-batch
               (values (nreverse landed)
                       (list (format nil "~a of ~a entries were written, and then: ~a"
                                     (length landed) (length operations) condition))))))
         (values (nreverse landed) nil))))))
