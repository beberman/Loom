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

(test a-call-sites-summary-carries-the-kind-of-referrer-it-came-from
  ;; DES-0014 R7: `describe' on a callee must show an incoming call site with
  ;; its line and kind rather than a bare id. The line is already in :LOCATION;
  ;; the kind has nowhere else to come from, because a summary is deliberately
  ;; not the whole property table.
  (let ((summary (entity-summary
                  (make-call-site-entity :file "src/workspace/overlay.lisp"
                                         :start-line 41 :end-line 53
                                         :call-name "resolve-overlay"
                                         :referrer-kind :ambiguous
                                         :candidate-count 2
                                         :language :lisp :system :workspace))))
    (is (eq :ambiguous (getf summary :referrer-kind)))
    (is (string= "src/workspace/overlay.lisp:41-53" (getf summary :location)))))

(test an-ordinary-entity-carries-a-null-kind-rather-than-no-key-at-all
  ;; The default argument is the whole test. GETF of an absent key already
  ;; answers NIL, so asserting (null ...) alone would pass just as well before
  ;; :REFERRER-KIND was added as after -- CON-0003's test that passes for the
  ;; wrong reason. :ABSENT distinguishes "present and NIL" from "not there".
  (let ((summary (entity-summary (k-resolve (make-k-fixture)))))
    (is (null (getf summary :referrer-kind :absent))
        "every summary carries the key so a consumer can read it unconditionally")))

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

(test search-says-how-many-matched-before-the-limit-cut-the-list
  ;; BUG-0002. Twenty rows and no total read as the whole truth: `find "" test\'
  ;; answered 20 where Loom holds 798 tests. The count is what tells a caller
  ;; which of the two questions they asked -- where is X, or what is there.
  (let ((f (make-k-fixture)))
    (multiple-value-bind (hits total)
        (search-entities (k-graph f) :name "overlay" :type :function :limit 1)
      (is (= 1 (length hits)) "the limit is still honoured")
      (is (= 2 total) "and the caller is told what it did not see"))
    (multiple-value-bind (hits total)
        (search-entities (k-graph f) :name "overlay" :type :function)
      (is (= 2 (length hits)))
      (is (= 2 total) "an uncut answer reports its own length, not a flag"))
    (multiple-value-bind (hits total)
        (search-entities (k-graph f) :name "leaflet")
      (is (null hits))
      (is (= 0 total)))))

(test search-with-no-match-returns-nothing-rather-than-guessing
  (is (null (search-entities (k-graph (make-k-fixture)) :name "leaflet"))))


;;; ------------------------------------------------------------------
;;; Picking one entity for a name (BUG-0032)
;;; ------------------------------------------------------------------
;;;
;;; A file named after what it exports is the whole convention of a React
;;; codebase, and SIGNIFICANT-NAME reduces LayerEditor.jsx to "LayerEditor" --
;;; so the file and the 251-line component are both exact matches and the tie
;;; fell to index order. `find' listing the file first is argued and wanted;
;;; `describe' picking it answers about a directory listing and, since
;;; REQ-0031, refuses to serve source for a definition three lines away.

(defun bnm-fixture ()
  "A graph where a file and a definition share one name, and a second
definition prefix-matches it."
  (let* ((g (make-graph))
         (file (make-instance 'file-entity :name "src/ui/LayerEditor.jsx"
                              :origin-file "src/ui/LayerEditor.jsx"
                              :properties (properties-table
                                           '(:path "src/ui/LayerEditor.jsx"
                                             :language :javascript))))
         (component (make-instance 'variable-entity :name "LayerEditor"
                                   :origin-file "src/ui/LayerEditor.jsx"
                                   :properties (properties-table
                                                '(:file "src/ui/LayerEditor.jsx"
                                                  :start-line 176 :end-line 426
                                                  :language :javascript))))
         (longer (make-instance 'function-entity :name "LayerEditorState"
                                :origin-file "src/ui/hooks.js"
                                :properties (properties-table
                                             '(:file "src/ui/hooks.js"
                                               :start-line 32 :end-line 393
                                               :language :javascript)))))
    (dolist (e (list file component longer)) (add-entity g e))
    (values g file component longer)))

(test best-name-match-prefers-the-definition-to-the-file-named-after-it
  (multiple-value-bind (g file component) (bnm-fixture)
    (declare (ignore file))
    (is (equal (id component) (getf (best-name-match g "LayerEditor") :id))
        "the 251-line component, not the file whose basename spells it")))

(test find-still-lists-the-file-first
  ;; The half that must not move. REQ-0016 R1's argument for demoting
  ;; containers was explicitly scoped away from `find', which answers "where is
  ;; this thing" -- and there an exactly-named file is the right answer, with
  ;; the definition on the next line of the same listing.
  (multiple-value-bind (g file) (bnm-fixture)
    (let ((hits (search-entities g :name "LayerEditor")))
      (is (equal (id file) (getf (first hits) :id)))
      (is (= 3 (length hits)) "and nothing is filtered out of the listing"))))

(test the-type-tier-breaks-a-tie-and-never-crosses-a-match-band
  ;; RESOLUTION-RANK multiplies the match rank out so the two cannot interleave.
  ;; A file that matches a name exactly must still beat a definition that only
  ;; prefix-matches it, or the fix would trade one wrong answer for another:
  ;; `describe LayerEditor' would answer about LayerEditorState.
  (multiple-value-bind (g file component longer) (bnm-fixture)
    (declare (ignore file))
    (is (< (loom-knowledge::resolution-rank component "LayerEditor")
           (loom-knowledge::resolution-rank longer "LayerEditor"))
        "exact beats prefix, which is MATCH-RANK's band and not the tier's")
    (is (equal (id component) (getf (best-name-match g "LayerEditor") :id)))))

