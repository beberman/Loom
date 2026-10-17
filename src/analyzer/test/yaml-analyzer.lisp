;;;
;;; Tests for src/analyzer/yaml-analyzer.lisp -- the documentation analyzer
;;; of SS10, run against Synoptik's own docs/ tree.
;;;
;;; SS14.2 makes that tree the fixture deliberately: "Synoptik's own docs/ tree is
;;; not decoration. It is the level 1 test fixture, the source of the
;;; architectural rules the build enforces, and the first real evidence that a
;;; decision recorded by an agent in July is still findable."
;;;

(in-package :synoptik-analyzer-test)

(def-suite yaml-analyzer
  :in all-tests
  :description "The documentation analyzer over docs/.")

(in-suite yaml-analyzer)

(defparameter *repo-root*
  (asdf:system-relative-pathname :synoptik-analyzer "../../"))

(defun docs-ops (relative)
  "Ops for one document in Synoptik's own docs/ tree."
  (let ((path (merge-pathnames relative *repo-root*)))
    (analyze-file (make-instance 'document-analyzer)
                  (concatenate 'string "docs/" (subseq relative 5))
                  (synoptik-utils:read-file path)
                  "ws-test")))

(defun docs-entity (relative)
  (let ((g (make-graph)))
    (apply-transaction g (docs-ops relative))
    (first (remove-if-not (lambda (e) (member (entity-type e)
                                              '(:decision :design :rule :concept :document)))
                          (all-entities g)))))

;;; ------------------------------------------------------------------
;;; Dispatch (SS10.1)
;;; ------------------------------------------------------------------

(test the-document-analyzer-claims-yaml-under-docs-only
  (let ((a (make-instance 'document-analyzer)))
    (is-true  (analyzer-handles-p a "docs/decisions/DEC-0001.yaml"))
    (is-true  (analyzer-handles-p a "docs/rules/RULE-0001.yaml"))
    (is-false (analyzer-handles-p a ".github/workflows/ci.yaml")
              "a CI config is YAML too, and indexing it as engineering
knowledge would be worse than ignoring it")
    (is-false (analyzer-handles-p a "docs/decisions/notes.md"))))

(test the-directory-names-the-type
  (is (eq :decision (synoptik-analyzer::document-type-for "docs/decisions/DEC-0001.yaml")))
  (is (eq :rule     (synoptik-analyzer::document-type-for "docs/rules/RULE-0001.yaml")))
  (is (eq :concept  (synoptik-analyzer::document-type-for "docs/concepts/CON-0001.yaml")))
  (is (eq :design   (synoptik-analyzer::document-type-for "docs/design/DES-0001.yaml"))
      "docs/design holds designs now; the decisions moved to docs/decisions")
  (is (eq :document (synoptik-analyzer::document-type-for "docs/plans/PLAN-0001.yaml"))))

(test an-unregistered-directory-is-indexed-not-ignored
  ;; SS10.1: "a documentation directory that Synoptik is quietly skipping is
  ;; exactly the kind of thing that erodes trust in the graph"
  (multiple-value-bind (type registered)
      (synoptik-analyzer::document-type-for "docs/scratch/thoughts.yaml")
    (is (eq :document type))
    (is-false registered "and reported, so the gap is visible")))

;;; ------------------------------------------------------------------
;;; A decision (SS10.3)
;;; ------------------------------------------------------------------

(test a-decision-becomes-an-entity-keyed-by-its-document-id
  (let ((e (docs-entity "docs/decisions/DEC-0001.yaml")))
    (is (eq :decision (entity-type e)))
    (is (string= "DEC-0001" (getp e :doc-id)))
    (is (string= "DEC-0001" (name e)))
    (is (eq :accepted (getp e :status)))
    (is (string= "docs/decisions/DEC-0001.yaml" (origin-file e)))
    (is (eq :human-validated (source e))
        "a human wrote this down; it is not an inference")))

(test a-decision-keeps-its-prose
  (let ((e (docs-entity "docs/decisions/DEC-0001.yaml")))
    (is (search "index over files" (getp e :rationale)))
    (is (search "durability requirement" (getp e :consequences)))
    (is (search "index over files" (getp e :body))
        ":body is what an agent reads when it wants the reasoning")))

(test a-decision-carries-its-declared-references-unresolved
  ;; The analyzer has no index, so affects: rides through as raw names for
  ;; SYNOPTIK-GRAPH:RESOLVE-DOCUMENT-LINKS to link (SS10.3).
  (let ((e (docs-entity "docs/decisions/DEC-0001.yaml")))
    (is (member "apply-transaction" (getp e :affects) :test #'string=))
    (is (member "retract-file" (getp e :affects) :test #'string=))))

(test a-decision-records-what-its-prose-mentions
  (let ((e (docs-entity "docs/decisions/DEC-0002.yaml")))
    (is (member "id-derived-p" (getp e :mentions) :test #'string=)
        "identifier-shaped tokens in prose become candidate inferred links")
    (is (not (member "the" (getp e :mentions) :test #'string=))
        "and English words do not, or the real hits would be buried")))

;;; ------------------------------------------------------------------
;;; A rule and its check clause (SS10.4)
;;; ------------------------------------------------------------------

(test a-rule-compiles-its-check-clause
  (let ((e (docs-entity "docs/rules/RULE-0001.yaml")))
    (is (eq :rule (entity-type e)))
    (is (string= "RULE-0001" (getp e :doc-id)))
    (is (eq :error (getp e :severity)))
    (is (eq :active (getp e :status)))
    (let ((check (getp e :check)))
      (is (eq :no-edge (getf check :kind)))
      ;; DES-0009 R8: the real package name, not the path segment. This
      ;; assertion is what ties the document's text to what ENTITY-SYSTEM
      ;; answers -- the two sides of one EQ comparison.
      (is (eq :synoptik-ontology (getf check :from-system)))
      (is (eq :outside (getf check :to-system)))
      (is (equal '(:calls :imports :depends-on) (getf check :rel-types))))))

(test rule-0002-and-rule-0003-also-compile-to-the-real-package-names
  ;; The other half of DES-0009 R8: RULE-0001 above pins one side of one
  ;; :no-edge comparison against the real YAML on disk, but RULE-0002 and
  ;; RULE-0003 each changed *two* fields (from-system: and to-system:), and
  ;; between them they account for every violation `check` currently reports
  ;; against this tree. Nothing before this test read either file's real
  ;; contents: a revert or a typo in either YAML -- from-system: analyzer
  ;; instead of synoptik-analyzer, say -- would compile silently to a keyword no
  ;; analyzed entity's :system property can ever equal, and `check` would
  ;; report 0 for that rule from then on. That is the exact vacuous-zero
  ;; failure BUG-0006 closed, reachable again through the YAML alone, and
  ;; nothing but a human reading the console's printed count would have
  ;; caught it without this test.
  (let ((rule-0002 (docs-entity "docs/rules/RULE-0002.yaml")))
    (is (string= "RULE-0002" (getp rule-0002 :doc-id)))
    (let ((check (getp rule-0002 :check)))
      (is (eq :no-edge (getf check :kind)))
      (is (eq :synoptik-analyzer (getf check :from-system)))
      (is (eq :synoptik-graph (getf check :to-system)))))
  (let ((rule-0003 (docs-entity "docs/rules/RULE-0003.yaml")))
    (is (string= "RULE-0003" (getp rule-0003 :doc-id)))
    (let ((check (getp rule-0003 :check)))
      (is (eq :no-call-to (getf check :kind))
          "BUG-0009 cause two: :no-edge could not say \"only a write\"")
      (is (eq :synoptik-knowledge (getf check :from-system)))
      (is (eq :synoptik-graph (getf check :to-system)))
      ;; The other half of the vacuous-zero guard above. :NO-CALL-TO with an
      ;; empty to-names: reports nothing at all, so a to-names: that failed to
      ;; parse -- or a document edited down to none -- would read as a clean
      ;; tree. Naming APPLY-TRANSACTION specifically because it is the one
      ;; callee RULE-0003's own statement names.
      (is (member "apply-transaction" (getf check :to-names) :test #'string-equal))
      (is (member "add-relationship" (getf check :to-names) :test #'string-equal)))))

(test a-from-family-compiles-to-a-family-designator
  ;; DES-0024 D3: both fields land in the same plist slot, so nothing
  ;; downstream of PARSE-CHECK learns a new key.
  (let ((e (literal-entity "docs/rules/RULE-9001.yaml"
                           "id: RULE-9001
type: rule
title: Nothing outside the game family reaches its internals
severity: error
statement: |
  One rule, not fourteen.
check:
  kind: no-edge
  from-family: game
  to-system: outside
  rel-types: [calls]
" :rule)))
    (let ((check (getp e :check)))
      (is (equal '(:family :game) (getf check :from-system)))
      (is (eq :outside (getf check :to-system))))))

(test a-clause-naming-one-side-both-ways-stays-prose
  ;; Guessing which the author meant is the fabricated fact CON-0001 rules
  ;; out. The document still indexes; the rule falls back to prose and is
  ;; counted by UNENFORCED-RULES.
  (let ((e (literal-entity "docs/rules/RULE-9002.yaml"
                           "id: RULE-9002
type: rule
title: Two minds about one side
severity: error
statement: |
  Undecided.
check:
  kind: no-edge
  from-system: synoptik-graph
  from-family: synoptik
  to-system: outside
" :rule)))
    (is (not (null e)) "the statement survives even though the check does not")
    (is (null (getp e :check)))))

(test a-rule-with-no-recognisable-check-stays-prose
  ;; SS10.4: such a rule "remains valid as prose with severity advisory; it is
  ;; not enforced". It must still index -- refusing the document would lose the
  ;; statement entirely.
  (let* ((ops (analyze-file (make-instance 'document-analyzer)
                            "docs/rules/RULE-9999.yaml"
                            "id: RULE-9999
type: rule
title: Prefer clarity
severity: advisory
statement: |
  Write for the next reader.
check:
  kind: vibes
"
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((e (first (entities-of-type g :rule))))
      (is (not (null e)) "the rule is indexed even though its check is not usable")
      (is (null (getp e :check)))
      (is (eq :advisory (getp e :severity))))))

;;; ------------------------------------------------------------------
;;; A summary stored on its own (DES-0005 R4)
;;;
;;; Driven by literal YAML rather than by Synoptik's own docs/ tree, unlike the
;;; tests above: these assert on exact field text, and a document edited for an
;;; unrelated reason must not turn them red.
;;; ------------------------------------------------------------------

(defun literal-entity (path contents type)
  "The TYPE entity analyzed out of CONTENTS at PATH."
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'document-analyzer)
                                       path contents "ws-test"))
    (first (entities-of-type g type))))

(test a-plain-document-reads-its-affects-field
  ;; The analyzer half of the fix. DOCUMENT-PROPERTIES read affects: only in
  ;; its :DECISION method, so a plan, a requirement, an architecture note or a
  ;; bug report could declare what it bore on and the field went into the
  ;; parse and no further. Measured when this landed: 67 documents carrying
  ;; roughly 610 names, of which only the four decisions produced an edge.
  ;; Without the read this is NIL and the test fails here rather than
  ;; downstream (CON-0003).
  (let ((e (literal-entity "docs/plans/PLAN-9001.yaml"
                           "id: PLAN-9001
title: A plan that says what it touches
affects: [apply-transaction, resolve-calls]
"
                           :document)))
    (is (equal '("apply-transaction" "resolve-calls") (getp e :affects)))))

(test an-architecture-document-describes-rather-than-affects
  ;; The genre distinction, enforced by which key is looked up rather than by
  ;; convention. An ARCH document describes structure; it does not govern, and
  ;; it does not argue how to implement a requirement -- that is a DES. Writing
  ;; affects: here must therefore do nothing, because reading it would make an
  ;; architecture document govern code and re-open exactly the confusion the
  ;; type was split out to end.
  (let ((e (literal-entity "docs/arch/ARCH-9001.yaml"
                           "id: ARCH-9001
title: The shape of the thing
status: accepted
describes: [apply-transaction, resolve-calls]
affects: [should-be-ignored]
invariants: |
  I1  One writer.
"
                           :architecture)))
    (is (equal '("apply-transaction" "resolve-calls") (getp e :describes)))
    (is (null (getp e :affects))
        "an architecture document describes; governing is a DES or a DEC")
    (is (eq :accepted (getp e :status)))
    (is (search "One writer" (getp e :invariants)))
    (is (search "One writer" (getp e :body))
        "invariants: is a prose field, so it folds into the body the mention
scan runs over")))

(test an-architecture-document-refuses-a-design-status
  ;; :IMPLEMENTED is deliberately absent from the vocabulary. Architecture is
  ;; never implemented -- it is accurate or it is superseded -- and offering
  ;; the word would invite the genre confusion back in.
  (let ((e (literal-entity "docs/arch/ARCH-9002.yaml"
                           "id: ARCH-9002
title: A structure that cannot be implemented
status: implemented
"
                           :architecture)))
    (is (eq :draft (getp e :status))
        "outside the vocabulary falls back to the default rather than sticking")))

(test a-summary-is-stored-on-its-own-and-still-folds-into-the-body
  ;; The first assertion is the witness: before BASE-PROPERTIES read summary:,
  ;; a decision's summary existed only inside the :BODY concatenation and had
  ;; no addressable property. The other two pass before and after -- they are
  ;; not the witness, they are the guard that makes it safe: DES-0005 R4 and
  ;; DEC-0003 require COLLECT-BODY's derivation to be untouched, so :SUMMARY
  ;; must still fold into :BODY alongside :RATIONALE.
  (let ((e (literal-entity "docs/decisions/DEC-9001.yaml"
                           "id: DEC-9001
title: Keep the overlay
status: accepted
summary: |
  Bounded output beats a faithful dump.
rationale: |
  Diffing an overlay is cheaper than rebuilding.
"
                           :decision)))
    (is (search "Bounded output beats a faithful dump" (getp e :summary)))
    (is (search "Bounded output beats a faithful dump" (getp e :body)))
    (is (search "Diffing an overlay is cheaper" (getp e :body)))))

(test a-concept-summary-survives-the-cleanup
  ;; Passes before and after by design: the :CONCEPT method's own :SUMMARY line
  ;; was removed in the same edit that added BASE-PROPERTIES', and this is what
  ;; makes that a cleanup rather than a deletion.
  (let ((e (literal-entity "docs/concepts/CON-9001.yaml"
                           "id: CON-9001
title: Recorded gaps
summary: |
  A fabricated fact is worse than a recorded gap.
"
                           :concept)))
    (is (search "A fabricated fact is worse" (getp e :summary)))))

(test a-document-status-outside-the-old-vocabulary-is-kept
  ;; AS-KEYWORD returns NIL for a value outside its allowed list rather than
  ;; signalling, so `status: implemented' -- what RULE-0005 requires of a
  ;; landed document -- was silently dropped by every ARCH and REQ in the tree.
  (let ((e (literal-entity "docs/design/DES-9001.yaml"
                           "id: DES-9001
title: A landed design
status: implemented
"
                           :design)))
    (is (eq :implemented (getp e :status)))))

(test a-document-carries-the-system-its-path-names
  ;; DES-0009 R3. A document has no IN-PACKAGE to read, so the shared path
  ;; default is the whole answer and every document in docs/ lands on :DOCS.
  (let ((e (literal-entity "docs/design/DES-9999.yaml"
                           "id: DES-9999
title: A design with a system
"
                           :design)))
    (is (eq :docs (getp e :system)))))

(test every-genre-carries-its-path-not-just-the-workflow-ones
  ;; BUG-0059. :PATH is where ENTITY-LOCATION and DEFINITION-SOURCE read a
  ;; document's whereabouts. It was set by the :DOCUMENT method alone, so a
  ;; design, decision, concept or rule resolved with a null location. Moved to
  ;; BASE-PROPERTIES, so no genre can omit it -- the four that used to are the
  ;; ones asserted here.
  (dolist (case '(("docs/design/DES-9001.yaml"    "id: DES-9001" :design)
                  ("docs/decisions/DEC-9001.yaml" "id: DEC-9001" :decision)
                  ("docs/concepts/CON-9001.yaml"  "id: CON-9001" :concept)
                  ("docs/rules/RULE-9001.yaml"    "id: RULE-9001" :rule)))
    (destructuring-bind (path body type) case
      (let ((e (literal-entity path body type)))
        (is (string= path (getp e :path))
            "~a must carry its own path" type)))))

(test a-rule-document-carries-no-system-at-all
  ;; R1 gives :RULE no :SYSTEM property, so writing one here would be dropped
  ;; by DECLARED-PROPERTIES-ONLY's equivalent and read by nothing. ENTITY-SYSTEM
  ;; already answered NIL for a rule and has to keep doing so -- a rule that
  ;; classified into a system would start matching the layering checks it is
  ;; the subject of.
  (let ((e (literal-entity "docs/rules/RULE-9999.yaml"
                           "id: RULE-9999
title: A rule with no system
"
                           :rule)))
    (is (null (getp e :system)))))

;;; ------------------------------------------------------------------
;;; Malformed input (SS3.3, SS9.3)
;;; ------------------------------------------------------------------

(test an-unparsable-document-is-marked-not-dropped
  (let* ((ops (analyze-file (make-instance 'document-analyzer)
                            "docs/decisions/broken.yaml"
                            "id: [unclosed" "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((e (first (entities-of-type g :document))))
      (is (not (null e)))
      (is (stringp (getp e :analysis-error))
          "a known unknown beats an absence an agent cannot explain"))))

(test an-unquoted-colon-in-a-title-reports-the-line-it-is-on
  ;; BUG-0033's trigger, twice over: PLAN-0032 and BUG-0013 both broke this
  ;; way. The line number is the whole point of the message -- it is what makes
  ;; the difference between "a document is missing" and "quote the title" --
  ;; and cl-yaml counts lines from zero while everything else Synoptik reports
  ;; counts from one, so the parser's own report sends a reader one line above
  ;; the mistake.
  (let* ((ops (analyze-file (make-instance 'document-analyzer)
                            "docs/plans/PLAN-0001.yaml"
                            (format nil "id: PLAN-0001~%title: DES-0026 in seven steps: the walk~%status: draft~%")
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((problem (getp (first (entities-of-type g :document)) :analysis-error)))
      (is (search "line 2" problem)
          "the title is on line 2 of the file; cl-yaml says 1")
      (is (search "column 31" problem)
          "and the column is the offending colon, counted the same way"))))

(test a-document-that-is-not-a-mapping-is-a-validation-error
  (signals document-error (parse-document "- just" "docs/decisions/list.yaml")))

;;; ------------------------------------------------------------------
;;; Every pass opens with a retract (SS5.4)
;;; ------------------------------------------------------------------

(test a-document-pass-opens-by-clearing-the-file
  (is (typep (first (docs-ops "docs/rules/RULE-0001.yaml")) 'retract-file-op)))

(test reindexing-a-document-is-a-no-op
  (let ((g (make-graph)))
    (apply-transaction g (docs-ops "docs/decisions/DEC-0001.yaml"))
    (let ((ids (mapcar #'id (all-entities g))))
      (apply-transaction g (docs-ops "docs/decisions/DEC-0001.yaml"))
      (is (equal ids (mapcar #'id (all-entities g)))))))

;;; ------------------------------------------------------------------
;;; importance: (REQ-0037..REQ-0044 carry it; every requirement does)
;;;
;;; The field is read for every workflow document, not only for requirements,
;;; for the reason the :DOCUMENT method already gives about :DOC-ID and
;;; :AFFECTS: a field only one method reads is a field the other categories
;;; write into a void. What is asserted here is that it arrives as a keyword
;;; from the vocabulary, that a value outside the vocabulary arrives as nothing
;;; rather than as a fourth level, and that Synoptik's own requirements all carry
;;; one -- the last being the check that keeps the field true of the tree
;;; rather than merely available in it.
;;; ------------------------------------------------------------------

(defun requirement-entity-from (contents)
  "The document entity the analyzer makes of CONTENTS, read as a requirement."
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'document-analyzer)
                                       "docs/requirements/REQ-9999.yaml"
                                       contents "ws-test"))
    (first (remove-if-not (lambda (e) (eq :document (entity-type e)))
                          (all-entities g)))))

(test importance-is-read-as-a-keyword-from-the-vocabulary
  ;; All three levels, from fixtures rather than from documents in this tree.
  ;; It read REQ-0037 for :CRITICAL and REQ-0044 for :MINOR until 2026-08-23,
  ;; when REQ-0037 was repriced to Minor and this test failed -- correctly
  ;; reporting a fact about the document and nothing at all about the analyzer.
  ;; An importance is a judgement that is meant to change; pinning one makes
  ;; every reprice look like a regression in the code that reads it.
  (dolist (case '(("Critical" . :critical) ("Major" . :major) ("Minor" . :minor)))
    (let ((e (requirement-entity-from
              (format nil "id: REQ-9999~%title: t~%status: draft~%~
importance: ~a~%summary: s~%" (car case)))))
      (is (eq (cdr case) (getp e :importance))
          "~a must be recorded as ~s" (car case) (cdr case)))))

(test a-real-documents-importance-arrives-as-a-vocabulary-keyword
  ;; The live path the test above used to cover, asserting what does not move:
  ;; a document in this tree that declares an importance has it read as one of
  ;; the three keywords rather than as the string it was written as. Which of
  ;; the three is the author's business.
  (let ((importance (getp (docs-entity "docs/requirements/REQ-0037.yaml")
                          :importance)))
    (is (member importance '(:critical :major :minor))
        "REQ-0037 declares an importance and it must reach the graph as a ~
keyword from the vocabulary, not as ~s" importance)))

(test importance-outside-the-vocabulary-is-not-recorded
  ;; Not an error and not a fourth level. AS-KEYWORD's allowed list drops it,
  ;; which is what keeps :ONE-OF on the ontology property true by construction.
  (let ((e (requirement-entity-from
            (format nil "id: REQ-9999~%title: t~%status: draft~%importance: Blocker~%summary: s~%"))))
    (is (null (getp e :importance))
        "a value outside Critical/Major/Minor records nothing")))

(test a-document-without-importance-is-still-a-document
  ;; Most categories do not carry it, so its absence must not change anything
  ;; else about the entity.
  (let ((e (requirement-entity-from
            (format nil "id: REQ-9999~%title: t~%status: draft~%summary: s~%"))))
    (is (null (getp e :importance)))
    (is (string= "REQ-9999" (getp e :doc-id))
        "the rest of the document is unaffected by the missing field")))

(test importance-is-lowercase-insensitive
  ;; The tree writes Critical; a human writing critical means the same thing.
  (let ((e (requirement-entity-from
            (format nil "id: REQ-9999~%title: t~%status: draft~%importance: critical~%summary: s~%"))))
    (is (eq :critical (getp e :importance)))))

(test every-requirement-in-this-tree-declares-its-importance
  ;; The assertion that keeps the field honest. A requirement without one is not
  ;; a parse failure -- the analyzer is happy -- so nothing else would report it,
  ;; and an importance field two thirds of the requirements carry is worse than
  ;; none: it reads as a judgement about the ones that have it.
  (let ((missing '())
        (counted 0))
    (dolist (path (append
                   (directory (merge-pathnames "docs/requirements/*.yaml" *repo-root*))
                   (directory (merge-pathnames "docs/requirements/completed/*.yaml" *repo-root*))))
      (let* ((relative (format nil "docs/requirements/~@[completed/~*~]~a.~a"
                               (search "completed" (namestring path))
                               (pathname-name path) (pathname-type path)))
             (g (make-graph)))
        (apply-transaction g (analyze-file (make-instance 'document-analyzer)
                                           relative (synoptik-utils:read-file path) "ws-test"))
        (let* ((e (first (remove-if-not (lambda (x) (eq :document (entity-type x)))
                                        (all-entities g))))
               (importance (and e (getp e :importance))))
          (incf counted)
          (unless (member importance '(:critical :major :minor))
            (push (list relative importance) missing)))))
    (is (plusp counted) "the requirements directory is not empty")
    (is (null missing)
        "every requirement declares importance: Critical, Major or Minor; these do not: ~s"
        missing)))
