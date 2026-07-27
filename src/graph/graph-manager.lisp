;;;; The in-memory Graph Manager: the live store of ENTITY and RELATIONSHIP
;;;; objects, validated against the LOOM-ONTOLOGY registry.
;;;;
;;;; This is the reasoning layer -- analyzers write CLOS objects into it and
;;;; knowledge services read them back out. Persistence is deliberately not
;;;; its job: a Graph Adapter (not yet written) is what will later take these
;;;; objects and put them into permanent storage, keeping the graph usable in
;;;; any image without dragging in a database.

(in-package :loom-graph)

(define-condition graph-error (error)
  ((problems :initarg :problems :reader graph-error-problems))
  (:documentation "Signaled when an entity or relationship fails ontology
validation on entry to the graph. PROBLEMS is the plist list VALIDATE-ENTITY
or VALIDATE-RELATIONSHIP-ENDPOINTS returned.")
  (:report (lambda (c s)
             (format s "Graph rejected the write:~{~%  ~a~}"
                     (mapcar (lambda (p) (getf p :problem)) (graph-error-problems c))))))

(defstruct (graph (:constructor make-graph))
  "The whole in-memory graph: entities and relationships by id, plus indices
from an entity id to the relationship ids touching it, so traversal doesn't
require a scan."
  (entities      (make-hash-table :test #'equal) :type hash-table)
  (relationships (make-hash-table :test #'equal) :type hash-table)
  (from-index    (make-hash-table :test #'equal) :type hash-table)
  (to-index      (make-hash-table :test #'equal) :type hash-table))

;;;; ------------------------------------------------------------------
;;;; Entities
;;;; ------------------------------------------------------------------

(defun add-entity (graph entity)
  "Validate ENTITY against its registered type and store it under its id.
Signals GRAPH-ERROR, and stores nothing, if validation fails."
  (let ((problems (validate-entity entity)))
    (when problems
      (error 'graph-error :problems problems)))
  (setf (gethash (id entity) (graph-entities graph)) entity))

(defun get-entity (graph id)
  "The entity stored under ID, or NIL."
  (gethash id (graph-entities graph)))

(defun remove-entity (graph id)
  "Remove the entity ID and every relationship touching it, so the graph
never holds an edge pointing at an id it no longer stores."
  (dolist (rid (append (gethash id (graph-from-index graph))
                        (gethash id (graph-to-index graph))))
    (remove-relationship graph rid))
  (remhash id (graph-entities graph))
  (values))

(defun all-entities (graph)
  (loop for e being the hash-values of (graph-entities graph) collect e))

(defun entities-of-type (graph type-key)
  (remove type-key (all-entities graph) :key #'entity-type :test-not #'eq))

;;;; ------------------------------------------------------------------
;;;; Relationships
;;;; ------------------------------------------------------------------

(defun add-relationship (graph relationship)
  "Validate RELATIONSHIP's endpoints against its registered type and store
it, indexed by both ends. Both FROM-ID and TO-ID must already be entities in
GRAPH -- the ontology validates types, not existence, so that check happens
here. Signals GRAPH-ERROR, and stores nothing, if either check fails."
  (let ((from-entity (get-entity graph (from-id relationship)))
        (to-entity   (get-entity graph (to-id relationship))))
    (unless from-entity
      (error 'graph-error
             :problems (list (list :end :from :problem
                                    (format nil "unknown FROM entity ~s" (from-id relationship))))))
    (unless to-entity
      (error 'graph-error
             :problems (list (list :end :to :problem
                                    (format nil "unknown TO entity ~s" (to-id relationship))))))
    (let ((problems (validate-relationship-endpoints (rel-type relationship)
                                                      (entity-type from-entity)
                                                      (entity-type to-entity))))
      (when problems
        (error 'graph-error :problems problems))))
  (setf (gethash (id relationship) (graph-relationships graph)) relationship)
  (push (id relationship) (gethash (from-id relationship) (graph-from-index graph)))
  (push (id relationship) (gethash (to-id relationship) (graph-to-index graph)))
  relationship)

(defun get-relationship (graph id)
  (gethash id (graph-relationships graph)))

(defun remove-relationship (graph id)
  (let ((rel (get-relationship graph id)))
    (when rel
      (remhash id (graph-relationships graph))
      (setf (gethash (from-id rel) (graph-from-index graph))
            (remove id (gethash (from-id rel) (graph-from-index graph))))
      (setf (gethash (to-id rel) (graph-to-index graph))
            (remove id (gethash (to-id rel) (graph-to-index graph))))))
  (values))

(defun all-relationships (graph)
  (loop for r being the hash-values of (graph-relationships graph) collect r))

(defun relationships-from (graph entity-id &optional rel-type)
  "Relationships originating at ENTITY-ID, optionally filtered to REL-TYPE."
  (loop for rid in (gethash entity-id (graph-from-index graph))
        for r = (get-relationship graph rid)
        when (and r (or (null rel-type) (eq rel-type (rel-type r))))
          collect r))

(defun relationships-to (graph entity-id &optional rel-type)
  "Relationships terminating at ENTITY-ID, optionally filtered to REL-TYPE."
  (loop for rid in (gethash entity-id (graph-to-index graph))
        for r = (get-relationship graph rid)
        when (and r (or (null rel-type) (eq rel-type (rel-type r))))
          collect r))
