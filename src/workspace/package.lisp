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
  (:use #:cl #:loom-utils #:loom-ontology #:loom-graph #:loom-analyzer #:loom-knowledge)

  ;; From the standalone library. PROPER-LIST-P and ALISTP replace two
  ;; predicates context-log.lisp defined for itself -- ALISTP with
  ;; :KEY-TEST #'KEYWORDP is ALIST-OBJECT-P clause for clause -- and READ-FILE
  ;; and STRING-LINES replace loom-analyzer's SLURP-FILE and SPLIT-LINES.
  (:import-from #:utils #:read-file #:string-lines #:proper-list-p #:alistp)

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
   #:split-designator
   #:unknown-domain
   #:all-repositories

   ;; REQ-0051, DES-0043. `find' across every watched tree, and the count-only
   ;; probe a zero-hit search of one tree makes of the others. Here rather than
   ;; in loom-knowledge because that system is handed a graph and never learns
   ;; which repository it belongs to.
   #:search-repositories
   #:repositories-holding

   ;; lifecycle
   #:watch-repository
   #:await-repository-index
   #:repository-state
   #:repository-index-build
   #:*index-build-wait*
   #:pause-repository
   #:unwatch-repository
   #:index-repository

   ;; REQ-0031, DES-0027 D1. The source of a definition, which only this
   ;; system can serve: the range is on the entity and the root is on the
   ;; repository, and loom-knowledge cannot see the second.
   #:definition-source

   ;; REQ-0034, DES-0029 D5. One document's declared references resolved
   ;; against the live index before the file is written, indexed or asserted.
   #:check-document-references

   ;; REQ-0036, DES-0030. The retrieval log: one record per context call, and
   ;; the feedback call that completes it. Off unless an operator sets the
   ;; directory.
   #:*context-log-directory*
   #:default-context-log-directory
   #:configure-context-log-from-environment
   #:loom-root

   ;; the vector sidecar, DEC-0006 and DES-0040 D2
   #:build-vector-store
   #:repository-vectors
   #:start-vector-build
   #:await-vector-build
   #:vector-build-status
   #:*vector-build-wait*
   #:require-repository-vectors
   #:forget-repository-vectors
   #:current-embedder
   #:*embedder*
   #:update-vector-store
   #:vector-store-staleness
   #:entity-document
   #:*vector-definition-types*
   #:*vector-batch*
   #:record-context-call
   #:record-query
   #:drain-context-log
   #:record-context-use
   #:context-record-path
   #:context-use-path
   #:read-json-record
   #:context-record-error
   #:*context-log-failure*
   #:*source-line-limit*

   ;; Cross-repository edges (REQ-0027, DES-0025). The one pass that reads
   ;; more than one graph, and the only place in the system that may.
   #:federate-repositories
   #:federation-report
   ;; REQ-0056. The three states an unresolved reference can be in, told apart
   ;; by the federated edges the pass already drew.
   #:classified-unresolved-references
   #:unresolved-path-references
   #:federated-edge-p
   #:repository-commit
   ;; REQ-0050 R1: what GIT-DIFF-HASH answers for a clean tree, so a surface
   ;; can say "uncommitted edits" rather than print sixteen hex digits.
   #:clean-diff-hash
   ;; REQ-0050 R1: the tree an index was built from and how far behind it is,
   ;; in one plist, so every surface reports provenance the same way.
   #:index-provenance
   #:answer-provenance
   ;; REQ-0050 R1 for an answer about one definition: the same fingerprint, and
   ;; one stat rather than one per claimed file.
   #:file-provenance
   #:index-drift
   ;; REQ-0050 R3: the half a stamp walk cannot see, and the half that costs a
   ;; tree walk. `status' reports it and no query does.
   #:unindexed-files
   #:repository-indexed-fingerprint
   #:reindex-repository
   #:repository-status
   ;; REQ-0059. What the tree tracks that no analyzer claims, as a plist --
   ;; :COUNT, :BY-EXTENSION, :REASON. Read by `find' on a miss.
   #:repository-unclaimed
   ;; REQ-0054. The lines a term occurs on when no definition carries it --
   ;; a second band on a zero-hit `find', never an entity.
   #:textual-occurrences
   #:*occurrence-limit*

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
