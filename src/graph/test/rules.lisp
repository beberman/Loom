;;;
;;; Tests for src/graph/resolve.lisp document linking (SS10.3) and
;;; src/graph/rules.lisp rule checking (SS10.4).
;;;

(in-package :loom-graph-test)

(def-suite rules
  :in all-tests
  :description "RESOLVE-DOCUMENT-LINKS and the rule check kinds.")

(in-suite rules)

(defun rules-function (graph name file system)
  "A function fixture that says which system it is in.

SYSTEM is required rather than optional deliberately. ENTITY-SYSTEM reads a
property now (ARCH-0009 R7), so a fixture that omits it is unplaceable -- and
EDGES-BETWEEN-SYSTEMS treats an unplaceable endpoint as no evidence of a
violation, which means every :no-edge test below would pass by matching
nothing. The three tests here that assert NULL would pass that way too. Making
the argument impossible to forget is what keeps them evidence rather than
decoration (CON-0003)."
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 9
                                             :language :lisp :system system)))))
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
         (target (rules-function g "apply-transaction" "graph/transaction.lisp"
                                 :loom-graph))
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
         (target (rules-function g "resolve-overlay" "workspace/overlay.lisp"
                                 :loom-workspace))
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
         (inner (rules-function g "derive-id" "ontology/root-ontology.lisp"
                                :loom-ontology))
         (outer (rules-function g "add-entity" "graph/graph-manager.lisp"
                                :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id inner) :to-id (id outer)
                                       :origin-file "ontology/root-ontology.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :loom-ontology
                             :to-system :outside :rel-types (:calls)))
    (let ((violations (check-rules g)))
      (is (= 1 (length violations)))
      (is (string= "RULE-1" (violation-rule-id (first violations))))
      (is (search "derive-id" (violation-detail (first violations)))))))

(test the-no-edge-check-passes-a-clean-tree
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/root-ontology.lisp"
                            :loom-ontology))
         (b (rules-function g "entity-natural-key" "ontology/root-ontology.lisp"
                            :loom-ontology)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/root-ontology.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :loom-ontology
                             :to-system :outside :rel-types (:calls)))
    (is (null (check-rules g))
        "an edge inside the system is exactly what the rule permits")))

;;; These four repeat RULE-0001 to RULE-0003 verbatim, by rule id and by the
;;; :from-system/:to-system values the real documents carry. What they guard is
;;; that those values and the :system the analyzer writes are one vocabulary --
;;; the failure ARCH-0009 R7/R8 could introduce, because ENTITY-SYSTEM's answer
;;; and a rule's from-system: are the two sides of one EQ comparison. Change
;;; either alone and every :no-edge check matches nothing, `check` prints "No
;;; violations.", and that reads as success. It is the same vacuous pass
;;; BUG-0006 closed, reached by a different route: there the two sides
;;; disagreed because ENTITY-SYSTEM answered :SRC for everything, here they
;;; would disagree because one side says :ANALYZER and the other :LOOM-ANALYZER.
;;;
;;; The fixtures name real packages, not path segments, because that is what
;;; :system now holds. The src/-shaped paths stay as documentation of which
;;; real file each fixture stands for; nothing reads them any more.

(test rule-0001-catches-ontology-calling-outside-under-the-real-src-layout
  (let* ((g (make-graph))
         (inner (rules-function g "derive-id" "src/ontology/root-ontology.lisp"
                                :loom-ontology))
         (outer (rules-function g "add-entity" "src/graph/graph-manager.lisp"
                                :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id inner) :to-id (id outer)
                                       :origin-file "src/ontology/root-ontology.lisp"))
    (rules-rule g "RULE-0001" '(:kind :no-edge :from-system :loom-ontology
                                :to-system :outside :rel-types (:calls :imports :depends-on)))
    (let ((violations (check-rules g)))
      (is (= 1 (length violations)))
      (is (string= "RULE-0001" (violation-rule-id (first violations)))))))

