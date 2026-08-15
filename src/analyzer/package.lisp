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

   ;; the inspector protocol (DES-0011 R1) -- a second pass that asks the
   ;; language's own toolchain rather than reading text. The three INSPECTION-
   ;; readers are exported for LOOM-WORKSPACE's report; LOOM-GRAPH reads the
   ;; same plist with GETF and names nothing from here.
   #:inspector
   #:inspector-language
   #:inspector-available-p
   #:inspect-repository
   #:*inspectors*
   #:register-inspector
   #:find-inspectors
   #:inspection-units
   #:inspection-definitions
   #:inspection-calls

   ;; the Common Lisp inspector (DES-0011 R3). The four bound slots are
   ;; exported because they are knobs a caller sets, not internals.
   #:lisp-inspector
   #:inspector-timeout-seconds
   #:inspector-heap-mb
   #:inspector-isolate-p
   #:inspector-include-test-units

   ;; driving an analyzer over files on disk
   #:analyze-path
   #:analyze-tree
   #:slurp-file
   #:workspace-relative-path

   ;; the system a path belongs to (DES-0009 R2) -- exported because every
   ;; analyzer with no grouping construct of its own calls it, not because
   ;; anything above LOOM-ANALYZER does
   #:default-system-for-path
   #:*src-prefix*

   ;; analyzers
   #:lisp-analyzer
   #:document-analyzer
   #:markdown-analyzer

   ;; what a macro call defines (DES-0002) -- read by LOOM-WORKSPACE, which
   ;; hands it to the resolution pass LOOM-GRAPH cannot reach this package from
   #:*macro-generators*

   ;; what a repository declares about its own frameworks (DES-0025 D4).
   ;; Handed in the same direction and for the same reason, except that the
   ;; value is per repository rather than global -- FRAMEWORKS-REGISTRY
   ;; returns a fresh table so two watched trees cannot teach each other.
   #:*frameworks-file*
   #:frameworks-path
   #:read-frameworks
   #:parse-frameworks
   #:frameworks-registry
   #:frameworks-problems
   ;; Bound by loom-workspace around one repository's files, so the JavaScript
   ;; analyzer can tell a route literal from any other string without learning
   ;; a convention (DES-0025 D1).
   #:*route-callers*
   ;; Namespaces a Lisp tree uses but does not declare (DES-0015). Handed to
   ;; BUILD-PACKAGE-GRAPH the way *MACRO-GENERATORS* is handed to
   ;; RESOLVE-GENERATED-DEFINITIONS, and for the same layering reason.
   #:*external-package-names*
   #:external-package-exports
   #:register-macro-generator
   #:macro-generators-for

   ;; the documentation tree (SS10)
   #:*document-type-directories*
   #:register-document-type
   #:document-category
   #:docs-relative-p
   ;; markdown under a documentation directory (REQ-0014, DES-0016). The
   ;; directory list is exported because it is the seam a foreign repository
   ;; adjusts -- convention with a knob, not configuration; DES-0016 D2.
   #:*documentation-directories*
   #:documentation-relative-p
   #:*excluded-directories*
   #:*assistant-instruction-files*
   #:parse-document
   #:parse-check
   #:*check-kinds*
   #:document-error
   #:document-error-path
   #:document-error-problem))
