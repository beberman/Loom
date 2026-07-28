;;;
;;; Tests for src/analyzer/yaml-analyzer.lisp -- the documentation analyzer
;;; of SS10, run against Loom's own docs/ tree.
;;;
;;; SS14.2 makes that tree the fixture deliberately: "Loom's own docs/ tree is
;;; not decoration. It is the level 1 test fixture, the source of the
;;; architectural rules the build enforces, and the first real evidence that a
;;; decision recorded by an agent in July is still findable."
;;;

(in-package :loom-analyzer-test)

(def-suite yaml-analyzer
  :in all-tests
  :description "The documentation analyzer over docs/.")

(in-suite yaml-analyzer)

(defparameter *repo-root*
  (asdf:system-relative-pathname :loom-analyzer "../../"))

(defun docs-ops (relative)
  "Ops for one document in Loom's own docs/ tree."
  (let ((path (merge-pathnames relative *repo-root*)))
    (analyze-file (make-instance 'document-analyzer)
                  (concatenate 'string "docs/" (subseq relative 5))
                  (slurp-file path)
                  "ws-test")))

(defun docs-entity (relative)
  (let ((g (make-graph)))
    (apply-transaction g (docs-ops relative))
    (first (remove-if-not (lambda (e) (member (entity-type e)
                                              '(:decision :rule :concept :document)))
                          (all-entities g)))))

;;; ------------------------------------------------------------------
;;; Dispatch (SS10.1)
;;; ------------------------------------------------------------------

(test the-document-analyzer-claims-yaml-under-docs-only
  (let ((a (make-instance 'document-analyzer)))
    (is-true  (analyzer-handles-p a "docs/design/DEC-0001.yaml"))
    (is-true  (analyzer-handles-p a "docs/rules/RULE-0001.yaml"))
    (is-false (analyzer-handles-p a ".github/workflows/ci.yaml")
              "a CI config is YAML too, and indexing it as engineering
knowledge would be worse than ignoring it")
    (is-false (analyzer-handles-p a "docs/design/notes.md"))))

(test the-directory-names-the-type
  (is (eq :decision (loom-analyzer::document-type-for "docs/design/DEC-0001.yaml")))
  (is (eq :rule     (loom-analyzer::document-type-for "docs/rules/RULE-0001.yaml")))
  (is (eq :concept  (loom-analyzer::document-type-for "docs/concepts/CON-0001.yaml")))
  (is (eq :document (loom-analyzer::document-type-for "docs/arch/overview.yaml"))))

(test an-unregistered-directory-is-indexed-not-ignored
  ;; SS10.1: "a documentation directory that Loom is quietly skipping is
  ;; exactly the kind of thing that erodes trust in the graph"
  (multiple-value-bind (type registered)
      (loom-analyzer::document-type-for "docs/scratch/thoughts.yaml")
    (is (eq :document type))
    (is-false registered "and reported, so the gap is visible")))

;;; ------------------------------------------------------------------
;;; A decision (SS10.3)
;;; ------------------------------------------------------------------

(test a-decision-becomes-an-entity-keyed-by-its-document-id
  (let ((e (docs-entity "docs/design/DEC-0001.yaml")))
    (is (eq :decision (entity-type e)))
    (is (string= "DEC-0001" (getp e :doc-id)))
    (is (string= "DEC-0001" (name e)))
    (is (eq :accepted (getp e :status)))
    (is (string= "docs/design/DEC-0001.yaml" (origin-file e)))
    (is (eq :human-validated (source e))
        "a human wrote this down; it is not an inference")))

(test a-decision-keeps-its-prose
  (let ((e (docs-entity "docs/design/DEC-0001.yaml")))
    (is (search "index over files" (getp e :rationale)))
    (is (search "durability requirement" (getp e :consequences)))
    (is (search "index over files" (getp e :body))
        ":body is what an agent reads when it wants the reasoning")))

(test a-decision-carries-its-declared-references-unresolved
  ;; The analyzer has no index, so affects: rides through as raw names for
  ;; LOOM-GRAPH:RESOLVE-DOCUMENT-LINKS to link (SS10.3).
  (let ((e (docs-entity "docs/design/DEC-0001.yaml")))
    (is (member "apply-transaction" (getp e :affects) :test #'string=))
    (is (member "retract-file" (getp e :affects) :test #'string=))))

(test a-decision-records-what-its-prose-mentions
  (let ((e (docs-entity "docs/design/DEC-0002.yaml")))
    (is (member "id-derived-p" (getp e :mentions) :test #'string=)
        "identifier-shaped tokens in prose become candidate inferred links")
    (is (not (member "the" (getp e :mentions) :test #'string=))
        "and English words do not, or the real hits would be buried")))

;;; ------------------------------------------------------------------
;;; A rule and its check clause (SS10.4)
;;; ------------------------------------------------------------------

(test a-rule-compiles-its-check-clause
  (let ((e (docs-entity "docs/rules/RULE-0001.yaml")))
    (is (eq :rule (entity-type e)))
    (is (string= "RULE-0001" (getp e :doc-id)))
    (is (eq :error (getp e :severity)))
    (is (eq :active (getp e :status)))
    (let ((check (getp e :check)))
      (is (eq :no-edge (getf check :kind)))
      (is (eq :ontology (getf check :from-system)))
      (is (eq :outside (getf check :to-system)))
      (is (equal '(:calls :imports :depends-on) (getf check :rel-types))))))

(test a-rule-with-no-recognisable-check-stays-prose
  ;; SS10.4: such a rule "remains valid as prose with severity advisory; it is
  ;; not enforced". It must still index -- refusing the document would lose the
  ;; statement entirely.
  (let* ((ops (analyze-file (make-instance 'document-analyzer)
                            "docs/rules/RULE-9999.yaml"
                            "id: RULE-9999
type: rule
title: Prefer clarity
severity: advisory
statement: |
  Write for the next reader.
check:
  kind: vibes
"
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((e (first (entities-of-type g :rule))))
      (is (not (null e)) "the rule is indexed even though its check is not usable")
      (is (null (getp e :check)))
      (is (eq :advisory (getp e :severity))))))

;;; ------------------------------------------------------------------
;;; Malformed input (SS3.3, SS9.3)
;;; ------------------------------------------------------------------

(test an-unparsable-document-is-marked-not-dropped
  (let* ((ops (analyze-file (make-instance 'document-analyzer)
                            "docs/design/broken.yaml"
                            "id: [unclosed" "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((e (first (entities-of-type g :document))))
      (is (not (null e)))
      (is (stringp (getp e :analysis-error))
          "a known unknown beats an absence an agent cannot explain"))))

(test a-document-that-is-not-a-mapping-is-a-validation-error
  (signals document-error (parse-document "- just" "docs/design/list.yaml")))

;;; ------------------------------------------------------------------
;;; Every pass opens with a retract (SS5.4)
;;; ------------------------------------------------------------------

(test a-document-pass-opens-by-clearing-the-file
  (is (typep (first (docs-ops "docs/rules/RULE-0001.yaml")) 'retract-file-op)))

(test reindexing-a-document-is-a-no-op
  (let ((g (make-graph)))
    (apply-transaction g (docs-ops "docs/design/DEC-0001.yaml"))
    (let ((ids (mapcar #'id (all-entities g))))
      (apply-transaction g (docs-ops "docs/design/DEC-0001.yaml"))
      (is (equal ids (mapcar #'id (all-entities g)))))))