(test a-file-still-wins-when-no-definition-shares-its-name
  ;; Nothing here filters. A file is the right answer whenever it is the only
  ;; one, which on both Lisp trees is nearly every file.
  (let ((f (make-k-fixture)))
    (is (equal (id (k-file f)) (getf (best-name-match (k-graph f) "overlay") :id))
        "no definition is named `overlay\', so the file is the answer")))

(test best-name-match-returns-nothing-rather-than-guessing
  (is (null (best-name-match (k-graph (make-k-fixture)) "leaflet"))))

(test a-call-site-ranks-below-a-real-definition-it-would-otherwise-outrank
  ;; PLAN-0014 step 10's fallback. "overlay" is a prefix of the call site's
  ;; label "overlay-cache@...", so MATCH-RANK alone puts it at 1 and above
  ;; RESET-OVERLAY's substring match at 2 -- which off the silent 20-hit cap is
  ;; how a real definition disappears from `find'. Ranked, not filtered: the
  ;; site is still in the answer, last.
  (let* ((f (make-k-fixture))
         (site (make-call-site-entity :file "src/workspace/overlay.lisp"
                                      :start-line 41 :end-line 53
                                      :call-name "overlay-cache"
                                      :referrer-kind :definer-call
                                      :language :lisp :system :workspace)))
    (add-entity (k-graph f) site)
    (let ((types (mapcar (lambda (s) (getf s :type))
                         (search-entities (k-graph f) :name "overlay"))))
      (is (= 1 (count :call-site types))
          "ranked below, never filtered out -- an invisible call site is the
thing this design exists to stop")
      (is (eq :call-site (car (last types)))
          "and below every real definition, not merely below the ones it ties
with"))))

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


;;; ------------------------------------------------------------------
;;; A name as English (DES-0040 D3, DES-0041 D4)
;;; ------------------------------------------------------------------

;;; Moved here from the loom-workspace suite by PLAN-0044 S1, with the
;;; assertions unchanged. Rewriting them would have thrown away the only thing
;;; that witnesses the move changed nothing -- and a changed NAME-AS-WORDS
;;; invalidates the digest of every vector store on the machine without
;;; signalling anything.

(test a-compound-name-is-split-into-words-before-embedding
  ;; DES-0040 D3. An embedder tokenizes English and GETTYPEFROMOBJ is not
  ;; English. This is the same split TASK-TOKENS makes on a query, for the same
  ;; reason, against a different consumer.
  (is (string= "get type from obj" (name-as-words "getTypeFromObj")))
  (is (string= "connection connect database" (name-as-words "connection-connect-database")))
  (is (string= "piece type editor state set value"
               (name-as-words "PieceTypeEditorState.setValue")))
  (is (string= "min scale meters" (name-as-words "*min-scale-meters*")))
  (is (string= "url" (name-as-words "URL"))
      "an all-capitals name is one word, not three letters"))


;;; ------------------------------------------------------------------
;;; A definition's parameter list (BUG-0044)
;;; ------------------------------------------------------------------

(defun sig-function (name arguments &key (language :lisp) (type 'function-entity))
  (make-instance type :name name
                 :origin-file "src/lib.lisp"
                 :properties (properties-table
                              (list :file "src/lib.lisp" :start-line 1 :end-line 9
                                    :language language :arguments arguments))))

(test a-signature-is-rendered-in-the-language-that-wrote-it
  ;; The one job :SIGNATURE was declared for, and the reason removing it did not
  ;; mean dropping the fact. A Lisp signature is a form and a JavaScript one is
  ;; a call; printing either in the other's shape misstates the source.
  (is (string= "(find-entities view &key entity-type)"
               (render-signature
                (sig-function "find-entities" '("view" "&key" "entity-type")))))
  (is (string= "Game.decodeGame(definitions, objects)"
               (render-signature
                (sig-function "Game.decodeGame" '("definitions" "objects")
                              :language :javascript)))))

(test a-function-taking-nothing-renders-its-name-and-a-class-renders-nothing
  ;; Different facts that read alike in the property table: an absent
  ;; :ARGUMENTS and an empty one are both NIL, so the entity type decides.
  ;; "()" would claim a class takes no arguments, which is a statement about
  ;; something a class does not have.
  (is (string= "(pidfile-path)" (render-signature (sig-function "pidfile-path" '()))))
  (is (null (render-signature
             (sig-function "protected-table" '() :type 'class-entity)))))

(test describe-carries-the-signature-and-the-arity-without-widening-a-summary
  ;; Type-specific detail belongs in DESCRIBE-ENTITY. ENTITY-SUMMARY is read in
  ;; bulk by `find' and `impact' and carries what is true of every entity, so a
  ;; signature there would widen every row of both.
  (let* ((f (make-k-fixture))
         (detail (describe-entity (k-graph f) (id (k-resolve f)))))
    (is (string= "(resolve-overlay)" (getf detail :signature)))
    (is (eql 0 (getf detail :arity)))
    (is (eq :absent (getf (entity-summary (k-resolve f)) :signature :absent))
        "the summary does not carry the key at all, so no `find' row widens")))

(test the-ontology-no-longer-declares-a-signature-property
  ;; BUG-0044's own claim, asserted rather than described. A property declared
  ;; and never written is indistinguishable from one whose value is absent, and
  ;; that is how this one survived: the analyzer's key fixture recorded
  ;; (:signature nil) on every source and passed.
  (let ((f (sig-function "anything" '("x"))))
    (is (null (getp f :signature))
        "nothing writes it, and nothing declares it either")))

