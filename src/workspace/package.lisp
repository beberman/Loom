;;;; Package definition for the Loom workspace registry and monitor.
;;;;
;;;; SS4: "Workspace registry, filesystem and Git event monitoring, debouncing
;;;; and batching, analyzer dispatch."
;;;;
;;;; This is the first system that knows both how to analyze and where to put
;;;; the result, and that is precisely its job: it owns the answer to "a file
;;;; changed, here is everything that has to happen." Analysis, then the
;;;; resolution passes that need a whole-repository view, then the rule checks.
;;;; Nothing below it has to know about that ordering.

(defpackage #:loom-workspace
  (:use #:cl #:loom-ontology #:loom-graph #:loom-analyzer #:loom-knowledge)
  (:export
   ;; the registry
   #:repository
   #:repository-root
   #:repository-name
   #:repository-graph
   #:repository-indexed-at
   #:repository-file-count
   #:repository-errors
   #:repository-enrichment
   ;; DES-0022 D5: the commit a structural report was derived from, or NIL and
   ;; a reason. A report that cannot name its tree cannot be checked later.
   #:repository-commit
   #:*repositories*
   #:find-repository
   #:all-repositories

   ;; lifecycle
   #:watch-repository
   #:pause-repository
   #:unwatch-repository
   #:index-repository

   ;; REQ-0031, DES-0027 D1. The source of a definition, which only this
   ;; system can serve: the range is on the entity and the root is on the
   ;; repository, and loom-knowledge cannot see the second.
   #:definition-source
   #:*source-line-limit*

   ;; Cross-repository edges (REQ-0027, DES-0025). The one pass that reads
   ;; more than one graph, and the only place in the system that may.
   #:federate-repositories
   #:federation-report
   #:unresolved-path-references
   #:federated-edge-p
   #:repository-commit
   #:reindex-repository
   #:repository-status

   ;; the second pass (DES-0011). On explicit demand only -- nothing in
   ;; POLL-ONCE, the monitor, watch or reindex reaches it.
   #:enrich-repository

   ;; document state transitions (REQ-0022, DES-0019) -- the one write path
   ;; that edits a document rather than reading one. Both return a report
   ;; plist whose :PROBLEMS is empty exactly when something was written.
   #:set-document-status
   #:complete-plan
   #:parse-verdicts
   #:document-status-vocabulary

   ;; preparing a repository Loom did not write (REQ-0021, DES-0022 S2).
   ;; Writes into somebody else's tree, so it plans every write before making
   ;; one and records what it did before doing it.
   #:prepare-repository
   #:read-manifest
   #:prepared-p
   #:*default-endpoint*

   ;; REQ-0021 R5/R6: the structural report rendered into an ARCH document a
   ;; prepared tree can actually read. Says only what was measured, and says
   ;; plainly that its invariants section is empty because a generated
   ;; invariant is a defect.
   #:generate-architecture

   ;; REQ-0021 R13: taking Loom back out, in the two modes a team actually
   ;; means by it. Never infers what init wrote -- the manifest is the only
   ;; authority, and full mode refuses rather than orphan a document nobody
   ;; can prove init created.
   #:remove-preparation

   ;; monitoring
   #:start-monitor
   #:stop-monitor
   #:monitor-running-p
   #:*poll-interval*
   #:poll-once))
