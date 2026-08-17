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
