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

(test describe-carries-a-bounded-summary-alongside-the-full-properties
  (let* ((f (make-k-fixture))
         (detail (describe-entity (k-graph f) (id (k-adr f)))))
    (is (eq :rationale (getf (getf detail :document) :field)))
    (is (search "Diffing an overlay"
                (getf (getf detail :properties) :rationale))
        "and :properties still holds the full untruncated text -- this is the
assertion that fails if someone later \"fixes\" describe by truncating there")))

(test describe-of-a-code-entity-has-no-document-key
  ;; Passes today, vacuously, because the key does not exist yet: this is a
  ;; regression guard, not the witness for the key being added.
  (let ((f (make-k-fixture)))
    (is (null (getf (describe-entity (k-graph f) (id (k-resolve f))) :document)))))

;;; ------------------------------------------------------------------
;;; document-summary -- a bounded answer for a document-shaped entity
;;;
;;; These build their entities locally rather than extending the shared
;;; K-FIXTURE: DOCUMENT-SUMMARY takes an entity, not a view, so nothing here
;;; needs the graph, and three tests above assert exact fixture hit counts.
;;; ------------------------------------------------------------------

(defun k-doc (class properties)
  (make-instance class :name (getf properties :doc-id)
                       :origin-file "docs/x.yaml"
                       :properties (properties-table properties)))

(defun k-long-text ()
  "Several hundred words, comfortably over *SUMMARY-TOKEN-BUDGET*."
  (with-output-to-string (s)
    (dotimes (i 400) (format s "word~d " i))))

(test document-summary-prefers-the-authors-own-summary
  (let ((doc (k-doc 'document-entity
                    (list :doc-id "ARCH-9" :title "A bounded describe"
                          :status :draft
                          :summary "One paragraph the author actually wrote."
                          :body "The whole concatenation, which is not this."))))
    (let ((s (document-summary doc)))
      (is (eq :summary (getf s :field)))
      (is (string= "One paragraph the author actually wrote." (getf s :text)))
      (is (null (getf s :truncated)))
      (is (string= "A bounded describe" (getf s :title)))
      (is (eq :draft (getf s :status))))))

(test document-summary-names-the-fallback-field-it-showed
  ;; Asserting :FIELD is the point: a fallback that does not report which
  ;; field it showed is indistinguishable from a summary the author wrote,
  ;; which is the fabrication CON-0001 forbids.
  (let ((s (document-summary (k-adr (make-k-fixture)))))
    (is (eq :rationale (getf s :field)))
    (is (search "Diffing an overlay" (getf s :text)))))

(test document-summary-tells-two-kinds-of-nothing-apart
  ;; NIL and a plist whose :FIELD is NIL mean different things -- "no summary
  ;; shape for this type" and "a summary shape nobody filled" -- and an
  ;; implementation that conflated them would pass a weaker test than this.
  (let ((s (document-summary (k-doc 'rule-entity
                                    (list :doc-id "RULE-9" :title "Unwritten")))))
    (is (null (document-summary (k-resolve (make-k-fixture))))
        "a :function has no summary shape at all")
    (is (not (null s)) "a :rule does, even when nothing fills it")
    (is (null (getf s :field)))
    (is (null (getf s :text)))
    (is (string= "Unwritten" (getf s :title)))))

(test bounded-text-cuts-at-a-word-boundary-and-says-it-did
  ;; Asserted against ESTIMATE-TOKENS rather than a real token count: the
  ;; budget is spent in that function's currency, four characters to the
  ;; token, and an assertion in any other would start lying the day the
  ;; estimate is replaced.
  (let ((long (k-long-text)))
    (multiple-value-bind (shown truncated) (bounded-text long 120)
      (is-true truncated)
      (is (< (length shown) (length long)))
      (is (string= shown (subseq long 0 (length shown))) "a prefix, not a rewrite")
      (is (<= (estimate-tokens shown) 120))
      (is (member (char long (length shown)) '(#\Space #\Tab #\Newline))
          "the cut lands on whitespace, so no word is split")))
  (multiple-value-bind (shown truncated) (bounded-text "short" 120)
    (is (string= "short" shown))
    (is (null truncated))))

(test document-summary-reports-the-full-size-of-what-it-cut
  (let* ((long (k-long-text))
         (s (document-summary (k-doc 'rule-entity
                                     (list :doc-id "RULE-8" :statement long)))))
    (is (eq :statement (getf s :field)))
    (is-true (getf s :truncated))
    (is (> (getf s :full-tokens) *summary-token-budget*)
        "the size reported is of what was cut, not of what was shown")
    (is (<= (estimate-tokens (getf s :text)) *summary-token-budget*))))

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
