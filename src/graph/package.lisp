;;;; Package definition for the Loom in-memory Graph Manager.

(defpackage #:loom-graph
  (:use #:cl #:loom-ontology)
  (:export
   ;; the graph itself
   #:graph
   #:make-graph

   ;; entities
   #:add-entity
   #:get-entity
   #:find-entity-by-key
   #:remove-entity
   #:facts-from-file
   #:origin-files
   #:all-entities
   #:entities-of-type

   ;; relationships
   #:add-relationship
   #:get-relationship
   #:find-relationship-by-key
   #:remove-relationship
   #:all-relationships
   #:relationships-from
   #:relationships-to

   ;; transactions -- the write path for ontology operations (SS4.4, SS5.2)
   #:apply-transaction
   #:plan-op
   #:apply-op
   #:cascade-staleness

   ;; cross-file resolution (SS8.3) -- reads a view, returns ops
   #:resolve-calls
   #:callable-index
   #:*callable-types*

   ;; document link resolution (SS10.3)
   #:resolve-document-links
   #:unresolved-references
   #:linkable-index
   #:*document-types*
   #:*mention-confidence*

   ;; rules as executable checks (SS10.4)
   #:run-check
   #:check-rules
   #:violation-ops
   #:violations-of
   #:active-rules
   #:unenforced-rules
   #:enforceable-rule-p
   #:violation
   #:violation-rule-id
   #:violation-severity
   #:violation-subject
   #:violation-detail

   ;; queries -- read-only (SS6.3)
   #:find-entities
   #:entity-system
   #:in-system-p
   #:entities-in-system
   #:edges-between-systems
   #:neighbors
   #:neighbor
   #:neighbor-entity
   #:neighbor-relationship
   #:neighbor-direction
   #:name-matches-p

   ;; impact analysis (SS9)
   #:impact-set
   #:*default-impact-depth*
   #:*max-impact-depth*
   #:hop
   #:hop-rel-type
   #:hop-entity-id
   #:impact-entry
   #:impact-entry-entity
   #:impact-entry-depth
   #:impact-entry-path
   #:impact-result
   #:impact-result-seed
   #:impact-result-impacted
   #:impact-result-collected
   #:impact-result-possibly-affected
   #:impact-result-truncated-p
   #:impact-result-tests
   #:impact-result-documents
   #:impact-result-decisions

   ;; errors
   #:graph-error
   #:graph-error-problems
   #:transaction-error
   #:transaction-error-ops))
