;;;; Package definition for the embedder protocol.
;;;;
;;;; DRAKMA and CL-JSON are deliberately not :USEd. Both export short generic
;;;; names -- DRAKMA:HEADER-VALUE, JSON:DECODE-JSON -- and this package is
;;;; small enough that qualifying every call is cheaper than the collision it
;;;; would otherwise grow into.

(defpackage #:loom-embed
  (:use #:cl)
  (:export
   ;; the protocol, DEC-0006 and DES-0040 D1
   #:embed-texts
   #:embedder-id
   #:embedder-dimensions

   ;; conditions
   #:embedder-unavailable
   #:embedder-unavailable-detail

   ;; implementations
   #:ollama-embedder
   #:make-ollama-embedder
   #:ollama-host
   #:ollama-model

   ;; a stand-in for tests and for callers with no embedder configured
   #:fixed-embedder
   #:make-fixed-embedder

   ;; not asking again, REQ-0048 R6
   #:memoing-embedder
   #:make-memoing-embedder
   #:memoing-embedder-inner
   #:memoing-embedder-suppressed
   #:*embedder-retry-after*

   ;; the sidecar's file format, DES-0040 D2
   #:vector-store
   #:vector-store-p
   #:make-vector-store
   #:vector-store-embedder-id
   #:vector-store-dimensions
   #:vector-store-count
   #:vector-store-built-at
   #:vector-store-ids
   #:vector-store-digests
   #:vector-store-vectors
   #:vector-store-entity-id
   #:vector-store-directory
   #:vector-store-paths
   #:write-vector-store
   #:load-vector-store
   #:delete-vector-store
   #:vector-store-present-p
   #:document-digest
   #:*vector-store-magic*

   ;; the scan, PLAN-0043 S4
   #:nearest
   #:float-vector))
