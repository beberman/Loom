(in-package :asdf-user)

(defsystem :loom-analyzer
  :description "Reader-based Lisp analyzer: walks source files and writes entities/relationships into the Graph Manager."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-ontology #:loom-graph)
  :serial t
  :components
  (
   (:file "package")
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
