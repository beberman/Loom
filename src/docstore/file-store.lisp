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
returning a hash table (EQUAL) whose keys are the ignored ones."))
  (:documentation "Documents as files under ROOT. DES-0051 D6."))

(defun make-file-docstore (root &key claim ignore)
  "A file store over ROOT. CLAIM and IGNORE as the slots describe."
  (make-instance 'file-docstore
                 :root (pathname root)
                 :claim (or claim (constantly nil))
                 :ignore ignore))

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
                                 (directory (merge-pathnames "**/*.*" (file-docstore-root store)))))
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

(defmethod docstore-changed-since ((store file-docstore) token &key (contents t))
  "Walk the documents and compare each with TOKEN's stamp for it.

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
