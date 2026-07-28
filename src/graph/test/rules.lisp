;;;
;;; Tests for src/graph/resolve.lisp document linking (SS10.3) and
;;; src/graph/rules.lisp rule checking (SS10.4).
;;;

(in-package :loom-graph-test)

(def-suite rules
  :in all-tests
  :description "RESOLVE-DOCUMENT-LINKS and the rule check kinds.")

(in-suite rules)

(defun rules-function (graph name file)
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 9
                                             :language :lisp)))))
    (add-entity graph e)
    e))

(defun rules-decision (graph doc-id &key affects mentions supersedes)
  (let ((e (make-instance 'decision-entity
                          :name doc-id
                          :origin-file (format nil "docs/design/~a.yaml" doc-id)
                          :source :human-validated
                          :properties (properties-table
                                       (list :doc-id doc-id
                                             :affects affects
                                             :mentions mentions
                                             :supersedes supersedes)))))
    (add-entity graph e)
    e))

(defun rules-rule (graph doc-id check &key (severity :error) (status :active))
  (let ((e (make-instance 'rule-entity
                          :name doc-id
                          :origin-file (format nil "docs/rules/~a.yaml" doc-id)
                          :properties (properties-table
                                       (list :doc-id doc-id :check check
                                             :severity severity :status status)))))
    (add-entity graph e)
    e))

;;; ------------------------------------------------------------------
;;; Declared links (SS10.3)
;;; ------------------------------------------------------------------

