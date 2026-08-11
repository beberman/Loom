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
  (:use #:cl #:loom-ontology #:loom-graph #:loom-analyzer)
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
   #:*repositories*
   #:find-repository
   #:all-repositories

   ;; lifecycle
   #:watch-repository
   #:pause-repository
   #:unwatch-repository
   #:index-repository
   #:reindex-repository
   #:repository-status

   ;; the second pass (DES-0011). On explicit demand only -- nothing in
   ;; POLL-ONCE, the monitor, watch or reindex reaches it.
   #:enrich-repository

   ;; monitoring
   #:start-monitor
   #:stop-monitor
   #:monitor-running-p
   #:*poll-interval*
   #:poll-once))
