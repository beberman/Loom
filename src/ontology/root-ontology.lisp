;;;; Core ontology classes, the type registry, and the declaration macros.
;;;; Implements Phase 1 Software Architecture (Revision 2) SS5.1 - SS5.3.

(in-package :loom-ontology)

;;;; ==================================================================
;;;; Core classes (SS5.1)
;;;; ==================================================================

(defclass identified ()
  ((id   :initarg :id :reader id
         :documentation "Stable id, derived from the natural key, not random.

Deliberately not a uuid. SS5.1: ids are \"derived deterministically from the
natural key ... so that a full rebuild produces the same ids as an incremental
update\" -- the property SS14.4 tests by asserting that an incrementally
updated index and an independently rebuilt one are identical, not merely
equivalent. A random id could only ever satisfy the weaker claim.

Unbound until INITIALIZE-INSTANCE derives one, or until a caller supplies one
explicitly when replaying the operation log.")
   (name :initarg :name :accessor name)
   (id-derived-p :initform nil :accessor id-derived-p
                 :documentation "True while this id is still a function of the
natural key rather than a value in its own right.

The hazard it guards against: a derived id is computed from properties, and a
caller who constructs an entity and then fills its properties in with SETP has
already had the id computed from the values it did not yet have -- silently,
and producing something that looks like a real id. While this flag is set,
writing a natural-key property re-derives the id. LOOM-GRAPH:ADD-ENTITY clears
it on the way into the index, after which the id is fixed and moving it is the
Graph Manager's business, not a property write's."))
  )

(defclass provenanced ()
  ((source        :initarg :source :accessor source
                  :initform :structural
                  :type (member :structural :inferred :human-validated :introspected)
                  :documentation "Which pass produced this fact.

:STRUCTURAL   read from the text of a file -- what an analyzer saw written.
:INFERRED     derived by a resolution pass that had to choose, and so carries
              a fractional CONFIDENCE saying how much of a choice it was.
:HUMAN-VALIDATED  asserted by a person, and not re-derivable from anything.
:INTROSPECTED the language's own toolchain reported it, from an image in which
              the target was loaded (DES-0011). Confidence 1.0: it is not a
              reading of source but an answer from the compiler.

The fourth member is the whole ontology cost of REQ-0018. Read it as the
vocabulary rather than as an enforced constraint: SBCL does not check a
standard-class slot :TYPE at the safety this tree compiles at, measured
2026-08-07, so this declaration is what a reader and a higher-safety build
see and not something MAKE-INSTANCE will refuse.")
   (confidence    :initarg :confidence :accessor confidence
                  :initform 1.0 :type (real 0 1))
   (derived-from  :initarg :derived-from :accessor derived-from
                  :initform '()
                  :documentation "Entity ids whose modification invalidates this fact.")
   (origin-file   :initarg :origin-file :accessor origin-file
                  :initform nil
                  :documentation "The file this fact was read from. Every fact has one.

SS5.1 makes this mandatory, and SS14.3 asserts its presence as an
architectural invariant. It is what files-as-truth rests on: reanalyzing a
file is only a well-defined operation if the index can name the facts that
came from it, and a fact with no origin is by definition not derivable from
the repository -- which under SS2.1 means it is not knowledge, it is cache.")
   (stale-p       :initarg :stale-p :initform nil :accessor stale-p)))

(defclass entity (identified provenanced)
  ((entity-type :initarg :entity-type :reader entity-type)   ; keyword, e.g. :function
   (properties  :initarg :properties
                :initform (make-hash-table :test #'equal)
                :reader properties)))

(defclass relationship (identified provenanced)
  ((rel-type :initarg :rel-type :reader rel-type)            ; keyword, e.g. :calls
   (from-id  :initarg :from-id :reader from-id)
   (to-id    :initarg :to-id  :reader to-id)
   (properties :initarg :properties
               :initform (make-hash-table :test #'equal)
               :reader properties)))

;;; Everything concrete -- workspace, snapshot, file, function, and the rest of
;;; the taxonomy -- is declared with DEFENTITY in code-ontology.lisp.  This
;;; file defines only the machinery those declarations run on.

;;;; ==================================================================
;;;; Property types and specs (SS4.2)
;;;; ==================================================================

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *property-types*
    '((string  . string)
      (integer . integer)
      (real    . real)
      (boolean . (member t nil))
      (keyword . keyword)
      (list    . list)
      (any     . t))
    "Declared property type name -> Common Lisp type specifier.")

  (defun property-type-specifier (name)
    "The CL type specifier for a declared property type NAME."
    (let ((entry (assoc name *property-types*)))
      (unless entry
        (error "Unknown property type ~s; expected one of ~{~s~^, ~}."
               name (mapcar #'car *property-types*)))
      (cdr entry)))

  (defun code-form-p (form)
    "True when FORM is a call to be evaluated rather than literal data.
A cons whose car names a function, macro, or special operator is code --
(get-universal-time), #'foo, '(:a :b) all qualify.  Everything else,
including a bare list of data like (:a :b), is a literal."
    (and (consp form)
         (symbolp (car form))
         (fboundp (car form))))

  (defun property-thunk (value-form)
    "Build the thunk that produces one property's default."
    (if (code-form-p value-form)
        `(lambda () ,value-form)
        `(lambda () ',value-form)))

  (defun one-of-form (spec)
    "Expand a :ONE-OF declaration to a form yielding the allowed values.
A literal list is taken as data; a symbol is read as a variable, so a shared
vocabulary can be named once and referenced -- :one-of *source-languages*."
    (cond ((null spec) nil)
          ((symbolp spec) spec)
          ((code-form-p spec) spec)
          (t `',spec))))

(defstruct (property-spec (:conc-name property-))
  "One declared property of an entity type.  This is plain data so the
registry can be served as a schema; DEFAULT-THUNK is the compiled artifact."
  (key nil :type keyword)
  (type 'any)
  (required nil)
  (one-of nil :type list)
  (documentation nil)
  (default-form nil)
  (default-thunk (lambda () nil) :type function))

(defstruct (entity-type-spec (:conc-name entity-type-))
  (key nil :type keyword)
  (class-name nil :type symbol)
  (documentation nil)
  (properties '() :type list)
  ;; SS4.4: "Assert operations are upserts keyed by a natural key (for a
  ;; function: file plus qualified name), so re-analyzing an unchanged file is
  ;; idempotent."  A list of property keys, plus the pseudo-key :NAME for the
  ;; entity's name slot.  NIL means the type has no identity beyond its id.
  (natural-key '() :type list)
  ;; DES-0054 D7: a closed type rejects any property it does not declare.
  ;; Open is the default, so every type declared before this is unchanged.
  (closed nil))

(defstruct (relationship-type-spec (:conc-name relationship-type-))
  "Relationship metadata, including the two fields the impact engine needs
(SS4.3, SS9): whether impact traverses this type transitively, and which way
impact flows across it."
  (key nil :type keyword)
  (from '() :type list)
  (to '() :type list)
  (transitive-impact nil)
  (impact-direction :reverse :type keyword)
  (collect-as nil)
  (documentation nil))

;;;; ==================================================================
;;;; Registries -- the single source of the schema (SS4.2)
;;;; ==================================================================

(defvar *entity-type-registry* (make-hash-table :test #'eq)
  "Keyword -> ENTITY-TYPE-SPEC.")

(defvar *relationship-type-registry* (make-hash-table :test #'eq)
  "Keyword -> RELATIONSHIP-TYPE-SPEC.")

(defun find-entity-type (key)
  "The ENTITY-TYPE-SPEC registered for KEY, or NIL."
  (gethash key *entity-type-registry*))

(defun find-relationship-type (key)
  "The RELATIONSHIP-TYPE-SPEC registered for KEY, or NIL."
  (gethash key *relationship-type-registry*))

(defun register-entity-type (spec)
  (setf (gethash (entity-type-key spec) *entity-type-registry*) spec))

(defun register-relationship-type (spec)
  (setf (gethash (relationship-type-key spec) *relationship-type-registry*) spec))

(defun all-entity-types ()
  "All registered entity type keywords, sorted for stable output."
  (sort (loop for k being the hash-keys of *entity-type-registry* collect k)
        #'string< :key #'symbol-name))

(defun all-relationship-types ()
  (sort (loop for k being the hash-keys of *relationship-type-registry* collect k)
        #'string< :key #'symbol-name))

(defun find-property (type-key property-key)
  "The PROPERTY-SPEC for PROPERTY-KEY on entity type TYPE-KEY, or NIL."
  (let ((spec (find-entity-type type-key)))
    (when spec
      (find property-key (entity-type-properties spec) :key #'property-key))))

(defun clear-entity-registry ()
  "Empty the entity type registry. For test isolation and reload scenarios;
DEFENTITY forms must be re-run afterward to repopulate it."
  (clrhash *entity-type-registry*)
  (values))

(defun clear-relationship-registry ()
  "Empty the relationship type registry. For test isolation and reload
scenarios; DEFRELATIONSHIP forms must be re-run afterward to repopulate it."
  (clrhash *relationship-type-registry*)
  (values))

;;;; ==================================================================
;;;; Validation (SS5.2)
;;;; ==================================================================

(define-condition ontology-error (error) ()
  (:documentation "Base for every ontology-level failure."))

(define-condition property-error (ontology-error)
  ((entity-type :initarg :entity-type :reader property-error-entity-type)
   (key         :initarg :key         :reader property-error-key)
   (value       :initarg :value       :reader property-error-value)
   (problem     :initarg :problem     :reader property-error-problem))
  (:report (lambda (c s)
             (format s "~a.~a: ~a (got ~s)"
                     (property-error-entity-type c)
                     (property-error-key c)
                     (property-error-problem c)
                     (property-error-value c)))))

;;; TODO: NIL is overloaded as both "no value stored" and, for BOOLEAN
;;; properties, the legitimate value false -- GETP and the generated
;;; per-type accessors return a bare value with no presence flag, so
;;; VALIDATE-ENTITY below cannot tell a false boolean from an absent one. A
;;; :REQUIRED BOOLEAN property set to NIL is therefore misreported as
;;; missing. Latent only: no property in code-ontology.lisp currently marks
;;; a boolean :REQUIRED. Fixing it means GETP returning (VALUES value
;;; present-p) and threading presence through PROPERTY-VALUE-PROBLEM and
;;; VALIDATE-ENTITY's required check, not just a GETP change.

(defun property-value-problem (spec value)
  "A human-readable problem string if VALUE is invalid for SPEC, else NIL.
NIL passes regardless of declared type: absence is REQUIRED's business."
  (cond ((null value) nil)
        ((not (typep value (property-type-specifier (property-type spec))))
         (format nil "expected ~a" (property-type spec)))
        ((and (property-one-of spec)
              (not (member value (property-one-of spec) :test #'equal)))
         (format nil "expected one of ~{~s~^, ~}" (property-one-of spec)))))

(defun check-property-value (type-key property-key value)
  "Signal PROPERTY-ERROR unless VALUE is valid for TYPE-KEY's PROPERTY-KEY.
Used by the generated typed accessors."
  (let ((spec (find-property type-key property-key)))
    (when spec
      (let ((problem (property-value-problem spec value)))
        (when problem
          (error 'property-error :entity-type type-key :key property-key
                                 :value value :problem problem)))))
  value)

(defun getp (entity key)
  "Generic property reader: the value of property KEY on ENTITY.
Complement to the per-type accessors DEFENTITY generates -- for code that
builds or walks entities by key rather than by a known accessor name, such as
an analyzer populating a freshly parsed entity from extracted properties."
  (gethash key (properties entity)))

(defun (setf getp) (value entity key)
  "SETF-able counterpart to GETP. Validates VALUE the same way the
type-specific accessors do, via CHECK-PROPERTY-VALUE.

Writing a natural-key property on an entity whose id is still derived moves
the id with it -- see ID-DERIVED-P. That keeps construct-then-populate honest
instead of silently wrong, and stops once the entity is in the index."
  (check-property-value (entity-type entity) key value)
  (setf (gethash key (properties entity)) value)
  (when (and (id-derived-p entity) (natural-key-property-p entity key))
    (rederive-id entity))
  value)

(defun setp (entity key value)
  "Function-call form of (SETF (GETP ENTITY KEY) VALUE), for callers that
prefer not to write a SETF form -- e.g. looping SETP over an alist of
parsed properties."
  (setf (getp entity key) value))

(defun validate-entity (e)
  "Return a list of problem plists for E; NIL means valid.
Non-signaling so the Graph Manager can reject a whole transaction with a
structured error naming every failing operation."
  (let ((spec (find-entity-type (entity-type e))))
    (if (null spec)
        (list (list :key nil :problem
                    (format nil "unregistered entity type ~s" (entity-type e))))
        (append
         (loop with table = (properties e)
               for p in (entity-type-properties spec)
               for key = (property-key p)
               for value = (gethash key table)
               for problem = (cond ((and (property-required p) (null value))
                                    "required property is missing")
                                   (t (property-value-problem p value)))
               when problem
                 collect (list :key key :value value :problem problem))
         (when (entity-type-closed spec)
           (undeclared-property-problems spec (properties e)))))))

(defun undeclared-property-problems (spec table)
  "Problem plists for every key in TABLE that SPEC does not declare.
Only a type declared :CLOSED T is asked. VALIDATE-ENTITY otherwise ignores an
extra key on an assert and only UPDATE-PROPERTIES refuses one, which is why a
value stored on a node that must never hold one would pass (DES-0054 D7)."
  (loop for key being the hash-keys of table using (hash-value value)
        unless (find key (entity-type-properties spec) :key #'property-key)
          collect (list :key key :value value
                        :problem "undeclared property on a closed type")))

(defun validate-relationship-endpoints (rel-type from-type to-type)
  "Return a list of problem plists for an edge of REL-TYPE between entities of
FROM-TYPE and TO-TYPE.  The Graph Manager resolves the endpoint types; this
only judges them, so the ontology stays free of storage concerns."
  (let ((spec (find-relationship-type rel-type)))
    (cond ((null spec)
           (list (list :problem (format nil "unregistered relationship type ~s" rel-type))))
          (t (append
              (when (and (relationship-type-from spec)
                         (not (member from-type (relationship-type-from spec))))
                (list (list :end :from :value from-type :problem
                            (format nil "~s cannot originate at ~s" rel-type from-type))))
              (when (and (relationship-type-to spec)
                         (not (member to-type (relationship-type-to spec))))
                (list (list :end :to :value to-type :problem
                            (format nil "~s cannot terminate at ~s" rel-type to-type)))))))))

;;;; ==================================================================
;;;; Natural keys and derived ids (SS4.4, SS5.1)
;;;; ==================================================================
;;;;
;;;; An analyzer is stateless and builds fresh objects on every pass. The
;;;; natural key is the content-derived identity that lets the Graph Manager
;;;; recognise one of those objects as something it already holds -- and,
;;;; since SS5.1, it is also where the id itself comes from, so a rebuilt
;;;; index and an incrementally updated one agree down to the ids.

(defun entity-natural-key (e)
  "The upsert identity of entity E, or NIL if its type declares none.
Compare with EQUAL. A type without a natural key is identified only by its
id, so every assert of one inserts -- right for knowledge minted once by a
human or an agent, wrong for anything an analyzer re-derives from source."
  (let ((spec (find-entity-type (entity-type e))))
    (when (and spec (entity-type-natural-key spec))
      (cons (entity-type e)
            (loop for key in (entity-type-natural-key spec)
                  collect (if (eq key :name)
                              (and (slot-boundp e 'name) (name e))
                              (gethash key (properties e))))))))

(defun relationship-natural-key (r)
  "The upsert identity of relationship R: its type and its two endpoints.
Universal rather than declared -- an edge is fully described by what it
connects, so there is nothing per-type to say."
  (list (rel-type r) (from-id r) (to-id r)))

(defun render-key-part (value)
  "One natural-key component as a string, for embedding in an id."
  (typecase value
    (null      "")
    (string    value)
    (keyword   (string-downcase (symbol-name value)))
    (cons      (format nil "~{~a~^,~}" (mapcar #'render-key-part value)))
    (t         (princ-to-string value))))

(defun derive-id (natural-key)
  "An id string for NATURAL-KEY, or NIL when there is no key to derive from.

Readable by design -- \"function:src/graph/query.lisp:impact-set\" rather than
a uuid -- because these ids appear in API responses, in impact paths, and in
whatever an agent quotes back at a human. The type leads: SS12's wire example
omits it, but :FILE and :DOCUMENT both key on a path, and :MODULE and :PACKAGE
both on a qualified name, so without the type those pairs would collide."
  (when natural-key
    (format nil "~(~a~)~{:~a~}"
            (first natural-key) (mapcar #'render-key-part (rest natural-key)))))

(defvar *fresh-id-lock* (bt:make-lock "loom-fresh-id")
  "Serializes FRESH-ID's callers against one another.

What it guards is not Loom's: RANDOM-UUID:MAKE-UUID, called with no generator,
evaluates (RANDOM (EXPT 2 64)) twice against CL:*RANDOM-STATE* -- one global
object per image that SBCL threads inherit by value and whose MT19937 state
vector it mutates without atomicity. Two threads inside it interleave and mint
the same id, which BUG-0005 measured at 26,039 distinct strings out of 40,000.

Global rather than hung off a graph or a repository as DES-0003's and
DES-0004's locks are, because the resource is: one random state per image, so
a per-object lock would not help two graphs' threads. Plain and not recursive
because FRESH-ID's body calls two library functions and can never re-enter
itself, so there is nothing to compose. It is a leaf in the acquisition order
repository > graph > fresh-id -- neither library function acquires a lock or
calls back into Loom -- which is what makes it safe to take while the graph
lock is held, as MAKE-INSTANCE of a key-less entity inside WITH-GRAPH-LOCK
does.

Not exported, and not wrapped in a WITH- macro: it has one user six lines
below, and a caller outside loom-ontology holding it across work of its own
would be a deadlock no rule check could catch.")

(defun fresh-id ()
  "A random id, for facts that have no natural key to derive one from."
  (bt:with-lock-held (*fresh-id-lock*)
    (random-uuid:to-string (random-uuid:make-uuid))))

(defun properties-table (plist)
  "A property table built from PLIST.

The way to give an entity its natural-key properties: they have to be present
before INITIALIZE-INSTANCE derives the id, so passing them as :PROPERTIES is
not a convenience but a requirement. Properties set with SETP afterwards do
not affect the id, which is correct for anything outside the natural key and
a bug waiting to happen for anything inside it."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash key table) value))
    table))

;;;; ==================================================================
;;;; Instantiation -- defaults and ids come from the registry
;;;; ==================================================================

(defmethod initialize-instance :after ((e entity) &key)
  (let ((spec (and (slot-boundp e 'entity-type) (find-entity-type (entity-type e)))))
    (when spec
      (let ((table (properties e)))
        (dolist (p (entity-type-properties spec))
          ;; an explicitly supplied properties table wins over the default
          (multiple-value-bind (value presentp) (gethash (property-key p) table)
            (declare (ignore value))
            (unless presentp
              (setf (gethash (property-key p) table)
                    (funcall (property-default-thunk p)))))))))
  ;; Defaults first, then the id: a natural key may name a property that only
  ;; the registry supplies.
  (unless (slot-boundp e 'id)
    (let ((derived (derive-id (entity-natural-key e))))
      (setf (slot-value e 'id) (or derived (fresh-id))
            (id-derived-p e)   (and derived t)))))

(defmethod initialize-instance :after ((r relationship) &key)
  (unless (slot-boundp r 'id)
    ;; An edge's key is its endpoints, which are readers -- there is no
    ;; property write that could move it, so nothing to guard.
    (setf (slot-value r 'id) (derive-id (relationship-natural-key r)))))

(defmethod (setf name) :after (value (e entity))
  "A rename moves a derived id too, for types keyed on :NAME."
  (declare (ignore value))
  (when (and (id-derived-p e) (natural-key-property-p e :name))
    (rederive-id e)))

(defun natural-key-property-p (e key)
  "True when KEY is one of the properties E's type derives its identity from."
  (let ((spec (find-entity-type (entity-type e))))
    (and spec (member key (entity-type-natural-key spec)) t)))

(defun rederive-id (e)
  "Recompute E's id from its natural key. Only meaningful while ID-DERIVED-P."
  (let ((derived (derive-id (entity-natural-key e))))
    (when derived (setf (slot-value e 'id) derived))
    e))

;;;; ==================================================================
;;;; Declaration macros (SS4.2, SS4.3)
;;;; ==================================================================

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun entity-class-name (type-key)
    "The class DEFENTITY generates for TYPE-KEY: :function -> FUNCTION-ENTITY."
    (intern (concatenate 'string (symbol-name type-key) "-ENTITY") *package*))

  (defun property-accessor-name (class-name property-key)
    "FUNCTION-ENTITY + :start-line -> FUNCTION-ENTITY-START-LINE."
    (intern (concatenate 'string (symbol-name class-name) "-" (symbol-name property-key))
            *package*))

  (defun parse-property-spec (spec)
    "Expand one DEFENTITY property SPEC into a form building a PROPERTY-SPEC.
SPEC is (key &optional type &key required default one-of documentation); a
bare keyword is shorthand for an untyped property."
    (destructuring-bind (key &optional (type 'any)
                         &key required default one-of documentation)
        (if (consp spec) spec (list spec))
      (property-type-specifier type)      ; reject unknown types at compile time
      `(make-property-spec
        :key ,key
        :type ',type
        :required ,required
        :one-of ,(one-of-form one-of)
        :documentation ,documentation
        :default-form ',default
        :default-thunk ,(property-thunk default))))

  (defun check-natural-key (type-key natural-key properties)
    "Reject a :NATURAL-KEY naming something the type does not have.
Caught at compile time, because a key referring to an absent property yields
NIL for every instance -- silently collapsing every entity of the type onto
one another at upsert, which is the worst way to find this out."
    (let ((known (cons :name (mapcar (lambda (spec) (if (consp spec) (car spec) spec))
                                     properties))))
      (dolist (key natural-key)
        (unless (member key known)
          (error "~s natural key names ~s, which is neither :name nor one of ~
its declared properties ~{~s~^, ~}."
                 type-key key (rest known)))))))

(defmacro defentity (type-key &key documentation properties natural-key closed)
  "Declare entity type TYPE-KEY, generating its class, typed accessors, and
its registry entry.  TYPE-KEY is the keyword that appears on the wire as
entityType; the class it generates is <TYPE-KEY>-ENTITY.

PROPERTIES is a list of (key &optional type &key required default one-of
documentation).  TYPE is one of string, integer, real, boolean, keyword,
list, any -- and is checked at compile time.  Each property is seeded into
the entity's PROPERTIES table at creation and validated by VALIDATE-ENTITY.

ONE-OF constrains the value to a fixed vocabulary.  Write it as a literal
list, or name a variable holding one so a vocabulary shared across types is
defined once: :one-of *source-languages*.

DEFAULT is a form: one that reads as a call is evaluated fresh per instance,
like a slot :initform, and anything else is stored as data -- so
:default (get-universal-time) stamps each entity, while :default (:a :b)
stores that list without needing a quote.

NATURAL-KEY is the type's content-derived identity, used to upsert (SS4.4):
a list of property keys, plus :name for the name slot.  Declare one for any
type an analyzer re-derives from source, or every analysis pass will insert
duplicates instead of updating what is already there.  Omit it for knowledge
that is minted once rather than rediscovered -- a decision, a concept.

  (defentity :function
    :documentation \"A named callable unit in source code.\"
    :natural-key (:file :name)
    :properties ((:file       string  :required t)
                 (:start-line integer :required t)
                 (:exported-p boolean :default nil)
                 (:language   keyword :one-of (:lisp :typescript :python))))

generates FUNCTION-ENTITY, the accessor FUNCTION-ENTITY-FILE and its SETF
expander (which validates on write), and registers the type so the Graph
Manager, GET /ontology/schema, and the MCP tool descriptions all read one
schema.  The class and its accessors are exported: they are the public API of
the type, and listing them by hand in a package definition would be a second
place to keep the taxonomy in sync.

CLOSED true makes VALIDATE-ENTITY report every property the type does not
declare.  Omit it and extra keys pass, as they always have."
  (check-natural-key type-key natural-key properties)
  (let* ((class-name (entity-class-name type-key))
         (accessors (loop for spec in properties
                          collect (property-accessor-name
                                   class-name (if (consp spec) (car spec) spec)))))
    `(progn
       (defclass ,class-name (entity) ()
         (:default-initargs :entity-type ,type-key)
         ,@(when documentation `((:documentation ,documentation))))
       ,@(loop for spec in properties
               for key = (if (consp spec) (car spec) spec)
               for accessor in accessors
               append `((defun ,accessor (e)
                          (gethash ,key (properties e)))
                        (defun (setf ,accessor) (value e)
                          ;; via (SETF GETP) rather than the table directly, so
                          ;; a natural-key write re-derives the id here too
                          (setf (getp e ,key) value))))
       (export '(,class-name ,@accessors))
       (register-entity-type
        (make-entity-type-spec
         :key ,type-key
         :class-name ',class-name
         :documentation ,documentation
         :natural-key ',natural-key
         :closed ,closed
         :properties (list ,@(mapcar #'parse-property-spec properties))))
       ,type-key)))

(defmacro defrelationship (type-key &key from to transitive-impact
                                      (impact-direction :reverse)
                                      collect-as documentation)
  "Declare relationship type TYPE-KEY.

FROM and TO are lists of entity-type keywords the edge may connect; NIL means
unconstrained.  TRANSITIVE-IMPACT and IMPACT-DIRECTION are what the impact
engine reads (SS9): whether traversal follows this type transitively or one
step, and whether impact flows against the edge (:reverse) or along it
(:forward).  COLLECT-AS names a distinct result field -- :tests and
:documents are gathered separately rather than mixed into the impact set.

  (defrelationship :calls
    :from (:function :method) :to (:function :method)
    :transitive-impact t :impact-direction :reverse)"
  `(progn
     (register-relationship-type
      (make-relationship-type-spec
       :key ,type-key
       :from ',from
       :to ',to
       :transitive-impact ,transitive-impact
       :impact-direction ,impact-direction
       :collect-as ,collect-as
       :documentation ,documentation))
     ,type-key))

;;;; ==================================================================
;;;; Schema export -- what GET /ontology/schema serves
;;;; ==================================================================

(defun property-schema (p)
  "One property as plain data.  DEFAULT is reported only when it is a literal;
a computed default has no single value to publish."
  (append (list :key (property-key p)
                :type (property-type p)
                :required (and (property-required p) t))
          (when (property-one-of p) (list :one-of (property-one-of p)))
          (when (property-documentation p)
            (list :documentation (property-documentation p)))
          (unless (code-form-p (property-default-form p))
            (list :default (property-default-form p)))))

(defun ontology-schema ()
  "The whole registry as plain data, ready for JSON encoding by loom-rest.
Contains no closures, so it round-trips."
  (list :entity-types
        (loop for key in (all-entity-types)
              for spec = (find-entity-type key)
              collect (list :key key
                            :documentation (entity-type-documentation spec)
                            :natural-key (entity-type-natural-key spec)
                            :properties (mapcar #'property-schema
                                                (entity-type-properties spec))))
        :relationship-types
        (loop for key in (all-relationship-types)
              for spec = (find-relationship-type key)
              collect (list :key key
                            :from (relationship-type-from spec)
                            :to (relationship-type-to spec)
                            :transitive-impact (and (relationship-type-transitive-impact spec) t)
                            :impact-direction (relationship-type-impact-direction spec)
                            :collect-as (relationship-type-collect-as spec)
                            :documentation (relationship-type-documentation spec)))))
