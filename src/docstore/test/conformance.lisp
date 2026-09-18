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
                   (make-file-docstore root :claim #'yaml-under-docs-p)
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
  (let ((store (make-memory-docstore)))
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
