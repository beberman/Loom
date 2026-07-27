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
   #:remove-entity
   #:all-entities
   #:entities-of-type

   ;; relationships
   #:add-relationship
   #:get-relationship
   #:remove-relationship
   #:all-relationships
   #:relationships-from
   #:relationships-to

   ;; errors
   #:graph-error
   #:graph-error-problems))
