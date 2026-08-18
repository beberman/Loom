;;;; Package definition for the Loom in-memory Graph Manager.

(defpackage #:loom-graph
  (:use #:cl #:loom-ontology)
  (:export
   ;; the graph itself
   #:graph
   #:make-graph

   ;; a hash table guarded by a shared reentrant lock (DES-0003 R2).
   ;; WITH-GRAPH-LOCK is deliberately absent: R4 keeps it internal, so a
   ;; caller outside this system cannot open a critical section on a graph.
   #:make-protected-table
   #:pt-get
   #:pt-rem
   #:pt-clear
   #:pt-count
   #:pt-keys
   #:pt-values
   #:pt-push
   #:pt-delete-from-list

   ;; entities
   #:add-entity
   #:get-entity
   #:find-entity-by-key
   #:remove-entity
   #:facts-from-file
   #:origin-files
   ;; BUG-0030 F1: the edges the ontology would not let the graph record.
   #:dropped-edges
   #:dropped-edge-count
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
   #:resolve-definitions
   #:resolve-inheritance
   #:resolve-specializers
   #:resolve-method-protocols
   #:callable-index
   #:callable-lookup
   #:name-lookup
   #:candidate-entities
   ;; The package graph (DES-0015)
   #:build-package-graph
   #:package-graph-p
   #:canonical-package
   #:home-package
   #:entity-home-package
   #:*callable-types*

   ;; generated definitions (DES-0002) -- the one pass that mints entities
   #:resolve-generated-definitions
   #:normalize-route
   #:structural-generated-uses
   #:generated-definition-collisions
   #:unhandled-definer-macros
   #:body-swallowing-macro-names
   #:*generatable-types*

   ;; image-derived facts merged against what the text pass wrote (DES-0011)
   #:enrich-ops

   ;; test coverage, derived from what a test's body calls (DES-0002 R9)
   #:resolve-tests
   #:*tested-types*

   ;; document link resolution (SS10.3)
   #:resolve-document-links
   #:unresolved-references
   #:linkable-index
   ;; Exported for DES-0022 S3's generator, which has to know whether a name it
   ;; is about to write into a describes: field will resolve. Duplicating the
   ;; rule was tried and got it wrong in the worst direction -- see the
   ;; function's own docstring for the generic-plus-methods case that a naive
   ;; "one candidate" test drops.
   #:resolve-one
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
   #:system-satisfies-p
   #:*system-family-delimiters*
   #:in-system-p
   #:entities-in-system
   #:edges-between-systems
   #:federated-relationships
   #:federated-relationship-p
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
   #:impact-result-mentions
   #:impact-result-decisions

   ;; errors
   #:graph-error
   #:graph-error-problems
   #:transaction-error
   #:transaction-error-ops))
