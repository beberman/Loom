(in-package :asdf-user)

(defsystem :synoptik-mcp
  :description "MCP over JSON-RPC 2.0, on the same listener synoptik-rest uses."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; Not #:synoptik-rest. The two protocol skins are peers over one registry, and
  ;; the shared listener is reached through synoptik-serve's registration seam
  ;; rather than through either naming the other. Not #:synoptik-process either,
  ;; for DES-0006 R5's reason; tools/load-test.lisp is the instrument.
  :depends-on (#:synoptik-serve
	       #:hunchentoot
	       #:cl-json)
  :serial t
  :components
  (
   (:file "package")
   (:file "tools")
   (:file "jsonrpc")
   )
  :in-order-to ((test-op (test-op :synoptik-mcp/test)))
  )

(defsystem :synoptik-mcp/test
  :description "Test suite for :synoptik-mcp."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; #:synoptik-rest is a *test* dependency and not a system one: the strongest
  ;; assertion in this suite is that a tools/call and the equivalent REST route
  ;; return the same data from the one registry, which needs both skins in the
  ;; image and neither depending on the other.
  :depends-on (#:synoptik-mcp
	       #:synoptik-rest
	       #:synoptik-serve
	       #:synoptik-serve/test
	       #:synoptik-workspace
	       #:fiveam
	       #:drakma
	       #:cl-json)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "tools")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :synoptik-mcp-test :test-runner)
                      (error "synoptik-mcp tests failed.")))
  )
