(in-package :asdf-user)

(defsystem :loom-analyzer
  :description "Analyzer protocol and per-language analyzers, emitting ontology operations."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS3: loom-analyzer depends on loom-ontology, and on nothing else.
  ;; Analyzers emit operations rather than writing to storage (SS8.1), so
  ;; loom-graph must not appear here -- SS12.3 asserts its absence as an
  ;; architectural invariant.
  :depends-on (#:loom-ontology)
  :serial t
  :components
  (
   (:file "package")
   (:file "analyzer")
   (:file "lisp-analyzer")
   )
  :in-order-to ((test-op (test-op :loom-analyzer/test)))
  )

(defsystem :loom-analyzer/test
  :description "Test suite for :loom-analyzer."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-analyzer
	       #:loom-graph
	       #:loom-ontology
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "lisp-analyzer")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-analyzer-test :test-runner)
                      (error "loom-analyzer tests failed.")))
  )
