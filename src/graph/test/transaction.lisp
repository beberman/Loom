;;;
;;; Tests for BUG-0030 F1: an op that fails endpoint validation is dropped,
;;; counted and reported rather than rejecting its transaction.
;;;
;;; The population these cover is the one no tree in the project produces on
;;; purpose. front-end indexed nothing at all because :MENTIONS had no
;;; :DOCUMENT in its :TO list, and the fix for that was one ontology entry; the
;;; fix for the next missing entry is that the pass survives it. So the fixture
;;; is a synthetic tree with a deliberately illegal edge in it, asserted
;;; alongside facts that must still land.
;;;

(in-package :loom-graph-test)

(def-suite transaction
  :in all-tests
  :description "Endpoint problems drop their op; everything else rejects the
transaction.")

(in-suite transaction)

;;; The fixtures of graph-manager.lisp are reused rather than repeated:
;;; :GRAPH-TEST-EDGE runs GRAPH-TEST-NODE -> GRAPH-TEST-NODE, and
;;; :GRAPH-TEST-OTHER is a type it may not terminate at. An edge from a node to
;;; an other is exactly the shape of the front-end failure -- a legal
;;; relationship type between two entity types its declaration does not list.

(defun tx-node (name file)
  (let ((e (make-instance 'graph-test-node-entity :name name :origin-file file)))
    (setp e :file file)
    e))

(defun tx-edge (from to file)
  (make-instance 'relationship :rel-type :graph-test-edge
                               :from-id (id from) :to-id (id to)
                               :origin-file file))

(defun tx-other (name file)
  (let ((e (make-instance 'graph-test-other-entity :name name :origin-file file)))
    e))

;;; ------------------------------------------------------------------
;;; The drop
;;; ------------------------------------------------------------------

(test an-illegal-endpoint-drops-its-op-and-not-the-transaction
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (b (tx-node "b" "src/one.lisp"))
         (o (tx-other "o" "src/one.lisp"))
         (good (tx-edge a b "src/one.lisp"))
         (bad  (tx-edge a o "src/one.lisp")))
    (apply-transaction g (list (assert-entity a) (assert-entity b)
                               (assert-entity o)
                               (assert-relationship bad)
                               (assert-relationship good)))
    (is (not (null (get-entity g (id a)))) "the entities still land")
    (is (not (null (get-entity g (id o))))
        "including the one the illegal edge pointed at")
    (is (not (null (get-relationship g (id good))))
        "and so does the legal edge that followed the illegal one")
    (is (null (get-relationship g (id bad)))
        "the illegal edge is the only thing missing")))

(test a-dropped-op-is-counted-and-describes-itself
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (o (tx-other "o" "src/one.lisp")))
    (apply-transaction g (list (assert-entity a) (assert-entity o)
                               (assert-relationship (tx-edge a o "src/one.lisp"))))
    (is (= 1 (dropped-edge-count g)))
    (let ((drop (first (dropped-edges g))))
      (is (eq :graph-test-edge (getf drop :rel-type)))
      (is (eq :graph-test-node (getf drop :from-type)))
      (is (eq :graph-test-other (getf drop :to-type)))
      (is (equal "src/one.lisp" (getf drop :origin-file)))
      (is (search "cannot terminate" (getf drop :problem))
          "the ontology's own sentence, which is what names the missing entry")
      (is (null (getf drop :op))
          "the op itself is not retained -- the record outlives the transaction"))))

(test apply-transaction-returns-the-dropped-problems
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (o (tx-other "o" "src/one.lisp")))
    (multiple-value-bind (remap dropped)
        (apply-transaction g (list (assert-entity a) (assert-entity o)
                                   (assert-relationship (tx-edge a o "src/one.lisp"))))
      (is (not (null remap)) "the remap is still the primary value")
      (is (= 1 (length dropped)))
      (is (eql 2 (getf (first dropped) :index))
          "the problem names the op's position, as a rejection's would"))))

(test an-edge-to-an-unknown-entity-drops-rather-than-rejects
  ;; The other half of endpoint validation, and the one a resolution pass hits:
  ;; an edge whose target was retracted between the derivation and the apply.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (edge (make-instance 'relationship :rel-type :graph-test-edge
                                            :from-id (id a) :to-id "no-such-id"
                                            :origin-file "src/one.lisp")))
    (apply-transaction g (list (assert-entity a) (assert-relationship edge)))
    (is (not (null (get-entity g (id a)))))
    (is (= 1 (dropped-edge-count g)))))

