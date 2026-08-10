;;;
;;; Tests for src/ontology/code-ontology.lisp -- the declared taxonomy.
;;; These assert against the specification, not against the source file: the
;;; type census, the SS9 impact table, and the shape of the SS4.2 example.
;;; Copyright Brian Eberman, Ten Factor Growth 2022
;;;

(in-package :root-ontology-test)

(def-suite code-ontology
  :in all-tests
  :description "The declared code taxonomy and its impact metadata.")

(in-suite code-ontology)

;;; ------------------------------------------------------------------
;;; Census -- every type the design names is registered
;;; ------------------------------------------------------------------

(test every-specified-entity-type-is-registered
  (dolist (key '(:workspace :snapshot :repository :branch :commit
                 :file :package :module :class :interface
                 :function :method :variable
                 :test :document :concept :decision :rule))
    (is (not (null (find-entity-type key))) "~s must be registered" key)))

(test every-specified-relationship-type-is-registered
  (dolist (key '(:calls :depends-on :imports :uses :inherits :implements
                 :contains :belongs-to :tests :documents
                 :decides :applies-to :supersedes))
    (is (not (null (find-relationship-type key))) "~s must be registered" key)))

(test every-entity-type-is-documented
  ;; the documentation string is what the MCP tool descriptions embed, so an
  ;; undocumented type is an agent-visible gap, not a style lapse
  (dolist (key (all-entity-types))
    (is (not (null (entity-type-documentation (find-entity-type key))))
        "~s has no documentation" key)))