(test rule-0002-catches-an-analyzer-reaching-the-graph-under-the-real-src-layout
  (let* ((g (make-graph))
         (analyzer (rules-function g "analyze-file" "src/analyzer/lisp-analyzer.lisp"
                                   :loom-analyzer))
         (graph-fn (rules-function g "add-entity" "src/graph/graph-manager.lisp"
                                   :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id analyzer) :to-id (id graph-fn)
                                       :origin-file "src/analyzer/lisp-analyzer.lisp"))
    (rules-rule g "RULE-0002" '(:kind :no-edge :from-system :loom-analyzer
                                :to-system :loom-graph
                                :rel-types (:calls :imports :depends-on)))
    (is (= 1 (length (check-rules g))))))

(test rule-0003-catches-knowledge-writing-under-the-real-src-layout
  (let* ((g (make-graph))
         (service (rules-function g "describe-entity" "src/knowledge/services.lisp"
                                  :loom-knowledge))
         (writer (rules-function g "apply-transaction" "src/graph/transaction.lisp"
                                 :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id service) :to-id (id writer)
                                       :origin-file "src/knowledge/services.lisp"))
    (rules-rule g "RULE-0003" '(:kind :no-edge :from-system :loom-knowledge
                                :to-system :loom-graph :rel-types (:calls)))
    (is (= 1 (length (check-rules g))))))

(test the-real-rules-still-pass-a-clean-real-layout
  ;; The other half of each test above: an edge that stays inside its own
  ;; package must not trip the rule. Note this one asserts NULL, which a
  ;; broken ENTITY-SYSTEM satisfies too -- its evidence value comes entirely
  ;; from the three above failing when the vocabularies disagree.
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "src/ontology/root-ontology.lisp"
                            :loom-ontology))
         (b (rules-function g "entity-natural-key" "src/ontology/root-ontology.lisp"
                            :loom-ontology)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "src/ontology/root-ontology.lisp"))
    (rules-rule g "RULE-0001" '(:kind :no-edge :from-system :loom-ontology
                                :to-system :outside :rel-types (:calls :imports :depends-on)))
    (is (null (check-rules g)))))

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
    ;; Any system: the :requires-edge check kind does not read one.
    (rules-function g "lonely" "a.lisp" :loom-graph)
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
  ;; The fixtures are a real violation of the rule as written: what makes this
  ;; NULL is the :retired status alone, not an unplaceable endpoint.
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp" :loom-ontology))
         (b (rules-function g "add-entity" "graph/b.lisp" :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/a.lisp"))
    (rules-rule g "RULE-OLD" '(:kind :no-edge :from-system :loom-ontology
                               :to-system :outside :rel-types (:calls))
                :status :retired)
    (is (null (check-rules g)))))

;;; ------------------------------------------------------------------
;;; Violations as entities (SS10.4)
;;; ------------------------------------------------------------------

(test violations-are-asserted-so-they-can-be-queried
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp" :loom-ontology))
         (b (rules-function g "add-entity" "graph/b.lisp" :loom-graph)))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id a) :to-id (id b)
                                       :origin-file "ontology/a.lisp"))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :loom-ontology
                             :to-system :outside :rel-types (:calls)))
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))
    (is (= 1 (length (violations-of g "RULE-1"))))
    ;; and running the checks again does not double them
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))))

(test a-fixed-violation-stops-being-asserted
  (let* ((g (make-graph))
         (a (rules-function g "derive-id" "ontology/a.lisp" :loom-ontology))
         (b (rules-function g "add-entity" "graph/b.lisp" :loom-graph))
         (edge (add-relationship g (make-instance 'relationship :rel-type :calls
                                                  :from-id (id a) :to-id (id b)
                                                  :origin-file "ontology/a.lisp"))))
    (rules-rule g "RULE-1" '(:kind :no-edge :from-system :loom-ontology
                             :to-system :outside :rel-types (:calls)))
    (apply-transaction g (violation-ops g))
    (is (= 1 (length (entities-of-type g :rule-violation))))
    (remove-relationship g (id edge))          ; the offending call goes away
    (apply-transaction g (violation-ops g))
    (is (null (entities-of-type g :rule-violation))
        "violations are re-derived, not accumulated")))
