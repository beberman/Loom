(in-package :asdf-user)

(defsystem :loom-workspace
  :description "Repository registry, indexing pipeline, and the file monitor."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: loom-workspace depends on loom-graph and the analyzers. It is the
  ;; first system that knows both how to analyze and where the result goes,
  ;; which is what lets everything below it stay ignorant of the other half.
  :depends-on (#:loom-ontology #:loom-graph #:loom-analyzer #:bordeaux-threads
               ;; UIOP runs `git check-ignore' for DES-0018. Already in the
               ;; image through loom-analyzer, and named here anyway: a
               ;; system that uses a library should say so rather than rely
               ;; on a dependency of a dependency continuing to want it.
               #:uiop)
  :serial t
  :components
  (
   (:file "package")
   (:file "workspace")
   )
  :in-order-to ((test-op (test-op :loom-workspace/test)))
  )

(defsystem :loom-workspace/test
  :description "Test suite for :loom-workspace."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-workspace
	       #:loom-knowledge
	       #:loom-graph
	       #:loom-ontology
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "workspace")
   (:file "gitignore")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-workspace-test :test-runner)
                      (error "loom-workspace tests failed.")))
  )
