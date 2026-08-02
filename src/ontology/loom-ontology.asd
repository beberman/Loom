(in-package :asdf-user)

(defsystem :loom-ontology
  :description "ontology of objects for an engineering knowledge system called loom for coding"
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; Two leaf libraries, and no more. SS3 asks that this system load "into any
  ;; image, including analysis scripts and tests, without dragging in a
  ;; server", which RULE-0001 restates as no server, no store, no analyzer.
  ;; RANDOM-UUID mints ids. BORDEAUX-THREADS is here since PLAN-0003 because
  ;; FRESH-ID has to guard the library's use of CL:*RANDOM-STATE* against its
  ;; own concurrent callers (BUG-0005) -- an ontology that mints ids for
  ;; threads is in the threading business whether it declares it or not, and a
  ;; portability shim over the implementation's own primitives is none of the
  ;; three things RULE-0001 excludes.
  ;;
  ;; RULE-0001's check cannot see a third: its kind is :no-edge over edges
  ;; between indexed entities, and an external library has no entities and this
  ;; file is not indexed. The prose is what governs adding one, so argue it in
  ;; a document rather than reading a green `check` as permission.
  :depends-on (#:random-uuid #:bordeaux-threads)
  :serial t
  :components
  (
   (:file "package")
   (:file "root-ontology")
   (:file "code-ontology")
   (:file "ontology-ops")
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
	       ;; Declared here as well as in :loom-ontology, on PLAN-0002
	       ;; TENSIONS item 4's precedent: a test system that spawns threads
	       ;; should say so rather than rely on a transitive dependency.
	       #:bordeaux-threads
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "root-ontology")
   (:file "code-ontology")
   (:file "concurrency")
   )
  ;; TEST-RUNNER returns NIL when any check fails; turn that into a real
  ;; failure so (asdf:test-system :loom-ontology) is usable from CI.
  :perform (test-op (op c)
                    (unless (symbol-call :root-ontology-test :test-runner)
                      (error "loom-ontology tests failed.")))
  )
