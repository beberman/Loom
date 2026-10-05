(in-package :asdf-user)

(defsystem :loom-analyzer
  :description "Analyzer protocol and per-language analyzers -- source and documentation -- emitting ontology operations."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  ;; SS4: loom-analyzer depends on loom-ontology, and on nothing above it.
  ;; Analyzers emit operations rather than writing to storage (SS9.1), so
  ;; loom-graph must not appear here -- SS14.3 asserts its absence as an
  ;; architectural invariant.
  ;;
  ;; CL-YAML, for the documentation analyzer, binds libyaml through CFFI. It is
  ;; the only FFI dependency in the system, and worth flagging against SS9.2's
  ;; stated preference for subprocesses over FFI: fine on Linux where libyaml
  ;; is packaged, and Windows will want the DLL on the path. The document
  ;; subset Loom actually writes is small enough to read directly if that ever
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
  ;; system: loom-serve and loom-rest already depend on cl-json, and
  ;; loom-ontology on bordeaux-threads, so the layering table gains nothing.
  ;; The JavaScript analyzer reads its child process's replies as JSON -- the
  ;; child writes them, so only a reader is needed, and the request frame is
  ;; length-prefixed precisely so no JSON *writer* has to exist here -- and
  ;; locks the exchange because the file monitor's thread and a console command
  ;; can both reach ANALYZE-FILE.
  :depends-on (#:loom-utils #:loom-ontology #:cl-yaml #:uiop #:eclector
               ;; The kernel of the standalone library at ~/lisp/utils. READ-FILE
               ;; and STRING-LINES were defined here as SLURP-FILE and
               ;; SPLIT-LINES until the library carried them; the library's
               ;; READ-FILE is this one plus :IF-DOES-NOT-EXIST, and its
               ;; STRING-LINES is the same algorithm with the same contract.
               #:utils
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
   (:file "yaml-analyzer")
   ;; After yaml-analyzer, whose *MENTION-MINIMUM-LENGTH* it reuses rather than
   ;; restates. The two claim disjoint extensions, so registration order does
   ;; not decide anything between them. PATH-SEGMENTS was the other thing it
   ;; reused here; REV-0002 A3 moved that to loom-utils, because loom-graph
   ;; held a verbatim second copy that RULE-0002 gave it no way to share.
   (:file "markdown-analyzer")
   ;; Last: it reads YAML through yaml-analyzer's helpers and defaults its
   ;; base registry to lisp-analyzer's *MACRO-GENERATORS*, so both must be
   ;; compiled before it. It registers no analyzer of its own -- .loom/ is
   ;; Loom's own configuration, not a repository's content (DES-0025 D4).
   (:file "frameworks")
   )
  :in-order-to ((test-op (test-op :loom-analyzer/test)))
  )

(defsystem :loom-analyzer/test
  :description "Test suite for :loom-analyzer."
  :version "0.1.0"
  :author "Brian Eberman"
  :license "MIT"
  :depends-on (#:loom-analyzer
	       #:loom-graph
	       #:loom-ontology
	       #:utils
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
   (:file "yaml-analyzer")
   (:file "markdown-analyzer")
   (:file "frameworks")
   )
  :perform (test-op (op c)
                    (unless (symbol-call :loom-analyzer-test :test-runner)
                      (error "loom-analyzer tests failed.")))
  )
