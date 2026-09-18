;;;; DES-0051 D9 part A: one test body per property of the protocol, run once
;;;; for every store.
;;;;
;;;; Each test loops over *STORE-KINDS*. A store joins the suite by adding one
;;;; entry there, and no test is edited. A failure message names the store.
;;;;
;;;; A store kind supplies a store and four ways to change what it holds behind
;;;; its back: put, edit, delete and break. The first three are writes to disk
;;;; for the file store. That is how a second writer -- an editor saving a
;;;; file -- reaches a store, and changed-since has to see it. Break makes a
;;;; document the store still holds fail to read, which is mode 000 on a file
;;;; and a flag in memory.

(in-package :loom-docstore-test)

;; Every file says so. A test defined without it lands outside ALL-TESTS, and
;; TEST-RUNNER never runs it: the first version of this file had 25 tests that
;; passed by never running, and a mutation of the store is what showed it.
(in-suite all-tests)

(defstruct (harness (:constructor make-harness (store put edit delete break)))
  "A fresh store, and four ways to change it that do not go through it.

PUT takes a category, a name and text, and returns the ref. EDIT takes a ref
and text. DELETE and BREAK take a ref."
  store put edit delete break)

(defvar *store-kinds* '()
  "Each store the conformance tests run against: (name . function). The
function calls its one argument with a fresh HARNESS and cleans up after.")

(defun register-store-kind (name function)
  (setf *store-kinds*
        (append (remove name *store-kinds* :key #'car :test #'string=)
                (list (cons name function)))))

(defmacro for-each-store ((kind harness) &body body)
  "Run BODY once per store kind, with KIND bound to its name and HARNESS to a
fresh harness."
  `(dolist (entry *store-kinds*)
     (let ((,kind (car entry)))
       (declare (ignorable ,kind))
       (funcall (cdr entry) (lambda (,harness) ,@body)))))

(defun put (harness category name text)
  (funcall (harness-put harness) category name text))

(defun edit (harness ref text)
  (funcall (harness-edit harness) ref text))

(defun erase (harness ref)
  (funcall (harness-delete harness) ref))

(defun break-document (harness ref)
  "Make reads of REF fail, with the document still held and still listed."
  (funcall (harness-break harness) ref))

(defun changes-of (kind changes)
  "The entries of CHANGES whose first element is KIND."
  (remove kind changes :key #'first :test-not #'eq))

(defun changed-refs (changes)
  (sort (mapcar (lambda (change) (docstore-record-ref (second change)))
                (changes-of :changed changes))
        #'string<))

;;;; ==================================================================
;;;; The file store as a kind
;;;; ==================================================================

(defun write-text (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string text out)))

(defun fresh-directory ()
  (let ((root (merge-pathnames (format nil "loom-docstore-~36r/"
                                       (random (expt 36 10) (make-random-state t)))
                               (uiop:temporary-directory))))
    (ensure-directories-exist root)
    root))

(defun test-terminal-p (category status)
  "CON-0004's terminal column, cut down to what these tests use.

The real table is *WORKFLOW-STATUS-VOCABULARY* in loom-workspace and stays
there: which statuses finish a document is the workflow's question, and a
store only ever asks it. Both harnesses pass this one in, so a transition
moves on both stores or on neither."
  (and (member status
               (cond ((string-equal "plans" category) '(:final))
                     ((string-equal "bugs" category) '(:closed))
                     (t '())))
       t))

(defun test-category-prefix (category)
  "CON-0004's category-to-prefix convention, cut down to what these tests use.
The real table is *DOCUMENT-ID-PREFIXES* in loom-workspace and stays there."
  (cdr (assoc category '(("plans" . "PLAN") ("decisions" . "DEC") ("design" . "DES"))
              :test #'string-equal)))

(defun yaml-under-docs-p (path)
  "The document analyzer's claim, restated for tests: YAML under a docs segment."
  (and (member (pathname-type path) '("yaml" "yml") :test #'string-equal)
       (member "docs" (pathname-directory path) :test #'equal)
       t))

(defun call-with-file-harness (function)
  (let ((root (fresh-directory)))
    (unwind-protect
         (funcall function
                  (make-harness
                   (make-file-docstore root :claim #'yaml-under-docs-p
                                            :terminal-p #'test-terminal-p
                                            :category-prefix #'test-category-prefix)
                   (lambda (category name text)
                     (let ((ref (format nil "docs/~a/~a.yaml" category name)))
                       (write-text (merge-pathnames ref root) text)
                       ref))
                   (lambda (ref text) (write-text (merge-pathnames ref root) text))
                   (lambda (ref) (delete-file (merge-pathnames ref root)))
                   (lambda (ref)
                     (uiop:run-program (list "chmod" "000"
                                             (namestring (merge-pathnames ref root)))))))
      ;; Mode 000 back to readable before the tree goes, so the walk that
      ;; deletes it is not the thing that fails.
      (dolist (path (uiop:directory-files (merge-pathnames "docs/decisions/" root)))
        (uiop:run-program (list "chmod" "644" (namestring path)) :ignore-error-status t))
      (uiop:delete-directory-tree root :validate t))))

(register-store-kind "file store" #'call-with-file-harness)

;;;; ==================================================================
;;;; The in-memory store as a kind
;;;; ==================================================================

(defun call-with-memory-harness (function)
  (let ((store (make-memory-docstore :terminal-p #'test-terminal-p
                                     :category-prefix #'test-category-prefix)))
    (funcall function
             (make-harness
              store
              (lambda (category name text)
                (docstore-record-ref (memory-docstore-put store category name text)))
              (lambda (ref text) (memory-docstore-replace store ref text))
              (lambda (ref) (memory-docstore-remove store ref))
              (lambda (ref) (memory-docstore-break store ref "cannot read it"))))))

(register-store-kind "in-memory store" #'call-with-memory-harness)

;;;; ==================================================================
;;;; Phase 1, read
;;;; ==================================================================

(test enumerate-lists-what-was-put-and-nothing-else
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (refs (list (put harness "decisions" "DEC-0001" "id: DEC-0001")
                       (put harness "rules" "RULE-0001" "id: RULE-0001")))
           (records (docstore-enumerate store)))
      (is (equal (sort (copy-list refs) #'string<)
                 (sort (mapcar #'docstore-record-ref records) #'string<))
          "~a: enumerate returned ~s" kind (mapcar #'docstore-record-ref records))
      (dolist (record records)
        (is (search "docs/" (docstore-record-address record))
            "~a: ~s has no address in the document layout"
            kind (docstore-record-address record))))))

(test a-read-returns-the-text-and-a-version-of-that-text
  ;; The version describes the text returned. Two reads with nothing between
  ;; them agree, and a read after an edit disagrees with both.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (multiple-value-bind (text version) (docstore-read store ref)
        (is (string= "id: DEC-0001" text) "~a: read returned ~s" kind text)
        (is (equalp version (nth-value 1 (docstore-read store ref)))
            "~a: two reads of unchanged text gave different versions" kind)
        (edit harness ref "id: DEC-0002")
        (multiple-value-bind (edited edited-version) (docstore-read store ref)
          (is (string= "id: DEC-0002" edited) "~a: read after an edit returned ~s" kind edited)
          (is (not (equalp version edited-version))
              "~a: an edit left the version unchanged" kind))))))

(test reading-a-ref-that-names-nothing-signals-missing
  (for-each-store (kind harness)
    (let ((store (harness-store harness)))
      (put harness "decisions" "DEC-0001" "id: DEC-0001")
      (signals docstore-missing (docstore-read store "docs/decisions/DEC-0099.yaml"))
      (signals docstore-missing (docstore-read store "mem:99")))))

(test changed-since-nothing-returns-every-document-with-its-text
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (one (put harness "decisions" "DEC-0001" "id: DEC-0001"))
           (two (put harness "rules" "RULE-0001" "id: RULE-0001")))
      (multiple-value-bind (changes token) (docstore-changed-since store nil)
        (is (equal (sort (list one two) #'string<) (changed-refs changes))
            "~a: changed-since NIL returned ~s" kind (changed-refs changes))
        (is (null (changes-of :removed changes)))
        (is (not (null token)) "~a: no token came back" kind)
        (dolist (change changes)
          (is (string= (third change)
                       (docstore-read store (docstore-record-ref (second change))))
              "~a: the text of ~s is not what a read returns"
              kind (docstore-record-ref (second change))))))))

(test changed-since-has-no-side-effect
  ;; The same token passed twice gives the same answer. A store that advanced
  ;; its own state on the first call would report the edit once and then lose
  ;; it.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (put harness "rules" "RULE-0001" "id: RULE-0001")
      (let ((token (nth-value 1 (docstore-changed-since store nil))))
        (edit harness ref "id: DEC-0001 edited")
        (let ((first (changed-refs (docstore-changed-since store token)))
              (second (changed-refs (docstore-changed-since store token))))
          (is (equal (list ref) first) "~a: first call returned ~s" kind first)
          (is (equal first second) "~a: second call returned ~s" kind second))))))

(test after-one-edit-changed-since-reports-that-edit-and-nothing-else
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (put harness "rules" "RULE-0001" "id: RULE-0001")
      (let ((token (nth-value 1 (docstore-changed-since store nil))))
        (is (null (docstore-changed-since store token))
            "~a: nothing moved and changed-since reported something" kind)
        (edit harness ref "id: DEC-0001 edited")
        (multiple-value-bind (changes next) (docstore-changed-since store token)
          (is (equal (list ref) (changed-refs changes)) "~a: returned ~s" kind changes)
          (is (string= "id: DEC-0001 edited" (third (first changes))))
          (is (null (docstore-changed-since store next))
              "~a: the returned token does not describe the text it came with" kind))))))

(test a-new-document-comes-back-changed
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (token (progn (put harness "decisions" "DEC-0001" "id: DEC-0001")
                         (nth-value 1 (docstore-changed-since store nil))))
           (ref (put harness "rules" "RULE-0001" "id: RULE-0001")))
      (is (equal (list ref) (changed-refs (docstore-changed-since store token)))
          "~a: a document put after the token was not reported" kind))))

(test a-deletion-comes-back-removed-with-its-ref-and-address
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (put harness "rules" "RULE-0001" "id: RULE-0001")
      (let* ((address (docstore-record-address
                       (find ref (docstore-enumerate store)
                             :key #'docstore-record-ref :test #'string=)))
             (token (nth-value 1 (docstore-changed-since store nil))))
        (erase harness ref)
        (let ((changes (docstore-changed-since store token)))
          (is (equal (list (list :removed ref address)) changes)
              "~a: a deletion came back as ~s" kind changes))))))

(test changed-since-without-contents-reports-what-moved-and-no-token
  ;; INDEX-DRIFT's form. It reads nothing, so it can return no token: a token
  ;; describes text somebody read.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (put harness "rules" "RULE-0001" "id: RULE-0001")
      (let ((token (nth-value 1 (docstore-changed-since store nil))))
        (edit harness ref "id: DEC-0001 edited")
        (multiple-value-bind (changes next)
            (docstore-changed-since store token :contents nil)
          (is (equal (list ref) (changed-refs changes)) "~a: returned ~s" kind changes)
          (is (null (third (first changes))) "~a: text came back anyway" kind)
          (is (null next) "~a: a token came back" kind))
        (is (equal (list ref) (changed-refs (docstore-changed-since store token)))
            "~a: the :contents nil call changed what the token reports" kind)))))

(test a-document-that-cannot-be-read-comes-back-failed
  ;; The third change kind. A store that holds a document and cannot read it
  ;; has to say so: leaving it out reads as a clean store, and the caller would
  ;; record the index as current on a document it never saw. DOCSTORE-READ
  ;; signals for the same reason rather than returning empty text.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (readable (put harness "decisions" "DEC-0001" "id: DEC-0001"))
           (broken (put harness "decisions" "DEC-0002" "id: DEC-0002")))
      (break-document harness broken)
      (let ((changes (docstore-changed-since store nil)))
        (is (equal (list readable) (changed-refs changes))
            "~a: changed-since reported ~s as readable" kind (changed-refs changes))
        (is (equal (list broken)
                   (mapcar (lambda (change) (docstore-record-ref (second change)))
                           (changes-of :failed changes)))
            "~a: the unreadable document came back as ~s" kind changes)
        (is (every #'stringp (mapcar #'third (changes-of :failed changes)))
            "~a: a :failed entry carries no reason" kind))
      (signals error (docstore-read store broken)))))

(test known-only-reports-edits-and-removals-and-not-new-documents
  ;; INDEX-DRIFT's form. Drift is how far the index is behind on what it read;
  ;; a document nobody has read yet is `unindexed' instead, and counting it
  ;; here would count it twice.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (edited (put harness "decisions" "DEC-0001" "id: DEC-0001"))
           (removed (put harness "rules" "RULE-0001" "id: RULE-0001")))
      (put harness "plans" "PLAN-0001" "id: PLAN-0001")
      (let ((token (nth-value 1 (docstore-changed-since store nil))))
        (edit harness edited "id: DEC-0001 edited")
        (erase harness removed)
        (put harness "design" "DES-0001" "id: DES-0001")
        (let ((changes (docstore-changed-since store token :contents nil :known-only t)))
          (is (equal (list edited) (changed-refs changes))
              "~a: known-only reported ~s as changed" kind (changed-refs changes))
          (is (equal (list removed) (mapcar #'second (changes-of :removed changes)))
              "~a: known-only reported ~s" kind changes)
          (is (= 2 (length changes)) "~a: known-only reported ~s" kind changes))
        (is (null (docstore-changed-since store nil :contents nil :known-only t))
            "~a: a NIL token describes no document" kind)))))

;;;; ==================================================================
;;;; Phase 2, write
;;;; ==================================================================

(defparameter *plan-text*
  "id: PLAN-0001
title: a plan
status: draft
"
  "A document with a top-level status line, which a transition needs.")

(defun text-of (harness ref)
  (docstore-read (harness-store harness) ref))

(defun harness-addresses (harness)
  "Every address the store holds, sorted. Named for the harness because
test/file-store.lisp already has an ADDRESSES that takes a store."
  (sort (mapcar #'docstore-record-address
                (docstore-enumerate (harness-store harness)))
        #'string<))

(test a-write-replaces-the-text-and-moves-the-version
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001")))
      (multiple-value-bind (text version) (docstore-read store ref)
        (declare (ignore text))
        (let ((record (docstore-write store ref "id: DEC-0001 edited")))
          (is (string= "id: DEC-0001 edited" (text-of harness (docstore-record-ref record)))
              "~a: the write did not land" kind)
          (is (not (equalp version (docstore-record-version record)))
              "~a: the new record carries the version the document had before" kind))))))

(test a-write-with-a-stale-version-is-refused-and-the-store-is-unchanged
  ;; Compare-and-swap, which is the window DES-0051 D2 closes.
  ;; PLAN-DOCUMENT-EDIT reads a document and APPLY-DOCUMENT-EDIT writes it
  ;; later, and nothing checked that it had not moved in between.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001" "id: DEC-0001"))
           (version (nth-value 1 (docstore-read store ref))))
      (edit harness ref "id: DEC-0001 from somebody else")
      (signals docstore-conflict
        (docstore-write store ref "id: DEC-0001 from us" :expected-version version))
      (is (string= "id: DEC-0001 from somebody else" (text-of harness ref))
          "~a: the refused write changed the document anyway" kind))))

