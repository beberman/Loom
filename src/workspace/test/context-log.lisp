;;;
;;; Tests for the retrieval log (REQ-0036, DES-0030).
;;;
;;; The record is the instrument the whole requirement exists to build, so what
;;; these assert is that it holds what a judgement needs and that it holds
;;; nothing when nobody asked for it. The second half is the tier argument: a
;;; :READ operation writes only where an operator turned it on, and a test that
;;; did not witness the off state would leave that claim unchecked.
;;;

(in-package :loom-workspace-test)

(def-suite context-log
  :in all-tests
  :description "One record per context call, and the feedback that completes it.")

(in-suite context-log)

(defmacro with-log-directory ((directory) &body body)
  "A throwaway log directory, bound and deleted."
  `(let ((,directory (merge-pathnames (format nil "loom-ctxlog-~a/" (random 100000))
                                      (uiop:temporary-directory))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,directory :validate t :if-does-not-exist :ignore))))

(defun log-fixture-repository (root)
  (write-document root "src/overlay.lisp"
                  (format nil "(in-package :app)~%(defun resolve-overlay (x) x)~%~
(defun reset-overlay () nil)~%"))
  (watch-tree root))

(test a-record-holds-what-a-judgement-needs
  (with-document-tree (root)
    (let ((repository (log-fixture-repository root)))
      (unwind-protect
           (with-log-directory (directory)
             (multiple-value-bind (bundle instrumentation)
                 (build-context (repository-graph repository) "resolve overlay")
               (let ((id (record-context-call repository bundle instrumentation
                                              :seconds 0.031
                                              :directory directory)))
                 (is (stringp id))
                 ;; The write is off the caller's path (REQ-0036 R8), so a test
                 ;; that wants the file says so.
                 (is-true (drain-context-log))
                 (let ((record (read-json-record (context-record-path id directory))))
                   (is (equal id (cdr (assoc :id record))))
                   (is (equal "resolve overlay" (cdr (assoc :task record))))
                   (is (consp (cdr (assoc :tokens record)))
                       "the tokens and not only the task: TASK-TOKENS is where
stopwords and stemming act, and a record holding the raw string cannot show
that the tokeniser dropped the discriminating word")
                   (let ((returned (cdr (assoc :returned record))))
                     (is (consp (cdr (assoc :seeds returned))))
                     (let ((seed (first (cdr (assoc :seeds returned)))))
                       (is (numberp (cdr (assoc :score seed)))
                           "a seed carries the number every ranking change moves")
                       (is (numberp (cdr (assoc :rank seed))))))
                   (let ((repo (cdr (assoc :repository record))))
                     (is (equal (repository-name repository)
                                (cdr (assoc :name repo)))))
                   (is (assoc :loom record)
                       "Loom's own fingerprint travels too, because the corpus
and the ranking move independently")))))
        (drop-tree repository)))))

(test with-no-directory-nothing-is-written-and-none-is-made
  ;; DES-0030 D1, and the half of the tier argument that has to be witnessed.
  ;; With *CONTEXT-LOG-DIRECTORY* NIL the operation is what it is today, so a
  ;; deployment that never enables logging never acquires a write.
  (with-document-tree (root)
    (let ((repository (log-fixture-repository root)))
      (unwind-protect
           (multiple-value-bind (bundle instrumentation)
               (build-context (repository-graph repository) "resolve overlay")
             (is (null (record-context-call repository bundle instrumentation
                                            :directory nil))
                 "no directory, no id, and nothing to write it to"))
        (drop-tree repository)))))

(test feedback-completes-the-record-and-may-name-what-was-not-returned
  ;; REQ-0036 R2. A feedback channel restricted to the returned items can never
  ;; record a miss, and the miss is the population that would raise recall.
  (with-document-tree (root)
    (let ((repository (log-fixture-repository root)))
      (unwind-protect
           (with-log-directory (directory)
             (multiple-value-bind (bundle instrumentation)
                 (build-context (repository-graph repository) "resolve overlay")
               (let* ((id (record-context-call repository bundle instrumentation
                                               :directory directory))
                      (drained (drain-context-log))
                      (completed
                        (record-context-use
                         id
                         (list (list :name "resolve-overlay" :how "returned")
                               (list :name "something-else"
                                     :how "grep -r overlay src"))
                         :directory directory)))
                 (is-true drained)
                 (let ((used (getf completed :used)))
                   (is (= 2 (length used)))
                   (is (find "something-else" used
                             :key (lambda (e) (cdr (assoc :name e)))
                             :test #'equal)
                       "an entity the bundle never returned is the record that
raises recall, and is kept")
                   (is (find "grep -r overlay src" used
                             :key (lambda (e) (cdr (assoc :how e)))
                             :test #'equal)
                       "how it was found travels with it: R3's three
populations imply different repairs"))
                 (is (equal "resolve overlay"
                            (cdr (assoc :task (getf completed :record))))
                     "and the first half is untouched, which is why it is a
second file: a record written once cannot be corrupted by its own
serialiser"))))
        (drop-tree repository)))))

(test an-id-no-record-has-is-refused-rather-than-created
  ;; A record minted because somebody quoted a wrong id is a judgement about a
  ;; query nobody asked -- CON-0001's fabricated fact wearing the shape of
  ;; evidence.
  (with-log-directory (directory)
    (signals context-record-error
      (record-context-use "ctx-nope" '() :directory directory))
    (is (null (probe-file (context-record-path "ctx-nope" directory))))
    (is (null (probe-file (context-use-path "ctx-nope" directory))))))

(test the-loom-root-is-the-tree-this-image-was-loaded-from
  (is (probe-file (merge-pathnames "src/workspace/workspace.lisp" (loom-root)))
      "not the current directory, which is whatever the operator started in"))

(test a-diff-hash-is-stable-and-a-missing-repository-is-a-reason
  (multiple-value-bind (hash reason) (loom-workspace::git-diff-hash (loom-root))
    (is (null reason))
    (is (stringp hash))
    (is (equal hash (loom-workspace::git-diff-hash (loom-root)))
        "asked twice of one tree, answered once"))
  (with-document-tree (root)
    (multiple-value-bind (commit reason) (loom-workspace::git-commit root)
      (is (null commit))
      (is (stringp reason)
          "a tree git cannot answer for is a recorded gap, never a fabricated
commit"))))

(test a-record-id-carries-its-timestamp-and-does-not-repeat
  ;; SBCL starts every image with the same *RANDOM-STATE*, so RANDOM-UUID mints
  ;; the same first UUID in every process. Measured before the fix: a console
  ;; call and a service call in two processes produced one id, and the second
  ;; record would have overwritten the first. What a test in one image can
  ;; witness is the timestamp and the non-repetition; the cross-process half was
  ;; measured by running the console twice and is recorded in PLAN-0035.
  (let ((first (loom-workspace::context-record-id))
        (second (loom-workspace::context-record-id)))
    (is (not (equal first second)))
    (dolist (id (list first second))
      (is (eql 0 (search "ctx-" id)))
      (is (find #\T id) "the timestamp is in the id, so a listing sorts by it")
      (is (> (length id) 20)))))
