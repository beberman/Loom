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
               ;; The standalone library's kernel: READ-FILE, STRING-LINES,
               ;; PROPER-LIST-P and ALISTP. The last two were defined in
               ;; context-log.lisp, the first two were loom-analyzer's -- named
               ;; here on the same principle the UIOP comment below states, that
               ;; a system using a library says so rather than inheriting it.
               #:utils
               ;; UIOP runs `git check-ignore' for DES-0018. Already in the
               ;; image through loom-analyzer, and named here anyway: a
               ;; system that uses a library should say so rather than rely
               ;; on a dependency of a dependency continuing to want it.
               #:uiop
               ;; DES-0030 D3. A context record is JSON because
               ;; tools/acceptance.py reads it and Python does not read plists,
               ;; and it is cl-json rather than a hand-rolled emitter because a
               ;; task string is arbitrary text with quotes and newlines in it.
               ;; An escaping bug there produces a record that parses as
               ;; something else, which is CON-0001's fabricated fact in the one
               ;; place the whole requirement exists to prevent one.
               #:cl-json
               ;; Record ids. Transitive through loom-ontology, and named because
               ;; context-log.lisp calls it directly.
               #:random-uuid)
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
   ;; After "workspace": it takes WITH-REPOSITORY-LOCK, NOTE-ERROR and
   ;; *REPOSITORIES*, and is the one pass that reads more than one graph.
   (:file "federate")
   ;; After "workspace": REQ-0031's reader takes STAMP-FILE and
   ;; REPOSITORY-STAMPS to answer whether the text it served is the text the
   ;; index was built from.
   (:file "source")
   ;; After "workspace": the record writer takes GIT-COMMIT, GIT-DIFF-HASH and
   ;; GIT-BRANCH, and REPOSITORY-NAME and REPOSITORY-ROOT off the struct.
   (:file "context-log")
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
	       #:utils
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "workspace")
   (:file "gitignore")
   ;; BUG-0034. After "workspace" only for its fixtures' sake; the tests build
   ;; their repositories by hand, because FEDERATE-REPOSITORIES reads route
   ;; claims off entities and never touches a filesystem.
   (:file "federate")
   (:file "transition")
   ;; After "transition": PREPARE-REPOSITORY reuses LINE-END and
   ;; WHITESPACE-CHAR-P to scan a manifest, and the plan-then-apply split it
   ;; follows is that file's.
   (:file "init")
   (:file "architecture")
   ;; After "workspace": it takes WITH-WORKSPACE-FIXTURE and WRITE-FILE, and
   ;; the line numbers it asserts are that fixture's src/alpha.lisp.
   (:file "source")
   ;; After "workspace": the record writer takes GIT-COMMIT, GIT-DIFF-HASH and
   ;; GIT-BRANCH, and REPOSITORY-NAME and REPOSITORY-ROOT off the struct.
   (:file "context-log")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-workspace-test :test-runner)
                      (error "loom-workspace tests failed.")))
  )