(test a-create-adds-a-document-and-a-taken-name-is-refused
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (record (docstore-create store "decisions" "DEC-0001" "id: DEC-0001")))
      (is (string= "docs/decisions/DEC-0001.yaml" (docstore-record-address record))
          "~a: created at ~a" kind (docstore-record-address record))
      (is (string= "id: DEC-0001" (text-of harness (docstore-record-ref record)))
          "~a: the created document does not read back" kind)
      (signals docstore-refused
        (docstore-create store "decisions" "DEC-0001" "id: DEC-0001 again"))
      (is (string= "id: DEC-0001" (text-of harness (docstore-record-ref record)))
          "~a: the refused create overwrote the document" kind))))

(test a-transition-sets-the-status-and-the-caller-uses-the-returned-ref
  ;; DES-0051 N3. Where the document goes is the store's business, and the two
  ;; stores answer differently: the file store's ref is the path and changes,
  ;; the in-memory store's ref is stable and only the address moves. A caller
  ;; that reads the new ref off the record works on both.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "plans" "PLAN-0001" *plan-text*))
           (record (docstore-transition store ref :final)))
      (is (string= "docs/plans/completed/PLAN-0001.yaml" (docstore-record-address record))
          "~a: a final plan landed at ~a" kind (docstore-record-address record))
      (is (search "status: final" (text-of harness (docstore-record-ref record)))
          "~a: the status line was not rewritten" kind)
      (is (equal (list (docstore-record-address record)) (harness-addresses harness))
          "~a: the store lists ~s" kind (harness-addresses harness))
      (let ((back (docstore-transition store (docstore-record-ref record) :draft)))
        (is (string= "docs/plans/PLAN-0001.yaml" (docstore-record-address back))
            "~a: a status that stops being terminal moved the document to ~a"
            kind (docstore-record-address back))
        (is (search "status: draft" (text-of harness (docstore-record-ref back)))
            "~a: the status line did not come back" kind)))))

