(in-package :asdf-user)

(defsystem :loom-ontology
  :description "ontology of objects for an engineering knowledge system called loom for coding"
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS3: "The ontology system has no dependencies at all -- it is pure CLOS
  ;; definitions and can be loaded into any image, including analysis scripts
  ;; and tests, without dragging in a server."  RANDOM-UUID is a leaf library
  ;; needed to mint ids; nothing else belongs here.
  :depends-on (#:random-uuid)
  :serial t
  :components
  (
   (:file "package")
   (:file "root-ontology")
   (:file "code-ontology")
   )
  :in-order-to ((test-op (test-op :loom-ontology/test)))
  )

(defsystem :loom-ontology/test
  :description "Test suite for :loom-ontology."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-ontology
	       #:random-uuid
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "root-ontology")
   (:file "code-ontology")
   )
  ;; TEST-RUNNER returns NIL when any check fails; turn that into a real
  ;; failure so (asdf:test-system :loom-ontology) is usable from CI.
  :perform (test-op (op c)
                    (unless (symbol-call :root-ontology-test :test-runner)
                      (error "loom-ontology tests failed.")))
  )
