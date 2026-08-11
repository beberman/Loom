;;;
;;; Tests for src/analyzer/lisp-analyzer.lisp -- the reader-based Lisp
;;; analyzer, run against test/fixtures/sample.lisp.
;;;
;;; The analyzer's contract is a list of ontology operations (SS8.1), so the
;;; tests come in two halves: what it emits, and what the Graph Manager makes
;;; of it. The second half is the one that matters -- an op list nobody can
;;; apply is not a fact -- which is why this test system depends on
;;; LOOM-GRAPH even though LOOM-ANALYZER must not.
;;;

(in-package :loom-analyzer-test)

(def-suite lisp-analyzer
  :in all-tests
  :description "ANALYZE-FILE against a small synthetic fixture.")

(in-suite lisp-analyzer)

(defparameter *fixture-path*
  (asdf:system-relative-pathname :loom-analyzer "test/fixtures/sample.lisp"))

(defparameter *fixture-relative* "test/fixtures/sample.lisp"
  "What the analyzer is handed as PATH -- workspace-relative and
forward-slashed, as :FILE's :PATH property is specified to be.")

(defun fixture-ops ()
  "A fresh batch of ops for the fixture. Fresh every call, with fresh ids:
that is what makes the idempotence test below meaningful."
  (analyze-file (make-instance 'lisp-analyzer)
                *fixture-relative*
                (slurp-file *fixture-path*)
                "ws-test"))

(defun find-by-name (graph type name)
  (find name (entities-of-type graph type) :key #'name :test #'string=))

(defun analyze-fixture ()
  "A graph with one analysis pass applied, and the file entity it produced."
  (let ((g (make-graph)))
    (apply-transaction g (fixture-ops))
    (values g (find-by-name g :file *fixture-relative*))))

;;; ------------------------------------------------------------------
;;; What the analyzer emits
;;; ------------------------------------------------------------------

(test analyze-file-returns-ontology-operations
  (let ((ops (fixture-ops)))
    (is (not (null ops)))
    (is (every (lambda (op) (typep op 'ontology-op)) ops)
        "an analyzer's whole output is operations -- SS8.1")
    (is (typep (first ops) 'retract-file-op)
        "SS5.4: every pass opens by clearing the file, so a deleted definition
leaves the index")
    (is (typep (second ops) 'assert-entity-op)
        "then the file assert, so edges naming it can resolve")
    (is (eq :file (entity-type (op-entity (second ops)))))))

(test every-fact-records-the-file-it-was-read-from
  ;; SS5.1 makes origin-file mandatory, and SS14.3 asserts its presence as an
  ;; architectural invariant.
  (dolist (op (fixture-ops))
    (typecase op
      (assert-entity-op
       (is (equal *fixture-relative* (origin-file (op-entity op)))
           "~a has no origin file" (name (op-entity op))))
      (assert-relationship-op
       (is (equal *fixture-relative* (origin-file (op-rel op))))))))

(test a-broken-form-costs-that-form-and-not-the-file
  ;; Was AN-UNREADABLE-FILE-IS-INDEXED-AS-A-KNOWN-UNKNOWN, and the change of
  ;; name is the change of contract. SS9.3 and SS3.3 asked for two things: a
  ;; file that could not be parsed is marked rather than omitted, and the
  ;; condition must not escape to take the watcher thread down. Both still
  ;; hold. What no longer holds is the scope: one unbalanced paren used to cost
  ;; every definition in the file, including the perfectly readable one above
  ;; it, and REQ-0019 R3 is that it should not.
  ;;
  ;; The recovered form is dropped rather than trusted (ARCH-0013 R4): Eclector
  ;; repairs an unterminated list by closing it, which on a longer file
  ;; swallows the NEXT definition into the damaged one's body, so a repaired
  ;; form must never reach pass 1.
  (let* ((ops (analyze-file (make-instance 'lisp-analyzer)
                            "broken.lisp"
                            "(defun ok () 1)
(defun broken ("      ; unbalanced
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((file (find-by-name g :file "broken.lisp")))
      (is (not (null file)) "the file is asserted")
      (is-false (getp file :analysis-failed-p)
                "and is not marked failed, because most of it read fine")
      (is (equal '("ok") (mapcar #'name (entities-of-type g :function)))
          "the readable definition survives, and the damaged one mints nothing"))))

(test a-file-that-cannot-be-read-at-all-is-still-a-known-unknown
  ;; The failure path R3 narrowed but did not remove. Nothing in this tree
  ;; reaches it today, which is why it is asserted directly against the
  ;; unparsable-file entity rather than through a fixture: without this the
  ;; deletion of the path would be invisible.
  (let* ((condition (make-condition 'simple-error :format-control "unreadable"))
         (file (loom-analyzer::make-unparsable-file-entity
                "broken.lisp" "(((" condition)))
    (is-true (getp file :analysis-failed-p))
    (is (stringp (getp file :analysis-error)))))

(test a-foreign-package-prefix-does-not-cost-the-file
  ;; The analyzer reads source from workspaces this image has never loaded, so
  ;; a prefix naming an absent package is the normal case. Reading used to
  ;; signal on the first one and take every definition in the file with it:
  ;; indexing a 137-file Lisp repository found 128 definitions where 830 were
  ;; there, and `find' answered "nothing matches" for most of the codebase.
  (let* ((ops (analyze-file (make-instance 'lisp-analyzer)
                            "foreign.lisp"
                            "(defun caller ()
  (utils:parse-config (log:info \"x\") absent-package::internal))
(defvar *setting* (config:default))"
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((file (find-by-name g :file "foreign.lisp")))
      (is (not (null file)))
      (is-false (getp file :analysis-failed-p)
                "a package this image has not loaded is not a parse failure"))
    (let ((caller (find-by-name g :function "caller")))
      (is (not (null caller)) "the definition is indexed, prefixes and all")
      (is (not (null (find-by-name g :variable "*setting*"))))
      ;; "internal" is absent deliberately: absent-package::internal sits in an
      ;; argument position, so it is a variable reference, not a call.
      (is (equal '("info" "parse-config")
                 (sort (copy-list (getp caller :call-names)) #'string<))
          "and the calls survive under their bare names, which is all
TOKEN-NAME ever reads -- the prefix carries nothing worth failing over"))))

(test analyze-file-stamps-the-workspace-onto-every-op
  (is (every (lambda (op) (equal "ws-test" (workspace-id op))) (fixture-ops))))

(test an-entity-id-is-derived-so-a-rebuild-lands-on-the-same-one
  ;; SS14.4 asserts an incrementally updated index and an independently
  ;; rebuilt one are identical. Two independent analysis passes are the
  ;; smallest case of that.
  (let ((a (make-graph)) (b (make-graph)))
    (apply-transaction a (fixture-ops))
    (apply-transaction b (fixture-ops))
    (is (equal (sort (mapcar #'id (all-entities a)) #'string<)
               (sort (mapcar #'id (all-entities b)) #'string<)))))

;;; ------------------------------------------------------------------
;;; What the graph makes of them
;;; ------------------------------------------------------------------

(test analyze-file-creates-a-file-entity
  (multiple-value-bind (g file) (analyze-fixture)
    (is (not (null file)))
    (is (eq :file (entity-type file)))
    (is (string= *fixture-relative* (getp file :path)))
    (is (eq :lisp (getp file :language)))
    (is (eql 14 (getp file :line-count)))
    (is (eq file (get-entity g (id file))))))

(test analyze-file-creates-a-function-entity-per-defun
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (= 3 (length (entities-of-type g :function))))
    (is (not (null (find-by-name g :function "add-on"))))
    (is (not (null (find-by-name g :function "triple-add-on"))))
    (is (not (null (find-by-name g :function "summarize"))))))

(test analyze-file-records-correct-line-spans
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (let ((add-on (find-by-name g :function "add-on")))
      (is (eql 6 (getp add-on :start-line)))
      (is (eql 7 (getp add-on :end-line))))
    (let ((summarize (find-by-name g :function "summarize")))
      (is (eql 12 (getp summarize :start-line)))
      (is (eql 14 (getp summarize :end-line))))))

(test every-top-level-form-is-read-not-just-the-first
  ;; The walk used to read each form from a stream bounded to start at that
  ;; form and add the offset back to the resulting FILE-POSITION. Whether that
  ;; double-counts depends on a detail implementations disagree about, so on
  ;; half of them the second form's end landed past itself and the walk stopped
  ;; two forms in -- silently, since overshooting the end just ends the loop.
  ;; The leading comment is the whole point: it puts the first form at a
  ;; non-zero offset, which is where the two conventions started to differ.
  ;;
  ;; ARCH-0013 removed the mechanism the bug lived in -- READ-SOURCE reads one
  ;; stream straight through and never seeks -- so this is now a regression
  ;; guard on the tuple's contract rather than on that arithmetic. It stays
  ;; because the contract is what ARCH-0010 R1 named and what
  ;; ANALYZE-FILE's DESTRUCTURING-BIND still takes apart.
  ;;
  ;; Reached into with :: deliberately. The walk is not protocol -- SS8.1 makes
  ;; ANALYZE-FILE the only coupling an analyzer has -- so this stays a private
  ;; function that a test may name rather than something the package exports.
  (let* ((content ";;;; a header comment
(defparameter *a* 1)

(defun one () 1)

(defun two () (one))
")
         (forms (loom-analyzer::reading-forms
                 (loom-analyzer::read-source content))))
    (is (= 3 (length forms)) "every top-level form, not just the ones before
the first miscounted span")
    (is (equal '("defparameter" "defun" "defun")
               (mapcar (lambda (spec) (loom-analyzer::token-name (first (first spec))))
                       forms)))
    ;; Four elements, not three: the fourth is the character offset of the
    ;; form's first character. ELEMENT-SPANS was its only consumer and it is
    ;; gone, so the element is vestigial -- but ARCH-0010 R1 named the widened
    ;; tuple as a requirement, and ARCH-0013 keeps it rather than break that
    ;; requirement to save one cons per top-level form.
    (is (equal '((2 2 22) (4 4 44) (6 6 62))
               (mapcar #'rest forms))
        "and each one spans its own lines and knows where it starts")
    ;; The offsets above are derived -- 21 characters of header comment plus a
    ;; newline, then a newline and a blank line between each pair of forms --
    ;; but a derivation is only as good as the string it was derived from, and
    ;; that string is three lines above. This makes them self-checking: every
    ;; recorded offset must land on the open paren it claims to name, so an
    ;; edit to the source above cannot leave the numbers silently wrong.
    (dolist (spec forms)
      (is (char= #\( (char content (fourth spec)))
          "offset ~a does not name the start of a form" (fourth spec)))))


(test analyze-file-parses-arguments
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (equal '("x") (getp (find-by-name g :function "add-on") :arguments)))))

(test analyze-file-creates-a-variable-entity-per-defparameter
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (= 1 (length (entities-of-type g :variable))))
    (let ((tally (find-by-name g :variable "*tally*")))
      (is (not (null tally)))
      (is (eq :special (getp tally :kind)))
      (is (eql 3 (getp tally :start-line))))))

(test analyze-file-creates-contains-edges-from-the-file
  (multiple-value-bind (g file) (analyze-fixture)
    (let ((contained-ids (mapcar #'to-id (relationships-from g (id file) :rel-type :contains))))
      (is (= 4 (length contained-ids))
          "3 functions + 1 variable")
      (is (member (id (find-by-name g :function "add-on")) contained-ids :test #'equal))
      (is (member (id (find-by-name g :variable "*tally*")) contained-ids :test #'equal)))))

(test analyze-file-creates-calls-edges-between-local-functions
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (let* ((add-on (find-by-name g :function "add-on"))
           (triple (find-by-name g :function "triple-add-on"))
           (summarize (find-by-name g :function "summarize")))
      (is (equal (list (id add-on))
                 (mapcar #'to-id (relationships-from g (id triple) :rel-type :calls)))
          "triple-add-on calls add-on three times but must produce one edge")
      (is (equal (list (id triple))
                 (mapcar #'to-id (relationships-from g (id summarize) :rel-type :calls))))
      (is (null (relationships-from g (id add-on) :rel-type :calls))))))

(test analyze-file-does-not-record-calls-to-the-standard-library
  (multiple-value-bind (g file) (analyze-fixture)
    (declare (ignore file))
    (is (null (find-by-name g :function "format")))
    (is (null (find-by-name g :function "incf")))))

;;; ------------------------------------------------------------------
;;; Definer call sites (ARCH-0002 R2)
;;;
;;; Driven by literal source strings rather than by test/fixtures/sample.lisp.
;;; Several tests above count the entities and ops the shared fixture produces,
;;; so adding a macro or a call site to it would perturb every one of them for
;;; no gain -- ANALYZE-FILE takes path and contents, which is exactly the hook
;;; for handing it something small.
;;; ------------------------------------------------------------------

(defun analyze-source (source &optional (path "sample.lisp"))
  "A graph with SOURCE analyzed into it, and the :FILE entity it produced."
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'lisp-analyzer)
                                       path source "ws-test"))
    (values g (find-by-name g :file path))))

;;; ------------------------------------------------------------------
;;; Package declarations (ARCH-0015, PLAN-0015 step 3)

(test a-defpackage-records-its-aliases-uses-exports-and-every-import-clause
  (multiple-value-bind (g file) (analyze-source "
(defpackage #:mpackage/filter
  (:nicknames #:mpackage.filter)
  (:use #:cl)
  (:import-from #:mpackage/object #:name #:id)
  (:import-from #:utils #:proper-listp)
  (:export #:make-filter))")
    (declare (ignore file))
    (let ((p (find-by-name g :package "MPACKAGE/FILTER")))
      (is (not (null p)) "a package declaration is a definition this ontology models")
      (is (equal '("MPACKAGE.FILTER") (getp p :nicknames)))
      (is (equal '("CL") (getp p :uses)))
      (is (equal '("MAKE-FILTER") (getp p :exports)))
      ;; Every :import-from clause, not the first. Reading one is how
      ;; tools/package-census.lisp reported 0 imported names against a true
      ;; 227, so this is the assertion that guards the defect rather than the
      ;; feature.
      (is (equal '(("NAME" . "MPACKAGE/OBJECT")
                   ("ID"   . "MPACKAGE/OBJECT")
                   ("PROPER-LISTP" . "UTILS"))
                 (getp p :imported-symbols))
          "two clauses, three symbols, each paired with the package it came from"))))

(test a-uiop-define-package-is-read-exactly-like-a-defpackage
  ;; game-server declares 31 of its 41 packages this way. TOKEN-NAME reads
  ;; SYMBOL-NAME and nothing else, so the UIOP/PACKAGE: prefix is already gone
  ;; before the dispatch table sees the head.
  (multiple-value-bind (g file) (analyze-source "
(uiop/package:define-package :mpackage/filter
  (:nicknames :mpackage.filter)
  (:use :cl)
  (:import-from :mpackage/object :id))")
    (declare (ignore file))
    (let ((p (find-by-name g :package "MPACKAGE/FILTER")))
      (is (not (null p)))
      (is (equal '("MPACKAGE.FILTER") (getp p :nicknames)))
      (is (equal '(("ID" . "MPACKAGE/OBJECT")) (getp p :imported-symbols))))))

(test a-clause-that-moves-symbols-and-is-not-modelled-is-recorded-not-dropped
  ;; CON-0001. Neither tree uses these -- zero occurrences in 65 declarations,
  ;; measured 2026-08-10 -- so the first that does must be a recorded gap
  ;; rather than a confident wrong answer.
  (multiple-value-bind (g file) (analyze-source "
(uiop/package:define-package :a
  (:use :cl)
  (:use-reexport :b)
  (:shadow :name))")
    (declare (ignore file))
    (let ((p (find-by-name g :package "A")))
      (is (member "USE-REEXPORT" (getp p :unhandled-package-clauses) :test #'equal))
      (is (member "SHADOW" (getp p :unhandled-package-clauses) :test #'equal)))))

(test a-package-declaration-does-not-change-the-package-in-effect
  ;; Declaring a package is not entering it. HANDLE-DEFPACKAGE returns SYSTEM
  ;; unchanged, so the definitions after it belong to whatever IN-PACKAGE said,
  ;; and a file that declares a package it never enters does not capture them.
  (multiple-value-bind (g file) (analyze-source "
(defpackage #:declared-only (:use #:cl))
(in-package #:actually-entered)
(defun f () 1)")
    (declare (ignore file))
    (is (eq :actually-entered (getp (find-by-name g :function "f") :system))
        "the DEFPACKAGE between them must not have become the current package")))

;;; ------------------------------------------------------------------
;;; What the reader passed over, on the file entity (ARCH-0013, PLAN-0013 R5)
;;;
;;; The mechanism landed with READ-SOURCE; this is the reporting half, and the
;;; thing it has to get right is which gaps are worth reporting. Comments reach
;;; the analyzer through the same channel as feature-suppressed code and
;;; outnumber it 4513 to 2 on this tree, so the assertions below are as much
;;; about what is absent from the property as about what is in it.
;;; ------------------------------------------------------------------

(test a-malformed-form-costs-a-form-and-not-the-file
  ;; REQ-0019 R3, end to end. Before this the reader signalled, ANALYZE-FILE's
  ;; HANDLER-CASE caught it, and the file became one :ANALYSIS-FAILED-P entity
  ;; with every definition in it invisible to `find'.
  ;;
  ;; The THIRD definition is the assertion that matters. One asserting only
  ;; that the first survives passes with READ-SOURCE's HANDLER-BIND and
  ;; HANDLER-CASE nested the wrong way round, whose symptom is not an error but
  ;; the rest of the file silently not being read.
  (multiple-value-bind (g file)
      (analyze-source "(defun a () 1)
)
(defun c () 3)")
    (is-false (getp file :analysis-failed-p)
              "a file with damage in it is read, not failed")
    (is (not (null (find-by-name g :function "a"))))
    (is (not (null (find-by-name g :function "c")))
        "the definition after the damage is indexed")
    (let ((recovered (getp file :recovered-regions)))
      (is (= 1 (length recovered)) "and the damage is one recorded region")
      (is-true (getf (first recovered) :start-line)
               "with a line someone can open")
      (is (eq :nothing (getf (first recovered) :cost))
          "a stray paren between forms costs no definition"))))

(test a-repaired-form-mints-nothing-and-says-what-it-cost
  ;; ARCH-0013 R4's other half. Recovering an unterminated list swallows the
  ;; NEXT definition into the damaged one's body, so a repaired form handed to
  ;; pass 1 would mint a :FUNCTION named b whose range covers the text defining
  ;; c -- and c would vanish with no count moving to say so. The entity is
  ;; wrong rather than missing, which is the fabrication CON-0001 forbids
  ;; because nothing downstream can detect it.
  (multiple-value-bind (g file)
      (analyze-source "(defun a () 1)
(defun b () (oops
(defun c () 3)")
    (is (not (null (find-by-name g :function "a"))))
    (is (null (find-by-name g :function "b"))
        "the repaired form mints nothing")
    (is (null (find-by-name g :function "c"))
        "and neither does the definition it swallowed -- a recorded gap")
    (let ((recovered (getp file :recovered-regions)))
      ;; Two, not one: an unterminated list signals at end of input once for
      ;; the inner list and once for the outer, and both are damage to the same
      ;; form. Asserted as two because classifying only one of them as having
      ;; cost a form -- which is what a single FIND-IF over the repairs did --
      ;; leaves the other reading as harmless junk in the property an agent
      ;; consults to find out why a name is missing.
      (is (= 2 (length recovered)))
      (is (every (lambda (r) (eq :form (getf r :cost))) recovered)
          "every repair to this form cost a form, where a stray paren costs
nothing"))))

(test a-feature-suppressed-branch-is-a-recorded-gap-and-a-comment-is-not
  ;; The discrimination the property exists for. Both halves are asserted in
  ;; one test deliberately: recording the branch is worthless if commentary
  ;; comes with it, since 4513 entries burying 2 is the same failure as
  ;; recording nothing -- BUG-0009's, in a different place.
  (multiple-value-bind (g file)
      (analyze-source ";; an ordinary line comment
#| and a block comment |#
(defun a () 1)
#+no-such-feature (defun b () 2)")
    (is (not (null (find-by-name g :function "a"))))
    (is (null (find-by-name g :function "b"))
        "the branch the feature policy did not take defines nothing")
    (let ((suppressed (getp file :suppressed-regions)))
      (is (= 1 (length suppressed))
          "one region: the branch, and neither comment")
      (is (string= "sharpsign-plus" (getf (first suppressed) :reason))
          "named by the marker, not by the uninterned feature symbol after it")
      (is (= 4 (getf (first suppressed) :start-line))))))

(test a-read-eval-form-is-refused-with-a-line-and-costs-only-itself
  ;; REQ-0019 R4. Under the host reader with *READ-EVAL* NIL this signalled a
  ;; READER-ERROR, which reached ANALYZE-FILE's HANDLER-CASE and lost every
  ;; definition in the file. Refusing the form was always the requirement;
  ;; losing the file for it never was.
  (multiple-value-bind (g file)
      (analyze-source "(defun a () 1)
(defparameter *x* #.(+ 1 2))
(defun c () 3)")
    (is (not (null (find-by-name g :function "a"))))
    (is (not (null (find-by-name g :function "c"))))
    (let ((suppressed (getp file :suppressed-regions)))
      (is (= 1 (length suppressed)))
      (is (string= "read-eval" (getf (first suppressed) :reason)))
      (is (eql 2 (getf (first suppressed) :start-line))
          "the line the refusal happened on, not NIL"))))

(test a-clean-file-carries-neither-property
  ;; Absent and empty differ. A file with nothing to report must carry no
  ;; property rather than an empty list, or every one of this tree's 177 files
  ;; would read as a report that says nothing -- the same discipline
  ;; :SHADOWED-DEFINITIONS keeps, and what makes a non-NIL value meaningful.
  (multiple-value-bind (g file)
      (analyze-source "(defun a () 1)
;; a comment, which is not a gap in anything")
    (declare (ignore g))
    (is (null (getp file :suppressed-regions)))
    (is (null (getp file :recovered-regions)))))

;;; ------------------------------------------------------------------
;;; The package prefix a call site wrote (REQ-0019 R2, PLAN-0013 step 6)
;;;
;;; Recorded, and read by nothing. The scope discipline is the point of the
;;; step: whether resolution should prefer a qualified match is REQ-0015's
;;; question, and answering it here would move edge counts under cover of a
;;; reader change, leaving a movement nobody could attribute to one or the
;;; other. So these tests assert both halves -- the fact is recorded, and
;;; nothing downstream moved.
;;; ------------------------------------------------------------------

(test a-qualified-call-records-the-prefix-the-site-wrote
  ;; The fact INTERN-FOREIGN-SYMBOL-LOCALLY destroyed. Before ARCH-0013 the
  ;; prefix was absorbed into a throwaway package at read time and TOKEN-NAME
  ;; read SYMBOL-NAME alone, so by the time anything could have recorded it the
  ;; evidence was gone.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (utils:parse-config) (local-thing))")
    (declare (ignore file))
    (let ((f (find-by-name g :function "f")))
      ;; Reverse source order, which is what :CALL-NAMES has always been --
      ;; COLLECT-CALL-NAMES pushes as it walks and the list is not re-sorted.
      ;; Asserted as it is rather than as it reads, because the point of this
      ;; test is that the first value did not move.
      (is (equal '("local-thing" "parse-config") (getp f :call-names))
          "the names are what they always were")
      (is (equal '((:name "parse-config" :package "utils"))
                 (getp f :qualified-calls))
          "and the prefix is recorded beside them, for the one site that wrote
one"))))

(test two-prefixes-on-one-name-are-two-facts-and-not-one
  ;; The deduplication has to be on the pair, not the name. Collapsing by name
  ;; would keep whichever came first and make the surviving prefix look like
  ;; the only one the file wrote -- a fabricated fact in the shape CON-0001
  ;; names, since nothing downstream could tell it from a body that really did
  ;; write only one.
  (multiple-value-bind (g file)
      (analyze-source "(defun f ()
  (utils:parse-config)
  (config:parse-config)
  (utils:parse-config))")
    (declare (ignore file))
    (let ((qualified (getp (find-by-name g :function "f") :qualified-calls)))
      (is (= 2 (length qualified))
          "two distinct prefixes, and the repeat of one of them collapsed")
      (is (equal '("config" "utils")
                 (sort (mapcar (lambda (q) (getf q :package)) qualified)
                       #'string<))))))

(test a-function-quotation-keeps-its-prefix-too
  ;; #'utils:parse-config is as qualified as (utils:parse-config x). The
  ;; FUNCTION clause is the one place a name is recovered from an argument
  ;; position rather than an operator position (BUG-0011), so it needs the
  ;; recording said separately or it silently would not have it.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (mapcar #'utils:parse-config xs))")
    (declare (ignore file))
    (let ((qualified (getp (find-by-name g :function "f") :qualified-calls)))
      (is (equal '((:name "parse-config" :package "utils")) qualified)))))

(test recording-a-prefix-moves-no-call-name-and-no-edge
  ;; PLAN-0013 step 6's scope discipline, asserted rather than argued. The
  ;; second value of COLLECT-CALL-NAMES is additive by construction -- the
  ;; first is computed exactly as before -- and this is what would go red if a
  ;; later change made the prefix affect which names are collected or which
  ;; local calls resolve.
  (let ((source "(defun helper (x) x)
(defun f () (helper 1) (utils:helper 2))"))
    (multiple-value-bind (g file) (analyze-source source)
      (declare (ignore file))
      (let ((f (find-by-name g :function "f")))
        ;; Both sites reduce to "helper" and both resolve to the local
        ;; definition, which is exactly the ambiguity REQ-0015 exists for and
        ;; which this step deliberately does NOT fix. Asserted as it stands, so
        ;; that whoever does fix it has to come here and say so.
        (is (null (getp f :call-names))
            "both sites resolved locally, prefix or no prefix")
        (is (equal '((:name "helper" :package "utils"))
                   (getp f :qualified-calls))
            "while the evidence that one of them was qualified is kept")
        (is (= 1 (count-if (lambda (r) (eq :calls (rel-type r)))
                           (all-relationships g)))
            "one :CALLS edge, as before -- the prefix changed no resolution")))))

(test a-clean-body-carries-no-qualified-calls-property
  ;; Absent rather than empty, the discipline :SHADOWED-DEFINITIONS and
  ;; :SUPPRESSED-REGIONS both keep. Most bodies write no prefix at all, so an
  ;; empty list on every one of them is noise that reads as a report.
  (multiple-value-bind (g file) (analyze-source "(defun f () (bare-call))")
    (declare (ignore file))
    (is (null (getp (find-by-name g :function "f") :qualified-calls)))))

;;; ------------------------------------------------------------------
;;; Reader-produced quotation (ARCH-0013 R12, PLAN-0013 step 8)
;;;
;;; The one step that deliberately changes the walk's output, which is why it
;;; lands after the parity steps rather than inside them. Both cases below were
;;; disclosed in COLLECT-CALL-NAMES' own docstring and accepted under PLAN-0011
;;; R-7 because "the analyzer holds no package knowledge to do better"; they
;;; are here as tests now that it does.
;;; ------------------------------------------------------------------

(test a-literal-function-call-is-not-a-quotation
  ;; The visible false positive. (some-pkg:function g) is an ordinary call to
  ;; something named FUNCTION in someone else's package, and it matched the
  ;; arity test that recovers #'g -- so "g" appeared in :CALL-NAMES and, once
  ;; resolution ran, could manufacture an edge to a definition the file never
  ;; mentions.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (some-pkg:function g))")
    (declare (ignore file))
    (let ((names (getp (find-by-name g :function "f") :call-names)))
      (is (null (member "g" names :test #'string=))
          "the argument is a value, not a quoted name")
      ;; "function" itself is absent too, and for an older reason that is not
      ;; this change's: STANDARD-OPERATOR-P filters every name that finds a
      ;; symbol in COMMON-LISP, and CL:FUNCTION does. The prefix is recorded
      ;; even so, which is the evidence a future resolution pass would need to
      ;; tell this site from a real CL:FUNCTION.
      (is (equal '((:name "function" :package "some-pkg"))
                 (getp (find-by-name g :function "f") :qualified-calls))))))

(test a-real-function-quotation-still-contributes-its-name
  ;; The guard on the test above: refusing (some-pkg:function g) is worthless
  ;; if it also refuses #'g, which is BUG-0011's whole fix.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (mapcar #'target xs))")
    (declare (ignore file))
    (is (member "target" (getp (find-by-name g :function "f") :call-names)
                :test #'string=))))

(test a-foreign-quote-does-not-suppress-the-walk-of-its-contents
  ;; The silent miss, and the more damaging of the two: (some-pkg:quote x) was
  ;; taken for quoted data, so every call inside it went unwalked and the
  ;; callees simply had no incoming edge -- nothing appeared anywhere to say a
  ;; body had been skipped.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (some-pkg:quote (inner-call x)))")
    (declare (ignore file))
    (let ((names (getp (find-by-name g :function "f") :call-names)))
      (is (member "inner-call" names :test #'string=)
          "the contents are walked, because this is not CL:QUOTE"))))

(test real-quoted-data-is-still-not-walked
  ;; The guard on that one. 'x written as a reader macro and (quote x) written
  ;; out longhand are both genuinely quoted data, and treating either as a call
  ;; site is the false positive the head-only discipline exists to prevent.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () '(not-a-call x) (quote (also-not-a-call y)))")
    (declare (ignore file))
    (let ((names (getp (find-by-name g :function "f") :call-names)))
      (is (null (member "not-a-call" names :test #'string=))
          "the reader macro's contents are data")
      (is (null (member "also-not-a-call" names :test #'string=))
          "and so are a hand-written CL:QUOTE's"))))

(test a-keyword-in-operator-position-is-not-a-call
  ;; BUG-0020. A keyword can never name a function in Common Lisp, so a list
  ;; whose head is one is a declaration, a plist or a CASE clause -- never a
  ;; call. TOKEN-NAME renders :FILE and FILE identically, so nothing downstream
  ;; can tell the two apart once the name is a string; the test has to be on
  ;; the symbol, in the walk, before TOKEN-NAME is applied.
  ;;
  ;; Both populations are asserted because both mint. The ordinary body is
  ;; where a CASE clause head lives, and the definer call site is where the
  ;; five edges that made this urgent live: `(:line-count integer)' inside a
  ;; DEFENTITY call reads as a call to LINE-COUNT, which is a real function in
  ;; loom-analyzer -- so PLAN-0014's step 7 would mint a :CALL-SITE for it and
  ;; hand RULE-0001, the one machine-checked rule whose output is currently
  ;; trustworthy, a :CALLS edge out of loom-ontology that nobody wrote.
  (multiple-value-bind (g file)
      (analyze-source "(defun f () (:file string :required t) (real-call x))
(defentity thing (:line-count integer))")
    (let ((names (getp (find-by-name g :function "f") :call-names)))
      (is (null (member "file" names :test #'string=))
          "a keyword head is not an operator")
      (is (member "real-call" names :test #'string=)
          "and an ordinary head beside it still is"))
    (let ((site (first (getp file :definer-call-sites))))
      (is (equal "defentity" (getf site :operator)))
      (is (null (member "line-count" (getf site :call-names) :test #'string=))
          "nor is a keyword head inside a definer call site's arguments"))))

;;; ------------------------------------------------------------------
;;; Initform call sites (BUG-0017, ARCH-0014 R3, PLAN-0014 step 6)
;;;
;;; The half of BUG-0017 its own FIX could not choose. A designator in an
;;; initform never reached COLLECT-CALL-NAMES at all -- ANALYZE-FILE hands
;;; NOTE-DEFINITION no :body for a DEFVAR, DEFPARAMETER, DEFCLASS or
;;; DEFINE-CONDITION -- and the reason the fix stalled once it did was that the
;;; recorded caller would have been a :VARIABLE, which :CALLS refuses as a
;;; source. ARCH-0014's answer is a :CALL-SITE the variable contains, so the
;;; ontology question that blocked it does not arise.
;;; ------------------------------------------------------------------

(test an-initform-designator-reaches-its-callee-through-a-call-site
  ;; R8's first test, and BUG-0017's SYMPTOM exactly: (defparameter *hook*
  ;; #'target) beside a DEFUN of TARGET left TARGET with no incoming edge at
  ;; all, so `describe target' answered as though nothing referenced it.
  (multiple-value-bind (g file)
      (analyze-source "(defun target (x) x)
(defparameter *hook* #'target)")
    (declare (ignore file))
    (let ((site (first (entities-of-type g :call-site)))
          (hook (find-by-name g :variable "*hook*"))
          (target (find-by-name g :function "target")))
      (is (not (null site)) "the initform mints one call site")
      (is (equal "target" (getp site :call-name)))
      (is (eq :variable (getp site :referrer-kind)))
      (is (equal (list (id site))
                 (mapcar #'to-id (relationships-from g (id hook) :rel-type :contains)))
          "owned by the variable through :CONTAINS -- decision 3's chain, file
contains variable contains call-site")
      ;; RESOLVE-CALLS rather than a local edge: the analyzer holds no callable
      ;; index and a call site is deliberately not short-circuited against
      ;; LOCAL-FUNCTIONS, so the edge is the graph's to derive like any other.
      (apply-transaction g (resolve-calls g :workspace-id "ws-test"))
      (is (equal (list (id target))
                 (mapcar #'to-id (relationships-from g (id site) :rel-type :calls)))
          "and the call reaches TARGET once resolution runs"))))

(test a-slot-initform-mints-a-call-site-its-class-contains
  ;; The DEFCLASS half of R3, which reads the initform off a slot option plist
  ;; rather than off a fixed position. A slot spec that is a bare symbol
  ;; declares no options at all and must not be read as one.
  (multiple-value-bind (g file)
      (analyze-source "(defun compute-default () 1)
(defclass thing ()
  (bare
   (slot :initarg :slot :initform (compute-default))))")
    (declare (ignore file))
    (let ((site (first (entities-of-type g :call-site)))
          (class (find-by-name g :class "thing")))
      (is (= 1 (length (entities-of-type g :call-site)))
          "one call site: the bare slot spec contributes none")
      (is (equal "compute-default" (getp site :call-name)))
      (is (eq :class (getp site :referrer-kind)))
      (is (equal (list (id site))
                 (mapcar #'to-id (relationships-from g (id class) :rel-type :contains)))))))

(test an-initform-mints-no-call-site-for-the-standard-library
  ;; The filter pass 2 applies, applied here for the same reason: every
  ;; operator position is a call candidate, and recording LIST and MAKE-HASH-
  ;; TABLE would bury the handful of names that point at another file. Also the
  ;; guard on the ceiling test in src/workspace/test/workspace.lisp -- an
  ;; unfiltered initform walk mints a call site for most DEFPARAMETERs in the
  ;; tree, which is the uniform model ARCH-0014 refused arriving by accident.
  (multiple-value-bind (g file)
      (analyze-source "(defparameter *table* (make-hash-table :test #'equal))")
    (declare (ignore file))
    (is (null (entities-of-type g :call-site))
        "make-hash-table and equal are both CL, so nothing is minted")))

(test a-superseded-definition-takes-its-call-sites-with-it
  ;; The supersession trap PLAN-0014 step 6 names. CALLABLES and LOCAL-FUNCTIONS
  ;; are filtered against the survivors at ANALYZE-FILE's supersession block,
  ;; and a call site list that is not would leave a site whose owner is never
  ;; asserted -- an entity in the graph with a :CONTAINS edge from nothing.
  (multiple-value-bind (g file)
      (analyze-source "(defparameter *hook* #'dropped-target)
(defparameter *hook* #'live-target)")
    (declare (ignore file))
    (is (equal '("live-target")
               (mapcar (lambda (e) (getp e :call-name))
                       (entities-of-type g :call-site)))
        "the shadowed DEFPARAMETER's initform is dead code and mints nothing")))

;;; ------------------------------------------------------------------
;;; Pass 1's dispatch table (ARCH-0013 R13, PLAN-0013 step 9)
;;;
;;; Behaviour-preserving, and the only step in the plan that is not about the
;;; reader at all. What it removes is a synchronisation *DEFINITION-HEADS*'
;;; own docstring made the reader responsible for.
;;; ------------------------------------------------------------------

(test the-dispatch-table-refuses-a-duplicate-head
  ;; The risk ARCH-0013 names, and the reason this table's semantics are the
  ;; opposite of the four registries REQ-0004 built. Those replace by name,
  ;; because they exist to be extended by third parties. This one is exhaustive
  ;; over a fixed set the analyzer owns, so a duplicated head must be a
  ;; load-time error -- replace-by-name would make it a definition kind that
  ;; silently stops being indexed in every workspace, with no count moving to
  ;; say so.
  (signals error
    (loom-analyzer::make-definition-dispatch
     (list (loom-analyzer::definition-handler "defun" #'identity)
           (loom-analyzer::definition-handler "defclass" #'identity)
           (loom-analyzer::definition-handler "defun" #'identity))))
  (finishes
    (loom-analyzer::make-definition-dispatch
     (list (loom-analyzer::definition-handler "defvar" #'identity)
           (loom-analyzer::definition-handler "defparameter" #'identity))))
  ;; Two heads sharing one handler is ordinary and must stay allowed: DEFVAR
  ;; and DEFPARAMETER shared a COND clause and now share a function. It is
  ;; duplicate keys that are refused, not duplicate values.
  (finishes
    (let ((one #'identity))
      (loom-analyzer::make-definition-dispatch
       (list (loom-analyzer::definition-handler "defvar" one)
             (loom-analyzer::definition-handler "defparameter" one))))))

(test the-head-set-is-the-tables-keys-and-cannot-drift
  ;; What replaced *DEFINITION-HEADS*. The failure the old docstring named was
  ;; "a DEFUN being offered to the macro registry", which is what happens when
  ;; a head has a clause but no entry in the parallel list -- so the assertion
  ;; is that every head the table dispatches on is also a head CALL-SITE-HEAD-P
  ;; accounts for, which is now true by construction rather than by upkeep.
  (dolist (head '("defun" "defmacro" "defvar" "defparameter" "defclass"
                  "define-condition" "defstruct" "defgeneric" "defmethod"
                  "in-package"))
    (is-true (loom-analyzer::definition-head-p head)
             "~a has no handler" head)
    (is-true (loom-analyzer::call-site-head-p head)
             "~a would be offered to the macro registry" head))
  (is-false (loom-analyzer::definition-head-p "struct-simplefn")
            "a definer macro is not a definition head"))

(test in-package-is-no-longer-a-first-clause-defending-its-position
  ;; The ordering comment step 9 deletes rather than carries forward. A keyed
  ;; lookup cannot be shadowed, so the property the comment defended has to be
  ;; asserted somewhere -- here. IN-PACKAGE sets the system, mints nothing, and
  ;; stays out of :DEFINER-CALL-SITES.
  (multiple-value-bind (g file)
      (analyze-source "(in-package :loom-graph)
(defun f () 1)")
    (is (eq :loom-graph (getp (find-by-name g :function "f") :system))
        "the handler's return value is what threads the system through")
    (is (eq :loom-graph (getp file :system)))
    (is (null (find-by-name g :function "in-package"))
        "and it mints nothing itself")
    (is (null (remove-if-not (lambda (site)
                               (string= "in-package" (getf site :operator)))
                             (getp file :definer-call-sites)))
        "nor reaches :DEFINER-CALL-SITES")))

(test a-top-level-call-is-recorded-as-a-definer-call-site
  ;; The whole input resolution gets: what was called, where, with what
  ;; arguments, and what the arguments themselves call. Without this property
  ;; a macro-defined name is invisible, because it appears nowhere as a defun.
  (multiple-value-bind (g file)
      (analyze-source "(struct-simplefn geo \"d\" (compute-area x))")
    (declare (ignore g))
    (let ((sites (getp file :definer-call-sites)))
      (is (= 1 (length sites)))
      (let ((site (first sites)))
        (is (string= "struct-simplefn" (getf site :operator)))
        (is (member "geo" (getf site :arguments) :test #'string=))
        (is (member 1 (getf site :symbol-arguments))
            "position 1 held a bare symbol, which is what lets resolution
name the entity rather than invent a name for it")
        (is (member "compute-area" (getf site :call-names) :test #'string=)
            "the argument list is walked for calls, or the generated entity
would exist with no edges and impact would still report nothing")))))

(test a-definition-is-not-a-call-site
  (multiple-value-bind (g file)
      (analyze-source "(in-package :foo)
(defun alpha (x) (beta x))
(defparameter *a* 1)
(declaim (inline alpha))")
    (declare (ignore g))
    (is (null (getp file :definer-call-sites))
        "a defun defines something the analyzer already indexed, and a
declaration defines nothing; neither is a call to a macro")))

(test a-call-site-argument-that-is-not-a-symbol-is-recorded-as-such
  ;; Nothing guarantees a call site put a symbol where the registry says the
  ;; name is. Minting from a computed form would produce a garbage-named
  ;; entity that resolves nothing and never goes away, so the fact that the
  ;; position is not a name has to survive into the property.
  (multiple-value-bind (g file)
      (analyze-source "(struct-simplefn (derive-name i) \"d\")")
    (declare (ignore g))
    (let ((site (first (getp file :definer-call-sites))))
      (is (not (null site)))
      (is (null (member 1 (getf site :symbol-arguments)))
          "position 1 is a form to be computed, not a name that is written")
      (is (member "derive-name" (getf site :call-names) :test #'string=)
          "and the site is still recorded and still walked -- the name is
what resolution has to refuse, not the whole entry"))))

(test a-call-site-argument-that-is-a-function-quotation-is-recorded
  ;; DEFINER-CALL-SITE is COLLECT-CALL-NAMES' other consumer, and the one whose
  ;; output RESOLVE-GENERATED-DEFINITIONS copies onto the entity a definer macro
  ;; mints -- in practice every FiveAM (test ...) form. Testing the quotation
  ;; only through a DEFUN body would leave half the blast radius of BUG-0011
  ;; uncovered.
  (multiple-value-bind (g file)
      (analyze-source "(deftest checks-it (verify #'target 1))")
    (declare (ignore g))
    (let ((site (first (getp file :definer-call-sites))))
      (is (not (null site)))
      (is (member "target" (getf site :call-names) :test #'string=)
          "#'target designates TARGET as surely as calling it does -- BUG-0011"))))

;;; ------------------------------------------------------------------
;;; Function quotations (BUG-0011)
;;;
;;; #'f reads as (FUNCTION F), so the name sits in an argument position and the
;;; head-only walk dropped it. These four fix the boundary of the one special
;;; case that recovers it: a bare symbol and a (SETF f) cons are names; anything
;;; else, a lambda above all, is not a name and must still be walked for the
;;; calls inside it.
;;; ------------------------------------------------------------------

(test a-function-quotation-of-a-local-name-becomes-a-calls-edge
  ;; The core regression: zero edges before the fix. A local callee is asserted
  ;; as an edge by ANALYZE-FILE's pass 2 rather than left to the graph layer,
  ;; which is what lets this assert on the edge and not on a property.
  (multiple-value-bind (g file)
      (analyze-source "(defun render (item) item)
(defun run (items) (mapcar #'render items))")
    (declare (ignore file))
    (let ((render (find-by-name g :function "render"))
          (run (find-by-name g :function "run")))
      (is (equal (list (id render))
                 (mapcar #'to-id (relationships-from g (id run) :rel-type :calls)))
          "#'render designates RENDER, so RUN calls it"))))

(test a-function-quotation-of-a-foreign-name-lands-in-call-names
  ;; game-server's DHANDLER-DELETE shape reduced to one line: the name is
  ;; defined in another file, so pass 2 records it for RESOLVE-CALLS rather
  ;; than emitting an edge. This is what ARCH-0010 R7 asked for and BUG-0011
  ;; found missing.
  (multiple-value-bind (g file)
      (analyze-source "(defun run (args) (apply #'make-selector args))")
    (declare (ignore file))
    (let ((run (find-by-name g :function "run")))
      (is (member "make-selector" (getp run :call-names) :test #'string=)))))

(test a-setf-function-quotation-records-the-name-a-defmethod-is-named-by
  ;; Asserted on :CALL-NAMES and not on an edge, deliberately: a DEFMETHOD is
  ;; kept out of LOCAL-FUNCTIONS on purpose, so the edge is RESOLVE-CALLS' job
  ;; at the graph layer and asserting one here would be asserting against the
  ;; wrong layer. What matters here is that the string recorded is the same one
  ;; DEFINITION-NAME gives the DEFMETHOD -- otherwise nothing downstream could
  ;; ever match the two.
  (multiple-value-bind (g file)
      (analyze-source "(defmethod (setf render) (v (x hop)) v)
(defun install (x) (funcall #'(setf render) 1 x))")
    (declare (ignore file))
    (let ((install (find-by-name g :function "install")))
      (is (member "(setf render)" (getp install :call-names) :test #'string=)))))

(test a-lambda-quotation-records-no-name-and-loses-no-call
  ;; THE GUARD, and it needs its history stated or it reads as vacuous: it
  ;; passes on unmodified code too. What makes it assert something is the
  ;; mutation it was observed to fail under -- recording DEFINITION-NAME of any
  ;; cons in the quotation's argument position, which renders
  ;; #'(lambda (item) (helper item)) as the fabricated name
  ;; "(lambda item helper)": unfiltered by STANDARD-OPERATOR-P, resolving to
  ;; nothing, and permanent. CON-0001. The exact-list assertion is what catches
  ;; that; asserting merely that "lambda" is absent would not, because
  ;; TOKEN-NAME of the cons is "lambda" and both consumers already filter it.
  (multiple-value-bind (g file)
      (analyze-source "(defun helper (x) x)
(defun run (items) (mapcar #'(lambda (item) (helper item)) items))")
    (declare (ignore file))
    (let ((helper (find-by-name g :function "helper"))
          (run (find-by-name g :function "run")))
      (is (equal (list (id helper))
                 (mapcar #'to-id (relationships-from g (id run) :rel-type :calls)))
          "the lambda body is still walked -- the quotation must not shadow it")
      ;; "item" is the head of the lambda list, the same pre-existing
      ;; imprecision that records "selector" for a LET binding head. BUG-0011
      ;; puts that out of scope; the exact list is how this test notices if
      ;; someone fixes it here anyway, or adds a name that is not a name.
      (is (equal '("item") (getp run :call-names))))))

;;; ------------------------------------------------------------------
;;; What a DEFMETHOD produces, recorded bit for bit (ARCH-0010 R3)
;;;
;;; An inverted guard, and it is worth saying so plainly: these literals were
;;; recorded mechanically from the analyzer *before* METHOD-DEFINITION-ENTITY
;;; and METHOD-BODY were split into wrappers over a shared core that the
;;; inline (:method ...) clause path also uses. Passing on the day they were
;;; written proves nothing -- it is what makes them a baseline. What makes
;;; them a guard is that they must still pass after the split, so that a
;;; property silently gained or lost, or a qualifier that stopped reaching the
;;; id, cannot hide inside a refactor advertised as inert.
;;;
;;; The whole property table is walked rather than a chosen few. A spot check
;;; of :qualifier and :specializers would not catch a dropped :signature or a
;;; :system that stopped defaulting.
;;;
;;; The corpus is eight sources: one per branch of the tail parsing, plus one
;;; that repeats a branch at a path carrying a system, because the other seven
;;; are analyzed where there is none and a dropped SYSTEM argument would leave
;;; every one of them green. The two
;;; that matter most are the empty lambda list -- which must NOT be read as a
;;; qualifier, and is the input that tells a correct qualifier test from
;;; (when (first tail) ...) written the obvious wrong way -- and the qualified
;;; case, whose qualifier is a natural-key component and so shows up twice, in
;;; the property and in the id.
;;; ------------------------------------------------------------------

(defun method-fingerprint (entity)
  "Everything about ENTITY that must not move: its type, name, id, origin
file, and every property with its value, in a stable order."
  (list (entity-type entity)
        (name entity)
        (id entity)
        (origin-file entity)
        (let ((pairs '()))
          (maphash (lambda (k v) (push (list k v) pairs))
                   (properties entity))
          (sort pairs #'string< :key (lambda (p) (princ-to-string (first p)))))))

(defparameter *defmethod-corpus*
  '(;; a  plain specializer
    ("(defmethod render ((x hop)) x)"
     (:method "render" "method:sample.lisp:render::hop" "sample.lisp"
      ((:arguments ("x")) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualified-calls nil) (:qualifier nil)
       (:shadowed-definitions nil) (:signature nil) (:specializers ("hop"))
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     (x))
    ;; b  a qualifier, which is a natural-key component: it must survive into
    ;;    the :QUALIFIER property AND into the id's third segment
    ("(defmethod render :around ((x hop)) x)"
     (:method "render" "method:sample.lisp:render:around:hop" "sample.lisp"
      ((:arguments ("x")) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualified-calls nil) (:qualifier :around)
       (:shadowed-definitions nil) (:signature nil) (:specializers ("hop"))
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     (x))
    ;; c  EQL specializer, rendered rather than resolved
    ("(defmethod render ((x (eql :oneof))) x)"
     (:method "render" "method:sample.lisp:render::(eql oneof)" "sample.lisp"
      ((:arguments ("x")) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualified-calls nil) (:qualifier nil)
       (:shadowed-definitions nil) (:signature nil)
       (:specializers ("(eql oneof)")) (:start-line 1)
       (:system nil) (:unresolved-calls nil)))
     (x))
    ;; d  a (setf f) name, which DEFINITION-NAME renders rather than flattens
    ("(defmethod (setf render) (v (x hop)) v)"
     (:method "(setf render)" "method:sample.lisp:(setf render)::t,hop"
      "sample.lisp"
      ((:arguments ("v" "x")) (:call-names nil) (:end-line 1)
       (:file "sample.lisp") (:generic-function "(setf render)")
       (:language :lisp) (:qualified-calls nil) (:qualifier nil) (:shadowed-definitions nil)
       (:signature nil)
       (:specializers ("t" "hop")) (:start-line 1) (:system nil)
       (:unresolved-calls nil)))
     (v))
    ;; e  an empty lambda list. NIL is a symbol, so a qualifier test written
    ;;    without the NIL guard reads () as a qualifier, loses the lambda list
    ;;    and mints an entity with the body where its arguments belong.
    ("(defmethod render () 1)"
     (:method "render" "method:sample.lisp:render::" "sample.lisp"
      ((:arguments nil) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualified-calls nil) (:qualifier nil)
       (:shadowed-definitions nil) (:signature nil) (:specializers nil)
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     (1))
    ;; f  an & marker stops the specializer walk but not the argument list
    ("(defmethod render ((x hop) &rest args) args)"
     (:method "render" "method:sample.lisp:render::hop" "sample.lisp"
      ((:arguments ("x" "&rest" "args")) (:call-names nil) (:end-line 1)
       (:file "sample.lisp") (:generic-function "render") (:language :lisp)
       (:qualified-calls nil) (:qualifier nil) (:shadowed-definitions nil) (:signature nil)
       (:specializers ("hop"))
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     (args))
    ;; g  wholly unspecialized, and the only entry with a call in its body
    ("(defmethod render (a b) (helper a b))"
     (:method "render" "method:sample.lisp:render::t,t" "sample.lisp"
      ((:arguments ("a" "b")) (:call-names ("helper")) (:end-line 1)
       (:file "sample.lisp") (:generic-function "render") (:language :lisp)
       (:qualified-calls nil) (:qualifier nil) (:shadowed-definitions nil) (:signature nil)
       (:specializers ("t" "t"))
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     ((helper a b)))
    ;; h  case a again, at a path DEFAULT-SYSTEM-FOR-PATH recognises. Every row
    ;;    above is analyzed at "sample.lisp", which has no system, so all seven
    ;;    record (:system nil) and all seven would still pass if SYSTEM stopped
    ;;    being threaded into METHOD-ENTITY-FROM-TAIL entirely. This is the only
    ;;    row whose :SYSTEM carries a value, and therefore the only one that can
    ;;    go red for that.
    ("(defmethod render ((x hop)) (helper x))"
     (:method "render" "method:src/graph/foo.lisp:render::hop"
      "src/graph/foo.lisp"
      ((:arguments ("x")) (:call-names ("helper")) (:end-line 1)
       (:file "src/graph/foo.lisp") (:generic-function "render")
       (:language :lisp) (:qualified-calls nil) (:qualifier nil) (:shadowed-definitions nil)
       (:signature nil)
       (:specializers ("hop")) (:start-line 1) (:system :graph)
       (:unresolved-calls nil)))
     ((helper x))
     "src/graph/foo.lisp"))
  "Source, expected fingerprint, expected METHOD-BODY, and the path to analyze
at when it is not the default -- one row per branch of the DEFMETHOD tail
grammar. The fingerprints and bodies were printed from the analyzer with ~S and
pasted, never hand-typed: id derivation renders an empty qualifier as an empty
segment (case a is render::hop, case e is render::), and a hand-typed guess at
that would be a guard over a guess.")

(test a-defmethod-produces-the-same-entity-it-always-has
  (dolist (row *defmethod-corpus*)
    (destructuring-bind (source fingerprint body &optional (path "sample.lisp")) row
      (declare (ignore body))
      (multiple-value-bind (g file) (analyze-source source path)
        (declare (ignore file))
        (let ((methods (entities-of-type g :method)))
          (is (= 1 (length methods)) "~a produced ~a methods" source
              (length methods))
          (is (equal fingerprint (method-fingerprint (first methods)))
              "~a~%  expected ~s~%  got      ~s"
              source fingerprint (method-fingerprint (first methods))))))))

(test a-defmethod-body-is-what-it-always-was
  ;; METHOD-BODY is extracted alongside the entity constructor and needs a
  ;; guard of its own: an entity can be right while the body handed to pass 2
  ;; is wrong, and then the :CALL-NAMES are wrong without anything else moving.
  ;; *PACKAGE* is bound rather than assumed, because READ-FROM-STRING interns
  ;; into whatever package the test runner happens to be in and the literals
  ;; below are read at compile time into this one.
  (let ((*package* (find-package :loom-analyzer-test)))
    (dolist (row *defmethod-corpus*)
      (destructuring-bind (source fingerprint body &optional path) row
        (declare (ignore fingerprint path))
        (is (equal body (loom-analyzer::method-body (read-from-string source)))
            "~a" source)))))

;;; ------------------------------------------------------------------
;;; Inline DEFGENERIC methods (ARCH-0010 R4, R6)
;;;
;;; A (:method ...) clause used to be discarded with the rest of a
;;; DEFGENERIC's options: no :METHOD entity, so no body walk, so no
;;; :CALL-NAMES, so no edge in either direction. game-server writes 247 of
;;; them and Loom two, which is why this was invisible here and expensive
;;; there.
;;; ------------------------------------------------------------------

(test an-inline-method-gets-its-own-range-and-the-interface-keeps-its
  ;; Both halves in one test deliberately. "The method got the right range" and
  ;; "the interface kept its own" are one fact, not two: the interface still
  ;; spans the bodies it now shares, which is fine because line ranges are
  ;; display-only, and the way to notice the method quietly taking the whole
  ;; form's range is to assert the two against each other.
  (multiple-value-bind (g file)
      (analyze-source "(defgeneric render (x)
  (:documentation \"d\")
  (:method ((x hop))
    x))")
    (declare (ignore file))
    (let ((method (find-by-name g :method "render"))
          (interface (find-by-name g :interface "render")))
      (is (not (null method)) "the clause mints a :METHOD entity at all")
      (is (eql 3 (getp method :start-line))
          "the clause's own line, not the DEFGENERIC's")
      (is (eql 4 (getp method :end-line)))
      (is (equal '("hop") (getp method :specializers)))
      (is (equal "render" (getp method :generic-function)))
      (is (not (null interface)) "and the interface is still there")
      (is (eql 1 (getp interface :start-line)))
      (is (eql 4 (getp interface :end-line))))))

(test two-clauses-differing-only-in-qualifier-are-two-entities
  ;; The natural key is (:file :name :qualifier :specializers). Asserting the
  ;; ids differ is what shows the qualifier reaching the key rather than only
  ;; the property table -- if it stopped at the property, these two would
  ;; collide on one id and the second assert would overwrite the first.
  (multiple-value-bind (g file)
      (analyze-source "(defgeneric render (x)
  (:method :around ((x hop)) x)
  (:method ((x hop)) x))")
    (declare (ignore file))
    (let ((methods (entities-of-type g :method)))
      (is (= 2 (length methods)))
      (is (equal '(:around nil)
                 (sort (mapcar (lambda (m) (getp m :qualifier)) methods)
                       #'string< :key #'princ-to-string)))
      (is (= 2 (length (remove-duplicates (mapcar #'id methods) :test #'equal)))
          "two entities, so two ids"))))

(test an-inline-methods-body-resolves-to-a-calls-edge
  ;; The end of the chain REQ-0012 asks for, and the one that returned nothing
  ;; before: a clause body's names only become edges if the clause became a
  ;; :METHOD entity with a body handed to pass 2. RESOLVE-CALLS walks :FUNCTION,
  ;; :METHOD and :TEST callers, so a name recorded on the :INTERFACE instead
  ;; would strand.
  (multiple-value-bind (g file)
      (analyze-source "(defun helper (x) x)
(defgeneric render (x)
  (:method ((x hop))
    (helper x)))")
    (declare (ignore file))
    (apply-transaction g (resolve-calls g))
    (let ((method (find-by-name g :method "render"))
          (helper (find-by-name g :function "helper")))
      (is (not (null method)))
      (is (member (id helper)
                  (mapcar #'to-id (relationships-from g (id method) :rel-type :calls))
                  :test #'equal)
          "the inline method calls the function defined above it"))))

(test a-defgeneric-with-no-inline-clause-produces-only-its-interface
  ;; The regression guard for the majority case -- five of Loom's seven
  ;; DEFGENERIC forms and most of game-server's. If this moves, the rename
  ;; changed what a plain DEFGENERIC means, which it must not.
  (multiple-value-bind (g file)
      (analyze-source "(defgeneric render (x y))")
    (declare (ignore file))
    (is (null (entities-of-type g :method)))
    (let ((interface (find-by-name g :interface "render")))
      (is (not (null interface)))
      (is (equal '("x" "y") (getp interface :members))))))

(test an-inline-method-falls-back-to-the-whole-forms-range
  ;; ARCH-0010 R4's fallback, which ARCH-0013 R7 keeps as the declared answer
  ;; while removing one of its two entrances. The mismatch entrance is gone:
  ;; ELEMENT-SPANS built a parallel sequence to zip against the form's own
  ;; elements and had to compare lengths before trusting it, where FORM-RANGE
  ;; asks the clause cons itself and cannot return a neighbour's range. What is
  ;; left is the caller that has no READING at all, which is why the keyword is
  ;; a keyword -- a caller with no reading is not made to lie about one.
  ;;
  ;; The positive case is asserted beside it, because a fallback test alone
  ;; would pass just as well if FORM-RANGE never found anything.
  (let* ((source "(defgeneric render (x)
  (:method ((x hop)) x))")
         (reading (loom-analyzer::read-source source))
         (form (first (first (loom-analyzer::reading-forms reading)))))
    (flet ((method-range (pairs)
             (let ((method (car (second pairs))))
               (list (getp method :start-line) (getp method :end-line)))))
      (is (equal '(10 20)
                 (method-range (loom-analyzer::generic-definition-entities
                                form 10 20 "sample.lisp" :test)))
          "no reading at all: nothing to ask, so the form's own range")
      (is (equal '(2 2)
                 (method-range (loom-analyzer::generic-definition-entities
                                form 10 20 "sample.lisp" :test
                                :reading reading)))
          "and with one, the clause's own line rather than the form's 10-20"))))

(test an-inline-method-and-a-standalone-defmethod-collide-in-one-file
  ;; ARCH-0010 R4's disclosed edge: the natural key is (:file :name :qualifier
  ;; :specializers), and nothing about it distinguishes a clause from a
  ;; DEFMETHOD -- so a standalone DEFMETHOD and an inline (:method ...) clause
  ;; on the same generic, same qualifier, same specializers, in the same file,
  ;; resolve to one id. The coder found two real instances of it in
  ;; game-server (mpackage/obj-types.lisp ADD-DEFN, mpackage/object.lisp
  ;; COMPUTED-ID-P).
  ;;
  ;; What this measures changed with PLAN-0012, though every assertion below
  ;; stands unaltered. It used to measure the *graph* absorbing two
  ;; ASSERT-ENTITY-OPs, later-wins; ARCH-0012 R1 now supersedes the earlier
  ;; definition inside ANALYZE-FILE, so the graph is handed one assert and has
  ;; nothing to absorb. Same one entity, same :CALL-NAMES -- which is why this
  ;; test is also the check that supersession picked the right survivor. The
  ;; LAST definition in source order is the one CL leaves in effect, and if
  ;; that ever inverted, :call-names would read ("first-callee").
  ;;
  ;; FIRST-CALLEE and SECOND-CALLEE are deliberately undefined anywhere in this
  ;; source, so each becomes a :CALL-NAMES property rather than a resolved
  ;; local :CALLS edge (see the next test for what happens when the callees
  ;; ARE local) -- this isolates the property-collision half of R4's claim.
  ;; Without ARCH-0010, this source would still produce exactly one :METHOD
  ;; entity -- the standalone DEFMETHOD, since the inline clause was discarded
  ;; outright -- so :CALL-NAMES would be ("first-callee"), not
  ;; ("second-callee"); that is what makes this a test of the collision rather
  ;; than a restatement of "one method exists".
  (multiple-value-bind (g file)
      (analyze-source "(defmethod render ((x hop)) (first-callee x))
(defgeneric render (x)
  (:method ((x hop)) (second-callee x)))")
    (declare (ignore file))
    (let ((methods (entities-of-type g :method)))
      (is (= 1 (length methods))
          "one id, so one entity survives -- the collision, not two distinct
methods")
      (is (equal '("second-callee") (getp (first methods) :call-names))
          "the later definition in source order -- the inline clause -- is the
one the graph kept; the standalone DEFMETHOD's :call-names are gone entirely,
not merged"))))

(test a-collided-methods-calls-edges-are-a-union-not-a-replacement
  ;; The name is kept, and it is now the opposite of what it says. This test
  ;; was written to record BUG-0012 as it stood: the surviving :METHOD's own
  ;; properties were the inline clause's, but its outgoing :CALLS edges were
  ;; the union of both definitions' bodies, because ASSERT-EDGE bakes FROM-ID
  ;; in at op-construction time and both colliding definitions derive one id,
  ;; so the graph -- which replaces entities by key but keys a relationship on
  ;; its endpoints -- had two distinct edges and nothing to choose between
  ;; them. It asserted FIRST-CALLEE PRESENT, deliberately, so a fix would have
  ;; something to turn red (CON-0003).
  ;;
  ;; PLAN-0012 inverted it. ARCH-0012 R1 supersedes the standalone DEFMETHOD
  ;; inside ANALYZE-FILE, between pass 1 and pass 2, so its body is never
  ;; walked and no edge is ever emitted for it. FIRST-CALLEE is now absent,
  ;; and it is absent because the op was never built -- not because anything
  ;; retracted it.
  (multiple-value-bind (g file)
      (analyze-source "(defun first-callee (x) x)
(defun second-callee (x) x)
(defmethod render ((x hop)) (first-callee x))
(defgeneric render (x)
  (:method ((x hop)) (second-callee x)))")
    (declare (ignore file))
    (let* ((methods (entities-of-type g :method))
           (method (first methods))
           (callees (mapcar #'to-id (relationships-from g (id method) :rel-type :calls))))
      (is (= 1 (length methods)) "still one surviving entity")
      (is (member (id (find-by-name g :function "second-callee")) callees :test #'equal)
          "the surviving definition's own call is present, as before")
      (is (not (member (id (find-by-name g :function "first-callee")) callees
                       :test #'equal))
          "BUG-0012 fixed: the superseded definition contributes no edge, so
the entity's edges and its properties now describe the same body"))))

(test two-defuns-of-one-name-leave-only-the-later-ones-calls
  ;; ARCH-0012 R1 is not method-specific: the key is (:file :name) for a
  ;; :FUNCTION too, so a redefined DEFUN collides exactly the way the colliding
  ;; methods above do. Only the mechanism differs -- CL warns about this one at
  ;; load time, which is why nobody had noticed it in the index.
  ;;
  ;; Two distinct defects before supersession, both from walking the dead body:
  ;;
  ;;   HELPER -- an edge target -> helper attributed to a body the file does
  ;;   not define once loaded. The two-definition union of BUG-0012.
  ;;
  ;;   TARGET -- a self-edge. The dead body's call to TARGET resolves through
  ;;   LOCAL-FUNCTIONS to the *survivor* (ASSOC finds the most recently pushed
  ;;   entry), which is a different object from the caller, so the
  ;;   (not (eq callee caller)) recursion guard does not fire -- and the edge
  ;;   it emits runs from the one derived id to itself.
  ;;
  ;; The :CALL-NAMES assertion is a guard rather than evidence: ABSORB-ENTITY
  ;; replaced properties wholesale, so the survivor's empty list already won
  ;; before this change. It is here because after supersession the property is
  ;; right by construction instead of by absorption, and that is the property
  ;; a future analyzer's contract has to keep (ARCH-0012 R3).
  (multiple-value-bind (g file)
      (analyze-source "(defun helper (x) x)
(defun target (x) (helper x) (target x) (only-in-the-dead-body x))
(defun target (x) x)")
    (declare (ignore file))
    (let ((targets (entities-of-type g :function)))
      (is (= 2 (length targets)) "helper and one target, not two targets"))
    (let* ((target (find-by-name g :function "target"))
           (callees (mapcar #'to-id (relationships-from g (id target)
                                                        :rel-type :calls))))
      (is (eql 3 (getp target :start-line))
          "the surviving definition is the last in source order")
      (is (not (member (id (find-by-name g :function "helper")) callees
                       :test #'equal))
          "the dead body's call to HELPER is not attributed to the survivor")
      (is (not (member (id target) callees :test #'equal))
          "and the dead body's call to TARGET is not a self-edge")
      (is (null (getp target :call-names))
          "and no foreign name reached the survivor from the dead body"))))

(test a-definition-that-shadowed-nothing-has-no-shadowed-definitions
  ;; ARCH-0012 R2 turns on absent-versus-empty: RULE-0006 reports every carrier
  ;; of the property, so writing an empty list on the ordinary case would make
  ;; every definition in every tree a finding.
  (multiple-value-bind (g file) (analyze-source "(defun ordinary (x) x)")
    (declare (ignore file))
    (is (null (getp (find-by-name g :function "ordinary") :shadowed-definitions))
        "nothing collided, so the property is absent")))

(test a-survivor-records-the-range-of-what-it-shadowed
  ;; The same source as A-COLLIDED-METHODS-CALLS-EDGES-ARE-A-UNION-NOT-A-
  ;; REPLACEMENT, asked the other question. That test shows the dead body's
  ;; edge is gone; this one shows the dead body is not thereby erased -- the
  ;; standalone DEFMETHOD on line 3 is still a recorded fact, as a line range
  ;; on the definition that replaced it (CON-0001).
  (multiple-value-bind (g file)
      (analyze-source "(defun first-callee (x) x)
(defun second-callee (x) x)
(defmethod render ((x hop)) (first-callee x))
(defgeneric render (x)
  (:method ((x hop)) (second-callee x)))")
    (declare (ignore file))
    (is (equal '("3-3")
               (getp (find-by-name g :method "render") :shadowed-definitions))
        "the superseded DEFMETHOD's own extent, not the survivor's")))

(test two-classes-declaring-one-accessor-are-not-a-shadowing
  ;; The CON-0003 anchor for the carve-out PLAN-0012 adds to ARCH-0012 R2, and
  ;; the reason RULE-0006 reports nothing on Loom: two classes each declaring
  ;; :ACCESSOR THING-NAME is one generic function with two methods in CL, not
  ;; a definition shadowing another, and both bodies are live. Loom's index
  ;; still collapses them to one :INTERFACE -- asserted below, so this cannot
  ;; pass by there being no collision to carve out -- but nothing died.
  ;;
  ;; The second half is what makes the predicate an AND rather than an OR. A
  ;; hand-written DEFGENERIC colliding with a generated accessor name IS a
  ;; real shadowing: one of the two is dead. Recorded blanketly, the first
  ;; assertion fails; carved out too broadly, the second does.
  (multiple-value-bind (g file)
      (analyze-source "(defclass a () ((x :accessor thing-name)))
(defclass b () ((y :accessor thing-name)))")
    (declare (ignore file))
    (let ((interfaces (entities-of-type g :interface)))
      (is (= 1 (length interfaces)) "the two accessor names do collide on one id")
      (is (null (getp (first interfaces) :shadowed-definitions))
          "but a duplicated accessor name is CL semantics, not dead code")))
  (multiple-value-bind (g file)
      (analyze-source "(defclass a () ((x :accessor thing-name)))
(defgeneric thing-name (obj))")
    (declare (ignore file))
    (is (equal '("1-1")
               (getp (find-by-name g :interface "thing-name")
                     :shadowed-definitions))
        "one name written by hand is enough to make the shadowing real")))

;;; ------------------------------------------------------------------
;;; Macro template inspection and the registry (ARCH-0002 R1, R3)
;;; ------------------------------------------------------------------

(test a-macro-that-plainly-defines-a-function-says-so
  (multiple-value-bind (g file)
      (analyze-source "(defmacro struct-simplefn (name description &body body)
  `(defun ,name () ,description ,@body))")
    (declare (ignore file))
    (let ((macro (find-by-name g :function "struct-simplefn")))
      (is (not (null macro)))
      (is (eq :function (getp macro :generator-entity-type)))
      (is (eql 1 (getp macro :generator-name-index))
          "argument 1 names the function, counting the operator as 0")
      (is (eql 3 (getp macro :generator-body-index))
          "and the body begins at 3, because &body consumes no argument")
      (is (null (getp macro :definer-status))
          "a template that reads cleanly is not an unhandled definer"))))

(test a-macro-whose-defined-name-is-computed-is-reported-not-guessed
  ;; DEFENTITY's shape: the DEFCLASS is real, but the name is a LET-bound
  ;; variable, so it exists only once the expander runs. This is the near-miss
  ;; REQ-0003 draws its line at, and CON-0001 says report it rather than
  ;; approximate it. It is also nested two forms deep inside the backquote,
  ;; which is why the template is walked rather than matched at the top.
  (multiple-value-bind (g file)
      (analyze-source "(defmacro defentity (key &key properties)
  (let ((class-name (entity-class-name key)))
    `(progn (defclass ,class-name (entity) ()) ,properties)))")
    (declare (ignore file))
    (let ((macro (find-by-name g :function "defentity")))
      (is (eq :unhandled (getp macro :definer-status)))
      (is (null (getp macro :generator-entity-type))
          "and nothing is recorded that would let resolution mint from it"))))

(test a-wrapper-macro-gets-no-generator-properties-at-all
  ;; console.lisp's DEFINE-COMMAND expands to a PROGN around a SETF and
  ;; defines nothing. If this comes out flagged, the template test is matching
  ;; too loosely, and every WITH-LOCK in a tree lands in a count that exists
  ;; to be read and acted on.
  (multiple-value-bind (g file)
      (analyze-source "(defmacro define-command (name args usage &body body)
  `(progn (setf *commands* (cons ,usage *commands*))
          (lambda ,args ,@body)))")
    (declare (ignore file))
    (let ((macro (find-by-name g :function "define-command")))
      (is (not (null macro)) "still indexed as a macro")
      (is (null (getp macro :definer-status)))
      (is (null (getp macro :generator-entity-type))))))

(test registering-a-macro-generator-replaces-rather-than-duplicates
  ;; REGISTER-ANALYZER and REGISTER-DOCUMENT-TYPE both replace, because in a
  ;; live image the registration form runs again every time the file is
  ;; recompiled. A registry that accumulated would turn one entry into
  ;; several, and several matches is what makes a pass leave a call site alone.
  (let ((*macro-generators* (make-hash-table :test #'equal)))
    (register-macro-generator "test" :package "fiveam" :entity-type :test
                                     :name-index 1 :framework :fiveam)
    (register-macro-generator "test" :package "fiveam" :entity-type :test
                                     :name-index 2 :framework :fiveam)
    (is (= 1 (length (macro-generators-for "test"))))
    (is (eql 2 (getf (first (macro-generators-for "TEST")) :name-index))
        "the later registration wins, and the lookup is case-insensitive")
    (register-macro-generator "test" :package "other" :entity-type :function
                                     :name-index 1)
    (is (= 2 (length (macro-generators-for "test")))
        "a different package is a different entry, because two packages may
name a macro identically and a pass must be able to see the ambiguity")))

(test fiveam-ships-registered
  ;; The acceptance instrument for the whole of ARCH-0002: TEST and DEF-SUITE
  ;; are the most common macro calls in this tree, and the :TEST entity type
  ;; has held zero facts until they were declared here.
  (let ((entry (first (macro-generators-for "test"))))
    (is (not (null entry)))
    (is (eq :test (getf entry :entity-type)))
    (is (eq :fiveam (getf entry :framework)))
    (is (eql 1 (getf entry :name-index))))
  (let ((entry (first (macro-generators-for "def-suite"))))
    (is (not (null entry)) "registered so it is never reported unhandled")
    (is (null (getf entry :entity-type))
        "a suite is not a test, and the ontology declares no :suite type")))

;;; ------------------------------------------------------------------
;;; Determinism (SS12.4)
;;;
;;; "Re-analyzing an unchanged file produces an operation set that applies as
;;; a no-op, which is what verifies the upsert natural keys of SS4.4." The
;;; analyzer is stateless and mints fresh uuids every pass, so this only holds
;;; if the natural keys are doing their job -- both for the entities and for
;;; the edges, whose endpoints have to be remapped onto the surviving ids.
;;; ------------------------------------------------------------------

(test re-analyzing-an-unchanged-file-applies-as-a-no-op
  (let ((g (make-graph)))
    (apply-transaction g (fixture-ops))
    (let ((entities (length (all-entities g)))
          (edges    (length (all-relationships g)))
          (ids      (sort (mapcar #'id (all-entities g)) #'string<)))
      (apply-transaction g (fixture-ops))
      (is (= entities (length (all-entities g)))
          "a second pass must upsert, not duplicate")
      (is (= edges (length (all-relationships g)))
          "edges must be remapped onto the surviving entities, not re-inserted")
      (is (equal ids (sort (mapcar #'id (all-entities g)) #'string<))
          "ids are stable across re-analysis, so nothing pointing at them breaks"))))

;;; ------------------------------------------------------------------
;;; System identity (ARCH-0009 R4, R5)
;;;
;;; Reached as LOOM-ANALYZER::, not through the export list: these two are
;;; Lisp specifics a Java analyzer has no use for, and R2 asks only for
;;; DEFAULT-SYSTEM-FOR-PATH to be exported.
;;; ------------------------------------------------------------------

(defun normalized-in-package (source)
  "The :system keyword SOURCE, one IN-PACKAGE form, names."
  (loom-analyzer::normalize-system-name
   (loom-analyzer::in-package-argument-name (read-from-string source))))

(test every-in-package-designator-folds-to-one-system-keyword
  ;; A keyword, a string literal and an escaped mixed-case symbol are three
  ;; spellings of one package, so they have to be one :system value or a rule
  ;; naming loom-graph would match some of a file's definitions and not others.
  (is (eq :loom-graph (normalized-in-package "(in-package :loom-graph)")))
  (is (eq :loom-graph (normalized-in-package "(in-package \"loom-graph\")")))
  (is (eq :loom-graph (normalized-in-package "(in-package :|Loom-Graph|)"))))

(test a-slash-structured-package-name-is-one-token
  ;; ~/lisp/game-server's live convention, verified at a REPL in ARCH-0009:
  ;; `/` is an ordinary constituent character to the reader, not a macro
  ;; character, so nothing here has to know the name is hierarchical.
  (is (eq :game/game (normalized-in-package "(in-package :game/game)")))
  (is (eq :game/game (loom-analyzer::normalize-system-name "game/game"))))

(test an-absent-package-designator-normalizes-to-nil
  ;; NIL is what the caller tests before overwriting CURRENT-SYSTEM, so an
  ;; IN-PACKAGE with nothing readable in it must leave the path default alone
  ;; rather than replace it with a keyword named "".
  (is (null (loom-analyzer::normalize-system-name nil)))
  (is (null (loom-analyzer::normalize-system-name "")))
  (is (null (loom-analyzer::in-package-argument-name (read-from-string "(in-package)")))))

(test the-analyzer-and-the-rule-reader-fold-case-identically
  ;; ARCH-0009 risk 7, stated as an assertion. NORMALIZE-SYSTEM-NAME produces
  ;; one side of every :no-edge comparison and yaml-analyzer's AS-KEYWORD
  ;; produces the other, from a rule's from-system: scalar. If a later edit
  ;; moves one fold, `check` goes quiet rather than wrong -- which reads as
  ;; success and is the failure BUG-0006 existed to close.
  (is (eq (loom-analyzer::as-keyword "loom-graph")
          (loom-analyzer::normalize-system-name "loom-graph")))
  (is (eq (loom-analyzer::as-keyword "loom-graph")
          (normalized-in-package "(in-package :loom-graph)"))))

(test a-definition-carries-the-package-its-file-declared
  (multiple-value-bind (g file) (analyze-source "(in-package :loom-graph)
(defun f (x) x)" "anywhere/at/all.lisp")
    (declare (ignore file))
    (is (eq :loom-graph (getp (find-by-name g :function "f") :system))
        "the IN-PACKAGE form is the fact, not the path it was found under")))

(test a-definition-with-no-in-package-falls-through-to-the-path
  ;; The seed value, unmodified: an analyzer with nothing stronger than a path
  ;; is exactly what DEFAULT-SYSTEM-FOR-PATH is for, and a Lisp file that
  ;; declares no package is that analyzer for the length of the file.
  (multiple-value-bind (g file) (analyze-source "(defun f (x) x)"
                                                "src/graph/query.lisp")
    (declare (ignore file))
    (is (eq :graph (getp (find-by-name g :function "f") :system)))))

(test each-definition-takes-the-in-package-lexically-nearest-above-it
  ;; Literal CL semantics, and not hypothetical: ~/lisp/game-server's
  ;; server/content.lisp switches package mid-file at line 179, so every
  ;; definition after it really does belong to the second package. Nothing in
  ;; Loom's own tree has two IN-PACKAGE forms, so without this test the walk's
  ;; per-entity granularity is uncovered.
  (multiple-value-bind (g file) (analyze-source "(in-package :server/content)
(defun early (x) x)
(in-package :media.service)
(defun late (x) x)" "server/content.lisp")
    (declare (ignore file))
    (is (eq :server/content (getp (find-by-name g :function "early") :system)))
    (is (eq :media.service (getp (find-by-name g :function "late") :system)))))

(test the-file-entity-takes-the-last-in-package-in-the-file
  ;; The documented approximation, asserted so a later change cannot quietly
  ;; make it per-entity and leave ARCH-0009's disclosure stale. One :FILE
  ;; entity cannot carry two packages; this is which one it carries.
  (multiple-value-bind (g file) (analyze-source "(in-package :server/content)
(defun early (x) x)
(in-package :media.service)
(defun late (x) x)" "server/content.lisp")
    (declare (ignore g))
    (is (eq :media.service (getp file :system)))))

(test a-class-and-its-slot-accessors-carry-the-package
  ;; The CLASS-DEFINITION-ENTITIES path -- an intermediate builder ARCH-0009's
  ;; CONSEQUENCES paragraph does not name, which is why it is covered on its
  ;; own rather than through the DEFUN case above.
  (multiple-value-bind (g file)
      (analyze-source "(in-package :loom-ontology)
(defclass widget () ((size :accessor widget-size)))" "anywhere.lisp")
    (declare (ignore file))
    (is (eq :loom-ontology (getp (find-by-name g :class "widget") :system)))
    (is (eq :loom-ontology (getp (find-by-name g :interface "widget-size") :system)))))

(test a-struct-a-generic-and-a-method-carry-the-package
  ;; STRUCT-DEFINITION-ENTITIES, GENERIC-DEFINITION-ENTITY and
  ;; METHOD-DEFINITION-ENTITY, the other three intermediate builders.
  (multiple-value-bind (g file)
      (analyze-source "(in-package :loom-ontology)
(defstruct hop entity-id)
(defgeneric render (x))
(defmethod render ((x hop)) x)" "anywhere.lisp")
    (declare (ignore file))
    (is (eq :loom-ontology (getp (find-by-name g :class "hop") :system)))
    (is (eq :loom-ontology (getp (find-by-name g :function "hop-entity-id") :system))
        "a DEFSTRUCT accessor is generated, and generated is not unplaceable")
    (is (eq :loom-ontology (getp (find-by-name g :interface "render") :system)))
    (is (eq :loom-ontology (getp (find-by-name g :method "render") :system)))))

(test a-real-file-with-no-in-package-gets-its-path-segment-throughout
  ;; test/fixtures/sample.lisp declares no package, so the seed default is what
  ;; every entity it produces carries -- the path rule exercised against a real
  ;; file rather than an inline string.
  (multiple-value-bind (g file) (analyze-fixture)
    (is (eq :test (getp file :system)))
    (dolist (type '(:function :variable))
      (dolist (e (entities-of-type g type))
        (is (eq :test (getp e :system)) "~a carries ~s" (name e) (getp e :system))))))

;;; ------------------------------------------------------------------
;;; Dispatch (SS8.1)
;;; ------------------------------------------------------------------

(test lisp-analyzer-claims-lisp-source-only
  (let ((a (make-instance 'lisp-analyzer)))
    (is-true  (analyzer-handles-p a "src/graph/transaction.lisp"))
    (is-true  (analyzer-handles-p a "src/graph/loom-graph.asd"))
    (is-false (analyzer-handles-p a "src/ui/DrawingTool.tsx"))
    (is-false (analyzer-handles-p a "README.md"))
    (is-false (analyzer-handles-p a "Makefile"))))

(test find-analyzer-routes-a-lisp-file-to-the-lisp-analyzer
  (is (typep (find-analyzer "src/ontology/root-ontology.lisp") 'lisp-analyzer))
  (is (null (find-analyzer "src/ui/DrawingTool.tsx"))
      "no TypeScript analyzer is registered yet, and NIL is how a caller
sweeping a mixed tree learns to skip the file"))