(test a-category-with-no-terminal-status-never-moves
  ;; The three categories CON-0004 gives no terminal status: an accepted
  ;; decision is in force rather than finished, and filing it under a name
  ;; meaning done with these would bury it.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "decisions" "DEC-0001"
                     "id: DEC-0001
status: proposed
"))
           (record (docstore-transition store ref :accepted)))
      (is (string= "docs/decisions/DEC-0001.yaml" (docstore-record-address record))
          "~a: a decision moved to ~a" kind (docstore-record-address record)))))

(test a-document-with-no-status-line-is-refused-a-transition
  ;; Refused and not repaired. A document with no top-level status line may be
  ;; one whose type has no status at all -- a concept is -- and writing one in
  ;; would invent a field its author never wrote.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "plans" "PLAN-0001" "id: PLAN-0001
title: a plan with a summary that mentions status: draft
")))
      (signals docstore-refused (docstore-transition store ref :final))
      (is (equal '("docs/plans/PLAN-0001.yaml") (harness-addresses harness))
          "~a: the refused transition moved the document to ~s" kind (harness-addresses harness)))))

(test a-batch-that-plans-applies-every-entry-and-returns-a-record-for-each
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (plan (put harness "plans" "PLAN-0001" *plan-text*))
           (design (put harness "design" "DES-0001" "id: DES-0001
status: draft
")))
      (multiple-value-bind (records problems)
          (docstore-apply-batch store (list (list :transition plan :final)
                                            (list :write design "id: DES-0001 rewritten")))
        (is (null problems) "~a: ~s" kind problems)
        (is (= 2 (length records)) "~a: ~s" kind records)
        (is (equal '("docs/design/DES-0001.yaml" "docs/plans/completed/PLAN-0001.yaml")
                   (harness-addresses harness))
            "~a: the store holds ~s" kind (harness-addresses harness))
        (is (string= "id: DES-0001 rewritten"
                     (text-of harness (docstore-record-ref (second records))))
            "~a: the second entry did not land" kind)))))

