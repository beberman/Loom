;;;; Merging image-derived facts into a text-derived index.
;;;; Implements DES-0011's ENRICH-OPS, beside resolve.lisp because it is the
;;;; same kind of thing: a graph-aware derive pass that reads a view and
;;;; returns operations without applying any of them.
;;;;
;;;; What makes it a different kind of thing from every analyzer is the one
;;;; sentence the whole design is shaped around. An analyzer emits operations
;;;; blind and lets the upsert reconcile them, which is safe only because the
;;;; analyzer is the sole author of the properties it overwrites:
;;;; ABSORB-PROPERTIES (transaction.lisp) CLRHASHes a matched entity's table
;;;; before copying, and ABSORB-PROVENANCE replaces all five provenance slots.
;;;; A second pass emitting operations the same way would land on the text
;;;; pass's natural keys and erase :CALL-NAMES -- which is RESOLVE-CALLS' only
;;;; input, so the :CALLS edges would not be rebuilt on the next pass and the
;;;; ~50 :TESTS edges derived from them would be gone for good. That is
;;;; REQ-0018 R5 dying in one upsert, with the entity count unchanged and
;;;; nothing signalled.
;;;;
;;;; So this pass reads the graph before it derives anything, and never emits
;;;; an ASSERT-ENTITY for a natural key the graph already holds. Existing
;;;; entities contribute lookups only.
;;;;
;;;; The inspection arrives as plain data and leaves as ops. It is a plist --
;;;; DES-0011's CHILD PROTOCOL -- read with GETF, and this file names nothing
;;;; from SYNOPTIK-ANALYZER: synoptik-graph depends on synoptik-ontology and
;;;; bordeaux-threads, which is the same wall RESOLVE-GENERATED-DEFINITIONS hit
;;;; with *MACRO-GENERATORS*, and it takes the same answer. SYNOPTIK-WORKSPACE is
;;;; the first system that uses both packages, so it is what hands the data
;;;; across.

(in-package :synoptik-graph)

(defparameter *inspected-entity-types*
  '((:function         . :function)
    (:macro            . :function)
    (:generic-function . :interface)
    (:method           . :method)
    (:class            . :class)
    (:structure        . :class)
    (:condition        . :class)
    (:variable         . :variable))
  "Inspection :KIND -> the ontology entity type it maps onto.

The three class-like kinds collapse onto :CLASS because the text pass already
collapses them -- CLASS-DEFINITION-ENTITIES and STRUCT-DEFINITION-ENTITIES both
mint a :CLASS and record which defining form produced it -- and a kind with no
row here is dropped and counted rather than guessed at.")

(defun inspected-entity-type (kind)
  (cdr (assoc kind *inspected-entity-types*)))

