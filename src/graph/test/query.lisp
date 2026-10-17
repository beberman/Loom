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

(in-package :synoptik-graph-test)

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
                               :origin-file "docs/decisions/ADR-1.yaml"
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
;;; entity-system and edges-between-systems (SS6.3, DES-0009)
;;;
;;; A fixture states its :system literally rather than encoding it in a path.
;;; That is not a convenience: ENTITY-SYSTEM no longer parses paths at all, so
;;; the analyzer is the only thing that could turn one into a system, and
;;; synoptik-graph/test must not depend on synoptik-analyzer to build a fixture --
;;; that would invert the layering for a test helper's sake. The real file
;;; paths stay so the fixtures still read as statements about this tree; they
;;; simply no longer drive the classification.
;;;
;;; The three path-parsing tests that lived here were ported to
;;; src/analyzer/test/analyzer.lisp, where the computation moved. Deleting
;;; rather than leaving them is what makes DES-0009's "one copy, not two"
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
  (is (eq :synoptik-knowledge
          (entity-system (sys-function "f" "src/knowledge/services.lisp"
                                       :synoptik-knowledge))))
  (is (null (entity-system (make-instance 'function-entity :name "f")))
      "no :system property is not a system"))

(test edges-between-systems-finds-a-real-cross-system-call
  ;; Two entities in different packages, a :calls edge between them, and a
  ;; query for exactly that boundary -- the shape RULE-0001 compiles to.
  (let* ((g (make-graph))
         (inner (sys-function "derive-id" "src/ontology/root-ontology.lisp"
                              :synoptik-ontology))
         (outer (sys-function "add-entity" "src/graph/graph-manager.lisp"
                              :synoptik-graph)))
    (dolist (e (list inner outer)) (add-entity g e))
    (add-relationship g (make-instance 'relationship :rel-type :calls
                                       :from-id (id inner) :to-id (id outer)
                                       :origin-file "src/ontology/root-ontology.lisp"))
    (let ((found (edges-between-systems g :synoptik-ontology :outside
                                        :rel-types '(:calls))))
      (is (= 1 (length found)))
      (is (eq :synoptik-graph (entity-system outer))))))

;;; ------------------------------------------------------------------
;;; system-satisfies-p (DES-0024)
;;;
;;; The negatives carry this section. A family match that answers YES to its
;;; own members is easy and proves little; what REQ-0029 measured is that the
;;; obvious implementation -- a raw string prefix -- answers YES to four
;;; game-server packages and two cl-dbi packages that belong to no family, and
;;; that admitting `-' as a delimiter re-opens BUG-0009 cause one across all
;;; eight of Synoptik's production/test pairs. Every keyword below is a package
;;; name counted in one of those trees on 2026-08-15, not an invented one.
;;; ------------------------------------------------------------------

(test a-keyword-designator-is-still-exactly-eq
  ;; REQ-0029 R1. Every rule in docs/rules/ passes a keyword, so this is the
  ;; path that must not have moved.
  (is (system-satisfies-p :synoptik-graph :synoptik-graph))
  (is (not (system-satisfies-p :synoptik-graph :synoptik-knowledge)))
  (is (not (system-satisfies-p :synoptik-graph nil))
      "an unplaceable entity satisfies nothing"))

(test a-family-designator-takes-its-members-and-its-own-name
  (is (system-satisfies-p '(:family :game) :game/map))
  (is (system-satisfies-p '(:family :game) :game/system))
  (is (system-satisfies-p '(:family :game) :game)
      "the bare family name is in its own family")
  (is (system-satisfies-p '(:family :dbi) :dbi.driver))
  (is (system-satisfies-p '(:family :dbi) :dbi.cache.single)))

(test a-family-designator-refuses-a-name-that-merely-starts-the-same-way
  ;; The four game-server packages beginning with "game" that belong to no
  ;; family, and cl-dbi's two test packages beginning with "dbi". A raw string
  ;; prefix takes all six; this is the assertion that fails if the delimiter
  ;; anchor is ever dropped.
  (dolist (impostor '(:game-server :game-server-test :game-test :game-full-test))
    (is (not (system-satisfies-p '(:family :game) impostor))
        "a dash is not a hierarchy separator"))
  (dolist (impostor '(:dbi-test.dbi :dbi-test.driver))
    (is (not (system-satisfies-p '(:family :dbi) impostor)))))

(test a-family-designator-never-joins-a-test-package-to-its-production-package
  ;; BUG-0009 cause one, as a standing assertion. If #\- is ever added to
  ;; *SYSTEM-FAMILY-DELIMITERS* this test goes red for all eight of Synoptik's
  ;; pairs before anyone reindexes anything.
  (dolist (pair '((:synoptik-analyzer . :synoptik-analyzer-test)
                  (:synoptik-graph . :synoptik-graph-test)
                  (:synoptik-knowledge . :synoptik-knowledge-test)
                  (:synoptik-workspace . :synoptik-workspace-test)
                  (:synoptik-process . :synoptik-process-test)
                  (:synoptik-serve . :synoptik-serve-test)
                  (:synoptik-rest . :synoptik-rest-test)
                  (:synoptik-mcp . :synoptik-mcp-test)))
    (is (not (system-satisfies-p (list :family (car pair)) (cdr pair)))
        "the thirty-seven false positives DES-0009 closed stay closed")))

(test a-family-designator-nests
  ;; REQ-0029 R5, and it needs no code of its own: :DBD.MYSQL.ERROR begins
  ;; with DBD followed by a delimiter and with DBD.MYSQL followed by one.
  (is (system-satisfies-p '(:family :dbd) :dbd.mysql.error))
  (is (system-satisfies-p '(:family :dbd.mysql) :dbd.mysql.error))
  (is (not (system-satisfies-p '(:family :dbd.mysql) :dbd.postgres))))

(test outside-a-family-means-outside-the-family-not-outside-one-package
  ;; DES-0024 D2, and the clause without which a family rule is useless: the
  ;; fourteen game/* packages call each other constantly, and a rule that
  ;; reported every one of those has replaced fourteen rules with fourteen
  ;; thousand findings.
  (let* ((g (make-graph))
         (member-a (sys-function "draw" "game/graphics.lisp" :game/graphics))
         (member-b (sys-function "tile-at" "game/map.lisp" :game/map))
         (stranger (sys-function "db-select" "data-api/db/connection.lisp"
                                 :data-api)))
    (dolist (e (list member-a member-b stranger)) (add-entity g e))
    (dolist (target (list member-b stranger))
      (add-relationship g (make-instance 'relationship :rel-type :calls
                                         :from-id (id member-a) :to-id (id target)
                                         :origin-file "game/graphics.lisp")))
    (let ((found (edges-between-systems g '(:family :game) :outside
                                        :rel-types '(:calls))))
      (is (= 1 (length found))
          "the call to a sibling package is internal traffic")
      (is (equal (id stranger) (to-id (first found)))))))

;;; ------------------------------------------------------------------
;;; Filtering on a set of types (PLAN-0054 S1)
;;; ------------------------------------------------------------------

(test a-type-set-returns-its-members-and-excludes-the-rest
  (let ((g (make-graph)))
    (add-entity g (q-function "alpha" 10))
    (add-entity g (make-instance 'class-entity :name "Beta" :origin-file "f.lisp"
                                 :properties (properties-table
                                              '(:file "f.lisp" :start-line 1 :end-line 2))))
    (add-entity g (make-instance 'variable-entity :name "gamma" :origin-file "f.lisp"
                                 :properties (properties-table
                                              '(:file "f.lisp" :start-line 3 :end-line 3))))
    (let ((found (find-entities g :entity-types '(:function :class))))
      (is (= 2 (length found)) "~a" (mapcar #'name found))
      (is (null (find :variable found :key #'entity-type))
          "the type outside the set is excluded"))))

(test a-type-and-a-type-set-given-together-intersect
  ;; Neither wins. That is the only reading that cannot surprise a caller who
  ;; passed both by accident: an intersection can only narrow, where letting
  ;; one override the other would silently widen the answer.
  (let ((g (make-graph)))
    (add-entity g (q-function "alpha" 10))
    (add-entity g (make-instance 'class-entity :name "Beta" :origin-file "f.lisp"
                                 :properties (properties-table
                                              '(:file "f.lisp" :start-line 1 :end-line 2))))
    (is (= 1 (length (find-entities g :entity-type :function
                                      :entity-types '(:function :class))))
        "the intersection is the functions")
    (is (null (find-entities g :entity-type :variable
                               :entity-types '(:function :class)))
        "and a type outside the set intersects to nothing")))

(test no-type-set-is-no-filter
  ;; Every existing caller passes no ENTITY-TYPES, so the default must be
  ;; indistinguishable from the behaviour before this argument existed.
  (let ((g (make-graph)))
    (add-entity g (q-function "alpha" 10))
    (add-entity g (q-function "beta" 20))
    (is (= 2 (length (find-entities g))))
    (is (= 2 (length (find-entities g :entity-types nil))))))

;;; BUG-0080. Tables derived from a graph are kept until the graph changes.

(test a-derived-table-is-built-once-per-change
  (let ((graph (make-graph))
        (builds 0))
    (flet ((table () (graph-derived graph :count (lambda () (incf builds)))))
      (is (eql 1 (table)))
      (is (eql 1 (table)) "a second call with no change built the table again")
      (add-entity graph (q-function "alpha" 1))
      (is (eql 2 (table)) "a change to the graph did not rebuild the table")
      (is (eql 2 (table))))))

(test a-failed-change-still-moves-the-generation
  ;; apply-transaction is atomic against a rejected op, but a derived table is
  ;; built from the graph and not from the transaction: the generation moves
  ;; whenever the lock is left.
  (let* ((graph (make-graph))
         (before (graph-generation graph)))
    (ignore-errors (add-relationship graph (make-instance 'relationship
                                                           :rel-type :calls
                                                           :from-id "absent" :to-id "absent2")))
    (is (> (graph-generation graph) before))))

(test a-name-search-follows-the-graph-and-ignores-case
  (let ((graph (make-graph)))
    (add-entity graph (q-function "Alpha-Widget" 1))
    (is (equal '("Alpha-Widget")
               (mapcar #'name (find-entities graph :name-like "widget"))))
    (is (equal '("Alpha-Widget")
               (mapcar #'name (find-entities graph :name-like "ALPHA-w"))))
    (add-entity graph (q-function "widget-two" 5))
    (is (= 2 (length (find-entities graph :name-like "widget")))
        "a name added after the first search was not found")
    (is (null (find-entities graph :name-like "no-such-part")))))

(test the-substring-test-agrees-with-search
  (let ((strings '("" "a" "alpha-widget" "widget" "wid" "idget" "xwidgetx" "widgex" "aaa" "aab")))
    (dolist (pattern strings)
      (dolist (string strings)
        (is (eq (and (search pattern string) t)
                (and (synoptik-graph::contains-p (coerce pattern '(simple-array character (*)))
                                             (coerce string '(simple-array character (*))))
                     t))
            "~s in ~s" pattern string)))))

;;; BUG-0082. A name search looks the pattern's rarest trigram up and verifies.

(defun brute-force-name-search (graph pattern)
  (loop for e in (all-entities graph)
        when (name-matches-p e pattern) collect e))

(test the-trigram-index-finds-what-a-scan-of-every-name-finds
  (let ((graph (make-graph))
        (names '("alpha" "Alpha-Widget" "widget-two" "WIDGET" "aa" "a" "abab" "ababab"
                 "résumé-parser" "naïve-widget" "x" "xy" "xyz" "the-cache-layer"
                 "cache" "recache" "uncached" "prefix-p" "dot-prefixed-p" "")))
    (loop for name in names for i from 1
          do (add-entity graph (q-function name i (format nil "f~d.lisp" i))))
    (dolist (pattern '("alpha" "ALPHA" "widget" "wid" "idg" "dget" "a" "aa" "ab" "aba" "bab"
                       "abab" "ababab" "abababab" "cache" "ache" "che" "ach" "xy" "xyz" "xyzz"
                       "rés" "ïve" "prefix" "fix-p" "-" "zzz" "q"))
      (is (equal (mapcar #'id (brute-force-name-search graph pattern))
                 (mapcar #'id (find-entities graph :name-like pattern)))
          "~s" pattern))))

(test the-trigram-index-follows-the-graph
  (let ((graph (make-graph)))
    (add-entity graph (q-function "first-name" 1 "a.lisp"))
    (is (= 1 (length (find-entities graph :name-like "name"))))
    (add-entity graph (q-function "second-name" 2 "b.lisp"))
    (is (= 2 (length (find-entities graph :name-like "name")))
        "a name added after the index was built was not found")
    (remove-entity graph (id (first (find-entities graph :name-like "first"))))
    (is (= 1 (length (find-entities graph :name-like "name")))
        "a removed entity was still found")))

(test the-trigram-index-is-built-once-per-change
  (let ((graph (make-graph)))
    (add-entity graph (q-function "alpha" 1))
    (find-entities graph :name-like "alp")
    (let ((index (synoptik-graph::name-index graph)))
      (find-entities graph :name-like "lph")
      (is (eq index (synoptik-graph::name-index graph)))
      (add-entity graph (q-function "beta" 2))
      (is (not (eq index (synoptik-graph::name-index graph)))))))

;;; BUG-0083. NEIGHBORS reads a table of every entity's neighbors, built once per
;;; change to the graph, where it used to look each edge and each far entity up.
;;; The old function is kept here as the oracle.

(defun reference-neighbors (view id &key rel-types (direction :both) include-stale)
  (flet ((collect (rels way far)
           (loop for r in rels
                 for e = (get-entity view (funcall far r))
                 when (and e (or (null rel-types) (member (rel-type r) rel-types)))
                   collect (synoptik-graph::make-neighbor :entity e :relationship r :direction way))))
    (append
     (when (member direction '(:out :both))
       (collect (relationships-from view id :include-stale include-stale) :out #'to-id))
     (when (member direction '(:in :both))
       (collect (relationships-to view id :include-stale include-stale) :in #'from-id)))))

(defun neighbor-keys (neighbors)
  (mapcar (lambda (n) (list (id (neighbor-entity n)) (id (neighbor-relationship n))
                            (neighbor-direction n)))
          neighbors))

(defun same-neighbors-p (graph)
  (loop for e in (all-entities graph)
        always (loop for (rel-types direction include-stale)
                       in '((nil :both nil) (nil :both t) (nil :out nil) (nil :in nil)
                            ((:calls) :both nil) ((:calls) :in t) ((:calls :contains) :out nil)
                            ((:no-such-type) :both nil) ((:mentions) :out nil))
                     always (equal (neighbor-keys
                                    (neighbors graph (id e) :rel-types rel-types
                                                            :direction direction
                                                            :include-stale include-stale))
                                   (neighbor-keys
                                    (reference-neighbors graph (id e) :rel-types rel-types
                                                                      :direction direction
                                                                      :include-stale include-stale))))))

(test neighbors-through-the-table-are-those-of-the-edge-walk
  (is-true (same-neighbors-p (q-graph (make-q-fixture))))
  (is-true (same-neighbors-p (q-graph (make-q-fixture :stale-gamma t)))
           "a stale edge was treated differently"))

(test neighbors-follow-the-graph-when-it-changes
  (let* ((f (make-q-fixture))
         (g (q-graph f)))
    (is (= 1 (length (neighbors g (id (q-alpha f)) :rel-types '(:calls) :direction :in))))
    (let ((delta (q-function "delta" 40)))
      (add-entity g delta)
      (q-edge g :calls delta (q-alpha f)))
    (is (= 2 (length (neighbors g (id (q-alpha f)) :rel-types '(:calls) :direction :in)))
        "an edge added after the table was built was not found")
    (is-true (same-neighbors-p g))
    (remove-entity g (id (q-beta f)))
    (is-true (same-neighbors-p g)
             "a removed entity and its edges were still neighbors")))

(test the-adjacency-table-is-built-once-per-change
  (let* ((f (make-q-fixture))
         (g (q-graph f)))
    (neighbors g (id (q-alpha f)))
    (let ((table (synoptik-graph::adjacency g)))
      (neighbors g (id (q-beta f)) :direction :out)
      (is (eq table (synoptik-graph::adjacency g)))
      (q-edge g :calls (q-gamma f) (q-alpha f))
      (is (not (eq table (synoptik-graph::adjacency g)))))))
