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

;;; ------------------------------------------------------------------
;;; string-lines (PLAN-0061 D1)
;;;
;;; SPLIT-LINES became UTILS:STRING-LINES when the standalone library carried
;;; it, and the library held its tests. The library is gone, STRING-LINES is
;;; defined in analyzer.lisp, and these are the tests that came with it.
;;; ------------------------------------------------------------------

(test string-lines-keeps-the-last-line-when-the-string-does-not-end-in-a-newline
  (let ((lines (string-lines (format nil "a~%b"))))
    (is (equalp #("a" "b") lines))))

(test string-lines-adds-no-empty-line-after-a-trailing-newline
  ;; An off-by-one here shifts every line number computed from the result.
  (is (equalp #("a") (string-lines (format nil "a~%"))))
  (is (= 2 (length (string-lines (format nil "a~%b~%"))))))

(test string-lines-drops-a-carriage-return-so-a-crlf-checkout-matches
  (is (equalp #("a" "b") (string-lines (format nil "a~c~%b" #\Return)))))

(test string-lines-of-the-empty-string-is-an-empty-vector
  (is (equalp #() (string-lines ""))))

(test analyze-path-stamps-a-domain-onto-every-entity-it-returns
  ;; PLAN-0050 S3. The stamp is in ANALYZE-PATH rather than in each analyzer,
  ;; and this has to go through ANALYZE-PATH to see it: JS-OPS, MD-OPS,
  ;; DOCS-OPS and FIXTURE-OPS all call ANALYZE-FILE directly and would see no
  ;; stamp at all.
  ;;
  ;; Against a real file on disk, because ANALYZE-PATH is what reads one.
  (let* ((path (merge-pathnames "src/analyzer/analyzer.lisp"
                                (asdf:system-source-directory :loom-analyzer)))
         (root (asdf:system-source-directory :loom-analyzer)))
    (when (probe-file path)
      (let* ((*domains* (domain-table
                         (getf (parse-frameworks "domains:
  - name: analyzer
    root: src/analyzer/
") :domains)))
             (ops (analyze-path path :workspace-root root))
             (entities (remove-if-not (lambda (op) (typep op 'loom-ontology:assert-entity-op)) ops)))
        (is (plusp (length entities)) "the file produced entities to stamp")
        (dolist (op entities)
          (let ((entity (loom-ontology:op-entity op)))
            (when (loom-ontology:find-property (loom-ontology:entity-type entity) :domain)
              (is (eq :analyzer (loom-ontology:getp entity :domain))
                  "~a carries ~a rather than the declared domain"
                  (loom-ontology:entity-type entity)
                  (loom-ontology:getp entity :domain)))))))))

;;; ------------------------------------------------------------------
;;; GROUP-CALL-SHAPES -- PLAN-0060 step 3, DES-0055 D11
;;; ------------------------------------------------------------------

(test call-shapes-group-by-key-then-signature-keeping-every-line
  (is (equal '(("f" ("2:y,y" 2 5) ("3:y,y,y" 4))
               ("g" ("1:y" 3)))
             (loom-analyzer::group-call-shapes
              '(("f" "2:y,y" 2) ("g" "1:y" 3) ("f" "3:y,y,y" 4) ("f" "2:y,y" 5))))
      "keys and signatures in first-seen order; one entry per signature"))

(test call-shape-lines-are-in-source-order-and-a-repeat-on-one-line-stays
  (is (equal '(("f" ("1:y" 2 2 7)))
             (loom-analyzer::group-call-shapes
              '(("f" "1:y" 7) ("f" "1:y" 2) ("f" "1:y" 2))))
      "two calls on one line are two occurrences; step 7 counts a site once
per distinct caller line, and needs the multiplicity to do it"))

(test no-occurrences-group-to-nothing
  (is (null (loom-analyzer::group-call-shapes '()))))