(test a-refused-batch-writes-nothing-and-lists-every-problem
  ;; Every problem and not the first: an agent that has to run a command five
  ;; times to find five problems stops reading the fifth. Nothing is written,
  ;; which on the file store is what :PLANNED means and on the in-memory store
  ;; is what :ATOMIC means -- the two agree here and differ only once a write
  ;; has begun.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (plan (put harness "plans" "PLAN-0001" *plan-text*))
           (version (nth-value 1 (docstore-read store plan))))
      ;; Different text, not the same text written again: a file store's
      ;; version is a stamp over the bytes, so rewriting them unchanged inside
      ;; one second is not a change and would not conflict.
      (edit harness plan "id: PLAN-0001
title: a plan somebody else edited
status: draft
")
      (multiple-value-bind (records problems)
          (docstore-apply-batch store (list (list :transition plan :final
                                                  :expected-version version)
                                            (list :write "mem:nothing" "text")))
        (is (null records) "~a: a refused batch returned ~s" kind records)
        (is (= 2 (length problems)) "~a: ~s" kind problems)
        (is (search "changed after it was read" (first problems)) "~a: ~s" kind problems)
        (is (search "holds nothing under" (second problems)) "~a: ~s" kind problems)
        (is (equal '("docs/plans/PLAN-0001.yaml") (harness-addresses harness))
            "~a: the refused batch moved something" kind)
        (is (search "status: draft" (text-of harness plan))
            "~a: the refused batch wrote the status line" kind)))))

