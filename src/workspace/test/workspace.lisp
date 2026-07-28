;;;
;;; Tests for src/workspace/workspace.lisp -- the indexing pipeline.
;;;
;;; Level 1 in SS14.1's ordering: this runs the real analyzers over a real
;;; directory, so it is the first test that can tell you the pieces fit
;;; together. The fixture is a temporary repository rather than Loom itself,
;;; because these tests need to edit and delete files.
;;;

(in-package :loom-workspace-test)

(def-suite workspace
  :in all-tests
  :description "Indexing, resolution ordering, and change detection.")

(in-suite workspace)

(defparameter *fixture-root* nil)

(defun write-file (relative contents)
  (let ((path (merge-pathnames relative *fixture-root*)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    path))

(defun make-fixture-repository ()
  "A small two-file repository with a docs/ tree, in a fresh temp directory."
  (setf *fixture-root*
        (merge-pathnames (format nil "loom-fixture-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *fixture-root*)
  (write-file "src/alpha.lisp"
              "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
  (write-file "src/beta.lisp"
              "(defun beta (x) (alpha x))
")
  (write-file "docs/design/DEC-0001.yaml"
              "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
affects: [alpha]
rationale: |
  Keeping alpha-twice free of side effects makes it testable.
")
  (write-file "docs/rules/RULE-0001.yaml"
              "id: RULE-0001
type: rule
title: Nothing in src may call into docs
status: active
severity: error
check:
  kind: no-edge
  from-system: src
  to-system: docs
  rel-types: [calls]
")
  (watch-repository *fixture-root* :monitor nil :quiet t))

(defun cleanup-fixture ()
  (when *fixture-root*
    (ignore-errors (uiop:delete-directory-tree *fixture-root* :validate t))
    (setf *fixture-root* nil)))

(defmacro with-workspace-fixture ((repository) &body body)
  `(let ((,repository (make-fixture-repository)))
     (unwind-protect (progn ,@body)
       (unwatch-repository (repository-name ,repository))
       (cleanup-fixture))))

;;; ------------------------------------------------------------------
;;; Indexing (SS3.4)
;;; ------------------------------------------------------------------

(test watching-a-repository-indexes-source-and-documents-together
  (with-workspace-fixture (repository)
    (let ((g (repository-graph repository)))
      (is (= 3 (length (entities-of-type g :function))))
      (is (= 1 (length (entities-of-type g :decision))))
      (is (= 1 (length (entities-of-type g :rule)))
          "one watcher, one pipeline, both kinds of file"))))

(test the-pipeline-resolves-cross-file-calls
  ;; The reason the ordering in RESOLVE-AND-CHECK exists: beta calls alpha,
  ;; and no file-scoped analyzer can see that.
  (with-workspace-fixture (repository)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=))
           (callers (mapcar (lambda (r) (name (get-entity g (from-id r))))
                            (relationships-to g (id alpha) :rel-type :calls))))
      (is (member "beta" callers :test #'string=)
          "resolved across a file boundary")
      (is (member "alpha-twice" callers :test #'string=)
          "and within one"))))

(test the-pipeline-resolves-document-links
  (with-workspace-fixture (repository)
    (let* ((g (repository-graph repository))
           (decision (first (entities-of-type g :decision)))
           (targets (mapcar (lambda (r) (name (get-entity g (to-id r))))
                            (relationships-from g (id decision) :rel-type :decides))))
      (is (equal '("alpha") targets)))))

(test the-pipeline-runs-the-rule-checks
  (with-workspace-fixture (repository)
    (let ((g (repository-graph repository)))
      (is (null (entities-of-type g :rule-violation))
          "the fixture is clean, and a clean tree must report nothing"))))

(test status-reports-what-a-developer-needs-to-see
  (with-workspace-fixture (repository)
    (let ((status (repository-status repository)))
      (is (= 4 (getf status :files)))
      (is (plusp (getf status :entities)))
      (is (= 2 (getf status :documents)))
      (is (zerop (getf status :unresolved-references)))
      (is (zerop (getf status :errors))))))

;;; ------------------------------------------------------------------
;;; Change detection (SS8.3)
;;; ------------------------------------------------------------------

(test a-changed-file-is-reanalyzed
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
(defun alpha-thrice (x) (alpha (alpha-twice x)))
")
    (poll-once repository :quiet t)
    (is (= 4 (length (entities-of-type (repository-graph repository) :function))))))

(test a-deleted-definition-leaves-the-index
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp" "(defun alpha (x) (+ x 1))
")
    (poll-once repository :quiet t)
    (let ((names (mapcar #'name (entities-of-type (repository-graph repository)
                                                  :function))))
      (is (not (member "alpha-twice" names :test #'string=))
          "retract-file plus fresh asserts, driven by the monitor"))))

(test a-deleted-file-leaves-the-index
  (with-workspace-fixture (repository)
    (delete-file (merge-pathnames "src/beta.lisp" *fixture-root*))
    (poll-once repository :quiet t)
    (let ((g (repository-graph repository)))
      (is (null (find "beta" (entities-of-type g :function)
                      :key #'name :test #'string=)))
      (is (not (member "src/beta.lisp" (origin-files g) :test #'string=))))))

(test cross-file-edges-survive-a-reanalysis
  ;; The TODO that RETRACT-FILE-OP left open: retracting a file drops the
  ;; inbound cross-file edges, and only the pipeline's ordering puts them back.
  ;; This is the test that says the ordering is right.
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 2))
(defun alpha-twice (x) (alpha (alpha x)))
")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=)))
      (is (member "beta" (mapcar (lambda (r) (name (get-entity g (from-id r))))
                                 (relationships-to g (id alpha) :rel-type :calls))
                  :test #'string=)
          "beta -> alpha was destroyed by the retract and rebuilt by resolution"))))

;;; ------------------------------------------------------------------
;;; Rebuild equivalence (SS14.4)
;;; ------------------------------------------------------------------

(test reindexing-produces-an-identical-index
  ;; SS14.4 wants B and C "identical -- not merely equivalent, since ids are
  ;; derived from natural keys rather than generated".
  (with-workspace-fixture (repository)
    (let ((before (sort (mapcar #'id (all-entities (repository-graph repository)))
                        #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal before
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<))))))

(test an-incremental-update-matches-a-full-rebuild
  (with-workspace-fixture (repository)
    (write-file "src/beta.lisp" "(defun beta (x) (alpha-twice x))
")
    (poll-once repository :quiet t)
    (let ((incremental (sort (mapcar #'id (all-entities (repository-graph repository)))
                             #'string<))
          (edges-incremental
            (sort (mapcar #'id (all-relationships (repository-graph repository)))
                  #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal incremental
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<)))
      (is (equal edges-incremental
                 (sort (mapcar #'id (all-relationships (repository-graph repository)))
                       #'string<))
          "the highest-value assertion in the suite: the index agrees with
the files whichever way it got there"))))

;;; ------------------------------------------------------------------
;;; Failure containment (SS3.3)
;;; ------------------------------------------------------------------

(test a-file-that-will-not-parse-does-not-stop-the-pass
  (with-workspace-fixture (repository)
    (write-file "src/gamma.lisp" "(defun gamma (")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (gamma (find "src/gamma.lisp" (entities-of-type g :file)
                        :key #'name :test #'string=)))
      (is (not (null gamma)) "the file is indexed as a known unknown")
      (is-true (getp gamma :analysis-failed-p))
      (is (= 3 (length (entities-of-type g :function)))
          "and the rest of the repository is still there"))))

(test a-rule-violation-is-detected-and-recorded
  (with-workspace-fixture (repository)
    ;; Make src call into docs, which RULE-0001 forbids. A decision entity is
    ;; not callable, so the violation is manufactured directly on the graph.
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=))
           (target (make-instance 'function-entity
                                  :name "doc-helper"
                                  :origin-file "docs/design/DEC-0001.yaml"
                                  :properties (properties-table
                                               '(:file "docs/design/helper.lisp"
                                                 :start-line 1 :end-line 2)))))
      (add-entity g target)
      (add-relationship g (make-instance 'relationship :rel-type :calls
                                         :from-id (id alpha) :to-id (id target)
                                         :origin-file "src/alpha.lisp"))
      (apply-transaction g (violation-ops g))
      (is (= 1 (length (entities-of-type g :rule-violation))))
      (is (string= "RULE-0001" (getp (first (entities-of-type g :rule-violation))
                                     :rule-id))))))