;;; ------------------------------------------------------------------
;;; What is still fatal
;;; ------------------------------------------------------------------

(test an-invalid-entity-still-rejects-the-whole-transaction
  ;; F1 widened nothing but endpoint validation. An entity missing a required
  ;; property is a claim that damages what the graph would hold, not one Loom
  ;; declines to record, and it must still leave the graph untouched.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (broken (make-instance 'graph-test-node-entity :name "no-file")))
    (signals transaction-error
      (apply-transaction g (list (assert-entity a) (assert-entity broken))))
    (is (null (get-entity g (id a)))
        "nothing applied, including the op that was sound")))

(test a-setting-carrying-a-value-rejects-the-whole-transaction
  ;; DES-0054 R8. :SETTING is closed, so a value stored on one fails its
  ;; transaction and the graph holds no setting afterwards.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (s (make-instance 'setting-entity :name "K"
                           :properties (properties-table
                                        (list :name "K" :sources '(:secret)
                                              :value "hunter2")))))
    (signals transaction-error
      (apply-transaction g (list (assert-entity a) (assert-entity s))))
    (is (null (get-entity g (id s))))
    (is (null (get-entity g (id a)))
        "nothing applied, including the op that was sound")))

(test a-retract-of-an-unknown-target-still-rejects
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp")))
    (signals transaction-error
      (apply-transaction g (list (assert-entity a) (retract "no-such-id"))))
    (is (null (get-entity g (id a))))))

;;; ------------------------------------------------------------------
;;; The count is a function of the files, not of history
;;; ------------------------------------------------------------------

(test reanalysing-the-file-clears-its-drops
  ;; DEC-0001 applied to a gap. The drop is keyed by origin file, so the pass
  ;; that re-reads the file decides again what it can record -- and a drop that
  ;; stops happening stops being reported instead of accumulating one per pass.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (o (tx-other "o" "src/one.lisp")))
    (flet ((one-pass (&rest ops)
             (apply-transaction g (list* (retract-file "src/one.lisp") ops))))
      (one-pass (assert-entity a) (assert-entity o)
            (assert-relationship (tx-edge a o "src/one.lisp")))
      (is (= 1 (dropped-edge-count g)))
      (one-pass (assert-entity a) (assert-entity o)
            (assert-relationship (tx-edge a o "src/one.lisp")))
      (is (= 1 (dropped-edge-count g))
          "a second identical pass reports one drop, not two")
      (one-pass (assert-entity a) (assert-entity o))
      (is (= 0 (dropped-edge-count g))
          "and a pass that no longer draws the edge reports none"))))

;;; ------------------------------------------------------------------
;;; A retract names a fact, not only an entity (BUG-0034)
;;; ------------------------------------------------------------------
;;;
;;; FEDERATED-RETRACTIONS builds one RETRACT-OP per federated edge it holds,
;;; and a relationship id resolved to no entity -- so PLAN-OP reported "cannot
;;; retract unknown entity" and one op took the whole federation transaction
;;; with it. Invisible on a first pass, which has no federated edges yet to
;;; retract, and fatal on every pass after.

(test a-retract-of-a-relationship-removes-the-edge-and-keeps-its-endpoints
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (b (tx-node "b" "src/one.lisp"))
         (edge (tx-edge a b "src/one.lisp")))
    (apply-transaction g (list (assert-entity a) (assert-entity b)
                               (assert-relationship edge)))
    (is (not (null (get-relationship g (id edge)))))
    (apply-transaction g (list (retract (id edge))))
    (is (null (get-relationship g (id edge))))
    (is (not (null (get-entity g (id a)))) "an edge is not its endpoints")
    (is (not (null (get-entity g (id b)))))
    (is (null (relationships-from g (id a) :rel-type :graph-test-edge))
        "and the indices no longer name it either")))

