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

(defun r-js-file (graph path &key imports)
  (let ((e (make-instance 'file-entity :name path :origin-file path
                          :properties (properties-table
                                       (list :path path :language :javascript
                                             :import-sources imports)))))
    (add-entity graph e)
    e))

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
