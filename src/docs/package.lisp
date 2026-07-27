;;;; Package definition for the Loom documentation analyzer.
;;;;
;;;; SS10: "If files are truth, then engineering knowledge -- decisions,
;;;; rules, architecture notes, vocabulary -- must live in files as well, or
;;;; the principle is a fiction and every restart quietly loses whatever the
;;;; agents had recorded."
;;;;
;;;; This system reads that tree. It is an analyzer in exactly the sense of
;;;; SS9.1 -- path and contents in, ontology operations out, no knowledge of
;;;; storage -- and it registers itself in the same registry the source
;;;; analyzers use, which is what lets SS8.3's dispatch be one rule ("source
;;;; extensions to the code analyzers, anything under docs/ to the
;;;; documentation analyzer") rather than two pipelines.
;;;;
;;;; NOTE ON DEPENDENCIES: SS4's table gives loom-docs a dependency on
;;;; loom-ontology alone. It also depends on LOOM-ANALYZER here, for the
;;;; analyzer protocol and registry and nothing else. The alternative -- a
;;;; second, parallel protocol so the table is satisfied literally -- would
;;;; mean two dispatch mechanisms for "file in, operations out" and two places
;;;; to register a new analyzer. The invariant that actually matters, SS14.3's
;;;; "no entity in loom-analyzer or loom-docs has any edge into loom-adapter
;;;; or loom-graph", is untouched: LOOM-ANALYZER is itself storage-free.

(defpackage #:loom-docs
  (:use #:cl #:loom-ontology #:loom-analyzer)
  (:export
   ;; the analyzer
   #:document-analyzer
   #:*document-type-directories*
   #:register-document-type
   #:document-category
   #:docs-relative-p

   ;; parsing, exposed for tests and for the REST layer's validation errors
   #:parse-document
   #:document-error
   #:document-error-path
   #:document-error-problem))
