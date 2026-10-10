(in-package :asdf-user)

(defsystem :loom-docstore
  :description "The document-store protocol, and the stores that implement it."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; DES-0051 D5. It deals in refs, addresses, versions and bytes and never
  ;; sees an ontology operation, so no Loom system but loom-utils appears
  ;; below. RULE-0010 and RULE-0013 to RULE-0021 check that, one rule per
  ;; system (a rule carries one check). loom-workspace is its only client, and
  ;; RULE-0011 and RULE-0012 keep loom-analyzer and loom-knowledge from
  ;; reaching it.
  ;;
  ;; Not loom-store: "store" already means the vector store in
  ;; src/embed/store.lisp.
  ;;
  ;; LOOM-UTILS for READ-FILE and DOT-PREFIXED-P (PLAN-0061 D1). A stamp
  ;; hashes the text READ-FILE returns, so the stamp and the analyzer see the
  ;; same string. UIOP is named because this system calls it (git queries in
  ;; file-store.lisp), and it arrived before only through the library this
  ;; replaces. The rules cannot see an external library, so UIOP is governed by
  ;; RULE-0010's prose.
  :depends-on (#:loom-utils #:uiop)
  :serial t
  :components
  (
   (:file "package")
   (:file "protocol")
   ;; FILE-STAMP, STAMP-FILE and *MTIME-SETTLE-SECONDS* came from
   ;; workspace.lisp. The file store's versions are stamps, and the code tier
   ;; in loom-workspace keeps using them from here.
   (:file "stamps")
   ;; Finding and replacing a document's top-level status line, from
   ;; transition.lisp. Text only: both stores set a status, and text is what
   ;; every store holds.
   (:file "status-line")
   ;; DES-0052's registry, before the stores rather than after: each one calls
   ;; REGISTER-DOCSTORE-KIND at the bottom of its own file, and their
   ;; constructors read CONFIG through CONFIG-VALUE and CHECK-CONFIG-KEYS.
   (:file "factory")
   ;; After "stamps": a file store's version is a stamp, and CHANGED-SINCE
   ;; decides with STAMP-CHANGED-P. After "status-line": a transition rewrites
   ;; one line of the document's text before the file moves.
   (:file "file-store")
   ;; DES-0051 D6. Built for the suite, to differ from the file store in every
   ;; way a caller could come to depend on.
   (:file "memory-store")
   )
  :in-order-to ((test-op (test-op :loom-docstore/test)))
  )

(defsystem :loom-docstore/test
  :description "Test suite for :loom-docstore."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; UIOP for WITH-TEMPORARY-FILE in the stamp tests. LOOM-UTILS because the
  ;; tests call LOOM-UTILS:READ-FILE to pin the stamp against it.
  :depends-on (#:loom-docstore #:loom-utils #:uiop #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   ;; DES-0051 D9 part A, run against every store in *STORE-KINDS*.
   (:file "conformance")
   ;; Part C. After "conformance" for its WRITE-TEXT, FRESH-DIRECTORY and
   ;; claim function.
   (:file "file-store")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-docstore-test :test-runner)
                      (error "loom-docstore tests failed.")))
  )
