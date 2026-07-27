;;;; Ontology operations -- the only way the graph changes.
;;;; Implements Phase 1 Software Architecture SS4.4.
;;;;
;;;; The governing theme of the architecture is that the operation log is the
;;;; source of truth: "Analyzers do not mutate the graph; they emit
;;;; operations. The Graph Manager validates and applies operations; adapters
;;;; replay them."  These classes are that vocabulary.  They live in
;;;; LOOM-ONTOLOGY rather than LOOM-GRAPH precisely so an analyzer can speak
;;;; them without depending on storage (SS3, SS8.1).
;;;;
;;;; Each op is a small immutable value.  A list of ops produced by one
;;;; analysis pass is a transaction; LOOM-GRAPH:APPLY-TRANSACTION is what
;;;; validates and applies one.

(in-package :loom-ontology)

;;;; ==================================================================
;;;; The operations
;;;; ==================================================================

(defclass ontology-op ()
  ((workspace-id :initarg :workspace-id :initform nil :reader workspace-id
                 :documentation "Workspace the op belongs to, or NIL for ops
against the committed base graph."))
  (:documentation "Base class for every graph-changing operation."))

(defclass assert-entity-op (ontology-op)
  ((entity :initarg :entity :reader op-entity))
  (:documentation "Upsert an entity, keyed by its natural key (see
ENTITY-NATURAL-KEY).  Re-asserting an unchanged entity applies as a no-op,
which is what makes re-analysing an untouched file idempotent."))

(defclass assert-relationship-op (ontology-op)
  ((rel :initarg :rel :reader op-rel))
  (:documentation "Upsert a relationship, keyed by type plus endpoints.  The
endpoint ids may be the ids of entities asserted earlier in the same
transaction; the Graph Manager resolves them to whatever those asserts
actually landed on."))

(defclass retract-op (ontology-op)
  ((target-id :initarg :target-id :reader target-id))
  (:documentation "Remove an entity and cascade staleness to the facts
derived from it."))

(defclass mark-stale-op (ontology-op)
  ((target-id :initarg :target-id :reader target-id)
   (reason    :initarg :reason :initform nil :reader reason))
  (:documentation "Flag a fact as no longer verified.  Stale facts are kept
in the store and excluded from agent context until re-verified -- deleting
them is what would make the graph forget rather than doubt."))

(defclass update-properties-op (ontology-op)
  ((target-id :initarg :target-id :reader target-id)
   (changes   :initarg :changes :reader changes
              :documentation "Plist of property key -> new value."))
  (:documentation "Change properties on an entity already in the graph,
without re-asserting the whole thing."))

;;;; ==================================================================
;;;; Constructors -- what analyzers actually call
;;;; ==================================================================

(defun assert-entity (entity &optional workspace-id)
  (make-instance 'assert-entity-op :entity entity :workspace-id workspace-id))

(defun assert-relationship (rel &optional workspace-id)
  (make-instance 'assert-relationship-op :rel rel :workspace-id workspace-id))

(defun assert-edge (rel-type from to &key workspace-id (source :structural)
                                          (confidence 1.0) derived-from)
  "An ASSERT-RELATIONSHIP-OP for a REL-TYPE edge between entities FROM and TO.
Takes the entities rather than their ids because that is what an analyzer has
in hand, and it removes the commonest way to build a broken edge."
  (assert-relationship
   (make-instance 'relationship
                  :rel-type rel-type
                  :from-id (id from) :to-id (id to)
                  :source source :confidence confidence
                  :derived-from derived-from)
   workspace-id))

(defun retract (target-id &optional workspace-id)
  (make-instance 'retract-op :target-id target-id :workspace-id workspace-id))

(defun mark-stale (target-id &key reason workspace-id)
  (make-instance 'mark-stale-op :target-id target-id :reason reason
                                :workspace-id workspace-id))

(defun update-properties (target-id changes &optional workspace-id)
  (make-instance 'update-properties-op :target-id target-id :changes changes
                                       :workspace-id workspace-id))

;;;; ==================================================================
;;;; Natural keys -- the upsert identity of a fact (SS4.4)
;;;; ==================================================================
;;;;
;;;; An analyzer is stateless, so every pass mints fresh objects with fresh
;;;; uuids.  Without a second, content-derived identity, re-analysing an
;;;; unchanged file would double the graph.  The natural key is that identity:
;;;; entity types declare theirs with DEFENTITY's :NATURAL-KEY, and the Graph
;;;; Manager upserts onto whatever already carries the same key.

(defun entity-natural-key (e)
  "The upsert identity of entity E, or NIL if its type declares none.
Compare with EQUAL.  A type without a natural key is identified only by its
id, so every assert of one inserts -- right for minted knowledge such as
decisions, wrong for anything an analyzer re-derives from source."
  (let ((spec (find-entity-type (entity-type e))))
    (when (and spec (entity-type-natural-key spec))
      (cons (entity-type e)
            (loop for key in (entity-type-natural-key spec)
                  collect (if (eq key :name)
                              (and (slot-boundp e 'name) (name e))
                              (gethash key (properties e))))))))

(defun relationship-natural-key (r)
  "The upsert identity of relationship R: its type and its two endpoints.
Universal rather than declared -- an edge is fully described by what it
connects, so there is nothing per-type to say."
  (list (rel-type r) (from-id r) (to-id r)))

;;;; ==================================================================
;;;; Endpoint rebinding
;;;; ==================================================================

(defun rebind-relationship (r &key (from-id (from-id r)) (to-id (to-id r)))
  "A copy of R pointing at FROM-ID and TO-ID.
The Graph Manager needs this when an assert upserts onto an existing entity:
edges emitted in the same pass name the freshly minted id, and have to be
retargeted at the id that survived.  A copy rather than a mutation because
FROM-ID and TO-ID are readers -- an edge that has been applied does not move."
  (make-instance 'relationship
                 :id (id r) :rel-type (rel-type r)
                 :from-id from-id :to-id to-id
                 :properties (properties r)
                 :source (source r) :confidence (confidence r)
                 :derived-from (derived-from r)
                 :last-verified (last-verified r) :stale-p (stale-p r)))

;;;; ==================================================================
;;;; Printing -- ops show up in transaction errors and the op log
;;;; ==================================================================

(defmethod print-object ((op assert-entity-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~s ~s" (entity-type (op-entity op)) (name (op-entity op)))))

(defmethod print-object ((op assert-relationship-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~s ~a -> ~a" (rel-type (op-rel op))
            (from-id (op-rel op)) (to-id (op-rel op)))))

(defmethod print-object ((op retract-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a" (target-id op))))

(defmethod print-object ((op mark-stale-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a~@[ ~a~]" (target-id op) (reason op))))

(defmethod print-object ((op update-properties-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a ~s" (target-id op) (changes op))))