(test a-retract-of-an-entity-still-removes-the-entity
  ;; The guard on the clause order: an id that names an entity must take the
  ;; entity path, cascade included, exactly as it always did.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (b (tx-node "b" "src/one.lisp")))
    (apply-transaction g (list (assert-entity a) (assert-entity b)
                               (assert-relationship (tx-edge a b "src/one.lisp"))))
    (apply-transaction g (list (retract (id b))))
    (is (null (get-entity g (id b))))
    (is (not (null (get-entity g (id a)))))
    (is (null (relationships-from g (id a) :rel-type :graph-test-edge))
        "removing an entity takes the edges touching it, as it always has")))

(test a-retract-of-an-id-that-names-nothing-is-still-fatal
  ;; Widened to relationships and no further. An op that cannot say what it
  ;; means to remove is not endpoint validation, and dropping it silently would
  ;; leave a stale edge behind while reporting success.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp")))
    (signals transaction-error
      (apply-transaction g (list (assert-entity a) (retract "no-such-id"))))
    (is (null (get-entity g (id a))) "nothing applied")))

;;; ------------------------------------------------------------------
;;; An edge's property table is built by a reader, not by being stored
;;; (PLAN-0060 step 2 follow-up)
;;; ------------------------------------------------------------------
;;;
;;; ADD-RELATIONSHIP and PLAN-OP asked every edge whether it was federated, and
;;; that reads the edge's table, so every edge had one built: 95972 tables on
;;; front-end, 17.4 MB of them for :VIA alone. They ask only when the TO end is
;;; missing now.

(test storing-an-edge-does-not-build-its-property-table
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (b (tx-node "b" "src/one.lisp"))
         (edge (make-instance 'relationship :rel-type :graph-test-edge
                                            :from-id (id a) :to-id (id b)
                                            :origin-file "src/one.lisp"
                                            :property-plist '(:via ("b")))))
    (apply-transaction g (list (assert-entity a) (assert-entity b)
                               (assert-relationship edge)))
    (is (not (null (get-relationship g (id edge)))) "control: the edge landed")
    (is (not (slot-boundp (get-relationship g (id edge)) 'loom-ontology::properties))
        "the stored edge still holds its plist")
    (is (equal '("b") (getp (get-relationship g (id edge)) :via)))))

(test a-federated-edge-to-an-entity-this-graph-lacks-still-lands
  ;; The check moved from before the TO test to inside it. This is the case
  ;; it exists for (DES-0025), through the transaction and through
  ;; ADD-RELATIONSHIP, which repeats it.
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (far (make-instance 'relationship
                             :rel-type :graph-test-edge
                             :from-id (id a) :to-id "node:elsewhere:far"
                             :origin-file "src/one.lisp"
                             :property-plist '(:federated t :foreign-repository "other")))
         (near (make-instance 'relationship
                              :rel-type :graph-test-edge
                              :from-id (id a) :to-id "node:elsewhere:near"
                              :origin-file "src/one.lisp"
                              :property-plist '(:federated t :foreign-repository "other"))))
    (apply-transaction g (list (assert-entity a) (assert-relationship far)))
    (is (not (null (get-relationship g (id far)))) "through the transaction")
    (add-relationship g near)
    (is (not (null (get-relationship g (id near)))) "through ADD-RELATIONSHIP")))

(test an-unfederated-edge-to-an-entity-this-graph-lacks-is-still-refused
  (let* ((g (make-graph))
         (a (tx-node "a" "src/one.lisp"))
         (ghost (make-instance 'relationship
                               :rel-type :graph-test-edge
                               :from-id (id a) :to-id "node:elsewhere:ghost"
                               :origin-file "src/one.lisp"
                               :property-plist '(:via ("ghost")))))
    (apply-transaction g (list (assert-entity a)))
    (signals graph-error (add-relationship g ghost))))
