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
   #:federated-summaries
   #:impact-report

   ;; a bounded answer for a document-shaped entity (DES-0005)
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
   ;; DES-0020: how much prose a bundle admits. Exported for the reason
   ;; *CONTEXT-RELATION-LIMIT* is -- the right number is a judgement about
   ;; budget rather than a fact, and someone tuning it should not have to
   ;; reach into the package.
   #:*context-mention-limit*

   ;; the structural report (REQ-0021 R5, DES-0022 S1) -- what the index can
   ;; say about a tree's shape, as data, so a generated architecture document
   ;; is confined to what was actually measured
   #:structure-report
   #:render-structure
   #:*structure-hub-limit*
   #:*structure-entry-point-limit*

   ;; REQ-0021 R7: where the prose and the index disagree. Reports candidates
   ;; for a human to read; never says a document is stale, because nothing in
   ;; an index says which side moved.
   #:prose-report
   #:render-prose
   #:*prose-engaged-rate*
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
