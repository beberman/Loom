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

(test an-ordinary-resolving-call-mints-no-call-site
  ;; DES-0014 R2, and the test R2 actually turns on: its whole-tree
  ;; counterpart in the workspace suite bounds the population, but this is what
  ;; says the common path is untouched. 2527 of this tree's 2557 resolving
  ;; call-name occurrences look exactly like this one, and every one of them
  ;; must keep producing the edge it produces today and nothing else.
  ;;
  ;; Cheap on purpose. The ceiling test costs a full index of the tree; this
  ;; costs two entities, so it is the one that can be run constantly.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee")))
         (callee (r-function g "callee" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "the edge is the one it always was, sourced at the caller")
    (is (null (entities-of-type g :call-site))
        "and no node is interposed. DES-0014: a :CALL-SITE is minted exactly
when a call name cannot be expressed as a :CALLS edge from an existing
definition entity -- here it can, so there is nothing for one to carry")))

(test a-call-site-is-a-caller-like-any-other
  ;; DES-0014, PLAN-0014 step 4. RESOLVE-CALLS walked '(:function :method
  ;; :test), so a :CALL-SITE entity sitting in the graph was simply never
  ;; looked at -- the pass that turns a name into an edge did not know the type
  ;; existed. Nothing mints one yet, which is the point: the plumbing lands
  ;; before any generator, so each generator afterwards moves a number that is
  ;; attributable to it alone.
  (let* ((g (make-graph))
         (site (make-call-site-entity :file "a.lisp" :start-line 12
                                      :call-name "target"
                                      :referrer-kind :variable
                                      :language :lisp :system :demo))
         (callee (r-function g "target" "b.lisp")))
    (add-entity g site)
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id site) :rel-type :calls)))
        "the edge runs from the call site to the callee, so `describe' on the
callee shows it as an incoming caller")))

