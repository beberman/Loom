;;;; Cross-file call resolution.
;;;; Implements the workspace half of Phase 1 Software Architecture SS8.3:
;;;; "CALLS relationships where the callee resolves within the workspace
;;;; (unresolved calls are recorded as a property, not a dangling edge)."
;;;;
;;;; This cannot live in an analyzer. SS8.1 makes analyzers stateless and
;;;; file-scoped, so one sees the call to APPLY-TRANSACTION but has no way to
;;;; know that transaction.lisp defines it -- it records the name and moves
;;;; on. Resolution is the first thing that needs the whole workspace in one
;;;; place, which is here.
;;;;
;;;; It is also the difference between a graph that can answer questions and
;;;; one that cannot. Without it, :CALLS edges stop at file boundaries, so
;;;; "what calls this?" and "what breaks if I change this?" -- the two
;;;; questions the impact engine exists to answer -- return almost nothing.
;;;;
;;;; Reads a view and returns operations; it does not apply them. The caller
;;;; submits them like any other transaction, which keeps the Graph Manager
;;;; the only writer (SS5.1).

(in-package :loom-graph)

(defparameter *callable-types* '(:function :method :interface)
  "Entity types a :CALLS edge may terminate at, per the :CALLS declaration in
code-ontology.lisp.

:INTERFACE is here because a generic function is callable, not because calls
route through generics -- ARCH-0001 says they do not. It is the target of last
resort, taken only when a protocol has no implementation in the workspace to
fan out to.")

(defun entities-by-name (view types)
  "Name -> list of entities of TYPES defined under it, downcased.
A list rather than a single entity because nothing stops two files defining
the same name, and pretending otherwise is how a resolver invents edges."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (type types)
      (dolist (entity (entities-of-type view type))
        (when (slot-boundp entity 'name)
          (push entity (gethash (string-downcase (name entity)) index)))))
    index))

(defun callable-index (view) (entities-by-name view *callable-types*))

(defun unique-match (index name)
  "The one entity INDEX holds under NAME, or NIL for none or several."
  (let ((candidates (gethash (string-downcase name) index)))
    (when (and candidates (null (rest candidates)))
      (first candidates))))

;;;; ==================================================================
;;;; Structure: inheritance, dispatch, and protocols (ARCH-0001)
;;;; ==================================================================
;;;;
;;;; Three more kinds of cross-file name, resolved the same way calls are and
;;;; for the same reason: a superclass, a specializer and a generic can each be
;;;; declared in a file the analyzer was not looking at. Each is derived from a
;;;; property the analyzer wrote and never rewrites, per DEC-0003, so an edge
;;;; destroyed by retracting the file it pointed into comes back on the next
;;;; pass.

