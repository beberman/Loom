;;;; Transactions: validating and applying a batch of ontology operations.
;;;; Implements Phase 1 Software Architecture SS5.2, and the operation-
;;;; application semantics of SS4.4.
;;;;
;;;; This is the other half of the event-sourced core. Analyzers emit
;;;; operations and know nothing about storage (SS8.1); everything that
;;;; interprets an operation lives here, in the one component permitted to
;;;; modify the graph.
;;;;
;;;; Two rules from the architecture are implemented here rather than in any
;;;; analyzer, which is what keeps analyzers stateless:
;;;;
;;;;   Upsert.     An assert is keyed by natural key, so re-analysing an
;;;;               unchanged file lands on the entities the last pass made
;;;;               and applies as a no-op (SS4.4, SS12.4).
;;;;   Staleness.  A retract cascades to the facts derived from its target,
;;;;               flagging them rather than deleting them (SS4.4).
;;;;
;;;; SS5.1 puts a single writer thread in front of all of this, consuming
;;;; transactions from a mailbox. That loop is not built yet; APPLY-TRANSACTION
;;;; is the synchronous core it will call, and is already the only write path
;;;; analyzers have.

(in-package :loom-graph)

(define-condition transaction-error (graph-error)
  ((ops :initarg :ops :initform '() :reader transaction-error-ops))
  (:documentation "Signaled when any operation in a transaction fails
validation. SS5.2: \"A transaction either applies atomically or is rejected
with a structured error naming the failing operation\" -- so every problem
plist carries the :INDEX and :OP it came from, and nothing has been applied
by the time this is signaled.")
  (:report
   (lambda (c s)
     (format s "Transaction rejected, nothing applied:~{~%  ~a~}"
             (mapcar (lambda (p)
                       (format nil "op ~a ~a: ~a"
                               (getf p :index) (getf p :op) (getf p :problem)))
                     (graph-error-problems c))))))

;;;; ==================================================================
;;;; Transaction context
;;;; ==================================================================
;;;;
;;;; An analyzer is stateless, so every pass mints fresh objects with fresh
;;;; uuids -- including the edges, which name those fresh ids. When an assert
;;;; upserts onto an entity the graph already holds, the edges emitted
;;;; alongside it are pointing at an id that is about to be discarded. REMAP
;;;; is what fixes that: it records, for each id the transaction mentions, the
;;;; id the transaction actually landed on, and every later op resolves
;;;; through it. Without this, re-analysing an unchanged file would upsert the
;;;; entities correctly and then insert a whole second set of edges.

(defstruct (tx (:constructor make-tx (graph)))
  "Bookkeeping for one in-flight transaction."
  (graph nil :type (or null graph))
  ;; id as written in the ops -> id it resolves to in the graph
  (remap (make-hash-table :test #'equal) :type hash-table)
  ;; natural key -> id, for keys asserted earlier in this same transaction
  (keys  (make-hash-table :test #'equal) :type hash-table)
  ;; id -> entity-type, for entities this transaction will have created
  (types (make-hash-table :test #'equal) :type hash-table))

(defun tx-resolve (tx id)
  "The id ID resolves to after upserts. ID itself when nothing remapped it."
  (gethash id (tx-remap tx) id))

(defun tx-entity-type (tx id)
  "The entity type ID will have once this transaction is applied, or NIL if
ID names no entity -- neither one already stored nor one this transaction
asserts."
  (or (gethash id (tx-types tx))
      (let ((e (get-entity (tx-graph tx) id)))
        (and e (entity-type e)))))

;;;; ==================================================================
;;;; The protocol -- adding an op type is two methods
;;;; ==================================================================

(defgeneric plan-op (tx op)
  (:documentation "Check OP against TX without changing the graph, recording
in TX whatever later ops need to resolve against. Returns a list of problem
plists; NIL means the op is sound."))

(defgeneric apply-op (tx op)
  (:documentation "Apply OP. Called only after PLAN-OP passed for every op in
the transaction, so this may assume its preconditions hold."))

;;;; ==================================================================
;;;; Index maintenance and merging
;;;; ==================================================================

(defun reindex-entity (graph e old-key)
  "Move E's natural-key index entry after its properties changed.

The one function outside graph-manager.lisp that reaches into a graph table,
which is why it is easy to miss and why it is named here rather than left to a
grep. Neither DES-0003 nor DES-0004 lists it, and DES-0004's promise to a
concurrent reader -- \"no entity missing its natural-key index entry\" --
is exactly what the gap between these two lines would break."
  (with-graph-lock (graph)
    (let ((new-key (entity-natural-key e)))
      (unless (equal old-key new-key)
        (when old-key (pt-rem (graph-entity-keys graph) old-key))
        (when new-key (setf (pt-get (graph-entity-keys graph) new-key) (id e))))))
  e)

(defun absorb-provenance (target incoming)
  "Overwrite TARGET's provenance from INCOMING.
A re-assert is a fresh observation, so this is also what clears STALE-P: the
fact has just been re-verified by the analyzer that emitted it."
  (setf (source target)        (source incoming)
        (confidence target)    (confidence incoming)
        (derived-from target)  (derived-from incoming)
        (origin-file target)   (origin-file incoming)
        (stale-p target)       (stale-p incoming))
  target)

(defun absorb-properties (target incoming)
  "Replace TARGET's property table contents with INCOMING's.
Replace rather than merge: an analysis pass reports everything it found, so a
property missing from the new pass is a property the source no longer has."
  (let ((table (properties target)))
    (clrhash table)
    (maphash (lambda (key value) (setf (gethash key table) value))
             (properties incoming)))
  target)

(defun absorb-entity (target incoming)
  "Overwrite TARGET's name, properties, and provenance from INCOMING, keeping
TARGET's id. SS4.1 says an id is \"assigned at creation, never reused\", so an
upsert updates in place; replacing the object would orphan every edge pointing
at the old id."
  (when (slot-boundp incoming 'name)
    (setf (name target) (name incoming)))
  (absorb-properties target incoming)
  (absorb-provenance target incoming))

(defun absorb-relationship (target incoming)
  "Overwrite TARGET's properties and provenance from INCOMING, keeping its id.
Endpoints are not absorbed: they are TARGET's natural key, so INCOMING would
not have matched it if they differed.

Absorbing a fact into itself is a no-op, and has to be said explicitly:
ABSORB-PROPERTIES replaces rather than merges, so a self-absorb CLRHASHes
TARGET's own table and then copies that emptied table back into it, losing
every property. APPLY-OP for ASSERT-ENTITY-OP has had the same guard since
SS4.1 (the ((eq existing e) existing) clause below); this one is here rather
than at the call site so every caller is covered. Re-applying an op list --
which the PLAN-0010 coder hit and routed around by re-deriving -- is the way
into it: the second pass finds the very relationship object the first pass
stored. DES-0012 R6."
  (if (eq target incoming)
      target
      (progn (absorb-properties target incoming)
             (absorb-provenance target incoming))))

(defun cascade-staleness (graph target-id)
  "Mark stale every fact whose DERIVED-FROM names TARGET-ID.
This is the staleness rule of SS4.4, and it is here -- in operation
application -- rather than in any analyzer. Flagged, never deleted: an
inferred fact that has merely gone unverified is still worth re-checking, and
discarding it is how a graph forgets instead of doubts.

A deviation from the literal wording of SS4.4, which also cascades a
mark-stale to \"every relationship touching\" the retracted entity: an edge
whose endpoint no longer exists is a dangling reference, which
ADD-RELATIONSHIP refuses to create in the first place. REMOVE-ENTITY drops
the touching edges outright and the retention rule is applied to derived
facts, which is what it is actually protecting.

Linear in the size of the graph -- DERIVED-FROM has no index yet. Adequate at
the Phase 1 scale of one workspace, and the obvious thing to index when it
isn't.

Held under the graph lock for its whole scan (DES-0003 R4): it reads both
full tables and writes back into whatever it finds, so run against a
concurrent writer it would mark a set of facts that never existed together."
  (with-graph-lock (graph)
    (flet ((mark (fact)
             (when (member target-id (derived-from fact) :test #'equal)
               (setf (stale-p fact) t))))
      (mapc #'mark (all-entities graph))
      (mapc #'mark (all-relationships graph))))
  (values))

;;;; ==================================================================
;;;; assert-entity
;;;; ==================================================================

(defmethod plan-op (tx (op assert-entity-op))
  (let* ((e         (op-entity op))
         (key       (entity-natural-key e))
         (in-tx     (and key (gethash key (tx-keys tx))))
         (existing  (and (null in-tx) (find-entity-by-key (tx-graph tx) key)))
         (effective (or in-tx (and existing (id existing)) (id e))))
    (setf (gethash (id e) (tx-remap tx)) effective)
    (when key (setf (gethash key (tx-keys tx)) effective))
    (setf (gethash effective (tx-types tx)) (entity-type e))
    (validate-entity e)))

(defmethod apply-op (tx (op assert-entity-op))
  (let* ((graph     (tx-graph tx))
         (e         (op-entity op))
         (effective (tx-resolve tx (id e)))
         (existing  (get-entity graph effective)))
    (cond ((null existing) (add-entity graph e))
          ((eq existing e) existing)
          (t (let ((old-key (entity-natural-key existing)))
               (absorb-entity existing e)
               (reindex-entity graph existing old-key))))))

;;;; ==================================================================
;;;; assert-relationship
;;;; ==================================================================

(defun tx-rebound-rel (tx op)
  "OP's relationship with its endpoints resolved through the remap."
  (let* ((r    (op-rel op))
         (from (tx-resolve tx (from-id r)))
         (to   (tx-resolve tx (to-id r))))
    (if (and (equal from (from-id r)) (equal to (to-id r)))
        r
        (rebind-relationship r :from-id from :to-id to))))

(defmethod plan-op (tx (op assert-relationship-op))
  (let* ((r         (op-rel op))
         (from      (tx-resolve tx (from-id r)))
         (to        (tx-resolve tx (to-id r)))
         (from-type (tx-entity-type tx from))
         (to-type   (tx-entity-type tx to)))
    (append
     (unless from-type
       (list (list :end :from :problem (format nil "unknown FROM entity ~s" from))))
     (unless to-type
       (list (list :end :to :problem (format nil "unknown TO entity ~s" to))))
     (when (and from-type to-type)
       (validate-relationship-endpoints (rel-type r) from-type to-type)))))

(defmethod apply-op (tx (op assert-relationship-op))
  (let* ((graph    (tx-graph tx))
         (r        (tx-rebound-rel tx op))
         (existing (find-relationship-by-key graph (relationship-natural-key r))))
    (if existing
        (absorb-relationship existing r)
        (add-relationship graph r))))

;;;; ==================================================================
;;;; retract-file -- the workhorse of incremental update (SS5.4)
;;;; ==================================================================

(defmethod plan-op (tx (op retract-file-op))
  ;; Nothing to check. Retracting a file the index has never seen is a no-op,
  ;; which is what makes it safe as the opening move of every analysis pass --
  ;; a first analysis and a reanalysis are then the same transaction shape.
  (declare (ignore tx op))
  '())

(defmethod apply-op (tx (op retract-file-op))
  "Remove every fact read from this file.

SS5.4: \"reanalyzing a changed file is retract-file followed by the fresh
asserts.\" The pairing is what lets a *deleted* definition leave the index: an
analyzer reports what it found and never what it stopped finding, so absence
is only expressible by clearing the file first and letting the asserts put
back whatever still exists.

Because ids are derived from natural keys (SS5.1), everything that still
exists comes back with the id it had, so edges from other files that point
into this one are still pointing at the right entity afterwards. What they
are not is still *present*: REMOVE-ENTITY drops them along with the entity, so
a reanalysis loses the inbound cross-file edges until RESOLVE-CALLS runs
again. That is idempotent and cheap, and the workspace monitor is where the
two get sequenced once it exists."
  (let ((graph (tx-graph tx)))
    (with-graph-lock (graph)
      (let* ((facts (facts-from-file graph (path op)))
             (entities (remove-if-not (lambda (f) (typep f 'entity)) facts))
             (edges    (remove-if     (lambda (f) (typep f 'entity)) facts)))
        ;; Edges first: removing an entity would cascade into them anyway, and
        ;; doing it explicitly keeps the origin index honest either way.
        (dolist (edge edges) (remove-relationship graph (id edge)))
        (dolist (entity entities)
          (cascade-staleness graph (id entity))
          (remove-entity graph (id entity)))
        (length facts)))))

;;;; ==================================================================
;;;; retract
;;;; ==================================================================

(defmethod plan-op (tx (op retract-op))
  (let ((target (tx-resolve tx (target-id op))))
    (unless (tx-entity-type tx target)
      (list (list :problem (format nil "cannot retract unknown entity ~s" target))))))

(defmethod apply-op (tx (op retract-op))
  (let ((graph  (tx-graph tx))
        (target (tx-resolve tx (target-id op))))
    (cascade-staleness graph target)
    (remove-entity graph target)))

;;;; ==================================================================
;;;; mark-stale
;;;; ==================================================================

(defun tx-find-fact (tx id)
  "The entity or relationship ID names, or NIL. Staleness applies to both."
  (let ((graph (tx-graph tx)))
    (or (get-entity graph id) (get-relationship graph id))))

(defmethod plan-op (tx (op mark-stale-op))
  (let ((target (tx-resolve tx (target-id op))))
    (unless (or (tx-entity-type tx target) (tx-find-fact tx target))
      (list (list :problem (format nil "cannot mark unknown fact ~s stale" target))))))

(defmethod apply-op (tx (op mark-stale-op))
  (let ((fact (tx-find-fact tx (tx-resolve tx (target-id op)))))
    (when fact (setf (stale-p fact) t))
    fact))

;;;; ==================================================================
;;;; update-properties
;;;; ==================================================================

(defmethod plan-op (tx (op update-properties-op))
  (let* ((target (tx-resolve tx (target-id op)))
         (type   (tx-entity-type tx target)))
    (if (null type)
        (list (list :problem (format nil "cannot update unknown entity ~s" target)))
        (loop for (key value) on (changes op) by #'cddr
              for spec = (find-property type key)
              for problem = (if spec
                                (property-value-problem spec value)
                                (format nil "~s has no property ~s" type key))
              when problem
                collect (list :key key :value value :problem problem)))))

(defmethod apply-op (tx (op update-properties-op))
  (let* ((graph (tx-graph tx))
         (e     (get-entity graph (tx-resolve tx (target-id op)))))
    (when e
      (let ((old-key (entity-natural-key e)))
        (loop for (key value) on (changes op) by #'cddr
              do (setf (getp e key) value))
        (reindex-entity graph e old-key)))
    e))

;;;; ==================================================================
;;;; The transaction itself (SS5.2)
;;;; ==================================================================

;;; Cross-file edges into a reanalyzed file are lost until resolution runs
;;; again. RETRACT-FILE-OP removes the file's entities, which cascades away the
;;; inbound :CALLS edges other files contributed; the entities come back with
;;; the same derived ids on the following asserts, but the edges do not come
;;; back on their own.
;;;
;;; This is by design rather than outstanding, and two things make it so.
;;; LOOM-WORKSPACE:RESOLVE-AND-CHECK owns the ordering -- analyze, resolve,
;;; check -- so no caller has to remember it. And DEC-0003 makes resolution
;;; able to honour it: a pass derives its output from a property the analyzer
;;; wrote and never rewrites, so the second pass can answer the same question
;;; the first one did. While resolution consumed :UNRESOLVED-CALLS, re-running
;;; it rebuilt nothing, and the sequencing above would have been ceremony.

(defun apply-transaction (graph ops)
  "Validate every op in OPS against GRAPH, then apply them all, in order.

SS5.2: \"A transaction is validated in full before any of it is applied ... A
transaction either applies atomically or is rejected with a structured error
naming the failing operation.\" A rejection signals TRANSACTION-ERROR and
leaves GRAPH untouched. Atomicity rests on the planning pass being complete
rather than on a rollback log -- adequate for the in-memory Phase 1 backend,
and the reason every precondition an op has is checked in PLAN-OP.

Returns the remap table: the id each op named, mapped to the id it landed on.
A caller that wants the entity it just asserted looks its own id up there.

The whole body is under the graph lock, which extends DES-0003 R4 rather than
following it -- R4 requires the bodies it lists to be wrapped, not that no
other body may be. Two reasons. It is what makes SS5.2's atomicity true
against a concurrent *reader* for the first time: without it a reader can
observe a transaction half applied, the entity present and its edge not, which
is precisely the guarantee the paragraph above claims. And it turns every pt-
primitive inside the transaction into a reentrant re-acquisition of a lock
this thread already holds, which is DES-0003 R13's own argument for why
composing the two mechanisms amortizes cost instead of compounding it.

The cost is worth stating rather than discovering: a knowledge query can now
wait on a whole transaction rather than one primitive -- one file's operations
in the common case, at worst one resolution pass's batch."
  (with-graph-lock (graph)
    (let ((tx (make-tx graph))
          (problems '()))
      (loop for op in ops
            for index from 0
            do (dolist (problem (plan-op tx op))
                 (push (list* :index index :op op problem) problems)))
      (when problems
        (error 'transaction-error :ops ops :problems (nreverse problems)))
      (dolist (op ops) (apply-op tx op))
      (tx-remap tx))))