(test two-entries-of-one-batch-cannot-land-on-one-address
  ;; Each entry checked against the store alone would pass: neither
  ;; destination exists until the other entry writes it. A batch that lost one
  ;; of two documents would report success.
  (for-each-store (kind harness)
    (let ((store (harness-store harness)))
      (multiple-value-bind (records problems)
          (docstore-apply-batch store (list (list :create "plans" "PLAN-0001" *plan-text*)
                                            (list :create "plans" "PLAN-0001" *plan-text*)))
        (is (null records) "~a: ~s" kind records)
        (is (= 1 (length problems)) "~a: ~s" kind problems)
        (is (null (harness-addresses harness))
            "~a: the store holds ~s" kind (harness-addresses harness))))))

(test capabilities-name-every-write-operation-and-the-batch-guarantee
  (for-each-store (kind harness)
    (let ((capabilities (docstore-capabilities (harness-store harness))))
      (dolist (operation '(:write :create :transition))
        (is (eq :native (getf capabilities operation))
            "~a: ~s reads ~s" kind operation (getf capabilities operation)))
      (is (member (getf capabilities :batch) '(:atomic :planned))
          "~a: the batch guarantee reads ~s" kind (getf capabilities :batch)))))

;;;; ==================================================================
;;;; Phase 3, workflow
;;;; ==================================================================

(test allocate-id-is-the-highest-in-the-category-plus-one
  ;; A gap is never reused. Highest plus one and not lowest free, because
  ;; reusing a retired number makes an old reference point silently at new
  ;; content -- CON-0004 records that this has already cost a document its
  ;; place in the index.
  (for-each-store (kind harness)
    (let ((store (harness-store harness)))
      (is (string= "PLAN-0001" (docstore-allocate-id store "plans"))
          "~a: an empty category allocated ~a" kind (docstore-allocate-id store "plans"))
      (put harness "plans" "PLAN-0003" *plan-text*)
      (is (string= "PLAN-0004" (docstore-allocate-id store "plans"))
          "~a: with PLAN-0003 held, allocated ~a" kind
          (docstore-allocate-id store "plans"))
      (is (string= "DEC-0001" (docstore-allocate-id store "decisions"))
          "~a: a category is counted on its own" kind))))

(test allocating-does-not-take-the-id
  ;; Two calls with nothing between them answer the same, which is what
  ;; :SINGLE-WRITER means: the store hands out a number and records nothing,
  ;; so two writers get the same one. Asserted rather than left implicit,
  ;; because DES-0048's lease is the upgrade and this is the behaviour it
  ;; replaces.
  (for-each-store (kind harness)
    (let ((store (harness-store harness)))
      (is (string= (docstore-allocate-id store "plans")
                   (docstore-allocate-id store "plans"))
          "~a: the second call answered differently" kind)
      (is (eq :single-writer (getf (docstore-capabilities store) :allocate-id))
          "~a: allocate-id declares ~s" kind
          (getf (docstore-capabilities store) :allocate-id)))))

(test a-category-with-no-id-convention-is-refused-rather-than-invented
  ;; CON-0001. A document directory the workflow does not name has no prefix,
  ;; and making one out of the directory\'s spelling would mint ids nothing
  ;; else in the tree agrees with.
  (for-each-store (kind harness)
    ;; Computed before IS rather than inside it: FIVEAM's IS takes the form
    ;; apart to report its arguments, and a macro in that position has its
    ;; body evaluated outside the handler.
    (let ((refused (handler-case
                       (progn (docstore-allocate-id (harness-store harness) "notebooks") nil)
                     (docstore-refused () t))))
      (is-true refused "~a: a category with no prefix allocated an id" kind))))

(test may-transition-is-true-where-the-merge-is-the-approval
  ;; CON-0008. Neither of these stores has a permission model: whoever can
  ;; write the document can set its status, and a check here would be theatre
  ;; in front of an editor. The operation exists for a tracker, which answers
  ;; from its own model.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (ref (put harness "plans" "PLAN-0001" *plan-text*)))
      (is-true (docstore-may-transition store ref :final "anybody")
               "~a: refused a transition" kind))))

