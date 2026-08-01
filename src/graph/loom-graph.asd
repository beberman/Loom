(in-package :asdf-user)

(defsystem :loom-graph
  :description "In-memory Graph Manager: validates and stores ontology entities and relationships."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; BORDEAUX-THREADS is an accepted layering cost, not an oversight
  ;; (ARCH-0003 R6): PROTECTED-TABLE lives here and never in loom-ontology, so
  ;; RULE-0001 is untouched, and loom-knowledge gains thread safety from the
  ;; layer beneath it without acquiring a lock or a write path of its own.
  :depends-on (#:loom-ontology #:bordeaux-threads)
  :serial t
  :components
  (
   (:file "package")
   (:file "protected-table")
   (:file "graph-manager")
   (:file "transaction")
   (:file "query")
   (:file "resolve")
   (:file "rules")
   )
  :in-order-to ((test-op (test-op :loom-graph/test)))
  )

(defsystem :loom-graph/test
  :description "Test suite for :loom-graph."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; BORDEAUX-THREADS is declared rather than inherited: "concurrency" spawns
  ;; threads, and after ARCH-0003 R6 it would arrive transitively through
  ;; loom-graph anyway -- but a test system that spawns threads should say so
  ;; rather than depend on a neighbour's dependency list not changing.
  :depends-on (#:loom-graph
	       #:loom-ontology
	       #:bordeaux-threads
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
   (:file "rules")
   (:file "concurrency")
   )
  ;; TEST-RUNNER returns NIL when any check fails; turn that into a real
  ;; failure so (asdf:test-system :loom-graph) is usable from CI.
  :perform (test-op (op c)
                    (unless (symbol-call :loom-graph-test :test-runner)
                      (error "loom-graph tests failed.")))
  )
