(in-package :asdf-user)

(defsystem :synoptik-analyzer
  :description "Analyzer protocol and per-language analyzers -- source and documentation -- emitting ontology operations."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: synoptik-analyzer depends on synoptik-ontology, and on nothing above it.
  ;; Analyzers emit operations rather than writing to storage (SS9.1), so
  ;; synoptik-graph must not appear here -- SS14.3 asserts its absence as an
  ;; architectural invariant.
  ;;
  ;; CL-YAML, for the documentation analyzer, binds libyaml through CFFI. It is
  ;; the only FFI dependency in the system, and worth flagging against SS9.2's
  ;; stated preference for subprocesses over FFI: fine on Linux where libyaml
  ;; is packaged, and Windows will want the DLL on the path. The document
  ;; subset Synoptik actually writes is small enough to read directly if that ever
  ;; becomes friction.
  ;;
  ;; UIOP is not a new dependency in the sense that matters: it ships with
  ;; ASDF, which is already required to load any of this, so it adds no system
  ;; to the layering table. The inspector uses it to run a child process
  ;; (DES-0011 R3), which is SS9.2's stated preference for subprocesses over
  ;; FFI exercised rather than merely agreed with.
  ;;
  ;; ECLECTOR is the Common Lisp reader the Lisp analyzer reads through
  ;; (DES-0013). Pure Common Lisp, no foreign code, so cl-yaml above remains
  ;; the only FFI dependency in the system. It is confined to lisp-reader.lisp
  ;; on the DES-0011 precedent that a library's spelling should be replaceable
  ;; without touching the code consuming its answers: no other file in the tree
  ;; names an ECLECTOR package, and DES-0013 R1 asserts it.
  ;; CL-JSON and BORDEAUX-THREADS are REQ-0024's, and neither is new to the
  ;; system: synoptik-serve and synoptik-rest already depend on cl-json, and
  ;; synoptik-ontology on bordeaux-threads, so the layering table gains nothing.
  ;; The JavaScript analyzer reads its child process's replies as JSON -- the
  ;; child writes them, so only a reader is needed, and the request frame is
  ;; length-prefixed precisely so no JSON *writer* has to exist here -- and
  ;; locks the exchange because the file monitor's thread and a console command
  ;; can both reach ANALYZE-FILE.
  ;;
  ;; READ-FILE comes from synoptik-utils and STRING-LINES is defined in analyzer.lisp.
  ;; Both were the standalone utils library's until PLAN-0061 D1 removed that
  ;; dependency.
  :depends-on (#:synoptik-utils #:synoptik-ontology #:cl-yaml #:uiop #:eclector
               #:cl-json #:bordeaux-threads)
  :serial t
  :components
  (
   (:file "package")
   (:file "analyzer")
   (:file "inspector")
   ;; After analyzer, whose OFFSET-LINE it agrees with by construction, and
   ;; before both callers of READ-SOURCE: lisp-analyzer's pass 0 and
   ;; lisp-inspector's FILE-FORM-SPANS.
   (:file "lisp-reader")
   (:file "lisp-inspector")
   (:file "lisp-analyzer")
   ;; Before js-analyzer and python-analyzer, which each build one instance of
   ;; its child (DES-0053 R14).
   (:file "extractor-child")
   (:file "js-analyzer")
   (:file "python-analyzer")
   (:file "yaml-analyzer")
   ;; After yaml-analyzer, whose *MENTION-MINIMUM-LENGTH* it reuses rather than
   ;; restates. The two claim disjoint extensions, so registration order does
   ;; not decide anything between them. PATH-SEGMENTS was the other thing it
   ;; reused here; REV-0002 A3 moved that to synoptik-utils, because synoptik-graph
   ;; held a verbatim second copy that RULE-0002 gave it no way to share.
   (:file "markdown-analyzer")
   ;; Last: it reads YAML through yaml-analyzer's helpers and defaults its
   ;; base registry to lisp-analyzer's *MACRO-GENERATORS*, so both must be
   ;; compiled before it. It registers no analyzer of its own -- .synoptik/ is
   ;; Synoptik's own configuration, not a repository's content (DES-0025 D4).
   (:file "frameworks")
   ;; After frameworks, whose PARSE-JSON-TEXT it reads through, and after
   ;; js-analyzer, whose VENDORED-PATH-P it asks (DES-0054 D4).
   (:file "firebase-analyzer")
   ;; After firebase-analyzer, whose shape it follows, and after python-analyzer
   ;; and js-analyzer, whose exclusion predicates it asks (DES-0055 D3).
   (:file "manifest-analyzer")
   )
  :in-order-to ((test-op (test-op :synoptik-analyzer/test)))
  )

(defsystem :synoptik-analyzer/test
  :description "Test suite for :synoptik-analyzer."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:synoptik-analyzer
	       #:synoptik-graph
	       #:synoptik-ontology
	       #:synoptik-utils
	       #:fiveam)
  :serial t
  :pathname "test/"
  :components
  (
   (:file "suite")
   (:file "analyzer")
   (:file "inspector")
   (:file "lisp-reader")
   (:file "lisp-analyzer")
   (:file "extractor-child")
   (:file "js-analyzer")
   (:file "python-extract")
   (:file "python-analyzer")
   (:file "yaml-analyzer")
   (:file "markdown-analyzer")
   (:file "frameworks")
   (:file "firebase-analyzer")
   (:file "manifest-analyzer")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :synoptik-analyzer-test :test-runner)
                      (error "synoptik-analyzer tests failed.")))
  )
