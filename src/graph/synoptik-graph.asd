(in-package :asdf-user)

(defsystem :synoptik-graph
  :description "In-memory Graph Manager: validates and stores ontology entities and relationships."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; BORDEAUX-THREADS is an accepted layering cost, not an oversight
  ;; (DES-0003 R6): PROTECTED-TABLE lives here and never in synoptik-ontology, so
  ;; RULE-0001 is untouched, and synoptik-knowledge gains thread safety from the
  ;; layer beneath it without acquiring a lock or a write path of its own.
  :depends-on (#:synoptik-utils #:synoptik-ontology #:bordeaux-threads)
  :serial t
  :components
  (
   (:file "package")
   (:file "protected-table")
   (:file "graph-manager")
   (:file "transaction")
   (:file "query")
   (:file "symbol-identity")
   (:file "resolve")
   (:file "enrich")
   (:file "rules")
   )
  :in-order-to ((test-op (test-op :synoptik-graph/test)))
  )

(defsystem :synoptik-graph/test
  :description "Test suite for :synoptik-graph."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; BORDEAUX-THREADS is declared rather than inherited: "concurrency" spawns
  ;; threads, and after DES-0003 R6 it would arrive transitively through
  ;; synoptik-graph anyway -- but a test system that spawns threads should say so
  ;; rather than depend on a neighbour's dependency list not changing.
  ;; SYNOPTIK-ANALYZER is here for one test and it is worth saying which.
  ;; DES-0011 R5 requires a fixture that runs *both* passes over one
  ;; definition set and asserts their natural keys meet -- the text pass being
  ;; the analyzer's, which this system cannot otherwise reach. The direction is
  ;; already precedented in the other direction (synoptik-analyzer/test depends on
  ;; synoptik-graph) and creates no cycle: neither production system depends on the
  ;; other, and the layering table is unchanged.
  :depends-on (#:synoptik-graph
	       #:synoptik-ontology
	       #:synoptik-analyzer
	       #:bordeaux-threads
	       #:synoptik-utils
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "graph-manager")
   (:file "query")
   (:file "symbol-identity")
   (:file "resolve")
   (:file "enrich")
   (:file "retract-file")
   ;; After graph-manager: BUG-0030 F1's tests reuse its :GRAPH-TEST-EDGE
   ;; fixture, which is the one declaration in this system with an entity type
   ;; deliberately outside its :TO list.
   (:file "transaction")
   (:file "rules")
   (:file "concurrency")
   )
  ;; TEST-RUNNER returns NIL when any check fails; turn that into a real
  ;; failure so (asdf:test-system :synoptik-graph) is usable from CI.
  :perform (test-op (op c)
                    (unless (symbol-call :synoptik-graph-test :test-runner)
                      (error "synoptik-graph tests failed.")))
  )
