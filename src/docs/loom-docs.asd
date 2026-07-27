(in-package :asdf-user)

(defsystem :loom-docs
  :description "YAML documentation analyzer: decisions, rules, concepts, and notes under docs/."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4 lists loom-ontology alone. LOOM-ANALYZER is here for the analyzer
  ;; protocol and registry only -- see the note in package.lisp. It is itself
  ;; storage-free, so SS14.3's invariant is unaffected.
  ;;
  ;; CL-YAML binds libyaml through CFFI. That is the one FFI dependency in the
  ;; system and it is worth flagging against SS9.2's stated preference for
  ;; subprocesses over FFI: it works on Linux where libyaml is packaged, and
  ;; Windows will need the DLL on the path. If that becomes friction, the
  ;; document subset Loom actually writes is small enough to read directly.
  :depends-on (#:loom-ontology #:loom-analyzer #:cl-yaml)
  :serial t
  :components
  (
   (:file "package")
   (:file "yaml-analyzer")
   )
  :in-order-to ((test-op (test-op :loom-docs/test)))
  )

(defsystem :loom-docs/test
  :description "Test suite for :loom-docs."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-docs
	       #:loom-analyzer
	       #:loom-graph
	       #:loom-ontology
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "yaml-analyzer")
   (:file "rules")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-docs-test :test-runner)
                      (error "loom-docs tests failed.")))
  )
