;;;
;;; Tests for src/knowledge/services.lisp -- the read-only tools of SS11.
;;;

(in-package :loom-knowledge-test)

(def-suite services
  :in all-tests
  :description "ENTITY-SUMMARY, SEARCH-ENTITIES, DESCRIBE-ENTITY, IMPACT-REPORT.")

(in-suite services)

;;; ------------------------------------------------------------------
;;; Summaries
;;; ------------------------------------------------------------------

(test a-summary-carries-the-location-an-agent-would-open
  (let* ((f (make-k-fixture))
         (summary (entity-summary (k-resolve f))))
    (is (string= "src/workspace/overlay.lisp:41-53" (getf summary :location))
        "file plus line range is the whole point -- a filename alone still
costs the agent a read")
    (is (eq :function (getf summary :type)))
    (is (string= "resolve-overlay" (getf summary :name)))
    (is (eq :structural (getf summary :source)))
    (is (null (getf summary :stale)))))

(test a-file-entity-locates-by-path
  (let ((f (make-k-fixture)))
    (is (string= "src/workspace/overlay.lisp"
                 (getf (entity-summary (k-file f)) :location)))))

(test a-summary-reports-staleness
  (let ((f (make-k-fixture)))
    (setf (stale-p (k-resolve f)) t)
    (is-true (getf (entity-summary (k-resolve f)) :stale))))

;;; ------------------------------------------------------------------
;;; search-entities (loom_find)
;;; ------------------------------------------------------------------

(test search-ranks-an-exact-name-above-a-substring
  (let* ((f (make-k-fixture))
         (hits (search-entities (k-graph f) :name "overlay" :type :function)))
    (is (= 2 (length hits)))
    (is (string= "resolve-overlay" (getf (first hits) :name)))
    (is (string= "reset-overlay" (getf (second hits) :name)))))

(test search-puts-an-exact-match-first
  (let* ((f (make-k-fixture))
         (hits (search-entities (k-graph f) :name "compose-view")))
    (is (string= "compose-view" (getf (first hits) :name)))))

(test search-honours-a-limit
  (let ((f (make-k-fixture)))
    (is (= 1 (length (search-entities (k-graph f) :name "overlay" :limit 1))))))

(test search-with-no-match-returns-nothing-rather-than-guessing
  (is (null (search-entities (k-graph (make-k-fixture)) :name "leaflet"))))

;;; ------------------------------------------------------------------
;;; describe-entity (loom_describe)
;;; ------------------------------------------------------------------

(test describe-returns-nil-for-an-unknown-id
  (is (null (describe-entity (k-graph (make-k-fixture)) "no-such-id"))))

(test describe-groups-neighbors-by-direction-and-type
  (let* ((f (make-k-fixture))
         (detail (describe-entity (k-graph f) (id (k-resolve f))))
         (groups (getf detail :neighbors)))
    (flet ((group (direction rel-type)
             (find-if (lambda (g) (and (eq direction (getf g :direction))
                                       (eq rel-type (getf g :rel-type))))
                      groups)))
      (is (not (null (group :in :calls))) "resolve-overlay is called by compose-view")
      (is (equal '("compose-view")
                 (mapcar (lambda (e) (getf e :name))
                         (getf (group :in :calls) :entities))))
      (is (not (null (group :in :contains))))
      (is (not (null (group :in :tests))))
      (is (not (null (group :in :decides)))))))

(test describe-includes-the-type-specific-properties
  (let* ((f (make-k-fixture))
         (detail (describe-entity (k-graph f) (id (k-adr f)))))
    (is (search "reset the overlay"
                (getf (getf detail :properties) :decision))
        "the decision text is exactly the knowledge that cannot be recovered
by reading source")))

;;; ------------------------------------------------------------------
;;; impact-report (loom_impact)
;;; ------------------------------------------------------------------

(test impact-report-explains-why-each-entity-is-affected
  (let* ((f (make-k-fixture))
         (report (impact-report (k-graph f) (id (k-resolve f))))
         (reset (find "reset-overlay" (getf report :impacted)
                      :key (lambda (e) (getf e :name)) :test #'string=)))
    (is (= 2 (getf reset :depth)))
    (is (string= "calls>compose-view calls>reset-overlay" (getf reset :via))
        "a path of names is what lets an agent judge whether the reason matters")))

(test impact-report-separates-tests-and-decisions-from-the-impact-set
  (let* ((f (make-k-fixture))
         (report (impact-report (k-graph f) (id (k-resolve f)))))
    (is (equal '("overlay-resolution-test")
               (mapcar (lambda (e) (getf e :name)) (getf report :tests))))
    (is (equal '("ADR-7")
               (mapcar (lambda (e) (getf e :name)) (getf report :decisions))))
    (is (= 3 (getf report :count))
        "compose-view, reset-overlay, and the containing file")))

(test impact-report-returns-nil-for-an-unknown-id
  (is (null (impact-report (k-graph (make-k-fixture)) "no-such-id"))))
