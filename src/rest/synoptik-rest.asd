(in-package :asdf-user)

(defsystem :synoptik-rest
  :description "HTTP/JSON skin over synoptik-serve's operation registry."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; synoptik-serve and the two libraries the translation needs, and nothing else --
  ;; notably not #:synoptik-mcp, which is a peer rather than a layer, and not
  ;; #:synoptik-process, which DES-0006 R5 forbids and tools/load-test.lisp is the
  ;; instrument for.
  :depends-on (#:synoptik-serve
	       #:hunchentoot
	       #:cl-json)
  :serial t
  :components
  (
   (:file "package")
   (:file "routes")
   )
  :in-order-to ((test-op (test-op :synoptik-rest/test)))
  )

(defsystem :synoptik-rest/test
  :description "Test suite for :synoptik-rest."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; :synoptik-serve/test for the acceptor fixture and the drakma helpers, which
  ;; PLAN-0005 asks be written once and reused: port discipline is the thing
  ;; worth having in one place, because a leaked acceptor fails the *next* run.
  :depends-on (#:synoptik-rest
	       #:synoptik-serve
	       #:synoptik-serve/test
	       #:synoptik-workspace
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
                    (unless (symbol-call :synoptik-rest-test :test-runner)
                      (error "synoptik-rest tests failed.")))
  )
