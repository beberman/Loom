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

   ;; mixins
   #:identified
   #:provenanced

   ;; identified
   #:id
   #:name

   ;; provenanced
   #:source
   #:confidence
   #:derived-from
   #:last-verified
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
