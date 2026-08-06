;;;
;;; Tests for src/graph/query.lisp -- the SS5.3 query protocol and the SS9
;;; impact engine.
;;;
;;; The fixture is a hand-built miniature of what the analyzer produces, using
;;; the real taxonomy rather than test-only types: the point of these tests is
;;; that the SS9 table as declared in code-ontology.lisp produces the traversal
;;; SS9 describes, so substituting fixture relationship types would test
;;; nothing.
;;;

(in-package :loom-graph-test)

(def-suite query
  :in all-tests
  :description "FIND-ENTITIES, NEIGHBORS, and IMPACT-SET.")

(in-suite query)

;;; ------------------------------------------------------------------
;;; Fixture
;;;
;;;   file.lisp  --contains-->  alpha, beta, gamma
;;;   beta       --calls------>  alpha
;;;   gamma      --calls------>  beta
;;;   alpha-test --tests------>  alpha
;;;   notes.md   --documents-->  alpha
;;;   ADR-1      --decides---->  alpha
;;;
;;; So changing ALPHA reaches BETA (1 hop), GAMMA (2 hops), and its own file;
;;; and collects one test, one document, and one decision.
;;; ------------------------------------------------------------------

(defun q-function (name start &optional (file "file.lisp"))
  (make-instance 'function-entity :name name :origin-file file
                 :properties (properties-table
                              (list :file file :start-line start
                                    :end-line (+ start 3) :language :lisp))))

(defun q-edge (graph type from to &key stale)
  (let ((r (make-instance 'relationship :rel-type type
                                        :from-id (id from) :to-id (id to)
                                        :origin-file (origin-file from)
                                        :stale-p stale)))
    (add-relationship graph r)
    r))

(defstruct (q-fixture (:conc-name q-) (:constructor %make-q-fixture))
  graph file alpha beta gamma test doc adr)

