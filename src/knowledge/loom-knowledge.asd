(in-package :asdf-user)

(defsystem :loom-knowledge
  :description "Knowledge Services: read-only search, description, impact, and context building over the graph."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS2/SS12.3: Knowledge Services read the graph and never write it. Nothing
  ;; here may call APPLY-TRANSACTION -- loom_record_decision, the one MCP tool
  ;; that writes, belongs to the layer above this one.
  :depends-on (#:loom-ontology #:loom-graph)
  :serial t
  :components
  (
   (:file "package")
   (:file "services")
   (:file "context")
   ;; After "services": the report builds its rows with ENTITY-SUMMARY and
   ;; ENTITY-LOCATION, which live there.
   ;; Before "structure": STRUCTURE-REPORT attributes prose to the systems it
   ;; describes, and reuses DOCUMENT-PROSE-ROW for the resolution rate.
   (:file "prose")
   (:file "structure")
   )
  :in-order-to ((test-op (test-op :loom-knowledge/test)))
  )

(defsystem :loom-knowledge/test
  :description "Test suite for :loom-knowledge."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-knowledge
	       #:loom-graph
	       #:loom-ontology
	       #:loom-analyzer
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "services")
   (:file "context")
   (:file "prose")
   (:file "structure")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-knowledge-test :test-runner)
                      (error "loom-knowledge tests failed.")))
  )
