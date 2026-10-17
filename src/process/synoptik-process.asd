(in-package :asdf-user)

(defsystem :synoptik-process
  :description "Entry point: command loop, thread supervision, lifecycle."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: synoptik-process depends on all of the above. It is the only system that
  ;; may, because it is the only one that has to know how the parts fit
  ;; together into a running process.
  :depends-on (#:synoptik-utils
	 #:synoptik-ontology
	       #:synoptik-graph
	       #:synoptik-analyzer
	       #:synoptik-workspace
	       #:synoptik-knowledge)
  :serial t
  :components
  (
   (:file "package")
   (:file "console")
   )
  :in-order-to ((test-op (test-op :synoptik-process/test)))
  )

(defsystem :synoptik-process/test
  :description "Test suite for :synoptik-process."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:synoptik-process #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "console")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :synoptik-process-test :test-runner)
                      (error "synoptik-process tests failed.")))
  )
