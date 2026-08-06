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
  (let ((forms (loom-analyzer::read-forms-with-spans ";;;; a header comment
(defparameter *a* 1)

(defun one () 1)

(defun two () (one))
")))
    (is (= 3 (length forms)) "every top-level form, not just the ones before
the first miscounted span")
    (is (equal '("defparameter" "defun" "defun")
               (mapcar (lambda (spec) (loom-analyzer::token-name (first (first spec))))
                       forms)))
    (is (equal '((2 2) (4 4) (6 6))
               (mapcar #'rest forms))
        "and each one spans its own lines")))

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