(defun operation-answer (store ref operation)
  "Three ways an operation can turn out: :ANSWERED, :REFUSED or :NO-METHOD."
  (let ((function (ecase operation
                    (:history 'docstore-history)
                    (:locate 'docstore-locate))))
    (if (null (compute-applicable-methods (fdefinition function) (list store ref)))
        :no-method
        (handler-case (progn (funcall function store ref) :answered)
          (docstore-error () :refused)))))

(test what-a-store-does-not-answer-it-declares-absent
  ;; DES-0051 D3, and the property that makes capabilities worth reading: what
  ;; the plist says is what happens at the call. :NATIVE answers. :ABSENT
  ;; either has no method or refuses -- what it must not do is return nothing
  ;; and let an empty history read like a document nothing ever touched
  ;; (CON-0001).
  ;;
  ;; Both outcomes are live here. The in-memory store has no DOCSTORE-HISTORY
  ;; method at all, and the file store has one that refuses, because a scratch
  ;; directory is not a git checkout.
  (for-each-store (kind harness)
    (let* ((store (harness-store harness))
           (capabilities (docstore-capabilities store))
           (ref (put harness "plans" "PLAN-0001" *plan-text*)))
      (dolist (operation '(:history :locate))
        (let ((outcome (operation-answer store ref operation)))
          (ecase (getf capabilities operation)
            (:native (is (eq :answered outcome)
                         "~a: ~s is :native and came back ~s" kind operation outcome))
            (:absent (is (member outcome '(:refused :no-method))
                         "~a: ~s is :absent and came back ~s" kind operation outcome))))))))