(defun resolve-inheritance (view &key workspace-id)
  "Operations linking each class to the superclasses it declares.

A name that matches no class in the workspace is left alone rather than
recorded: unlike a call, a superclass that is not here is almost always
STANDARD-OBJECT, ERROR, or another part of the language, and reporting those
as unresolved would be noise rather than a staleness signal."
  (let ((index (entities-by-name view '(:class)))
        (ops '()))
    (dolist (class (entities-of-type view :class))
      (dolist (name (getp class :superclass-names))
        (let ((super (unique-match index name)))
          (when (and super (not (eq super class)))
            (push (assert-edge :inherits class super :workspace-id workspace-id) ops)))))
    (nreverse ops)))

(defun eql-specializer-p (name)
  "True for a rendered EQL specializer such as \"(eql :svg)\".
It dispatches on a value, not a class, so there is no class edge to draw."
  (and (plusp (length name)) (char= #\( (char name 0))))

(defun resolve-specializers (view &key workspace-id)
  "Operations linking each method to the classes its parameters dispatch on.

One edge per specialised parameter, which is the whole answer to multiple
dispatch: a method has no owning class, it has as many class edges as it has
specialisers. A parameter specialised on T dispatches on everything and so
says nothing worth recording."
  (let ((index (entities-by-name view '(:class)))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (dolist (specializer (getp method :specializers))
        (unless (or (string-equal specializer "t") (eql-specializer-p specializer))
          (let ((class (unique-match index specializer)))
            (when class
              (push (assert-edge :uses method class :workspace-id workspace-id) ops))))))
    (nreverse ops)))

(defun resolve-method-protocols (view &key workspace-id)
  "Operations linking each method to the generic function it implements.

Only a declared generic: a method whose DEFGENERIC is implicit has no protocol
entity to point at, and ARCH-0001 refuses to synthesise one because there
would be no source region to send an agent to."
  (let ((index (entities-by-name view '(:interface)))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (let ((generic (unique-match index (or (getp method :generic-function)
                                             (name method)))))
        (when generic
          (push (assert-edge :implements method generic :workspace-id workspace-id) ops))))
    (nreverse ops)))

(defun resolve-definitions (view &key workspace-id)
  "Every structural edge the definition forms imply, as one batch."
  (append (resolve-inheritance view :workspace-id workspace-id)
          (resolve-specializers view :workspace-id workspace-id)
          (resolve-method-protocols view :workspace-id workspace-id)))

;;;; ==================================================================
;;;; Generated definitions (ARCH-0002)
;;;; ==================================================================
;;;;
;;;; A name can be brought into existence by a form that does not spell it:
;;;; a DEFSTRUCT slot generates an accessor, a DEFCLASS slot generates a
;;;; generic function, and a call to a definer macro generates whatever its
;;;; template defines. ARCH-0001 indexed the first two and marked them with
;;;; :GENERATED-BY, but a property is not an edge and nothing traversed it --
;;;; measured on Loom's own index, `impact repository 2' reported one row
;;;; while `describe repository-graph', its own accessor, listed six callers.
;;;;
;;;; This pass closes both halves with one edge type. :USES already carries
;;;; impact in the right direction (:REVERSE -- from the thing that changed to
;;;; whatever relied on it), which is exactly generator to generated.

(defun structural-generated-uses (view &key workspace-id)
  "Operations linking each DEFSTRUCT or DEFCLASS generated name to its class.

ARCH-0002 R6, and it needs no analyzer change at all: ARCH-0001 was already
writing :GENERATED-BY on every accessor, constructor, predicate and copier.
Only the edge was missing.

A name matching zero or several classes is left alone, per CON-0001. That
matters more here than it looks: the same property is what the macro half of
this pass writes, naming a macro rather than a class, and a macro is a
:FUNCTION -- so looking the name up in an index of classes is also what keeps
the two halves from crossing."
  (let ((index (entities-by-name view '(:class)))
        (ops '()))
    (dolist (type '(:function :interface))
      (dolist (entity (entities-of-type view type))
        (let ((generator (getp entity :generated-by)))
          (when generator
            (let ((class (unique-match index generator)))
              (when (and class (not (eq class entity)))
                (push (assert-edge :uses entity class :workspace-id workspace-id)
                      ops)))))))
    (nreverse ops)))

;;;; ------------------------------------------------------------------
;;;; Definitions a macro call brings into existence (ARCH-0002 R5, R7)
;;;;
;;;; The registry arrives as an argument rather than being read from
;;;; LOOM-ANALYZER, and that is not a style choice. loom-graph.asd depends on
;;;; loom-ontology alone; RULE-0001 to RULE-0003 put the analyzers above the
;;;; graph and a reference to LOOM-ANALYZER:*MACRO-GENERATORS* here would
;;;; invert the layering as well as failing to compile. LOOM-WORKSPACE is the
;;;; first system that uses both packages, so it is the one that hands the
;;;; shipped half across. That it also makes this pass testable against a
;;;; synthetic registry is a second reason and not the first.
;;;; ------------------------------------------------------------------

(defparameter *generatable-types* '(:function :class :method :test)
  "Entity types a registry entry may declare, and so the types the retract
half has to sweep. Mirrors LOOM-ANALYZER's *TEMPLATE-DEFINER-HEADS* plus
:TEST, which only a shipped entry can name -- no template reads as one.")

(defun workspace-generator-entry (macro)
  "The registry entry a workspace macro contributes from its own template, or
NIL when the analyzer could not characterise it.

An in-tree macro and a shipped framework entry are deliberately the same kind
of thing here: REQ-0003 asks for one table and one pass over it, and nothing
downstream can tell which is which. The one difference is :MACRO, the entity
to point the :USES edge at -- a shipped entry names a macro defined outside
the tree, which has no entity to reach."
  (let ((type (getp macro :generator-entity-type)))
    (when type
      (list :name (string-downcase (name macro))
            :package nil
            :entity-type type
            :name-index (getp macro :generator-name-index)
            :body-index (getp macro :generator-body-index)
            :framework nil
            :macro macro))))

(defun effective-generator-registry (view registry)
  "Downcased macro name -> entries, the shipped REGISTRY plus every workspace
macro carrying its own :GENERATOR-ENTITY-TYPE.

A fresh table: REGISTRY belongs to whoever passed it and a pass that pushed
in-tree entries into it would accumulate a duplicate on every poll."
  (let ((index (make-hash-table :test #'equal)))
    (when registry
      (maphash (lambda (name entries) (setf (gethash name index) (copy-list entries)))
               registry))
    (dolist (macro (entities-of-type view :function))
      (let ((entry (workspace-generator-entry macro)))
        (when entry
          (push entry (gethash (getf entry :name) index)))))
    index))

(defun definer-site-name (site index)
  "The name a call site supplies at INDEX, or NIL when it supplied no name.

NIL is the answer for a computed name -- (test (make-name i) ...) -- and it is
why :SYMBOL-ARGUMENTS is consulted rather than the rendered string. Minting
from a form nobody has evaluated would produce a garbage-named entity that
resolves nothing and never goes away, which is CON-0001's fabricated fact in
its most durable form."
  (let ((arguments (getf site :arguments)))
    (when (and index (member index (getf site :symbol-arguments))
               (<= index (length arguments)))
      (nth (1- index) arguments))))

(defun generated-natural-key (type file name)
  "The natural key a generated entity of TYPE at FILE named NAME will carry.

Read off the declared key rather than assumed to be (:FILE :NAME), so a type
with more parts -- :METHOD's qualifier and specializers -- is looked up under
the key the entity itself will derive rather than under a shorter one that
would never match."
  (let ((spec (find-entity-type type)))
    (when (and spec (entity-type-natural-key spec))
      (cons type (loop for key in (entity-type-natural-key spec)
                       collect (case key
                                 (:name name)
                                 (:file file)
                                 (t nil)))))))

(defun generated-definition-plan (view index)
  "What this pass should produce, and what it had to refuse: two values, a
list of plan plists and a list of (file . name) collisions.

A separate function from the one that emits operations because the collisions
have to be countable without applying anything -- ARCH-0002 requires a
collision to be counted rather than merely not crashing, and R1 forbids
recording it by writing :DEFINER-STATUS onto the macro, which is a property
the analyzer owns."
  (let ((plans '())
        (collisions '()))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        (let ((entries (gethash (string-downcase (getf site :operator)) index)))
          ;; Zero or several entries: left alone, per CON-0001. Several is a
          ;; real possibility rather than a theoretical one -- two packages may
          ;; name a macro identically, which is why the table holds a list --
          ;; and picking one would be the fabricated fact this codebase refuses.
          (when (and entries (null (rest entries))
                     ;; DEF-SUITE's entry declares no type: it exists so the
                     ;; call is recognised as accounted for, not so it mints.
                     (getf (first entries) :entity-type))
            (let* ((entry (first entries))
                   (type (getf entry :entity-type))
                   (path (getp file :path))
                   (name (definer-site-name site (getf entry :name-index))))
              (cond
                ((null name)
                 (push (cons path (getf site :operator)) collisions))
                (t
                 (let ((existing (find-entity-by-key
                                  view (generated-natural-key type path name))))
                   (if (and existing (null (getp existing :generated-by)))
                       ;; A hand-written definition already claims this natural
                       ;; key. Left alone and counted: a macro call that happens
                       ;; to name something a real DEFUN already defines must
                       ;; not clobber it, and an overwrite nobody counted is
                       ;; indistinguishable from nothing having happened.
                       (push (cons path name) collisions)
                       (push (list :type type :file file :site site
                                   :entry entry :name name)
                             plans))))))))))
    (values (nreverse plans) (nreverse collisions))))

(defun declared-properties-only (type plist)
  "PLIST reduced to the properties TYPE declares.

VALIDATE-ENTITY iterates declared properties, so an undeclared one is stored,
never validated, and absent from the schema the ontology exists to be the
single copy of. Filtering here rather than assembling per type keeps the one
list of what a generated entity knows in one place.

The cost is worth naming: :GENERATED-BY is declared on :FUNCTION, :INTERFACE
and :TEST but not on :CLASS or :METHOD, so a macro whose template is a
DEFCLASS or DEFMETHOD mints an entity the retract half below cannot see -- it
keys on exactly that property. No macro in this tree takes that shape and
ARCH-0002 named none, so it is a gap on the record rather than a defect being
worked around; closing it is two property declarations."
  (loop for (key value) on plist by #'cddr
        when (find-property type key)
          append (list key value)))

(defun generated-entity (plan)
  "The entity a definer call site brings into existence.

:ORIGIN-FILE is the *calling* file, never the macro's. That is what makes
RETRACT-FILE clean the entity up when the call site is edited or deleted, and
it is half of what keeps an incrementally updated index identical to a rebuilt
one. The macro's file is reachable through the :USES edge, which is where it
belongs."
  (destructuring-bind (&key type file site entry name) plan
    (let ((path (getp file :path)))
      (make-instance (entity-type-class-name (find-entity-type type))
                     :name name
                     :origin-file path
                     :properties
                     (properties-table
                      (declared-properties-only
                       type
                       (list :file path
                             :start-line (getf site :start-line)
                             :end-line (getf site :end-line)
                             :generated-by (getf entry :name)
                             :call-names (getf site :call-names)
                             :framework (getf entry :framework)
                             :language (getp file :language)
                             ;; ARCH-0009 R6, and the same shortcut :LANGUAGE
                             ;; takes one line up, for the same reason: a
                             ;; macro-minted entity has no form of its own to
                             ;; read a package from, so it takes its file's.
                             :system (getp file :system))))))))

(defun known-generator-names (view registry)
  "Downcased names this pass owns the lifecycle of: every shipped REGISTRY
key, plus the name of every workspace macro currently marked :MACRO-P,
whether or not it presently qualifies as a definer.

Deliberately broader than EFFECTIVE-GENERATOR-REGISTRY, which names only
generators that qualify *right now* -- and :GENERATOR-ENTITY-TYPE is exactly
the property a macro loses the moment its template is edited into a wrapper.
Sweeping against EFFECTIVE-GENERATOR-REGISTRY would make the predicate below
answer NIL for a macro that just stopped qualifying, which is
indistinguishable from a name that was never a macro at all -- the entity it
minted would then never be retracted, and the incremental index would drift
from a rebuilt one for as long as the call site's own file happened not to
change. :MACRO-P persists across that edit because it is set independently
of the generator inspection, so it is what this function reads instead."
  (let ((names (make-hash-table :test #'equal)))
    (when registry
      (maphash (lambda (name entries)
                 (declare (ignore entries))
                 (setf (gethash name names) t))
               registry))
    (dolist (macro (entities-of-type view :function))
      (when (getp macro :macro-p)
        (setf (gethash (string-downcase (name macro)) names) t)))
    names))

(defun generated-entity-retractions (view known-generators produced workspace-id)
  "Retract every entity a registered macro minted that this pass did not
produce again.

This pass owns a lifecycle no earlier resolution pass has had to carry. The
others only assert edges or update properties, and a stale edge is cleaned up
for free when RETRACT-FILE clears its origin file and the next analysis does
not reassert it. A generated entity has no single file whose reanalysis is
guaranteed to invalidate it: a macro can stop qualifying as a definer in its
own file while the call site's file never changes, so nothing retracts what
the call site still asks for and the macro no longer delivers. Recomputing the
full set every pass and taking back the difference is what keeps this a
derivation rather than an accumulation, per DEC-0003, despite creating
entities.

Two ways to get the predicate wrong, both silent.

Keyed on KNOWN-GENERATOR-NAMES, not on the presence of :GENERATED-BY. A
DEFSTRUCT accessor carries that property too -- naming a class rather than a
macro -- so a predicate reading the property alone would retract every
accessor in the tree on the first pass and re-mint none of them. The symptom
would be a large drop in entity count and a flood of newly unresolved calls.
KNOWN-GENERATOR-NAMES, not EFFECTIVE-GENERATOR-REGISTRY, for the reason given
on that function: the latter drops a macro from its index the moment the
macro stops qualifying, which is the one case this predicate exists to catch.

Keyed on absence from PRODUCED, not on anything about the entity. An entity
this pass did produce is a refresh, and a refresh is an upsert by natural key
-- a bare ASSERT-ENTITY. Emitting a retract and an assert for one key in one
transaction would risk the retract removing what the assert had just landed,
depending on the order the operations happen to be applied in."
  (let ((ops '()))
    (dolist (type *generatable-types*)
      (dolist (entity (entities-of-type view type))
        (let ((generator (getp entity :generated-by)))
          (when (and generator
                     (gethash (string-downcase generator) known-generators)
                     (not (gethash (id entity) produced)))
            (push (retract (id entity) workspace-id) ops)))))
    (nreverse ops)))

(defun resolve-generated-definitions (view &key workspace-id registry)
  "Operations for every definition a generator brought into existence.

Both halves of ARCH-0002's R4: the edge from a DEFSTRUCT or DEFCLASS generated
name to its class, which needed no analyzer change because ARCH-0001 was
already writing the property; and the entities a definer macro's call sites
define, which exist nowhere in the source as a DEFUN and so have to be minted.

This is the first resolution pass to create entities, so it is also the first
to owe a retract. The order the operations come back in matters: the asserts
precede the edges that name them, because the Graph Manager resolves an edge's
endpoints against the asserts already planned in the same transaction, and the
retracts come last, naming only entities no assert in this batch touches."
  (let* ((index (effective-generator-registry view registry))
         (produced (make-hash-table :test #'equal))
         (asserts '())
         (edges '()))
    (dolist (plan (generated-definition-plan view index))
      (let ((entity (generated-entity plan))
            (macro (getf (getf plan :entry) :macro)))
        (setf (gethash (id entity) produced) t)
        (push (assert-entity entity workspace-id) asserts)
        ;; No edge when the macro lives outside the tree -- fiveam's TEST is
        ;; the common case -- because there is no entity to point at. The
        ;; :GENERATED-BY property still records what made it.
        (when macro
          (push (assert-edge :uses entity macro :workspace-id workspace-id) edges))))
    (append (structural-generated-uses view :workspace-id workspace-id)
            (nreverse asserts)
            (nreverse edges)
            (generated-entity-retractions
             view (known-generator-names view registry) produced workspace-id))))

(defun generated-definition-collisions (view registry)
  "Every definer call site this pass refused, as (file . name).

Recounted by reading the view rather than recorded while the pass ran, for the
reason ARCH-0002 R1 gives: the obvious place to put the fact -- :DEFINER-STATUS
on the macro's entity -- is a property the analyzer owns and resolution must
not overwrite. Same shape as UNRESOLVED-REFERENCES, and REPOSITORY-STATUS
folds it in the same way."
  (nth-value 1 (generated-definition-plan
                view (effective-generator-registry view registry))))

(defun unhandled-definer-macros (view)
  "Every macro whose template names a definition Loom could not characterise.

ARCH-0002 R6: a macro that looks like a definer and cannot be read statically
is reported, not guessed at. Counted alongside the collisions, because both
are the same thing from a reader's point of view -- a definition the index
knows it is missing."
  (remove-if-not (lambda (entity) (eq :unhandled (getp entity :definer-status)))
                 (entities-of-type view :function)))

(defun call-targets (index name caller)
  "What a call to NAME from CALLER links to: a list of edge plists, each
naming a :CALLEE and, when the link is a guess rather than a fact, the
:CONFIDENCE and :DERIVED-FROM that say so. NIL leaves the name unresolved.

The precedence is ARCH-0001's, and the order of the clauses is the design:

  one plain function     one structural edge. Nothing is being guessed: the
                         name has exactly one definition and the call reaches
                         it.
  any methods            one :inferred edge per method. Dispatch is a union of
                         genuine possibilities, not an ambiguity among
                         mutually exclusive candidates, which is why fanning
                         out is not the fabricated edge CON-0001 forbids.
  one interface, no
  methods                one structural edge to the protocol. A generated slot
                         accessor, or a generic implemented outside the tree:
                         there is nothing to fan out to, and refusing would
                         make the commonest accessor in a CLOS codebase
                         uncallable.
  anything else          unresolved, and recorded as such."
  (let* ((candidates (remove caller (gethash (string-downcase name) index)))
         (functions  (remove-if-not (lambda (e) (eq :function  (entity-type e))) candidates))
         (methods    (remove-if-not (lambda (e) (eq :method    (entity-type e))) candidates))
         (interfaces (remove-if-not (lambda (e) (eq :interface (entity-type e))) candidates)))
    (cond ((and (= 1 (length functions)) (null methods) (null interfaces))
           (list (list :callee (first functions))))
          (methods
           (let ((confidence (dispatch-confidence (length methods)))
                 (generic (when (= 1 (length interfaces)) (id (first interfaces)))))
             (loop for method in methods
                   collect (list :callee method
                                 :confidence confidence
                                 :derived-from (when generic (list generic))))))
          ((= 1 (length interfaces))
           (list (list :callee (first interfaces))))
          (t nil))))

(defparameter *minimum-dispatch-confidence* 0.1
  "The floor for a fanned-out call edge, so a generic with a great many
methods still produces edges a consumer can find rather than ones rounding to
nothing.")

(defun dispatch-confidence (method-count)
  "How much to believe one edge of a fan-out across METHOD-COUNT methods.

1/n, which is worth more than it looks: 70% of the generics in the repository
that motivated ARCH-0001 have exactly one method, and a call to a generic with
one method reaches it with certainty. The number falls away exactly as the
real uncertainty rises, so a consumer filtering on confidence keeps the calls
it can rely on and drops the sixteen-way guesses."
  (if (<= method-count 1)
      1.0
      (max *minimum-dispatch-confidence* (/ 1.0 method-count))))

(defun resolve-calls (view &key workspace-id)
  "Operations linking each recorded call name to the definition it names.

For every callable carrying :CALL-NAMES, each name is looked up in the
workspace:

  exactly one definition  -- assert a :CALLS edge to it
  several definitions     -- record it unresolved rather than guess. Picking
                             one would be a fabricated edge, and asserting all
                             of them would make every caller of a common name
                             look coupled to code it never touches. Precise
                             disambiguation is what SS8.3 defers to LSP.
  none                    -- record it unresolved. It is a genuine external
                             dependency, and a standing record of one.

:UNRESOLVED-CALLS is rewritten from scratch each pass rather than whittled
down, and :CALL-NAMES is never touched. That distinction is what makes the
pipeline's ordering work rather than merely look right. Reanalyzing a file
retracts it first (SS5.4), which destroys the :CALLS edges pointing *into* it
from files that did not change. Those files are not reanalyzed, so the only
record that they call anything is whatever is already on their entities -- and
while this function consumed that record, resolution could not rebuild what the
retract had just destroyed. Deriving instead of consuming means every pass sees
the same question and can answer it again.

Idempotent: an edge that already exists upserts onto itself by natural key, and
a name that resolved last pass resolves to the same edge this pass. Safe to run
after every analysis pass."
  (let ((index (callable-index view))
        (ops '()))
    ;; :TEST alongside the two callables, per ARCH-0002 R8. No new logic: it
    ;; was always a permitted :CALLS source in the ontology and had simply
    ;; never been fed a :CALL-NAMES, because until a resolution pass minted
    ;; one there were no :TEST entities at all.
    (dolist (type '(:function :method :test))
      (dolist (caller (entities-of-type view type))
        (let ((names (getp caller :call-names))
              (linked '())          ; edge plists, reversed
              (left '()))
          (dolist (name names)
            (let ((targets (call-targets index name caller)))
              (if targets
                  (dolist (target targets) (push target linked))
                  (push name left))))
          (dolist (target (nreverse linked))
            (destructuring-bind (&key callee confidence derived-from) target
              (push (if confidence
                        (assert-edge :calls caller callee
                                     :workspace-id workspace-id
                                     :source :inferred
                                     :confidence confidence
                                     :derived-from derived-from)
                        (assert-edge :calls caller callee :workspace-id workspace-id))
                    ops)))
          ;; Unconditional where it used to be (WHEN LINKED ...): a caller
          ;; whose every name went external still has to have that written
          ;; down, and a caller whose callee has since been deleted has to
          ;; have :UNRESOLVED-CALLS grow back.
          (when names
            (push (update-properties (id caller)
                                     (list :unresolved-calls (nreverse left))
                                     workspace-id)
                  ops)))))
    (nreverse ops)))

(defparameter *tested-types* '(:function :method :interface)
  "What a :TESTS edge may be derived onto: exactly the things a :CALLS edge
can terminate at, since that is what this derivation reads.")

(defun resolve-tests (view &key workspace-id)
  "Operations linking each test to the units its body invokes.

ARCH-0002 R9: a :TESTS edge to every :FUNCTION, :METHOD or :INTERFACE the test
already has a :CALLS edge to. Derived from what the body actually calls, which
is the choice worth recording because the ontology's own documentation used to
describe a different one -- \"matched by import graph plus naming
convention\".

Naming conventions do not work for Lisp here. fiveam test names in this
codebase are prose: resolve-links-a-call-to-a-definition-in-another-file names
no function literally, so a naming heuristic would resolve almost nothing and
a looser one would fabricate. The import half describes a mechanism that does
not exist either -- the Lisp analyzer produces no :IMPORTS edges. What a test
calls is available now and safe by construction: a call that does not resolve
simply stays unresolved, exactly as anywhere else. A JS/TS test typically
imports its subject rather than calling it locally, so the import-graph
derivation is the right one there and the wrong one here; the edge type
commits to neither.

Reads the :CALLS edges rather than the :CALL-NAMES property, which is why this
has to run after RESOLVE-CALLS and not merely near it. That is a derivation
from a derivation, and still a derivation -- nothing here is consumed, so a
re-run after a retract rebuilds what the retract destroyed (DEC-0003)."
  (let ((ops '()))
    (dolist (test (entities-of-type view :test))
      (dolist (edge (relationships-from view (id test) :rel-type :calls))
        (let ((target (get-entity view (to-id edge))))
          (when (and target (member (entity-type target) *tested-types*))
            (push (assert-edge :tests test target :workspace-id workspace-id)
                  ops)))))
    (nreverse ops)))

;;;; ==================================================================
;;;; Document links (SS10.3)
;;;; ==================================================================
;;;;
;;;; The same problem in a different costume. A decision's affects: field
;;;; names entities the document analyzer cannot see, for the same reason the
;;;; Lisp analyzer cannot see across a file boundary: SS9.1 keeps analyzers
;;;; stateless. The names ride through as properties and are resolved here,
;;;; where the whole index is in one place.
;;;;
;;;; SS10.3 asks for two mechanisms with different provenance, and the
;;;; difference is the point:
;;;;
;;;;   Declared -- affects:, supersedes:, applies-to:. Someone wrote these
;;;;   down deliberately, so they resolve to :structural edges at confidence
;;;;   1.0, and a name that resolves to nothing is recorded rather than
;;;;   dropped. That record is the documentation staleness detector.
;;;;
;;;;   Mentioned -- names appearing in prose. Nobody promised these, so they
;;;;   resolve to :inferred edges at lower confidence with derived-from
;;;;   populated, which is what makes them go stale when the code moves.

(defparameter *document-types* '(:decision :rule :concept :document)
  "Entity types the documentation analyzer produces.")

(defparameter *declared-link-fields*
  '((:affects    . :decides)
    (:applies-to . :applies-to)
    (:supersedes . :supersedes)
    (:refines    . :refines))
  "Document property -> the relationship type it declares.

:REFINES is the one that points at another document rather than at code, which
LINKABLE-INDEX already supports: it keys on doc-id as well as on name, so
refines: [REQ-0002] finds the requirement. That is what makes the workflow a
graph rather than a filing convention -- the design that answers a requirement,
the plan that sequences the design, and the report of what went wrong are all
one walkable chain.")

(defparameter *mention-confidence* 0.5
  "Confidence for an edge inferred from prose.
Low enough that a caller filtering on confidence drops them, present enough
that \"what decisions touch this?\" answers without the author having
enumerated every consequence.")

(defun linkable-index (view)
  "Name -> entities that a document reference could name.
Keyed on both the entity name and, for documents, the doc-id -- a decision's
supersedes: names another decision by its id, not by a function name."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (entity (all-entities view))
      (when (slot-boundp entity 'name)
        (push entity (gethash (string-downcase (name entity)) index)))
      (let ((doc-id (getp entity :doc-id)))
        (when doc-id
          (pushnew entity (gethash (string-downcase doc-id) index)))))
    index))

(defun resolve-one (index name)
  "The single entity NAME identifies, or NIL when it names none or several.
Refusing an ambiguous name is the same judgement RESOLVE-CALLS makes: a
fabricated edge is worse than a recorded miss.

A generic function and its methods are the exception, and not by relaxing the
rule -- they are not several things sharing a name, they are one protocol and
its implementations, all answering to the protocol's name. A document that
names analyze-file means the contract; picking one of its methods would be
arbitrary and refusing outright reports the reference as rotten when it is
perfectly good. So a candidate set consisting of exactly one :INTERFACE plus
methods resolves to the interface."
  (let ((candidates (gethash (string-downcase name) index)))
    (cond ((null candidates) nil)
          ((null (rest candidates)) (first candidates))
          (t (let ((interfaces (remove-if-not
                                (lambda (e) (eq :interface (entity-type e)))
                                candidates)))
               (when (and (= 1 (length interfaces))
                          (every (lambda (e)
                                   (member (entity-type e) '(:interface :method)))
                                 candidates))
                 (first interfaces)))))))

(defun resolve-document-links (view &key workspace-id)
  "Operations linking each document's declared and mentioned references.

Declared names that resolve become :structural edges of the type their field
declares; the rest are collected onto the document's :UNRESOLVED-REFERENCES,
which is what SS10.3 asks be \"flagged ... counted in status, and exposed
through the API\" instead of quietly discarded. Prose mentions that resolve
become :inferred :DOCUMENTS edges.

Idempotent, like RESOLVE-CALLS: edges upsert by natural key, and a name that
resolved on a previous pass is still in the property, so nothing drifts."
  (let ((index (linkable-index view))
        (ops '()))
    (dolist (type *document-types*)
      (dolist (document (entities-of-type view type))
        (let ((unresolved '()))
          ;; --- declared links ------------------------------------------
          (dolist (field-and-type *declared-link-fields*)
            (dolist (name (getp document (car field-and-type)))
              (let ((target (resolve-one index name)))
                (if (and target (not (eq target document)))
                    (push (assert-edge (cdr field-and-type) document target
                                       :workspace-id workspace-id)
                          ops)
                    (pushnew name unresolved :test #'string=)))))
          ;; --- mentioned links -----------------------------------------
          (dolist (name (getp document :mentions))
            (let ((target (resolve-one index name)))
              (when (and target
                         (not (eq target document))
                         (not (member (entity-type target) *document-types*)))
                (push (assert-edge :documents document target
                                   :workspace-id workspace-id
                                   :source :inferred
                                   :confidence *mention-confidence*
                                   :derived-from (list (id target)))
                      ops))))
          (push (update-properties (id document)
                                   (list :unresolved-references (nreverse unresolved))
                                   workspace-id)
                ops))))
    (nreverse ops)))

(defun unresolved-references (view)
  "Every document reference that named nothing, as (document-name . name).
What the status command reports, per SS3.2."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type view type)
                     append (loop for name in (getp document :unresolved-references)
                                  collect (cons (name document) name)))))
