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
route through generics -- DES-0001 says they do not. It is the target of last
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

(defparameter *module-file-extensions*
  '(".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx")
  "Extensions a module specifier may have left off, in the order tried.

A specifier is written without one -- `import { X } from \'./widget\'` -- and the
file on disk is widget.js, widget.jsx or widget/index.js. Resolution here is
against the *index* and never against the filesystem: loom-graph has no
filesystem and must not acquire one, and a specifier naming a file no analyzer
claimed is a specifier that resolves to nothing, which is the right answer
either way.")

(defun path-segments (path)
  (loop with start = 0
        for pos = (position #\/ path :start start)
        collect (subseq path start (or pos (length path)))
        while pos do (setf start (1+ pos))))

(defun normalize-segments (segments)
  "SEGMENTS with `.', `..' and empty components resolved away."
  (let ((out '()))
    (dolist (segment segments (nreverse out))
      (cond ((or (string= segment ".") (string= segment "")) nil)
            ((string= segment "..") (pop out))
            (t (push segment out))))))

(defun resolve-module-specifier (specifier importer known)
  "The workspace path SPECIFIER names when written in IMPORTER, or NIL.
KNOWN is a table of every file path the index holds.

Relative specifiers only. A bare one -- `react', `lodash' -- names a package
outside the tree, and an aliased one -- `@/components/x' -- needs a bundler
configuration Loom does not read; both resolve to nothing here, which leaves
their call names exactly as unnarrowed as they are today."
  (when (and (stringp specifier) (plusp (length specifier))
             (char= (char specifier 0) #\.))
    (let* ((directory (butlast (path-segments importer)))
           (target (format nil "~{~a~^/~}"
                           (normalize-segments
                            (append directory (path-segments specifier))))))
      (or (and (gethash target known) target)
          (loop for extension in *module-file-extensions*
                for candidate = (concatenate 'string target extension)
                when (gethash candidate known) do (return candidate))
          (loop for extension in *module-file-extensions*
                for candidate = (concatenate 'string target "/index" extension)
                when (gethash candidate known) do (return candidate))))))

(defun build-module-scope (view)
  "File path -> the paths of the files it imports, for module-scoped languages.

Empty for a tree of Common Lisp, which is what makes this cost nothing where it
buys nothing: VISIBLE-CANDIDATES asks the table only after
MODULE-SCOPED-LANGUAGE-P has already said yes."
  (let ((known (make-hash-table :test #'equal))
        (scope (make-hash-table :test #'equal)))
    (dolist (file (entities-of-type view :file))
      (let ((path (getp file :path)))
        (when path (setf (gethash path known) t))))
    (dolist (file (entities-of-type view :file))
      (let ((path (getp file :path)))
        (when (and path (module-scoped-language-p (getp file :language)))
          (let ((targets '()))
            (dolist (specifier (getp file :import-sources))
              (let ((target (resolve-module-specifier specifier path known)))
                (when target (pushnew target targets :test #'equal))))
            (setf (gethash path scope) targets)))))
    scope))

(defun visible-candidates (candidates caller scope)
  "CANDIDATES reduced to the ones the module CALLER is written in can see.

Two tiers, and the order is the language's. A definition in the calling file
shadows every same-named definition elsewhere, so if any candidate is local
the local ones are the whole answer. Otherwise the candidates in files this one
imports are, because a name from a module nobody imported is not in scope at
all.

Never empties the set. Where neither tier applies the original is returned
unchanged, which is what keeps a method call intact: `log.commit()' records the
bare name `commit', and a method is a property of an object rather than a
module binding, so module scope has nothing to say about it. 33 of front-end's
163 fan-outs are that shape and this leaves every one of them as it was. What
the rule can do is reduce a fan-out; what it must never do is refuse a name
this reasoning does not govern."
  (let ((language (and caller (getp caller :language)))
        (file     (and caller (getp caller :file))))
    (if (or (null scope) (null file) (not (module-scoped-language-p language)))
        candidates
        (let ((local (remove-if-not (lambda (e) (equal file (getp e :file)))
                                    candidates)))
          (or local
              (let ((visible (gethash file scope)))
                (and visible
                     (remove-if-not (lambda (e)
                                      (member (getp e :file) visible :test #'equal))
                                    candidates)))
              candidates)))))

(defstruct (name-lookup (:constructor %make-name-lookup))
  "Entities under a name, keyed two ways (DES-0015).

BY-NAME is CALLABLE-INDEX, name to definitions, and stays the answer whenever
symbol identity cannot be established. BY-HOME is keyed on (home-package .
name), which is the identity a Common Lisp callable actually has.

Both, rather than one, because HOME-PACKAGE cannot place every name -- 8 of
Loom's 11 package-spanning names and 54 of game-server's 95, measured
2026-08-10, because their packages use packages no declaration in the tree
describes. Falling back to BY-NAME for those makes this strictly more precise
or identical: a name that can be placed resolves against its own package, and
a name that cannot resolves exactly as it did before. Nothing this cannot
place can regress, which is what lets game-server's 7085 at-risk edges move in
one step and still be reviewable."
  (by-name       (make-hash-table :test #'equal) :type hash-table)
  (by-home       (make-hash-table :test #'equal) :type hash-table)
  (package-graph nil)
  ;; BUG-0035. Empty on a tree with no module-scoped language in it, and
  ;; consulted only after MODULE-SCOPED-LANGUAGE-P has said the caller is
  ;; written in one, so a Lisp-only tree pays one empty table.
  (module-scope  (make-hash-table :test #'equal) :type hash-table))

(defun name-lookup (view types &key external-packages package-graph)
  "ENTITIES-BY-NAME plus the package-aware index over the same entities.

PACKAGE-GRAPH may be supplied by a caller resolving several kinds of name in
one pass, so the graph is assembled once rather than once per index."
  (let* ((by-name (entities-by-name view types))
         (pg (or package-graph
                 (build-package-graph view :external-packages external-packages)))
         (by-home (make-hash-table :test #'equal)))
    (maphash (lambda (name entities)
               (dolist (e entities)
                 (let ((home (entity-home-package pg e name)))
                   (when home
                     (push e (gethash (cons home name) by-home))))))
             by-name)
    (%make-name-lookup :by-name by-name :by-home by-home :package-graph pg
                       :module-scope (build-module-scope view))))

(defun callable-lookup (view &key external-packages package-graph)
  "The callable half of NAME-LOOKUP, which is what RESOLVE-CALLS wants."
  (name-lookup view *callable-types*
               :external-packages external-packages :package-graph package-graph))

(defun same-identifier-p (a b language-a language-b)
  "True when the identifiers A and B, written in LANGUAGE-A and LANGUAGE-B, are
the same identifier.

Case is folded only when *both* languages fold it. That asymmetry is the whole
of BUG-0029: the index is keyed on a downcased name and therefore matches
`error\' to `Error\', which is right for two Common Lisp symbols and wrong for
two JavaScript ones. Requiring both sides rather than either is the
conservative reading -- a pair that disagrees about case gets the strict rule,
so a language Loom has never seen cannot inherit Lisp\'s folding by being
compared against a Lisp definition."
  (if (and (case-insensitive-language-p language-a)
           (case-insensitive-language-p language-b))
      (string-equal a b)
      (string= a b)))

(defun same-identifier-candidates (candidates name caller)
  "CANDIDATES reduced to those whose name really is NAME, read from CALLER.

The downcased index is a *search structure* after BUG-0029 and not the
equality itself: it returns a superset keyed on a fold every language may not
share, and this is where the pair-wise judgement happens. It has to be
pair-wise, because whether two spellings are one identifier depends on both
languages and no single hash key can express that.

A NIL CALLER keeps the whole set. That is RESOLVE-GENERATED-DEFINITIONS asking
whether a name reaches anything at all, with nothing to take a language from,
and the old answer is the only one available."
  (let ((language (and caller (getp caller :language))))
    (if (null caller)
        candidates
        (remove-if-not (lambda (entity)
                         (and (slot-boundp entity 'name)
                              (same-identifier-p name (name entity)
                                                 language (getp entity :language))))
                       candidates))))

(defun candidate-entities (index name caller)
  "The definitions NAME could name, as read from CALLER.

INDEX may be a bare hash table, which is what CALLABLE-INDEX returns and what
every caller passed before DES-0015. That path is the old behaviour exactly,
which is why tools/call-site-census.lisp keeps working unchanged and why a
CALLER of NIL -- RESOLVE-GENERATED-DEFINITIONS asking whether a name reaches
anything at all -- still gets the unrestricted answer.

Both index paths are filtered through SAME-IDENTIFIER-CANDIDATES on the way
out, including the package-placed one: DES-0015 establishes that a name is one
*symbol*, which is a Common Lisp question, and answering it does not make the
spelling right in a language that has no packages.

VISIBLE-CANDIDATES follows it on the NAME-LOOKUP path, and only there: the
bare-hash-table path is RESOLVE-GENERATED-DEFINITIONS asking whether a definer
name reaches anything at all, which is a Common Lisp question about a tree with
no module scope in it. The two filters compose in the order they are named --
which spellings are this identifier, then which of those this module can see --
and neither can ever add a candidate."
  (let ((key (string-downcase name)))
    (flet ((admit (candidates)
             (visible-candidates
              (same-identifier-candidates candidates name caller)
              caller
              (and (typep index 'name-lookup) (name-lookup-module-scope index)))))
      (etypecase index
        (hash-table (values (admit (gethash key index)) nil))
        (name-lookup
         (let* ((home (and caller
                           (home-package (name-lookup-package-graph index)
                                         name (entity-package caller))))
                (placed (and home (gethash (cons home key)
                                           (name-lookup-by-home index)))))
           ;; The second value says whether symbol identity was established.
           ;; A caller that fans out across the candidate set needs to know:
           ;; fanning across a set assembled by spelling alone would assert
           ;; edges between definitions that share nothing but a name, which is
           ;; the fabrication DES-0015 exists to stop.
           (if placed
               (values (admit placed) t)
               (values (admit (gethash key (name-lookup-by-name index))) nil))))))))

(defun unique-match (index name &optional referrer)
  "The one entity INDEX holds under NAME as REFERRER sees it, or NIL for none
or several.

REFERRER is what makes this package-aware: a superclass or a specialiser named
in two packages matched several candidates and therefore resolved to nothing,
which is CON-0001 refusing to guess. Given the referring entity, the candidates
are those NAME actually reaches from where it was written, so the honest answer
is often one. A NIL REFERRER, or an INDEX that is a bare hash table, is the old
behaviour exactly."
  (let ((candidates (candidate-entities index name referrer)))
    (when (and candidates (null (rest candidates)))
      (first candidates))))

;;;; ==================================================================
;;;; Structure: inheritance, dispatch, and protocols (DES-0001)
;;;; ==================================================================
;;;;
;;;; Three more kinds of cross-file name, resolved the same way calls are and
;;;; for the same reason: a superclass, a specializer and a generic can each be
;;;; declared in a file the analyzer was not looking at. Each is derived from a
;;;; property the analyzer wrote and never rewrites, per DEC-0003, so an edge
;;;; destroyed by retracting the file it pointed into comes back on the next
;;;; pass.

(defun resolve-inheritance (view &key workspace-id package-graph)
  "Operations linking each class to the superclasses it declares.

A name that matches no class in the workspace is left alone rather than
recorded: unlike a call, a superclass that is not here is almost always
STANDARD-OBJECT, ERROR, or another part of the language, and reporting those
as unresolved would be noise rather than a staleness signal."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (class (entities-of-type view :class))
      (dolist (name (getp class :superclass-names))
        (let ((super (unique-match index name class)))
          (when (and super (not (eq super class)))
            (push (assert-edge :inherits class super :workspace-id workspace-id) ops)))))
    (nreverse ops)))

(defun eql-specializer-p (name)
  "True for a rendered EQL specializer such as \"(eql :svg)\".
It dispatches on a value, not a class, so there is no class edge to draw."
  (and (plusp (length name)) (char= #\( (char name 0))))

(defun resolve-specializers (view &key workspace-id package-graph)
  "Operations linking each method to the classes its parameters dispatch on.

One edge per specialised parameter, which is the whole answer to multiple
dispatch: a method has no owning class, it has as many class edges as it has
specialisers. A parameter specialised on T dispatches on everything and so
says nothing worth recording."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (dolist (specializer (getp method :specializers))
        (unless (or (string-equal specializer "t") (eql-specializer-p specializer))
          (let ((class (unique-match index specializer method)))
            (when class
              (push (assert-edge :uses method class :workspace-id workspace-id) ops))))))
    (nreverse ops)))

(defun resolve-method-protocols (view &key workspace-id package-graph)
  "Operations linking each method to the generic function it implements.

Only a declared generic: a method whose DEFGENERIC is implicit has no protocol
entity to point at, and DES-0001 refuses to synthesise one because there
would be no source region to send an agent to."
  (let ((index (name-lookup view '(:interface) :package-graph package-graph))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (let ((generic (unique-match index (or (getp method :generic-function)
                                             (name method)))))
        (when generic
          (push (assert-edge :implements method generic :workspace-id workspace-id) ops))))
    (nreverse ops)))

(defun resolve-definitions (view &key workspace-id external-packages)
  "Every structural edge the definition forms imply, as one batch.

The package graph is assembled once and shared: all three passes below resolve
a name against the same declarations, and building it three times would be
three walks of every :PACKAGE entity for one answer."
  (let ((pg (build-package-graph view :external-packages external-packages)))
    (append (resolve-inheritance view :workspace-id workspace-id :package-graph pg)
            (resolve-specializers view :workspace-id workspace-id :package-graph pg)
            (resolve-method-protocols view :workspace-id workspace-id :package-graph pg))))

;;;; ==================================================================
;;;; Generated definitions (DES-0002)
;;;; ==================================================================
;;;;
;;;; A name can be brought into existence by a form that does not spell it:
;;;; a DEFSTRUCT slot generates an accessor, a DEFCLASS slot generates a
;;;; generic function, and a call to a definer macro generates whatever its
;;;; template defines. DES-0001 indexed the first two and marked them with
;;;; :GENERATED-BY, but a property is not an edge and nothing traversed it --
;;;; measured on Loom's own index, `impact repository 2' reported one row
;;;; while `describe repository-graph', its own accessor, listed six callers.
;;;;
;;;; This pass closes both halves with one edge type. :USES already carries
;;;; impact in the right direction (:REVERSE -- from the thing that changed to
;;;; whatever relied on it), which is exactly generator to generated.

(defun structural-generated-uses (view &key workspace-id package-graph)
  "Operations linking each DEFSTRUCT or DEFCLASS generated name to its class.

DES-0002 R6, and it needs no analyzer change at all: DES-0001 was already
writing :GENERATED-BY on every accessor, constructor, predicate and copier.
Only the edge was missing.

A name matching zero or several classes is left alone, per CON-0001. That
matters more here than it looks: the same property is what the macro half of
this pass writes, naming a macro rather than a class, and a macro is a
:FUNCTION -- so looking the name up in an index of classes is also what keeps
the two halves from crossing."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (type '(:function :interface))
      (dolist (entity (entities-of-type view type))
        (let ((generator (getp entity :generated-by)))
          (when generator
            (let ((class (unique-match index generator entity)))
              (when (and class (not (eq class entity)))
                (push (assert-edge :uses entity class :workspace-id workspace-id)
                      ops)))))))
    (nreverse ops)))

;;;; ------------------------------------------------------------------
;;;; Definitions a macro call brings into existence (DES-0002 R5, R7)
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

(defun normalize-route (route)
  "ROUTE with a leading and trailing `/' stripped, or NIL.

DES-0025 D1, and deliberately the whole of the normalization. game-server
writes \"/public/game/create\" and front-end writes \"public/game/create\";
that one character is the entire difference between the two trees, measured
rather than assumed. Inventing more -- case folding, collapsing a trailing
segment, treating a parameter as a wildcard -- is how a matcher starts
producing joins nobody wrote."
  (let ((trimmed (and (stringp route) (string-trim "/" route))))
    (when (and trimmed (plusp (length trimmed))) trimmed)))

(defun definer-site-literal (site index)
  "The string literal a call site supplied at INDEX, or NIL.

:STRING-ARGUMENTS' counterpart to DEFINER-SITE-NAME above, and NIL for the
same class of reason: a site that computed its route rather than spelling it
supplies nothing here, and a route built at runtime is not a claim this pass
can honestly record."
  (when index
    (cdr (assoc index (getf site :string-arguments)))))

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
have to be countable without applying anything -- DES-0002 requires a
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
                   (if (and existing (null (getp existing :generated-by))
                            ;; ...unless the image put it there. An
                            ;; :INTROSPECTED entity is this same definition seen
                            ;; from the other side -- the compiler reporting
                            ;; what the macro call expanded into -- so reading
                            ;; it as a hand-written claim would make the first
                            ;; enrich the last one that could mint: the key
                            ;; would stay occupied, every later pass would
                            ;; report a collision, and the :USES edge back to
                            ;; the generator would never be drawn. Minting over
                            ;; it is the upsert the two passes are supposed to
                            ;; meet in (DES-0011 R6).
                            (not (eq :introspected (source existing))))
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
DES-0002 named none, so it is a gap on the record rather than a defect being
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
                             ;; DES-0025 D1. Present only for a declared
                             ;; :ROUTE-INDEX, which is absent on every definer
                             ;; that defines no endpoint -- that is, on all of
                             ;; them but one so far.
                             :routes (let ((route (normalize-route
                                                   (definer-site-literal
                                                    site (getf entry :route-index)))))
                                       (when route (list route)))
                             :route-role (when (definer-site-literal
                                                site (getf entry :route-index))
                                           :publishes)
                             :language (getp file :language)
                             ;; DES-0009 R6, and the same shortcut :LANGUAGE
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

(defun call-site-retractions (view kind produced workspace-id)
  "Retract every :CALL-SITE of KIND this pass did not produce again.

DES-0014 R6 says RETRACT-FILE needs nothing, and that is true of exactly one
of the three kinds. An initform site is derived from one file, so editing that
file removes it and the next analysis re-derives it. The graph's two are not:
an ambiguous site's origin file is the *caller's*, so deleting one of two
colliding definitions from a third file leaves the site behind with a live edge
to the survivor while the caller also acquires its own direct edge -- one call
reported twice, at two different confidences. A definer site's is the calling
file, so a macro that becomes characterised in its own file leaves the call
sites its calls used to orphan, beside the definition that now carries the same
names.

Both traps GENERATED-ENTITY-RETRACTIONS records apply here unchanged. The
retracts go last in the batch and name only entities no assert in it touches,
which is what keying on absence from PRODUCED buys: a site this pass did
produce is a refresh, and a refresh is an upsert by natural key, so emitting a
retract and an assert for one key in one transaction would risk the retract
removing what the assert had just landed.

KIND is the third condition and it is not a convenience. Each pass owns exactly
one referrer kind, and a sweep keyed on absence alone would retract every one
of the analyzer's sites on its first run and re-mint none of them -- the same
shape of silent, total loss that reading :GENERATED-BY alone would have had."
  (let ((ops '()))
    (dolist (site (entities-of-type view :call-site))
      (when (and (eq kind (getp site :referrer-kind))
                 (not (gethash (id site) produced)))
        (push (retract (id site) workspace-id) ops)))
    (nreverse ops)))

(defun definer-call-site-entities (view index minted)
  "One :CALL-SITE per resolving call name on a definer call site that minted no
definition, as a list of (file . entity) pairs.

BUG-0016's second half. A macro whose expansion is a runtime table entry --
DEFINE-OPERATION, DEFINE-COMMAND -- swallows a real body, and the names in it
reach no entity at all: there is no definition to source a :CALLS edge at, so
every REST route and every MCP tool is invisible in the call graph. The call
site is the node DES-0014 mints to be that source.

MINTED is the set of site plists GENERATED-DEFINITION-PLAN produced an entity
from, keyed by identity, which is why no second predicate is written: the plan
already carries the site in its :SITE key, so the two populations cannot
disagree about which sites minted. That disjointness is also what keeps the two
kinds of key apart -- a generated definition's start line is its site's start
line, so DES-0014's uniqueness argument (\"a definer call site cannot begin on
a definition's line\") holds only because a site that mints one never mints the
other.

Only where CALL-TARGETS returns something, which is PLAN-0014 decision 2 rather
than R4's literal text. Measured on this tree, R4 read literally is 266 nodes
of which 142 name something that is not in the workspace at all -- against
DES-0014's own R9 (\"expected order 100\") and against its own census
reasoning, that a node per absent callee is a node per thing that is not there.
A name that resolves to nothing carries no edge, and the fact that it went
nowhere already lives on the site's :CALL-NAMES and in `check''s definer-macro
report. The asymmetry with the analyzer's initform sites, which mint all 20, is
deliberate: the analyzer holds no callable index and cannot ask this question."
  (let ((pairs '()))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        (unless (gethash site minted)
          (dolist (name (getf site :call-names))
            (when (call-targets index name nil)
              (push (cons file
                          (make-call-site-entity
                           :file (getp file :path)
                           :start-line (getf site :start-line)
                           :end-line (getf site :end-line)
                           :call-name name
                           :referrer-kind :definer-call
                           :generated-by (getf site :operator)
                           ;; The file's, not re-decided: a call site read out
                           ;; of a macro call has no form of its own to take a
                           ;; package from, the same shortcut GENERATED-ENTITY
                           ;; takes one function up (DES-0009 R6).
                           :language (getp file :language)
                           :system (getp file :system)))
                    pairs))))))
    (nreverse pairs)))

(defun resolve-generated-definitions (view &key workspace-id registry external-packages)
  "Operations for every definition a generator brought into existence.

Both halves of DES-0002's R4: the edge from a DEFSTRUCT or DEFCLASS generated
name to its class, which needed no analyzer change because DES-0001 was
already writing the property; and the entities a definer macro's call sites
define, which exist nowhere in the source as a DEFUN and so have to be minted.

This is the first resolution pass to create entities, so it is also the first
to owe a retract. The order the operations come back in matters: the asserts
precede the edges that name them, because the Graph Manager resolves an edge's
endpoints against the asserts already planned in the same transaction, and the
retracts come last, naming only entities no assert in this batch touches."
  (let* ((index (effective-generator-registry view registry))
         (produced (make-hash-table :test #'equal))
         ;; The sites that minted, keyed by identity, so the call-site half
         ;; below can tell an orphaned site from an accounted-for one without
         ;; re-deciding it.
         (minted (make-hash-table :test #'eq))
         ;; The call sites this pass produced, for the sweep below. Kept apart
         ;; from PRODUCED, which GENERATED-ENTITY-RETRACTIONS reads against a
         ;; different type list and a different predicate.
         (produced-sites (make-hash-table :test #'equal))
         (asserts '())
         (edges '()))
    (dolist (plan (generated-definition-plan view index))
      (let ((entity (generated-entity plan))
            (macro (getf (getf plan :entry) :macro)))
        (setf (gethash (id entity) produced) t)
        (setf (gethash (getf plan :site) minted) t)
        (push (assert-entity entity workspace-id) asserts)
        ;; No edge when the macro lives outside the tree -- fiveam's TEST is
        ;; the common case -- because there is no entity to point at. The
        ;; :GENERATED-BY property still records what made it.
        (when macro
          (push (assert-edge :uses entity macro :workspace-id workspace-id) edges))))
    ;; BUG-0016's second half. CALLABLE-INDEX of this same view is stable
    ;; between here and RESOLVE-CALLS, because neither pass mints a :FUNCTION,
    ;; :METHOD or :INTERFACE -- so a name that resolves here resolves there too,
    ;; and a call site is never minted for an edge that will not be drawn.
    (let ((callables (callable-index view)))
      (dolist (pair (definer-call-site-entities view callables minted))
        (destructuring-bind (file . site) pair
          (setf (gethash (id site) produced-sites) t)
          (push (assert-entity site workspace-id) asserts)
          (push (assert-edge :contains file site :workspace-id workspace-id) edges))))
    (append (structural-generated-uses
             view :workspace-id workspace-id
             :package-graph (build-package-graph
                             view :external-packages external-packages))
            (nreverse asserts)
            (nreverse edges)
            (generated-entity-retractions
             view (known-generator-names view registry) produced workspace-id)
            (call-site-retractions view :definer-call produced-sites workspace-id))))

(defun generated-definition-collisions (view registry)
  "Every definer call site this pass refused, as (file . name).

Recounted by reading the view rather than recorded while the pass ran, for the
reason DES-0002 R1 gives: the obvious place to put the fact -- :DEFINER-STATUS
on the macro's entity -- is a property the analyzer owns and resolution must
not overwrite. Same shape as UNRESOLVED-REFERENCES, and REPOSITORY-STATUS
folds it in the same way."
  (nth-value 1 (generated-definition-plan
                view (effective-generator-registry view registry))))

(defun body-swallowing-macro-names (view)
  "Downcased names of macros whose calls stand as top-level forms carrying call
names of their own.

The discriminator BUG-0016 identified and left unused. A macro whose template
contains no DEFUN, DEFCLASS or DEFMETHOD claims to define nothing, and
MACRO-GENERATOR-PROPERTIES deliberately records nothing for it -- its docstring
is right that flagging every wrapper would put every WITH-LOCK in the tree into
a count that exists to be read and acted on. But a WITH-LOCK is never a
top-level form, and DEFINE-OPERATION is nothing but: its calls appear in
:DEFINER-CALL-SITES with non-empty :CALL-NAMES, which is the signature of a
macro swallowing real bodies whose calls then reach no entity at all.

Read from the whole workspace rather than from one file, because that is where
the fact lives and it is the reason this is not the analyzer's job.
DEFINE-OPERATION is defined in src/serve/registry.lisp and called in three
other files, so no file-scoped analyzer can see both halves (RULE-0002). Of
BUG-0016's two FIX options for counting, this is why the second -- decide it
where the whole tree is visible -- is the one taken.

Returns a table of name -> how many distinct call names its sites orphan,
because the count is what makes the report readable and the bare predicate does
not separate two populations that look alike from here. Measured on this tree:
DEFINE-OPERATION 42 and DEFINE-COMMAND 70, both of them real calls into
loom-knowledge, against DEFRELATIONSHIP's 12 -- which are `decision',
`document', `file' and the like, the heads of the keyword lists in its :FROM
and :TO arguments rather than calls to anything. That is COLLECT-CALL-NAMES'
own imprecision showing through: it reads the head of any non-quoted list as an
operator, and a keyword is a symbol. Both populations are honest members of
this count -- a macro whose declarations the ontology cannot model really is a
gap -- but only the first is a dropped call, so the number travels with the
name rather than being folded away."
  (let ((names (make-hash-table :test #'equal)))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        ;; :OPERATOR is already TOKEN-NAME's downcased rendering, so it is
        ;; comparable with (STRING-DOWNCASE (NAME macro)) without further folding.
        (let ((call-names (getf site :call-names)))
          (when call-names
            (setf (gethash (getf site :operator) names)
                  (union call-names (gethash (getf site :operator) names)
                         :test #'string=))))))
    (let ((counts (make-hash-table :test #'equal)))
      (maphash (lambda (operator call-names)
                 (setf (gethash operator counts) (length call-names)))
               names)
      counts)))

(defun unhandled-definer-macros (view)
  "Every macro whose expansion Loom could not read, in either of the two ways
that can happen.

DES-0002 R6: a macro that looks like a definer and cannot be read statically
is reported, not guessed at. Counted alongside the collisions, because both
are the same thing from a reader's point of view -- a definition the index
knows it is missing.

Two populations, summed into one list because a reader wants one answer to
\"what is the index missing\":

  :DEFINER-STATUS :UNHANDLED   the template defines something and the name is
                               computed -- INTERN or FORMAT -- so it cannot be
                               read without running the code that builds it.
  a body-swallowing macro      the template defines nothing this ontology
                               models, and yet the macro's call sites carry
                               call names, which therefore attach to nothing.

The second population is BUG-0016, and adding it is what stops `status'
reporting one gap on a tree that has two kinds. Before this, DEFINE-OPERATION's
15 call sites orphaned 42 distinct names -- every REST route and every MCP tool
invisible in the call graph -- and the tool whose job is to report gaps
reported this one as no gap. Silence that reads as success is the failure
CON-0001 exists to prevent, and it is worse here than a wrong number would be.

Reporting is all this does. What a DEFINE-OPERATION call should actually mint
is an ontology question BUG-0016 declined to settle inside a bug fix and
DES-0014 answers separately."
  (let ((swallowing (body-swallowing-macro-names view)))
    (remove-if-not
     (lambda (entity)
       (or (eq :unhandled (getp entity :definer-status))
           (and (getp entity :macro-p)
                (null (getp entity :generator-entity-type))
                (null (getp entity :definer-status))
                (gethash (string-downcase (name entity)) swallowing))))
     (entities-of-type view :function))))

(defun call-targets (index name caller)
  "What a call to NAME from CALLER links to: a list of edge plists, each
naming a :CALLEE and, when the link is a guess rather than a fact, the
:CONFIDENCE and :DERIVED-FROM that say so. NIL leaves the name unresolved.

The precedence is DES-0001's, and the order of the clauses is the design:

  one plain function     one structural edge. Nothing is being guessed: the
                         name has exactly one definition and the call reaches
                         it.
  any methods, or two
  or more accessor-
  generated interfaces   one :inferred edge per dispatch target. Dispatch is a
                         union of genuine possibilities, not an ambiguity among
                         mutually exclusive candidates, which is why fanning
                         out is not the fabricated edge CON-0001 forbids.

                         An accessor-generated :INTERFACE is a dispatch target
                         and not a rival protocol (REQ-0020). `:accessor id\' on
                         six classes is one generic function acquiring six
                         methods, and Loom mints an :INTERFACE for each because
                         no DEFGENERIC was written -- so a name with N of them
                         and no methods used to match no clause at all and
                         resolve to nothing. That was BUG-0021 on game-server:
                         144 dropped call sites for `id\'.

                         Only when the candidate set was package-placed. Fanning
                         out across a set assembled by spelling alone would
                         assert edges between accessors of genuinely different
                         generics -- the fabrication BUG-0021 warned the cheap
                         fix would cause -- so an unplaced set keeps the old
                         answer.
  one interface, no
  methods                one structural edge to the protocol. A generated slot
                         accessor, or a generic implemented outside the tree:
                         there is nothing to fan out to, and refusing would
                         make the commonest accessor in a CLOS codebase
                         uncallable.
  two or more plain
  functions              one edge per candidate at 1/N, sourced at a
                         :CALL-SITE the caller contains rather than at the
                         caller (REQ-0015, DES-0014).
  anything else          unresolved, and recorded as such.

A target may carry :CALL-SITE, the entity the edge runs from instead of CALLER.
RESOLVE-CALLS is what asserts it, because only the caller of this function is
in a transaction.

CALLER may be NIL, which asks the bare question \"does this name reach
anything\" without a caller to remove from the candidates or to hang a node on.
RESOLVE-GENERATED-DEFINITIONS asks it that way, so it can decide whether an
orphaned definer name is worth a call site at all."
  (multiple-value-bind (all placedp) (candidate-entities index name caller)
   (let* ((candidates (remove caller all))
         (functions  (remove-if-not (lambda (e) (eq :function  (entity-type e))) candidates))
         (methods    (remove-if-not (lambda (e) (eq :method    (entity-type e))) candidates))
         (interfaces (remove-if-not (lambda (e) (eq :interface (entity-type e))) candidates))
         ;; An :INTERFACE carrying :GENERATED-BY was synthesised from a slot
         ;; declaration -- `:accessor id\' -- rather than written as a
         ;; DEFGENERIC. It is one method of a generic function, not a protocol
         ;; of its own, and the analyzer already records which is which.
         (accessors  (remove-if-not (lambda (e) (getp e :generated-by)) interfaces))
         (protocols  (remove-if     (lambda (e) (getp e :generated-by)) interfaces))
         ;; Fan out over accessors only where the candidate set is one
         ;; symbol\'s. REQ-0020 R5 and BUG-0021\'s ordering argument.
         (dispatch   (append methods (if placedp accessors '()))))
    (cond ((and (= 1 (length functions)) (null methods) (null interfaces))
           (list (list :callee (first functions))))
          ((or methods (rest dispatch))
           (let ((confidence (dispatch-confidence (length dispatch)))
                 (generic (when (= 1 (length protocols)) (id (first protocols)))))
             (loop for target in dispatch
                   collect (list :callee target
                                 :confidence confidence
                                 :derived-from (when generic (list generic))))))
          ((= 1 (length interfaces))
           (list (list :callee (first interfaces))))
          ;; REQ-0015. The clauses above have already excluded every case with
          ;; a method or with exactly one interface, so two or more plain
          ;; functions is all that is left to test -- which is also exactly
          ;; CLASSIFY-CALL's :AMBIGUOUS clause in tools/call-site-census.lisp,
          ;; and the two have to keep agreeing for the census to measure this
          ;; pass rather than something adjacent to it.
          ;;
          ;; DISPATCH-CONFIDENCE, the same 1/N the method fan-out uses, but the
          ;; edges do not mean the same thing and the node is the difference.
          ;; Dispatch is a union of genuine possibilities, so it runs from the
          ;; caller; ambiguity is one call the resolver could not place, and
          ;; running N edges from the caller is what CALL-TARGETS' docstring has
          ;; always refused -- every caller of a common name looking coupled to
          ;; code it never touches. One hop away and labelled, it is a report of
          ;; a guess rather than a fabricated fact (CON-0001).
          ((>= (length functions) 2)
           (let ((confidence (dispatch-confidence (length functions)))
                 ;; Decision 6: a call site is already an anchor for an
                 ;; ambiguity, so it fans out directly. Minting a second node
                 ;; from the first one's file and line would recur on every
                 ;; pass. A NIL caller has nothing to build a node from and is
                 ;; only asking whether the name reaches anything, so it takes
                 ;; the same branch.
                 (directp (or (null caller)
                              (eq :call-site (entity-type caller)))))
             (let ((site (unless directp
                           (make-call-site-entity
                            :file (getp caller :file)
                            :start-line (getp caller :start-line)
                            :end-line (getp caller :end-line)
                            :call-name name
                            :referrer-kind :ambiguous
                            :candidate-count (length functions)
                            :language (getp caller :language)
                            :system (getp caller :system)))))
               (loop for candidate in functions
                     collect (list :callee candidate
                                   :confidence confidence
                                   :call-site site)))))
          (t nil)))))

(defparameter *minimum-dispatch-confidence* 0.1
  "The floor for a fanned-out call edge, so a generic with a great many
methods still produces edges a consumer can find rather than ones rounding to
nothing.")

(defun dispatch-confidence (method-count)
  "How much to believe one edge of a fan-out across METHOD-COUNT methods.

1/n, which is worth more than it looks: 70% of the generics in the repository
that motivated DES-0001 have exactly one method, and a call to a generic with
one method reaches it with certainty. The number falls away exactly as the
real uncertainty rises, so a consumer filtering on confidence keeps the calls
it can rely on and drops the sixteen-way guesses."
  (if (<= method-count 1)
      1.0
      (max *minimum-dispatch-confidence* (/ 1.0 method-count))))

(defun caller-call-names (caller)
  "The call names CALLER records, whatever kind of caller it is.

A :CALL-SITE is one call, so its names are the one-element list holding its
:CALL-NAME. Every other caller carries the list the analyzer wrote on it.

Deriving rather than reading a stored :CALL-NAMES is what keeps the referenced
name in exactly one place on a call site: :CALL-NAME is a natural-key
component, so a stored copy that drifted from it would leave the entity
resolving one name while keying on another, and nothing downstream could tell.
DES-0014, PLAN-0014 step 4."
  (if (eq :call-site (entity-type caller))
      (let ((name (getp caller :call-name)))
        (when name (list name)))
      (getp caller :call-names)))

(defun resolve-calls (view &key workspace-id external-packages)
  "Operations linking each recorded call name to the definition it names.

For every callable carrying :CALL-NAMES, each name is looked up in the
workspace:

  exactly one definition  -- assert a :CALLS edge to it
  several definitions     -- assert an ambiguous :CALL-SITE the caller
                             contains, and one edge from it to each candidate
                             at 1/N (REQ-0015). The caller still acquires no
                             direct edge, which is the false coupling this
                             clause has always refused; what changes is that
                             the refusal is now reportable rather than silent.
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
  (let ((index (callable-lookup view :external-packages external-packages))
        ;; The ambiguous call sites this pass produced, keyed by id: the
        ;; dedupe for the asserts below and the produced set for the sweep at
        ;; the end, which are the same question asked twice.
        (asserted (make-hash-table :test #'equal))
        (ops '()))
    ;; :TEST alongside the two callables, per DES-0002 R8. No new logic: it
    ;; was always a permitted :CALLS source in the ontology and had simply
    ;; never been fed a :CALL-NAMES, because until a resolution pass minted
    ;; one there were no :TEST entities at all.
    ;;
    ;; :CALL-SITE is the fourth, and it is the same move for the same reason
    ;; (DES-0014). A call site is one more kind of caller, so the fan-out, the
    ;; confidence handling, the :UNRESOLVED-CALLS write and DEC-0003's rebuild
    ;; property all apply to it without a second copy of any of them. The only
    ;; thing that differs is where the names come from, which is
    ;; CALLER-CALL-NAMES' whole job.
    (dolist (type '(:function :method :test :call-site))
      (dolist (caller (entities-of-type view type))
        (let ((names (caller-call-names caller))
              (linked '())          ; edge plists, reversed
              (left '()))
          (dolist (name names)
            (let ((targets (call-targets index name caller)))
              (if targets
                  (dolist (target targets) (push target linked))
                  (push name left))))
          ;; A target may name the :CALL-SITE its edge runs from rather than the
          ;; caller, which is REQ-0015's fan-out. The site is asserted once and
          ;; its :CONTAINS edge from the caller with it, both before the :CALLS
          ;; edges naming it, because the Graph Manager resolves an edge's
          ;; endpoints against the asserts already planned in the same
          ;; transaction. Keyed on id rather than on identity: CALL-TARGETS
          ;; builds a fresh entity per name, and two names from one caller are
          ;; two sites while one name asked twice is one.
          (dolist (target (nreverse linked))
            (destructuring-bind (&key callee confidence derived-from call-site) target
              (when (and call-site (null (gethash (id call-site) asserted)))
                (setf (gethash (id call-site) asserted) t)
                (push (assert-entity call-site workspace-id) ops)
                (push (assert-edge :contains caller call-site
                                   :workspace-id workspace-id)
                      ops))
              (let ((source (or call-site caller)))
                (push (if confidence
                          (assert-edge :calls source callee
                                       :workspace-id workspace-id
                                       :source :inferred
                                       :confidence confidence
                                       :derived-from derived-from)
                          (assert-edge :calls source callee
                                       :workspace-id workspace-id))
                      ops))))
          ;; Unconditional where it used to be (WHEN LINKED ...): a caller
          ;; whose every name went external still has to have that written
          ;; down, and a caller whose callee has since been deleted has to
          ;; have :UNRESOLVED-CALLS grow back.
          (when names
            (push (update-properties (id caller)
                                     (list :unresolved-calls (nreverse left))
                                     workspace-id)
                  ops)))))
    ;; The sweep last, so it names only sites no assert above touched. An
    ;; :UPDATE-PROPERTIES for a site being retracted is emitted above and is
    ;; harmless: it lands on an entity that is still there when it is applied.
    (append (nreverse ops)
            (call-site-retractions view :ambiguous asserted workspace-id))))

(defparameter *tested-types* '(:function :method :interface)
  "What a :TESTS edge may be derived onto: exactly the things a :CALLS edge
can terminate at, since that is what this derivation reads.")

(defun resolve-tests (view &key workspace-id)
  "Operations linking each test to the units its body invokes.

DES-0002 R9: a :TESTS edge to every :FUNCTION, :METHOD or :INTERFACE the test
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

(defparameter *document-types* '(:decision :design :architecture :rule :concept :document)
  "Entity types the documentation analyzer produces.")

(defparameter *governing-document-types* '(:decision :design)
  "Document types whose affects: is a claim to *govern* rather than to bear on.

A decision's affects: says this decision governs that code, which is what
:DECIDES means and why `impact' gathers it into the decisions field. Nothing
else in the workflow makes that claim: a requirement asks for a change, a plan
sequences one, a bug report locates one. All three bear on the code they name
without governing it, so they earn :DOCUMENTS instead -- the type declared for
exactly this since SS11 and, until affects: was read for them, the type with no
producer at all (DES-0016 D7 recorded that gap and predicted this would close
it).")

(defparameter *declared-link-fields*
  '((:affects    . :decides)
    (:describes  . :documents)
    (:applies-to . :applies-to)
    (:supersedes . :supersedes)
    (:refines    . :refines))
  "Document property -> the relationship type it declares.

:AFFECTS is the entry DECLARED-EDGE-TYPE overrides: the value here is what a
governing document asserts, and every other kind of document asserts
:DOCUMENTS instead.

:REFINES is the one that points at another document rather than at code, which
LINKABLE-INDEX already supports: it keys on doc-id as well as on name, so
refines: [REQ-0002] finds the requirement. That is what makes the workflow a
graph rather than a filing convention -- the design that answers a requirement,
the plan that sequences the design, and the report of what went wrong are all
one walkable chain.")

(defun declared-edge-type (field document)
  "The relationship DOCUMENT's declared FIELD asserts.

Only :AFFECTS depends on the speaker; every other declared field means one
thing whoever writes it. A rule's applies-to: constrains, a supersedes:
replaces, a refines: answers -- none of those change meaning with the document
type, because only one type may write them."
  (let ((declared (cdr (assoc field *declared-link-fields*))))
    (if (and (eq field :affects)
             (not (member (entity-type document) *governing-document-types*)))
        :documents
        declared)))

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
declares -- DECLARED-EDGE-TYPE, because affects: means :DECIDES from a
decision and :DOCUMENTS from anything else; the rest are collected onto the
document's :UNRESOLVED-REFERENCES,
which is what SS10.3 asks be \"flagged ... counted in status, and exposed
through the API\" instead of quietly discarded. Prose mentions that resolve
become :inferred :MENTIONS edges -- the weaker type, which claims that the
document names the entity and nothing more (DES-0016 D7). It was :DOCUMENTS
until REQ-0014, and this loop was that type's only producer in the tree; a
markdown backtick and a YAML backtick are the same fact and now say so with
the same word.

Idempotent, like RESOLVE-CALLS: edges upsert by natural key, and a name that
resolved on a previous pass is still in the property, so nothing drifts."
  (let ((index (linkable-index view))
        (ops '()))
    (dolist (type *document-types*)
      (dolist (document (entities-of-type view type))
        (let ((unresolved '()))
          ;; --- declared links ------------------------------------------
          (dolist (field-and-type *declared-link-fields*)
            (let* ((field (car field-and-type))
                   (edge-type (declared-edge-type field document)))
              (dolist (name (getp document field))
                (let ((target (resolve-one index name)))
                  (if (and target (not (eq target document)))
                      (push (assert-edge edge-type document target
                                         :workspace-id workspace-id)
                            ops)
                      (pushnew name unresolved :test #'string=))))))
          ;; --- link targets (BUG-0027) ---------------------------------
          ;; The same weak edge a mention earns, and a different failure. A
          ;; link target is a path an author wrote; when it resolves to nothing
          ;; the file is not there, which is a fact rather than the ambiguity a
          ;; backticked word might be. So it is reported where `check' looks
          ;; instead of being dropped into REQ-0014's silence, which was written
          ;; for ordinary prose and inherited by links only because the two
          ;; populations were merged before anything could tell them apart.
          (dolist (name (getp document :link-targets))
            (let ((target (resolve-one index name)))
              (cond
                ;; Not in the index. That is NOT the same as not on disk, and
                ;; the difference is the whole of why this branch does not
                ;; report anything: game-server links to CLAUDE.md, which
                ;; REQ-0028 excludes by name, and to data-api/sql/test.sql,
                ;; which no analyzer claims. Both files are right there. Calling
                ;; them broken would be a fabricated fact with a plausible
                ;; shape, which is worse than the silence BUG-0027 set out to
                ;; end.
                ;;
                ;; Whether a path exists is a filesystem question and loom-graph
                ;; has no filesystem. CHECK-DOCUMENT-LINKS in loom-workspace
                ;; owns it, because that is the layer that knows a repository
                ;; has a root.
                ((null target) nil)
                ;; A link to another document. It resolved -- the file exists --
                ;; so it is emphatically not broken, and reporting it would be a
                ;; false positive of exactly the kind that teaches a reader to
                ;; stop reading the list. It earns no edge because :MENTIONS may
                ;; not terminate at a :DOCUMENT: the type is declared to reach
                ;; code, and a document-to-document link is a different claim
                ;; that CON-0004's refines: is for.
                ;;
                ;; The transaction validator caught this rather than the tests:
                ;; docs/README.md links to design-summary/api.md, and the first
                ;; version of this branch tried to assert an edge the ontology
                ;; refuses. It refused the whole transaction, which is why a
                ;; whole repository's document links vanished instead of one
                ;; edge being silently wrong.
                ((member (entity-type target) *document-types*) nil)
                ((eq target document) nil)
                (t (push (assert-edge :mentions document target
                                      :workspace-id workspace-id
                                      :source :inferred
                                      :confidence *mention-confidence*
                                      :derived-from (list (id target)))
                         ops)))))
          ;; --- mentioned links -----------------------------------------
          (dolist (name (getp document :mentions))
            (let ((target (resolve-one index name)))
              (when (and target
                         (not (eq target document))
                         (not (member (entity-type target) *document-types*)))
                (push (assert-edge :mentions document target
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

(defun unparsed-facts (view)
  "Every file and document the analyzer could not read, as plists carrying
:PATH, :TYPE and :ERROR.

The analyzer\'s half of this has always worked and is SS3.3\'s contract: a file
that will not parse is *marked, not omitted*, so a YAML document whose title
carries an unquoted colon lands in the index as a :DOCUMENT named by its path
and carrying :ANALYSIS-ERROR -- with the parser\'s own line and column in it.
Nothing read that property. BUG-0033 is the reporting half arriving twelve days
and two lost documents later.

Worth being exact about what the silence was, because the bug document offered
two hypotheses and the answer is the less obvious one. The document is not
dropped and the count does not fall: `documents\' counts the entity like any
other, so the number looks right while the document has no id, no fields, no
references and no title. That is the shape CON-0006 calls the expensive error --
a reader cannot tell it from a document that says nothing.

:FILE is here beside the document types because it carries the same property
for the same reason. A JavaScript file acorn could not parse, or one whose
toolchain is absent entirely, is the same fact about the same index."
  (loop for type in (cons :file *document-types*)
        append (loop for entity in (entities-of-type view type)
                     for problem = (getp entity :analysis-error)
                     when problem
                       collect (list :path (or (getp entity :path)
                                               (and (slot-boundp entity \'name)
                                                    (princ-to-string (name entity))))
                                     :type type
                                     :error problem))))

(defun unresolved-references (view)
  "Every document reference that named nothing, as (document-name . name).
What the status command reports, per SS3.2.

Two properties, one report. :UNRESOLVED-REFERENCES holds names the index could
not place -- a decision naming a function that no longer exists. :BROKEN-LINKS
holds paths the filesystem does not have, which loom-workspace establishes
because loom-graph cannot stat anything. They are separate where they are
written, because they are found by different means at different layers, and
together where they are read, because to somebody fixing a document they are one
question: what does this name that is not there."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type view type)
                     append (loop for name in (append (getp document :unresolved-references)
                                                      (getp document :broken-links))
                                  collect (cons (name document) name)))))
