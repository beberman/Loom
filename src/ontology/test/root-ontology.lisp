;;;
;;; Tests for src/ontology/root-ontology.lisp -- core classes, the type
;;; registry, the declaration macros, and validation.
;;; Copyright Brian Eberman, Ten Factor Growth 2022
;;;

(in-package :root-ontology-test)

(def-suite root-ontology
  :in all-tests
  :description "Core classes, type registry, DEFENTITY/DEFRELATIONSHIP, validation.")

(in-suite root-ontology)

;;; ------------------------------------------------------------------
;;; Fixtures.  Named test-* so they cannot collide with the real taxonomy
;;; in code-ontology.lisp, which shares this global registry.
;;; ------------------------------------------------------------------

(defvar *stamp-counter* 0
  "Bumped by :test-widget's :stamp default, to count evaluations.")

(defvar *test-modes* '(:fast :slow)
  "A vocabulary named once and referenced by :one-of, as *source-languages* is.")

(defentity :test-widget
  :documentation "Fixture entity type."
  :properties ((:file    string  :required t)
               (:count   integer :default 0)
               (:mode    keyword :one-of *test-modes* :default :fast)
               (:flag    boolean :default nil)
               (:tags    list    :default (:a :b))
               (:stamp   integer :default (incf *stamp-counter*))))

(defentity :test-bare
  :documentation "Fixture entity type declaring no properties.")

(defrelationship :test-links
  :from (:test-widget) :to (:test-bare)
  :transitive-impact t :impact-direction :reverse
  :documentation "Fixture relationship type.")

(defun tree-contains-function-p (x)
  "True if any node of the cons tree X is a function object."
  (cond ((functionp x) t)
        ((consp x) (or (tree-contains-function-p (car x))
                       (tree-contains-function-p (cdr x))))
        (t nil)))

;;; ------------------------------------------------------------------
;;; identified
;;; ------------------------------------------------------------------

