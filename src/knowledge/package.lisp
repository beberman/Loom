;;;; Package definition for the Loom Knowledge Services.
;;;;
;;;; SS2: "Knowledge Services expose read-only APIs for impact analysis,
;;;; documentation, and context building." Read-only is the load-bearing word.
;;;; SS12.3 states it as an architectural invariant -- "No CALLS from a
;;;; Knowledge Services entity to any transaction-submitting function" -- so
;;;; nothing in this system may call APPLY-TRANSACTION, and the write-shaped
;;;; MCP tool of SS11, loom_record_decision, deliberately does not live here.
;;;; It belongs to the layer above, which has both this system and the Graph
;;;; Manager's write path available to it.
;;;;
;;;; Everything returned is plain data -- plists, strings, numbers -- with no
;;;; CLOS objects and no closures, so LOOM-REST can JSON-encode an answer and
;;;; LOOM-MCP can render the same answer as text without either of them
;;;; reaching back into the graph.

(defpackage #:loom-knowledge
  (:use #:cl #:loom-ontology #:loom-graph)
  (:export
   ;; summaries -- the shared vocabulary of every answer
   #:entity-summary
   #:entity-location
   #:significant-name
   #:match-rank
   #:summarize-entities

   ;; services (SS11's read-only tools)
   #:search-entities
   #:describe-entity
   #:impact-report

   ;; a bounded answer for a document-shaped entity (ARCH-0005)
   #:*summary-fields-by-type*
   #:summary-field-and-text
   #:*summary-token-budget*
   #:bounded-text
   #:document-summary

   ;; context building -- SS11's loom_context
   #:build-context
   #:render-context
   #:*context-token-budget*
   #:*context-relation-limit*
   #:*seed-type-preference*
   #:estimate-tokens

   ;; instrumentation
   #:*context-log*
   #:context-log-entry
   #:context-log-task
   #:context-log-seeds
   #:context-log-entities
   #:context-log-budget
   #:context-log-tokens
   #:context-log-at
   #:clear-context-log
   #:context-log-summary))
