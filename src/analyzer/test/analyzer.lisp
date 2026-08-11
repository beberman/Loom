;;;
;;; Tests for src/analyzer/analyzer.lisp -- the shared, language-neutral
;;; utilities every analyzer may call.
;;;
;;; The three DEFAULT-SYSTEM-FOR-PATH tests here are BUG-0006's, ported from
;;; src/graph/test/query.lisp rather than duplicated: the same three claims,
;;; made about the function that now owns the computation (DES-0009 R2). They
;;; state them about a path string rather than an entity, which is the whole
;;; move -- a path convention is a fact about a language's layout, and the
;;; query layer is structurally unable to know one.
;;;

(in-package :loom-analyzer-test)

(def-suite analyzer
  :in all-tests
  :description "Shared, language-neutral analyzer utilities.")

(in-suite analyzer)

;;; ------------------------------------------------------------------
;;; default-system-for-path (DES-0009 R2, BUG-0006)
;;;
;;; This tree's real files are all "src/<system>/...", not "<system>/...".
;;; BUG-0006 hid because every fixture used the latter shape, which reads the
;;; same under the leading-segment convention and the src/-aware one alike, so
;;; nothing ever exercised the real layout. These use "src/..." for that reason.
;;; ------------------------------------------------------------------

(test default-system-for-path-reads-the-segment-after-src-not-the-leading-one
  ;; The bug, stated as an assertion: "src/knowledge/services.lisp" is not
  ;; system :SRC -- every file in the tree shares that leading segment, which
  ;; is exactly why RULE-0001 to RULE-0003 matched nothing. It is :KNOWLEDGE.
  (is (eq :knowledge (default-system-for-path "src/knowledge/services.lisp")))
  (is (eq :ontology (default-system-for-path "src/ontology/root-ontology.lisp")))
  (is (eq :serve (default-system-for-path "src/serve/server.lisp"))))

(test default-system-for-path-outside-src-keeps-its-own-leading-segment
  ;; docs/ and tools/ are not under src/ at all, and nothing asks this function
  ;; to treat them as though they were -- a document's system stays its own
  ;; leading segment, unchanged from before BUG-0006's fix.
  (is (eq :docs (default-system-for-path "docs/rules/RULE-0001.yaml"))))

(test default-system-for-path-is-nil-for-a-bare-src-file-and-for-no-path-at-all
  ;; Asserted about the path rather than about src/full-test.lisp itself: that
  ;; file gains an IN-PACKAGE-derived system under DES-0009 R4, so only the
  ;; path function still answers NIL for this shape.
  (is (null (default-system-for-path "src/loose.lisp"))
      "a file directly under src/, with no subdirectory, names no system")
  (is (null (default-system-for-path nil))))
