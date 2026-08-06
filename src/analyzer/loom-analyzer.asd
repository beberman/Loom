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
  :depends-on (#:loom-ontology #:cl-yaml)
  :serial t
  :components
  (
   (:file "package")
   (:file "analyzer")
   (:file "lisp-analyzer")
   (:file "yaml-analyzer")
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
   (:file "lisp-analyzer")
   (:file "yaml-analyzer")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-analyzer-test :test-runner)
                      (error "loom-analyzer tests failed.")))
  )
