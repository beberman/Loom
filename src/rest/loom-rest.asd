(in-package :asdf-user)

(defsystem :loom-rest
  :description "HTTP/JSON skin over loom-serve's operation registry."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; loom-serve and the two libraries the translation needs, and nothing else --
  ;; notably not #:loom-mcp, which is a peer rather than a layer, and not
  ;; #:loom-process, which DES-0006 R5 forbids and tools/load-test.lisp is the
  ;; instrument for.
  :depends-on (#:loom-serve
	       #:hunchentoot
	       #:cl-json)
  :serial t
  :components
  (
   (:file "package")
   (:file "routes")
   )
  :in-order-to ((test-op (test-op :loom-rest/test)))
  )

(defsystem :loom-rest/test
  :description "Test suite for :loom-rest."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; :loom-serve/test for the acceptor fixture and the drakma helpers, which
  ;; PLAN-0005 asks be written once and reused: port discipline is the thing
  ;; worth having in one place, because a leaked acceptor fails the *next* run.
  :depends-on (#:loom-rest
	       #:loom-serve
	       #:loom-serve/test
	       #:loom-workspace
	       #:fiveam
	       #:drakma
	       #:cl-json
	       #:bordeaux-threads)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "routes")
   (:file "concurrency")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-rest-test :test-runner)
                      (error "loom-rest tests failed.")))
  )
