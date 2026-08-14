(in-package :asdf-user)

(defsystem :loom-workspace
  :description "Repository registry, indexing pipeline, and the file monitor."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: loom-workspace depends on loom-graph and the analyzers. It is the
  ;; first system that knows both how to analyze and where the result goes,
  ;; which is what lets everything below it stay ignorant of the other half.
  :depends-on (#:loom-ontology #:loom-graph #:loom-analyzer #:loom-knowledge
               #:bordeaux-threads
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
   ;; After "workspace": the transition takes WITH-REPOSITORY-LOCK and calls
   ;; REINDEX-REPOSITORY, both defined there, and :SERIAL T is what makes the
   ;; macro available at compile time rather than only at load time.
   (:file "transition")
   ;; After "transition": PREPARE-REPOSITORY reuses LINE-END and
   ;; WHITESPACE-CHAR-P to scan a manifest, and the plan-then-apply split it
   ;; follows is that file's.
   (:file "init")
   ;; After "init": the generator reuses NEXT-DOCUMENT-ID, READ-MANIFEST and
   ;; the create-only discipline, and after loom-knowledge because it renders
   ;; STRUCTURE-REPORT's output.
   (:file "architecture")
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
   (:file "transition")
   ;; After "transition": PREPARE-REPOSITORY reuses LINE-END and
   ;; WHITESPACE-CHAR-P to scan a manifest, and the plan-then-apply split it
   ;; follows is that file's.
   (:file "init")
   (:file "architecture")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-workspace-test :test-runner)
                      (error "loom-workspace tests failed.")))
  )
