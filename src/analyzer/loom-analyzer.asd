(in-package :asdf-user)

(defsystem :loom-analyzer
  :description "Analyzer protocol and per-language analyzers -- source and documentation -- emitting ontology operations."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: loom-analyzer depends on loom-ontology, and on nothing above it.
  ;; Analyzers emit operations rather than writing to storage (SS9.1), so
  ;; loom-graph must not appear here -- SS14.3 asserts its absence as an
  ;; architectural invariant.
  ;;
  ;; CL-YAML, for the documentation analyzer, binds libyaml through CFFI. It is
  ;; the only FFI dependency in the system, and worth flagging against SS9.2's
  ;; stated preference for subprocesses over FFI: fine on Linux where libyaml
  ;; is packaged, and Windows will want the DLL on the path. The document
  ;; subset Loom actually writes is small enough to read directly if that ever
  ;; becomes friction.
  ;;
  ;; UIOP is not a new dependency in the sense that matters: it ships with
  ;; ASDF, which is already required to load any of this, so it adds no system
  ;; to the layering table. The inspector uses it to run a child process
  ;; (ARCH-0011 R3), which is SS9.2's stated preference for subprocesses over
  ;; FFI exercised rather than merely agreed with.
  ;;
  ;; ECLECTOR is the Common Lisp reader the Lisp analyzer reads through
  ;; (ARCH-0013). Pure Common Lisp, no foreign code, so cl-yaml above remains
  ;; the only FFI dependency in the system. It is confined to lisp-reader.lisp
  ;; on the ARCH-0011 precedent that a library's spelling should be replaceable
  ;; without touching the code consuming its answers: no other file in the tree
  ;; names an ECLECTOR package, and ARCH-0013 R1 asserts it.
  :depends-on (#:loom-ontology #:cl-yaml #:uiop #:eclector)
  :serial t
  :components
  (
   (:file "package")
   (:file "analyzer")
   (:file "inspector")
   ;; After analyzer, whose OFFSET-LINE it agrees with by construction, and
   ;; before both callers of READ-SOURCE: lisp-analyzer's pass 0 and
   ;; lisp-inspector's FILE-FORM-SPANS.
   (:file "lisp-reader")
   (:file "lisp-inspector")
   (:file "lisp-analyzer")
   (:file "yaml-analyzer")
   ;; After yaml-analyzer, whose PATH-SEGMENTS and *MENTION-MINIMUM-LENGTH* it
   ;; reuses rather than reimplements. The two claim disjoint extensions, so
   ;; registration order does not decide anything between them.
   (:file "markdown-analyzer")
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
   (:file "analyzer")
   (:file "inspector")
   (:file "lisp-reader")
   (:file "lisp-analyzer")
   (:file "yaml-analyzer")
   (:file "markdown-analyzer")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-analyzer-test :test-runner)
                      (error "loom-analyzer tests failed.")))
  )
