;;;; The cost-ordered walk -- DES-0026 D6/D8, PLAN-0032 S1.

(in-package :loom-knowledge-test)

(in-suite context)

(defun reach-named (reaches name)
  (find name reaches :key (lambda (r) (name (reach-entity r))) :test #'string=))

(test an-inherits-chain-runs-deeper-than-a-call-fan-for-the-same-price
  ;; The property a cost horizon has and a depth limit cannot: one number serves
  ;; a hierarchy and a call fan differently, and the query does not choose --
  ;; the edges available from its seeds do. :INHERITS costs 1 so four hops fit
  ;; inside the horizon; an incoming :CALLS costs 4 so one hop reaches it
  ;; exactly and a second cannot.
  ;; Two seeds, because the ontology will not let a :CALLS terminate at a
  ;; :CLASS -- which it refused when this fixture first tried it, correctly.
  (let* ((g (make-graph))
         (root (k-def 'class-entity "root" "src/a.lisp"))
         (kids (loop for i from 1 to 4
                     collect (k-def 'class-entity (format nil "kid~d" i) "src/a.lisp")))
         (callee (k-def 'function-entity "callee" "src/b.lisp"))
         (caller (k-def 'function-entity "caller" "src/b.lisp"))
         (indirect (k-def 'function-entity "indirect" "src/b.lisp")))
    (dolist (e (list* root callee caller indirect kids)) (add-entity g e))
    ;; root <- kid1 <- kid2 <- kid3 <- kid4, each an :INHERITS
    (loop for parent in (cons root kids) for child in kids
          do (k-edge g :inherits child parent))
    ;; callee <- caller <- indirect, both :CALLS
    (k-edge g :calls caller callee)
    (k-edge g :calls indirect caller)
    (let ((reaches (expand-from-seeds g (list root callee))))
      (is (= 1 (reach-cost (reach-named reaches "kid1"))))
      (is (= 4 (reach-cost (reach-named reaches "kid4")))
          "four hierarchy hops fit inside a horizon of 4")
      (is (= 4 (reach-cost (reach-named reaches "caller")))
          "one incoming call costs 4 and lands on the horizon exactly")
      (is (null (reach-named reaches "indirect"))
          "a second call hop costs 8 and is out of reach"))))

(test a-call-is-cheaper-outward-than-inward
  ;; The asymmetry that makes one table serve both R6's hierarchy query and
  ;; R7's startup-sequence query. What a thing calls is its implementation --
  ;; bounded, and about it. What calls it is its client set -- unbounded, and
  ;; about them.
  (is (= 3 (edge-cost :calls :out)))
  (is (= 4 (edge-cost :calls :in)))
  (is (= 1 (edge-cost :inherits :out)))
  (is (= 1 (edge-cost :inherits :in))))

(test an-unpriced-relationship-type-is-uncrossable-rather-than-free
  ;; The safe default, and the reason there is no fallback cost: a type added to
  ;; the ontology without being priced loses reach, which is a recorded gap,
  ;; rather than gaining free reach, which would be a fabricated one. The
  ;; document edges are unpriced deliberately -- DES-0020 owns those bands.
  (is (null (edge-cost :mentions :out)))
  (is (null (edge-cost :decides :in)))
  (let* ((g (make-graph))
         (a (k-def 'function-entity "a" "src/a.lisp"))
         (doc (make-instance 'design-entity :name "DES-9999"
                             :properties (properties-table (list :doc-id "DES-9999")))))
    (add-entity g a) (add-entity g doc)
    (k-edge g :mentions doc a)
    (is (null (expand-from-seeds g (list a)))
        "a walk that followed :MENTIONS would spend its horizon in prose")))

(test a-container-is-reached-and-never-expanded-from
  ;; DES-0026 D8. Without this the table is unusable at any price: one seed
  ;; reaching its own file would put every definition in that file two hops out,
  ;; and the directory listing R1 fought out of the seed band would arrive in
  ;; the neighbour band instead.
  (let* ((g (make-graph))
         (seed (k-def 'function-entity "seed" "src/a.lisp"))
         (file (make-instance 'file-entity :name "src/a.lisp"
                              :properties (properties-table (list :path "src/a.lisp"))))
         (sibling (k-def 'function-entity "sibling" "src/a.lisp")))
    (dolist (e (list seed file sibling)) (add-entity g e))
    (k-edge g :contains file seed)
    (k-edge g :contains file sibling)
    (let ((reaches (expand-from-seeds g (list seed))))
      (is (reach-named reaches "src/a.lisp") "the file is an answer")
      (is (null (reach-named reaches "sibling"))
          "and not a route to everything else in it"))))

(test the-walk-reports-the-edge-each-neighbour-arrived-on
  ;; DES-0026 D10. A neighbour at distance 1 on :IMPLEMENTS and one at distance
  ;; 4 on :CALLS deserve different decisions, and before this they printed
  ;; identically.
  (let* ((g (make-graph))
         (root (k-def 'class-entity "root" "src/a.lisp"))
         (kid (k-def 'class-entity "kid" "src/a.lisp")))
    (add-entity g root) (add-entity g kid)
    (k-edge g :inherits kid root)
    (let ((r (reach-named (expand-from-seeds g (list root)) "kid")))
      (is (eq :inherits (reach-via r)))
      (is (eq :in (reach-direction r)) "the subclass points at the superclass")
      (is (= 0 (reach-origin r)) "reached from the first seed"))))

(test a-seed-is-never-offered-as-its-own-neighbour
  (let* ((g (make-graph))
         (a (k-def 'class-entity "a" "src/a.lisp"))
         (b (k-def 'class-entity "b" "src/a.lisp")))
    (add-entity g a) (add-entity g b)
    (k-edge g :inherits b a)
    (let ((reaches (expand-from-seeds g (list a b))))
      (is (null reaches)
          "both are seeds, in the bundle already under their own band"))))

;;; ------------------------------------------------------------------
;;; The two tiers -- DES-0026 D2/D3, PLAN-0032 S3
;;; ------------------------------------------------------------------

(defun stub-source (id)
  "A source block of a known size, so a test can reason about the budget."
  (list :status :current :range "1-3" :file "src/a.lisp"
        :text (format nil "line one about ~a~%line two~%line three~%" id)))

(test only-the-first-few-seeds-carry-a-body
  ;; DES-0026 D2. The expensive tier is bounded by a count of definitions and
  ;; the cheap one by tokens, because that is the unit each is rationed in.
  (let* ((g (seed-graph "alpha" "alpha-two" "alpha-three" "alpha-four"))
         (bundle (build-context g "alpha" :source-fn #'stub-source
                                          :source-definitions 2))
         (sourced (remove-if-not (lambda (i) (getf i :source)) (getf bundle :items))))
    (is (= 2 (length sourced)) "two bodies, not four")
    (is (= 2 (getf bundle :sourced)))
    (is (every (lambda (i) (eq :seed (getf i :band))) sourced)
        "the source tier is the first N seeds until DES-0026 D9's one order exists")))

(test a-caller-that-asks-for-no-bodies-gets-the-bundle-it-always-got
  ;; SOURCE-FN is NIL for every caller that existed before this step, and the
  ;; absence has to cost nothing rather than merely not crash.
  (let ((bundle (build-context (seed-graph "alpha" "alpha-two") "alpha")))
    (is (= 0 (getf bundle :sourced)))
    (is (= 0 (getf bundle :source-tokens)))
    (is (notany (lambda (i) (getf i :source)) (getf bundle :items)))))

(test a-body-is-not-charged-to-the-index-budget
  ;; The defect this guard exists for, measured before it: charging a 400-token
  ;; body to the index budget spent the cheap tier on the expensive one, and
  ;; `context data-handler' named 14 of the 157 entities the walk had reached.
  ;; Two budgets that share one counter are one budget.
  ;; Asserted as "no more", not "the same", which is what the first draft got
  ;; wrong: an entity in the source tier leaves the index budget altogether, so
  ;; the index figure legitimately *falls* when bodies are asked for. What must
  ;; never happen is the other direction -- a body inflating the tier that is
  ;; supposed to be cheap.
  (let* ((g (seed-graph "alpha" "alpha-two" "alpha-three"))
         (plain (build-context g "alpha"))
         (sourced (build-context g "alpha" :source-fn #'stub-source
                                           :source-definitions 3)))
    (is (plusp (getf sourced :source-tokens)) "the bodies cost something")
    (is (<= (getf sourced :tokens) (getf plain :tokens))
        "and none of it came out of the index tier")
    ;; The invariant stated the other way round, on a budget tight enough to
    ;; bite: bodies must not cost the index tier a single entry.
    (let ((tight-plain (build-context g "alpha" :budget 40))
          (tight-sourced (build-context g "alpha" :budget 40
                                                  :source-fn #'stub-source
                                                  :source-definitions 1)))
      (is (>= (count-if-not (lambda (i) (getf i :source)) (getf tight-sourced :items))
              (count-if-not (lambda (i) (getf i :source)) (getf tight-plain :items)))
          "a tight index budget holds at least as many lines when bodies are added"))))

(test the-budget-is-measured-against-what-is-printed
  ;; RENDER-ITEM is used to cost an item and to print it, so the two cannot
  ;; disagree. They did: the estimate was taken from the serialised plist, keys
  ;; and all, which over-counts the rendered line about fivefold -- so an index
  ;; tier sized on the premise that a line costs 15 tokens bought a fifth of
  ;; what it was budgeted for.
  (let* ((bundle (build-context (seed-graph "alpha" "alpha-two") "alpha"))
         (item (first (getf bundle :items)))
         (rendered (loom-knowledge::render-item item)))
    (is (search "alpha" rendered) "the item's own line")
    (is (< (loom-knowledge::estimate-tokens rendered)
           (loom-knowledge::estimate-tokens (princ-to-string item)))
        "the plist is the bigger number, and it is not the one that is spent")))

;;; ------------------------------------------------------------------
;;; Convergence -- DES-0026 D7, PLAN-0032 S2
;;; ------------------------------------------------------------------

(test convergence-counts-the-distinct-seeds-that-reach-an-entity
  ;; D7's answer to R5, the clause REQ-0016 has never had one for. Eight seeds
  ;; on a prose query are eight guesses, and the guesses are not independent: if
  ;; several reach one entity, that entity is what the task was about, and no
  ;; lexical score could have said so because the evidence is not in the names.
  (let* ((g (make-graph))
         (a (k-def 'class-entity "alpha" "src/a.lisp"))
         (b (k-def 'class-entity "beta" "src/a.lisp"))
         (shared (k-def 'class-entity "shared" "src/a.lisp")))
    (dolist (e (list a b shared)) (add-entity g e))
    (k-edge g :inherits shared a)
    (k-edge g :inherits shared b)
    (let ((r (reach-named (expand-from-seeds g (list a b)) "shared")))
      (is (= 2 (reach-convergence r)) "both seeds reached it")
      (is (= 1 (reach-cost r)))
      (is (= 1 (loom-knowledge::effective-cost r))
          "already at the floor, so the discount has nothing left to give"))))

(test the-discount-is-one-cheap-edge-per-extra-seed-and-floors-at-one
  ;; The floor is argued rather than tuned: the cheapest edge costs 1, so a
  ;; second seed is worth exactly the strongest structural claim the table
  ;; admits and never more. Convergence may promote past a call hop and may not
  ;; promote past a hierarchy, because three seeds meeting at a utility function
  ;; is an ordinary thing to happen.
  (flet ((eff (cost convergence)
           (loom-knowledge::effective-cost
            (loom-knowledge::make-reach :entity (k-def 'function-entity "f" "src/a.lisp")
                                        :cost cost :convergence convergence))))
    (is (= 4 (eff 4 1)))
    (is (= 3 (eff 4 2)) "one extra seed, one cheap edge")
    (is (= 2 (eff 4 3)))
    (is (= 1 (eff 4 9)) "and it never goes below the cheapest edge in the table")))

(test a-container-is-never-discounted-by-convergence
  ;; D8's docstring predicted this before it was written, and it happened:
  ;; measured on game-server, five of the eight seeds are defined in
  ;; server/server.lisp, so the file arrived at x5 and a raw cost of 3 became an
  ;; effective 1 -- a directory listing lifted above the definitions the query
  ;; was about. D8 stops a container being a route; this stops co-location alone
  ;; making it a destination.
  (let ((file (make-instance 'file-entity :name "src/a.lisp"
                             :properties (properties-table (list :path "src/a.lisp")))))
    (is (= 3 (loom-knowledge::effective-cost
              (loom-knowledge::make-reach :entity file :cost 3 :convergence 5)))
        "raw cost, undiscounted")))

(test convergence-reorders-and-does-not-extend
  ;; The horizon is checked against raw cost during the walk, so a discount
  ;; cannot pull in an entity the walk never reached. Otherwise convergence
  ;; would quietly widen the bound it is supposed to be ordered within.
  (let* ((g (make-graph))
         (a (k-def 'function-entity "alpha" "src/a.lisp"))
         (b (k-def 'function-entity "beta" "src/a.lisp"))
         (far (k-def 'function-entity "far" "src/b.lisp"))
         (farther (k-def 'function-entity "farther" "src/b.lisp")))
    (dolist (e (list a b far farther)) (add-entity g e))
    ;; both seeds call FAR (cost 3 out), and FAR calls FARTHER (3 more = 6)
    (k-edge g :calls a far)
    (k-edge g :calls b far)
    (k-edge g :calls far farther)
    (let ((reaches (expand-from-seeds g (list a b))))
      (is (= 2 (reach-convergence (reach-named reaches "far"))))
      (is (null (reach-named reaches "farther"))
          "cost 6 is past the horizon and convergence does not buy it in"))))
