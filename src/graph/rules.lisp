;;;; Rules as executable checks.
;;;; Implements Phase 1 Software Architecture (Revision 2) SS10.4.
;;;;
;;;; "A rule's check clause is compiled into the same query form as the
;;;; architectural invariants in the test suite. This closes a loop the
;;;; previous revision left open: the invariants of Section 14.3 need not be
;;;; hand-written tests that happen to agree with the architecture -- they can
;;;; be the rules themselves, read from docs/rules and executed against the
;;;; graph. The rule is written where a human reads it and enforced from the
;;;; same text."
;;;;
;;;; The check kinds are deliberately few. SS10.4 asks for enough to express
;;;; "the layering and single-writer rules Loom needs on itself", and a rule
;;;; that outgrows them stays valid as advisory prose rather than forcing a
;;;; general query language into Phase 1.

(in-package :loom-graph)

(defstruct (violation (:conc-name violation-))
  "One breach of one rule."
  (rule-id nil)
  (severity :error)
  (subject nil)       ; id of the offending entity or relationship
  (detail ""))

;;;; ==================================================================
;;;; The check kinds
;;;; ==================================================================

(defgeneric run-check (kind view rule check)
  (:documentation "Violations of CHECK for RULE against VIEW.
Dispatching on the kind keyword means adding a check kind is one method plus
one entry in LOOM-DOCS:*CHECK-KINDS*.")
  (:method (kind view rule check)
    (declare (ignore view check))
    ;; An unknown kind is not a violation and not an error: the document
    ;; indexed fine, Loom simply cannot enforce it. UNENFORCED-RULES counts it.
    (declare (ignore rule kind))
    '()))

(defmethod run-check ((kind (eql :no-edge)) view rule check)
  "No edge of these types may run from this system to that one.
The layering rules of SS14.3: \"Ontology depends on nothing\", \"Analyzers are
storage-agnostic\"."
  (let ((from (getf check :from-system))
        (to   (or (getf check :to-system) (getf check :to) :outside))
        (types (getf check :rel-types)))
    (when from
      (loop for edge in (edges-between-systems view from to :rel-types types)
            collect (make-violation
                     :rule-id (getp rule :doc-id)
                     :severity (getp rule :severity)
                     :subject (id edge)
                     :detail (format nil "~(~a~) edge from ~a to ~a"
                                     (rel-type edge)
                                     (entity-name-or-id view (from-id edge))
                                     (entity-name-or-id view (to-id edge))))))))

(defmethod run-check ((kind (eql :no-call-to)) view rule check)
  "No edge of these types may reach any of these named callees.

:NO-EDGE's narrower sibling, and the answer to BUG-0009's cause two. A
layering rule that names a whole system -- \"analyzers never reach the graph\"
-- is exactly what :NO-EDGE says, and RULE-0001 and RULE-0002 mean it. But
RULE-0003 does not: loom-knowledge depends on loom-graph *in order to read
it*, and its own statement forbids only \"apply-transaction or any other
function that submits a transaction\". Checked as :NO-EDGE, that rule reported
every legitimate NEIGHBORS and GET-ENTITY call as an error -- 63 of them on
this tree, and not one a breach.

TO-NAMES is the list of callee names, compared with STRING-EQUAL against the
entity's own name. FROM-SYSTEM and TO-SYSTEM keep :NO-EDGE's meaning, TO-SYSTEM
defaulting to :OUTSIDE, so the check still reads as a statement about a
boundary rather than a grep: a same-named function inside FROM-SYSTEM is not a
crossing and is not reported.

This is a deny list, and it is worth being plain about what that costs. A
writer added to the target system later is not covered until someone adds its
name here, so the rule is only as current as its TO-NAMES. The alternative --
listing the permitted readers instead -- fails closed but puts the upkeep on
every new query, and RULE-0003's prose names the writers, so this is the form
that keeps the check and the sentence above it saying the same thing."
  (let ((from (getf check :from-system))
        (to   (or (getf check :to-system) (getf check :to) :outside))
        (types (or (getf check :rel-types) '(:calls)))
        (names (getf check :to-names)))
    (when (and from names)
      (loop for edge in (edges-between-systems view from to :rel-types types)
            for target = (entity-name-or-id view (to-id edge))
            when (member target names :test #'string-equal)
              collect (make-violation
                       :rule-id (getp rule :doc-id)
                       :severity (getp rule :severity)
                       :subject (id edge)
                       :detail (format nil "~(~a~) edge from ~a to ~a"
                                       (rel-type edge)
                                       (entity-name-or-id view (from-id edge))
                                       target))))))

(defmethod run-check ((kind (eql :requires-edge)) view rule check)
  "Every entity of this type must have an edge of one of these types."
  (let ((entity-type (getf check :entity-type))
        (types (getf check :rel-types)))
    (when entity-type
      (loop for entity in (entities-of-type view entity-type)
            unless (or (neighbors view (id entity) :rel-types types :direction :out)
                       (neighbors view (id entity) :rel-types types :direction :in))
              collect (make-violation
                       :rule-id (getp rule :doc-id)
                       :severity (getp rule :severity)
                       :subject (id entity)
                       :detail (format nil "~a has no ~{~(~a~)~^/~} edge"
                                       (name entity) types))))))

(defmethod run-check ((kind (eql :property-constraint)) view rule check)
  "Every entity of this type must carry this property, optionally equal to
this value. The shape of SS14.3's \"Every fact has an origin file\"."
  (let ((entity-type (getf check :entity-type))
        (property (getf check :property))
        (expected (getf check :equals)))
    (when (and entity-type property)
      (loop for entity in (entities-of-type view entity-type)
            for value = (if (eq property :origin-file)
                            (origin-file entity)
                            (getp entity property))
            for bad = (cond ((null value) "is missing")
                            ((and expected (not (equal expected (princ-to-string value))))
                             (format nil "is ~s, expected ~s" value expected)))
            when bad
              collect (make-violation
                       :rule-id (getp rule :doc-id)
                       :severity (getp rule :severity)
                       :subject (id entity)
                       :detail (format nil "~a.~(~a~) ~a"
                                       (name entity) property bad))))))

(defmethod run-check ((kind (eql :property-absent)) view rule check)
  "No entity may carry this property. The mirror of :PROPERTY-CONSTRAINT, and
it reads the same way round -- as a constraint, not a query. A rule using it
says \"this property must be absent\"; every carrier is a violation, and the
report quotes the value so a reader does not have to go and find it.

:ENTITY-TYPE is optional here, unlike in the two kinds above. Given, only that
type is scanned; omitted, every entity is, which is what a property declared
on several types needs in order to be checked with one rule.

The location comes from the entity's own :FILE and :START-LINE rather than
from ORIGIN-FILE, matching what the console's unhandled-definer report already
prints: origin-file is the file a fact was read from, which for a derived fact
is not where a reader should go looking."
  (let ((entity-type (getf check :entity-type))
        (property (getf check :property)))
    (when property
      (loop for entity in (if entity-type
                              (entities-of-type view entity-type)
                              (all-entities view))
            for value = (getp entity property)
            when value
              collect (make-violation
                       :rule-id (getp rule :doc-id)
                       :severity (getp rule :severity)
                       :subject (id entity)
                       :detail (format nil "~a (~a:~a) carries ~(~a~) ~{~a~^, ~}"
                                       (entity-name-or-id view (id entity))
                                       (getp entity :file)
                                       (getp entity :start-line)
                                       property
                                       (if (listp value) value (list value))))))))

(defun entity-name-or-id (view id)
  (let ((entity (get-entity view id)))
    (if (and entity (slot-boundp entity 'name)) (name entity) id)))

;;;; ==================================================================
;;;; Running the rule set
;;;; ==================================================================

(defun active-rules (view)
  (remove-if-not (lambda (r) (eq :active (getp r :status)))
                 (entities-of-type view :rule)))

(defun enforceable-rule-p (rule)
  (and (getf (getp rule :check) :kind) t))

(defun unenforced-rules (view)
  "Active rules with no compiled check.
SS10.4: \"status reports the count of unenforced rules so that prose-only
drift stays visible rather than comfortable.\""
  (remove-if #'enforceable-rule-p (active-rules view)))

(defun check-rules (view)
  "Every current violation of every active, enforceable rule."
  (loop for rule in (active-rules view)
        for check = (getp rule :check)
        when (getf check :kind)
          append (run-check (getf check :kind) view rule check)))

(defun violation-ops (view &key workspace-id)
  "Operations recording the current violations as entities (SS10.4).

Every rule document's violations are retracted and re-asserted together, so a
rule that now passes stops having violations rather than keeping yesterday's.
Origin is the rule document, which makes reindexing that document clear its
findings -- the same files-as-truth accounting as everything else."
  (let ((by-rule (make-hash-table :test #'equal))
        (ops '()))
    (dolist (rule (active-rules view))
      (setf (gethash (getp rule :doc-id) by-rule) (cons rule '())))
    (dolist (violation (check-rules view))
      (let ((cell (gethash (violation-rule-id violation) by-rule)))
        (when cell (push violation (cdr cell)))))
    (maphash
     (lambda (rule-id cell)
       (declare (ignore rule-id))
       (destructuring-bind (rule . violations) cell
         (dolist (existing (violations-of view (getp rule :doc-id)))
           (push (retract (id existing) workspace-id) ops))
         (dolist (violation (reverse violations))
           (push (assert-entity
                  (make-instance 'rule-violation-entity
                                 :name (format nil "~a: ~a"
                                               (violation-rule-id violation)
                                               (violation-detail violation))
                                 :origin-file (origin-file rule)
                                 :properties (properties-table
                                              (list :rule-id (violation-rule-id violation)
                                                    :subject (violation-subject violation)
                                                    :severity (violation-severity violation)
                                                    :detail (violation-detail violation))))
                  workspace-id)
                 ops))))
     by-rule)
    (nreverse ops)))

(defun violations-of (view rule-id)
  (remove-if-not (lambda (v) (equal rule-id (getp v :rule-id)))
                 (entities-of-type view :rule-violation)))
