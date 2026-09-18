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
                                                  :ignore ,ignore
                                                  :terminal-p #'test-terminal-p
                                                  :category-prefix #'test-category-prefix)))
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

(test the-store-walks-the-listing-it-is-given
  ;; File property: the walk is the expensive part of a poll, so the workspace
  ;; hands the store the listing its own walk already paid for. A store that
  ;; walked the tree itself would pass every other test and double the cost.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (write-text (merge-pathnames "docs/decisions/DEC-0002.yaml" root) "id: DEC-0002")
    (let ((listed (make-file-docstore
                   root :claim #'yaml-under-docs-p
                        :listing (lambda ()
                                   (list (merge-pathnames "docs/decisions/DEC-0002.yaml" root))))))
      (is (equal '("docs/decisions/DEC-0001.yaml" "docs/decisions/DEC-0002.yaml")
                 (addresses store)))
      (is (equal '("docs/decisions/DEC-0002.yaml") (addresses listed))
          "the store walked the tree rather than the listing it was given"))))

(test a-crlf-document-keeps-its-line-endings-through-a-transition
  ;; File property, and PLAN-0055 risk 5. REPLACE-STATUS-LINE carries a
  ;; carriage return from the old line onto the new one, and nothing covered
  ;; that until the function moved down here. Without the carry the edited file
  ;; has one LF line in the middle of a CRLF file, which every later diff of
  ;; that document shows as a change nobody made.
  (with-file-store (store root)
    (let ((path (merge-pathnames "docs/plans/PLAN-0001.yaml" root)))
      (write-text path (format nil "id: PLAN-0001~c~%title: a plan~c~%status: draft~c~%"
                               #\Return #\Return #\Return))
      (let* ((record (docstore-transition store "docs/plans/PLAN-0001.yaml" :final))
             (text (docstore-read store (docstore-record-ref record)))
             (lines (loop with start = 0
                          while (< start (length text))
                          collect (multiple-value-bind (end next) (line-end text start)
                                    (prog1 (subseq text start end) (setf start next))))))
        (is (search "status: final" text) "the status line was not rewritten")
        (is (every (lambda (line) (and (plusp (length line))
                                       (char= #\Return (char line (1- (length line))))))
                   lines)
            "a line lost its carriage return: ~s" lines)))))

(test a-terminal-status-moves-the-file-into-completed
  ;; File property: the store's move is a rename on disk, so the old path is
  ;; gone and the new directory exists. RULE-0007's convention, which is what
  ;; STATUS-DESTINATION and FLAT-DIRECTORY came down here to keep.
  (with-file-store (store root)
    (let ((flat (merge-pathnames "docs/plans/PLAN-0001.yaml" root))
          (filed (merge-pathnames "docs/plans/completed/PLAN-0001.yaml" root)))
      (write-text flat (format nil "id: PLAN-0001~%status: draft~%"))
      (docstore-transition store "docs/plans/PLAN-0001.yaml" :final)
      (is (null (probe-file flat)) "the flat file is still there")
      (is (probe-file filed) "nothing was written into completed/")
      (docstore-transition store "docs/plans/completed/PLAN-0001.yaml" :draft)
      (is (probe-file flat) "a status that stopped being terminal did not come back out")
      (is (null (probe-file filed)) "and the completed/ copy is still there"))))

(test a-file-that-cannot-be-written-is-refused-before-anything-is-written
  ;; File property: PROBE-WRITABLE opens for append and closes without writing
  ;; a byte, which is a real probe rather than a guess about permissions. The
  ;; alternative is finding out during the write, which is the one thing
  ;; planning before writing exists to prevent.
  (with-file-store (store root)
    (let ((path (merge-pathnames "docs/decisions/DEC-0001.yaml" root)))
      (write-text path "id: DEC-0001")
      (uiop:run-program (list "chmod" "444" (namestring path)))
      (unwind-protect
           (progn
             (signals docstore-refused (docstore-write store "docs/decisions/DEC-0001.yaml"
                                                       "id: DEC-0001 edited"))
             (is (string= "id: DEC-0001"
                          (docstore-read store "docs/decisions/DEC-0001.yaml"))
                 "the refused write landed anyway"))
        (uiop:run-program (list "chmod" "644" (namestring path)))))))

(defun git (root &rest arguments)
  (uiop:run-program (append (list "git" "-C" (namestring root)) arguments)
                    :output nil :error-output nil :ignore-error-status t))

(defun git-tree (root)
  "Make ROOT a git repository a commit can be made in."
  (git root "init" "-q")
  (git root "config" "user.email" "suite@example.invalid")
  (git root "config" "user.name" "The Suite"))

(test locate-is-the-absolute-path
  ;; File property: DOCSTORE-LOCATE is "a string a person can open", and for
  ;; this store that is the path. The in-memory store has no method, which is
  ;; the honest answer for documents that are nowhere on disk.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (let ((located (docstore-locate store "docs/decisions/DEC-0001.yaml")))
      (is (stringp located))
      (is-true (probe-file located) "locate returned ~a, which is not there" located))))

(test history-follows-a-document-through-the-rename-a-transition-makes
  ;; File property, and the reason --follow is in the command rather than a
  ;; plain `git log'. A transition renames the file, so a finished document
  ;; asked about at its completed/ address would otherwise report only the
  ;; commit that put it there and none of the work that came before.
  (with-file-store (store root)
    (git-tree root)
    (write-text (merge-pathnames "docs/plans/PLAN-0001.yaml" root)
                (format nil "id: PLAN-0001~%status: draft~%"))
    (git root "add" "-A")
    (git root "commit" "-q" "-m" "PLAN-0001: the plan")
    (let ((record (docstore-transition store "docs/plans/PLAN-0001.yaml" :final)))
      (git root "add" "-A")
      (git root "commit" "-q" "-m" "PLAN-0001: finished")
      (let ((history (docstore-history store (docstore-record-ref record))))
        (is (= 2 (length history))
            "the history of a moved document is ~s" history)
        (destructuring-bind (when who field from to why) (first history)
          (is (stringp when) "the date is ~s" when)
          (is (string= "The Suite" who))
          (is (eq :commit field))
          (is (null from) "a commit has no from-value to name: ~s" from)
          (is (= 40 (length to)) "the to-value is the hash: ~s" to)
          (is (string= "PLAN-0001: finished" why)
              "the newest entry is ~s" why))
        (is (string= "PLAN-0001: the plan" (sixth (second history)))
            "the commit before the rename is ~s" (second history))))))

(test a-tree-git-cannot-answer-for-says-so-rather-than-reporting-no-history
  ;; CON-0001 in the capability. A scratch directory is not a checkout, and an
  ;; empty history there would read exactly like a document nobody has ever
  ;; touched.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/decisions/DEC-0001.yaml" root) "id: DEC-0001")
    (is (eq :absent (getf (docstore-capabilities store) :history))
        "history reads ~s for a directory that is not a checkout"
        (getf (docstore-capabilities store) :history))
    (signals docstore-refused (docstore-history store "docs/decisions/DEC-0001.yaml"))))

(test allocate-id-counts-completed-as-well-as-the-open-documents
  ;; File property, and the whole correctness of the allocator: `complete'
  ;; moves a finished document into completed/, so the highest id in a mature
  ;; category is normally in there. Looking only at the open ones answered
  ;; BUG-0026 on 2026-08-14 when BUG-0026 and BUG-0027 were both already taken
  ;; and filed, and the duplicate that was written had to be renumbered.
  (with-file-store (store root)
    (write-text (merge-pathnames "docs/plans/PLAN-0001.yaml" root) "id: PLAN-0001")
    (write-text (merge-pathnames "docs/plans/completed/PLAN-0007.yaml" root) "id: PLAN-0007")
    (is (string= "PLAN-0008" (docstore-allocate-id store "plans"))
        "allocated ~a with PLAN-0007 in completed/"
        (docstore-allocate-id store "plans"))))