(test id-can-be-supplied-so-operations-can-be-replayed
  ;; Without this, replaying the operation log or loading a snapshot would
  ;; mint fresh uuids and every from-id/to-id in the log would dangle.
  (let ((e (make-instance 'test-bare-entity :id "id-from-the-op-log")))
    (is (string= "id-from-the-op-log" (id e)))))

(test id-is-generated-when-not-supplied
  (let ((a (make-instance 'test-bare-entity))
        (b (make-instance 'test-bare-entity)))
    (is (random-uuid:valid-string-p (id a)))
    (is (string/= (id a) (id b)) "ids must never be reused between entities")))

(test name-round-trips
  (let ((e (make-instance 'test-bare-entity :name "widget")))
    (is (string= "widget" (name e)))
    (setf (name e) "gadget")
    (is (string= "gadget" (name e)))))

;;; ------------------------------------------------------------------
;;; provenanced
;;; ------------------------------------------------------------------

(test provenance-defaults
  (let ((e (make-instance 'test-bare-entity)))
    (is (eq :structural (source e))
        "structural facts are the common case and must not require an initarg")
    (is (= 1.0 (confidence e)))
    (is (null (derived-from e)))
    (is (null (last-verified e)))
    (is (null (stale-p e)))))

(test provenance-initargs
  (let ((e (make-instance 'test-bare-entity
                          :source :inferred :confidence 0.5
                          :derived-from '("a" "b") :last-verified "snap-3121")))
    (is (eq :inferred (source e)))
    (is (= 0.5 (confidence e)))
    (is (equal '("a" "b") (derived-from e)))
    (is (string= "snap-3121" (last-verified e)))))

;;; ------------------------------------------------------------------
;;; entity / relationship
;;; ------------------------------------------------------------------

(test entity-properties-is-an-equal-table
  (let ((tbl (properties (make-instance 'entity :entity-type :unregistered))))
    (is (hash-table-p tbl))
    (is (eq 'equal (hash-table-test tbl)))
    (setf (gethash "src/foo.lisp" tbl) 1)
    (is (eql 1 (gethash "src/foo.lisp" tbl))
        "string keys must match by content, not identity")))

(test relationship-slots
  (let ((r (make-instance 'relationship :rel-type :calls :from-id "a" :to-id "b")))
    (is (eq :calls (rel-type r)))
    (is (equal "a" (from-id r)))
    (is (equal "b" (to-id r)))
    (is (random-uuid:valid-string-p (id r)))
    (is (eq :structural (source r)))))

;;; ------------------------------------------------------------------
;;; defentity -- class generation and registration
;;; ------------------------------------------------------------------

(test defentity-generates-a-suffixed-class
  (is (not (null (find-class 'test-widget-entity nil)))
      ":test-widget must generate TEST-WIDGET-ENTITY")
  (is (eq 'test-widget-entity
          (entity-type-class-name (find-entity-type :test-widget)))))

(test entity-type-is-the-declared-keyword-not-the-class-name
  ;; this keyword is what appears on the wire as entityType
  (is (eq :test-widget (entity-type (make-instance 'test-widget-entity)))))

(test defentity-subclasses-entity
  (is (typep (make-instance 'test-widget-entity) 'entity)))

(test defentity-attaches-documentation
  (is (string= "Fixture entity type."
               (documentation (find-class 'test-widget-entity) t)))
  (is (string= "Fixture entity type."
               (entity-type-documentation (find-entity-type :test-widget)))))

(test defentity-registers-its-properties
  (let ((spec (find-entity-type :test-widget)))
    (is (not (null spec)))
    (is (equal '(:file :count :mode :flag :tags :stamp)
               (mapcar #'property-key (entity-type-properties spec)))
        "declaration order is preserved")))

(test defentity-with-no-properties-registers-an-empty-schema
  (is (null (entity-type-properties (find-entity-type :test-bare))))
  (is (zerop (hash-table-count (properties (make-instance 'test-bare-entity))))))

;;; ------------------------------------------------------------------
;;; defentity -- defaults
;;; ------------------------------------------------------------------

(test declared-properties-are-seeded-at-creation
  (let ((tbl (properties (make-instance 'test-widget-entity))))
    (is (eql 0 (gethash :count tbl)))
    (is (eq :fast (gethash :mode tbl)))
    (is (null (gethash :flag tbl)))
    (is (equal '(:a :b) (gethash :tags tbl))
        "a literal list default needs no quote")
    (is-true (nth-value 1 (gethash :file tbl))
             "a property with no default is still present, holding NIL")))

(test computed-defaults-are-evaluated-fresh-per-instance
  (let* ((*stamp-counter* 0)
         (a (make-instance 'test-widget-entity))
         (b (make-instance 'test-widget-entity)))
    (is (eql 1 (test-widget-entity-stamp a)))
    (is (eql 2 (test-widget-entity-stamp b))
        "each instance must re-evaluate the default, like a slot :initform")))

(test a-supplied-properties-table-wins-over-defaults
  (let* ((tbl (make-hash-table :test #'equal))
         (_ (setf (gethash :count tbl) 99))
         (e (make-instance 'test-widget-entity :properties tbl)))
    (declare (ignore _))
    (is (eql 99 (test-widget-entity-count e)) "loaded state must survive seeding")
    (is (eq :fast (test-widget-entity-mode e)) "unset properties still get defaults")))

;;; ------------------------------------------------------------------
;;; defentity -- typed accessors
;;; ------------------------------------------------------------------

(test typed-accessors-read-and-write
  (let ((e (make-instance 'test-widget-entity)))
    (setf (test-widget-entity-file e) "src/foo.lisp")
    (is (string= "src/foo.lisp" (test-widget-entity-file e)))
    (is (string= "src/foo.lisp" (gethash :file (properties e)))
        "the accessor is a view on the properties table, not a separate slot")))

(test typed-accessors-reject-a-wrong-type
  (let ((e (make-instance 'test-widget-entity)))
    (signals property-error (setf (test-widget-entity-count e) "not an integer"))))

(test typed-accessors-reject-a-value-outside-one-of
  (let ((e (make-instance 'test-widget-entity)))
    (signals property-error (setf (test-widget-entity-mode e) :sideways))
    (finishes (setf (test-widget-entity-mode e) :slow))))

(test one-of-can-name-a-shared-vocabulary
  (is (eq *test-modes* (property-one-of (find-property :test-widget :mode)))
      ":one-of *test-modes* must resolve to the variable's list, not the symbol"))

(test unknown-property-types-are-rejected-at-compile-time
  (signals error
    (macroexpand-1 '(defentity :test-bogus :properties ((:x no-such-type))))))

;;; ------------------------------------------------------------------
;;; Validation
;;; ------------------------------------------------------------------

(test validate-entity-passes-a-well-formed-entity
  (let ((e (make-instance 'test-widget-entity)))
    (setf (test-widget-entity-file e) "src/foo.lisp")
    (is (null (validate-entity e)))))

(test validate-entity-reports-a-missing-required-property
  (let* ((e (make-instance 'test-widget-entity))
         (problems (validate-entity e)))
    (is (= 1 (length problems)))
    (is (eq :file (getf (first problems) :key)))))

(test validate-entity-reports-a-type-mismatch
  (let ((e (make-instance 'test-widget-entity)))
    (setf (gethash :file (properties e)) "src/foo.lisp")
    (setf (gethash :count (properties e)) :not-an-integer) ; bypass the accessor
    (is (eq :count (getf (first (validate-entity e)) :key)))))

(test validate-entity-reports-a-one-of-violation
  (let ((e (make-instance 'test-widget-entity)))
    (setf (gethash :file (properties e)) "src/foo.lisp")
    (setf (gethash :mode (properties e)) :sideways)
    (is (eq :mode (getf (first (validate-entity e)) :key)))))

(test validate-entity-reports-an-unregistered-type
  (is (not (null (validate-entity (make-instance 'entity :entity-type :no-such-type))))))

(test nil-satisfies-any-declared-type
  ;; absence is REQUIRED's business, not the type checker's, so an optional
  ;; integer property left unset must not be reported as a type error
  (let ((e (make-instance 'test-widget-entity)))
    (setf (gethash :file (properties e)) "src/foo.lisp")
    (setf (gethash :count (properties e)) nil)
    (is (null (validate-entity e)))))

;;; ------------------------------------------------------------------
;;; defrelationship
;;; ------------------------------------------------------------------

(test defrelationship-registers-impact-metadata
  (let ((spec (find-relationship-type :test-links)))
    (is (not (null spec)))
    (is (equal '(:test-widget) (relationship-type-from spec)))
    (is (equal '(:test-bare) (relationship-type-to spec)))
    (is-true (relationship-type-transitive-impact spec))
    (is (eq :reverse (relationship-type-impact-direction spec)))
    (is (null (relationship-type-collect-as spec)))))

(test endpoint-validation-accepts-a-legal-edge
  (is (null (validate-relationship-endpoints :test-links :test-widget :test-bare))))

(test endpoint-validation-rejects-a-bad-origin
  (let ((problems (validate-relationship-endpoints :test-links :test-bare :test-bare)))
    (is (= 1 (length problems)))
    (is (eq :from (getf (first problems) :end)))))

(test endpoint-validation-rejects-a-bad-target
  (let ((problems (validate-relationship-endpoints :test-links :test-widget :test-widget)))
    (is (= 1 (length problems)))
    (is (eq :to (getf (first problems) :end)))))

(test endpoint-validation-rejects-an-unregistered-type
  (is (not (null (validate-relationship-endpoints :no-such-edge :test-widget :test-bare)))))

;;; ------------------------------------------------------------------
;;; Schema export -- what GET /ontology/schema serves
;;; ------------------------------------------------------------------

(test schema-is-plain-data-with-no-closures
  ;; the registry holds compiled default thunks; the schema must not, or the
  ;; REST layer and the MCP tool descriptions cannot serialize it
  (is-false (tree-contains-function-p (ontology-schema))))

(test schema-describes-a-declared-type
  (let* ((types (getf (ontology-schema) :entity-types))
         (widget (find :test-widget types :key (lambda (e) (getf e :key))))
         (props (getf widget :properties))
         (file (find :file props :key (lambda (p) (getf p :key))))
         (mode (find :mode props :key (lambda (p) (getf p :key)))))
    (is (not (null widget)))
    (is (eq 'string (getf file :type)))
    (is-true (getf file :required))
    (is (equal *test-modes* (getf mode :one-of)))))

(test schema-publishes-literal-defaults-and-omits-computed-ones
  (let* ((types (getf (ontology-schema) :entity-types))
         (widget (find :test-widget types :key (lambda (e) (getf e :key))))
         (props (getf widget :properties))
         (count (find :count props :key (lambda (p) (getf p :key))))
         (stamp (find :stamp props :key (lambda (p) (getf p :key)))))
    (is (eql 0 (getf count :default)))
    (is (eq :absent (getf stamp :default :absent))
        "a computed default has no single value to publish")))

(test schema-includes-relationship-impact-metadata
  (let* ((rels (getf (ontology-schema) :relationship-types))
         (links (find :test-links rels :key (lambda (r) (getf r :key)))))
    (is-true (getf links :transitive-impact))
    (is (eq :reverse (getf links :impact-direction)))))
