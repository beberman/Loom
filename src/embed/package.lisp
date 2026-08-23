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
   #:make-fixed-embedder))
