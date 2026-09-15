;;;; DES-0051 D9 part C: properties the file store has because it is files.
;;;;
;;;; Each test names the file property it tests. A test belongs here only for
;;;; that reason. A test that has to move here for any other reason means the
;;;; protocol is in the wrong place.

(in-package :loom-docstore-test)

(in-suite all-tests)

(defmacro with-file-store ((store root &key ignore) &body body)
  `(let ((,root (fresh-directory)))
     (unwind-protect
          (let ((,store (make-file-docstore ,root :claim #'yaml-under-docs-p
                                                  :ignore ,ignore)))
            ,@body)
       (uiop:delete-directory-tree ,root :validate t))))

(defun addresses (store)
  (sort (mapcar #'docstore-record-address (docstore-enumerate store)) #'string<))

(test the-file-stores-ref-is-the-relative-path
  ;; File property: the ref and the address are one string, the path relative
  ;; to the root, spelled as the analyzer spells an origin file.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (let ((record (first (docstore-enumerate store))))
      (is (string= "docs/decisions/DEC-0001.yaml" (docstore-record-ref record)))
      (is (string= "docs/decisions/DEC-0001.yaml" (docstore-record-address record))))))

(test a-same-second-edit-is-seen
  ;; File property: FILE-WRITE-DATE counts whole seconds, so an edit in the
  ;; second the store read the file leaves the write date unchanged. CON-0002.
  ;; The edit keeps the length, so nothing but the content differs.
  (with-file-store (store root)
    (let ((path (merge-pathnames "docs/decisions/DEC-0001.yaml" root)))
      (write-text path "status: draft")
      (let ((token (nth-value 1 (docstore-changed-since store nil))))
        (write-text path "status: final")
        (is (equal '("docs/decisions/DEC-0001.yaml")
                   (changed-refs (docstore-changed-since store token)))
            "an edit inside the settle window was missed")))))

(test dot-prefixed-files-and-directories-are-not-documents
  ;; File property: a name beginning with a dot is an editor's or a tool's
  ;; bookkeeping, wherever it sits.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (write-text (merge-pathnames "docs/decisions/.DEC-0002.yaml" root) "id: DEC-0002")
    (write-text (merge-pathnames "docs/.drafts/DEC-0003.yaml" root) "id: DEC-0003")
    (write-text (merge-pathnames ".claude/docs/DEC-0004.yaml" root) "id: DEC-0004")
    (is (equal '("docs/decisions/DEC-0001.yaml") (addresses store)))))

(test the-emacs-lock-symlink-is-not-a-document
  ;; File property: Emacs writes .#DEC-0001.yaml as a dangling symlink while a
  ;; buffer is open. It keeps the extension, so a claim alone would take it,
  ;; and reading it fails.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (uiop:run-program (list "ln" "-s" "user@host.1234:1700000000"
                            (namestring (merge-pathnames "docs/decisions/.#DEC-0001.yaml" root))))
    (is (equal '("docs/decisions/DEC-0001.yaml") (addresses store)))
    (multiple-value-bind (changes) (docstore-changed-since store nil)
      (is (null (changes-of :failed changes))
          "the lock symlink was read: ~s" changes))))

(test a-git-ignored-document-is-not-held
  ;; File property: git decides what in a checkout is generated. The store asks
  ;; its IGNORE function once, with the claimed paths, and holds none of the
  ;; ones it names.
  (let ((asked '()))
    (with-file-store (store root
                      :ignore (lambda (paths)
                                (push paths asked)
                                (let ((table (make-hash-table :test #'equal)))
                                  (setf (gethash "docs/generated/DEC-0002.yaml" table) t)
                                  table)))
      (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
      (write-text (merge-pathnames "docs/generated/DEC-0002.yaml" root) "id: DEC-0002")
      (write-text (merge-pathnames "src/notes.txt" root) "not a document")
      (is (equal '("docs/decisions/DEC-0001.yaml") (addresses store)))
      (is (= 1 (length asked)) "the ignore query ran ~d times for one walk" (length asked))
      (is (equal '("docs/decisions/DEC-0001.yaml" "docs/generated/DEC-0002.yaml")
                 (sort (copy-list (first asked)) #'string<))
          "git was asked about ~s rather than the claimed paths" (first asked)))))

(test a-path-that-is-not-a-document-cannot-be-read
  ;; File property: a ref is a path, and a path to a file that is not a
  ;; document names nothing in the store even though the file exists.
  (with-file-store (store root)
    (write-text (merge-pathnames "src/code.lisp" root) "(defun f ())")
    (signals docstore-missing (docstore-read store "src/code.lisp"))))

(test an-unreadable-document-comes-back-failed
  ;; File property: a file can be listed and still fail to read, and a file
  ;; with mode 000 is one. Dropping it would read as a clean tree, so it comes
  ;; back :FAILED and stays out of the token.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (let ((path (merge-pathnames "docs/decisions/DEC-0002.yaml" root)))
      (write-text path "id: DEC-0002")
      (uiop:run-program (list "chmod" "000" (namestring path)))
      (unwind-protect
           (multiple-value-bind (changes token) (docstore-changed-since store nil)
             (is (equal '("docs/decisions/DEC-0001.yaml") (changed-refs changes)))
             (is (equal '("docs/decisions/DEC-0002.yaml")
                        (mapcar (lambda (change) (docstore-record-ref (second change)))
                                (changes-of :failed changes)))
                 "the unreadable document came back as ~s" changes)
             (is (null (gethash "docs/decisions/DEC-0002.yaml" token))
                 "a document nobody could read has a stamp in the token"))
        (uiop:run-program (list "chmod" "644" (namestring path)))))))
