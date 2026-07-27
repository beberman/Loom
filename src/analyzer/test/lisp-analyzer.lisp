;;;
;;; Tests for src/analyzer/lisp-analyzer.lisp -- the reader-based Lisp
;;; analyzer, run against test/fixtures/sample.lisp.
;;;
;;; The analyzer's contract is a list of ontology operations (SS8.1), so the
;;; tests come in two halves: what it emits, and what the Graph Manager makes
;;; of it. The second half is the one that matters -- an op list nobody can
;;; apply is not a fact -- which is why this test system depends on
;;; LOOM-GRAPH even though LOOM-ANALYZER must not.
;;;

(in-package :loom-analyzer-test)

(def-suite lisp-analyzer
  :in all-tests
  :description "ANALYZE-FILE against a small synthetic fixture.")

(in-suite lisp-analyzer)

(defparameter *fixture-path*
  (asdf:system-relative-pathname :loom-analyzer "test/fixtures/sample.lisp"))

(defparameter *fixture-relative* "test/fixtures/sample.lisp"
  "What the analyzer is handed as PATH -- workspace-relative and
forward-slashed, as :FILE's :PATH property is specified to be.")

(defun fixture-ops ()
  "A fresh batch of ops for the fixture. Fresh every call, with fresh ids:
that is what makes the idempotence test below meaningful."
  (analyze-file (make-instance 'lisp-analyzer)
                *fixture-relative*
                (slurp-file *fixture-path*)
                "ws-test"))

(defun find-by-name (graph type name)
  (find name (entities-of-type graph type) :key #'name :test #'string=))

(defun analyze-fixture ()
  "A graph with one analysis pass applied, and the file entity it produced."
  (let ((g (make-graph)))
    (apply-transaction g (fixture-ops))
    (values g (find-by-name g :file *fixture-relative*))))

;;; ------------------------------------------------------------------
;;; What the analyzer emits
;;; ------------------------------------------------------------------

(test analyze-file-returns-ontology-operations
  (let ((ops (fixture-ops)))
    (is (not (null ops)))
    (is (every (lambda (op) (typep op 'ontology-op)) ops)
        "an analyzer's whole output is operations -- SS8.1")
    (is (typep (first ops) 'retract-file-op)
        "SS5.4: every pass opens by clearing the file, so a deleted definition
leaves the index")
    (is (typep (second ops) 'assert-entity-op)
        "then the file assert, so edges naming it can resolve")
    (is (eq :file (entity-type (op-entity (second ops)))))))

(test every-fact-records-the-file-it-was-read-from
  ;; SS5.1 makes origin-file mandatory, and SS14.3 asserts its presence as an
  ;; architectural invariant.
  (dolist (op (fixture-ops))
    (typecase op
      (assert-entity-op
       (is (equal *fixture-relative* (origin-file (op-entity op)))
           "~a has no origin file" (name (op-entity op))))
      (assert-relationship-op
       (is (equal *fixture-relative* (origin-file (op-rel op))))))))

(test an-unreadable-file-is-indexed-as-a-known-unknown
  ;; SS9.3 / SS3.3: a file that could not be parsed is marked, not omitted --
  ;; and the condition must not escape to take the watcher thread down.
  (let* ((ops (analyze-file (make-instance 'lisp-analyzer)
                            "broken.lisp"
                            "(defun ok () 1)~%(defun broken (" ; unbalanced
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((file (find-by-name g :file "broken.lisp")))
      (is (not (null file)) "the file is asserted even though it did not parse")
      (is-true (getp file :analysis-failed-p))
      (is (stringp (getp file :analysis-error)))
      (is (null (entities-of-type g :function))
          "and nothing is guessed at from a file that could not be read"))))

(test analyze-file-stamps-the-workspace-onto-every-op
  (is (every (lambda (op) (equal "ws-test" (workspace-id op))) (fixture-ops))))

(test an-entity-id-is-derived-so-a-rebuild-lands-on-the-same-one
  ;; SS14.4 asserts an incrementally updated index and an independently
  ;; rebuilt one are identical. Two independent analysis passes are the
  ;; smallest case of that.
  (let ((a (make-graph)) (b (make-graph)))
    (apply-transaction a (fixture-ops))
    (apply-transaction b (fixture-ops))
    (is (equal (sort (mapcar #'id (all-entities a)) #'string<)
               (sort (mapcar #'id (all-entities b)) #'string<)))))

;;; ------------------------------------------------------------------
;;; What the graph makes of them
;;; ------------------------------------------------------------------

(test analyze-file-creates-a-file-entity
  (multiple-value-bind (g file) (analyze-fixture)
    (is (not (null file)))
    (is (eq :file (entity-type file)))
    (is (string= *fixture-relative* (getp file :path)))
    (is (eq :lisp (getp file :language)))
    (is (eql 14 (getp file :line-count)))
    (is (eq file (get-entity g (id file))))))

(test analyze-file-creates-a-function-entity-per-defun
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (= 3 (length (entities-of-type g :function))))
    (is (not (null (find-by-name g :function "add-on"))))
    (is (not (null (find-by-name g :function "triple-add-on"))))
    (is (not (null (find-by-name g :function "summarize"))))))

(test analyze-file-records-correct-line-spans
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (let ((add-on (find-by-name g :function "add-on")))
      (is (eql 6 (getp add-on :start-line)))
      (is (eql 7 (getp add-on :end-line))))
    (let ((summarize (find-by-name g :function "summarize")))
      (is (eql 12 (getp summarize :start-line)))
      (is (eql 14 (getp summarize :end-line))))))

(test analyze-file-parses-arguments
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (equal '("x") (getp (find-by-name g :function "add-on") :arguments)))))

(test analyze-file-creates-a-variable-entity-per-defparameter
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (= 1 (length (entities-of-type g :variable))))
    (let ((tally (find-by-name g :variable "*tally*")))
      (is (not (null tally)))
      (is (eq :special (getp tally :kind)))
      (is (eql 3 (getp tally :start-line))))))

(test analyze-file-creates-contains-edges-from-the-file
  (multiple-value-bind (g file) (analyze-fixture)
    (let ((contained-ids (mapcar #'to-id (relationships-from g (id file) :rel-type :contains))))
      (is (= 4 (length contained-ids))
          "3 functions + 1 variable")
      (is (member (id (find-by-name g :function "add-on")) contained-ids :test #'equal))
      (is (member (id (find-by-name g :variable "*tally*")) contained-ids :test #'equal)))))

(test analyze-file-creates-calls-edges-between-local-functions
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (let* ((add-on (find-by-name g :function "add-on"))
           (triple (find-by-name g :function "triple-add-on"))
           (summarize (find-by-name g :function "summarize")))
      (is (equal (list (id add-on))
                 (mapcar #'to-id (relationships-from g (id triple) :rel-type :calls)))
          "triple-add-on calls add-on three times but must produce one edge")
      (is (equal (list (id triple))
                 (mapcar #'to-id (relationships-from g (id summarize) :rel-type :calls))))
      (is (null (relationships-from g (id add-on) :rel-type :calls))))))

(test analyze-file-does-not-record-calls-to-the-standard-library
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (null (find-by-name g :function "format")))
    (is (null (find-by-name g :function "incf")))))

;;; ------------------------------------------------------------------
;;; Determinism (SS12.4)
;;;
;;; "Re-analyzing an unchanged file produces an operation set that applies as
;;; a no-op, which is what verifies the upsert natural keys of SS4.4." The
;;; analyzer is stateless and mints fresh uuids every pass, so this only holds
;;; if the natural keys are doing their job -- both for the entities and for
;;; the edges, whose endpoints have to be remapped onto the surviving ids.
;;; ------------------------------------------------------------------

(test re-analyzing-an-unchanged-file-applies-as-a-no-op
  (let ((g (make-graph)))
    (apply-transaction g (fixture-ops))
    (let ((entities (length (all-entities g)))
          (edges    (length (all-relationships g)))
          (ids      (sort (mapcar #'id (all-entities g)) #'string<)))
      (apply-transaction g (fixture-ops))
      (is (= entities (length (all-entities g)))
          "a second pass must upsert, not duplicate")
      (is (= edges (length (all-relationships g)))
          "edges must be remapped onto the surviving entities, not re-inserted")
      (is (equal ids (sort (mapcar #'id (all-entities g)) #'string<))
          "ids are stable across re-analysis, so nothing pointing at them breaks"))))

;;; ------------------------------------------------------------------
;;; Dispatch (SS8.1)
;;; ------------------------------------------------------------------

(test lisp-analyzer-claims-lisp-source-only
  (let ((a (make-instance 'lisp-analyzer)))
    (is-true  (analyzer-handles-p a "src/graph/transaction.lisp"))
    (is-true  (analyzer-handles-p a "src/graph/loom-graph.asd"))
    (is-false (analyzer-handles-p a "src/ui/DrawingTool.tsx"))
    (is-false (analyzer-handles-p a "README.md"))
    (is-false (analyzer-handles-p a "Makefile"))))

(test find-analyzer-routes-a-lisp-file-to-the-lisp-analyzer
  (is (typep (find-analyzer "src/ontology/root-ontology.lisp") 'lisp-analyzer))
  (is (null (find-analyzer "src/ui/DrawingTool.tsx"))
      "no TypeScript analyzer is registered yet, and NIL is how a caller
sweeping a mixed tree learns to skip the file"))
