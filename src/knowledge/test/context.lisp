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