(test generated-class-names-do-not-shadow-common-lisp
  ;; :function, :class, :method, :package and :variable would all name CL
  ;; symbols if the class took the bare type name; the -ENTITY suffix is what
  ;; keeps the taxonomy free to use the natural vocabulary
  (dolist (key '(:function :class :method :package :variable))
    (let ((class-name (entity-type-class-name (find-entity-type key))))
      (is (not (eq (find-package :cl) (symbol-package class-name)))
          "~s generated ~s, which is a Common Lisp symbol" key class-name)
      (is (not (null (find-class class-name nil)))
          "~s did not generate a class" key))))

;;; ------------------------------------------------------------------
;;; Definition entities carry a location
;;; ------------------------------------------------------------------

(test definition-entities-require-a-file-and-a-line-range
  ;; a graph answer is only actionable if the agent can open the exact region
  ;; the fact came from
  (dolist (key '(:class :interface :function :method :test))
    (dolist (prop '(:file :start-line :end-line))
      (let ((p (find-property key prop)))
        (is (not (null p)) "~s is missing ~s" key prop)
        (is-true (property-required p) "~s ~s must be required" key prop)))))

(test the-function-type-matches-the-specified-shape
  (let ((spec (find-entity-type :function)))
    (is (eq 'string  (property-type (find-property :function :file))))
    (is (eq 'integer (property-type (find-property :function :start-line))))
    (is (eq 'boolean (property-type (find-property :function :exported-p))))
    (is (null (property-default-form (find-property :function :exported-p))))
    (is (eq 'function-entity (entity-type-class-name spec)))))

(test every-document-shaped-type-can-carry-a-summary
  ;; :SUMMARY started on :CONCEPT alone, which is why BASE-PROPERTIES had no
  ;; line for it and three of the four types folded summary: into :BODY and
  ;; kept nothing addressable.  Declared here first because VALIDATE-ENTITY
  ;; only checks *declared* properties: an undeclared :SUMMARY would be stored
  ;; and silently unvalidated, outside the schema the ontology exists to be.
  (dolist (key '(:document :decision :rule :concept))
    (let ((p (find-property key :summary)))
      (is (not (null p)) "~a has no :summary property" key)
      (is (eq 'string (property-type p))))))

(test a-document-status-covers-the-workflow-vocabulary
  ;; CON-0004's vocabulary has REQ and ARCH reaching implemented or partial,
  ;; and RULE-0005 requires a plan reaching final to move them there.  Outside
  ;; the :one-of list AS-KEYWORD returns NIL rather than signalling, so every
  ;; already-landed document carried :status NIL and nothing said so.
  (let ((allowed (property-one-of (find-property :document :status))))
    (is (member :implemented allowed))
    (is (member :partial allowed))))

(test unresolved-calls-are-a-property-not-an-edge
  ;; a callee outside the workspace must never become a dangling relationship
  (dolist (key '(:function :method))
    (is (eq 'list (property-type (find-property key :unresolved-calls))))
    ;; :CALL-NAMES is what the analyzer writes and resolution reads; it is
    ;; separate from :UNRESOLVED-CALLS precisely so that resolution can derive
    ;; one from the other every pass instead of consuming its own input.
    (is (eq 'list (property-type (find-property key :call-names))))))

;;; ------------------------------------------------------------------
;;; Workspace and history
;;; ------------------------------------------------------------------

(test a-snapshot-is-three-integers-and-a-timestamp
  ;; snapshots are taken after every applied transaction, so they must be
  ;; cheap by construction -- a position, never a copy of the graph
  (dolist (key '(:base-version :overlay-version :op-log-offset))
    (let ((p (find-property :snapshot key)))
      (is (eq 'integer (property-type p)) "~s must be an integer" key)
      (is-true (property-required p) "~s must be required" key))))

(test a-snapshot-timestamps-itself
  (let ((before (get-universal-time))
        (taken (snapshot-entity-taken-at
                (make-instance 'snapshot-entity))))
    (is (integerp taken))
    (is (>= taken before) "the default must be evaluated at creation")))

(test a-workspace-starts-at-version-zero
  (let ((w (make-instance 'workspace-entity)))
    (is (eql 0 (workspace-entity-base-version w)))
    (is (eql 0 (workspace-entity-overlay-version w)))))

;;; ------------------------------------------------------------------
;;; The shared language vocabulary
;;; ------------------------------------------------------------------

(test every-language-property-shares-one-vocabulary
  ;; :one-of *source-languages* must resolve to the variable's list, so adding
  ;; a language is a single push rather than an edit of nine declarations
  (let ((typed '(:file :package :module :class :interface
                 :function :method :variable :test)))
    (dolist (key typed)
      (let ((p (find-property key :language)))
        (is (not (null p)) "~s has no :language property" key)
        (is (eq *source-languages* (property-one-of p))
            "~s :language does not share the vocabulary" key)))))

(test the-system-property-is-declared-on-exactly-the-types-that-can-carry-one
  ;; ARCH-0009 R1. Asserted through FIND-PROPERTY rather than by round-tripping
  ;; an entity because getting this wrong is silent: VALIDATE-ENTITY only walks
  ;; declared properties, so an undeclared :SYSTEM would be stored and never
  ;; complained about -- everywhere except DECLARED-PROPERTIES-ONLY, which
  ;; filters a generated entity's plist against this exact set and would drop
  ;; the value without a word.
  (dolist (key '(:file :function :variable :class :interface :method
                 :test :document))
    (let ((p (find-property key :system)))
      (is (not (null p)) "~s has no :system property" key)
      (is (eq 'keyword (property-type p)) "~s :system must be a keyword" key)
      (is (null (property-one-of p))
          "~s :system must have no :one-of -- the vocabulary is open" key)))
  ;; :RULE, :DECISION and :CONCEPT declare no :PATH, so ENTITY-SYSTEM already
  ;; answers NIL for them and R1 makes that absence part of the requirement.
  (dolist (key '(:rule :decision :concept))
    (is (null (find-property key :system))
        "~s must not declare :system" key)))

(test the-language-vocabulary-covers-the-phase-one-analyzers
  (dolist (lang '(:lisp :typescript))
    (is-true (member lang *source-languages*) "~s must be analyzable" lang)))

(test language-values-are-validated-against-the-vocabulary
  (let ((f (make-instance 'file-entity)))
    (finishes (setf (file-entity-language f) :lisp))
    (signals property-error (setf (file-entity-language f) :cobol))))

;;; ------------------------------------------------------------------
;;; SS9 impact table, in executable form
;;; ------------------------------------------------------------------

(test impact-metadata-matches-the-specified-table
  (loop for (key transitive direction collect) in
        '((:calls       t   :reverse nil)
          (:depends-on  t   :reverse nil)
          (:imports     t   :reverse nil)
          (:uses        t   :reverse nil)
          (:inherits    t   :reverse nil)
          (:implements  t   :reverse nil)
          (:contains    nil :reverse nil)
          (:belongs-to  nil :forward nil)
          (:tests       nil :reverse :tests)
          (:documents   nil :reverse :documents)
          (:decides     nil :reverse :decisions)
          (:applies-to  nil :reverse :rules)
          (:supersedes  nil :reverse nil))
        for spec = (find-relationship-type key)
        do (is (eq transitive (and (relationship-type-transitive-impact spec) t))
               "~s transitive-impact" key)
           (is (eq direction (relationship-type-impact-direction spec))
               "~s impact-direction" key)
           (is (eq collect (relationship-type-collect-as spec))
               "~s collect-as" key)))

(test containment-does-not-propagate
  ;; if CONTAINS were transitive, one changed function would mark the
  ;; repository and every impact query would return the world
  (is-false (relationship-type-transitive-impact (find-relationship-type :contains))))

(test belongs-to-is-the-inverse-of-contains
  (let ((contains (find-relationship-type :contains))
        (belongs (find-relationship-type :belongs-to)))
    (is (equal (relationship-type-from contains) (relationship-type-to belongs)))
    (is (equal (relationship-type-to contains) (relationship-type-from belongs)))))

;;; ------------------------------------------------------------------
;;; Endpoint validation against the real taxonomy
;;; ------------------------------------------------------------------

(test legal-edges-validate
  (is (null (validate-relationship-endpoints :calls :function :function)))
  (is (null (validate-relationship-endpoints :calls :test :method)))
  (is (null (validate-relationship-endpoints :contains :file :function)))
  (is (null (validate-relationship-endpoints :inherits :class :class)))
  (is (null (validate-relationship-endpoints :tests :test :function))))

(test a-generated-definition-can-point-at-what-generated-it
  ;; ARCH-0002 R4. All three returned a problem list before the widening, and
  ;; PLAN-OP rejects a whole transaction on one illegal endpoint -- so without
  ;; these three pairs RESOLVE-GENERATED-DEFINITIONS loses every op it emits,
  ;; not just the offending one. code-ontology.lisp records that happening
  ;; before, when :DECIDES did not permit :INTERFACE.
  (is (null (validate-relationship-endpoints :uses :interface :class))
      "a DEFCLASS slot accessor is an :interface and must reach its class")
  (is (null (validate-relationship-endpoints :uses :test :function))
      "a generated test must reach the macro, which is a :function")
  (is (null (validate-relationship-endpoints :tests :test :interface))
      "and a test that calls a slot accessor directly still covers it"))

(test a-call-site-is-called-from-and-contained-by-what-refers-to-it
  ;; ARCH-0014 R1, plus PLAN-0014 decision 3 for the caller-side :CONTAINS.
  ;; PLAN-OP rejects a whole transaction on one illegal endpoint, so each of
  ;; these missing would cost RESOLVE-CALLS every op it emits rather than one
  ;; edge -- which is the failure a-generated-definition-can-point-at-what-
  ;; generated-it records happening before.
  (is (null (validate-relationship-endpoints :calls :call-site :function))
      "the edge runs from the call site to the callee, which is the whole
ontology cost of ARCH-0014")
  (is (null (validate-relationship-endpoints :contains :variable :call-site))
      "BUG-0017: an initform's site belongs to the variable that holds it")
  (is (null (validate-relationship-endpoints :contains :class :call-site))
      "and a slot initform's to its class")
  (is (null (validate-relationship-endpoints :contains :file :call-site))
      "BUG-0016: a definer call site's belongs to the file")
  (is (null (validate-relationship-endpoints :contains :function :call-site))
      "REQ-0015: and an ambiguous site to the caller it runs from, or
`describe' on that caller shows the site as no neighbour at all")
  ;; The guard on all five. A call site is a call, not a callable: widening
  ;; :CALLS' :TO as well would let one call site call another, which is the
  ;; recursion PLAN-0014 decision 6 exists to prevent.
  (is (not (null (validate-relationship-endpoints :calls :function :call-site)))
      "nothing calls a call site"))

(test two-constructions-of-one-call-site-agree-on-its-identity
  ;; The seam ARCH-0014's RISKS section names: the analyzer mints initform
  ;; sites and the graph mints the other two, so if the two ever spelled the
  ;; key differently the graph would grow a duplicate per pass that nothing
  ;; retracts. MAKE-CALL-SITE-ENTITY being the only constructor is the
  ;; insurance; this asserts the property that makes it worth having.
  (let ((a (make-call-site-entity :file "a.lisp" :start-line 12
                                  :call-name "target" :referrer-kind :variable
                                  :language :lisp :system :demo))
        (b (make-call-site-entity :file "a.lisp" :start-line 12
                                  :call-name "target" :referrer-kind :definer-call
                                  :generated-by "define-operation"
                                  :language :lisp :system :other)))
    (is (equal (entity-natural-key a) (entity-natural-key b))
        "the key is (:file :start-line :call-name) and nothing else -- two
minting passes disagreeing about the referrer must still land on one entity")
    (is (equal "call-site:a.lisp:12:target" (id a))
        "and the derived id reads the way every other derived id here does")
    (is (equal "call-site:a.lisp:12:target" (id b))))
  ;; A different line is a different site, which is what lets two colliding
  ;; definitions produce two call sites rather than one merged set (BUG-0012).
  (is (not (equal (id (make-call-site-entity :file "a.lisp" :start-line 12
                                             :call-name "target"))
                  (id (make-call-site-entity :file "a.lisp" :start-line 13
                                             :call-name "target"))))))

(test a-call-sites-name-carries-its-referenced-name-and-its-location
  ;; PLAN-0014 decision 1. NAME cannot be the bare referenced name:
  ;; LINKABLE-INDEX keys every named entity and RESOLVE-ONE refuses a name
  ;; matching several, so call sites named exactly like their callees would
  ;; turn resolved `affects:' references into unresolved ones and move the
  ;; pinned "0 unresolved document references" off zero.
  (let ((site (make-call-site-entity :file "src/serve/operations.lisp"
                                     :start-line 165
                                     :call-name "violation-summary"
                                     :referrer-kind :definer-call)))
    (is (equal "violation-summary@src/serve/operations.lisp:165" (name site)))
    (is (equal "violation-summary" (getp site :call-name))
        "the referenced name is the property, so RESOLVE-CALLS looks up the
callee rather than the label")
    (is (null (getp site :call-names))
        "and the name is stored once -- CALLER-CALL-NAMES derives the list
RESOLVE-CALLS reads, so a second copy here could drift from the key")
    (is (equal (call-site-label "violation-summary" "src/serve/operations.lisp" 165)
               (name site))
        "the label and the entity cannot disagree, because one makes the other")))

(test a-document-may-mention-a-test
  ;; Found by running the pipeline over Loom's own tree the first time :TEST
  ;; held any facts. fiveam names tests in prose, so a document discussing one
  ;; mentions it by name and the mention resolves -- and PLAN-OP rejects the
  ;; whole transaction on one illegal endpoint, so this cost every document
  ;; link in the repository rather than one edge.
  (is (null (validate-relationship-endpoints :documents :concept :test))))

(test illegal-edges-are-rejected
  (is (not (null (validate-relationship-endpoints :calls :file :function)))
      "a file does not call")
  (is (not (null (validate-relationship-endpoints :inherits :function :class)))
      "a function does not inherit")
  (is (not (null (validate-relationship-endpoints :tests :function :function)))
      "only a test tests"))

(test an-unconstrained-endpoint-accepts-anything
  ;; An empty :to declaration means unconstrained. Nothing in the current
  ;; taxonomy leaves both ends open, so this checks the validator's handling
  ;; of the case directly rather than through a type that happens to use it.
  (is (null (validate-relationship-endpoints :calls :function :function)))
  (let ((spec (find-relationship-type :decides)))
    (is (not (null (relationship-type-to spec)))
        "SS5.3 names the types a decision may govern, so :decides is
constrained on both ends")))

(test decisions-and-rules-are-keyed-by-their-document-id
  ;; SS10.1: a decision is a YAML file, and its id: field is what other
  ;; documents reference it by, so that is its identity in the index too
  (is (equal '(:doc-id) (entity-type-natural-key (find-entity-type :decision))))
  (is (equal '(:doc-id) (entity-type-natural-key (find-entity-type :rule)))))

(test a-rule-carries-a-severity-and-a-check
  ;; SS10.4: a rule that cannot be compiled to a check stays valid as prose
  ;; with severity :advisory, so CHECK must be optional and SEVERITY must not
  (let ((r (make-instance 'rule-entity :name "RULE-0007"
                                       :properties (properties-table
                                                    '(:doc-id "RULE-0007")))))
    (is (null (validate-entity r)))
    (is (eq :error (getp r :severity)) "severity defaults to the strict end")
    (is (eq :active (getp r :status)))
    (is (null (getp r :check)) "advisory rules have no check")))

;;; ------------------------------------------------------------------
;;; A realistic entity, end to end
;;; ------------------------------------------------------------------

(test a-populated-function-entity-validates
  (let ((f (make-instance 'function-entity
                          :name "validate-entity" :source :structural)))
    (setf (function-entity-file f) "src/ontology/root-ontology.lisp"
          (function-entity-start-line f) 214
          (function-entity-end-line f) 232
          (function-entity-signature f) "(validate-entity e)"
          (function-entity-exported-p f) t
          (function-entity-language f) :lisp)
    (is (null (validate-entity f)))
    (is (eq :function (entity-type f)) "the wire form is the declared keyword")
    ;; Constructed before its :file was known, so the id was first derived from
    ;; an incomplete key -- and moved when the key completed. Without that, an
    ;; entity built this way would carry a plausible-looking wrong id.
    (is (string= "function:src/ontology/root-ontology.lisp:validate-entity" (id f))
        "the id follows the natural key until the entity enters the index")))

(test an-id-stops-following-the-natural-key-once-the-entity-is-indexed
  ;; Other facts point at an id, so it cannot keep moving under them. SS5.1's
  ;; "stable id" is stable from the moment the Graph Manager takes it.
  (let ((f (make-instance 'function-entity :name "before"
                          :properties (properties-table
                                       '(:file "a.lisp" :start-line 1 :end-line 2)))))
    (is-true (id-derived-p f))
    (setf (function-entity-file f) "b.lisp")
    (is (string= "function:b.lisp:before" (id f)) "still tracking")
    (setf (id-derived-p f) nil)                     ; what ADD-ENTITY does
    (setf (function-entity-file f) "c.lisp")
    (is (string= "function:b.lisp:before" (id f))
        "frozen: the property moved, the identity did not")))

(test an-incomplete-function-entity-is-reported
  (let* ((f (make-instance 'function-entity))
         (problems (validate-entity f)))
    ;; every failing property is reported, not just the first: the Graph
    ;; Manager rejects a transaction with all of its problems at once
    (is (equal '(:file :start-line :end-line)
               (mapcar (lambda (p) (getf p :key)) problems)))))

;;; ------------------------------------------------------------------
;;; Schema export
;;; ------------------------------------------------------------------

(test the-published-schema-covers-the-whole-taxonomy
  (let ((schema (ontology-schema)))
    (is (= (length (all-entity-types)) (length (getf schema :entity-types))))
    (is (= (length (all-relationship-types))
           (length (getf schema :relationship-types))))
    (is-false (tree-contains-function-p schema)
              "the schema is served over HTTP and must hold no closures")))
