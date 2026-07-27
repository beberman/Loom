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

   ;; analyzers
   #:lisp-analyzer))
