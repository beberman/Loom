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
which is what makes re-analysing an untouched file idempotent.

Emitted by an analyzer, and -- since DES-0002 -- by a resolution pass as
well.  A definer macro's call site brings a name into existence that appears
nowhere in the source as a definition, and the decision that it did needs the
whole workspace, which no file-scoped analyzer has.  So \"every entity comes
from an analyzer\" is no longer true; the invariant that replaced it is
\"every entity comes from an analyzer, or from a resolution pass that owns its
full lifecycle -- mint and retract -- and marks what it made with
:GENERATED-BY.\"  The second clause is what the first bought: an analyzer's
entities are cleaned up by RETRACT-FILE, and a pass that mints has no single
file whose reanalysis would do the same."))

(defclass assert-relationship-op (ontology-op)
  ((rel :initarg :rel :reader op-rel))
  (:documentation "Upsert a relationship, keyed by type plus endpoints.  The
endpoint ids may be the ids of entities asserted earlier in the same
transaction; the Graph Manager resolves them to whatever those asserts
actually landed on."))

(defclass retract-file-op (ontology-op)
  ((path :initarg :path :reader path))
  (:documentation "Retract every fact whose origin-file is PATH.

SS5.4: \"The file-scoped retract is the workhorse of incremental update:
reanalyzing a changed file is retract-file followed by the fresh asserts,
which is simple, obviously correct, and cheap at the granularity of one
file.\" It is also the only mechanism by which a *deleted* definition leaves
the index -- a stateless analyzer emits what it found, never what it stopped
finding, so absence can only be expressed by clearing the file first."))

(defclass retract-op (ontology-op)
  ((target-id :initarg :target-id :reader target-id))
  (:documentation "Remove one fact -- an entity or a relationship -- by id.
An entity also cascades staleness to the facts derived from it.

Entities only until BUG-0034, which is how a whole federation pass came to be
rejected. FEDERATED-RETRACTIONS builds one of these per federated edge it
holds, and a relationship id resolved to no entity, so the op reported
\"cannot retract unknown entity\" and took the transaction with it -- every
retraction and every re-derived cross-repository edge alike. It was invisible
on a first pass, which has no federated edges yet to retract, and fatal on
every pass after."))

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

(defun assert-edge (rel-type from to &key workspace-id origin-file
                                          (source :structural)
                                          (confidence 1.0) derived-from
                                          properties)
  "An ASSERT-RELATIONSHIP-OP for a REL-TYPE edge between entities FROM and TO.
Takes the entities rather than their ids because that is what an analyzer has
in hand, and it removes the commonest way to build a broken edge.

ORIGIN-FILE defaults to FROM's, which is right for a structural edge: the
file that says A calls B is the file A is written in, and that is the file
whose reanalysis should retract the claim.

PROPERTIES is a plist stored with PROPERTIES-TABLE, which is how a :CALLS edge
carries :VIA (PLAN-0060 step 2). NIL gives the empty table every edge had
before this keyword. An existing edge absorbs these properties by replacing its
own, so a caller asserting an edge a second time must pass the whole plist."
  (assert-relationship
   (make-instance 'relationship
                  :rel-type rel-type
                  :from-id (id from) :to-id (id to)
                  :origin-file (or origin-file (origin-file from))
                  :source source :confidence confidence
                  :derived-from derived-from
                  :properties (properties-table properties))
   workspace-id))

(defun retract-file (path &optional workspace-id)
  (make-instance 'retract-file-op :path path :workspace-id workspace-id))

(defun retract (target-id &optional workspace-id)
  (make-instance 'retract-op :target-id target-id :workspace-id workspace-id))

(defun mark-stale (target-id &key reason workspace-id)
  (make-instance 'mark-stale-op :target-id target-id :reason reason
                                :workspace-id workspace-id))

(defun update-properties (target-id changes &optional workspace-id)
  (make-instance 'update-properties-op :target-id target-id :changes changes
                                       :workspace-id workspace-id))

;;;; ==================================================================
;;;; Endpoint rebinding
;;;; ==================================================================

(defun rebind-relationship (r &key (from-id (from-id r)) (to-id (to-id r)))
  "A copy of R pointing at FROM-ID and TO-ID.
The Graph Manager needs this when an assert upserts onto an entity carrying a
different id from the one the edge named. A copy rather than a mutation
because FROM-ID and TO-ID are readers -- an edge that has been applied does
not move -- and the copy deliberately does not carry R's id: an edge's id is
derived from its endpoints, so moving an endpoint moves the id with it."
  (make-instance 'relationship
                 :rel-type (rel-type r)
                 :from-id from-id :to-id to-id
                 :properties (properties r)
                 :origin-file (origin-file r)
                 :source (source r) :confidence (confidence r)
                 :derived-from (derived-from r)
                 :stale-p (stale-p r)))

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

(defmethod print-object ((op retract-file-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a" (path op))))

(defmethod print-object ((op retract-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a" (target-id op))))

(defmethod print-object ((op mark-stale-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a~@[ ~a~]" (target-id op) (reason op))))

(defmethod print-object ((op update-properties-op) stream)
  (print-unreadable-object (op stream :type t)
    (format stream "~a ~s" (target-id op) (changes op))))
