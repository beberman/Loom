;;;
;;; Tests for src/knowledge/context.lisp -- SS11's loom_context.
;;;

(in-package :loom-knowledge-test)

(def-suite context
  :in all-tests
  :description "TASK-TOKENS, BUILD-CONTEXT, budget enforcement, and the log.")

(in-suite context)

;;; ------------------------------------------------------------------
;;; Seeding
;;; ------------------------------------------------------------------

(test task-tokens-drops-noise-and-keeps-identifiers
  (let ((tokens (loom-knowledge::task-tokens
                 "How does the overlay get reset when I switch branches?")))
    (is (member "overlay" tokens :test #'string=))
    (is (member "branches" tokens :test #'string=))
    (is (not (member "the" tokens :test #'string=)))
    (is (not (member "how" tokens :test #'string=)))
    (is (not (member "does" tokens :test #'string=)))))

(test task-tokens-keeps-a-compound-whole-and-split
  (let ((tokens (loom-knowledge::task-tokens "change resolve-overlay")))
    (is (member "resolve-overlay" tokens :test #'string=)
        "the exact name has to be matchable")
    (is (member "resolve" tokens :test #'string=))
    (is (member "overlay" tokens :test #'string=)
        "and so do its parts, for when the exact name is not in the graph")))

(test seeding-finds-the-entities-a-task-names
  (let* ((f (make-k-fixture))
         (seeds (loom-knowledge::seed-entities (k-graph f) "fix resolve-overlay")))
    (is (string= "resolve-overlay" (name (first seeds)))
        "the exactly-named entity must come first")))

;;; ------------------------------------------------------------------
;;; Bundles
;;; ------------------------------------------------------------------

(test a-bundle-contains-the-seeds-and-their-neighbourhood
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "resolve-overlay" (getf bundle :seeds)
                :key (lambda (s) (getf s :name)) :test #'string=))
    (let ((names (mapcar (lambda (i) (getf (getf i :entity) :name))
                         (getf bundle :items))))
      (is (member "resolve-overlay" names :test #'string=))
      (is (member "compose-view" names :test #'string=)
          "one hop out from the seed"))))

(test a-bundle-carries-the-decisions-bearing-on-what-it-found
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "ADR-7" (getf bundle :decisions)
                :key (lambda (d) (getf d :name)) :test #'string=)
        "why the code is the way it is, which no amount of re-reading recovers")))

(test a-bundle-excludes-stale-knowledge
  (let* ((f (make-k-fixture)))
    (setf (stale-p (k-adr f)) t)
    (let ((bundle (build-context (k-graph f) "change resolve-overlay")))
      (is (null (getf bundle :decisions))
          "SS-provenance: stale facts stay out of agent context until re-verified"))))

(test a-bundle-that-matches-nothing-says-so-rather-than-inventing
  (let ((bundle (build-context (k-graph (make-k-fixture)) "rewrite the leaflet map")))
    (is (null (getf bundle :seeds)))
    (is (null (getf bundle :items)))
    (is (search "No indexed entity matched" (render-context bundle)))))

;;; ------------------------------------------------------------------
;;; Bands (REQ-0026, DES-0020)
;;;
;;; The fixture the shared k-fixture cannot be: it needs a :DOCUMENT reached by
;;; a declared edge, a :DOCUMENT reached only by a mention, a governing type
;;; reached only by a mention, and a document carrying both kinds of edge at
;;; once. Built here rather than folded into MAKE-K-FIXTURE so that the two
;;; tests above keep testing the graph they were written against -- they are
;;; the regression guard for DES-0020's claim that nothing leaves a bundle, and
;;; a guard whose fixture moved under it guards nothing.
;;; ------------------------------------------------------------------

(defun band-doc (type name properties)
  (make-instance type :name name
                 :origin-file (format nil "docs/~a" name)
                 :properties (properties-table properties)))

(defun banded-fixture ()
  "The k-fixture plus one document of every kind the bands have to tell apart."
  (let* ((f (make-k-fixture))
         (g (k-graph f))
         ;; A requirement: :DOCUMENT, declaring affects: -- which resolves to a
         ;; :DOCUMENTS edge. The population the old type filter discarded.
         (req  (band-doc 'document-entity "REQ-9001"
                      '(:path "docs/requirements/REQ-9001.yaml" :doc-id "REQ-9001"
                        :category "requirements" :format :yaml)))
         ;; Prose naming two of the bundle's entities, and prose naming one.
         ;; Markdown cannot produce a declared edge, so both can only ever
         ;; arrive by :MENTIONS -- which is DES-0020 D3's whole argument.
         (near (band-doc 'document-entity "docs/overlay-notes.md"
                      '(:path "docs/overlay-notes.md" :format :markdown)))
         (far  (band-doc 'document-entity "docs/glossary.md"
                      '(:path "docs/glossary.md" :format :markdown)))
         ;; A design reached ONLY by a mention. The behaviour the old filter's
         ;; comment defends, and which the new banding must not lose.
         (des  (band-doc 'design-entity "DES-9001" '(:doc-id "DES-9001"))))
    (dolist (e (list req near far des)) (add-entity g e))
    (k-edge g :documents req  (k-resolve f))
    (k-edge g :mentions  near (k-resolve f))
    (k-edge g :mentions  near (k-compose f))
    (k-edge g :mentions  far  (k-resolve f))
    (k-edge g :mentions  des  (k-resolve f))
    ;; The ADR already has a :DECIDES edge from the shared fixture; give it a
    ;; :MENTIONS edge too, so one document carries both kinds at once.
    (k-edge g :mentions (k-adr f) (k-resolve f))
    (values f req near far des)))

(defun band-names (bundle band)
  (loop for item in (getf bundle :items)
        when (eq band (getf item :band))
          collect (getf (getf item :entity) :name)))

(test a-document-that-declares-it-bears-on-the-code-reaches-the-bundle
  ;; REQ-0026's whole complaint. REQ-9001 is a :DOCUMENT, which is what
  ;; requirements, plans, bugs and reviews all are, and it declares affects:
  ;; -- so it earns a :DOCUMENTS edge that DECISIONS-TOUCHING collected and
  ;; then threw away for having the wrong type. Delete the documents band and
  ;; this fails.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "REQ-9001" (getf bundle :documents)
                :key (lambda (d) (getf d :name)) :test #'string=)
        "a declared claim on this code belongs in the bundle whatever its type")
    (is (member "REQ-9001" (band-names bundle :document) :test #'string=))
    (is (not (member "REQ-9001" (band-names bundle :decision) :test #'string=))
        "and it is not a decision: a requirement asks for code, it does not govern it")))

(test a-governing-type-reached-only-by-a-mention-is-still-a-decision
  ;; The behaviour the old filter's comment defends, kept. DES-9001 has no
  ;; declared edge at all -- only a backtick in someone's prose -- and it must
  ;; still land among the decisions, because walking :MENTIONS was put there
  ;; for exactly this case.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "DES-9001" (band-names bundle :decision) :test #'string=)
        "decisions band: ~a" (band-names bundle :decision))))

(test a-document-carrying-both-kinds-of-edge-appears-once-in-the-strongest-band
  ;; ADR-7 has both a :DECIDES and a :MENTIONS edge to the seed. Banding per
  ;; edge rather than per document would put it in two bands and print it
  ;; twice, spending the budget on a duplicate.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"))
         (names (mapcar (lambda (i) (getf (getf i :entity) :name))
                        (getf bundle :items))))
    (is (= 1 (count "ADR-7" names :test #'string=))
        "ADR-7 appears ~d times" (count "ADR-7" names :test #'string=))
    (is (member "ADR-7" (band-names bundle :decision) :test #'string=))))

(test prose-is-ranked-by-how-much-of-the-bundle-it-actually-names
  ;; DES-0020 D4. overlay-notes.md names two of the bundle's entities and
  ;; glossary.md names one, so the first is likelier to be about the task. A
  ;; bare cap in graph order would be an arbitrary answer that looked definite.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"))
         (mentions (band-names bundle :mention)))
    (is (equal '("docs/overlay-notes.md" "docs/glossary.md") mentions)
        "ranked by mention count, not by graph order: ~a" mentions)))

(test the-mention-band-is-capped-so-prose-cannot-flood-a-bundle
  ;; The reason the old filter existed, and the constraint any answer had to
  ;; keep. Ten markdown files all naming the seed, and the bundle admits
  ;; *CONTEXT-MENTION-LIMIT* of them.
  (let* ((f (make-k-fixture))
         (g (k-graph f)))
    (dotimes (n 10)
      (let ((doc (band-doc 'document-entity (format nil "docs/note-~2,'0d.md" n)
                        (list :path (format nil "docs/note-~2,'0d.md" n)
                              :format :markdown))))
        (add-entity g doc)
        (k-edge g :mentions doc (k-resolve f))))
    (let ((bundle (build-context g "change resolve-overlay")))
      (is (= loom-knowledge::*context-mention-limit*
             (length (band-names bundle :mention)))
          "~d admitted, cap is ~d"
          (length (band-names bundle :mention))
          loom-knowledge::*context-mention-limit*))))

(test the-rendered-bundle-says-why-each-entry-is-in-it
  ;; DES-0020 D6, and the step that makes the other four observable. Before
  ;; this, every item printed as the same kind of line and the :DECISIONS field
  ;; was never rendered at all -- so an agent could not tell the code it asked
  ;; about from the reasoning about it.
  (let* ((f (banded-fixture))
         (text (render-context (build-context (k-graph f) "change resolve-overlay"))))
    (dolist (heading '("the task named these" "decisions governing them"
                       "documents bearing on them" "prose that names them"))
      (is (search heading text) "the ~s heading is missing from the block" heading))))

(test the-reasoning-survives-a-budget-the-seeds-would-have-eaten
  ;; DES-0020 D5a, and the defect that made the whole feature inert on a real
  ;; tree: measured on ~/lisp/game-server, eight seeds and their relations spent
  ;; 1968 of 2000 tokens and the bundle truncated before the first document, so
  ;; the band this design adds was empty on exactly the repository it was built
  ;; for. A budget this tight reproduces it -- without the reserve the seeds
  ;; consume everything and the documents band is empty.
  ;;
  ;; 450 is chosen so the budget bites in exactly the interesting place: the
  ;; seeds alone cost more than that, so without the reserve they fill it and
  ;; no document survives. CON-0003 -- remove the reserve and this fails.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 450)))
    (is-true (getf bundle :truncated) "the budget has to actually bite")
    (is (member "REQ-9001" (band-names bundle :document) :test #'string=)
        "the declared document survives a budget the seeds would have eaten: ~a"
        (mapcar (lambda (i) (list (getf i :band) (getf (getf i :entity) :name)))
                (getf bundle :items)))
    (is (member "resolve-overlay" (band-names bundle :seed) :test #'string=)
        "and the reserve did not cost the best seed, which it may never do")
    (is (<= (getf bundle :tokens) 450) "and the budget is still a budget")))

(test a-stale-document-stays-out-of-every-band
  ;; The staleness rule applied to the two new bands as well as the old one.
  ;; A stale fact is one nobody has re-verified, and the bands are three ways
  ;; into a bundle rather than three exemptions from that.
  (multiple-value-bind (f req near) (banded-fixture)
    (setf (stale-p req) t
          (stale-p near) t)
    (let ((bundle (build-context (k-graph f) "change resolve-overlay")))
      (is (null (band-names bundle :document)))
      (is (not (member "docs/overlay-notes.md" (band-names bundle :mention)
                       :test #'string=))))))

;;; ------------------------------------------------------------------
;;; Budget
;;; ------------------------------------------------------------------

(test a-bundle-stays-within-its-budget
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 40)))
    (is (<= (getf bundle :tokens) 40))
    (is-true (getf bundle :truncated)
             "and says when it had to leave something out")))

(test a-generous-budget-is-not-truncated
  (let ((bundle (build-context (k-graph (make-k-fixture))
                               "change resolve-overlay" :budget 100000)))
    (is-false (getf bundle :truncated))))

;;; ------------------------------------------------------------------
;;; Rendering
;;; ------------------------------------------------------------------

(test rendering-puts-the-location-on-every-line
  (let* ((f (make-k-fixture))
         (text (render-context (build-context (k-graph f) "change resolve-overlay"))))
    (is (search "resolve-overlay" text))
    (is (search "src/workspace/overlay.lisp:41-53" text)
        "the rendered line has to be enough to open the code")))

;;; ------------------------------------------------------------------
;;; Instrumentation (SS11: "instrumented from day one")
;;; ------------------------------------------------------------------

(test every-request-is-logged-with-what-it-got
  (clear-context-log)
  (let ((f (make-k-fixture)))
    (build-context (k-graph f) "change resolve-overlay")
    (build-context (k-graph f) "rewrite the leaflet map"))
  (is (= 2 (length *context-log*)))
  (let ((summary (context-log-summary)))
    (is (= 2 (getf summary :requests)))
    (is (= 1 (getf summary :seeded-nothing))
        "requests that found nothing are the signal that name matching is
not enough -- they have to be countable"))
  (clear-context-log))