(test a-call-site-records-a-name-that-reached-nothing
  ;; The other half of treating a call site as one more caller: the
  ;; :UNRESOLVED-CALLS write applies to it unchanged, which is where the seven
  ;; initform names that resolve to nothing on this tree are recorded rather
  ;; than dropped (CON-0001, PLAN-0014 decision 4). Free, because it is the
  ;; same code path -- but free only if the caller loop reaches the type at
  ;; all, which is what this asserts.
  (let* ((g (make-graph))
         (site (make-call-site-entity :file "a.lisp" :start-line 12
                                      :call-name "nowhere"
                                      :referrer-kind :variable)))
    (add-entity g site)
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id site) :rel-type :calls)))
    (is (equal '("nowhere") (getp site :unresolved-calls))
        "a name matching nothing is a recorded gap, not a silent drop")
    (is (null (getp site :call-names))
        "and the name is still stored once -- CALLER-CALL-NAMES derives the
list the pass reads from :CALL-NAME rather than from a second copy")))

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
  ;; Rewritten by PLAN-0014 step 8 rather than deleted: what it protects is
  ;; still true and still worth a test. CALL-TARGETS' docstring argued against
  ;; fanning out on the grounds that "asserting all of them would make every
  ;; caller of a common name look coupled to code it never touches", and that
  ;; objection is about edges running *from the caller*. It still holds --
  ;; CALLER acquires no direct edge to either RUN below -- and REQ-0015's
  ;; fan-out now happens one hop away, from a node that is labelled as a guess.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("run"))))
    (r-function g "run" "b.lisp")
    (r-function g "run" "c.lisp")
    (apply-transaction g (resolve-calls g))
    (is (null (remove :call-site
                      (relationships-from g (id caller) :rel-type :calls)
                      :key (lambda (edge)
                             (entity-type (get-entity g (to-id edge))))))
        "picking one would be a fabricated edge; asserting both from the caller
would be the false coupling this clause has always refused")))

(test an-ambiguous-call-fans-out-from-a-call-site-the-caller-contains
  ;; REQ-0015 and R8's third test. (t nil) dropped 18 occurrences on this tree
  ;; and 144 for a single name on game-server, and the drop was invisible: the
  ;; name landed in :UNRESOLVED-CALLS beside the genuinely external ones, so
  ;; nothing distinguished "this is defined elsewhere" from "this is defined
  ;; twice here and I declined to choose".
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("run")))
         (b (r-function g "run" "b.lisp"))
         (c (r-function g "run" "c.lisp")))
    (apply-transaction g (resolve-calls g))
    (let ((sites (entities-of-type g :call-site)))
      (is (= 1 (length sites)) "one site, not one per candidate")
      (let ((site (first sites)))
        (is (eq :ambiguous (getp site :referrer-kind)))
        (is (eql 2 (getp site :candidate-count))
            "how much of a guess this is, as a number a consumer can read")
        (is (equal "a.lisp" (getp site :file))
            "at the caller's file and start line: :CALL-NAMES records no
position of its own, so there is no finer truth available (decision 5)")
        (is (equal (list (id site))
                   (mapcar #'to-id (relationships-from g (id caller) :rel-type :contains)))
            "and the caller shows one ambiguous site rather than two couplings")
        (let ((edges (relationships-from g (id site) :rel-type :calls)))
          (is (equal (sort (list (id b) (id c)) #'string<)
                     (sort (mapcar #'to-id edges) #'string<))
              "both candidates reached, which is REQ-0015's fan-out")
          (is (every (lambda (e) (= 0.5 (confidence e))) edges)
              "each at 1/N, the same DISPATCH-CONFIDENCE the method fan-out
uses"))))
    (is (null (getp caller :unresolved-calls))
        "and the name leaves :UNRESOLVED-CALLS -- REQ-0015 R3 keeps only names
matching nothing")))

(test an-ambiguous-name-on-a-call-site-mints-no-second-call-site
  ;; PLAN-0014 decision 6, and the recursion it guards. Seven of this tree's
  ;; 124 resolving definer-call names are themselves ambiguous, so without this
  ;; the pass would mint a call site from a call site -- at a key derived from
  ;; the first one's file and line -- on every pass, forever. The node exists to
  ;; be the anchor for an ambiguity, and a call site already is one.
  (let* ((g (make-graph))
         (site (make-call-site-entity :file "a.lisp" :start-line 12
                                      :call-name "run"
                                      :referrer-kind :definer-call
                                      :language :lisp :system :demo)))
    (add-entity g site)
    (r-function g "run" "b.lisp")
    (r-function g "run" "c.lisp")
    (apply-transaction g (resolve-calls g))
    (is (= 1 (length (entities-of-type g :call-site)))
        "the call site fans out directly and mints nothing")
    (is (= 2 (length (relationships-from g (id site) :rel-type :calls)))
        "still reaching both candidates")))

;;; ------------------------------------------------------------------
;;; Definitions: inheritance, dispatch, protocols (DES-0001)
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
  ;; DES-0001 refuses to synthesise one rather than invent a location.
  (let* ((g (make-graph))
         (method (r-method g "draw" "a.lisp" :specializers '("shape"))))
    (apply-transaction g (resolve-method-protocols g))
    (is (null (relationships-from g (id method) :rel-type :implements)))))

;;; ------------------------------------------------------------------
;;; Generated definitions reach their generator (DES-0002 R6)
;;; ------------------------------------------------------------------

(test a-generated-name-points-back-at-the-form-that-generated-it
  ;; The measured defect DES-0002 opens with: :GENERATED-BY was already on
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
;;; Definitions a macro call brings into existence (DES-0002 R5, R7)
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
  ;; DES-0009 R6. A macro-minted entity has no form of its own to read a
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

(test an-orphaned-definer-call-site-mints-a-call-site-per-resolving-name
  ;; BUG-0016's second half and R8's second test. Reporting the gap was the
  ;; first half; this is the call actually reaching its callee. DEFINE-OPERATION
  ;; expands to a runtime table entry, so its 15 sites mint no entity and the 42
  ;; names their bodies call attach to nothing -- every REST route and every MCP
  ;; tool invisible in the call graph.
  ;;
  ;; `not-here' is decision 2 asserted rather than assumed. DES-0014 R4 reads
  ;; literally as one node per name, which on this tree is 266 nodes of which
  ;; 142 name something that is not there; a node per absent callee is a node
  ;; per thing that does not exist, and the fact that the name went nowhere
  ;; already lives on the site's :CALL-NAMES and in `check''s definer report.
  (let* ((g (make-graph))
         (callee (r-function g "violation-summary" "check.lisp"))
         (file (r-file g "operations.lisp"
                       :call-sites
                       (list (r-call-site "define-operation" "check"
                                          :call-names '("violation-summary"
                                                        "not-here"))))))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (let ((sites (entities-of-type g :call-site)))
      (is (= 1 (length sites))
          "one node per resolving name, and none for the name that resolves to
nothing")
      (let ((site (first sites)))
        (is (equal "violation-summary" (getp site :call-name)))
        (is (eq :definer-call (getp site :referrer-kind)))
        (is (equal "define-operation" (getp site :generated-by))
            "carrying the macro that swallowed the body it was read from")
        (is (eql 10 (getp site :start-line))
            "at the call site's line, which is the region an agent opens")
        (is (equal (list (id site))
                   (mapcar #'to-id (relationships-from g (id file) :rel-type :contains)))
            "owned by the file, because there is no definition entity to own it")
        (apply-transaction g (resolve-calls g))
        (is (equal (list (id callee))
                   (mapcar #'to-id (relationships-from g (id site) :rel-type :calls)))
            "and the call reaches its callee, which is the whole of BUG-0016")))))

(test a-definer-call-site-that-minted-a-definition-mints-no-call-site
  ;; DES-0014 R4's last clause, and the disjointness the two populations rely
  ;; on: a site that minted an entity mints no call site, because the entity
  ;; already carries the site's :CALL-NAMES and RESOLVE-CALLS sources the edge
  ;; at it. Minting both would double every fiveam TEST body's calls.
  (let ((g (make-graph)))
    (r-macro g "struct-simplefn" "macros.lisp")
    (r-function g "compute-area" "area.lisp")
    (r-file g "geo.lisp"
            :call-sites (list (r-call-site "struct-simplefn" "geo"
                                           :call-names '("compute-area"))))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (not (null (find-entity-by-key g '(:function "geo.lisp" "geo"))))
        "the site mints its definition as before")
    (is (null (entities-of-type g :call-site))
        "and nothing else -- the definition is the :CALLS source")))

(test an-introspected-entity-does-not-block-the-call-site-that-explains-it
  ;; The same guard, and the one claim it must not read as a rival. An
  ;; :INTROSPECTED entity is this very definition seen from the other side --
  ;; the compiler reporting what the macro call expanded into (DES-0011 R6) --
  ;; and enrichment mints exactly these, since a macro-generated name is what
  ;; the text pass cannot see and the image can. Counted as hand-written, the
  ;; first enrich would be the last pass able to mint here: the key would stay
  ;; occupied, every later pass would report a collision it could do nothing
  ;; about, and the :USES edge back to the macro would never be drawn -- so
  ;; `impact' on the macro would stop reaching what it generates, which is the
  ;; whole of DES-0002.
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
  ;; DES-0002 R5's collision guard, and the trigger PLAN-0001 step 5b names as
  ;; the one that can silently not fire: a call site whose name matches a
  ;; natural key a real, hand-written DEFUN already claims must not be
  ;; overwritten. Two halves are asserted, per DES-0002 CONSEQUENCES -- the
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
          "counted rather than merely not crashing -- the trigger DES-0002
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

(test a-definer-site-whose-macro-becomes-characterised-loses-its-call-sites
  ;; PLAN-0014 step 9, and the case DES-0014 R6 got wrong. "RETRACT-FILE needs
  ;; nothing" is true of the analyzer's initform sites and false of these two
  ;; kinds: the call site's origin file is geo.lisp and geo.lisp never changes,
  ;; so nothing retracts a site that the macro's own file stopped orphaning.
  ;; Without the sweep the graph keeps a :CALL-SITE with a live :CALLS edge
  ;; beside the definition that now carries the same call name, and an
  ;; incremental index drifts from a rebuilt one for as long as geo.lisp
  ;; happens not to be touched.
  (let ((g (make-graph)))
    (r-function g "compute-area" "area.lisp")
    (r-file g "geo.lisp"
            :call-sites (list (r-call-site "struct-simplefn" "geo"
                                           :call-names '("compute-area"))))
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (= 1 (length (entities-of-type g :call-site)))
        "no macro of that name, so the site is orphaned and its name gets a node")
    (r-macro g "struct-simplefn" "macros.lisp")
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (is (not (null (find-entity-by-key g '(:function "geo.lisp" "geo"))))
        "the site now mints a definition")
    (is (null (entities-of-type g :call-site))
        "which carries the call name itself, so the call site is not derived
again -- and what this pass no longer produces must not survive by having been
produced once")))

(test a-name-that-stops-being-ambiguous-leaves-no-call-site-behind
  ;; The other half of step 9, and the harder one to notice: nothing about
  ;; a.lisp changed. One of the two definitions of RUN was deleted from c.lisp,
  ;; so the name resolves cleanly now -- but the ambiguous call site's own
  ;; origin file is a.lisp, so RETRACT-FILE never sees it, and it would sit
  ;; there with a live edge to the survivor while the caller also acquired its
  ;; own direct edge. One call reported twice, at two different confidences.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("run"))))
    (r-function g "run" "b.lisp")
    (r-function g "run" "c.lisp")
    (apply-transaction g (resolve-calls g))
    (is (= 1 (length (entities-of-type g :call-site))))
    (apply-transaction g (list (retract-file "c.lisp" nil)))
    (apply-transaction g (resolve-calls g))
    (is (null (entities-of-type g :call-site))
        "the ambiguity is gone, so its anchor is not derived again")
    (is (= 1 (length (relationships-from g (id caller) :rel-type :calls)))
        "and the caller has the one direct edge the name now earns")))

(test a-sweep-does-not-touch-a-call-site-the-analyzer-owns
  ;; The predicate keys on :REFERRER-KIND as well as on absence from the
  ;; produced set, and both sweeps need it. An initform site is derived from one
  ;; file by ANALYZE-FILE and aged out by RETRACT-FILE; neither resolution pass
  ;; produces one, so a sweep that keyed on absence alone would retract every
  ;; one of them on its first run and re-mint none.
  (let ((g (make-graph))
        (site (make-call-site-entity :file "a.lisp" :start-line 12
                                     :call-name "target"
                                     :referrer-kind :variable
                                     :language :lisp :system :demo)))
    (add-entity g site)
    (apply-transaction g (resolve-generated-definitions g :registry nil))
    (apply-transaction g (resolve-calls g))
    (is (not (null (get-entity g (id site))))
        "still there -- the analyzer's, and RETRACT-FILE's to age out")))

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
        "still there, and the DES-0001 output the whole index depends on")))

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
  ;; DES-0002 R8. Without this the minted entities exist with no edges and
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
  ;; DES-0002 R9, and the payoff the whole sequence exists for: until this
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

(test a-helper-in-the-test-file-is-not-a-tested-unit
  ;; REQ-0053 R6. A test calls its own fixtures as often as it calls its
  ;; subject -- 192 of front-end's 1,351 resolvable case calls reach a helper
  ;; defined in the test file itself -- and counting those makes `tested-units'
  ;; a count of the scaffolding. The :CALLS edge is still drawn: what the test
  ;; reaches is a fact, and only the coverage claim is refused.
  (let* ((g (make-graph))
         (test (r-test g "alpha-works" "t.lisp" :call-names '("alpha" "with-server")))
         (alpha (r-function g "alpha" "a.lisp"))
         (helper (r-function g "with-server" "t.lisp")))
    (apply-transaction g (resolve-calls g))
    (apply-transaction g (resolve-tests g))
    (let ((covered (mapcar #'to-id (relationships-from g (id test) :rel-type :tests))))
      (is (equal (list (id alpha)) covered)
          "the subject is covered and the fixture beside the test is not"))
    (is (member (id helper)
                (mapcar #'to-id (relationships-from g (id test) :rel-type :calls))
                :test #'equal)
        "the call itself is still recorded")))

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
;;; Dispatched calls fan out (DES-0001 R4)
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
  ;; 70% of the generics in the repository that motivated DES-0001 have
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

;;; ------------------------------------------------------------------
;;; A broken link is reported; an ordinary word is not (BUG-0027)
;;; ------------------------------------------------------------------

(test resolution-links-a-target-and-refuses-to-judge-one-it-cannot-place
  ;; BUG-0027, and the correction that followed the first fix. Resolution makes
  ;; the edge when a link target names an indexed entity, and says *nothing*
  ;; when it does not -- because "absent from the index" is not "absent from the
  ;; disk". game-server links to CLAUDE.md, which REQ-0028 excludes by name, and
  ;; to a .sql fixture no analyzer claims; both files are present. Reporting
  ;; those as broken put five confident falsehoods beside two real findings.
  ;;
  ;; Whether a path exists is a filesystem question, and loom-graph has no
  ;; filesystem. CHECK-DOCUMENT-LINKS in loom-workspace owns it.
  (let* ((g (make-graph))
         (file (make-instance 'file-entity :name "media/media-handler.lisp"
                              :origin-file "media/media-handler.lisp"
                              :properties (properties-table
                                           '(:path "media/media-handler.lisp"
                                             :language :lisp))))
         (doc (make-instance 'document-entity :name "docs/notes.md"
                             :origin-file "docs/notes.md"
                             :properties (properties-table
                                          '(:path "docs/notes.md"
                                            :format :markdown
                                            :link-targets ("media/media-handler.lisp"
                                                           "CLAUDE.md")
                                            :mentions ("sprite"))))))
    (add-entity g file)
    (add-entity g doc)
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (= 1 (length (relationships-from g (id doc) :rel-type :mentions)))
        "the target that names an indexed file earns the same weak edge a
mention does")
    (is (null (unresolved-references g))
        "and the one it could not place is left for the layer that can stat it: ~a"
        (unresolved-references g))))

(test a-link-to-another-document-resolves-and-is-not-reported-broken
  ;; The false positive the first version of BUG-0027's fix produced. A markdown
  ;; file linking to another markdown file has a *working* link -- the file is
  ;; right there -- and reporting it as unresolved is exactly the kind of noise
  ;; that teaches a reader to stop reading the list.
  ;;
  ;; It earns no edge because :MENTIONS is declared to terminate at code, and a
  ;; document-to-document link is a different claim that refines: exists for.
  ;; The transaction validator caught this rather than a test: asserting the
  ;; forbidden edge refused the whole transaction, so one bad edge cost an
  ;; entire repository its document links.
  (let* ((g (make-graph))
         (other (make-instance 'document-entity :name "docs/api.md"
                               :origin-file "docs/api.md"
                               :properties (properties-table
                                            '(:path "docs/api.md" :format :markdown))))
         (doc (make-instance 'document-entity :name "docs/README.md"
                             :origin-file "docs/README.md"
                             :properties (properties-table
                                          '(:path "docs/README.md" :format :markdown
                                            :link-targets ("docs/api.md"))))))
    (add-entity g other)
    (add-entity g doc)
    (let ((ops (resolve-document-links g :workspace-id "w")))
      ;; The transaction has to be applicable at all, which is the regression.
      (finishes (apply-transaction g ops)))
    (is (null (unresolved-references g))
        "a link to a document that exists is not broken: ~a"
        (unresolved-references g))
    (is (null (relationships-from g (id doc) :rel-type :mentions))
        "and earns no edge, because :MENTIONS is declared to reach code")))


;;; ------------------------------------------------------------------
;;; Case sensitivity is the language's, not the index's (BUG-0029)
;;; ------------------------------------------------------------------
;;;
;;; The definition index is keyed on a downcased name, which is correct for
;;; Common Lisp -- the reader upcases, so `Error' and `error' are one symbol --
;;; and was applied to every language because every language indexed was Lisp.
;;; On ~/github/front-end it made three components named `Error' the top three
;;; hubs in `structure' with 116 inbound edges each, all of them
;;; `logger.error(...)' call sites. 348 edges, and the repository renders
;;; `<Error />' twice.

(defun r-js-function (graph name file &key unresolved)
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :javascript
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(test a-javascript-call-does-not-reach-a-definition-differing-only-in-case
  (let* ((g (make-graph))
         (caller (r-js-function g "logSomething" "a.js" :unresolved '("error")))
         (wrong  (r-js-function g "Error" "b.jsx")))
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "`error' and `Error' are two identifiers in JavaScript")
    (is (null (relationships-to g (id wrong) :rel-type :calls))
        "and the component collects none of them")
    (is (equal '("error") (getp caller :unresolved-calls))
        "the name is recorded unresolved, which is the honest answer")))

(test a-javascript-call-still-reaches-the-definition-it-does-name
  ;; The other half, and the one that would make the fix worthless if it
  ;; failed: exact matching must still resolve.
  (let* ((g (make-graph))
         (caller (r-js-function g "logSomething" "a.js" :unresolved '("error")))
         (callee (r-js-function g "error" "logger.js")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls))))))

(test a-lisp-call-still-folds-case-because-the-reader-does
  ;; Common Lisp is why the index folds at all, and this is the behaviour that
  ;; must survive the fix untouched. `(defun Foo ...)' and `(foo)' are one
  ;; symbol, and an index that distinguished them would resolve nothing.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("Analyze-Path")))
         (callee (r-function g "analyze-path" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls))))))

(test a-lisp-caller-does-not-reach-a-javascript-definition-by-folding
  ;; The mixed pair, which is what a repository holding both languages
  ;; produces. SAME-IDENTIFIER-P folds only when both sides fold, so the
  ;; stricter language decides -- a JavaScript definition cannot be reached by
  ;; a spelling only Lisp considers equal.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("handler")))
         (wrong  (r-js-function g "Handler" "b.js")))
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls)))
    (is (null (relationships-to g (id wrong) :rel-type :calls)))))

(test same-identifier-p-folds-only-when-both-languages-fold
  ;; Named with the double colon: the predicate is internal to loom-graph and
  ;; exporting it to be tested would widen the system's surface for the test's
  ;; convenience. The four tests above are the behaviour; this one pins the
  ;; rule they all rest on.
  (is (loom-graph::same-identifier-p "Error" "error" :lisp :lisp))
  (is (not (loom-graph::same-identifier-p "Error" "error" :javascript :javascript)))
  (is (not (loom-graph::same-identifier-p "Error" "error" :lisp :javascript))
      "the stricter side decides, so an unknown language cannot inherit
Lisp's folding by being compared against a Lisp definition")
  (is (not (loom-graph::same-identifier-p "Error" "error" :javascript :lisp)))
  (is (loom-graph::same-identifier-p "error" "error" :javascript :javascript))
  ;; A NIL language is a caller that never had one -- RESOLVE-GENERATED-
  ;; DEFINITIONS asking whether a name reaches anything at all -- and keeps the
  ;; old answer rather than acquiring a stricter one.
  (is (loom-graph::same-identifier-p "Error" "error" nil nil)))

;;; ------------------------------------------------------------------
;;; A module is a namespace (BUG-0035)
;;; ------------------------------------------------------------------
;;;
;;; After BUG-0029 removed the case fabrications, DesignHome.jsx still drew
;;; three edges to three different components named `Error' -- one of which it
;;; defines itself, at line 163, and renders twice. A name defined in the
;;; calling module shadows every other definition of it in the repository, and
;;; a name from a module nobody imported is not a candidate at all. Neither is
;;; true in Common Lisp, where a symbol is visible throughout its package
;;; however many files that package spans, so the rule is the language's.

(defun r-js-file (graph path &key imports domain)
  (let ((e (make-instance 'file-entity :name path :origin-file path
                          :properties (properties-table
                                       (list :path path :language :javascript
                                             :domain domain
                                             :import-sources imports)))))
    (add-entity graph e)
    e))

(defun r-domains (&rest entries)
  "A domain table, built the way DOMAIN-TABLE builds one."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entry entries table)
      (destructuring-bind (name &rest aliases) entry
        (setf (gethash name table)
              (list :name name :resolution :bundler
                    :extensions '(".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx")
                    :guess-extension t :index-fallback t
                    :aliases aliases))))))

(test with-no-domains-the-scope-is-what-it-has-always-been
  ;; R2's promise at this layer: a tree that declares nothing resolves exactly
  ;; as it did, and step 7 can therefore be added to RESOLVE-AND-CHECK on nine
  ;; watched trees without changing eight of them.
  (let ((g (make-graph)))
    (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget" "react"))
    (r-js-file g "ui/parts/Widget.jsx")
    (let ((scope (build-module-scope g)))
      (is (equal '("ui/parts/Widget.jsx") (gethash "ui/Home.jsx" scope))
          "the relative import resolves and the bare one does not"))))

(test an-alias-specifier-is-in-the-scope-only-when-a-domain-declares-its-key
  (let ((g (make-graph)))
    (r-js-file g "src/ui/Home.jsx" :domain :ui :imports '("utils/log.js"))
    (r-js-file g "src/utils/log.js" :domain :ui)
    (is (null (gethash "src/ui/Home.jsx" (build-module-scope g)))
        "with no domains the alias resolves to nothing, as it does today")
    (is (equal '("src/utils/log.js")
               (gethash "src/ui/Home.jsx"
                        (build-module-scope
                         g :domains (r-domains (list :ui (cons "utils" "src/utils"))))))
        "and to the file the declared key names once a domain declares it")))

(test the-second-value-carries-one-entry-per-unresolved-specifier-with-its-cause
  (let ((g (make-graph)))
    (r-js-file g "src/ui/Home.jsx" :domain :ui
               :imports '("react" "./nowhere" "server/db"))
    (r-js-file g "src/server/db.js" :domain :server)
    (multiple-value-bind (scope unresolved)
        (build-module-scope g :domains (r-domains (list :ui)
                                                  (list :server (cons "server" "src/server"))))
      (declare (ignore scope))
      (let ((misses (gethash "src/ui/Home.jsx" unresolved)))
        (is (= 3 (length misses)) "one entry per specifier that resolved to nothing")
        (is (eq :external (getf (first misses) :cause)))
        (is (eq :unresolved (getf (second misses) :cause)))
        (is (eq :out-of-domain (getf (third misses) :cause))
            "a key the server domain declares and the ui domain does not")))))

(test a-resolved-specifier-draws-an-imports-edge-and-is-not-named-unresolved
  (let* ((g (make-graph))
         (home (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget")))
         (widget (r-js-file g "ui/parts/Widget.jsx")))
    (apply-transaction g (resolve-imports g))
    (is (= 1 (length (relationships-from g (id home))))
        "one :IMPORTS edge")
    (is (equal (id widget) (to-id (first (relationships-from g (id home)))))
        "pointing at the file the specifier names")
    (is (null (getp (get-entity g (id home)) :unresolved-imports))
        "and nothing is recorded as unresolved")))

(test an-unresolved-specifier-draws-no-edge-and-is-recorded-with-its-cause
  (let* ((g (make-graph))
         (home (r-js-file g "ui/Home.jsx" :imports '("react" "./nowhere"))))
    (apply-transaction g (resolve-imports g))
    (is (null (relationships-from g (id home))) "no edge for either")
    (let ((misses (getp (get-entity g (id home)) :unresolved-imports)))
      (is (= 2 (length misses)))
      (is (eq :external (getf (first misses) :cause)))
      (is (eq :unresolved (getf (second misses) :cause))))))

(test the-unresolved-write-is-unconditional-so-an-entry-can-shrink-back-to-none
  ;; The reason the :UNRESOLVED-CALLS write gives a hundred lines down: writing
  ;; only when something failed would make the property a high-water mark, so a
  ;; file whose every specifier now resolves would keep naming the one that
  ;; used to fail.
  (let* ((g (make-graph))
         (home (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget"))))
    (apply-transaction g (resolve-imports g))
    (is (= 1 (length (getp (get-entity g (id home)) :unresolved-imports)))
        "the target does not exist yet, so it is recorded")
    (r-js-file g "ui/parts/Widget.jsx")
    (apply-transaction g (resolve-imports g))
    (is (null (getp (get-entity g (id home)) :unresolved-imports))
        "and once it does, the entry shrinks back to none")))

(test running-the-import-pass-twice-over-an-unchanged-view-changes-nothing
  ;; DEC-0003. The pass derives both outputs from :IMPORT-SOURCES and consumes
  ;; neither, so it can be re-run -- which it is, on every poll that finds any
  ;; file changed.
  (let* ((g (make-graph))
         (home (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget" "react"))))
    (r-js-file g "ui/parts/Widget.jsx")
    (apply-transaction g (resolve-imports g))
    (let ((edges (length (relationships-from g (id home))))
          (misses (getp (get-entity g (id home)) :unresolved-imports)))
      (apply-transaction g (resolve-imports g))
      (is (= edges (length (relationships-from g (id home))))
          "no edge was added by the second run")
      (is (equal misses (getp (get-entity g (id home)) :unresolved-imports))
          "and the recorded misses are the same ones"))))

(test resolve-calls-handed-a-scope-draws-what-it-draws-building-its-own
  ;; What makes step 7's single build safe rather than assumed: the pass will
  ;; be handed a scope built once, beside the unresolved specifiers, instead of
  ;; building its own inside CALLABLE-LOOKUP.
  (let ((own nil) (handed nil))
    (let ((g (make-graph)))
      (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget"))
      (r-js-file g "ui/parts/Widget.jsx")
      (r-js-function g "render" "ui/Home.jsx" :unresolved '("Widget"))
      (r-js-function g "Widget" "ui/parts/Widget.jsx")
      (setf own (length (resolve-calls g))))
    (let ((g (make-graph)))
      (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget"))
      (r-js-file g "ui/parts/Widget.jsx")
      (r-js-function g "render" "ui/Home.jsx" :unresolved '("Widget"))
      (r-js-function g "Widget" "ui/parts/Widget.jsx")
      (setf handed (length (resolve-calls g :module-scope (build-module-scope g)))))
    (is (= own handed) "~a ops building its own, ~a handed one" own handed)
    (is (plusp own) "and the fixture actually resolves something")))

(test a-definition-in-the-calling-file-shadows-every-other-of-that-name
  (let* ((g (make-graph))
         (caller (r-js-function g "render" "ui/Home.jsx" :unresolved '("Widget")))
         (local  (r-js-function g "Widget" "ui/Home.jsx"))
         (far    (r-js-function g "Widget" "ui/Other.jsx")))
    (r-js-file g "ui/Home.jsx")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id local))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "one edge, to the definition in the caller's own file")
    (is (null (relationships-to g (id far) :rel-type :calls))
        "and none at all to the same name in another module")))

(test an-imported-module-is-in-scope-and-an-unimported-one-is-not
  (let* ((g (make-graph))
         (caller (r-js-function g "render" "ui/Home.jsx" :unresolved '("Widget")))
         (wanted (r-js-function g "Widget" "ui/parts/Widget.jsx"))
         (other  (r-js-function g "Widget" "ui/Other.jsx")))
    (r-js-file g "ui/Home.jsx" :imports '("./parts/Widget"))
    (r-js-file g "ui/parts/Widget.jsx")
    (r-js-file g "ui/Other.jsx")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "the specifier resolves through the extension the file actually has")
    (is (null (relationships-to g (id other) :rel-type :calls)))))

(test a-specifier-can-name-a-directory-index
  (let* ((g (make-graph))
         (caller (r-js-function g "render" "ui/Home.jsx" :unresolved '("Widget")))
         (wanted (r-js-function g "Widget" "ui/parts/index.js")))
    (r-js-file g "ui/Home.jsx" :imports '("./parts"))
    (r-js-file g "ui/parts/index.js")
    (r-js-function g "Widget" "ui/Other.jsx")
    (r-js-file g "ui/Other.jsx")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls))))))

(test a-specifier-climbing-out-of-its-directory-resolves
  (let* ((g (make-graph))
         (caller (r-js-function g "render" "ui/edit/pages/Home.jsx" :unresolved '("Widget")))
         (wanted (r-js-function g "Widget" "ui/common/Widget.jsx")))
    (r-js-file g "ui/edit/pages/Home.jsx" :imports '("../../common/Widget"))
    (r-js-file g "ui/common/Widget.jsx")
    (r-js-function g "Widget" "ui/Other.jsx")
    (r-js-file g "ui/Other.jsx")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls))))))

(test a-name-no-tier-governs-keeps-the-candidates-it-had
  ;; The rule may only ever reduce a candidate set, never empty one. A bare
  ;; call to a name defined in two modules the caller neither holds nor imports
  ;; is the shape nothing here governs, and it must survive untouched.
  ;;
  ;; `commit' and not `log.commit': BUG-0036 gave a member call its receiver,
  ;; so the name that arrives here with nothing to narrow it is the bare one.
  (let* ((g (make-graph))
         (caller (r-js-function g "run" "ui/Home.jsx" :unresolved '("commit")))
         (one    (r-js-function g "commit" "a/Log.js"))
         (two    (r-js-function g "commit" "b/Store.js")))
    (r-js-file g "ui/Home.jsx")
    (r-js-file g "a/Log.js")
    (r-js-file g "b/Store.js")
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "the caller takes no direct edge, which is REQ-0015's refusal")
    (dolist (target (list one two))
      (is (relationships-to g (id target) :rel-type :calls)
          "and both candidates are still reached, through the call site"))))

(test a-bare-specifier-narrows-nothing
  ;; `react' names a package outside the tree and `@/x' needs a bundler
  ;; configuration Loom does not read. Both resolve to nothing, which must
  ;; leave the call exactly as unnarrowed as it is today rather than making
  ;; the importing file appear to import nothing at all.
  (let* ((g (make-graph))
         (caller (r-js-function g "run" "ui/Home.jsx" :unresolved '("Widget")))
         (one    (r-js-function g "Widget" "a/One.jsx"))
         (two    (r-js-function g "Widget" "b/Two.jsx")))
    (r-js-file g "ui/Home.jsx" :imports '("react" "@/components/Widget"))
    (r-js-file g "a/One.jsx")
    (r-js-file g "b/Two.jsx")
    (apply-transaction g (resolve-calls g))
    (dolist (target (list one two))
      (is (relationships-to g (id target) :rel-type :calls)
          "both are still candidates, because nothing was learned"))))

(test a-lisp-caller-is-untouched-by-module-scope
  ;; The guard. A Common Lisp symbol is visible throughout its package however
  ;; many files that package spans, so a file boundary tells resolution
  ;; nothing -- and narrowing on one would silently delete the cross-file edges
  ;; RESOLVE-CALLS exists to draw.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee")))
         (callee (r-function g "callee" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "the edge across a file boundary is the whole point of the pass")))

(test resolve-module-specifier-answers-against-the-index-and-not-the-disk
  (let ((known (make-hash-table :test #'equal)))
    (setf (gethash "ui/parts/Widget.jsx" known) t
          (gethash "ui/parts/index.js" known) t)
    (is (equal "ui/parts/Widget.jsx"
               (loom-graph::resolve-module-specifier "./parts/Widget" "ui/Home.jsx" known)))
    (is (equal "ui/parts/index.js"
               (loom-graph::resolve-module-specifier "./parts" "ui/Home.jsx" known)))
    (is (equal "ui/parts/Widget.jsx"
               (loom-graph::resolve-module-specifier "../parts/Widget" "ui/edit/Home.jsx" known)))
    (is (null (loom-graph::resolve-module-specifier "react" "ui/Home.jsx" known))
        "a bare specifier names something outside the tree")
    (is (null (loom-graph::resolve-module-specifier "./nowhere" "ui/Home.jsx" known))
        "and a relative one naming no indexed file resolves to nothing rather
than to a path nobody holds")))


(defun known-table (&rest paths)
  (let ((known (make-hash-table :test #'equal)))
    (dolist (p paths known) (setf (gethash p known) t))))

(defun bundler-domain (&rest aliases)
  (list :extensions '(".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx")
        :guess-extension t :index-fallback t
        :resolution :bundler :aliases aliases))

(test an-alias-key-rewrites-a-specifier-and-resolves-it
  ;; The 1320 of front-end's 1885 in-tree imports REQ-0063 is about. Every one
  ;; is alias-rooted and resolved to nothing because the resolver handled only
  ;; specifiers beginning with a dot.
  (let ((known (known-table "src/utils/wrappedLogger.js")))
    (is (equal "src/utils/wrappedLogger.js"
               (loom-graph::resolve-module-specifier
                "utils/wrappedLogger.js" "src/ui/Home.jsx" known
                :domain (bundler-domain (cons "utils" "src/utils")))))))

(test the-longer-of-two-overlapping-alias-keys-wins
  (let ((known (known-table "src/ui/widgets/Button.jsx" "src/other/widgets/Button.jsx")))
    (is (equal "src/ui/widgets/Button.jsx"
               (loom-graph::resolve-module-specifier
                "ui/widgets/Button.jsx" "src/main.js" known
                :domain (bundler-domain (cons "ui" "src/other")
                                        (cons "ui/widgets" "src/ui/widgets")))))))

(test an-alias-key-does-not-claim-a-longer-word-it-merely-prefixes
  ;; `utils' must not claim `utilsx/thing'.
  (let ((known (known-table "src/utils/thing.js")))
    (is (null (loom-graph::resolve-module-specifier
               "utilsx/thing" "src/main.js" known
               :domain (bundler-domain (cons "utils" "src/utils")))))))

(test one-specifier-answers-three-ways-under-the-three-presets
  ;; CON-0003 at the preset: three answers, not three passes. The same
  ;; specifier against the same index, resolving differently because the
  ;; toolchain differs -- which is the whole reason the presets are data.
  (let ((known (known-table "src/mod.js" "src/dir/index.js")))
    ;; Built the way DOMAIN-TABLE builds one, :RESOLUTION included, because
    ;; that key is what tells an expanded plist from a caller who named no
    ;; domain -- and node-esm's empty extension list cannot.
    (flet ((try (spec name extensions guess fallback)
             (loom-graph::resolve-module-specifier
              spec "src/main.js" known
              :domain (list :resolution name :extensions extensions
                            :guess-extension guess :index-fallback fallback
                            :aliases '()))))
      (is (equal "src/mod.js"
                 (try "./mod" :bundler '(".js" ".jsx") t t))
          "bundler guesses the extension")
      (is (null (try "./mod" :node-esm '() nil nil))
          "node-esm requires the specifier to name the file")
      (is (equal "src/dir/index.js"
                 (try "./dir" :commonjs '(".js" ".json" ".node") t t))
          "commonjs falls back to an index file")
      (is (null (try "./dir" :node-esm '() nil nil))
          "and node-esm does not"))))

(test each-of-the-four-causes-is-returned-for-a-specifier-built-to-produce-it
  ;; The half a reader acts on. An alias nobody declared and a path that is
  ;; simply wrong need different repairs, and until now both were a silence.
  (let ((known (known-table "src/utils/real.js")))
    (flet ((cause (spec &rest args)
             (nth-value 1 (apply #'loom-graph::resolve-module-specifier
                                 spec "src/main.js" known args))))
      (is (eq :external (cause "react" :domain (bundler-domain)))
          "not relative, no alias key anywhere")
      (is (eq :out-of-domain
              (cause "server/db" :domain (bundler-domain)
                                 :sibling-aliases (list (cons "server" "src/server"))))
          "a key another domain declares and this one does not")
      (is (eq :unclaimed-target
              (cause "utils/missing" :domain (bundler-domain (cons "utils" "src/utils"))))
          "the alias rewrote it and the index holds nothing under the result")
      (is (eq :unresolved (cause "./nowhere" :domain (bundler-domain)))
          "relative, and no candidate under the preset is indexed"))))

(test an-alias-target-outside-the-declaring-domains-own-root-resolves
  ;; All 32 of front-end's server/ aliases point under src/, so a resolver that
  ;; required the target to lie under the declaring domain's root would resolve
  ;; none of them.
  (let ((known (known-table "src/shared/types.js")))
    (is (equal "src/shared/types.js"
               (loom-graph::resolve-module-specifier
                "shared/types.js" "server/api.js" known
                :domain (append (list :root "server/")
                                (bundler-domain (cons "shared" "src/shared"))))))))

;;; ------------------------------------------------------------------
;;; A member call names a receiver (BUG-0036)
;;; ------------------------------------------------------------------
;;;
;;; `log.commit()' contributed COMMIT, which matched every plain function of
;;; that name in the repository and no method at all, since a method entity is
;;; named Class.method. Module scope cannot narrow it -- a property is not a
;;; module binding -- so BUG-0035's two tiers both declined by design and the
;;; name reached resolution with nothing on it. On ~/github/front-end that was
;;; 40 of 50 fan-outs, and the largest single one was `set.persist()' pointing
;;; at two test-local `function persist' and one arrow in a mock.
;;;
;;; The extractor now records the receiver the source wrote, and resolution
;;; reads it back: the receiver names the class, or it does not and the
;;; property is what is left to go on.

(defun r-js-method (graph name file &key unresolved)
  (let ((e (make-instance 'method-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :javascript
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(test member-call-parts-reads-one-dot-and-refuses-the-rest
  (multiple-value-bind (receiver property)
      (loom-graph:member-call-parts "log.commit")
    (is (equal "log" receiver))
    (is (equal "commit" property)))
  (is (null (loom-graph:member-call-parts "commit"))
      "a bare call is not a member call")
  (is (null (loom-graph:member-call-parts "obj.a.b"))
      "two dots means the receiver was an expression, and the extractor
reports the property alone for that case")
  (is (null (loom-graph:member-call-parts ".commit")))
  (is (null (loom-graph:member-call-parts "log."))))

(test a-receiver-naming-the-class-resolves-to-that-class-method
  ;; `this.commit()' inside GestureLog, which the extractor records as
  ;; GestureLog.commit because the enclosing class is not a guess.
  (let* ((g (make-graph))
         (caller (r-js-method g "GestureLog.record" "a/GestureLog.js"
                              :unresolved '("GestureLog.commit")))
         (wanted (r-js-method g "GestureLog.commit" "a/GestureLog.js"))
         (other  (r-js-method g "CircleGraphic.commit" "b/CircleGraphic.js"))
         (plain  (r-js-function g "commit" "c/util.js")))
    (r-js-file g "a/GestureLog.js")
    (r-js-file g "b/CircleGraphic.js")
    (r-js-file g "c/util.js")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "one edge, to the method of the class the receiver names")
    (is (null (relationships-to g (id other) :rel-type :calls))
        "and none to the other class's method of the same property")
    (is (null (relationships-to g (id plain) :rel-type :calls))
        "nor to the plain function, which a property access cannot reach")))

(test a-member-call-fans-out-over-methods-and-never-over-functions
  ;; The population BUG-0036 measured. `set.persist()' names no class, so the
  ;; property is all there is: every method of it is a candidate, at 1/N, and
  ;; the plain functions that used to collect these edges get none.
  (let* ((g (make-graph))
         (caller (r-js-function g "run" "ui/Home.jsx" :unresolved '("set.persist")))
         (one    (r-js-method g "TypeSet.persist" "core/TypeSet.js"))
         (two    (r-js-method g "WorkingSet.persist" "core/WorkingSet.js"))
         (plain  (r-js-function g "persist" "test/reload.test.js")))
    (r-js-file g "ui/Home.jsx")
    (r-js-file g "core/TypeSet.js")
    (r-js-file g "core/WorkingSet.js")
    (r-js-file g "test/reload.test.js")
    (apply-transaction g (resolve-calls g))
    (let ((edges (relationships-from g (id caller) :rel-type :calls)))
      (is (equal (sort (list (id one) (id two)) #'string<)
                 (sort (mapcar #'to-id edges) #'string<))
          "both methods, and only the methods")
      (is (every (lambda (r) (< (confidence r) 0.51)) edges)
          "each at 1/N, which is the recorded guess CON-0001 asks for"))
    (is (null (relationships-to g (id plain) :rel-type :calls))
        "the plain function collects nothing: a property is not a module
binding, and this edge was the defect")))

(test a-member-call-with-no-method-of-that-property-falls-back-to-the-name
  ;; The namespace import -- `import * as api' then `api.fetchGame()'. The
  ;; receiver is a module rather than an object, the property really is a plain
  ;; function, and this is the answer the call had before BUG-0036.
  (let* ((g (make-graph))
         (caller (r-js-function g "load" "ui/Home.jsx" :unresolved '("api.fetchGame")))
         (wanted (r-js-function g "fetchGame" "data/api.js")))
    (r-js-file g "ui/Home.jsx" :imports '("../data/api"))
    (r-js-file g "data/api.js")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "one edge, and the module scope BUG-0035 added still applies to it")))

(test a-lisp-caller-never-reads-a-dot-as-a-receiver
  ;; The gate. A dot in a Common Lisp symbol is a character in a name, so the
  ;; member-call tiers are asked only where MODULE-SCOPED-LANGUAGE-P says the
  ;; caller is written in a language that has properties.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("log.commit")))
         (method (r-js-method g "GestureLog.commit" "b/GestureLog.js")))
    (r-js-file g "b/GestureLog.js")
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "the name is a symbol Loom does not hold, not a property access")
    (is (null (relationships-to g (id method) :rel-type :calls)))
    (is (equal '("log.commit") (getp caller :unresolved-calls))
        "and it is recorded unresolved rather than guessed at")))


;;; ------------------------------------------------------------------
;;; None and several are two answers (REQ-0030, DES-0029)
;;; ------------------------------------------------------------------
;;;
;;; RESOLVE-ONE computed the candidate set, found several, returned NIL, and
;;; RESOLVE-DOCUMENT-LINKS pushed the name onto :UNRESOLVED-REFERENCES beside
;;; the names that matched nothing. On game-server, writing the four documents
;;; of one change, every name most central to it was ambiguous and all four
;;; were reported as rot. On Loom 7 of 15 were.

(defun r-decision (graph doc-id &key affects refines)
  (let ((e (make-instance 'decision-entity :name doc-id
                          :origin-file (format nil "docs/design/~a.yaml" doc-id)
                          :properties (properties-table
                                       (list :path (format nil "docs/design/~a.yaml" doc-id)
                                             :doc-id doc-id
                                             :affects affects
                                             :refines refines)))))
    (add-entity graph e)
    e))

(test resolve-one-hands-back-the-candidates-it-declined-over
  (let* ((g (make-graph))
         (one (r-function g "check-database" "server/server.lisp"))
         (two (r-function g "check-database" "game/test/api.lisp"))
         (index (loom-graph::linkable-index g)))
    (multiple-value-bind (target candidates)
        (loom-graph::resolve-one index "check-database")
      (is (null target) "an ambiguous name still resolves to nothing")
      (is (equal (sort (list (id one) (id two)) #'string<)
                 (sort (mapcar #'id candidates) #'string<))
          "and the set it declined over is what the caller needs"))
    (multiple-value-bind (target candidates)
        (loom-graph::resolve-one index "no-such-name")
      (is (null target))
      (is (null candidates)
          "a name that matched nothing declined over nothing, which is the
distinction this whole change is"))))

(test the-interface-clause-still-answers-and-declines-over-nothing
  ;; The exception RESOLVE-ONE has always made, and it must not start looking
  ;; like an ambiguity: a generic and its methods are one protocol.
  (let* ((g (make-graph))
         (generic (r-interface g "analyze-file" "a.lisp"))
         (index (progn (r-method g "analyze-file" "b.lisp")
                       (r-method g "analyze-file" "c.lisp")
                       (loom-graph::linkable-index g))))
    (multiple-value-bind (target candidates)
        (loom-graph::resolve-one index "analyze-file")
      (is (eq generic target))
      (is (null candidates)))))

(test a-document-may-name-an-entity-by-the-id-find-prints
  (let* ((g (make-graph))
         (wanted (r-function g "check-database" "server/server.lisp"))
         (other  (r-function g "check-database" "game/test/api.lisp"))
         (doc (r-decision g "DES-0001" :affects (list (id wanted)))))
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (equal (list (id wanted))
               (mapcar #'to-id (relationships-from g (id doc) :rel-type :decides)))
        "the id resolves to exactly the entity it names")
    (is (null (relationships-to g (id other) :rel-type :decides))
        "and to no other candidate of the same name")
    (is (null (getp doc :unresolved-references)))
    (is (null (getp doc :ambiguous-references))
        "an id is never ambiguous")))

(test an-id-that-names-nothing-rots-like-a-name-that-names-nothing
  ;; REQ-0030 R4. The escape hatch may not become a way to assert an edge to
  ;; something that is not there.
  (let* ((g (make-graph))
         (doc (r-decision g "DES-0001"
                          :affects '("function:src/nowhere.lisp:gone"))))
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (null (relationships-from g (id doc) :rel-type :decides)))
    (is (equal '("function:src/nowhere.lisp:gone")
               (getp doc :unresolved-references)))
    (is (null (getp doc :ambiguous-references)))))

(test an-ambiguous-reference-is-recorded-with-its-candidates-and-not-as-rot
  (let* ((g (make-graph))
         (one (r-function g "check-database" "server/server.lisp"))
         (two (r-function g "check-database" "game/test/api.lisp"))
         (doc (r-decision g "DES-0001" :affects '("check-database" "missing-name"))))
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (null (relationships-from g (id doc) :rel-type :decides))
        "still no edge: picking one would be the fabrication CON-0001 forbids")
    (is (equal '("missing-name") (getp doc :unresolved-references))
        "the name that matched nothing is the only rot, where both used to be")
    (let ((entries (getp doc :ambiguous-references)))
      (is (= 1 (length entries)))
      (is (equal "check-database" (getf (first entries) :name)))
      (is (equal (sort (list (id one) (id two)) #'string<)
                 (sort (copy-list (getf (first entries) :candidates)) #'string<))
          "the ids are what an author pastes back into the field"))
    (let ((reported (ambiguous-references g)))
      (is (= 1 (length reported)))
      (is (equal "check-database" (getf (first reported) :name)))
      (is (equal "DES-0001" (getf (first reported) :document))))))

(test the-two-reference-properties-are-rewritten-from-scratch-each-pass
  ;; DEC-0003. A pass that consumed its own input could not be re-run, and an
  ;; entry destroyed by a retract would never return.
  (let* ((g (make-graph))
         (doc (r-decision g "DES-0001" :affects '("check-database"))))
    (r-function g "check-database" "server/server.lisp")
    (r-function g "check-database" "game/test/api.lisp")
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (= 1 (length (getp doc :ambiguous-references))))
    (apply-transaction g (resolve-document-links g :workspace-id "w"))
    (is (= 1 (length (getp doc :ambiguous-references)))
        "asked twice, answered once")))

;;; ------------------------------------------------------------------
;;; Python specifiers (DES-0053 D5)
;;; ------------------------------------------------------------------
;;;
;;; The fixtures are shaped like lfia-accounting: functions/ is a directory
;;; with no __init__.py that Firebase runs main.py from, functions/ledger/ is a
;;; package, and functions/tests/ imports `ledger.refs', which resolves only
;;; when functions/ is on sys.path.

(defun r-py-file (graph path &key imports bindings domain)
  (let ((e (make-instance 'file-entity :name path :origin-file path
                          :properties (properties-table
                                       (list :path path :language :python
                                             :domain domain
                                             :import-sources imports
                                             :import-bindings bindings)))))
    (add-entity graph e)
    e))

(defun r-py-function (graph name file &key unresolved)
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :python
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(defun py-resolve (specifier importer known &key domain)
  "RESOLVE-PYTHON-SPECIFIER over the paths KNOWN, as two values."
  (loom-graph::resolve-python-specifier
   specifier importer (loom-graph::make-python-index (apply #'known-table known))
   :domain domain))

(defparameter *lfia-paths*
  '("functions/main.py" "functions/config.py" "functions/sheets.py"
    "functions/ledger/__init__.py" "functions/ledger/posting.py"
    "functions/ledger/hashing.py" "functions/ledger/dates.py"
    "functions/ledger/refs.py" "functions/tests/test_refs.py"))

(test a-script-directory-is-a-root-when-it-is-not-a-package
  ;; main.py imports `config' by bare name because Firebase runs it from
  ;; functions/, which holds no __init__.py. Root 1.
  (is (equal "functions/config.py"
             (py-resolve "config" "functions/main.py" *lfia-paths*))))

(test the-parent-of-the-outermost-package-is-a-root
  ;; ledger/posting.py's `from ledger.hashing import content_hash`. ledger/ is a
  ;; package, so its own directory is not a root and its parent is. Root 2.
  (is (equal "functions/ledger/hashing.py"
             (py-resolve "ledger.hashing" "functions/ledger/posting.py" *lfia-paths*))))

(test a-relative-specifier-starts-in-the-importers-directory
  (is (equal "functions/ledger/posting.py"
             (py-resolve ".posting" "functions/ledger/__init__.py" *lfia-paths*)))
  (is (equal "functions/ledger/__init__.py"
             (py-resolve "." "functions/ledger/posting.py" *lfia-paths*))
      "a bare dot names the importer's own package"))

(test each-dot-after-the-first-climbs-one-directory
  ;; DES-0053 D5: "climbs one directory per dot after the first". PLAN-0056's
  ;; wording, that `..x' climbs two directories, disagrees with the design; the
  ;; design is Python's own rule and is what this asserts.
  (let ((known '("a/x.py" "a/b/y.py" "a/b/c/m.py")))
    (is (equal "a/b/y.py" (py-resolve "..y" "a/b/c/m.py" known)) "two dots, one climb")
    (is (equal "a/x.py" (py-resolve "...x" "a/b/c/m.py" known)) "three dots, two climbs")
    (is (eq :unresolved (nth-value 1 (py-resolve "....x" "a/m.py" '("a/m.py"))))
        "and climbing past the root resolves nothing")))

(test a-dotted-name-finds-a-package-when-there-is-no-module
  (is (equal "functions/ledger/__init__.py"
             (py-resolve "ledger" "functions/main.py" *lfia-paths*)))
  (is (equal "pkg/sub/__init__.py"
             (py-resolve "pkg.sub" "main.py" '("main.py" "pkg/__init__.py" "pkg/sub/__init__.py")))
      "a/b names a/b/__init__.py when there is no a/b.py"))

(test a-module-no-root-reaches-is-unrooted-until-a-domain-names-its-root
  ;; functions/tests' `from ledger.refs import ...'. The tests directory holds
  ;; no ledger, and ledger is indexed one level up: that is not an external
  ;; library, and the cause says which declaration is missing.
  (multiple-value-bind (target cause)
      (py-resolve "ledger.refs" "functions/tests/test_refs.py" *lfia-paths*)
    (is (null target))
    (is (eq :unrooted cause)))
  (is (equal "functions/ledger/refs.py"
             (py-resolve "ledger.refs" "functions/tests/test_refs.py" *lfia-paths*
                         :domain (list :name :functions :root "functions/")))
      "the domain root is the third root"))

(test the-implicit-default-domains-root-is-not-a-third-import-root
  ;; DES-0053 D5: the third root is a declared one. The default domain has root
  ;; \"\" and exists whether or not anything declared it, so it must not make
  ;; tools/x.py's `import config' reach the repository-root config.py.
  (let ((known '("config.py" "tools/x.py")))
    (is (eq :unrooted
            (nth-value 1 (py-resolve "config" "tools/x.py" '("config.py" "tools/x.py" "tools/y.py")
                                     :domain (list :name :default :root ""))))
        "tools/ is a script directory, so config is looked for there only")
    (is (equal "config.py"
               (py-resolve "config" "tools/x.py" known
                           :domain (list :name :app :root "")))
        "a declared domain whose root is the repository root does reach it")))

(test a-library-the-tree-does-not-hold-is-external
  (multiple-value-bind (target cause)
      (py-resolve "googleapiclient.discovery" "functions/sheets.py" *lfia-paths*)
    (is (null target))
    (is (eq :external cause))))

(test a-held-package-missing-the-submodule-is-unresolved-not-external
  ;; The in-tree miss a reader acts on: ledger is here, ledger.missing is not.
  (is (eq :unresolved
          (nth-value 1 (py-resolve "ledger.missing" "functions/main.py" *lfia-paths*)))))

(test a-python-resolver-answers-against-the-index-and-not-the-disk
  ;; The Python twin of RESOLVE-MODULE-SPECIFIER-ANSWERS-AGAINST-THE-INDEX-AND-
  ;; NOT-THE-DISK, and the proof that loom-graph reads no filesystem here.
  ;; tools/test/service.py exists on disk as this is written and is absent from
  ;; the table, so `import service' must not resolve; add it and it does.
  (is (probe-file (merge-pathnames "tools/test/service.py"
                                   (asdf:system-relative-pathname :loom-graph "../../")))
      "precondition: the file this test pretends is unindexed exists on disk")
  (is (eq :external
          (nth-value 1 (py-resolve "service" "tools/test/acceptance.py"
                                   '("tools/test/acceptance.py")))))
  (is (equal "tools/test/service.py"
             (py-resolve "service" "tools/test/acceptance.py"
                         '("tools/test/acceptance.py" "tools/test/service.py")))))

(defun py-scope (graph &key domains)
  (loom-graph:build-module-scope graph :domains domains))

(test from-import-of-a-submodule-adds-the-file-to-the-importers-scope
  ;; `from ledger import dates' reads ledger/dates.py when ledger/__init__.py
  ;; does not define dates. Read from :IMPORT-BINDINGS, module level only.
  (let ((g (make-graph)))
    (dolist (path *lfia-paths*)
      (unless (string= path "functions/main.py") (r-py-file g path)))
    (r-py-file g "functions/main.py"
               :imports '("ledger")
               :bindings '((:local "dates" :specifier "ledger" :name "dates")
                           (:local "nothing" :specifier "ledger" :name "nothing")))
    (let ((scope (py-scope g)))
      (is (equal '("functions/ledger/dates.py" "functions/ledger/__init__.py")
                 (gethash "functions/main.py" scope))
          "the package, and the submodule the from-import also names; a name that
is no submodule adds nothing"))))

(test a-python-caller-sees-its-own-files-definition-before-another-files
  ;; VISIBLE-CANDIDATES' local tier, which applies now that :PYTHON is
  ;; module-scoped. Without it `read_tab' from main.py fans out across both.
  (let* ((g (make-graph))
         (caller (r-py-function g "seed" "functions/main.py" :unresolved '("read_tab")))
         (local  (r-py-function g "read_tab" "functions/main.py"))
         (far    (r-py-function g "read_tab" "functions/sheets.py")))
    (r-py-file g "functions/main.py")
    (r-py-file g "functions/sheets.py")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id local))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "one edge, to the definition in the caller's own file")
    (is (null (relationships-to g (id far) :rel-type :calls)))))

(test a-python-importer-is-resolved-by-pythons-rules-and-a-javascript-one-is-not
  ;; The dispatch on :LANGUAGE. `config' is a sibling script to Python and an
  ;; external package to the bundler, and both answers hold in one graph.
  (let ((g (make-graph)))
    (r-py-file g "app/main.py" :imports '("config"))
    (r-py-file g "app/config.py")
    (r-js-file g "app/main.js" :imports '("config"))
    (r-js-file g "app/config.js")
    (multiple-value-bind (scope unresolved) (py-scope g)
      (is (equal '("app/config.py") (gethash "app/main.py" scope)))
      (is (null (gethash "app/main.py" unresolved)))
      (is (null (gethash "app/main.js" scope))
          "a bare specifier is a package to the bundler")
      (is (equal '((:specifier "config" :cause :external))
                 (gethash "app/main.js" unresolved))))))

(test an-unrooted-python-import-is-recorded-with-its-cause
  (let ((g (make-graph)))
    (dolist (path *lfia-paths*)
      (unless (string= path "functions/tests/test_refs.py") (r-py-file g path)))
    (r-py-file g "functions/tests/test_refs.py" :imports '("ledger.refs" "pytest"))
    (multiple-value-bind (scope unresolved) (py-scope g)
      (declare (ignore scope))
      (is (equal '((:specifier "ledger.refs" :cause :unrooted)
                   (:specifier "pytest" :cause :external))
                 (gethash "functions/tests/test_refs.py" unresolved))))))

;;; ------------------------------------------------------------------
;;; The :IMPORTED-CALLS tier (DES-0053 D6)
;;; ------------------------------------------------------------------
;;;
;;; The graph is hand-built and shaped like lfia-accounting, whose three wrong
;;; fan-outs on `build' are what the design measured. Each test is the failure
;;; the tier exists to prevent.

(defun r-py-definition (graph type name file &key bases)
  "A Python :FUNCTION, :METHOD, :CLASS or :VARIABLE named NAME in FILE. BASES
are a class's :SUPERCLASS-NAMES."
  (let ((e (make-instance (ecase type
                            (:function 'function-entity)
                            (:method 'method-entity)
                            (:class 'class-entity)
                            (:variable 'variable-entity))
                          :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :python
                                             :superclass-names bases)))))
    (add-entity graph e)
    e))

(defun r-py-caller (graph name file &key imported-calls call-names)
  "A Python function whose calls are all named by IMPORTED-CALLS, each a plist
of :SPECIFIER, :PATH and :LINE."
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :python
                                             :call-names call-names
                                             :imported-calls imported-calls)))))
    (add-entity graph e)
    e))

(defun called-ids (graph entity)
  (mapcar #'to-id (relationships-from graph (id entity) :rel-type :calls)))

(defun r-resolve (graph &key domains)
  (apply-transaction graph (resolve-calls graph :domains domains)))

(defun r-py-tree (graph &rest paths)
  "A :FILE for each of PATHS that has none yet."
  (dolist (path paths)
    (unless (find path (entities-of-type graph :file) :key #'name :test #'string=)
      (r-py-file graph path))))

(test a-call-through-an-external-import-reaches-nothing-and-says-why
  ;; sheets.py: `from googleapiclient.discovery import build', then build(...).
  ;; Bare, BUILD fans out to cross_check.build and simplifi.build at 1/2 each,
  ;; because no tier applies and VISIBLE-CANDIDATES never empties a set. Bound
  ;; to its import it is external and draws no edge at all.
  (let* ((g (make-graph))
         (cross (r-py-definition g :function "build" "functions/cross_check.py"))
         (simplifi (r-py-definition g :function "build" "functions/simplifi.py"))
         (bound (r-py-caller g "_service" "functions/sheets.py"
                             :imported-calls '((:specifier "googleapiclient.discovery"
                                                :path ("build") :line 11))))
         (bare (r-py-caller g "_service_bare" "functions/sheets.py"
                            :call-names '("build"))))
    (r-py-tree g "functions/sheets.py" "functions/cross_check.py" "functions/simplifi.py")
    (r-resolve g)
    (is (null (called-ids g bound)) "no direct edge")
    (is (null (relationships-from g (id bound) :rel-type :contains))
        "and no call site, which is what a fan-out would have minted")
    (is (equal '((:specifier "googleapiclient.discovery" :path ("build") :line 11
                  :cause :external))
               (getp bound :unresolved-imported-calls)))
    ;; The bare spelling used to be the control here: it fanned out to both
    ;; builds at 1/2. BUG-0070 closed that, since a bare name no import binds
    ;; cannot reach another file, so the control now asserts the same silence
    ;; and the bound caller's own assertions above carry the test.
    (dolist (target (list cross simplifi))
      (is (null (relationships-to g (id target) :rel-type :calls))
          "neither the bare call nor the bound one reaches another file's build"))
    (is (null (called-ids g bare)))))

(test a-module-attribute-call-reaches-the-module-and-not-the-callers-own-file
  ;; main.py:56 calls sheets.read_tab(...) from seed_accounts_map. main.py also
  ;; defines its own HTTP function read_tab, which the bare spelling matched on
  ;; the local tier.
  (let* ((g (make-graph))
         (caller (r-py-caller g "seed_accounts_map" "functions/main.py"
                              :imported-calls '((:specifier "sheets"
                                                 :path ("read_tab") :line 56))))
         (own (r-py-definition g :function "read_tab" "functions/main.py"))
         (wanted (r-py-definition g :function "read_tab" "functions/sheets.py")))
    (r-py-tree g "functions/main.py" "functions/sheets.py")
    (r-resolve g)
    (is (equal (list (id wanted)) (called-ids g caller)))
    (is (null (relationships-to g (id own) :rel-type :calls)))
    (is (null (getp caller :unresolved-imported-calls)))))

(test a-same-named-function-in-another-file-is-the-edge-and-not-the-removed-caller
  ;; acceptance.py:250 calls service.watched_repositories() from its own
  ;; watched_repositories. CALL-TARGETS removes the caller from the candidates,
  ;; so the bare spelling lost the real edge into tools/test/service.py.
  (let* ((g (make-graph))
         (caller (r-py-caller g "watched_repositories" "tools/test/acceptance.py"
                              :imported-calls '((:specifier "service"
                                                 :path ("watched_repositories")
                                                 :line 250))))
         (target (r-py-definition g :function "watched_repositories" "tools/test/service.py")))
    (r-py-tree g "tools/test/acceptance.py" "tools/test/service.py")
    (r-resolve g)
    (is (equal (list (id target)) (called-ids g caller)))))

(test a-call-follows-a-reexport-through-the-package-init
  ;; ledger/__init__.py writes `from .posting import post'. The definition is
  ;; one file further than the import names.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "ledger" :path ("post")
                                                 :line 9))))
         (post (r-py-definition g :function "post" "functions/ledger/posting.py")))
    (r-py-tree g "functions/main.py" "functions/ledger/posting.py")
    (r-py-file g "functions/ledger/__init__.py"
               :bindings '((:local "post" :specifier ".posting" :name "post")))
    (r-resolve g)
    (is (equal (list (id post)) (called-ids g caller)))))

(test calling-a-class-reaches-its-init
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "ledger.refs"
                                                 :path ("RefIssuer") :line 3)
                                                (:specifier "ledger.refs"
                                                 :path ("Plain") :line 4))))
         (init (r-py-definition g :method "RefIssuer.__init__" "functions/ledger/refs.py")))
    (r-py-definition g :class "RefIssuer" "functions/ledger/refs.py")
    (r-py-definition g :class "Plain" "functions/ledger/refs.py")
    (r-py-tree g "functions/main.py" "functions/ledger/refs.py"
               "functions/ledger/__init__.py")
    (r-resolve g)
    (is (equal (list (id init)) (called-ids g caller)))
    (is (equal '(:not-callable)
               (mapcar (lambda (m) (getf m :cause)) (getp caller :unresolved-imported-calls)))
        "a class with no __init__ in its own file is not callable here")))

(test a-class-method-is-reached-through-the-class
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "rules" :path ("Rules" "find")
                                                 :line 3))))
         (method (r-py-definition g :method "Rules.find" "functions/rules.py")))
    (r-py-definition g :class "Rules" "functions/rules.py")
    (r-py-tree g "functions/main.py" "functions/rules.py")
    (r-resolve g)
    (is (equal (list (id method)) (called-ids g caller)))))

(test two-files-re-exporting-each-other-end-as-a-miss-not-a-loop
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "main.py"
                              :imported-calls '((:specifier "a" :path ("x") :line 1)))))
    (r-py-file g "main.py")
    (r-py-file g "a.py" :bindings '((:local "x" :specifier "b" :name "x")))
    (r-py-file g "b.py" :bindings '((:local "x" :specifier "a" :name "x")))
    (r-resolve g)
    (is (null (called-ids g caller)))
    (is (equal '(:missing-in-target)
               (mapcar (lambda (m) (getf m :cause)) (getp caller :unresolved-imported-calls))))))

(test a-renamed-target-is-missing-in-target-and-is-reported
  ;; The rot REQ-0078 R2 asks `check' to report: the module is there, and the
  ;; function a call still names is not.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "sheets" :path ("upsert_tab")
                                                 :line 7)))))
    (r-py-definition g :function "upsert" "functions/sheets.py")
    (r-py-tree g "functions/main.py" "functions/sheets.py")
    (r-resolve g)
    (is (null (called-ids g caller)))
    (is (equal '(:missing-in-target)
               (mapcar (lambda (m) (getf m :cause)) (getp caller :unresolved-imported-calls))))
    (is (equal '((:caller "run" :file "functions/main.py" :line 7
                  :specifier "sheets" :path ("upsert_tab")))
               (loom-graph:missing-imported-calls g)))))

(test an-external-or-unrooted-miss-is-not-reported-as-missing
  (let ((g (make-graph)))
    (r-py-caller g "run" "functions/tests/t.py"
                 :imported-calls '((:specifier "pytest" :path ("raises") :line 1)
                                   (:specifier "ledger.refs" :path ("x") :line 2)))
    (r-py-tree g "functions/tests/t.py" "functions/ledger/refs.py"
               "functions/ledger/__init__.py")
    (r-resolve g)
    (is (null (loom-graph:missing-imported-calls g))
        "a library and a missing domain declaration are counted gaps, not errors")))

(test a-path-ending-at-a-variable-is-not-callable
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "config" :path ("SHEET_NAME")
                                                 :line 3)))))
    (r-py-definition g :variable "SHEET_NAME" "functions/config.py")
    (r-py-tree g "functions/main.py" "functions/config.py")
    (r-resolve g)
    (is (null (called-ids g caller)))
    (is (equal '(:not-callable)
               (mapcar (lambda (m) (getf m :cause)) (getp caller :unresolved-imported-calls))))))

(test a-call-site-bound-to-an-import-resolves-once-through-its-binding
  ;; DES-0053 D4. CALLER-CALL-NAMES returns nothing for it, so its dotted
  ;; :CALL-NAME is not also resolved as a bare name.
  (let* ((g (make-graph))
         (site (make-call-site-entity
                :file "tools/test/acceptance.py" :start-line 300
                :call-name "service.ensure" :referrer-kind :module
                :language :python
                :imported-calls '((:specifier "service" :path ("ensure") :line 301))))
         (target (r-py-definition g :function "ensure" "tools/test/service.py"))
         (decoy (r-py-definition g :function "service.ensure" "tools/other.py")))
    (add-entity g site)
    (r-py-tree g "tools/test/acceptance.py" "tools/test/service.py")
    (r-resolve g)
    (is (equal (list (id target)) (called-ids g site)))
    (is (null (relationships-to g (id decoy) :rel-type :calls))
        "the dotted spelling is a label, not a name to look up")
    (is (null (loom-graph::caller-call-names site)))))

(test a-python-member-call-with-no-method-of-that-property-draws-no-edge
  ;; The third tier of MEMBER-CALL-CANDIDATES is JavaScript's namespace import.
  ;; Python writes a namespace access as :IMPORTED-CALLS, so `obj.read' with no
  ;; method `read' anywhere must not reach a plain function named read.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "app/main.py" :call-names '("obj.read")))
         (plain (r-py-definition g :function "read" "app/io.py")))
    (r-py-tree g "app/main.py" "app/io.py")
    (r-resolve g)
    (is (null (called-ids g caller)))
    (is (null (relationships-to g (id plain) :rel-type :calls)))
    (is (equal '("obj.read") (getp caller :unresolved-calls)))))

(test a-python-member-call-reaches-the-methods-of-that-property
  ;; The second tier stays: `rules.find' with no class named rules reaches the
  ;; one method called find.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "app/main.py" :call-names '("rules.find")))
         (method (r-py-definition g :method "Rules.find" "app/rules.py")))
    (r-py-tree g "app/main.py" "app/rules.py")
    (r-resolve g)
    (is (equal (list (id method)) (called-ids g caller)))))

(test a-python-caller-never-reaches-a-lisp-or-javascript-definition
  ;; CPython code does not call either in process.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "app/main.py" :call-names '("helper")))
         (lisp (r-function g "helper" "other.lisp"))
         (js (r-js-function g "helper" "ui/helper.js")))
    (r-py-tree g "app/main.py")
    (r-resolve g)
    (is (null (called-ids g caller)))
    (is (null (relationships-to g (id lisp) :rel-type :calls)))
    (is (null (relationships-to g (id js) :rel-type :calls)))
    (is (equal '("helper") (getp caller :unresolved-calls)))))

(test retracting-a-reexported-file-and-resolving-again-brings-the-edge-back
  ;; DEC-0003. Retracting posting.py destroys the edge pointing into it; the
  ;; caller and ledger/__init__.py are untouched, and what they recorded is all
  ;; the next pass needs.
  (let* ((g (make-graph))
         (caller (r-py-caller g "run" "functions/main.py"
                              :imported-calls '((:specifier "ledger" :path ("post")
                                                 :line 9)))))
    (r-py-tree g "functions/main.py" "functions/ledger/posting.py")
    (r-py-file g "functions/ledger/__init__.py"
               :bindings '((:local "post" :specifier ".posting" :name "post")))
    (let ((post (r-py-definition g :function "post" "functions/ledger/posting.py")))
      (r-resolve g)
      (is (equal (list (id post)) (called-ids g caller)))
      (apply-transaction g (list (retract-file "functions/ledger/posting.py" nil)))
      (is (null (called-ids g caller)) "the retract took the edge with its target")
      (r-py-file g "functions/ledger/posting.py")
      (let ((again (r-py-definition g :function "post" "functions/ledger/posting.py")))
        (r-resolve g)
        (is (equal (list (id again)) (called-ids g caller))
            "and the next pass derives it again from what the caller recorded")))))

;;;; ==================================================================
;;;; RESOLVE-SETTINGS (DES-0053 D10)
;;;; ==================================================================

(defun r-reader (graph type name file &rest names)
  "A Python entity of TYPE whose code reads each of NAMES from the environment."
  (let ((e (r-py-definition graph type name file)))
    (setp e :environment-reads names)
    e))

(defun r-settle (graph)
  (apply-transaction graph (resolve-settings graph)))

(defun reads-ids (graph entity)
  (mapcar #'to-id (relationships-from graph (id entity) :rel-type :reads)))

(test two-readers-of-one-name-give-one-setting-and-two-reads-edges
  (let* ((g (make-graph))
         (a (r-reader g :variable "SPREADSHEET_ID" "functions/config.py" "SPREADSHEET_ID"))
         (b (r-reader g :function "load" "functions/sheets.py" "SPREADSHEET_ID" "OTHER")))
    (r-settle g)
    (let ((settings (entities-of-type g :setting)))
      (is (equal '("OTHER" "SPREADSHEET_ID")
                 (sort (mapcar #'name settings) #'string<)))
      (let ((shared (find "SPREADSHEET_ID" settings :key #'name :test #'string=)))
        (is (equal '(:environment) (getp shared :sources)))
        (is (member (id shared) (reads-ids g a) :test #'string=))
        (is (member (id shared) (reads-ids g b) :test #'string=))
        (is (= 2 (length (relationships-to g (id shared) :rel-type :reads)))
            "one node, one edge from each reader")))))

(test a-repeated-name-on-one-reader-is-one-edge
  (let* ((g (make-graph))
         (a (r-reader g :function "f" "app/a.py" "K" "K")))
    (r-settle g)
    (is (= 1 (length (reads-ids g a))))))

(test a-setting-survives-one-reader-and-is-swept-when-the-last-goes
  (let* ((g (make-graph))
         (a (r-reader g :function "f" "app/a.py" "K"))
         (b (r-reader g :function "g" "app/b.py" "K")))
    (r-settle g)
    (setp a :environment-reads nil)
    (r-settle g)
    (is (= 1 (length (entities-of-type g :setting)))
        "b still reads it")
    (setp b :environment-reads nil)
    (r-settle g)
    (is (null (entities-of-type g :setting))
        "no reader names it, so it is derived no longer")))

(test resolving-settings-twice-changes-nothing
  (let ((g (make-graph)))
    (r-reader g :function "f" "app/a.py" "K")
    (r-settle g)
    (r-settle g)
    (is (= 1 (length (entities-of-type g :setting))))
    (is (= 1 (length (relationships-to g (id (first (entities-of-type g :setting)))
                                       :rel-type :reads))))))

(test a-setting-reaches-its-readers-and-their-callers
  (let* ((g (make-graph))
         (reader (r-reader g :function "load" "app/sheets.py" "K"))
         (caller (r-py-definition g :function "main" "app/main.py")))
    (apply-transaction g (list (assert-edge :calls caller reader)))
    (r-settle g)
    (let ((result (impact-set g (id (first (entities-of-type g :setting))))))
      (is (equal '("load" "main")
                 (sort (mapcar (lambda (e) (name (impact-entry-entity e)))
                               (remove :file (impact-result-impacted result)
                                       :key (lambda (e) (entity-type (impact-entry-entity e)))))
                       #'string<))))))

(test a-document-naming-a-setting-resolves-to-it
  ;; Neither :DECIDES nor :DOCUMENTS listed :SETTING as a target, so `affects:
  ;; [SPREADSHEET_ID]' would have resolved and then lost its edge. A plan bears
  ;; on a setting; a decision governs one.
  ;; The reader is the :VARIABLE `SPREADSHEET_ID = os.environ.get(...)', which
  ;; shares its setting's name: every one of lfia's eight config reads has that
  ;; shape. A function named `load' avoided the collision and passed for a shape
  ;; the canonical case does not have (REV-0003 item 3).
  (let ((g (make-graph)))
    (r-reader g :variable "SPREADSHEET_ID" "app/config.py" "SPREADSHEET_ID")
    (let ((decision (r-decision g "DEC-9000" :affects '("SPREADSHEET_ID")))
          (plan (make-instance 'document-entity :name "docs/plans/PLAN-9000.yaml"
                               :origin-file "docs/plans/PLAN-9000.yaml"
                               :properties (properties-table
                                            '(:path "docs/plans/PLAN-9000.yaml"
                                              :doc-id "PLAN-9000"
                                              :affects ("SPREADSHEET_ID"))))))
      (add-entity g plan)
      (r-settle g)
      (apply-transaction g (resolve-document-links g :workspace-id "w"))
      (let ((setting (id (first (entities-of-type g :setting)))))
        (is (equal (list setting)
                   (mapcar #'to-id (relationships-from g (id decision) :rel-type :decides))))
        (is (equal (list setting)
                   (mapcar #'to-id (relationships-from g (id plan) :rel-type :documents))))
        (is (null (getp plan :unresolved-references)))))))

;;; ------------------------------------------------------------------
;;; DES-0054 D3 and D5: declarations, registrations and the sentinel's setting
;;; ------------------------------------------------------------------

(defparameter *r-entry-points*
  '((:framework "firebase-functions" :trigger :https
     :module "firebase_functions.https_fn" :names ("on_request") :settings ("secrets")
     :positional nil)
    (:framework "firebase-functions" :trigger :schedule
     :module "firebase_functions.scheduler_fn" :names ("on_schedule") :settings ("secrets")
     :positional nil)
    (:framework "firebase-functions-js" :trigger :https
     :module "firebase-functions" :names ("default.https.onRequest") :settings ("secrets")
     :positional nil)))

(defparameter *r-declarations*
  '((:source :secret :module "firebase_functions.params" :names ("SecretParam"))
    (:source :param :module "firebase_functions.params" :names ("StringParam" "IntParam"))))

(defun r-settle-with (graph)
  "RESOLVE-SETTINGS with both declaration lists, applied."
  (apply-transaction graph (resolve-settings graph
                                             :setting-declarations *r-declarations*
                                             :entry-points *r-entry-points*)))

(defun r-declares (graph name file call first &key (specifier "firebase_functions.params"))
  "A Python :VARIABLE NAME in FILE bound to CALL(FIRST) -- a :VALUE-CALL as the
analyzer writes it, with no other argument."
  (let ((e (r-py-definition graph :variable name file)))
    (setp e :value-call (append (list :specifier specifier :path (list call) :line 1)
                                (when first (list :first-string first))))
    e))

(defun r-registered (graph name file arguments
                     &key (specifier "firebase_functions") (path '("https_fn" "on_request"))
                       positional)
  "A Python :FUNCTION carrying one decorator, as DES-0054 D1 encodes it."
  (let ((e (r-py-definition graph :function name file)))
    (setp e :decorators (list (list :name "d" :specifier specifier :path path
                                    :arguments arguments :positional positional :line 1)))
    e))

(defun r-local (name) (list :name name :binding :local))

(defun r-imported (name specifier path)
  (list :name name :binding :import :specifier specifier :path path))

(defun reads-names (graph entity)
  (sort (mapcar (lambda (id) (name (get-entity graph id))) (reads-ids graph entity))
        #'string<))

(test match-registration-follows-each-languages-own-rule
  (flet ((hit (registration language)
           (loom-graph:match-registration registration language *r-entry-points*)))
    (is (eq :https (getf (hit '(:specifier "firebase_functions.https_fn" :path ("on_request"))
                              :python)
                         :trigger))
        "`from firebase_functions import https_fn' joined gives the same callee")
    (is (eq :schedule (getf (hit '(:specifier "firebase_functions" :path ("scheduler_fn" "on_schedule"))
                                 :python)
                            :trigger)))
    (is (eq :schedule (getf (hit '(:specifier "firebase_functions.scheduler_fn" :path ("on_schedule"))
                                 :python)
                            :trigger))
        "`import firebase_functions.scheduler_fn as s' then s.on_schedule")
    (is (null (hit '(:specifier "firebase_functions" :path ("scheduler_fn" "on_schedule"))
                   :javascript))
        "a JavaScript registration is matched by the JavaScript rule only")
    (is (eq :https (getf (hit '(:specifier "firebase-functions" :path ("default" "https" "onRequest"))
                              :javascript)
                         :trigger)))
    (is (null (hit '(:specifier ".https_fn" :path ("on_request")) :python)) "relative")
    (is (null (hit '(:specifier "./firebase-functions" :path ("default" "https" "onRequest"))
                   :javascript)))
    (is (null (hit '(:path ("on_schedule")) :python))
        "a bare local decorator has no specifier and matches nothing")
    (is (null (hit '(:specifier "firebase_functions.https_fn" :path ("on_request")) :lisp)))))

(test match-registration-refuses-two-matches
  (multiple-value-bind (one many)
      (loom-graph:match-registration
       '(:specifier "m" :path ("f")) :python
       '((:module "m" :names ("f")) (:module "m" :names ("f" "g"))))
    (is (null one))
    (is (= 2 (length many)))))

(test a-declaration-and-four-registrations-give-one-setting-and-five-reads
  (let* ((g (make-graph))
         (key (r-declares g "ZEFFY_API_KEY" "functions/main.py" "SecretParam" "ZEFFY_API_KEY"))
         (bound (loop for n in '("a" "b" "c" "d")
                      collect (r-registered
                               g n "functions/main.py"
                               `(("secrets" :list ,(r-local "ZEFFY_API_KEY"))
                                 ("timeout_sec" . 540)))))
         (plain (r-registered g "e" "functions/main.py" '(("timeout_sec" . 540)))))
    (r-py-tree g "functions/main.py")
    (r-settle-with g)
    (let ((setting (first (entities-of-type g :setting))))
      (is (= 1 (length (entities-of-type g :setting))))
      (is (equal "ZEFFY_API_KEY" (name setting)))
      (is (equal '(:secret) (getp setting :sources)))
      (is (= 5 (length (relationships-to g (id setting) :rel-type :reads)))
          "the variable and the four functions whose decorators bind it")
      (is (member (id setting) (reads-ids g key) :test #'string=))
      (dolist (f bound)
        (is (member (id setting) (reads-ids g f) :test #'string=)))
      (is (null (reads-ids g plain))))))

(test a-secret-and-an-environment-read-of-one-name-are-one-setting
  (let ((g (make-graph)))
    (r-declares g "ZEFFY_API_KEY" "functions/main.py" "SecretParam" "ZEFFY_API_KEY")
    (r-reader g :variable "KEY" "functions/config.py" "ZEFFY_API_KEY")
    (r-settle-with g)
    (let ((settings (entities-of-type g :setting)))
      (is (= 1 (length settings)))
      (is (equal '(:environment :secret) (getp (first settings) :sources))))))

(test a-name-reaches-only-the-variable-its-own-binding-names
  ;; REV-0003 finding 1, in a pass. K is declared in a.py and in b.py with
  ;; different names. A bare-name lookup across the tree would give one of them
  ;; to c.py's function, which has no K.
  (let* ((g (make-graph))
         (in-a (r-registered g "fa" "app/a.py" `(("secrets" :list ,(r-local "K")))))
         (in-c (r-registered g "fc" "app/c.py" `(("secrets" :list ,(r-local "K"))))))
    (r-declares g "K" "app/a.py" "SecretParam" "A")
    (r-declares g "K" "app/b.py" "SecretParam" "B")
    (r-py-tree g "app/a.py" "app/b.py" "app/c.py")
    (r-settle-with g)
    (is (equal '("A") (reads-names g in-a)))
    (is (null (reads-ids g in-c)) "no K in c.py, and no lookup by spelling")))

(test an-imported-name-is-walked-to-the-file-it-came-from
  (let* ((g (make-graph))
         (user (r-registered g "f" "app/main.py"
                             `(("secrets" :list ,(r-imported "K" "config" '("K")))
                               ("memory" :dotted "config.OTHER" :specifier "config"
                                :path nil))))
         (other (r-declares g "K" "app/other.py" "SecretParam" "WRONG")))
    (declare (ignore other))
    (r-declares g "K" "app/config.py" "SecretParam" "RIGHT")
    (r-py-tree g "app/main.py" "app/config.py" "app/other.py")
    (r-settle-with g)
    (is (equal '("RIGHT") (reads-names g user)))))

(test a-dotted-chain-is-followed-from-its-first-names-import
  (let* ((g (make-graph))
         (user (r-registered g "f" "app/main.py"
                             '(("memory" :dotted "config.K" :specifier "config" :path nil)))))
    (r-declares g "K" "app/config.py" "IntParam" "MEM")
    (r-py-tree g "app/main.py" "app/config.py")
    (r-settle-with g)
    (is (equal '("MEM") (reads-names g user)))
    (is (equal '(:param) (getp (find "MEM" (entities-of-type g :setting)
                                     :key #'name :test #'string=)
                               :sources)))))

(test a-literal-names-a-setting-only-under-a-keyword-the-entry-lists
  (let* ((g (make-graph))
         (f (r-registered g "f" "app/a.py" '(("secrets" :list "LITERAL")
                                             ("region" . "OTHER")
                                             ("labels" :list "ALSO-NOT")))))
    (r-py-tree g "app/a.py")
    (r-settle-with g)
    (is (equal '("LITERAL") (reads-names g f)))
    (is (equal '("LITERAL") (mapcar #'name (entities-of-type g :setting))))))

(test a-param-bound-to-a-timeout-is-read-keyword-blind
  (let* ((g (make-graph))
         (f (r-registered g "f" "app/a.py" `(("timeout_sec" ,@(r-local "T"))))))
    (r-declares g "T" "app/a.py" "IntParam" "T")
    (r-py-tree g "app/a.py")
    (r-settle-with g)
    (is (equal '("T") (reads-names g f)))))

(test a-declaring-variable-with-no-first-string-names-nothing
  (let* ((g (make-graph))
         (v (r-declares g "X" "app/a.py" "SecretParam" nil)))
    (r-py-tree g "app/a.py")
    (r-settle-with g)
    (is (null (entities-of-type g :setting)))
    (is (null (reads-ids g v)))))

(test a-registration-matching-no-entry-reads-nothing
  (let* ((g (make-graph))
         (f (r-registered g "f" "app/a.py" `(("secrets" :list ,(r-local "K")))
                          :specifier "flask" :path '("route"))))
    (r-declares g "K" "app/a.py" "SecretParam" "K")
    (r-py-tree g "app/a.py")
    (r-settle-with g)
    (is (null (reads-ids g f)))))

(test the-declaration-edge-follows-the-file-that-decided-it
  ;; DES-0054 refinement 2. b.py's declaration changes from "B" to "B2" and a.py
  ;; is untouched. The edge from a.py's function took b.py as its origin, so
  ;; RETRACT-FILE on b.py removes it and the next pass draws the true one, even
  ;; though some other reader still reads B from the environment. The answer
  ;; equals a fresh build's.
  (flet ((build (declared)
           (let* ((g (make-graph))
                  (user (r-registered g "f" "app/a.py"
                                      `(("secrets" :list ,(r-imported "K" "b" '("K"))))))
                  (env (r-reader g :function "g" "app/env.py" "B")))
             (r-declares g "K" "app/b.py" "SecretParam" declared)
             (r-py-tree g "app/a.py" "app/b.py" "app/env.py")
             (r-settle-with g)
             (values g user env))))
    (multiple-value-bind (g user env) (build "B")
      (declare (ignore env))
      (is (equal '("B") (reads-names g user)))
      (apply-transaction g (list (retract-file "app/b.py" nil)))
      (is (null (reads-ids g user)) "the retract took the edge a.py never wrote")
      (r-py-file g "app/b.py")
      (r-declares g "K" "app/b.py" "SecretParam" "B2")
      (r-settle-with g)
      (is (equal '("B2") (reads-names g user)))
      (let ((fresh (build "B2")))
        (flet ((edges (graph)
                 (sort (mapcar (lambda (r) (list (from-id r) (to-id r)))
                               (loop for e in (all-entities graph)
                                     append (relationships-from graph (id e) :rel-type :reads)))
                       #'string< :key #'first)))
          (is (equal (edges fresh) (edges g)) "equal to a fresh build"))))))

(test a-document-naming-a-secret-resolves-to-the-setting-and-not-its-variable
  ;; REV-0003 finding 3. ZEFFY_API_KEY is a :VARIABLE and, after this pass, a
  ;; :SETTING; config.py's variable reads the name from the environment. The
  ;; variable that declares the secret holds no environment read, so only the
  ;; :READS edge ties it to the setting.
  (let ((g (make-graph)))
    (r-declares g "ZEFFY_API_KEY" "functions/main.py" "SecretParam" "ZEFFY_API_KEY")
    (r-reader g :variable "ZEFFY_API_KEY" "functions/config.py" "ZEFFY_API_KEY")
    (r-settle-with g)
    (let ((index (loom-graph:linkable-index g))
          (setting (first (entities-of-type g :setting))))
      (is (eq setting (loom-graph:resolve-one index "ZEFFY_API_KEY" :view g)))
      (is (null (loom-graph:resolve-one index "ZEFFY_API_KEY"))
          "without the view the old rule applies, and the declaring variable has no
environment read, so it stays ambiguous: nothing that resolved before moves")
      (r-py-definition g :variable "ZEFFY_API_KEY" "functions/other.py")
      (let ((index (loom-graph:linkable-index g)))
        (multiple-value-bind (target candidates)
            (loom-graph:resolve-one index "ZEFFY_API_KEY" :view g)
          (is (null target) "a same-named variable that reads nothing keeps it ambiguous")
          (is (= 4 (length candidates))))))
))

(test a-decision-naming-a-secret-gets-one-decides-edge
  (let ((g (make-graph)))
    (r-declares g "ZEFFY_API_KEY" "functions/main.py" "SecretParam" "ZEFFY_API_KEY")
    (r-reader g :variable "ZEFFY_API_KEY" "functions/config.py" "ZEFFY_API_KEY")
    (let ((decision (r-decision g "DEC-9001" :affects '("ZEFFY_API_KEY"))))
      (r-settle-with g)
      (apply-transaction g (resolve-document-links g :workspace-id "w"))
      (is (equal (list (id (first (entities-of-type g :setting))))
                 (mapcar #'to-id (relationships-from g (id decision) :rel-type :decides))))
      (is (null (getp decision :unresolved-references)))
      (is (null (getp decision :ambiguous-references))))))

(test resolve-one-without-a-view-resolves-what-it-always-did
  (let* ((g (make-graph))
         (variable (r-reader g :variable "SPREADSHEET_ID" "app/config.py" "SPREADSHEET_ID")))
    (declare (ignore variable))
    (r-settle g)
    (let ((index (loom-graph:linkable-index g)))
      (is (eq (first (entities-of-type g :setting))
              (loom-graph:resolve-one index "SPREADSHEET_ID")))
      (is (eq (first (entities-of-type g :setting))
              (loom-graph:resolve-one index "SPREADSHEET_ID" :view g))))))

;;; ------------------------------------------------------------------
;;; DES-0054 D6: entry points, codebases and deployment
;;; ------------------------------------------------------------------

(defun r-firebase (graph path &rest codebases)
  "A firebase.json :FILE at PATH holding CODEBASES, as the firebase analyzer writes it."
  (let ((e (make-instance 'file-entity :name path :origin-file path
                          :properties (properties-table
                                       (list :path path :codebases codebases)))))
    (add-entity graph e)
    e))

(defun r-codebase (&key (source "functions") (codebase "default") (runtime "python312")
                     ignore)
  (append (list :source source :codebase codebase)
          (when runtime (list :runtime runtime))
          (list :ignore ignore :defaulted nil)))

(defun r-entry-settle (graph &optional (entry-points *r-entry-points*))
  (apply-transaction graph (resolve-entry-points graph :entry-points entry-points)))

(defun r-on-request (graph name file)
  (r-registered graph name file '(("timeout_sec" . 540))))

(defun r-on-schedule (graph name file)
  (r-registered graph name file '(("schedule" . "every 1 hours"))
                :path '("scheduler_fn" "on_schedule")))

(defun entry-of (entity) (first (getp entity :entry-point)))

(defun depends-on-ids (graph entity)
  (mapcar #'to-id (relationships-from graph (id entity) :rel-type :depends-on)))

(test lfias-shape-gives-eight-triggered-deployed-functions
  (let* ((g (make-graph))
         (fire (r-firebase g "firebase.json" (r-codebase :ignore '("venv" "tests"))))
         (schedule (list (r-on-schedule g "sync_zeffy" "functions/main.py")
                         (r-on-schedule g "sync_zeffy_ledger" "functions/main.py")))
         (https (loop for n in '("a" "b" "c" "d" "e" "f")
                      collect (r-on-request g n "functions/main.py")))
         (sync (r-py-definition g :function "_sync" "functions/main.py")))
    (r-py-tree g "functions/main.py")
    (dolist (f (append schedule https))
      (apply-transaction g (list (assert-edge :calls f sync))))
    (r-entry-settle g)
    (dolist (f schedule)
      (is (eq :schedule (getp f :trigger))))
    (dolist (f https)
      (is (eq :https (getp f :trigger))))
    (dolist (f (append schedule https))
      (let ((entry (entry-of f)))
        (is (eq :yes (getf entry :deployed)))
        (is (equal "default" (getf entry :codebase)))
        (is (equal "python312" (getf entry :runtime)))
        (is (equal (list (id fire)) (depends-on-ids g f)))))
    (is (equal "firebase_functions.scheduler_fn.on_schedule"
               (getf (entry-of (first schedule)) :callee)))
    (is (equal '(("schedule" . "every 1 hours")) (getf (entry-of (first schedule)) :options)))
    (is (= 8 (length (relationships-to g (id fire) :rel-type :depends-on))))
    (let ((names (mapcar (lambda (e) (name (impact-entry-entity e)))
                         (impact-result-impacted (impact-set g (id fire))))))
      (is (= 8 (count-if (lambda (n) (not (string= n "functions/main.py"))) names)))
      (is (not (member "_sync" names :test #'string=))
          "what the functions call does not depend on firebase.json"))))

(test two-matching-decorators-give-multiple-and-two-plists
  (let* ((g (make-graph))
         (f (r-py-definition g :function "f" "app/a.py")))
    (setp f :decorators
          (list (list :name "x" :specifier "firebase_functions"
                      :path '("https_fn" "on_request") :arguments nil :line 1)
                (list :name "y" :specifier "firebase_functions"
                      :path '("scheduler_fn" "on_schedule") :arguments nil :line 2)))
    (r-entry-settle g)
    (is (eq :multiple (getp f :trigger)))
    (is (= 2 (length (getp f :entry-point))))))

(defun r-deploy-case (&key bindings (handler-file "functions/handlers.py") main-regions
                        (handler-name "f") (with-handlers-file t) extra)
  "A firebase.json, a main.py binding BINDINGS, and a registered HANDLER-NAME in
HANDLER-FILE. Returns the handler. EXTRA is called with the graph before the pass."
  (let* ((g (make-graph))
         (handler (r-on-request g handler-name handler-file)))
    (r-firebase g "firebase.json" (r-codebase))
    (let ((main (r-py-file g "functions/main.py" :bindings bindings)))
      (when main-regions (setp main :suppressed-regions main-regions)))
    (when with-handlers-file (r-py-tree g handler-file))
    (when extra (funcall extra g))
    (r-entry-settle g)
    (values handler g)))

(test a-registered-function-main-does-not-bind-is-not-deployed
  (is (eq :no (getf (entry-of (r-deploy-case)) :deployed))))

(test a-from-import-in-main-deploys-it
  (is (eq :yes (getf (entry-of (r-deploy-case
                                :bindings '((:local "f" :specifier "handlers" :name "f"))))
                     :deployed))))

(test import-of-the-module-does-not-deploy-its-functions
  ;; Firebase's getmembers sees a module object, not a function.
  (is (eq :no (getf (entry-of (r-deploy-case
                               :bindings '((:local "handlers" :specifier "handlers"
                                            :name nil))))
                    :deployed))))

(test a-star-import-that-resolves-deploys-what-the-module-defines
  (is (eq :yes (getf (entry-of (r-deploy-case
                                :bindings '((:local nil :specifier "handlers" :name "*"))))
                     :deployed))))

(test a-star-import-that-does-not-resolve-is-unknown-and-not-no
  ;; REV-0003 finding 2: a miss the language might resolve is not reported.
  (is (eq :unknown (getf (entry-of (r-deploy-case
                                    :bindings '((:local nil :specifier "vendored_pkg"
                                                 :name "*"))))
                         :deployed))))

(test a-reexport-through-a-packages-init-deploys-it
  (let ((handler (r-deploy-case
                  :handler-file "functions/pkg/handlers.py"
                  :bindings '((:local "f" :specifier "pkg" :name "f"))
                  :extra (lambda (g)
                           (r-py-file g "functions/pkg/__init__.py"
                                      :bindings '((:local "f" :specifier ".handlers"
                                                   :name "f")))))))
    (is (eq :yes (getf (entry-of handler) :deployed)))))

(test a-main-with-a-damaged-region-is-unknown-and-not-no
  (is (eq :unknown
          (getf (entry-of (r-deploy-case
                           :main-regions '((:reason "python syntax error"
                                            :start-line 3 :end-line 4))))
                :deployed))))

(test a-function-defined-in-main-is-deployed
  (is (eq :yes (getf (entry-of (r-deploy-case :handler-file "functions/main.py"))
                     :deployed))))

(test an-ignored-path-is-not-covered
  (let* ((g (make-graph))
         (f (r-on-request g "test_fixture" "functions/tests/test_x.py")))
    (r-firebase g "firebase.json" (r-codebase :ignore '("tests")))
    (r-entry-settle g)
    (is (eq :https (getp f :trigger)) "it is still a registration")
    (is (null (getf (entry-of f) :codebase)) "but no codebase covers it")
    (is (null (getf (entry-of f) :deployed)))
    (is (null (depends-on-ids g f)))))

(test two-codebases-covering-one-path-at-one-length-give-no-codebase
  (let* ((g (make-graph))
         (f (r-on-request g "f" "a/b/main.py")))
    (r-firebase g "firebase.json" (r-codebase :source "a/b" :codebase "one"))
    (r-firebase g "a/firebase.json" (r-codebase :source "b" :codebase "two"))
    (r-entry-settle g)
    (is (null (getf (entry-of f) :codebase)))
    (is (equal '("a/firebase.json" "firebase.json")
               (sort (copy-list (getf (entry-of f) :codebase-tie)) #'string<)))))

(test the-longest-prefix-wins
  (let* ((g (make-graph))
         (f (r-on-request g "f" "app/functions/main.py")))
    (r-firebase g "firebase.json" (r-codebase :source "app" :codebase "outer"))
    (r-firebase g "app/firebase.json" (r-codebase :source "functions" :codebase "inner"))
    (r-entry-settle g)
    (is (equal "inner" (getf (entry-of f) :codebase)))))

(test an-ignore-in-syntax-loom-does-not-read-excludes-nothing-and-is-listed
  (let* ((g (make-graph))
         (f (r-on-request g "f" "functions/a/main.py")))
    (r-firebase g "firebase.json" (r-codebase :ignore '("{a,b}")))
    (r-entry-settle g)
    (is (equal "default" (getf (entry-of f) :codebase)) "not excluded")
    (is (equal '("{a,b}") (getf (entry-of f) :uninterpreted-ignores)))))

(test ignore-globs-follow-the-segments-they-name
  (flet ((hit (pattern path) (loom-graph::ignore-matches-p pattern path)))
    (is (hit "tests" "tests/x.py"))
    (is (hit "tests" "pkg/tests/x.py") "a plain name matches at any depth")
    (is (hit "*.pyc" "pkg/m.pyc"))
    (is (not (hit "tests" "attests/x.py")))
    (is (hit "**/node_modules/**" "a/node_modules/b/c.js"))
    (is (hit "pkg/gen" "pkg/gen/x.py") "excluding a directory excludes what is under it")
    (is (not (hit "pkg/gen" "other/pkg/gen/x.py")) "a path pattern is anchored at the source")
    (is (hit "m?.py" "ma.py"))
    (is (not (hit "m?.py" "mab.py")))))

(test a-registration-matching-no-declaration-marks-nothing
  (let* ((g (make-graph))
         (f (r-registered g "f" "app/a.py" nil :specifier "flask" :path '("route"))))
    (r-entry-settle g)
    (is (null (getp f :trigger)))
    (is (null (getp f :entry-point)))))

(test a-function-with-no-firebase-json-still-gets-its-trigger
  (let* ((g (make-graph))
         (f (r-on-request g "f" "app/a.py")))
    (r-entry-settle g)
    (is (eq :https (getp f :trigger)))
    (is (null (getf (entry-of f) :codebase)))
    (is (null (depends-on-ids g f)))))

(test removing-the-declarations-clears-the-marks-and-retracts-no-file
  (let* ((g (make-graph))
         (f (r-on-request g "f" "functions/main.py")))
    (r-firebase g "firebase.json" (r-codebase))
    (r-py-tree g "functions/main.py")
    (r-entry-settle g)
    (is (eq :https (getp f :trigger)))
    (let ((files (length (entities-of-type g :file))))
      (r-entry-settle g nil)
      (is (null (getp f :trigger)))
      (is (null (getp f :entry-point)))
      (is (= files (length (entities-of-type g :file)))
          "nothing was reanalyzed to clear it"))))

(test a-non-python-entry-point-is-unknown-and-never-no
  (let* ((g (make-graph))
         (v (make-instance 'variable-entity :name "api" :origin-file "functions/index.js"
                           :properties (properties-table
                                        (list :file "functions/index.js" :start-line 1
                                              :language :javascript
                                              :registration
                                              (list :name "functions.https.onRequest"
                                                    :specifier "firebase-functions"
                                                    :path '("default" "https" "onRequest")
                                                    :arguments nil :line 1))))))
    (add-entity g v)
    (r-firebase g "firebase.json" (r-codebase :runtime nil))
    (r-entry-settle g)
    (is (eq :https (getp v :trigger)))
    (is (eq :unknown (getf (entry-of v) :deployed)))
    (is (null (depends-on-ids g v)))))

;;; ------------------------------------------------------------------
;;; The Python line, drawn both ways (BUG-0070)
;;; ------------------------------------------------------------------

(defun r-foreign-caller (graph language name file call-names)
  "A function in LANGUAGE (:LISP or :JAVASCRIPT) calling CALL-NAMES by spelling."
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language language
                                             :call-names call-names)))))
    (add-entity graph e)
    e))

(test a-python-bare-name-reaches-no-other-files-definition
  ;; extract.py writes `d["k"].get(x)' as the bare name `get'. tools/test/
  ;; service.py holds the one Python `get' on Loom's tree, and seven dict lookups
  ;; used to land on it at confidence 1.0.
  (let* ((g (make-graph))
         (caller (r-py-function g "bind" "tools/py/extract.py" :unresolved '("get")))
         (far (r-py-function g "get" "tools/test/service.py")))
    (r-py-tree g "tools/py/extract.py" "tools/test/service.py")
    (apply-transaction g (resolve-calls g))
    (is (null (called-ids g caller)))
    (is (null (relationships-to g (id far) :rel-type :calls)))
    (is (equal '("get") (getp caller :unresolved-calls))
        "recorded unresolved, not dropped")))

(test a-python-bare-name-still-reaches-its-own-file
  ;; The control: the narrowing must not remove the local definition, or the
  ;; test above would pass for a resolver that resolves no Python name at all.
  (let* ((g (make-graph))
         (caller (r-py-function g "run" "app/m.py" :unresolved '("helper")))
         (local (r-py-function g "helper" "app/m.py")))
    (r-py-tree g "app/m.py")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id local)) (called-ids g caller)))))

(test a-lisp-or-javascript-name-reaches-no-python-definition
  ;; file-store.lisp's `(git ...)' and a JavaScript `git()' both fell back to
  ;; their spelling and landed on tools/test/acceptance.py's `git'.
  (let* ((g (make-graph))
         (lisp (r-foreign-caller g :lisp "probe" "src/a.lisp" '("git")))
         (js (r-foreign-caller g :javascript "probe" "web/a.js" '("git")))
         (py (r-py-function g "git" "tools/test/acceptance.py")))
    (r-py-tree g "tools/test/acceptance.py")
    (apply-transaction g (resolve-calls g))
    (is (null (called-ids g lisp)))
    (is (null (called-ids g js)))
    (is (null (relationships-to g (id py) :rel-type :calls)))))

;;; ------------------------------------------------------------------
;;; Inheritance and star imports in the walk (BUG-0071)
;;; ------------------------------------------------------------------

(defun r-call-through (graph specifier path &optional (file "app/main.py"))
  "A caller in FILE with one imported call of PATH through SPECIFIER, and the
resolution pass run."
  (let ((caller (r-py-caller graph "run" file
                             :imported-calls (list (list :specifier specifier
                                                         :path path :line 6)))))
    (r-py-tree graph file)
    (r-resolve graph)
    caller))

(defun r-causes (caller)
  (mapcar (lambda (m) (getf m :cause)) (getp caller :unresolved-imported-calls)))

(test a-classmethod-the-class-inherits-is-the-edge-and-not-a-miss
  ;; `from models import Foo; Foo.create()' where create is Base's.
  (let* ((g (make-graph))
         (create (r-py-definition g :method "Base.create" "app/models.py")))
    (r-py-definition g :class "Base" "app/models.py")
    (r-py-definition g :class "Foo" "app/models.py" :bases '("Base"))
    (r-py-tree g "app/models.py")
    (let ((caller (r-call-through g "models" '("Foo" "create"))))
      (is (equal (list (id create)) (called-ids g caller)))
      (is (null (loom-graph:missing-imported-calls g))))))

(test a-method-a-base-the-tree-does-not-hold-may-define-is-not-reported
  ;; pydantic's `Model.model_validate'. The base is no definition in the tree,
  ;; so nothing shows the name absent.
  (let ((g (make-graph)))
    (r-py-definition g :class "Foo" "app/models.py" :bases '("BaseModel"))
    (r-py-tree g "app/models.py")
    (let ((caller (r-call-through g "models" '("Foo" "model_validate"))))
      (is (null (called-ids g caller)))
      (is (equal '(:inherited) (r-causes caller)))
      (is (null (loom-graph:missing-imported-calls g))))))

(test a-class-with-no-base-but-object-lacking-the-method-is-still-reported
  ;; The control: the carve-out must not silence the rot `check' exists for.
  (let ((g (make-graph)))
    (r-py-definition g :class "Foo" "app/models.py" :bases '("object"))
    (r-py-tree g "app/models.py")
    (r-call-through g "models" '("Foo" "gone"))
    (is (= 1 (length (loom-graph:missing-imported-calls g))))))

(test two-classes-naming-each-other-as-bases-end-in-a-cause
  (let ((g (make-graph)))
    (r-py-definition g :class "A" "app/models.py" :bases '("B"))
    (r-py-definition g :class "B" "app/models.py" :bases '("A"))
    (r-py-tree g "app/models.py")
    (let ((caller (r-call-through g "models" '("A" "x"))))
      (is (equal '(:inherited) (r-causes caller))))))

(test a-name-a-star-import-binds-is-followed-to-its-definition
  ;; app/pkg/__init__.py: `from .impl import *'.
  (let* ((g (make-graph))
         (helper (r-py-definition g :function "helper" "app/pkg/impl.py")))
    (r-py-file g "app/pkg/__init__.py"
               :bindings '((:local nil :specifier ".impl" :name "*")))
    (r-py-tree g "app/pkg/impl.py")
    (let ((caller (r-call-through g "pkg" '("helper"))))
      (is (equal (list (id helper)) (called-ids g caller)))
      (is (null (loom-graph:missing-imported-calls g))))))

(test a-star-import-from-a-module-the-tree-lacks-leaves-the-name-unknowable
  (let ((g (make-graph)))
    (r-py-file g "app/pkg/__init__.py"
               :bindings '((:local nil :specifier "somelib" :name "*")))
    (let ((caller (r-call-through g "pkg" '("helper"))))
      (is (equal '(:star-import) (r-causes caller)))
      (is (null (loom-graph:missing-imported-calls g))))))

(test a-name-no-star-module-holds-is-still-missing
  ;; Every star read and none defines it, so the claim is true and reported.
  (let ((g (make-graph)))
    (r-py-file g "app/pkg/__init__.py"
               :bindings '((:local nil :specifier ".impl" :name "*")))
    (r-py-definition g :function "other" "app/pkg/impl.py")
    (r-py-tree g "app/pkg/impl.py")
    (r-call-through g "pkg" '("helper"))
    (is (= 1 (length (loom-graph:missing-imported-calls g))))))

(test two-modules-star-importing-each-other-end-in-a-cause
  (let ((g (make-graph)))
    (r-py-file g "app/a.py" :bindings '((:local nil :specifier "b" :name "*")))
    (r-py-file g "app/b.py" :bindings '((:local nil :specifier "a" :name "*")))
    (let ((caller (r-call-through g "a" '("x"))))
      (is (null (called-ids g caller)))
      (is (null (loom-graph:missing-imported-calls g))
          "a walk cut off at the limit has not shown the name absent"))))

(test a-variable-that-does-not-read-the-setting-leaves-the-name-ambiguous
  ;; The control for the setting-and-reader rule: a same-named variable that
  ;; reads something else is a second thing, and refusing is still right.
  (let ((g (make-graph)))
    (r-reader g :function "load" "app/sheets.py" "SPREADSHEET_ID")
    (r-reader g :variable "SPREADSHEET_ID" "app/config.py" "OTHER")
    (r-settle g)
    (let ((decision (r-decision g "DEC-9001" :affects '("SPREADSHEET_ID"))))
      (apply-transaction g (resolve-document-links g :workspace-id "w"))
      (is (null (relationships-from g (id decision) :rel-type :decides)))
      (is (= 1 (length (getp decision :ambiguous-references)))))))