(defun make-q-fixture (&key stale-gamma)
  "The fixture above. STALE-GAMMA marks the gamma->beta call stale, which is
how the SS9 rule about facts reached only through a stale edge is exercised."
  (let* ((g (make-graph))
         (file (make-instance 'file-entity :name "file.lisp"
                              :origin-file "file.lisp"
                              :properties (properties-table
                                           '(:path "file.lisp" :language :lisp))))
         (alpha (q-function "alpha" 10))
         (beta  (q-function "beta" 20))
         (gamma (q-function "gamma" 30))
         (test  (make-instance 'test-entity :name "alpha-test"
                               :origin-file "file-test.lisp"
                               :properties (properties-table
                                            '(:file "file-test.lisp"
                                              :start-line 1 :end-line 5))))
         (doc   (make-instance 'document-entity :name "notes.md"
                               :origin-file "notes.md"
                               :properties (properties-table '(:path "notes.md"))))
         (adr   (make-instance 'decision-entity :name "ADR-1"
                               :origin-file "docs/design/ADR-1.yaml"
                               :properties (properties-table
                                            '(:doc-id "ADR-1"
                                              :decision "Alpha stays synchronous.")))))
    (dolist (e (list file alpha beta gamma test doc adr)) (add-entity g e))
    (dolist (member (list alpha beta gamma)) (q-edge g :contains file member))
    (q-edge g :calls beta alpha)
    (q-edge g :calls gamma beta :stale stale-gamma)
    (q-edge g :tests test alpha)
    (q-edge g :documents doc alpha)
    (q-edge g :decides adr alpha)
    (%make-q-fixture :graph g :file file :alpha alpha :beta beta :gamma gamma
                     :test test :doc doc :adr adr)))

(defun impacted-names (result)
  (sort (mapcar (lambda (e) (name (impact-entry-entity e)))
                (impact-result-impacted result))
        #'string<))

;;; ------------------------------------------------------------------
;;; find-entities (SS5.3)
;;; ------------------------------------------------------------------

(test find-entities-with-no-criteria-returns-everything
  (is (= 7 (length (find-entities (q-graph (make-q-fixture)))))))

(test find-entities-filters-by-type
  (let ((g (q-graph (make-q-fixture))))
    (is (= 3 (length (find-entities g :entity-type :function))))
    (is (= 1 (length (find-entities g :entity-type :file))))))

(test find-entities-matches-a-name-substring-case-insensitively
  (let ((g (q-graph (make-q-fixture))))
    (is (equal '("alpha") (mapcar #'name (find-entities g :entity-type :function
                                                          :name-like "ALP"))))
    (is (null (find-entities g :name-like "no-such-thing")))))

(test find-entities-filters-by-property
  (let ((g (q-graph (make-q-fixture))))
    (is (= 3 (length (find-entities g :property-filters '(:file "file.lisp")))))
    (is (null (find-entities g :property-filters '(:file "elsewhere.lisp"))))))

(test find-entities-excludes-stale-entities-unless-asked
  (let* ((f (make-q-fixture))
         (g (q-graph f)))
    (setf (stale-p (q-gamma f)) t)
    (is (= 2 (length (find-entities g :entity-type :function))))
    (is (= 3 (length (find-entities g :entity-type :function :include-stale t))))))

;;; ------------------------------------------------------------------
;;; neighbors (SS5.3)
;;; ------------------------------------------------------------------

(test neighbors-finds-both-directions-by-default
  (let* ((f (make-q-fixture))
         (found (neighbors (q-graph f) (id (q-alpha f)))))
    ;; in: contains from file, calls from beta, tests, documents, decides
    (is (= 5 (length found)))
    (is (every (lambda (n) (eq :in (neighbor-direction n))) found))))

(test neighbors-can-restrict-direction-and-type
  (let* ((f (make-q-fixture))
         (g (q-graph f)))
    (is (= 3 (length (neighbors g (id (q-file f)) :direction :out))))
    (is (null (neighbors g (id (q-file f)) :direction :in)))
    (let ((callers (neighbors g (id (q-alpha f)) :rel-types '(:calls) :direction :in)))
      (is (= 1 (length callers)))
      (is (string= "beta" (name (neighbor-entity (first callers))))))))

;;; ------------------------------------------------------------------
;;; impact-set (SS9)
;;; ------------------------------------------------------------------

(test impact-returns-nil-for-an-unknown-entity
  (is (null (impact-set (make-graph) "no-such-id"))))

(test impact-propagates-calls-transitively-against-the-edge
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f)))))
    (is (equal '("beta" "file.lisp" "gamma") (impacted-names result))
        "beta calls alpha; gamma calls beta; the file contains alpha")
    (let ((by-name (lambda (n) (find n (impact-result-impacted result)
                                     :key (lambda (e) (name (impact-entry-entity e)))
                                     :test #'string=))))
      (is (= 1 (impact-entry-depth (funcall by-name "beta"))))
      (is (= 2 (impact-entry-depth (funcall by-name "gamma")))
          "distance must be recorded so agents can rank near impact first"))))

(test impact-does-not-propagate-away-from-the-changed-entity
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-gamma f)))))
    (is (null (remove "file.lisp" (impacted-names result) :test #'string=))
        "nothing calls gamma, so only its container is impacted")))

(test impact-records-the-path-it-arrived-by
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f))))
         (gamma (find "gamma" (impact-result-impacted result)
                      :key (lambda (e) (name (impact-entry-entity e)))
                      :test #'string=)))
    (is (equal '(:calls :calls) (mapcar #'hop-rel-type (impact-entry-path gamma))))
    (is (equal (list (id (q-beta f)) (id (q-gamma f)))
               (mapcar #'hop-entity-id (impact-entry-path gamma)))
        "the path names the entities impact ran through, not just the hop count")))

(test impact-containment-is-one-step-not-transitive
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f)))))
    (is (member "file.lisp" (impacted-names result) :test #'string=)
        "a changed function marks its file")
    (is (= 1 (count "file.lisp" (impacted-names result) :test #'string=)))
    (is (= 3 (length (impact-result-impacted result)))
        "the file must not then drag in everything else it contains")))

(test impact-honours-max-depth
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f)) :max-depth 1)))
    (is (equal '("beta" "file.lisp") (impacted-names result))
        "gamma is two calls away and must be cut off")
    (is-true (impact-result-truncated-p result)
             "a caller has to be able to tell a boundary from an exhausted graph")))

(test impact-clamps-max-depth-to-the-specified-ceiling
  (let ((f (make-q-fixture)))
    (is (equal (impacted-names (impact-set (q-graph f) (id (q-alpha f)) :max-depth 500))
               (impacted-names (impact-set (q-graph f) (id (q-alpha f))
                                           :max-depth *max-impact-depth*))))))

(test impact-collects-tests-and-documents-into-their-own-fields
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f)))))
    (is (equal '("alpha-test") (mapcar #'name (impact-result-tests result))))
    (is (equal '("notes.md") (mapcar #'name (impact-result-documents result))))
    (is (equal '("ADR-1") (mapcar #'name (impact-result-decisions result))))
    (is (null (intersection '("alpha-test" "notes.md" "ADR-1") (impacted-names result)
                            :test #'string=))
        "SS9 gathers these separately rather than inflating the impact count")))

