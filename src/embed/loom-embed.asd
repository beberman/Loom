(in-package :asdf-user)

(defsystem :loom-embed
  :description "The embedder protocol and its implementations, for semantic seeding."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; A leaf, depending on nothing of Loom's at all -- not even loom-ontology,
  ;; which DEC-0006 permits and which nothing here needs. An embedder turns
  ;; strings into vectors and holds no opinion about entities.
  ;;
  ;; That is the point rather than tidiness. loom-workspace builds the vector
  ;; sidecar because it owns the write path and loom-knowledge reads it at
  ;; query time because it owns seeding, so both depend on this and it may
  ;; depend on neither. A protocol that sat in either one would make the other
  ;; depend upward.
  ;;
  ;; DRAKMA and CL-JSON are already this tree's: drakma through
  ;; :loom-rest/test, cl-json through four systems. Both ollama and a hosted
  ;; embedder are a JSON POST, so a second implementation is a subclass and a
  ;; bearer token rather than a new dependency.
  ;;
  ;; BABEL is declared rather than reached through drakma, on the precedent
  ;; PLAN-0002 TENSIONS item 4 set for :loom-ontology and BORDEAUX-THREADS: a
  ;; system that names a library's symbols should depend on it, whatever it
  ;; would inherit. OLLAMA.LISP decodes a reply body that arrives as octets.
  ;;
  ;; USOCKET for the preflight connect in REACHABLE-P, which is what separates
  ;; "nothing is listening" from "this batch is taking a while". Transitive
  ;; through drakma and named on the same precedent as BABEL.
  :depends-on (#:drakma #:cl-json #:babel #:usocket)
  :serial t
  :components
  (
   (:file "package")
   (:file "protocol")
   (:file "ollama")
   ;; After "protocol": the store is keyed by EMBEDDER-ID and refuses on it.
   (:file "store")
   ;; After "protocol": REQ-0048 R6, and it decorates any of the above.
   (:file "memo")
   )
  :in-order-to ((test-op (test-op :loom-embed/test)))
  )

(defsystem :loom-embed/test
  :description "Test suite for :loom-embed."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; No drakma here on purpose. Every test in this system runs against
  ;; FIXED-EMBEDDER, so the suite passes on a machine with no ollama installed
  ;; and never opens a socket -- which is what lets REQ-0048 R6's absent-embedder
  ;; behaviour be tested at all rather than assumed.
  :depends-on (#:loom-embed
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   ;; One file, holding the protocol, the stand-ins and the memo. The memo's
   ;; tests need FAILING-EMBEDDER and nothing else does, so splitting them
   ;; would put a fixture in one file and its only user in another.
   (:file "protocol")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-embed-test :test-runner)
                      (error "loom-embed tests failed.")))
  )
