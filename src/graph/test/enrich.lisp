;;;
;;; Tests for src/graph/enrich.lisp -- the graph-aware merge of image-derived
;;; facts (DES-0011).
;;;
;;; The first suite in this file exists for one property: enrichment must not
;;; be able to destroy what the text pass wrote. REQ-0018 R5 states it and
;;; ABSORB-PROPERTIES is what would break it, so the guard is written against
;;; the mechanism -- :CALL-NAMES surviving, and the derived edges with it --
;;; rather than against an edge count that a blind assert would happen to leave
;;; alone.
;;;

(in-package :synoptik-graph-test)

(def-suite enrich
  :in all-tests
  :description "ENRICH-OPS: image facts merged without touching text facts.")

(in-suite enrich)

;;; ------------------------------------------------------------------
;;; Fixtures
;;; ------------------------------------------------------------------

(defun en-test (graph name file &key call-names)
  (let ((e (make-instance 'test-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp
                                             :call-names call-names)))))
    (add-entity graph e)
    e))

(defun enrich-fixture ()
  "A graph in the shape the R5 guard has to protect.

Two files of functions whose cross-file call has been resolved, plus a test
whose coverage was derived from that call. Built by running RESOLVE-CALLS and
RESOLVE-TESTS rather than by asserting the edges directly, because what is
being protected is not the edges -- it is :CALL-NAMES, the property those two
passes re-derive from on every run. An edge asserted by hand would survive an
absorb that wiped the property, and the guard would pass while the real index
was quietly unrebuildable."
  (let ((graph (make-graph)))
    (r-function graph "analyze-tree" "a.lisp" :unresolved '("analyze-path"))
    (r-function graph "analyze-path" "b.lisp")
    (en-test graph "analyze-path-walks-a-tree" "t.lisp" :call-names '("analyze-path"))
    (apply-transaction graph (resolve-calls graph))
    (apply-transaction graph (resolve-tests graph))
    graph))

(defun fixture-definition (name file &key (kind :function) (package "fixture")
                                          (start 1) (end 5))
  (list :kind kind :name name :package package :file file
        :start-line start :end-line end :system :fixture))

(defun fixture-inspection (definitions &optional calls)
  "The facts document the inspector would have produced, hand-written."
  (list :synoptik-inspection 1
        :language :lisp
        :toolchain "fixture"
        :units '((:unit "fixture" :status :loaded))
        :definitions definitions
        :calls calls))

(defun fixture-agreeing-inspection ()
  "An inspection naming exactly the definitions ENRICH-FIXTURE already holds."
  (fixture-inspection
   (list (fixture-definition "analyze-tree" "a.lisp")
         (fixture-definition "analyze-path" "b.lisp"))))

(defun property-alist (entity)
  "ENTITY's whole property table as a sorted alist, for EQUAL comparison."
  (sort (loop for key being the hash-keys of (properties entity)
                using (hash-value value)
              collect (cons key value))
        #'string< :key (lambda (pair) (symbol-name (car pair)))))

(defun graph-snapshot (graph)
  "Everything about GRAPH that enrichment must not move: every entity's id,
provenance and full property table, and every edge's id, endpoints, source and
origin file."
  (list (sort (loop for e in (all-entities graph)
                    collect (list (id e) (source e) (origin-file e)
                                  (property-alist e)))
              #'string< :key #'first)
        (sort (loop for r in (all-relationships graph)
                    collect (list (id r) (rel-type r) (from-id r) (to-id r)
                                  (source r) (origin-file r)))
              #'string< :key #'first)))

;;; ------------------------------------------------------------------
;;; The R5 guard
;;; ------------------------------------------------------------------

(test an-inspection-that-names-only-known-definitions-produces-no-operations
  ;; PLAN-0010 step 2 (a), and the sharpest assertion in it: not "the graph is
  ;; unchanged afterwards" -- which a merge could satisfy by asserting and
  ;; absorbing onto identical values -- but that there was nothing to apply.
  (let* ((graph (enrich-fixture))
         (before (graph-snapshot graph)))
    (multiple-value-bind (ops report) (enrich-ops graph (fixture-agreeing-inspection))
      (is (null ops)
          "a definition the graph already holds contributes a lookup, not an op")
      (is (= 2 (getf report :confirmed)))
      (is (= 0 (getf report :added)))
      (apply-transaction graph ops)
      (is (equal before (graph-snapshot graph))))))

(test enrichment-leaves-call-names-and-the-edges-derived-from-them-intact
  ;; The same guard read the other way round, naming what would actually be
  ;; lost. A blind ASSERT-ENTITY on "analyze-tree" reaches ABSORB-PROPERTIES,
  ;; which CLRHASHes the table -- so :CALL-NAMES goes, RESOLVE-CALLS rebuilds
  ;; nothing on the next pass, and the :TESTS edge derived from the :CALLS edge
  ;; never comes back. This is REQ-0018 R5 at the smallest scale that still
  ;; contains the mechanism.
  (let ((graph (enrich-fixture)))
    (apply-transaction graph
                       (enrich-ops graph (fixture-agreeing-inspection)))
    (let ((caller (find-entity-by-key graph '(:function "a.lisp" "analyze-tree")))
          (test   (find-entity-by-key graph '(:test "t.lisp" "analyze-path-walks-a-tree"))))
      (is (equal '("analyze-path") (getp caller :call-names))
          "the resolution input the image pass knows nothing about")
      (is (= 1 (length (relationships-from graph (id caller) :rel-type :calls))))
      (is (= 1 (length (relationships-from graph (id test) :rel-type :tests)))
          "coverage the image cannot produce and must not remove"))))

;;; ------------------------------------------------------------------
;;; What the image adds
;;; ------------------------------------------------------------------

(test a-definition-the-graph-does-not-hold-becomes-one-introspected-entity
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      (list (fixture-definition "properties-table" "c.lisp"
                                                :start 12 :end 18)))))
    (multiple-value-bind (ops report) (enrich-ops graph inspection)
      (is (= 1 (length ops)))
      (is (= 1 (getf report :added)))
      (is (= 0 (getf report :confirmed)))
      (apply-transaction graph ops)
      (let ((e (find-entity-by-key graph '(:function "c.lisp" "properties-table"))))
        (is (not (null e)))
        (is (eq :introspected (source e)))
        (is (= 1.0 (confidence e)))
        (is (equal "c.lisp" (origin-file e))
            "the origin file is what RETRACT-FILE will age this fact out on")
        (is (eql 12 (getp e :start-line)))
        (is (eql 18 (getp e :end-line)))))))

(test a-definition-with-no-recovered-range-is-dropped-and-counted
  ;; :START-LINE is :REQUIRED on every code entity type, so there is no honest
  ;; partial assert -- and a fabricated range is the failure hardest to notice,
  ;; because it sends an agent to the wrong lines of a real file (CON-0001).
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      (list (list :kind :function :name "unlocatable"
                                  :package "fixture" :file "c.lisp"
                                  :system :fixture)))))
    (multiple-value-bind (ops report) (enrich-ops graph inspection)
      (is (null ops))
      (is (= 1 (getf report :dropped-no-location)))
      (is (null (find-entity-by-key graph '(:function "c.lisp" "unlocatable")))))))

(test a-definition-outside-the-workspace-is-dropped-and-counted
  ;; An absolute path would never match RETRACT-FILE's origin-index key, so a
  ;; fact carrying one could never go stale.
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      (list (fixture-definition "gethash" "/usr/lib/sbcl/hash.lisp")))))
    (multiple-value-bind (ops report) (enrich-ops graph inspection)
      (is (null ops))
      (is (= 1 (getf report :dropped-not-under-root))))))

(test a-kind-the-ontology-has-no-type-for-is-dropped-and-counted
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      (list (fixture-definition "some-type" "c.lisp"
                                                :kind :deftype)))))
    (multiple-value-bind (ops report) (enrich-ops graph inspection)
      (is (null ops))
      (is (= 1 (getf report :dropped-unknown-kind))))))

;;; ------------------------------------------------------------------
;;; Call edges, and the record that both passes agree
;;; ------------------------------------------------------------------

(defun fixture-call (caller-name callee-name &key (caller-file "a.lisp"))
  (list :caller (list :function caller-name "fixture")
        :caller-file caller-file
        :callee (list :function callee-name "fixture")))

(defun agreeing-inspection-with-calls (&rest calls)
  (fixture-inspection
   (list (fixture-definition "analyze-tree" "a.lisp")
         (fixture-definition "analyze-path" "b.lisp"))
   calls))

(defun calls-edge (graph from-key to-key)
  (find-relationship-by-key
   graph (list :calls
               (id (find-entity-by-key graph from-key))
               (id (find-entity-by-key graph to-key)))))

(test a-call-the-text-pass-already-recorded-is-confirmed-on-the-same-edge
  ;; Provenance in the natural key was rejected by DES-0011: one edge per pass
  ;; doubles every agreed fact and inflates every impact count with duplicates
  ;; that mean "we agree". So agreement lands on the edge that is already there,
  ;; and this is the test that it is the same edge and not a second one.
  (let* ((graph (enrich-fixture))
         (edge (calls-edge graph '(:function "a.lisp" "analyze-tree")
                                 '(:function "b.lisp" "analyze-path")))
         (edge-id (id edge))
         (edge-origin (origin-file edge))
         (edge-count (length (all-relationships graph))))
    (multiple-value-bind (ops report)
        (enrich-ops graph (agreeing-inspection-with-calls
                           (fixture-call "analyze-tree" "analyze-path")))
      (is (= 1 (length ops)))
      (is (= 1 (getf report :edges-confirmed)))
      (is (= 0 (getf report :edges-added)))
      (apply-transaction graph ops))
    (let ((after (calls-edge graph '(:function "a.lisp" "analyze-tree")
                                   '(:function "b.lisp" "analyze-path"))))
      (is (equal edge-id (id after)) "confirmation must not mint a second edge")
      (is (= edge-count (length (all-relationships graph))))
      (is (equal '(:structural :introspected) (getp after :sources))
          "the slot says who asserted last; the property says who has agreed")
      ;; PLAN-0010 R-3. INDEX-ORIGIN runs from ADD-ENTITY and ADD-RELATIONSHIP
      ;; and nowhere else, so an absorb that moved ORIGIN-FILE would desynchronise
      ;; the index RETRACT-FILE reads and the edge would stop ageing out.
      ;; Asserted against the value read before the merge, not against a literal.
      (is (equal edge-origin (origin-file after))))))

(test a-call-only-the-image-can-see-becomes-a-new-introspected-edge
  ;; The BUG-0011-shaped case, predicted here and measured on Synoptik's own tree
  ;; in PLAN-0010 step 11: xref records a callee reached through #'f, funcall,
  ;; mapcar or apply, none of which the text pass's operator-position walk sees.
  (let ((graph (enrich-fixture)))
    (multiple-value-bind (ops report)
        (enrich-ops graph (agreeing-inspection-with-calls
                           (fixture-call "analyze-path" "analyze-tree"
                                         :caller-file "b.lisp")))
      (is (= 1 (getf report :edges-added)))
      (is (= 0 (getf report :edges-confirmed)))
      (apply-transaction graph ops))
    (let ((edge (calls-edge graph '(:function "b.lisp" "analyze-path")
                                  '(:function "a.lisp" "analyze-tree"))))
      (is (not (null edge)))
      (is (eq :introspected (source edge)))
      (is (equal '(:introspected) (getp edge :sources)))
      (is (equal "b.lisp" (origin-file edge))
          "the calling file, so editing it retracts the claim"))))

(test the-sources-union-is-stable-across-runs
  ;; ABSORB-RELATIONSHIP rewrites the property table on every confirmation, so
  ;; an ordering that depended on what the graph happened to hold would make the
  ;; second run against an unchanged tree a churn rather than a no-op.
  (let ((graph (enrich-fixture))
        (inspection (agreeing-inspection-with-calls
                     (fixture-call "analyze-tree" "analyze-path"))))
    (apply-transaction graph (enrich-ops graph inspection))
    (let ((first-run (graph-snapshot graph))
          (sources (getp (calls-edge graph '(:function "a.lisp" "analyze-tree")
                                           '(:function "b.lisp" "analyze-path"))
                         :sources)))
      (apply-transaction graph (enrich-ops graph inspection))
      (is (equal sources
                 (getp (calls-edge graph '(:function "a.lisp" "analyze-tree")
                                         '(:function "b.lisp" "analyze-path"))
                       :sources)))
      (is (equal first-run (graph-snapshot graph))))))

(test a-confirmed-edge-keeps-the-call-keys-resolution-wrote-on-it
  ;; PLAN-0060 step 2. ENRICHED-EDGE's op is absorbed onto the existing edge,
  ;; and ABSORB-PROPERTIES clears the table before it copies, so :VIA would be
  ;; erased by every confirmation unless the op carries it. RESOLVE-CALLS
  ;; writes :VIA on this edge; the enrich fixture is built by running it.
  (let ((graph (enrich-fixture))
        (from '(:function "a.lisp" "analyze-tree"))
        (to '(:function "b.lisp" "analyze-path")))
    (is (equal '("analyze-path") (getp (calls-edge graph from to) :via))
        "control: the fixture's edge starts with the key that produced it")
    (apply-transaction graph (enrich-ops graph (agreeing-inspection-with-calls
                                                (fixture-call "analyze-tree"
                                                              "analyze-path"))))
    (let ((after (calls-edge graph from to)))
      (is (equal '(:structural :introspected) (getp after :sources))
          "control: the edge was confirmed, not left alone")
      (is (equal '("analyze-path") (getp after :via))))))

(test an-edge-only-the-image-reported-has-no-call-key
  ;; No call form produced it, so there is no key to name. An empty :VIA would
  ;; claim the text pass looked and found none.
  (let ((graph (enrich-fixture)))
    (apply-transaction graph (enrich-ops graph (agreeing-inspection-with-calls
                                                (fixture-call "analyze-path"
                                                              "analyze-tree"
                                                              :caller-file "b.lisp"))))
    (let ((edge (calls-edge graph '(:function "b.lisp" "analyze-path")
                                  '(:function "a.lisp" "analyze-tree"))))
      (is (not (null edge)))
      (is (null (nth-value 1 (gethash :via (properties edge))))
          "the property is absent, not present and empty"))))

(test a-call-with-an-endpoint-outside-the-index-is-dropped-and-counted
  (let ((graph (enrich-fixture)))
    (multiple-value-bind (ops report)
        (enrich-ops graph (agreeing-inspection-with-calls
                           (fixture-call "analyze-tree" "hunchentoot-start")))
      (is (null ops) "a dangling edge is worse than a counted gap")
      (is (= 1 (getf report :edges-dropped))))))

(test a-function-and-a-variable-of-one-name-stay-two-things
  ;; The child emits a :FUNCTION, a :CLASS and a :VARIABLE for one symbol when
  ;; all three exist, in that order. While the endpoint index keyed on the name
  ;; alone, the last of the three won it: a call naming the function resolved
  ;; onto the :VARIABLE entity, CALLABLE-ENDPOINTS-P refused that endpoint, and
  ;; the edge disappeared into :EDGES-DROPPED where it read as an external
  ;; callee. The edge landing on the :FUNCTION is the whole assertion; the drop
  ;; count staying at zero is what says it was not a near miss.
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      ;; The caller has to be named too: an endpoint resolves
                      ;; through the inspection's own definition facts.
                      (list (fixture-definition "analyze-tree" "a.lisp")
                            (fixture-definition "id" "c.lisp")
                            (fixture-definition "id" "c.lisp" :kind :variable))
                      (list (fixture-call "analyze-tree" "id")))))
    (multiple-value-bind (ops report) (enrich-ops graph inspection)
      (is (= 2 (getf report :added)) "the two definitions are two entities")
      (is (= 1 (getf report :edges-added)))
      (is (= 0 (getf report :edges-dropped)))
      (apply-transaction graph ops))
    (let ((callee (find-entity-by-key graph '(:function "c.lisp" "id")))
          (caller (find-entity-by-key graph '(:function "a.lisp" "analyze-tree"))))
      (is (not (null (find (id callee)
                           (relationships-from graph (id caller) :rel-type :calls)
                           :key #'to-id :test #'equal)))
          "the call reaches the function, not the variable that shares its name"))))

;;; ------------------------------------------------------------------
;;; Dispatched calls do not become edges into the generic (DES-0001)
;;; ------------------------------------------------------------------
;;;
;;; The text pass fans a dispatched call out to the candidate methods and lands
;;; on the :INTERFACE only when there are none to fan out to. xref answers a
;;; different question -- who names this generic -- so an unfiltered merge gives
;;; every generic with methods a direct caller set the text pass deliberately
;;; never gives it, and double-counts every dispatched call in `impact'. The
;;; :CALLS declaration states the invariant outright ("it does not make the
;;; generic a hub"), and these two tests are what keeps that sentence true after
;;; an enrich.

(defparameter *dispatch-fixture-source*
  "(in-package :fixture)

(defgeneric draw (shape))

(defmethod draw ((shape hop)) (list shape))

(defun paint (s) (draw s))
")

(defparameter *accessor-fixture-source*
  "(in-package :fixture)

(defgeneric slot-reader (object))

(defun show (o) (slot-reader o))
")

(defun text-indexed (source file)
  "SOURCE through the real text pass, resolved: entities, :IMPLEMENTS edges and
the :CALLS edges RESOLVE-CALLS derives. Built with the analyzer rather than by
hand because what is under test is a distinction the analyzer draws."
  (let ((graph (make-graph)))
    (apply-transaction
     graph
     (synoptik-analyzer:analyze-file (make-instance 'synoptik-analyzer:lisp-analyzer)
                                 file source nil))
    (apply-transaction graph (resolve-definitions graph))
    (apply-transaction graph (resolve-calls graph))
    graph))

(test a-call-into-a-generic-that-has-methods-is-dropped-not-minted
  (let* ((graph (text-indexed *dispatch-fixture-source* "g.lisp"))
         (generic (find-entity-by-key graph '(:interface "g.lisp" "draw")))
         (caller (find-entity-by-key graph '(:function "g.lisp" "paint")))
         (before (length (relationships-to graph (id generic) :rel-type :calls))))
    (is (= 1 (length (relationships-to graph (id generic) :rel-type :implements)))
        "the fixture only means anything if the method implements the generic")
    (multiple-value-bind (ops report)
        (enrich-ops graph
                    (fixture-inspection
                     (list (fixture-definition "paint" "g.lisp")
                           (fixture-definition "draw" "g.lisp" :kind :generic-function)
                           (list :kind :method :name "draw" :package "fixture"
                                 :qualifier nil :specializers '("hop")
                                 :file "g.lisp" :start-line 5 :end-line 5))
                     (list (list :caller (list :function "paint" "fixture")
                                 :caller-file "g.lisp"
                                 :callee (list :generic-function "draw" "fixture")))))
      (is (= 1 (getf report :edges-dropped)))
      (is (= 0 (getf report :edges-added)))
      (is (= 0 (getf report :edges-confirmed)))
      (apply-transaction graph ops))
    (is (= before (length (relationships-to graph (id generic) :rel-type :calls)))
        "enrichment must not give the generic a caller set the text pass refused")
    (is (= 1 (length (relationships-from graph (id caller) :rel-type :calls)))
        "the fanned-out edge to the method is the one that already carries it")))

(test a-call-into-a-generic-with-no-methods-is-still-an-edge
  ;; The control, and the reason the test above is keyed on :IMPLEMENTS rather
  ;; than on the entity type. A DEFCLASS slot accessor, or a generic implemented
  ;; outside the indexed tree, has nothing to fan out to -- the text pass mints
  ;; the edge into the interface itself, and refusing it here would make the
  ;; commonest accessor in a CLOS codebase uncallable.
  (let* ((graph (text-indexed *accessor-fixture-source* "h.lisp"))
         (generic (find-entity-by-key graph '(:interface "h.lisp" "slot-reader"))))
    (is (null (relationships-to graph (id generic) :rel-type :implements)))
    (multiple-value-bind (ops report)
        (enrich-ops graph
                    (fixture-inspection
                     (list (fixture-definition "show" "h.lisp")
                           (fixture-definition "slot-reader" "h.lisp"
                                               :kind :generic-function))
                     (list (list :caller (list :function "show" "fixture")
                                 :caller-file "h.lisp"
                                 :callee (list :generic-function "slot-reader" "fixture")))))
      (is (= 1 (getf report :edges-confirmed)))
      (is (= 0 (getf report :edges-dropped)))
      (apply-transaction graph ops))
    (is (equal '(:structural :introspected)
               (getp (first (relationships-to graph (id generic) :rel-type :calls))
                     :sources))
        "and both passes are recorded as having seen it")))

;;; ------------------------------------------------------------------
;;; The key-equality fixture (DES-0011 R5, REQ-0018 R8's comparison seam)
;;; ------------------------------------------------------------------
;;;
;;; Every component of a natural key is a rendering, and the two passes render
;;; independently: DEFINITION-NAME and SPECIALIZER-NAME in the analyzer, the
;;; child's printing in the inspector. Drift does not fail -- it mints a
;;; duplicate entity beside the text pass's own, which reads as success because
;;; the entity count went up.
;;;
;;; Asserted through ENRICH-OPS' public result rather than by comparing key
;;; lists: if every rendering meets, an inspection naming exactly what the text
;;; pass found emits nothing at all, and any drift shows up as an op. That is
;;; the same assertion the R5 guard makes, aimed at the four shapes whose
;;; renderings are hardest to reproduce.

(defparameter *key-fixture-source*
  "(in-package :fixture)

(defun plain-fn (x) (list x))

(defmethod render :after ((x hop) (s stream)) (list x s))

(defmethod render ((x (eql :svg)) s) (list x s))

(defgeneric draw (shape)
  (:method ((shape hop)) (plain-fn shape)))
"
  "One DEFUN, a qualified DEFMETHOD, a DEFMETHOD with an EQL specializer, and a
DEFGENERIC with an inline (:method ...) clause -- the four shapes whose
renderings DES-0011 R5 names.")

(defparameter *key-fixture-inspection*
  ;; Hand-written as the inspector would report it, and every string here is
  ;; the inspector's obligation. Note "(eql svg)": SPECIALIZER-NAME renders an
  ;; EQL specializer through TOKEN-NAME, which takes SYMBOL-NAME and drops the
  ;; keyword's colon. PLAN-0010 R-2 and DES-0011 both write "(eql :svg)";
  ;; measured against the analyzer, the colon is not there.
  (list :synoptik-inspection 1
        :language :lisp
        :definitions
        (list (list :kind :function :name "plain-fn" :package "fixture"
                    :file "f.lisp" :start-line 3 :end-line 3 :system :fixture)
              (list :kind :method :name "render" :package "fixture"
                    :qualifier "after" :specializers '("hop" "stream")
                    :file "f.lisp" :start-line 5 :end-line 5 :system :fixture)
              (list :kind :method :name "render" :package "fixture"
                    :qualifier nil :specializers '("(eql svg)" "t")
                    :file "f.lisp" :start-line 7 :end-line 7 :system :fixture)
              (list :kind :generic-function :name "draw" :package "fixture"
                    :file "f.lisp" :start-line 9 :end-line 10 :system :fixture)
              (list :kind :method :name "draw" :package "fixture"
                    :qualifier nil :specializers '("hop")
                    :file "f.lisp" :start-line 10 :end-line 10 :system :fixture))))

(test both-passes-derive-the-same-natural-key-for-one-definition-set
  (let ((graph (make-graph)))
    (apply-transaction
     graph
     (synoptik-analyzer:analyze-file (make-instance 'synoptik-analyzer:lisp-analyzer)
                                 "f.lisp" *key-fixture-source* nil))
    (multiple-value-bind (ops report) (enrich-ops graph *key-fixture-inspection*)
      (is (= 5 (getf report :confirmed))
          "each of the five definitions must find the entity the text pass made")
      (is (= 0 (getf report :added))
          "an addition here is a drifted rendering, not a new definition")
      (is (null ops)))))

(test the-key-fixture-fails-when-a-rendering-drifts
  ;; CON-0003 applied to the fixture above: it has to be able to go red. One
  ;; specializer upcased is the smallest drift a change to either side's
  ;; renderer could produce, and it must cost a confirmation and buy an assert.
  (let ((graph (make-graph))
        (drifted (copy-tree *key-fixture-inspection*)))
    (setf (getf (third (getf drifted :definitions)) :specializers)
          '("(eql svg)" "T"))
    (apply-transaction
     graph
     (synoptik-analyzer:analyze-file (make-instance 'synoptik-analyzer:lisp-analyzer)
                                 "f.lisp" *key-fixture-source* nil))
    (multiple-value-bind (ops report) (enrich-ops graph drifted)
      (is (= 4 (getf report :confirmed)))
      (is (= 1 (getf report :added)))
      (is (= 1 (length ops))))))

;;; ------------------------------------------------------------------
;;; Self-aging (DES-0011's staleness claim, PLAN-0010 R-4)
;;; ------------------------------------------------------------------
;;;
;;; PLAN-0010 puts this in step 8's analyzer tests. It is here instead because
;;; what it exercises is RETRACT-FILE and RESOLVE-CALLS -- synoptik-graph's, both of
;;; them -- and a real recovered line range is not what makes it true; an honest
;;; workspace-relative origin file is.

(defun aging-definitions ()
  "One definition the text pass already holds and one only the image sees.

Both are needed. An endpoint resolves through the inspection's own definition
facts, so an inspection naming only the minted callee would drop the edge into
it -- correctly, and without demonstrating anything."
  (list (fixture-definition "analyze-tree" "a.lisp")
        (fixture-definition "generated-accessor" "c.lisp")))

(defun aging-calls ()
  (list (list :caller (list :function "analyze-tree" "fixture")
              :caller-file "a.lisp"
              :callee (list :function "generated-accessor" "fixture"))))

(test an-introspected-fact-is-aged-out-by-the-machinery-that-already-existed
  ;; DES-0011 claims image facts need no new staleness code: they carry an
  ;; origin-file like every other fact, so RETRACT-FILE removes them and
  ;; REMOVE-ENTITY takes their inbound edges with them. Claimed, and until now
  ;; unverified -- which for a claim of the form "degrades rather than lies" is
  ;; the difference between a design and a hope.
  (let* ((graph (enrich-fixture))
         (caller (find-entity-by-key graph '(:function "a.lisp" "analyze-tree"))))
    (apply-transaction
     graph
     (enrich-ops graph (fixture-inspection (aging-definitions) (aging-calls))))
    (let* ((minted (find-entity-by-key graph '(:function "c.lisp" "generated-accessor")))
           (inbound (relationships-to graph (id minted) :rel-type :calls)))
      (is (not (null minted)))
      (is (= 1 (length inbound)))
      (is (= 2 (length (relationships-from graph (id caller) :rel-type :calls)))
          "the text pass's edge and the image's, side by side")
      ;; Editing c.lisp is what a poll would do next.
      (apply-transaction graph (list (retract-file "c.lisp" nil)))
      (is (null (find-entity-by-key graph '(:function "c.lisp" "generated-accessor")))
          "no code outside transaction.lisp ran to make this happen")
      (is (null (get-relationship graph (id (first inbound))))
          "and the inbound edge went with the entity")
      (is (= 1 (length (relationships-from graph (id caller) :rel-type :calls)))
          "while the text pass's own edge is untouched"))))

(test the-text-pass-alone-does-not-bring-an-introspected-fact-back
  ;; The honest half, and the one that makes the claim worth something. The
  ;; text pass never saw either fact -- RESOLVE-CALLS derives from :CALL-NAMES
  ;; and the image pass writes none -- so between enrich runs the index degrades
  ;; toward today's text index rather than keeping a claim nobody re-verified.
  (let ((graph (enrich-fixture))
        (inspection (fixture-inspection (aging-definitions) (aging-calls))))
    (apply-transaction graph (enrich-ops graph inspection))
    (apply-transaction graph (list (retract-file "c.lisp" nil)))
    (apply-transaction graph (resolve-calls graph))
    (is (null (find-entity-by-key graph '(:function "c.lisp" "generated-accessor")))
        "resolution rebuilds what the analyzer recorded, and it recorded nothing")
    ;; And the next enrich puts it back, which is what makes the degradation a
    ;; degradation rather than a loss.
    (apply-transaction graph (enrich-ops graph inspection))
    (is (not (null (find-entity-by-key graph '(:function "c.lisp" "generated-accessor")))))))

(test applying-the-same-inspection-twice-is-a-no-op-the-second-time
  ;; Idempotence, cheaply: the first run's entities are the second run's
  ;; confirmations. Re-running enrich against an unchanged tree must cost
  ;; nothing, or nobody will run it twice.
  (let* ((graph (enrich-fixture))
         (inspection (fixture-inspection
                      (list (fixture-definition "properties-table" "c.lisp")))))
    (apply-transaction graph (enrich-ops graph inspection))
    (let ((after-first (graph-snapshot graph)))
      (multiple-value-bind (ops report) (enrich-ops graph inspection)
        (is (null ops))
        (is (= 1 (getf report :confirmed))))
      (is (equal after-first (graph-snapshot graph))))))

;;; ------------------------------------------------------------------
;;; The real child, not a hand transcription (PLAN-0010 R-2)
;;; ------------------------------------------------------------------
;;;
;;; BOTH-PASSES-DERIVE-THE-SAME-NATURAL-KEY above proves ENRICH-OPS' own key
;;; function agrees with a *hand-written* rendering of what the child would
;;; say -- both sides typed by hand, both naming "f.lisp" at the inspection
;;; root's own top level, a single path segment. It says nothing about
;;; whether the child's own file rendering (RELATIVE-FILE in
;;; lisp-inspector.lisp: a truename, forward-slashed and made relative by
;;; string subtraction) and the text pass's own WORKSPACE-RELATIVE-PATH
;;; (ENOUGH-NAMESTRING) actually agree once both are computed from a real
;;; file on disk with more than one path segment -- the shape every real
;;; repository has, including this one, and that no fixture above exercises.
;;; A disagreement here would not fail: it would mint a duplicate beside
;;; every definition both passes can see, which is PLAN-0010 R-2's silent
;;; doubling arriving through the file string rather than through a name or a
;;; specializer. This spawns a real child SBCL because nothing hand-written
;;; can stand in for what it is checking.

(defun inspect-fixture-root ()
  (asdf:system-relative-pathname :synoptik-analyzer "test/fixtures/inspect/"))

(test the-real-childs-file-string-agrees-with-the-real-text-passs
  (let* ((root (inspect-fixture-root))
         (path (merge-pathnames "fixture-ok/fixture-ok.lisp" root))
         (relative (synoptik-analyzer:workspace-relative-path path root))
         (contents (synoptik-utils:read-file path))
         (graph (make-graph)))
    (is (find #\/ relative)
        "the shape neither fixture above exercises: more than one path segment")
    (apply-transaction
     graph
     (synoptik-analyzer:analyze-file (make-instance 'synoptik-analyzer:lisp-analyzer)
                                 relative contents nil))
    (let* ((inspector (make-instance 'synoptik-analyzer:lisp-inspector
                                     :timeout-seconds 60 :include-test-units t))
           (inspection (synoptik-analyzer:inspect-repository inspector root
                                                          :units '("fixture-ok"))))
      (multiple-value-bind (ops report) (enrich-ops graph inspection)
        ;; The three definitions both passes can see: a DEFUN calling a
        ;; DEFUN, a DEFGENERIC, and its inline method. If the file strings
        ;; disagreed by even one character -- a missing slash, a case fold,
        ;; a trailing separator -- FIND-ENTITY-BY-KEY would miss every one of
        ;; them and all three would be :ADDED instead of :CONFIRMED.
        (is (<= 3 (getf report :confirmed))
            "the file rendering must agree, or every shared definition doubles")
        (apply-transaction graph ops))
      ;; The doubling itself, checked directly rather than only through the
      ;; report: one entity per name, not two.
      (dolist (name '("inner-callee" "outer-caller"))
        (is (= 1 (count name (entities-of-type graph :function) :key #'name :test #'string=))
            "~a must not have doubled" name))
      (is (= 1 (count "shape-area" (entities-of-type graph :method) :key #'name :test #'string=))
          "the inline method must not have doubled")
      ;; generated-reader is the one definition the text pass genuinely
      ;; cannot see (it never ran DEFINE-READER), so it is the control: this
      ;; one is SUPPOSED to be new, which is what makes the others' absence
      ;; of duplication a finding rather than a tautology.
      (is (= 1 (count "generated-reader" (entities-of-type graph :function)
                      :key #'name :test #'string=)))
      (is (eq :introspected (source (find-entity-by-key
                                     graph '(:function "fixture-ok/fixture-ok.lisp"
                                             "generated-reader"))))))))