(test impact-can-omit-tests-and-documents
  (let* ((f (make-q-fixture))
         (result (impact-set (q-graph f) (id (q-alpha f))
                             :include-tests nil :include-docs nil)))
    (is (null (impact-result-tests result)))
    (is (null (impact-result-documents result)))
    (is (equal '("ADR-1") (mapcar #'name (impact-result-decisions result)))
        "decisions are not covered by either flag")))

(test impact-excludes-stale-edges-but-reports-what-they-led-to
  (let* ((f (make-q-fixture :stale-gamma t))
         (result (impact-set (q-graph f) (id (q-alpha f)))))
    (is (not (member "gamma" (impacted-names result) :test #'string=))
        "a stale edge must not carry impact")
    (is (equal '("gamma") (mapcar #'name (impact-result-possibly-affected result)))
        "but what it led to must not silently disappear either")))

;;; ------------------------------------------------------------------
;;; entity-system and edges-between-systems (SS6.3, ARCH-0009)
;;;
;;; A fixture states its :system literally rather than encoding it in a path.
;;; That is not a convenience: ENTITY-SYSTEM no longer parses paths at all, so
;;; the analyzer is the only thing that could turn one into a system, and
;;; loom-graph/test must not depend on loom-analyzer to build a fixture --
;;; that would invert the layering for a test helper's sake. The real file
;;; paths stay so the fixtures still read as statements about this tree; they
;;; simply no longer drive the classification.
;;;
;;; The three path-parsing tests that lived here were ported to
;;; src/analyzer/test/analyzer.lisp, where the computation moved. Deleting
;;; rather than leaving them is what makes ARCH-0009's "one copy, not two"
;;; true of the tests as well as of the function.
;;; ------------------------------------------------------------------

(defun sys-function (name file system)
  (make-instance 'function-entity :name name :origin-file file
                 :properties (properties-table (list :file file :start-line 1
                                                     :end-line 2 :system system))))

(test entity-system-is-the-property-verbatim-or-nothing
  ;; Both halves matter. The second is what keeps EDGES-BETWEEN-SYSTEMS' "an
  ;; unplaceable endpoint is not evidence of a violation" clause honest: an
  ;; entity no analyzer placed has to read as unknown, not as some system.
  (is (eq :loom-knowledge
          (entity-system (sys-function "f" "src/knowledge/services.lisp"
                                       :loom-knowledge))))
  (is (null (entity-system (make-instance 'function-entity :name "f")))
      "no :system property is not a system"))

(test edges-between-systems-finds-a-real-cross-system-call
  ;; Two entities in different packages, a :calls edge between them, and a
  ;; query for exactly that boundary -- the shape RULE-0001 compiles to.
  (let* ((g (make-graph))
         (inner (sys-function "derive-id" "src/ontology/root-ontology.lisp"
                              :loom-ontology))
         (outer (sys-function "add-entity" "src/graph/graph-manager.lisp"
                              :loom-graph)))
    (dolist (e (list inner outer)) (add-entity g e))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id inner) :to-id (id outer)
                                       :origin-file "src/ontology/root-ontology.lisp"))
    (let ((found (edges-between-systems g :loom-ontology :outside
                                        :rel-types '(:calls))))
      (is (= 1 (length found)))
      (is (eq :loom-graph (entity-system outer))))))
