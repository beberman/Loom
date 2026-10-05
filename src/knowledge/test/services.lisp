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
;;; definition-summary -- REQ-0049's middle tier, and BUG-0046's cut
;;;
;;; Built locally for the reason the DOCUMENT-SUMMARY tests are: the function
;;; takes an entity rather than a view, and the shared fixture asserts exact
;;; hit counts three tests above.
;;; ------------------------------------------------------------------

(defun k-documented (documentation)
  "A function entity carrying DOCUMENTATION and nothing else of interest."
  (make-instance 'function-entity :name "vector-store-directory"
                 :origin-file "src/embed/store.lisp"
                 :properties (properties-table
                              (list :file "src/embed/store.lisp"
                                    :start-line 32 :end-line 45
                                    :documentation documentation))))

(test definition-summary-takes-the-first-sentence
  (is (string= "A 64-bit FNV-1a hash of TEXT, as sixteen hex digits."
               (definition-summary
                (k-documented "A 64-bit FNV-1a hash of TEXT, as sixteen hex digits.
Deterministic across images, which SXHASH is not.")))))

(test definition-summary-does-not-cut-inside-a-path
  ;; BUG-0046, from the tree: `context refactor Loom to use utils where needed'
  ;; printed `<loom>/.' for this docstring, which is a line that costs tokens
  ;; and carries no claim. The period inside `.loom' ends no sentence.
  (let ((summary (definition-summary
                  (k-documented "<loom>/.loom/vectors/, beside the context log and for the same two reasons.
In Loom's own tree rather than the searched one."))))
    (is (string= "<loom>/.loom/vectors/, beside the context log and for the same two reasons."
                 summary))))

(test definition-summary-does-not-cut-at-a-dotted-pair
  ;; The other half of the rule. A period with whitespace on both sides passes
  ;; the following-character test and ends no sentence -- it is Lisp's dotted
  ;; pair, and this tree writes it in prose.
  (is (string= "Alist of (from . to) pairs, one per edge."
               (definition-summary
                (k-documented "Alist of (from . to) pairs, one per edge.
The order is the walk's.")))))

(test definition-summary-keeps-a-short-sentence-whole
  ;; No floor on length: a rule that reached past this for something longer
  ;; would return the second sentence as the first.
  (is (string= "Mirrors REMHASH."
               (definition-summary
                (k-documented "Mirrors REMHASH.
The lock is the table's own.")))))

(test definition-summary-falls-back-to-the-whole-text-with-no-sentence-break
  (is (string= "help [command]"
               (definition-summary (k-documented "help [command]")))))

(test definition-summary-says-nothing-when-there-is-nothing
  ;; REQ-0049 R4, CON-0001: 3861 of 5268 definitions across the indexed trees
  ;; carry no docstring, so absence is the common case and a placeholder here
  ;; would be a claim about every one of them.
  (is (null (definition-summary (k-function "resolve-overlay" 41))))
  (is (null (definition-summary (k-documented "")))))

(test definition-summary-is-bounded
  (let ((summary (definition-summary (k-documented (k-long-text)))))
    (is (<= (estimate-tokens summary) *definition-summary-budget*))))

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



;;; ------------------------------------------------------------------
;;; An inferred edge says so (BUG-0055)
;;; ------------------------------------------------------------------
;;;
;;; The data was always there. RESOLVE-CALLS asserts a fanned-out call edge
;;; with :SOURCE :INFERRED and a 1/N :CONFIDENCE, and every answer surface
;;; dropped both -- so front-end's `describe ingestModel' printed three guesses
;;; from one `.get()' on a plain Map beside the one real callee, all four
;;; reading `structural, 1.0' because that is the *entity's* provenance.

(defun k-inferred-edge (graph from to &key (confidence 1/3))
  "A :CALLS edge a resolution pass guessed at, as RESOLVE-CALLS asserts one."
  (add-relationship graph (make-instance 'relationship
                                         :rel-type :calls
                                         :from-id (id from) :to-id (id to)
                                         :origin-file (origin-file from)
                                         :source :inferred
                                         :confidence (float confidence 1.0))))

(test a-neighbour-row-carries-the-edges-provenance-and-not-only-the-entitys
  ;; The two are different questions and the row has to answer both. RESET is a
  ;; perfectly certain definition -- :STRUCTURAL, confidence 1.0 -- reached
  ;; here across an edge the resolver guessed at, and before this the row said
  ;; only the first half.
  (let* ((f (make-k-fixture)))
    (k-inferred-edge (k-graph f) (k-resolve f) (k-reset f))
    (let* ((detail (describe-entity (k-graph f) (id (k-resolve f))))
           (out (find-if (lambda (g) (and (eq :out (getf g :direction))
                                          (eq :calls (getf g :rel-type))))
                         (getf detail :neighbors)))
           (row (first (getf out :entities))))
      (is (string= "reset-overlay" (getf row :name)))
      (is (eq :structural (getf row :source))
          "the definition is a fact the analyzer read")
      (is (= 1.0 (getf row :confidence)))
      (is (eq :inferred (getf row :edge-source))
          "and the edge reaching it is a guess, which is the half that was missing")
      (is (< (abs (- 1/3 (getf row :edge-confidence))) 0.001)))))

(test a-resolved-edge-says-that-too-rather-than-saying-nothing
  ;; The key is on every row, not only the uncertain ones. A field that appears
  ;; only when something is wrong makes its absence carry meaning, and a reader
  ;; cannot tell "this edge is certain" from "this build predates the marker".
  (let* ((f (make-k-fixture))
         (detail (describe-entity (k-graph f) (id (k-resolve f))))
         (in (find-if (lambda (g) (and (eq :in (getf g :direction))
                                       (eq :calls (getf g :rel-type))))
                      (getf detail :neighbors)))
         (row (first (getf in :entities))))
    (is (string= "compose-view" (getf row :name)))
    (is (eq :structural (getf row :edge-source :absent)))
    (is (= 1.0 (getf row :edge-confidence -1)))))

(test an-impact-row-reached-through-a-guess-says-so
  ;; The control first, in the same test, because CON-0003's requirement is
  ;; that the assertion fail without the change and a boolean that is NIL for
  ;; every row would pass either way. The fixture's own edges are all
  ;; structural, so no row of the untouched report may be marked.
  (let* ((clean (make-k-fixture))
         (before (impact-report (k-graph clean) (id (k-resolve clean)))))
    (is-true (getf before :impacted) "compose-view is impacted by resolve-overlay")
    (is (notany (lambda (row) (getf row :inferred)) (getf before :impacted))
        "nothing in a wholly structural walk is marked")
    (is (every (lambda (row) (= 1.0 (getf row :confidence-of-path)))
               (getf before :impacted))))
  ;; RESOLVE-OVERLAY --calls?--> RESET-OVERLAY, the shape RESOLVE-CALLS asserts
  ;; for a member call whose receiver names no class. Impact runs against a
  ;; call edge, so a change to RESET now reaches RESOLVE across the guess, and
  ;; COMPOSE-VIEW behind it.
  (let* ((f (make-k-fixture)))
    (k-inferred-edge (k-graph f) (k-resolve f) (k-reset f))
    (let* ((report (impact-report (k-graph f) (id (k-reset f))))
           (row (find "resolve-overlay" (getf report :impacted)
                      :key (lambda (r) (getf r :name)) :test #'equal)))
      (is-true row "resolve-overlay calls reset-overlay, however uncertainly")
      (when row
        (is-true (getf row :inferred))
        (is (< (abs (- 1/3 (getf row :confidence-of-path))) 0.001))
        (is (search "?>" (getf row :via))
            "the path marks which hop was the guess: ~a" (getf row :via))))))

(test a-guess-early-in-a-path-marks-everything-behind-it
  ;; The transitive half. COMPOSE-VIEW is two hops from RESET-OVERLAY and the
  ;; second hop is structural, so a per-hop marker alone would leave this row
  ;; looking certain -- and it is in the set only because of the guess.
  (let* ((f (make-k-fixture)))
    (k-inferred-edge (k-graph f) (k-resolve f) (k-reset f))
    (let* ((report (impact-report (k-graph f) (id (k-reset f))))
           (row (find "compose-view" (getf report :impacted)
                      :key (lambda (r) (getf r :name)) :test #'equal)))
      (is-true row)
      (when row
        (is (= 2 (getf row :depth)))
        (is-true (getf row :inferred))
        (is (< (abs (- 1/3 (getf row :confidence-of-path))) 0.001)
            "the weakest hop, carried the whole way")))))

(test the-paths-confidence-is-its-weakest-hop-and-not-the-product
  ;; A product decays with length: four certain hops and one 0.33 would report
  ;; less confidence at depth 5 than the same guess reports at depth 1, which
  ;; is an artefact of depth rather than a fact about the claim.
  (let ((path (list (loom-graph::make-hop :rel-type :calls :entity-id "a")
                    (loom-graph::make-hop :rel-type :calls :entity-id "b"
                              :edge-source :inferred :edge-confidence 0.5)
                    (loom-graph::make-hop :rel-type :calls :entity-id "c"
                              :edge-source :inferred :edge-confidence 0.25))))
    (is (= 0.25 (loom-knowledge::path-confidence path)))
    (is-true (loom-knowledge::path-inferred-p path))
    (is (= 1.0 (loom-knowledge::path-confidence '()))
        "a seed's own empty path is certain, not zero")
    (is (not (loom-knowledge::path-inferred-p
              (list (loom-graph::make-hop :rel-type :calls :entity-id "a")))))))


;;; ------------------------------------------------------------------
;;; An impact answer says what depth it was asked for (BUG-0050 F2)
;;; ------------------------------------------------------------------

(test an-impact-report-carries-the-depth-it-was-asked-for
  ;; Without it a reader compares a row's depth against the number they typed
  ;; and has no way to learn that the one-step band lies outside it. On
  ;; game-server, `impact data-handler 5' returns 7 rows at d6 of 822 -- the
  ;; true path length, and indistinguishable from a defect.
  (let* ((f (make-k-fixture))
         (report (impact-report (k-graph f) (id (k-resolve f)) :max-depth 3)))
    (is (= 3 (getf report :depth)))
    (is (<= (reduce #'max (getf report :impacted)
                    :key (lambda (e) (getf e :depth)) :initial-value 0)
            4)
        "a one-step edge may land one past the cap and no further"))
  (let* ((f (make-k-fixture))
         (report (impact-report (k-graph f) (id (k-resolve f)))))
    (is (= *default-impact-depth* (getf report :depth))
        "and the default is reported rather than left for the caller to assume")))

(test an-impact-row-carries-the-location-that-separates-two-of-one-name
  ;; The console prints what this row carries. On game-server 45 names occupy
  ;; more than one row of `impact data-handler 5' and `dhandler-copy' occupies
  ;; eight -- eight real methods in four files, distinguishable only here.
  (let* ((f (make-k-fixture))
         (report (impact-report (k-graph f) (id (k-resolve f))))
         (row (first (getf report :impacted))))
    (is-true row)
    (is-true (getf row :location) "every impact row locates its definition")
    (is (search ":" (getf row :location))
        "file and line range, as `find' and `describe' print it: ~a"
        (getf row :location))))

;;; ------------------------------------------------------------------
;;; A domain filter runs before the cap (PLAN-0050 S12, DES-0047 D4)
;;; ------------------------------------------------------------------

(defun domain-fixture (&key (in-other 20) (in-mine 10))
  "A graph where IN-OTHER better-named entities sit in one domain and IN-MINE
sit in another.

Better-named on purpose: every name in the other domain is an exact match for
the search term and every name in this one is a longer compound, so match
quality alone would return the other domain's entities first and fill the cap
with them."
  (let ((g (make-graph)))
    (dotimes (i in-other)
      (add-entity g (make-instance 'function-entity
                                   :name "render"
                                   :origin-file (format nil "src/play/p~d.js" i)
                                   :properties (properties-table
                                                (list :file (format nil "src/play/p~d.js" i)
                                                      :start-line 1 :end-line 2
                                                      :language :javascript
                                                      :domain :play)))))
    (dotimes (i in-mine)
      (add-entity g (make-instance 'function-entity
                                   :name (format nil "renderPanel~d" i)
                                   :origin-file (format nil "src/edit/e~d.js" i)
                                   :properties (properties-table
                                                (list :file (format nil "src/edit/e~d.js" i)
                                                      :start-line 1 :end-line 2
                                                      :language :javascript
                                                      :domain :edit)))))
    g))

(test a-domain-filter-is-applied-before-the-cap-and-not-after
  ;; DES-0047 D4. Twenty better-ranked hits sit in another domain. A filter
  ;; applied to the result of a capped search would see only those twenty, cut
  ;; them all, and answer nothing -- so the caller who named a domain would be
  ;; told the domain is empty when it holds ten.
  (let* ((g (domain-fixture))
         (asked 10))
    (multiple-value-bind (hits total)
        (search-entities g :name "render" :limit asked
                           :property-filters '(:domain :edit))
      (is (= 10 total) "the ten in this domain are the whole population, not 30")
      (is (= 10 (length hits)) "and all ten come back")
      ;; By name, because a summary carries no :DOMAIN. Every entity in the
      ;; edit domain is named renderPanelN and every one in play is named
      ;; render, so the names say which domain answered. Whether a summary
      ;; should carry the domain is a real question and not this step's.
      (is (every (lambda (h) (eql 0 (search "renderPanel" (getf h :name)))) hits)
          "every hit is one of the domain's own: ~a"
          (mapcar (lambda (h) (getf h :name)) hits)))))

(test a-domain-filter-narrows-rather-than-reorders
  ;; Without the filter the same query answers about both domains, which is
  ;; what makes the assertion above about the filter and not about the fixture.
  (multiple-value-bind (hits total)
      (search-entities (domain-fixture) :name "render" :limit 10)
    (is (= 30 total) "both domains, thirty matches")
    (is (= 10 (length hits)) "capped at ten")))

(test a-domain-filter-reaches-the-entity-describe-would-choose
  ;; BEST-NAME-MATCH is what `describe' and `impact' resolve through on both
  ;; surfaces, so a domain address has to narrow it too or those two commands
  ;; answer about the whole repository while `find' answers about the domain.
  (let ((g (domain-fixture)))
    (let ((mine (best-name-match g "render" :property-filters '(:domain :edit)))
          (any  (best-name-match g "render")))
      (is-true mine "a match exists inside the domain")
      (is (eql 0 (search "renderPanel" (getf mine :name)))
          "the filtered answer is one of the domain's own: ~a" (getf mine :name))
      (is (string= "render" (getf any :name))
          "and without the filter the better-named other domain wins: ~a"
          (getf any :name)))))

;;; ------------------------------------------------------------------
;;; The two families (PLAN-0054 S2, DES-0049 D1)
;;; ------------------------------------------------------------------

(test the-two-families-partition-every-declared-type
  ;; What makes a complement safe rather than a second list to keep current.
  ;; Asserted as a partition -- every type in exactly one -- rather than as
  ;; disjointness, because disjointness alone would pass with :WORKSPACE,
  ;; :COMMIT and four others silently filed as code and nobody the wiser.
  (let ((code (kind-types :code))
        (documents (kind-types :documentation))
        (all (loom-ontology:all-entity-types)))
    (dolist (type all)
      (let ((in-code (and (member type code) t))
            (in-documents (and (member type documents) t)))
        (is (not (eq in-code in-documents))
            "~a is in ~a" type
            (cond ((and in-code in-documents) "both families")
                  (t "neither family")))))
    (is (= (length all) (+ (length code) (length documents)))
        "the two families together are every declared type")))

(test the-document-family-is-what-the-document-analyzers-mint
  (is (equal (sort (copy-list loom-graph:*document-types*) #'string<)
             (sort (copy-list (kind-types :documentation)) #'string<))
      "the family is *DOCUMENT-TYPES* itself, not a copy that can drift"))

(test no-kind-is-no-narrowing
  (is (null (kind-types nil))))

(defun family-fixture ()
  "A graph holding a function and a document, both named `repository'."
  (let ((g (make-graph)))
    (add-entity g (make-instance 'function-entity :name "repository"
                                 :origin-file "src/workspace.lisp"
                                 :properties (properties-table
                                              '(:file "src/workspace.lisp"
                                                :start-line 1 :end-line 2))))
    (add-entity g (make-instance 'document-entity :name "repository"
                                 :origin-file "docs/arch/ARCH-0001.yaml"
                                 :properties (properties-table
                                              '(:path "docs/arch/ARCH-0001.yaml"
                                                :doc-id "ARCH-0001"))))
    g))

(test a-family-narrows-find-to-one-of-two-same-named-entities
  (let ((g (family-fixture)))
    (multiple-value-bind (hits total) (search-entities g :name "repository")
      (declare (ignorable hits))
      (is (= 2 total) "both without a family"))
    (multiple-value-bind (hits total) (search-entities g :name "repository" :kind :code)
      (is (= 1 total))
      (is (eq :function (getf (first hits) :type))))
    (multiple-value-bind (hits total)
        (search-entities g :name "repository" :kind :documentation)
      (is (= 1 total))
      (is (eq :document (getf (first hits) :type))))))

(test the-truncation-count-is-computed-over-the-filtered-population
  ;; R2, and it asserts the count rather than the rows: a filter applied after
  ;; the cap would return the right row here and the wrong number beside it,
  ;; which is the answer that tells a caller to narrow a term already as narrow
  ;; as it goes.
  (let ((g (make-graph)))
    (dotimes (i 20)
      (add-entity g (make-instance 'function-entity :name (format nil "repo~d" i)
                                   :origin-file "src/f.lisp"
                                   :properties (properties-table
                                                (list :file "src/f.lisp"
                                                      :start-line i :end-line i)))))
    (dotimes (i 5)
      (add-entity g (make-instance 'document-entity :name (format nil "repo-doc~d" i)
                                   :origin-file (format nil "docs/d~d.yaml" i)
                                   :properties (properties-table
                                                (list :path (format nil "docs/d~d.yaml" i)
                                                      :doc-id (format nil "DOC-~d" i))))))
    (multiple-value-bind (hits total) (search-entities g :name "repo" :limit 3)
      (is (= 3 (length hits)))
      (is (= 25 total) "unfiltered, the population is everything named repo"))
    (multiple-value-bind (hits total)
        (search-entities g :name "repo" :limit 3 :kind :documentation)
      (is (= 3 (length hits)))
      (is (= 5 total) "filtered, it is the five documents and not twenty-five"))))

(test a-type-and-a-family-that-contradict-are-refused
  (let ((g (family-fixture)))
    (handler-case
        (progn (search-entities g :name "repository" :type :class :kind :documentation)
               (is-true nil "a code type and a document family were both accepted"))
      (loom-utils:refusal (condition)
        (is-true (search "class" (loom-utils:refusal-message condition)))
        (is-true (search "documentation" (loom-utils:refusal-message condition)))))
    (multiple-value-bind (hits total)
        (search-entities g :name "repository" :type :function :kind :code)
      (declare (ignorable hits))
      (is (= 1 total) "a type inside the family is not refused"))))

;;; ------------------------------------------------------------------
;;; A :SETTING is found and described like any entity (DES-0053 D10)
;;; ------------------------------------------------------------------

(test find-and-describe-answer-for-a-setting
  ;; Nothing in the knowledge layer names :SETTING, and a type missing from a
  ;; list it walks is reported by nothing (PLAN-0056, BLAST RADIUS). This is the
  ;; check that `find SPREADSHEET_ID' and `describe' reach the node.
  (let* ((g (make-graph))
         (reader (make-instance 'variable-entity :name "SPREADSHEET_ID"
                                :origin-file "functions/config.py"
                                :properties (properties-table
                                             '(:file "functions/config.py"
                                               :start-line 3 :end-line 3
                                               :language :python
                                               :environment-reads ("SPREADSHEET_ID")))))
         (setting (make-instance 'setting-entity :name "SPREADSHEET_ID"
                                 :properties (properties-table
                                              '(:name "SPREADSHEET_ID"
                                                :sources (:environment))))))
    (add-entity g reader)
    (add-entity g setting)
    (apply-transaction g (list (assert-edge :reads reader setting)))
    (let ((hits (search-entities g :name "SPREADSHEET_ID" :type :setting)))
      (is (= 1 (length hits)))
      (is (eq :setting (getf (first hits) :type))))
    (let* ((detail (describe-entity g (id setting)))
           (group (find-if (lambda (n) (and (eq :in (getf n :direction))
                                            (eq :reads (getf n :rel-type))))
                           (getf detail :neighbors))))
      (is (not (null group)) "the reader is listed as a neighbour")
      (is (equal '("SPREADSHEET_ID")
                 (mapcar (lambda (e) (getf e :name)) (getf group :entities)))))))