(test a-declared-reference-becomes-a-structural-edge
  (let* ((g (make-graph))
         (target (rules-function g "apply-transaction" "graph/transaction.lisp"))
         (decision (rules-decision g "DEC-1" :affects '("apply-transaction"))))
    (apply-transaction g (resolve-document-links g))
    (let ((edges (relationships-from g (id decision) :rel-type :decides)))
      (is (equal (list (id target)) (mapcar #'to-id edges)))
      (is (eq :structural (source (first edges)))
          "someone wrote this down deliberately")
      (is (= 1.0 (confidence (first edges)))))))

(test a-declared-reference-that-resolves-to-nothing-is-recorded
  ;; SS10.3: "A name that does not resolve is not dropped silently ... That
  ;; flag is the documentation staleness detector."
  (let* ((g (make-graph))
         (decision (rules-decision g "DEC-1" :affects '("function-deleted-last-week"))))
    (apply-transaction g (resolve-document-links g))
    (is (equal '("function-deleted-last-week") (getp decision :unresolved-references)))
    (is (equal (list (cons "DEC-1" "function-deleted-last-week"))
               (unresolved-references g))
        "and it is countable, for status")))

(test supersedes-links-one-decision-to-another-by-document-id
  (let* ((g (make-graph))
         (old (rules-decision g "DEC-1"))
         (new (rules-decision g "DEC-2" :supersedes '("DEC-1"))))
    (apply-transaction g (resolve-document-links g))
    (is (equal (list (id old))
               (mapcar #'to-id (relationships-from g (id new) :rel-type :supersedes))))))

;;; ------------------------------------------------------------------
;;; Mentioned links (SS10.3)
;;; ------------------------------------------------------------------

(test a-prose-mention-becomes-an-inferred-edge
  (let* ((g (make-graph))
         (target (rules-function g "resolve-overlay" "workspace/overlay.lisp"))
         (decision (rules-decision g "DEC-1" :mentions '("resolve-overlay"))))
    (apply-transaction g (resolve-document-links g))
    (let ((edges (relationships-from g (id decision) :rel-type :documents)))
      (is (equal (list (id target)) (mapcar #'to-id edges)))
      (is (eq :inferred (source (first edges)))
          "nobody promised this link, so it must not claim structural certainty")
      (is (< (confidence (first edges)) 1.0))
      (is (equal (list (id target)) (derived-from (first edges)))
          "and derived-from is what makes it go stale when the code moves"))))

(test a-mention-that-resolves-to-nothing-is-simply-absent
  ;; Unlike a declared reference: nobody promised a prose token names anything,
  ;; so a miss is not evidence of rot and must not be reported as such.
  (let* ((g (make-graph))
         (decision (rules-decision g "DEC-1" :mentions '("something-else"))))
    (apply-transaction g (resolve-document-links g))
    (is (null (relationships-from g (id decision))))
    (is (null (getp decision :unresolved-references)))))

;;; ------------------------------------------------------------------
;;; no-edge (SS10.4)
;;; ------------------------------------------------------------------

(test the-no-edge-check-finds-a-layering-violation
  (let* ((g (make-graph))
         (inner (rules-function g "derive-id" "ontology/root-ontology.lisp"))
         (outer (rules-function g "add-entity" "graph/graph-manager.lisp")))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id inner) :to-id (id outer)
                                       :origin-file "ontology/root-ontology.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :ontology
                             :to-system :outside :rel-types (:calls)))
    (let ((violations (check-rules g)))
      (is (= 1 (length violations)))
      (is (string= "RULE-1" (violation-rule-id (first violations))))
      (is (search "derive-id" (violation-detail (first violations)))))))

(test the-no-edge-check-passes-a-clean-tree
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/root-ontology.lisp"))
         (b (rules-function g "entity-natural-key" "ontology/root-ontology.lisp")))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/root-ontology.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :ontology
                             :to-system :outside :rel-types (:calls)))
    (is (null (check-rules g))
        "an edge inside the system is exactly what the rule permits")))

;;; ------------------------------------------------------------------
;;; property-constraint (SS10.4, SS14.3)
;;; ------------------------------------------------------------------

(test the-property-constraint-check-catches-a-fact-with-no-origin-file
  (let ((g (make-graph)))
    (let ((e (make-instance 'function-entity :name "orphan"
                            :properties (properties-table
                                         '(:file "a.lisp" :start-line 1 :end-line 2)))))
      (add-entity g e))                    ; no :origin-file
    (rules-rule g "RULE-ORIGIN" '(:kind :property-constraint
                                  :entity-type :function :property :origin-file))
    (let ((violations (check-rules g)))
      (is (= 1 (length violations)))
      (is (search "origin-file is missing" (violation-detail (first violations)))))))

;;; ------------------------------------------------------------------
;;; requires-edge (SS10.4)
;;; ------------------------------------------------------------------

(test the-requires-edge-check-catches-an-unconnected-entity
  (let ((g (make-graph)))
    (rules-function g "lonely" "a.lisp")
    (rules-rule g "RULE-CONTAINED" '(:kind :requires-edge
                                     :entity-type :function :rel-types (:contains)))
    (is (= 1 (length (check-rules g))))))

;;; ------------------------------------------------------------------
;;; Enforcement bookkeeping (SS10.4)
;;; ------------------------------------------------------------------

(test a-rule-with-no-check-is-counted-as-unenforced
  (let ((g (make-graph)))
    (rules-rule g "RULE-PROSE" nil :severity :advisory)
    (is (null (check-rules g)))
    (is (equal '("RULE-PROSE") (mapcar (lambda (r) (getp r :doc-id))
                                       (unenforced-rules g)))
        "SS10.4 reports the count so prose-only drift stays visible rather
than comfortable")))

(test a-retired-rule-is-not-checked
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp"))
         (b (rules-function g "add-entity" "graph/b.lisp")))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/a.lisp"))
    (rules-rule g "RULE-OLD" '(:kind :no-edge :from-system :ontology
                               :to-system :outside :rel-types (:calls))
                :status :retired)
    (is (null (check-rules g)))))

;;; ------------------------------------------------------------------
;;; Violations as entities (SS10.4)
;;; ------------------------------------------------------------------

(test violations-are-asserted-so-they-can-be-queried
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp"))
         (b (rules-function g "add-entity" "graph/b.lisp")))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/a.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :ontology
                             :to-system :outside :rel-types (:calls)))
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))
    (is (= 1 (length (violations-of g "RULE-1"))))
    ;; and running the checks again does not double them
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))))

(test a-fixed-violation-stops-being-asserted
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp"))
         (b (rules-function g "add-entity" "graph/b.lisp"))
         (edge (add-relationship g (make-instance 'relationship :rel-type :calls
                                                  :from-id (id a) :to-id (id b)
                                                  :origin-file "ontology/a.lisp"))))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :ontology
                             :to-system :outside :rel-types (:calls)))
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))
    (remove-relationship g (id edge))          ; the offending call goes away
    (apply-transaction g (violation-ops g))
    (is (null (entities-of-type g :rule-violation))
        "violations are re-derived, not accumulated")))
