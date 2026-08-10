;;;
;;; Tests for src/graph/resolve.lisp -- cross-file call resolution (SS8.3).
;;;

(in-package :loom-graph-test)

(def-suite resolve
  :in all-tests
  :description "RESOLVE-CALLS turning recorded unresolved names into edges.")

(in-suite resolve)

(defun r-function (graph name file &key unresolved)
  ;; UNRESOLVED names the analyzer's output, which is :CALL-NAMES: the names
  ;; this file does not define. Whether they resolve is what RESOLVE-CALLS
  ;; decides, and it writes that verdict to :UNRESOLVED-CALLS.
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(test resolve-links-a-call-to-a-definition-in-another-file
  (let* ((g (make-graph))
         (caller (r-function g "analyze-tree" "a.lisp" :unresolved '("analyze-path")))
         (callee (r-function g "analyze-path" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "the edge the analyzer could not see across a file boundary")))

(test resolve-records-what-did-not-link-without-consuming-what-did
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee" "external-thing"))))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (is (equal '("external-thing") (getp caller :unresolved-calls))
        "what resolved becomes an edge; what did not stays an honest record")
    (is (equal '("callee" "external-thing") (getp caller :call-names))
        "and what the analyzer saw is left intact, because the next pass has
to be able to ask the same question again")))

(test a-resolved-edge-is-rebuilt-after-its-callee-is-retracted
  ;; The cross-file half of SS5.4's reanalysis, at the smallest possible scale.
  ;; Retracting b.lisp destroys the edge into it; a.lisp is not reanalyzed, so
  ;; nothing but a's own record can put the edge back. RESOLVE-CALLS used to
  ;; consume that record on the first pass, which made this unrecoverable.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee"))))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (is (= 1 (length (relationships-from g (id caller) :rel-type :calls)))
        "resolved once")
    (apply-transaction g (list (retract-file "b.lisp" nil)))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "and the retract takes the edge with it")
    (let ((callee (r-function g "callee" "b.lisp")))
      (declare (ignore callee))
      (apply-transaction g (resolve-calls g))
      (is (= 1 (length (relationships-from g (id caller) :rel-type :calls)))
          "resolution rebuilds it, which it can only do because a.lisp still
records that it calls something named callee"))))

(test resolve-leaves-a-genuinely-external-call-alone
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("hunchentoot-start"))))
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls)))
    (is (equal '("hunchentoot-start") (getp caller :unresolved-calls)))))

(test resolve-refuses-to-guess-between-two-definitions-of-a-name
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("run"))))
    (r-function g "run" "b.lisp")
    (r-function g "run" "c.lisp")
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "picking one would be a fabricated edge; asserting both would be worse")
    (is (equal '("run") (getp caller :unresolved-calls)))))

;;; ------------------------------------------------------------------
;;; Definitions: inheritance, dispatch, protocols (ARCH-0001)
;;; ------------------------------------------------------------------

(defun r-class (graph name file &key superclasses (kind :class))
  (let ((e (make-instance 'class-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :kind kind :language :lisp
                                             :superclass-names superclasses)))))
    (add-entity graph e)
    e))

(defun r-interface (graph name file)
  (let ((e (make-instance 'interface-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp)))))
    (add-entity graph e)
    e))

(defun r-method (graph name file &key specializers unresolved)
  (let ((e (make-instance 'method-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp
                                             :specializers specializers
                                             :generic-function name
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(test inheritance-resolves-across-a-file-boundary
  (let* ((g (make-graph))
         (child (r-class g "circle" "a.lisp" :superclasses '("shape" "standard-object"))))
    (let ((parent (r-class g "shape" "b.lisp")))
      (apply-transaction g (resolve-inheritance g))
      (is (equal (list (id parent))
                 (mapcar #'to-id (relationships-from g (id child) :rel-type :inherits)))
          "standard-object names no class here and is simply not an edge"))))

(test every-specialised-parameter-becomes-its-own-class-edge
  ;; The whole answer to multiple dispatch: no owning class, one edge each.
  (let* ((g (make-graph))
         (method (r-method g "draw" "a.lisp"
                           :specializers '("shape" "medium" "t" "(eql :svg)"))))
    (r-class g "shape" "b.lisp")
    (r-class g "medium" "c.lisp")
    (apply-transaction g (resolve-specializers g))
    (is (= 2 (length (relationships-from g (id method) :rel-type :uses)))
        "t dispatches on everything and (eql :svg) on a value; neither is a class")))

(test a-method-implements-the-generic-it-shares-a-name-with
  (let* ((g (make-graph))
         (method (r-method g "draw" "a.lisp" :specializers '("shape")))
         (generic (r-interface g "draw" "b.lisp")))
    (apply-transaction g (resolve-method-protocols g))
    (is (equal (list (id generic))
               (mapcar #'to-id (relationships-from g (id method) :rel-type :implements))))))

(test a-method-with-no-declared-generic-gets-no-protocol-edge
  ;; An implicit generic has no defgeneric form and so no source region.
  ;; ARCH-0001 refuses to synthesise one rather than invent a location.
  (let* ((g (make-graph))
         (method (r-method g "draw" "a.lisp" :specializers '("shape"))))
    (apply-transaction g (resolve-method-protocols g))
    (is (null (relationships-from g (id method) :rel-type :implements)))))

;;; ------------------------------------------------------------------
;;; Generated definitions reach their generator (ARCH-0002 R6)
;;; ------------------------------------------------------------------

(test a-generated-name-points-back-at-the-form-that-generated-it
  ;; The measured defect ARCH-0002 opens with: :GENERATED-BY was already on
  ;; every DEFSTRUCT accessor and every DEFCLASS slot accessor, but a property
  ;; is not an edge, so changing a structure reached none of its accessors'
  ;; callers. Both entity types are here because they take different shapes --
  ;; a DEFSTRUCT accessor is a plain :FUNCTION, a DEFCLASS accessor is a
  ;; generic and so an :INTERFACE -- and the :INTERFACE half is the one the
  ;; ontology had to be widened for.
  (let* ((g (make-graph))
         (class (r-class g "repository" "a.lisp"))
         (accessor (r-function g "repository-graph" "a.lisp"))
         (reader (r-interface g "id-derived-p" "b.lisp")))
    (setp accessor :generated-by "repository")
    (setp reader :generated-by "repository")
    (apply-transaction g (resolve-generated-definitions g))
    (is (equal (list (id class))
               (mapcar #'to-id (relationships-from g (id accessor) :rel-type :uses)))
        "a defstruct accessor reaches its structure")
    (is (equal (list (id class))
               (mapcar #'to-id (relationships-from g (id reader) :rel-type :uses)))
        "and a defclass slot accessor reaches its class")))

(test a-generated-name-whose-generator-is-ambiguous-is-left-alone
  ;; CON-0001 unchanged: two classes of one name is not a reason to pick one.
  (let* ((g (make-graph))
         (accessor (r-function g "thing-slot" "a.lisp")))
    (r-class g "thing" "b.lisp")
    (r-class g "thing" "c.lisp")
    (setp accessor :generated-by "thing")
    (apply-transaction g (resolve-generated-definitions g))
    (is (null (relationships-from g (id accessor) :rel-type :uses)))))

;;; ------------------------------------------------------------------
;;; Definitions a macro call brings into existence (ARCH-0002 R5, R7)
;;; ------------------------------------------------------------------

(defun r-file (graph path &key call-sites)
  (let ((e (make-instance 'file-entity :name path :origin-file path
                          :properties (properties-table
                                       (list :path path :language :lisp
                                             :definer-call-sites call-sites)))))
    (add-entity graph e)
    e))

(defun r-macro (graph name file &key (entity-type :function) (name-index 1)
                                     (body-index 2))
  "A macro whose template the analyzer characterised, as pass 1 would leave it."
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp :macro-p t
                                             :generator-entity-type entity-type
                                             :generator-name-index name-index
                                             :generator-body-index body-index)))))
    (add-entity graph e)
    e))

(defun r-call-site (operator name &key (line 10) call-names)
  (list :operator operator :start-line line :end-line (+ line 2)
        :arguments (list name) :symbol-arguments '(1)
        :call-names call-names))

(test a-definer-call-site-mints-the-definition-it-names
  ;; The name exists nowhere in the source as a defun, so nothing but this
  ;; pass can put it in the index. Located at the call site rather than at the
  ;; macro, because that is the region an agent has to open to change it.
  (let* ((g (make-graph))
         (macro (r-macro g "struct-simplefn" "macros.lisp")))
    (r-file g "geo.lisp"
            :call-sites (list (r-call-site "struct-simplefn" "geo"
                                           :call-names '("compute-area"))))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (let ((minted (find-entity-by-key g '(:function "geo.lisp" "geo"))))
      (is (not (null minted)) "the definition the macro call defines")
      (is (equal "geo.lisp" (getp minted :file))
          "located at the call site, not at the macro")
      (is (eql 10 (getp minted :start-line)))
      (is (equal "struct-simplefn" (getp minted :generated-by))
          "marked, so a derived name can be told from a written one -- and so
the retract half can recognise what it made")
      (is (equal '("compute-area") (getp minted :call-names))
          "carrying the site's pre-walked names, or resolve-calls has nothing")
      (is (equal (list (id macro))
                 (mapcar #'to-id (relationships-from g (id minted) :rel-type :uses)))
          "and reaching the macro, so changing the macro reaches what it made"))))

(test a-registry-entry-mints-without-any-macro-in-the-tree
  ;; fiveam's TEST is the case that matters: defined outside the indexed tree,
  ;; so there is no macro entity to point a :uses edge at, and the :test entity
  ;; type has held zero facts for exactly this reason.
  (let ((g (make-graph))
        (registry (make-hash-table :test #'equal)))
    (setf (gethash "test" registry)
          (list (list :name "test" :package "fiveam" :entity-type :test
                      :name-index 1 :body-index 2 :framework :fiveam)))
    (r-file g "t.lisp" :call-sites (list (r-call-site "test" "alpha-works"
                                                      :call-names '("alpha"))))
    (apply-transaction g (resolve-generated-definitions g :registry registry))
    (let ((minted (first (entities-of-type g :test))))
      (is (not (null minted)))
      (is (string= "alpha-works" (name minted)))
      (is (eq :fiveam (getp minted :framework)))
      (is (null (relationships-from g (id minted) :rel-type :uses))
          "no edge, because there is no macro entity to reach -- the
:generated-by property still records what made it"))))

(test a-minted-entity-inherits-the-system-of-the-file-that-called-the-macro
  ;; ARCH-0009 R6. A macro-minted entity has no form of its own to read a
  ;; package from, so the calling file's is the only fact available -- and
  ;; without it every :TEST in the tree would be unplaceable, which
  ;; EDGES-BETWEEN-SYSTEMS reads as "not evidence of a violation" rather than
  ;; as a gap. This test is also why :SYSTEM had to be declared on :TEST first:
  ;; DECLARED-PROPERTIES-ONLY drops an undeclared key without a word.
  (let ((g (make-graph))
        (registry (make-hash-table :test #'equal)))
    (setf (gethash "test" registry)
          (list (list :name "test" :package "fiveam" :entity-type :test
                      :name-index 1 :body-index 2 :framework :fiveam)))
    (let ((file (r-file g "src/analyzer/test/lisp-analyzer.lisp"
                        :call-sites (list (r-call-site "test" "alpha-works")))))
      (setp file :system :loom-analyzer-test))
    (apply-transaction g (resolve-generated-definitions g :registry registry))
    (let ((minted (first (entities-of-type g :test))))
      (is (not (null minted)))
      (is (eq :loom-analyzer-test (getp minted :system))
          "the file's package, not the path it sits under"))))

(test a-call-site-matching-several-registry-entries-is-left-alone
  ;; Two packages may name a macro identically, which is why the table holds a
  ;; list. Picking one would be the fabricated fact CON-0001 forbids.
  (let ((g (make-graph)))
    (r-macro g "define-thing" "a.lisp")
    (r-macro g "define-thing" "b.lisp")
    (r-file g "c.lisp" :call-sites (list (r-call-site "define-thing" "widget")))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (null (find-entity-by-key g '(:function "c.lisp" "widget"))))))

(test an-uncharacterised-macro-mints-nothing-and-is-reported
  ;; The near-miss: a template whose defined name only exists once the expander
  ;; runs. Reported rather than approximated, and countable so the gap is
  ;; visible without a suite run.
  (let* ((g (make-graph))
         (macro (r-function g "defentity" "a.lisp")))
    (setp macro :macro-p t)
    (setp macro :definer-status :unhandled)
    (r-file g "b.lisp" :call-sites (list (r-call-site "defentity" "workspace")))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (null (find-entity-by-key g '(:function "b.lisp" "workspace"))))
    (is (equal (list macro) (unhandled-definer-macros g)))))

(test a-macro-that-defines-nothing-but-swallows-a-body-is-reported
  ;; BUG-0016. DEFINE-OPERATION's template contains no DEFUN, DEFCLASS or
  ;; DEFMETHOD, so MACRO-GENERATOR-PROPERTIES records nothing for it and it
  ;; carries no :DEFINER-STATUS either -- which used to mean `status' said "1
  ;; definer macro" on a tree where 15 call sites were orphaning 42 names, and
  ;; the tool whose job is reporting gaps reported this one as no gap.
  ;;
  ;; The discriminator is that its calls are top-level forms carrying call
  ;; names. Decided here rather than in the analyzer because the macro's
  ;; definition and its call sites are in different files, which a file-scoped
  ;; analyzer cannot see across (RULE-0002).
  (let* ((g (make-graph))
         (macro (r-function g "define-operation" "registry.lisp")))
    (setp macro :macro-p t)
    (r-file g "operations.lisp"
            :call-sites (list (r-call-site "define-operation" "check"
                                           :call-names '("violation-summary"))))
    (is (equal (list macro) (unhandled-definer-macros g))
        "reported, where before it was silently uncharacterised")
    (is (= 1 (gethash "define-operation" (body-swallowing-macro-names g)))
        "and the orphan count travels with the name, so the line is actionable")))

(test a-wrapper-macro-is-not-swept-into-the-definer-count
  ;; The guard MACRO-GENERATOR-PROPERTIES' docstring asks for, and the reason
  ;; the clause above keys on definer call sites rather than on "template
  ;; defines nothing": every WITH-LOCK in the tree would otherwise land in a
  ;; count that exists to be read and acted on, which is what makes BUG-0009's
  ;; output unreadable. A wrapper is never a top-level form, so it has no
  ;; definer call site and nothing to orphan.
  (let* ((g (make-graph))
         (macro (r-function g "with-lock" "util.lisp")))
    (setp macro :macro-p t)
    (r-file g "user.lisp" :call-sites (list (r-call-site "some-other-definer" "thing")))
    (is (null (unhandled-definer-macros g)))))

(test an-introspected-entity-does-not-block-the-call-site-that-explains-it
  ;; The same guard, and the one claim it must not read as a rival. An
  ;; :INTROSPECTED entity is this very definition seen from the other side --
  ;; the compiler reporting what the macro call expanded into (ARCH-0011 R6) --
  ;; and enrichment mints exactly these, since a macro-generated name is what
  ;; the text pass cannot see and the image can. Counted as hand-written, the
  ;; first enrich would be the last pass able to mint here: the key would stay
  ;; occupied, every later pass would report a collision it could do nothing
  ;; about, and the :USES edge back to the macro would never be drawn -- so
  ;; `impact' on the macro would stop reaching what it generates, which is the
  ;; whole of ARCH-0002.
  (let* ((g (make-graph))
         (macro (r-macro g "struct-simplefn" "macros.lisp")))
    (add-entity g (make-instance 'function-entity
                                 :name "geo" :origin-file "geo.lisp"
                                 :source :introspected :confidence 1.0
                                 :properties (properties-table
                                              (list :file "geo.lisp" :start-line 3
                                                    :end-line 3 :language :lisp))))
    (r-file g "geo.lisp"
            :call-sites (list (r-call-site "struct-simplefn" "geo")))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (let ((entity (find-entity-by-key g '(:function "geo.lisp" "geo"))))
      (is (equal "struct-simplefn" (getp entity :generated-by))
          "the minted account upserts onto the image's, rather than being refused")
      (is (equal (list (id macro))
                 (mapcar #'to-id (relationships-from g (id entity) :rel-type :uses)))
          "and the edge to the generator exists, which is what the refusal cost")
      (is (null (generated-definition-collisions g nil))
          "and nothing is reported as a collision, because nothing collided"))))

(test a-hand-written-definition-survives-a-colliding-generated-call-site
  ;; ARCH-0002 R5's collision guard, and the trigger PLAN-0001 step 5b names as
  ;; the one that can silently not fire: a call site whose name matches a
  ;; natural key a real, hand-written DEFUN already claims must not be
  ;; overwritten. Two halves are asserted, per ARCH-0002 CONSEQUENCES -- the
  ;; hand-written entity survives untouched, AND the collision is counted,
  ;; because "did not crash" alone is indistinguishable from a guard that
  ;; quietly stopped guarding.
  (let* ((g (make-graph))
         (macro (r-macro g "struct-simplefn" "macros.lisp"))
         (handwritten (r-function g "geo" "geo.lisp")))
    (declare (ignorable macro))
    (r-file g "geo.lisp"
            :call-sites (list (r-call-site "struct-simplefn" "geo"
                                           :call-names '("compute-area"))))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (let ((survivor (find-entity-by-key g '(:function "geo.lisp" "geo"))))
      (is (eq handwritten survivor)
          "the hand-written entity, not a mint that clobbered it")
      (is (equal (id handwritten) (id survivor))
          "same id -- nothing was retracted and replaced under the same key")
      (is (null (getp survivor :generated-by))
          "still hand-written: an overwrite nobody recorded would be
indistinguishable from nothing having happened")
      (is (eql 1 (getp survivor :start-line))
          "original location intact -- not overwritten with the call site's own line")
      (is (null (relationships-from g (id survivor) :rel-type :uses))
          "no edge to the macro, because nothing was minted to carry one")
      (is (= 1 (length (generated-definition-collisions g nil)))
          "counted rather than merely not crashing -- the trigger ARCH-0002
warns can silently not fire")
      (is (equal (cons "geo.lisp" "geo")
                 (first (generated-definition-collisions g nil)))))))

(test a-generated-entity-is-refreshed-rather-than-duplicated
  (let ((g (make-graph)))
    (r-macro g "struct-simplefn" "macros.lisp")
    (r-file g "geo.lisp" :call-sites (list (r-call-site "struct-simplefn" "geo")))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (let ((entities (length (all-entities g)))
          (edges (length (all-relationships g))))
      (apply-transaction g (resolve-generated-definitions g :registry nil))
      (is (= entities (length (all-entities g)))
          "a refresh is an upsert by natural key, not a second entity -- and
not a retract-plus-assert, which could remove what it had just landed")
      (is (= edges (length (all-relationships g)))))))

(test a-call-site-that-disappears-takes-its-generated-entity-with-it
  ;; The retract half at its smallest. The call site's own file is reanalyzed
  ;; here, so retract-file would have handled it -- the case retract-file
  ;; cannot handle is the macro changing while the call site's file does not,
  ;; which needs the workspace pipeline to show.
  (let ((g (make-graph)))
    (r-macro g "struct-simplefn" "macros.lisp")
    (r-file g "geo.lisp" :call-sites (list (r-call-site "struct-simplefn" "geo")))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (not (null (find-entity-by-key g '(:function "geo.lisp" "geo")))))
    (apply-transaction g (list (retract-file "geo.lisp" nil)))
    (r-file g "geo.lisp" :call-sites '())
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (null (find-entity-by-key g '(:function "geo.lisp" "geo")))
        "the pass recomputes its whole output, so what it no longer produces
does not survive by having been produced once")))

(test a-defstruct-accessor-is-not-retracted-by-the-macro-half
  ;; The retract predicate keys on the registry, not on the mere presence of
  ;; :generated-by. A defstruct accessor carries that property too -- naming a
  ;; class rather than a macro -- and a predicate that read the property alone
  ;; would retract every accessor in the tree on the first pass and re-mint
  ;; none of them.
  (let* ((g (make-graph))
         (accessor (r-function g "repository-graph" "a.lisp")))
    (r-class g "repository" "a.lisp")
    (setp accessor :generated-by "repository")
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (not (null (get-entity g (id accessor))))
        "still there, and the ARCH-0001 output the whole index depends on")))

(defun r-test (graph name file &key call-names)
  (let ((e (make-instance 'test-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp :framework :fiveam
                                             :generated-by "test"
                                             :call-names call-names)))))
    (add-entity graph e)
    e))

(test a-test-body-resolves-its-calls-like-any-other-caller
  ;; ARCH-0002 R8. Without this the minted entities exist with no edges and
  ;; impact still reports nothing, which is the whole payoff missed by one
  ;; missing element of a type list.
  (let* ((g (make-graph))
         (test (r-test g "alpha-works" "t.lisp" :call-names '("alpha" "is")))
         (alpha (r-function g "alpha" "a.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id alpha))
               (mapcar #'to-id (relationships-from g (id test) :rel-type :calls)))
        "the subject the test invokes")
    (is (equal '("is") (getp test :unresolved-calls))
        "and the framework's own assertion operators stay unresolved, which is
correct rather than a gap: fiveam is external to every indexed tree")))

(test coverage-is-derived-from-what-a-test-body-calls
  ;; ARCH-0002 R9, and the payoff the whole sequence exists for: until this
  ;; ran, the graph held no :tests edge at all and `impact' could not answer
  ;; which tests cover a change. The :interface case is why step 1 widened
  ;; :tests -- a test calling a defclass slot accessor directly still covers it.
  (let* ((g (make-graph))
         (test (r-test g "alpha-works" "t.lisp"
                       :call-names '("alpha" "id-derived-p")))
         (alpha (r-function g "alpha" "a.lisp"))
         (accessor (r-interface g "id-derived-p" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (apply-transaction g (resolve-tests g))
    (let ((covered (mapcar #'to-id (relationships-from g (id test) :rel-type :tests))))
      (is (member (id alpha) covered :test #'equal))
      (is (member (id accessor) covered :test #'equal)))))

(test coverage-needs-the-calls-to-exist-first
  ;; The ordering RESOLVE-AND-CHECK owns, asserted rather than described. This
  ;; pass reads :calls edges, so running it before RESOLVE-CALLS produces
  ;; nothing at all -- silently, since an empty op list is a valid one.
  (let ((g (make-graph)))
    (r-test g "alpha-works" "t.lisp" :call-names '("alpha"))
    (r-function g "alpha" "a.lisp")
    (is (null (resolve-tests g)) "nothing to derive from yet")
    (apply-transaction g (resolve-calls g))
    (is (not (null (resolve-tests g))))))

(test coverage-reaches-impact-as-a-collected-field
  ;; :tests is :collect-as :tests, so it must land in the report's tests field
  ;; rather than inflating the impact set. Changing alpha should tell an agent
  ;; which test to run, not claim the test is a thing that broke.
  (let* ((g (make-graph))
         (test (r-test g "alpha-works" "t.lisp" :call-names '("alpha")))
         (alpha (r-function g "alpha" "a.lisp")))
    (apply-transaction g (resolve-calls g))
    (apply-transaction g (resolve-tests g))
    (let ((result (impact-set g (id alpha))))
      (is (equal (list (name test))
                 (mapcar #'name (impact-result-tests result)))))))

;;; ------------------------------------------------------------------
;;; Dispatched calls fan out (ARCH-0001 R4)
;;; ------------------------------------------------------------------

(test a-dispatched-call-reaches-every-candidate-method
  (let* ((g (make-graph))
         (caller (r-function g "render" "a.lisp" :unresolved '("draw"))))
    (r-interface g "draw" "b.lisp")
    (r-method g "draw" "b.lisp" :specializers '("circle"))
    (r-method g "draw" "c.lisp" :specializers '("square"))
    (apply-transaction g (resolve-calls g))
    (let ((edges (relationships-from g (id caller) :rel-type :calls)))
      (is (= 2 (length edges))
          "a union of genuine possibilities, not a guess among candidates")
      (is (every (lambda (r) (eq :inferred (source r))) edges)
          "and marked as inferred, because which one runs is a runtime question")
      (is (every (lambda (r) (< (confidence r) 1.0)) edges))
      (is (null (getp caller :unresolved-calls))
          "a name that fanned out is resolved, not outstanding"))))

(test one-method-means-the-dispatch-is-certain
  ;; 70% of the generics in the repository that motivated ARCH-0001 have
  ;; exactly one method, so this is the common case and not a corner.
  (let* ((g (make-graph))
         (caller (r-function g "render" "a.lisp" :unresolved '("draw"))))
    (r-method g "draw" "b.lisp" :specializers '("circle"))
    (apply-transaction g (resolve-calls g))
    (let ((edge (first (relationships-from g (id caller) :rel-type :calls))))
      (is (not (null edge)))
      (is (= 1.0 (confidence edge))
          "one implementation, so the call reaches it"))))

(test a-protocol-with-no-implementation-is-still-callable
  ;; A DEFCLASS slot accessor is a generic function generated from a slot and
  ;; never specialised again. Refusing this edge is what left DEC-0002's
  ;; reference to id-derived-p dangling.
  (let* ((g (make-graph))
         (caller (r-function g "use" "a.lisp" :unresolved '("id-derived-p")))
         (accessor (r-interface g "id-derived-p" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (let ((edges (relationships-from g (id caller) :rel-type :calls)))
      (is (equal (list (id accessor)) (mapcar #'to-id edges)))
      (is (eq :structural (source (first edges)))
          "nothing is being guessed: there is one definition and no dispatch"))))

(test a-plain-function-still-resolves-exactly
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee")))
         (callee (r-function g "callee" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (let ((edge (first (relationships-from g (id caller) :rel-type :calls))))
      (is (equal (id callee) (to-id edge)))
      (is (eq :structural (source edge))
          "adding dispatch must not turn ordinary calls into guesses"))))

(test resolve-does-not-link-a-function-to-itself
  (let ((g (make-graph)))
    (let ((f (r-function g "recurse" "a.lisp" :unresolved '("recurse"))))
      (apply-transaction g (resolve-calls g))
      (is (null (relationships-from g (id f) :rel-type :calls))))))

(test resolve-is-idempotent
  (let ((g (make-graph)))
    (r-function g "caller" "a.lisp" :unresolved '("callee"))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (let ((edges (length (all-relationships g))))
      (apply-transaction g (resolve-calls g))
      (is (= edges (length (all-relationships g)))
          "safe to run after every analysis pass")
      (is (= 1 edges)))))

(test resolution-is-what-makes-impact-cross-a-file-boundary
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee")))
         (callee (r-function g "callee" "b.lisp")))
    (is (null (impact-result-impacted (impact-set g (id callee))))
        "before resolution, changing callee looks like it affects nothing")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (name caller))
               (mapcar (lambda (e) (name (impact-entry-entity e)))
                       (impact-result-impacted (impact-set g (id callee)))))
        "after it, the question has an answer")))
