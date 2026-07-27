;;;
;;; Tests for src/graph/graph-manager.lisp -- the in-memory Graph Manager.
;;;

(in-package :loom-graph-test)

(def-suite graph-manager
  :in all-tests
  :description "GRAPH struct, entity/relationship CRUD, and validation on entry.")

(in-suite graph-manager)

;;; ------------------------------------------------------------------
;;; Fixtures.  Named graph-test-* so they cannot collide with the real
;;; taxonomy in code-ontology.lisp, or with root-ontology-test's own
;;; fixtures, which share this global registry.
;;; ------------------------------------------------------------------

(defentity :graph-test-node
  :documentation "Fixture entity type: a thing that can sit in the graph."
  :properties ((:file string :required t)))

(defentity :graph-test-other
  :documentation "Fixture entity type not accepted as a GRAPH-TEST-EDGE endpoint.")

(defrelationship :graph-test-edge
  :from (:graph-test-node) :to (:graph-test-node)
  :transitive-impact t :impact-direction :reverse
  :documentation "Fixture relationship type restricted to GRAPH-TEST-NODE endpoints.")

(defun make-node (name &optional (file "src/foo.lisp"))
  (let ((e (make-instance 'graph-test-node-entity :name name)))
    (setp e :file file)
    e))

(defun make-other (name)
  (make-instance 'graph-test-other-entity :name name))

(defun make-edge (from-e to-e)
  (make-instance 'relationship :rel-type :graph-test-edge
                                :from-id (id from-e) :to-id (id to-e)))

;;; ------------------------------------------------------------------
;;; Entities
;;; ------------------------------------------------------------------

(test add-entity-stores-a-valid-entity
  (let* ((g (make-graph))
         (n (make-node "a")))
    (add-entity g n)
    (is (eq n (get-entity g (id n))))))

(test add-entity-rejects-an-invalid-entity
  (let* ((g (make-graph))
         (n (make-instance 'graph-test-node-entity :name "no-file")))
    (signals graph-error (add-entity g n))
    (is (null (get-entity g (id n)))
        "a rejected entity must not be stored")))

(test graph-error-carries-the-validation-problems
  (let ((g (make-graph)))
    (handler-case
        (add-entity g (make-instance 'graph-test-node-entity :name "no-file"))
      (graph-error (c)
        (is (eq :file (getf (first (graph-error-problems c)) :key)))))))

(test get-entity-returns-nil-for-an-unknown-id
  (is (null (get-entity (make-graph) "no-such-id"))))

(test remove-entity-removes-it
  (let* ((g (make-graph))
         (n (make-node "a")))
    (add-entity g n)
    (remove-entity g (id n))
    (is (null (get-entity g (id n))))))

(test remove-entity-cascades-to-touching-relationships
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (edge (make-edge a b)))
    (add-entity g a)
    (add-entity g b)
    (add-relationship g edge)
    (remove-entity g (id a))
    (is (null (get-relationship g (id edge)))
        "removing an endpoint must remove the edge, not leave it dangling")
    (is (null (relationships-to g (id b)))
        "the surviving endpoint's index must be cleaned up too")))

(test all-entities-returns-every-stored-entity
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b")))
    (add-entity g a)
    (add-entity g b)
    (is (= 2 (length (all-entities g))))
    (is (null (set-difference (list a b) (all-entities g))))))

(test entities-of-type-filters-by-entity-type
  (let* ((g (make-graph))
         (n (make-node "a"))
         (o (make-other "b")))
    (add-entity g n)
    (add-entity g o)
    (is (equal (list n) (entities-of-type g :graph-test-node)))
    (is (equal (list o) (entities-of-type g :graph-test-other)))))

;;; ------------------------------------------------------------------
;;; Relationships
;;; ------------------------------------------------------------------

(test add-relationship-stores-a-valid-edge
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (edge (make-edge a b)))
    (add-entity g a)
    (add-entity g b)
    (add-relationship g edge)
    (is (eq edge (get-relationship g (id edge))))))

(test add-relationship-rejects-an-unknown-from-endpoint
  (let* ((g (make-graph))
         (b (make-node "b"))
         (edge (make-instance 'relationship :rel-type :graph-test-edge
                                             :from-id "no-such-id" :to-id (id b))))
    (add-entity g b)
    (signals graph-error (add-relationship g edge))
    (is (null (get-relationship g (id edge))))))

(test add-relationship-rejects-an-unknown-to-endpoint
  (let* ((g (make-graph))
         (a (make-node "a"))
         (edge (make-instance 'relationship :rel-type :graph-test-edge
                                             :from-id (id a) :to-id "no-such-id")))
    (add-entity g a)
    (signals graph-error (add-relationship g edge))
    (is (null (get-relationship g (id edge))))))

(test add-relationship-rejects-a-bad-endpoint-type
  (let* ((g (make-graph))
         (a (make-node "a"))
         (o (make-other "b"))
         (edge (make-edge a o)))
    (add-entity g a)
    (add-entity g o)
    (signals graph-error (add-relationship g edge))
    (is (null (get-relationship g (id edge))))))

(test get-relationship-returns-nil-for-an-unknown-id
  (is (null (get-relationship (make-graph) "no-such-id"))))

(test remove-relationship-removes-it-and-its-index-entries
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (edge (make-edge a b)))
    (add-entity g a)
    (add-entity g b)
    (add-relationship g edge)
    (remove-relationship g (id edge))
    (is (null (get-relationship g (id edge))))
    (is (null (relationships-from g (id a))))
    (is (null (relationships-to g (id b))))))

(test all-relationships-returns-every-stored-relationship
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (c (make-node "c"))
         (e1 (make-edge a b))
         (e2 (make-edge a c)))
    (add-entity g a)
    (add-entity g b)
    (add-entity g c)
    (add-relationship g e1)
    (add-relationship g e2)
    (is (= 2 (length (all-relationships g))))))

(test relationships-from-finds-outgoing-edges
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (c (make-node "c"))
         (e1 (make-edge a b))
         (e2 (make-edge a c)))
    (add-entity g a)
    (add-entity g b)
    (add-entity g c)
    (add-relationship g e1)
    (add-relationship g e2)
    (is (= 2 (length (relationships-from g (id a)))))
    (is (null (relationships-from g (id b))))))

(test relationships-to-finds-incoming-edges
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (edge (make-edge a b)))
    (add-entity g a)
    (add-entity g b)
    (add-relationship g edge)
    (is (equal (list edge) (relationships-to g (id b))))
    (is (null (relationships-to g (id a))))))

(test relationships-from-can-filter-by-rel-type
  (let* ((g (make-graph))
         (a (make-node "a"))
         (b (make-node "b"))
         (edge (make-edge a b)))
    (add-entity g a)
    (add-entity g b)
    (add-relationship g edge)
    (is (equal (list edge) (relationships-from g (id a) :graph-test-edge)))
    (is (null (relationships-from g (id a) :some-other-type)))))
