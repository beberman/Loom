(in-package :asdf-user)

(defsystem :synoptik-utils
  :description "Leaf utilities shared by systems that may not depend on each other."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; REV-0002. A second leaf beside synoptik-embed, and added for the reason
  ;; DEC-0006 added that one: two systems needed the same thing and neither
  ;; could depend on the other. Six of REV-0002's twenty-two findings are pairs
  ;; straddling a boundary the layering forbids crossing -- LOG-EVENT across
  ;; the synoptik-process / synoptik-serve peer boundary, PATH-SEGMENTS across
  ;; RULE-0002's analyzer/graph line -- and a copy on each side was the only
  ;; other answer.
  ;;
  ;; The entry condition, which is what keeps this from becoming the place
  ;; unrelated code accumulates: a function belongs here only when two systems
  ;; that cannot depend on each other both need it. When one caller's system
  ;; already depends on the other's, the shared home is that lower system.
  ;; Twelve of REV-0002's findings are that case and none of them is here.
  ;;
  ;; No Synoptik system may appear below, and RULE-0009 checks it. BORDEAUX-THREADS
  ;; is a leaf library synoptik-ontology and synoptik-graph already carry, and
  ;; threads.lisp needs THREAD-ALIVE-P; on synoptik-ontology.asd's precedent, that
  ;; is argued here rather than read off a green `check', whose :no-edge kind
  ;; cannot see an external library at all.
  ;;
  ;; Not named `utils'. That was the name of a standalone library Synoptik used to
  ;; depend on, whose system and package were both spelled UTILS. DES-0009 makes
  ;; the package name the :SYSTEM property every rule keys on, so the package is
  ;; SYNOPTIK-UTILS in order for RULE-0009 to be able to name it.
  :depends-on (#:bordeaux-threads)
  :serial t
  :components
  (
   (:file "package")
   (:file "errors")
   (:file "logging")
   (:file "parsing")
   (:file "files")
   (:file "paths")
   (:file "plists")
   (:file "threads")
   )
  :in-order-to ((test-op (test-op :synoptik-utils/test)))
  )

(defsystem :synoptik-utils/test
  :description "Test suite for :synoptik-utils."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; UIOP for WITH-TEMPORARY-FILE in the READ-FILE tests.
  :depends-on (#:synoptik-utils #:bordeaux-threads #:uiop #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :synoptik-utils-test :test-runner)
                      (error "synoptik-utils tests failed.")))
  )
