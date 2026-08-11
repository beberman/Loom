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

(defstruct (graph (:constructor %make-graph (lock entities relationships
                                             from-index to-index entity-keys
                                             rel-keys origin-index)))
  "The whole in-memory graph: entities and relationships by id, plus indices
from an entity id to the relationship ids touching it, so traversal doesn't
require a scan.

ENTITY-KEYS and REL-KEYS are the second lookup path the upsert semantics of
SS5.4 need: natural key -> id, so an analyzer's freshly built object can be
recognised as something the index already holds.

ORIGIN-INDEX is the third, and it exists because of files-as-truth. SS7: an
index by origin file \"is what makes file-scoped retraction O(facts in the
file) rather than a scan\", and file-scoped retraction is what makes
reanalyzing a changed file a well-defined operation.

All seven tables are PROTECTED-TABLEs sharing the one lock in LOCK (DES-0003
R3, R11). One lock and not seven: ADD-RELATIONSHIP alone needs four of these
tables held together, and four separate locks acquired in whatever order each
caller happened to write would deadlock the first time two callers disagreed.
With one lock there is no order to get wrong.

The initforms below are never evaluated -- the BOA constructor supplies every
slot, and MAKE-GRAPH is its only caller. They are NIL rather than a plausible
table because a plausible one would suggest a graph could be built without
going through MAKE-GRAPH, which is the one thing that would leave the seven
tables holding seven different locks."
  (lock          nil)
  (entities      nil :type protected-table)
  (relationships nil :type protected-table)
  (from-index    nil :type protected-table)
  (to-index      nil :type protected-table)
  (entity-keys   nil :type protected-table)
  (rel-keys      nil :type protected-table)
  (origin-index  nil :type protected-table))

