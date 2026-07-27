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
require a scan.

ENTITY-KEYS and REL-KEYS are the second lookup path the upsert semantics of
SS5.4 need: natural key -> id, so an analyzer's freshly built object can be
recognised as something the index already holds.

ORIGIN-INDEX is the third, and it exists because of files-as-truth. SS7: an
index by origin file \"is what makes file-scoped retraction O(facts in the
file) rather than a scan\", and file-scoped retraction is what makes
reanalyzing a changed file a well-defined operation."
  (entities      (make-hash-table :test #'equal) :type hash-table)
  (relationships (make-hash-table :test #'equal) :type hash-table)
  (from-index    (make-hash-table :test #'equal) :type hash-table)
  (to-index      (make-hash-table :test #'equal) :type hash-table)
  (entity-keys   (make-hash-table :test #'equal) :type hash-table)
  (rel-keys      (make-hash-table :test #'equal) :type hash-table)
  (origin-index  (make-hash-table :test #'equal) :type hash-table))

;;;; ------------------------------------------------------------------
;;;; Origin-file index (SS5.1, SS7)
;;;; ------------------------------------------------------------------

(defun index-origin (graph fact)
  (let ((file (origin-file fact)))
    (when file (push (id fact) (gethash file (graph-origin-index graph))))))

(defun unindex-origin (graph fact)
  (let ((file (origin-file fact)))
    (when file
      (let ((remaining (remove (id fact) (gethash file (graph-origin-index graph))
                               :test #'equal)))
        (if remaining
            (setf (gethash file (graph-origin-index graph)) remaining)
            (remhash file (graph-origin-index graph)))))))

(defun facts-from-file (graph path)
  "Every entity and relationship read from PATH.
Backs RETRACT-FILE-OP, and answers \"what does Loom think this file says\"."
  (loop for fid in (gethash path (graph-origin-index graph))
        for fact = (or (gethash fid (graph-entities graph))
                       (gethash fid (graph-relationships graph)))
        when fact collect fact))

(defun origin-files (graph)
  "Every file the index currently holds facts from."
  (loop for file being the hash-keys of (graph-origin-index graph) collect file))

;;;; ------------------------------------------------------------------
;;;; Entities
;;;; ------------------------------------------------------------------

(defun add-entity (graph entity)
  "Validate ENTITY against its registered type and store it under its id.
Signals GRAPH-ERROR, and stores nothing, if validation fails.

A plain insert: it does not consult the natural-key index, so calling it
twice with equivalent entities leaves two of them. Upsert is the business of
APPLY-TRANSACTION, which is the path analyzers use."
  (let ((problems (validate-entity entity)))
    (when problems
      (error 'graph-error :problems problems)))
  ;; The id stops tracking the natural key here: from now on it is a value
  ;; other facts point at, and moving it is the Graph Manager's business.
  (setf (id-derived-p entity) nil)
  (let ((key (entity-natural-key entity)))
    (when key
      (setf (gethash key (graph-entity-keys graph)) (id entity))))
  (index-origin graph entity)
  (setf (gethash (id entity) (graph-entities graph)) entity))

(defun get-entity (graph id)
  "The entity stored under ID, or NIL."
  (gethash id (graph-entities graph)))

(defun find-entity-by-key (graph natural-key)
  "The entity carrying NATURAL-KEY, or NIL. See ONTOLOGY:ENTITY-NATURAL-KEY."
  (let ((id (and natural-key (gethash natural-key (graph-entity-keys graph)))))
    (and id (get-entity graph id))))

(defun remove-entity (graph id)
  "Remove the entity ID and every relationship touching it, so the graph
never holds an edge pointing at an id it no longer stores."
  (dolist (rid (append (gethash id (graph-from-index graph))
                        (gethash id (graph-to-index graph))))
    (remove-relationship graph rid))
  (let ((entity (get-entity graph id)))
    (when entity
      (unindex-origin graph entity)
      (let ((key (entity-natural-key entity)))
        (when key (remhash key (graph-entity-keys graph))))))
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
  (setf (gethash (relationship-natural-key relationship) (graph-rel-keys graph))
        (id relationship))
  (index-origin graph relationship)
  (setf (gethash (id relationship) (graph-relationships graph)) relationship)
  (push (id relationship) (gethash (from-id relationship) (graph-from-index graph)))
  (push (id relationship) (gethash (to-id relationship) (graph-to-index graph)))
  relationship)

(defun get-relationship (graph id)
  (gethash id (graph-relationships graph)))

(defun find-relationship-by-key (graph natural-key)
  "The relationship carrying NATURAL-KEY -- (rel-type from-id to-id) -- or NIL."
  (let ((id (and natural-key (gethash natural-key (graph-rel-keys graph)))))
    (and id (get-relationship graph id))))

(defun remove-relationship (graph id)
  (let ((rel (get-relationship graph id)))
    (when rel
      (remhash id (graph-relationships graph))
      (unindex-origin graph rel)
      (remhash (relationship-natural-key rel) (graph-rel-keys graph))
      (setf (gethash (from-id rel) (graph-from-index graph))
            (remove id (gethash (from-id rel) (graph-from-index graph))))
      (setf (gethash (to-id rel) (graph-to-index graph))
            (remove id (gethash (to-id rel) (graph-to-index graph))))))
  (values))

(defun all-relationships (graph)
  (loop for r being the hash-values of (graph-relationships graph) collect r))

;;; SS9: "Stale inferred facts are excluded from traversal entirely." That is
;;; enforced here, at the one place traversal reads edges, rather than left to
;;; each caller to remember. INCLUDE-STALE is for the re-verification pass,
;;; which is the only consumer that needs to see what it is re-checking.
;;;
;;; REL-TYPE is a keyword argument rather than the optional it used to be,
;;; now that there is a second argument to pass: a mixed &optional/&key lambda
;;; list would read (relationships-from g id :include-stale t) as a filter on
;;; the rel-type :include-stale and quietly answer NIL.

(defun edges-matching (graph ids rel-type include-stale)
  "The relationships named by IDS that pass the type and staleness filters."
  (loop for rid in ids
        for r = (get-relationship graph rid)
        when (and r
                  (or (null rel-type) (eq rel-type (rel-type r)))
                  (or include-stale (not (stale-p r))))
          collect r))

(defun relationships-from (graph entity-id &key rel-type include-stale)
  "Relationships originating at ENTITY-ID, optionally filtered to REL-TYPE.
Stale edges are omitted unless INCLUDE-STALE."
  (edges-matching graph (gethash entity-id (graph-from-index graph))
                  rel-type include-stale))

(defun relationships-to (graph entity-id &key rel-type include-stale)
  "Relationships terminating at ENTITY-ID, optionally filtered to REL-TYPE.
Stale edges are omitted unless INCLUDE-STALE."
  (edges-matching graph (gethash entity-id (graph-to-index graph))
                  rel-type include-stale))
