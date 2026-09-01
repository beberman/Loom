(in-package :asdf-user)

(defsystem :loom-serve
  :description "Shared service layer: one typed operation registry, with a permission tier and a structured-error contract, behind both protocol skins."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; DES-0006: exactly the five systems loom-process.asd depends on, plus the
  ;; three libraries a listener needs -- and conspicuously not #:loom-process.
  ;; R5 makes zero edits to console.lisp the mechanism by which the console
  ;; cannot regress, and the surest way to keep that true is for nothing here
  ;; to be able to reach it. PLAN-0005 FINDING 1 records that `check` cannot
  ;; see this property: RULE-0001 to RULE-0003 key on ENTITY-SYSTEM, which
  ;; returns the text before the first slash of a file path, so every entity in
  ;; this tree is in system :SRC and every layering rule matches nothing. The
  ;; instrument for this line is tools/load-test.lisp, which loads this system
  ;; into a fresh image and asserts (find-package "LOOM-PROCESS") is NIL.
  :depends-on (#:loom-utils
	 #:loom-ontology
	       #:loom-graph
	       #:loom-analyzer
	       #:loom-workspace
	       #:loom-knowledge
	       ;; The standalone library, for IMPROPER-LIST-P. The encoder in
	       ;; json.lisp stays: its plist walk, its key vocabulary and
	       ;; *ARRAY-VALUED-KEYS* are policy this service owns, and the library
	       ;; encodes alists. The predicate was general, and was three lines
	       ;; here only because nothing supplied one.
	       #:utils
	       #:hunchentoot
	       #:cl-json
	       #:bordeaux-threads
	       ;; Transitive through loom-ontology, which mints entity ids with
	       ;; it, and named here anyway because repl.lisp calls it directly:
	       ;; a system that uses a library should say so rather than rely on
	       ;; a dependency of a dependency continuing to want it.
	       #:random-uuid)
  :serial t
  :components
  (
   (:file "package")
   ;; errors and capability before registry, which is not the order PLAN-0005's
   ;; FILES section lists them in. REGISTRY.LISP names the GUARDED-CONDITION
   ;; type and the REQUEST-ERROR class, and a type must exist when the file
   ;; naming it is compiled -- unlike a function, whose forward reference is a
   ;; STYLE-WARNING deferred to the end of ASDF's compilation unit.
   (:file "errors")
   (:file "capability")
   (:file "registry")
   (:file "operations")
   (:file "repl")
   (:file "json")
   (:file "server")
   )
  :in-order-to ((test-op (test-op :loom-serve/test)))
  )

(defsystem :loom-serve/test
  :description "Test suite for :loom-serve."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-serve
	       #:loom-ontology
	       #:loom-graph
	       #:loom-analyzer
	       #:loom-workspace
	       #:loom-knowledge
	       #:fiveam
	       ;; The HTTP client, so that a test of a route is a test of a
	       ;; request arriving over TCP rather than a direct call wearing
	       ;; one's clothes.
	       #:drakma)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "registry")
   (:file "operations")
   (:file "repl")
   (:file "json")
   (:file "server")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-serve-test :test-runner)
                      (error "loom-serve tests failed.")))
  )
