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

   ;; errors
   #:graph-error
   #:graph-error-problems
   #:transaction-error
   #:transaction-error-ops))
