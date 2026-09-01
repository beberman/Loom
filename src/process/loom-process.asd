(in-package :asdf-user)

(defsystem :loom-process
  :description "Entry point: command loop, thread supervision, lifecycle."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: loom-process depends on all of the above. It is the only system that
  ;; may, because it is the only one that has to know how the parts fit
  ;; together into a running process.
  :depends-on (#:loom-utils
	 #:loom-ontology
	       #:loom-graph
	       #:loom-analyzer
	       #:loom-workspace
	       #:loom-knowledge)
  :serial t
  :components
  (
   (:file "package")
   (:file "console")
   )
  :in-order-to ((test-op (test-op :loom-process/test)))
  )

(defsystem :loom-process/test
  :description "Test suite for :loom-process."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-process #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "console")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-process-test :test-runner)
                      (error "loom-process tests failed.")))
  )