(defun make-graph ()
  "A graph whose seven tables are guarded by one reentrant lock.

A function rather than DEFSTRUCT's own constructor, and the reason is
mechanical: a slot initform cannot see another slot's value, so there is no
way to write \"and pass this graph's lock to all seven tables\" as seven
initforms. The signature is unchanged -- every one of its call sites passes no
arguments -- so this is a change to how a graph is built and not to who may
build one."
  (let ((lock (bt:make-recursive-lock "loom-graph")))
    (flet ((table () (make-protected-table :test #'equal :lock lock)))
      (%make-graph lock (table) (table) (table) (table) (table) (table) (table)))))

(defmacro with-graph-lock ((graph) &body body)
  "Run BODY holding GRAPH's lock, so a multi-step mutation appears atomic.
DES-0003 R4.

Not exported, and that is the point of it. A protected-table makes each
primitive call crash-safe; it does not make ADD-RELATIONSHIP's five stores
across four tables one event, and a reader that catches the middle of one sees
a relationship present in RELATIONSHIPS and absent from FROM-INDEX -- each
operation individually safe, jointly a torn view. This macro is for the
compound mutations in this file and in transaction.lisp and for nothing else;
exporting it would let a caller outside loom-graph hold the write lock across
work of its own, which is a deadlock that no rule check would catch.

Every pt- primitive called inside BODY re-acquires the same lock this macro
already holds. That is what the lock being recursive is for, and it makes the
inner acquisitions cheaper than fresh ones rather than more expensive."
  `(bt:with-recursive-lock-held ((graph-lock ,graph))
     ,@body))

;;;; ------------------------------------------------------------------
;;;; Origin-file index (SS5.1, SS7)
;;;; ------------------------------------------------------------------

(defun index-origin (graph fact)
  (let ((file (origin-file fact)))
    (when file (pt-push (graph-origin-index graph) file (id fact)))))

(defun unindex-origin (graph fact)
  (let ((file (origin-file fact)))
    (when file
      (pt-delete-from-list (graph-origin-index graph) file (id fact) :test #'equal))))

(defun facts-from-file (graph path)
  "Every entity and relationship read from PATH.
Backs RETRACT-FILE-OP, and answers \"what does Loom think this file says\"."
  (loop for fid in (pt-get (graph-origin-index graph) path)
        for fact = (or (pt-get (graph-entities graph) fid)
                       (pt-get (graph-relationships graph) fid))
        when fact collect fact))

(defun origin-files (graph)
  "Every file the index currently holds facts from."
  (pt-keys (graph-origin-index graph)))

;;;; ------------------------------------------------------------------
;;;; Entities
;;;; ------------------------------------------------------------------

(defun add-entity (graph entity)
  "Validate ENTITY against its registered type and store it under its id.
Signals GRAPH-ERROR, and stores nothing, if validation fails.

A plain insert: it does not consult the natural-key index, so calling it
twice with equivalent entities leaves two of them. Upsert is the business of
APPLY-TRANSACTION, which is the path analyzers use."
  (with-graph-lock (graph)
    (let ((problems (validate-entity entity)))
      (when problems
        (error 'graph-error :problems problems)))
    ;; The id stops tracking the natural key here: from now on it is a value
    ;; other facts point at, and moving it is the Graph Manager's business.
    (setf (id-derived-p entity) nil)
    (let ((key (entity-natural-key entity)))
      (when key
        (setf (pt-get (graph-entity-keys graph) key) (id entity))))
    (index-origin graph entity)
    (setf (pt-get (graph-entities graph) (id entity)) entity)))

(defun get-entity (graph id)
  "The entity stored under ID, or NIL."
  (pt-get (graph-entities graph) id))

(defun find-entity-by-key (graph natural-key)
  "The entity carrying NATURAL-KEY, or NIL. See ONTOLOGY:ENTITY-NATURAL-KEY."
  (let ((id (and natural-key (pt-get (graph-entity-keys graph) natural-key))))
    (and id (get-entity graph id))))

(defun remove-entity (graph id)
  "Remove the entity ID and every relationship touching it, so the graph
never holds an edge pointing at an id it no longer stores."
  (with-graph-lock (graph)
    (dolist (rid (append (pt-get (graph-from-index graph) id)
                         (pt-get (graph-to-index graph) id)))
      (remove-relationship graph rid))
    (let ((entity (get-entity graph id)))
      (when entity
        (unindex-origin graph entity)
        (let ((key (entity-natural-key entity)))
          (when key (pt-rem (graph-entity-keys graph) key)))))
    (pt-rem (graph-entities graph) id))
  (values))

(defun all-entities (graph)
  (pt-values (graph-entities graph)))

(defun entities-of-type (graph type-key)
  (remove type-key (all-entities graph) :key #'entity-type :test-not #'eq))

;;;; ------------------------------------------------------------------
;;;; Relationships
;;;; ------------------------------------------------------------------

(defun add-relationship (graph relationship)
  "Validate RELATIONSHIP's endpoints against its registered type and store
it, indexed by both ends. Both FROM-ID and TO-ID must already be entities in
GRAPH -- the ontology validates types, not existence, so that check happens
here. Signals GRAPH-ERROR, and stores nothing, if either check fails.

The endpoint checks are inside the lock along with the stores, not merely
beside them: read outside it, a concurrent RETRACT-FILE could remove the FROM
entity between the check and the store, and this function would create the
dangling edge it exists to refuse."
  (with-graph-lock (graph)
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
    (setf (pt-get (graph-rel-keys graph) (relationship-natural-key relationship))
          (id relationship))
    (index-origin graph relationship)
    (setf (pt-get (graph-relationships graph) (id relationship)) relationship)
    (pt-push (graph-from-index graph) (from-id relationship) (id relationship))
    (pt-push (graph-to-index graph) (to-id relationship) (id relationship))
    relationship))

(defun get-relationship (graph id)
  (pt-get (graph-relationships graph) id))

(defun find-relationship-by-key (graph natural-key)
  "The relationship carrying NATURAL-KEY -- (rel-type from-id to-id) -- or NIL."
  (let ((id (and natural-key (pt-get (graph-rel-keys graph) natural-key))))
    (and id (get-relationship graph id))))

(defun remove-relationship (graph id)
  (with-graph-lock (graph)
    (let ((rel (get-relationship graph id)))
      (when rel
        (pt-rem (graph-relationships graph) id)
        (unindex-origin graph rel)
        (pt-rem (graph-rel-keys graph) (relationship-natural-key rel))
        ;; PT-DELETE-FROM-LIST rather than a read, a REMOVE and a write:
        ;; composed that way, two threads retracting different edges from one
        ;; entity can each write back a list computed before the other's
        ;; removal, and one retraction is lost. It also drops the key once the
        ;; last edge goes, where the old code left it mapped to NIL --
        ;; unobservable, since nothing enumerates these two tables' keys, but
        ;; it stops the indices growing by one entry per entity that ever had
        ;; an edge.
        (pt-delete-from-list (graph-from-index graph) (from-id rel) id)
        (pt-delete-from-list (graph-to-index graph) (to-id rel) id))))
  (values))

(defun all-relationships (graph)
  (pt-values (graph-relationships graph)))

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
  (edges-matching graph (pt-get (graph-from-index graph) entity-id)
                  rel-type include-stale))

(defun relationships-to (graph entity-id &key rel-type include-stale)
  "Relationships terminating at ENTITY-ID, optionally filtered to REL-TYPE.
Stale edges are omitted unless INCLUDE-STALE."
  (edges-matching graph (pt-get (graph-to-index graph) entity-id)
                  rel-type include-stale))
