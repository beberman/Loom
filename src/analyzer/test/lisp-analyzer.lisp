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

(test an-unreadable-file-is-indexed-as-a-known-unknown
  ;; SS9.3 / SS3.3: a file that could not be parsed is marked, not omitted --
  ;; and the condition must not escape to take the watcher thread down.
  (let* ((ops (analyze-file (make-instance 'lisp-analyzer)
                            "broken.lisp"
                            "(defun ok () 1)~%(defun broken (" ; unbalanced
                            "ws-test"))
         (g (make-graph)))
    (apply-transaction g ops)
    (let ((file (find-by-name g :file "broken.lisp")))
      (is (not (null file)) "the file is asserted even though it did not parse")
      (is-true (getp file :analysis-failed-p))
      (is (stringp (getp file :analysis-error)))
      (is (null (entities-of-type g :function))
          "and nothing is guessed at from a file that could not be read"))))

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
  ;; non-zero offset, which is where the two conventions start to differ.
  ;; Reached into with :: deliberately. The walk is not protocol -- SS8.1 makes
  ;; ANALYZE-FILE the only coupling an analyzer has -- so this stays a private
  ;; function that a test may name rather than something the package exports.
  (let* ((content ";;;; a header comment
(defparameter *a* 1)

(defun one () 1)

(defun two () (one))
")
         (forms (loom-analyzer::read-forms-with-spans content)))
    (is (= 3 (length forms)) "every top-level form, not just the ones before
the first miscounted span")
    (is (equal '("defparameter" "defun" "defun")
               (mapcar (lambda (spec) (loom-analyzer::token-name (first (first spec))))
                       forms)))
    ;; Four elements, not three: the fourth is the character offset of the
    ;; form's first character, which ELEMENT-SPANS seeks to when it re-reads a
    ;; DEFGENERIC's clauses one at a time (ARCH-0010 R1).
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

;;; ------------------------------------------------------------------
;;; Per-element source spans (ARCH-0010 R2)
;;;
;;; The reader hands out positions for top-level forms and nothing else, so a
;;; DEFGENERIC's inline (:method ...) clause has no range of its own until one
;;; is recovered by re-reading the form's elements one at a time. That re-read
;;; is the piece of this machinery most likely to be wrong in a way nothing
;;; notices: a mistake produces wrong line numbers and signals nothing. Hence
;;; the spans are asserted here, standalone, against sources small enough to
;;; count lines in by eye, before anything consumes them.
;;;
;;; Reached into with :: for the reason the READ-FORMS-WITH-SPANS test above
;;; gives -- SS8.1 makes ANALYZE-FILE an analyzer's only coupling, so this is
;;; a private function a test may name, not something the package exports.
;;; ------------------------------------------------------------------

(defparameter *span-fixture* "(defgeneric g (x)
  (:documentation \"d\")
  (:method :around ((x foo))
    (call-next-method))
  (:method ((primary (eql :oneof)) &key k)
    (helper primary k)))"
  "Six elements over six lines: the head, the name, the lambda list, an option
clause and two method clauses, one qualified and one with an EQL specializer.")

(test element-spans-of-a-one-line-form-are-all-that-line
  (is (equal '((1 1) (1 1) (1 1))
             (mapcar #'rest (loom-analyzer::element-spans "(defgeneric g (x))" 0)))
      "three elements -- defgeneric, g and the lambda list"))

(test element-spans-give-each-clause-its-own-range-not-the-forms
  ;; The assertion the whole design rests on. If these came back as six copies
  ;; of 1-6 the machinery would still "work" -- every inline method would just
  ;; point at its DEFGENERIC's first line, which is the fallback ARCH-0010
  ;; keeps for when the re-read fails, silently standing in for the real thing.
  (let ((spans (loom-analyzer::element-spans *span-fixture* 0)))
    (is (= 6 (length spans)))
    (is (equal '((1 1) (1 1) (1 1) (2 2) (3 4) (5 6))
               (mapcar #'rest spans)))))

(test element-spans-align-one-to-one-with-the-forms-own-elements
  ;; The invariant the clause walk zips against. Tested here, where it is one
  ;; comparison, rather than discovered downstream as a clause wearing its
  ;; neighbour's line numbers.
  (let* ((form (first (first (loom-analyzer::read-forms-with-spans *span-fixture*))))
         (spans (loom-analyzer::element-spans *span-fixture* 0)))
    (is (= (length form) (length spans)))))

(test a-clause-head-read-a-second-time-is-eq-to-the-keyword
  ;; Why the clause walk may compare heads across two separate reads at all:
  ;; a keyword interns in KEYWORD whatever *PACKAGE* is, so :method survives
  ;; the throwaway package both reads use. Nothing else does -- an ordinary
  ;; symbol comes back interned in a package that is deleted on the way out --
  ;; which is why every other comparison goes through TOKEN-NAME.
  (let ((spans (loom-analyzer::element-spans *span-fixture* 0)))
    (is (eq :method (first (first (fifth spans)))))
    (is (eq :method (first (first (sixth spans)))))))

(test a-foreign-package-prefix-inside-a-clause-still-yields-spans
  ;; The second reader must establish the same environment as the first, or it
  ;; signals on exactly the foreign source INTERN-FOREIGN-SYMBOL-LOCALLY
  ;; exists for -- and the damage shows up only on someone else's repository,
  ;; as every inline method in it quietly taking the whole-form range.
  (let ((spans (loom-analyzer::element-spans
                "(defgeneric g (x)
  (:method ((x foo)) (utils:parse-config x)))"
                0)))
    (is (= 4 (length spans)))
    (is (equal '(2 2) (rest (fourth spans))))))

(test element-spans-refuses-rather-than-guesses
  ;; Three ways of being asked for spans that do not exist. NIL from all three,
  ;; because the caller's fallback -- the whole form's range on every clause --
  ;; is a wider truth that contains the clause, where a span read out of the
  ;; middle of a token would be a fabricated one (CON-0001).
  (is (null (loom-analyzer::element-spans "(defgeneric g (x))" 1))
      "an offset naming an atom, not a list")
  (is (null (loom-analyzer::element-spans "(defgeneric g (x))" 99))
      "an offset past the end of the content")
  (is (null (loom-analyzer::element-spans "(defgeneric g (x" 0))
      "an element that runs off the end of the content"))

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
       (:generic-function "render") (:language :lisp) (:qualifier nil)
       (:signature nil) (:specializers ("hop")) (:start-line 1) (:system nil)
       (:unresolved-calls nil)))
     (x))
    ;; b  a qualifier, which is a natural-key component: it must survive into
    ;;    the :QUALIFIER property AND into the id's third segment
    ("(defmethod render :around ((x hop)) x)"
     (:method "render" "method:sample.lisp:render:around:hop" "sample.lisp"
      ((:arguments ("x")) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualifier :around)
       (:signature nil) (:specializers ("hop")) (:start-line 1) (:system nil)
       (:unresolved-calls nil)))
     (x))
    ;; c  EQL specializer, rendered rather than resolved
    ("(defmethod render ((x (eql :oneof))) x)"
     (:method "render" "method:sample.lisp:render::(eql oneof)" "sample.lisp"
      ((:arguments ("x")) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualifier nil)
       (:signature nil) (:specializers ("(eql oneof)")) (:start-line 1)
       (:system nil) (:unresolved-calls nil)))
     (x))
    ;; d  a (setf f) name, which DEFINITION-NAME renders rather than flattens
    ("(defmethod (setf render) (v (x hop)) v)"
     (:method "(setf render)" "method:sample.lisp:(setf render)::t,hop"
      "sample.lisp"
      ((:arguments ("v" "x")) (:call-names nil) (:end-line 1)
       (:file "sample.lisp") (:generic-function "(setf render)")
       (:language :lisp) (:qualifier nil) (:signature nil)
       (:specializers ("t" "hop")) (:start-line 1) (:system nil)
       (:unresolved-calls nil)))
     (v))
    ;; e  an empty lambda list. NIL is a symbol, so a qualifier test written
    ;;    without the NIL guard reads () as a qualifier, loses the lambda list
    ;;    and mints an entity with the body where its arguments belong.
    ("(defmethod render () 1)"
     (:method "render" "method:sample.lisp:render::" "sample.lisp"
      ((:arguments nil) (:call-names nil) (:end-line 1) (:file "sample.lisp")
       (:generic-function "render") (:language :lisp) (:qualifier nil)
       (:signature nil) (:specializers nil) (:start-line 1) (:system nil)
       (:unresolved-calls nil)))
     (1))
    ;; f  an & marker stops the specializer walk but not the argument list
    ("(defmethod render ((x hop) &rest args) args)"
     (:method "render" "method:sample.lisp:render::hop" "sample.lisp"
      ((:arguments ("x" "&rest" "args")) (:call-names nil) (:end-line 1)
       (:file "sample.lisp") (:generic-function "render") (:language :lisp)
       (:qualifier nil) (:signature nil) (:specializers ("hop"))
       (:start-line 1) (:system nil) (:unresolved-calls nil)))
     (args))
    ;; g  wholly unspecialized, and the only entry with a call in its body
    ("(defmethod render (a b) (helper a b))"
     (:method "render" "method:sample.lisp:render::t,t" "sample.lisp"
      ((:arguments ("a" "b")) (:call-names ("helper")) (:end-line 1)
       (:file "sample.lisp") (:generic-function "render") (:language :lisp)
       (:qualifier nil) (:signature nil) (:specializers ("t" "t"))
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
       (:language :lisp) (:qualifier nil) (:signature nil)
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
  ;; Two calls, because the fallback has two entrances and only one of them is
  ;; "no spans". A caller with contents whose element count disagrees with the
  ;; form's has spans that are real and misaligned, and using them would give a
  ;; clause its neighbour's line numbers -- worse than a range that is merely
  ;; wide. Exercised as a case rather than left as an untested safety net.
  ;; The second form has five elements where the DEFGENERIC has four, which is
  ;; what makes the second call a mismatch rather than a silent misattribution
  ;; -- the length comparison is the whole of the alignment check.
  (let* ((source "(defgeneric render (x)
  (:method ((x hop)) x))
(defun elsewhere (a) 1 2)")
         (form (first (first (loom-analyzer::read-forms-with-spans source))))
         (other-offset (fourth (second (loom-analyzer::read-forms-with-spans source)))))
    (flet ((method-range (pairs)
             (let ((method (car (second pairs))))
               (list (getp method :start-line) (getp method :end-line)))))
      (is (equal '(10 20)
                 (method-range (loom-analyzer::generic-definition-entities
                                form 10 20 "sample.lisp" :test)))
          "no contents at all: nothing to re-read, so the form's own range")
      (is (equal '(10 20)
                 (method-range (loom-analyzer::generic-definition-entities
                                form 10 20 "sample.lisp" :test
                                :contents source
                                :start-offset other-offset)))
          "spans of a different form in the same string: real, and misaligned"))))

(test an-inline-method-and-a-standalone-defmethod-collide-in-one-file
  ;; ARCH-0010 R4's disclosed, not fixed, edge: the natural key is (:file :name
  ;; :qualifier :specializers), and nothing about it distinguishes a clause
  ;; from a DEFMETHOD -- so a standalone DEFMETHOD and an inline (:method ...)
  ;; clause on the same generic, same qualifier, same specializers, in the same
  ;; file, resolve to one id. Both are ASSERT-ENTITY-OP; the graph applies them
  ;; in source order, so whichever definition sits later in the file overwrites
  ;; the other's properties entirely -- not merged, replaced. This mirrors CL's
  ;; own load-order redefinition semantics, and the coder found two real
  ;; instances of it in game-server (mpackage/obj-types.lisp ADD-DEFN,
  ;; mpackage/object.lisp COMPUTED-ID-P).
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
  ;; A consequence of R4's collision that ARCH-0010's text does not name:
  ;; "the later assert wins" is true of the surviving entity's OWN properties
  ;; (the test above), but it is NOT true of the :CALLS edges a *local* callee
  ;; produces. ASSERT-EDGE bakes FROM-ID in at op-construction time (ID FROM),
  ;; before the transaction runs, so an edge from the overwritten (earlier)
  ;; definition and an edge from the surviving (later) definition carry the
  ;; identical from-id string once the two definitions collide -- and the
  ;; graph does not deduplicate or replace relationships the way it replaces
  ;; entities. Both edges land on the one surviving id. The result: the single
  ;; :METHOD entity that ends up representing only the inline clause's body
  ;; (per the test above) is shown as calling FIRST-CALLEE too, a call no
  ;; queryable definition of RENDER actually makes -- `impact render` would
  ;; report a call site that does not exist in the surviving source. Filed as
  ;; BUG-0012; this test documents the current, undesirable behaviour so a fix
  ;; has something to turn red.
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
          "the surviving definition's own call is present, as expected")
      (is (member (id (find-by-name g :function "first-callee")) callees :test #'equal)
          "BUG-0012: the OVERWRITTEN definition's call survives as an edge on
an entity whose properties no longer mention it at all -- a call attributed to
a body that, from every other query, does not exist"))))

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
