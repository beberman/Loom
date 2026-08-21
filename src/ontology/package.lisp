;;;; Package definition for the Loom ontology.
;;;;
;;;; RANDOM-UUID is deliberately not :USEd -- it exports generic names
;;;; (TO-STRING, VERSION, UUID) that would collide as this ontology grows.
;;;; Call it qualified: (random-uuid:to-string (random-uuid:make-uuid)).

(defpackage #:loom-ontology
  (:use #:cl)
  (:export
   ;; declaration macros
   #:defentity
   #:defrelationship

   ;; shared vocabularies
   #:*source-languages*
   #:*case-insensitive-languages*
   #:case-insensitive-language-p
   #:*module-scoped-languages*
   #:module-scoped-language-p

   ;; mixins
   #:identified
   #:provenanced

   ;; identified
   #:id
   #:id-derived-p
   #:name

   ;; provenanced
   #:source
   #:confidence
   #:derived-from
   #:origin-file
   #:stale-p

   ;; entity
   #:entity
   #:entity-type
   #:properties

   ;; relationship
   #:relationship
   #:rel-type
   #:from-id
   #:to-id
   #:rebind-relationship

   ;; ontology operations (SS4.4) -- the vocabulary analyzers emit
   #:ontology-op
   #:assert-entity-op
   #:assert-relationship-op
   #:retract-file-op
   #:retract-op
   #:mark-stale-op
   #:update-properties-op
   #:workspace-id
   #:op-entity
   #:op-rel
   #:target-id
   #:path
   #:reason
   #:changes
   #:assert-entity
   #:assert-relationship
   #:assert-edge
   #:retract-file
   #:retract
   #:mark-stale
   #:update-properties

   ;; natural keys and derived ids (SS4.4, SS5.1)
   #:entity-natural-key
   #:relationship-natural-key
   #:derive-id
   #:fresh-id
   #:render-key-part
   #:properties-table

   ;; :CALL-SITE's shared constructor (DES-0014). Exported because two systems
   ;; mint the type -- the analyzer for initforms, the graph for definer calls
   ;; and ambiguity -- and a key spelled two ways would grow a duplicate per
   ;; pass that nothing retracts. The DEFENTITY class and its accessors export
   ;; themselves.
   #:entity-package
   #:call-site-label
   #:make-call-site-entity

   ;; type registry -- the single source of the schema
   #:*entity-type-registry*
   #:*relationship-type-registry*
   #:find-entity-type
   #:find-relationship-type
   #:find-property
   #:register-entity-type
   #:register-relationship-type
   #:all-entity-types
   #:all-relationship-types
   #:clear-entity-registry
   #:clear-relationship-registry

   ;; entity-type-spec
   #:entity-type-spec
   #:entity-type-key
   #:entity-type-class-name
   #:entity-type-documentation
   #:entity-type-properties
   #:entity-type-natural-key

   ;; property-spec
   #:property-spec
   #:property-key
   #:property-type
   #:property-required
   #:property-one-of
   #:property-documentation
   #:property-default-form
   #:property-default-thunk

   ;; relationship-type-spec
   #:relationship-type-spec
   #:relationship-type-key
   #:relationship-type-from
   #:relationship-type-to
   #:relationship-type-transitive-impact
   #:relationship-type-impact-direction
   #:relationship-type-collect-as
   #:relationship-type-documentation

   ;; validation
   #:ontology-error
   #:property-error
   #:property-error-entity-type
   #:property-error-key
   #:property-error-value
   #:property-error-problem
   #:validate-entity
   #:validate-relationship-endpoints
   #:check-property-value
   #:property-value-problem
   #:getp
   #:setp

   ;; schema export
   #:ontology-schema
   #:property-schema
   #:code-form-p
   #:*property-types*))
