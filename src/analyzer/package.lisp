;;;; Package definition for the Loom code analyzers.
;;;;
;;;; LOOM-GRAPH is deliberately absent from :USE, and from the system's
;;;; dependencies. SS8.1: analyzers "are stateless and know nothing about
;;;; storage, which keeps the language-independence principle enforceable."
;;;; They speak only ontology: entities, relationships, and the operations of
;;;; SS4.4. SS12.3 makes that a build-failing query against Loom's own graph
;;;; once self-analysis runs, so the coupling cannot creep back in unnoticed.

(defpackage #:loom-analyzer
  (:use #:cl #:loom-ontology)
  (:export
   ;; protocol (SS8.1)
   #:analyzer
   #:analyzer-language
   #:analyzer-file-types
   #:analyze-file
   #:analyzer-handles-p

   ;; registry
   #:*analyzers*
   #:register-analyzer
   #:find-analyzer
   #:analyzable-p

   ;; driving an analyzer over files on disk
   #:analyze-path
   #:analyze-tree
   #:slurp-file
   #:workspace-relative-path

   ;; the system a path belongs to (ARCH-0009 R2) -- exported because every
   ;; analyzer with no grouping construct of its own calls it, not because
   ;; anything above LOOM-ANALYZER does
   #:default-system-for-path
   #:*src-prefix*

   ;; analyzers
   #:lisp-analyzer
   #:document-analyzer

   ;; what a macro call defines (ARCH-0002) -- read by LOOM-WORKSPACE, which
   ;; hands it to the resolution pass LOOM-GRAPH cannot reach this package from
   #:*macro-generators*
   #:register-macro-generator
   #:macro-generators-for

   ;; the documentation tree (SS10)
   #:*document-type-directories*
   #:register-document-type
   #:document-category
   #:docs-relative-p
   #:parse-document
   #:parse-check
   #:*check-kinds*
   #:document-error
   #:document-error-path
   #:document-error-problem))
