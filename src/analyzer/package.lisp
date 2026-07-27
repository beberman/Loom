;;;; Package definition for the Loom Lisp analyzer.

(defpackage #:loom-analyzer
  (:use #:cl #:loom-ontology #:loom-graph)
  (:export
   #:analyze-lisp-file))