(defun workspace-relative-p (file)
  "True when FILE is the workspace-relative, forward-slashed path every fact in
this index is keyed on.

Absolute is the failure worth catching rather than a shape worth supporting: a
fact carrying an absolute origin-file would never match RETRACT-FILE's
origin-index key, so it would never age out, and an image fact that cannot go
stale is the permanent lie CON-0001 forbids."
  (and (stringp file) (plusp (length file)) (char/= #\/ (char file 0))))

;;;; ==================================================================
;;;; Speaking the text pass's renderings (DES-0011 R5)
;;;; ==================================================================
;;;;
;;;; Every component of a natural key is a rendering, and a drifted one does
;;;; not fail -- it mints a duplicate entity beside the text pass's own, which
;;;; looks like success because the entity count went up. The fixture in
;;;; src/graph/test/enrich.lisp runs both passes over one definition set and is
;;;; what makes that visible.

(defun inspected-qualifier (qualifier)
  "QUALIFIER as the keyword METHOD-ENTITY-FROM-TAIL interns for it.

It crosses from the child as a string, because no symbol from target code is
ever interned into a Synoptik package, and it is part of :METHOD's natural key --
so the two spellings have to meet exactly here or every qualified method in the
tree doubles."
  (typecase qualifier
    (null    nil)
    (keyword qualifier)
    (t       (intern (string-upcase (string qualifier)) :keyword))))

(defun inspected-system (system)
  "SYSTEM as the keyword NORMALIZE-SYSTEM-NAME interns for it.

The same fold, and it has to be the same one: DES-0009 warns that a rule whose
two sides fold differently reports no violations rather than wrong ones, which
is silence that reads as success. A keyword is passed through, so a caller that
already has one -- a test, or a language whose inspector interns its own -- is
not required to render it back into a string first."
  (typecase system
    (null    nil)
    (keyword system)
    (t       (intern (string-upcase (string system)) :keyword))))

(defun inspected-properties (definition language &optional domain-of-path)
  "The properties the text pass would have written for DEFINITION.

DOMAIN-OF-PATH is a function from a workspace-relative path to a domain
keyword, handed in by the caller rather than called for. synoptik-graph reads no
configuration and this is why: DOMAIN-FOR-PATH lives in synoptik-analyzer, and
calling it here would make the production graph depend on the production
analyzer -- which neither does, which the layering table says, and which
`sbcl --script tools/test/load-test.lisp synoptik-graph' is the instrument for.
Measured: it failed to load with the direct call in place while the full suite
stayed green, because the test system pulls the analyzer in anyway.

NIL leaves :DOMAIN unset, which is what an enrich run that was given no
function should write rather than a guess."
  (let ((kind (getf definition :kind)))
    (append (list :file       (getf definition :file)
                  :start-line (getf definition :start-line)
                  :end-line   (getf definition :end-line)
                  :language   language
                  :system     (inspected-system (getf definition :system))
                  ;; PLAN-0050 S3, D-g. This is a fourth minting site outside
                  ;; ANALYZE-PATH's funnel, alongside resolve.lisp's three, so
                  ;; the stamp does not reach it and the property is computed
                  ;; here -- from a function the caller supplies, never from one
                  ;; this system reaches for.
                  :domain     (and domain-of-path
                                   (funcall domain-of-path (getf definition :file))))
            ;; A macro is a :FUNCTION carrying :MACRO-P in this ontology, and
            ;; the child knows which it saw. Dropping the distinction here
            ;; would cost a fact the image reported for nothing.
            (when (eq kind :macro) (list :macro-p t))
            (when (eq kind :method)
              (list :qualifier    (inspected-qualifier (getf definition :qualifier))
                    :specializers (getf definition :specializers))))))

(defun inspected-natural-key (type name properties)
  "The natural key an entity of TYPE named NAME with PROPERTIES will derive.

Read off the declared key rather than assumed to be (:FILE :NAME), exactly as
GENERATED-NATURAL-KEY does and for the same reason: :METHOD keys on four
components, and a lookup under a shorter key would match nothing -- silently,
and then assert a second method beside the one it failed to find."
  (let ((spec (find-entity-type type)))
    (when (and spec (entity-type-natural-key spec))
      (cons type (loop for key in (entity-type-natural-key spec)
                       collect (if (eq key :name) name (getf properties key)))))))

(defun enriched-entity (type name properties origin-file)
  "The entity a definition the graph does not hold becomes.

:SOURCE :INTROSPECTED and :CONFIDENCE 1.0 per DES-0011 R6 -- this is not a
reading of source that might be wrong, it is what the compiler said. ORIGIN-FILE
is the defining file's workspace-relative path, which is the whole of the
staleness design: RETRACT-FILE removes it when that file is edited, and the
next enrich puts it back."
  (make-instance (entity-type-class-name (find-entity-type type))
                 :name name
                 :origin-file origin-file
                 :source :introspected
                 :confidence 1.0
                 :properties (properties-table
                              (declared-properties-only type properties))))

;;;; ==================================================================
;;;; Matching a call fact's endpoints to definition facts
;;;; ==================================================================

(defun designator-kind-key (kind)
  "The bucket KIND keys under when a designator is matched against a definition.

Every callable kind collapses into one, because the two sides of a call fact
classify the same definition differently and neither is wrong: the child records
a definition it found as :GENERIC-FUNCTION or :MACRO, while CALLER-DESIGNATOR
reports every plain-symbol caller as :FUNCTION. Without the collapse those never
meet, and the symptom is a silently dropped edge.

Dropping the kind entirely -- which is what this used to do -- collapsed one
step too far. RECORD-SYMBOL emits a :FUNCTION, a :CLASS and a :VARIABLE for one
symbol when all three exist, in that order, so the variable overwrote the
function in the index; a call naming the function then resolved onto the
:VARIABLE entity, CALLABLE-ENDPOINTS-P refused the endpoint, and the edge became
a drop count nobody could attribute. Keying on the ontology type keeps those
three apart while leaving the callables together."
  (let ((type (inspected-entity-type kind)))
    (cond ((null type) kind)
          ((member type *callable-types*) :callable)
          (t type))))

(defun designator-key (designator)
  "A comparable key for one endpoint of a call fact, or for a definition.

Two shapes cross from the child. (:METHOD generic qualifiers specializers),
because SBCL reports a method caller under a compound key and the inspector
parses it there rather than here. (<kind> name package) for everything else."
  (destructuring-bind (kind first &optional second third) designator
    (if (eq kind :method)
        (list :method (string-downcase first)
              (mapcar #'string-downcase second)
              (mapcar #'string-downcase third))
        (list (designator-kind-key kind) (string-downcase first)
              (and second (string-downcase second))))))

(defun definition-designator (definition)
  "DEFINITION expressed as the designator a call fact would name it by."
  (let ((qualifier (getf definition :qualifier)))
    (if (eq (getf definition :kind) :method)
        (list :method (getf definition :name)
              (when qualifier (list qualifier))
              (getf definition :specializers))
        (list (getf definition :kind) (getf definition :name)
              (getf definition :package)))))

;;;; ==================================================================
;;;; Edges, and recording that two passes agree (DES-0011 R6)
;;;; ==================================================================

(defparameter *source-order* '(:structural :inferred :human-validated :introspected)
  "The order a :SOURCES union is written in.

Fixed, and that is the whole reason it exists. ABSORB-RELATIONSHIP replaces a
matched edge's properties wholesale, so the union is recomputed and rewritten
on every enrich -- and if the order depended on what the graph happened to hold
first, the second run against an unchanged tree would rewrite a value that
differed only in ordering. Idempotence is what makes re-running enrich cheap
enough to be worth doing.")

(defun union-sources (existing)
  "The :SOURCES value a confirmed or new edge carries.

EXISTING is the edge the graph already holds under this natural key, or NIL.
Its own recorded :SOURCES when it has one, else its SOURCE slot as a singleton
-- an edge asserted before this design existed has its provenance only in the
slot -- with :INTROSPECTED added. That is how agreement between the two passes
survives ABSORB-RELATIONSHIP overwriting the SOURCE slot with :INTROSPECTED:
the slot says who asserted last, the property says who has ever agreed."
  (let* ((recorded (and existing (getp existing :sources)))
         (base (or recorded (and existing (list (source existing))) '()))
         (union (remove-duplicates (cons :introspected base))))
    (sort (copy-list union) #'<
          :key (lambda (s) (or (position s *source-order*) (length *source-order*))))))

(defun enriched-edge (from to sources &key workspace-id via)
  "A :CALLS edge the image reported, as an operation.

ASSERT-EDGE was not usable when this was written: it took no properties, and
:SOURCES is a property (DES-0011 R6). It takes :PROPERTIES since PLAN-0060 step
2; this still builds the relationship itself, as it always has.

ORIGIN-FILE is (ORIGIN-FILE FROM), computed identically to ASSERT-EDGE and
deliberately not taken from the child's :CALLER-FILE string. An absorb
overwrites ORIGIN-FILE without touching the origin index -- INDEX-ORIGIN is
called from ADD-ENTITY and ADD-RELATIONSHIP and nowhere else -- so a confirmed
edge given a different origin file would say one thing while the index
RETRACT-FILE consults said another, and the edge would stop ageing out when its
caller was edited. Equal by construction is the only cheap defence.

VIA is the existing edge's :VIA, or NIL. The op is absorbed onto that edge, and
ABSORB-PROPERTIES clears the table before it copies, so an op carrying only
:SOURCES would erase the call keys RESOLVE-CALLS wrote on it (PLAN-0060
FINDINGS 1b). NIL writes no :VIA, which is right for an edge only the image saw:
no call form produced it."
  (assert-relationship
   (make-instance 'relationship
                  :rel-type :calls
                  :from-id (id from) :to-id (id to)
                  :origin-file (origin-file from)
                  :source :introspected
                  :confidence 1.0
                  :derived-from (list (id to))
                  :properties (properties-table
                               (list* :sources sources
                                      (and via (list :via via)))))
   workspace-id))

(defun implemented-interface-p (graph entity)
  "True when ENTITY is a generic function some method in the index implements.

A call fact landing there is refused, and the refusal is DES-0001's existing
decision applied to the second pass rather than a new one. CALL-TARGETS fans a
dispatched call out to the candidate methods and falls through to the
:INTERFACE only when there are none to fan out to -- a slot accessor, or a
generic implemented outside the tree -- which is what the :CALLS declaration
means by \"it does not make the generic a hub\". xref answers a different
question, who names this generic, so minting its answer as a :CALLS edge would
give every generic in the tree a direct caller set the text pass deliberately
never gives it, and double-count every dispatched call in `impact' beside the
per-method edges that already carry it.

An interface with no implementations here is the case the text pass does mint,
so it stays mintable: the test for it is the presence of :IMPLEMENTS edges, not
the entity type."
  (and (eq :interface (entity-type entity))
       (relationships-to graph (id entity) :rel-type :implements)
       t))

(defun callable-endpoints-p (from to)
  "True when a :CALLS edge may run from FROM to TO.

Read off the :CALLS declaration rather than restated, and checked here rather
than left to the Graph Manager, because SS5.2 rejects a transaction entire: one
illegal endpoint would cost the whole enrich pass where REQ-0018 R4 asks that a
gap cost only itself."
  (let ((spec (find-relationship-type :calls)))
    (and (member (entity-type from) (relationship-type-from spec))
         (member (entity-type to) (relationship-type-to spec))
         t)))

;;;; ==================================================================
;;;; The pass
;;;; ==================================================================

(defun enrich-ops (graph inspection &key workspace-id domain-of-path)
  "Two values: ops merging INSPECTION into GRAPH, and a report plist.

INSPECTION is DES-0011's facts document as plain data. Nothing here writes;
the caller submits the ops as a transaction like any other pass, so the Graph
Manager stays the only writer.

The report counts what happened and, as importantly, what did not: a pass whose
child died on its first unit produces no ops and no error, and is
indistinguishable from a tree the image agrees with completely unless the
refusals are counted (REQ-0018 R4)."
  (let ((language (getf inspection :language))
        (index (make-hash-table :test #'equal))
        (asserts '())
        (edges '())
        (report (list :confirmed 0 :added 0
                      :dropped-no-location 0 :dropped-not-under-root 0
                      :dropped-unknown-kind 0
                      :edges-confirmed 0 :edges-added 0 :edges-dropped 0)))
    (flet ((tally (key) (incf (getf report key))))
      (dolist (definition (getf inspection :definitions))
        (let ((type (inspected-entity-type (getf definition :kind)))
              (file (getf definition :file)))
          (cond
            ((null type) (tally :dropped-unknown-kind))
            ((not (workspace-relative-p file)) (tally :dropped-not-under-root))
            ;; Both ends of the range, not only the one PLAN-0010 names.
            ;; :END-LINE is :REQUIRED on every code type but :VARIABLE, so a
            ;; half-recovered range would not be dropped here and would instead
            ;; fail VALIDATE-ENTITY -- taking the whole enrich transaction with
            ;; it, since SS5.2 rejects a transaction entire. One definition's
            ;; missing location must cost that definition (CON-0001).
            ((or (null (getf definition :start-line))
                 (null (getf definition :end-line)))
             (tally :dropped-no-location))
            (t
             (let* ((name (getf definition :name))
                    (properties (inspected-properties definition language
                                                      domain-of-path))
                    (key (inspected-natural-key type name properties))
                    (existing (find-entity-by-key graph key)))
               (cond
                 ;; The R5 protection, and the load-bearing line of the design.
                 ;; An existing key contributes a lookup and nothing else.
                 (existing
                  (tally :confirmed)
                  (setf (gethash (designator-key (definition-designator definition))
                                 index)
                        existing))
                 (t
                  (let ((entity (enriched-entity type name properties file)))
                    (tally :added)
                    (push (assert-entity entity workspace-id) asserts)
                    (setf (gethash (designator-key (definition-designator definition))
                                   index)
                          entity)))))))))
      ;; Edges after the definitions, because an endpoint may be an entity this
      ;; same transaction asserts: the tx remap resolves an edge against the
      ;; asserts already planned, so the ordering is the whole of what makes
      ;; that sound.
      (dolist (call (getf inspection :calls))
        (let ((from (gethash (designator-key (getf call :caller)) index))
              (to   (gethash (designator-key (getf call :callee)) index)))
          (cond
            ;; An endpoint naming nothing under the root is a recorded gap, not
            ;; a dangling edge (CON-0001). It is also the common case: xref
            ;; reports every caller it knows, most of them in libraries.
            ((not (and from to (callable-endpoints-p from to)))
             (tally :edges-dropped))
            ;; Counted as a drop rather than as a confirmation, because it is
            ;; one: the image saw a call the text pass expresses as a fan-out
            ;; over the generic's methods, and those edges are already there.
            ((implemented-interface-p graph to)
             (tally :edges-dropped))
            (t
             (let ((existing (find-relationship-by-key
                              graph (list :calls (id from) (id to)))))
               (tally (if existing :edges-confirmed :edges-added))
               (push (enriched-edge from to (union-sources existing)
                                    :workspace-id workspace-id
                                    :via (and existing (getp existing :via)))
                     edges)))))))
    (values (append (nreverse asserts) (nreverse edges)) report)))
