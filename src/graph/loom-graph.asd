(in-package :asdf-user)

(defsystem :loom-graph
  :description "In-memory Graph Manager: validates and stores ontology entities and relationships."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-ontology)
  :serial t
  :components
  (
   (:file "package")
   (:file "graph-manager")
   (:file "transaction")
   (:file "query")
   (:file "resolve")
   )
  :in-order-to ((test-op (test-op :loom-graph/test)))
  )

(defsystem :loom-graph/test
  :description "Test suite for :loom-graph."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-graph
	       #:loom-ontology
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "graph-manager")
   (:file "query")
   (:file "resolve")
   (:file "retract-file")
   )
  ;; TEST-RUNNER returns NIL when any check fails; turn that into a real
  ;; failure so (asdf:test-system :loom-graph) is usable from CI.
  :perform (test-op (op c)
                    (unless (symbol-call :loom-graph-test :test-runner)
                      (error "loom-graph tests failed.")))
  )
