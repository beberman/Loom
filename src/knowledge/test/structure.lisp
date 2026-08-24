;;;
;;; Tests for src/knowledge/structure.lisp -- REQ-0021 R5's structural report.
;;;
;;; The fixture is built here rather than from K-FIXTURE because everything
;;; this report says is about *systems*, and the shared fixture places every
;;; entity in one file with no :SYSTEM property at all. What has to be
;;; exercised is the shape the report is for: two systems calling each other in
;;; both directions, a protocol with implementors, a definition nothing calls,
;;; and a repository whose source no analyzer claimed.
;;;

(in-package :loom-knowledge-test)

(def-suite structure
  :in all-tests
  :description "STRUCTURE-REPORT: what the index can say about a tree's shape.")

(in-suite structure)

(defun s-function (name system file &key (start 1))
  (make-instance 'function-entity :name name :origin-file file
                 :properties (properties-table
                              (list :file file :start-line start :end-line (+ start 8)
                                    :system system :language :lisp))))

(defun s-edge (graph type from to)
  (add-relationship graph (make-instance 'relationship :rel-type type
                                                       :from-id (id from)
                                                       :to-id (id to)
                                                       :origin-file (origin-file from))))

(defstruct (s-fixture (:conc-name s-) (:constructor %make-s-fixture))
  graph alpha beta protocol impl-one impl-two orphan)

(defun make-s-fixture ()
  "Two systems that call each other, a protocol with two implementors, and a
function nothing calls.

The mutual call is deliberate and is the assertion the report's honesty rests
on: :ALPHA calls :BETA and :BETA calls :ALPHA, and the report must show both
without calling either a violation. Which direction was intended is exactly the
intent REQ-0021 says no index holds."
  (let* ((g (make-graph))
         (alpha (s-function "alpha-entry"  :alpha "src/alpha/a.lisp" :start 10))
         (beta  (s-function "beta-helper"  :beta  "src/beta/b.lisp"  :start 20))
         (back  (s-function "beta-callback" :beta "src/beta/b.lisp"  :start 40))
         (protocol (make-instance 'interface-entity :name "render"
                                  :origin-file "src/alpha/a.lisp"
                                  :properties (properties-table
                                               '(:file "src/alpha/a.lisp"
                                                 :start-line 60 :end-line 62
                                                 :system :alpha :language :lisp))))
         (impl-one (s-function "render-svg"  :alpha "src/alpha/a.lisp" :start 70))
         (impl-two (s-function "render-png"  :beta  "src/beta/b.lisp"  :start 80))
         (orphan   (s-function "never-called" :alpha "src/alpha/a.lisp" :start 90))
         (test     (make-instance 'test-entity :name "alpha-entry-test"
                                  :origin-file "src/alpha/test/a.lisp"
                                  :properties (properties-table
                                               '(:file "src/alpha/test/a.lisp"
                                                 :start-line 1 :end-line 5
                                                 :system :alpha)))))
    (dolist (e (list alpha beta back protocol impl-one impl-two orphan test))
      (add-entity g e))
    (s-edge g :calls alpha beta)        ; alpha -> beta
    (s-edge g :calls back alpha)        ; beta  -> alpha, the other direction
    (s-edge g :implements impl-one protocol)
    (s-edge g :implements impl-two protocol)
    (s-edge g :calls alpha impl-one)
    (s-edge g :tests test alpha)
    (%make-s-fixture :graph g :alpha alpha :beta beta :protocol protocol
                     :impl-one impl-one :impl-two impl-two :orphan orphan)))

(defun row-named (rows name &optional (key :name))
  (find name rows :key (lambda (row) (getf row key)) :test #'equal))

;;; ------------------------------------------------------------------
;;; Systems
;;; ------------------------------------------------------------------

(test the-report-counts-definitions-and-tests-per-system
  (let* ((f (make-s-fixture))
         (report (structure-report (s-graph f)))
         (alpha (row-named (getf report :systems) :alpha)))
    (is (not (null alpha)) "systems: ~a" (getf report :systems))
    (is (= 1 (getf alpha :tests)) "the test entity is counted as a test")
    (is (= 4 (getf alpha :definitions))
        "four definitions in :alpha, and the test is not one of them: ~a" alpha)
    (is (= 1 (getf alpha :tested-units))
        "coverage is derived from :TESTS edges, not from a naming convention")))

(test both-directions-of-a-system-cycle-are-reported-and-neither-is-judged
  ;; The report's central restraint. :ALPHA calls :BETA and :BETA calls :ALPHA;
  ;; a report that named one of them a layering violation would be asserting an
  ;; intent no index holds, which is REQ-0021's line between what is derivable
  ;; and what is not.
  (let* ((f (make-s-fixture))
         (report (structure-report (s-graph f)))
         (edges (getf report :system-edges))
         (forward (find-if (lambda (row) (and (eq :alpha (getf row :from))
                                              (eq :beta (getf row :to))))
                           edges))
         (backward (find-if (lambda (row) (and (eq :beta (getf row :from))
                                               (eq :alpha (getf row :to))))
                            edges)))
    (is (not (null forward))  "alpha -> beta missing from ~a" edges)
    (is (not (null backward)) "beta -> alpha missing from ~a" edges)
    (let ((text (render-structure report)))
      (is (not (search "violation" text))
          "the report must not call a cycle a violation")
      (is (search "neither is judged" text)
          "and it says so, so a reader does not supply the judgement itself"))))

;;; ------------------------------------------------------------------
;;; Protocols, entry points, hubs
;;; ------------------------------------------------------------------

(test a-protocol-is-reported-with-its-implementors
  (let* ((f (make-s-fixture))
         (report (structure-report (s-graph f)))
         (protocol (row-named (getf report :protocols) "render")))
    (is (not (null protocol)) "protocols: ~a" (getf report :protocols))
    (is (= 2 (getf protocol :implementor-count)))
    (is (equal '("render-png" "render-svg")
               (mapcar (lambda (i) (getf i :name)) (getf protocol :implementors)))
        "sorted by name, so two runs over one index agree")))

(test a-definition-nothing-calls-is-an-entry-point
  (let* ((f (make-s-fixture))
         (report (structure-report (s-graph f)))
         (names (mapcar (lambda (row) (getf row :name)) (getf report :entry-points))))
    (is (member "never-called" names :test #'string=) "entry points: ~a" names)
    (is (not (member "beta-helper" names :test #'string=))
        "and something with a caller is not")))

(test the-entry-point-list-declares-what-it-cannot-see
  ;; DES-0001's blind spots land on this computation: a definition called only
  ;; from inside a macro body has no attributed edge and is indistinguishable
  ;; from one nothing calls. A list that presented those as entry points with
  ;; no qualifier would be CON-0001's fabricated fact in list form.
  (let* ((f (make-s-fixture))
         (g (s-graph f)))
    (is (null (getf (structure-report g) :entry-point-qualifier))
        "no unattributed sites, so nothing to qualify")
    (add-entity g (make-instance 'call-site-entity :name "somewhere@src/alpha/a.lisp:5"
                                 :origin-file "src/alpha/a.lisp"
                                 :properties (properties-table
                                              '(:file "src/alpha/a.lisp"
                                                :start-line 5
                                                :call-name "mystery"))))
    (let ((report (structure-report g)))
      (is (not (null (getf report :entry-point-qualifier)))
          "one unattributed call site, so the list has to say so")
      (is (search "DES-0001" (getf report :entry-point-qualifier))
          "and name where a reader can go to understand it"))))

(test hubs-are-ranked-by-inbound-edges-and-called-nothing-else
  (let* ((f (make-s-fixture))
         (report (structure-report (s-graph f)))
         (hubs (getf report :hubs)))
    (is (plusp (length hubs)))
    (is (every (lambda (row) (plusp (getf row :inbound))) hubs)
        "an entity nothing points at is not a hub")
    (is (apply #'>= (mapcar (lambda (row) (getf row :inbound)) hubs))
        "ranked descending: ~a" (mapcar (lambda (r) (getf r :inbound)) hubs))
    (let ((text (render-structure report)))
      (is (not (search "important" text))
          "a hub is a measurement; what it means is a judgement the report does not make"))))

;;; ------------------------------------------------------------------
;;; The case this report is most likely to be misread in
;;; ------------------------------------------------------------------

(test a-tree-whose-source-was-never-analyzed-says-so-rather-than-looking-clean
  ;; ~/github/front-end measured 2026-08-12: 27 entities, all documents, and no
  ;; relationships at all, because 455 .js files have no analyzer that claims
  ;; them. Empty lists there are indistinguishable from a simple, clean
  ;; architecture, and only one of those is a description.
  (let ((g (make-graph)))
    (add-entity g (make-instance 'document-entity :name "docs/readme.md"
                                 :origin-file "docs/readme.md"
                                 :properties (properties-table
                                              '(:path "docs/readme.md"
                                                :format :markdown))))
    (let ((report (structure-report g)))
      (is-false (getf report :indexed-p)
                "entities but no relationships is an unread tree, not a simple one")
      (is (search "nothing here is indexed" (render-structure report))
          "and the text says it before anything a reader could misread"))))

(test an-indexed-tree-is-not-flagged-as-unread
  ;; The complement, without which the test above passes against a report that
  ;; always says it.
  (let ((report (structure-report (s-graph (make-s-fixture)))))
    (is-true (getf report :indexed-p))
    (is (not (search "nothing here is indexed" (render-structure report))))))

(test the-commit-is-carried-through-and-its-absence-is-explained
  ;; REQ-0021 R5: the report names what it was derived from, or says why it
  ;; cannot. A generated architecture document read six months later is
  ;; checkable only against a named tree.
  (let ((g (s-graph (make-s-fixture))))
    (let ((text (render-structure (structure-report g :commit "abc1234"
                                                     :repository "fixture"))))
      (is (search "abc1234" text))
      (is (search "fixture" text)))
    (let ((text (render-structure (structure-report g :commit nil
                                                     :commit-reason "not a repository"))))
      (is (search "commit unknown: not a repository" text)
          "a known gap rather than a blank where a commit should be"))))

(test the-report-says-whether-the-index-had-caught-up-with-the-tree
  ;; REQ-0050 R3, and it is the requirement's own acceptance clause. The commit
  ;; field measures the tree and was read as measuring the index; the two
  ;; differ by every uncommitted edit and by however long since the last poll,
  ;; so the answer says which of the two it is.
  (let ((g (s-graph (make-s-fixture))))
    (is (search "STALE INDEX: 3 claimed files changed since it was read"
                (render-structure (structure-report g :commit "abc1234" :drift 3))))
    (is (search "index current with the tree"
                (render-structure (structure-report g :commit "abc1234" :drift 0)))
        "said on both outcomes: a report silent about freshness cannot be told
from one whose index is current")))

(test the-report-says-when-the-commit-is-not-the-whole-of-what-was-read
  ;; The other half of REQ-0050 R1. An index built from a working tree with
  ;; uncommitted edits is not the commit it names, and DRIFT will not say so --
  ;; drift is the index against the tree on disk, and both can agree while
  ;; neither is the commit.
  (let ((g (s-graph (make-s-fixture))))
    (is (search "+ uncommitted edits"
                (render-structure (structure-report g :commit "abc1234"
                                                     :dirty t :drift 0))))
    (is (not (search "+ uncommitted edits"
                     (render-structure (structure-report g :commit "abc1234"
                                                          :dirty nil :drift 0)))))))

(test the-branch-is-carried-because-it-is-the-half-a-reader-recognises
  (let ((g (s-graph (make-s-fixture))))
    (is (search "(req-0050-r1)"
                (render-structure (structure-report g :commit "abc1234"
                                                     :branch "req-0050-r1"))))))

;;; ------------------------------------------------------------------
;;; Prose attributed to the systems it describes
;;;
;;; The half a first version of this report left out. REQ-0021 says the
;;; markdown "says what the author believed, which is exactly the material the
;;; index cannot supply" -- and which document describes which system turns out
;;; to be derivable from the mention edges rather than needing an LLM.
;;; ------------------------------------------------------------------

(defun s-doc (name mentions)
  (make-instance 'document-entity :name name :origin-file name
                 :properties (properties-table
                              (list :path name :format :markdown :mentions mentions))))

(test prose-is-attributed-to-the-system-it-actually-names
  ;; Measured on ~/lisp/game-server before this existed: docs/data-layer.md
  ;; names eighteen entities in DATA-API and seven in MPACKAGE/NAMESPACE. That
  ;; is not a guess about what the document is about, and the generated
  ;; architecture document was throwing it away.
  (let* ((f (make-s-fixture))
         (g (s-graph f))
         (about-alpha (s-doc "docs/alpha-design.md" '("alpha-entry" "never-called")))
         (about-beta  (s-doc "docs/beta-notes.md" '("beta-helper"))))
    (dolist (d (list about-alpha about-beta)) (add-entity g d))
    (s-edge g :mentions about-alpha (s-alpha f))
    (s-edge g :mentions about-alpha (s-orphan f))
    (s-edge g :mentions about-beta (s-beta f))
    (let* ((report (structure-report g))
           (alpha (row-named (getf report :systems) :alpha))
           (beta  (row-named (getf report :systems) :beta)))
      (is (equal '("docs/alpha-design.md")
                 (mapcar (lambda (p) (getf p :document)) (getf alpha :described-by)))
          "the document naming two things in :alpha is attributed to it: ~a"
          (getf alpha :described-by))
      (is (= 2 (getf (first (getf alpha :described-by)) :names))
          "with the count that earned the attribution")
      (is (equal '("docs/beta-notes.md")
                 (mapcar (lambda (p) (getf p :document)) (getf beta :described-by)))))))

(test the-report-lists-the-prose-ranked-by-how-much-it-names
  (let* ((f (make-s-fixture))
         (g (s-graph f))
         (broad (s-doc "docs/broad.md" '("a" "b")))
         (narrow (s-doc "docs/narrow.md" '("c"))))
    (dolist (d (list broad narrow)) (add-entity g d))
    (s-edge g :mentions broad (s-alpha f))
    (s-edge g :mentions broad (s-beta f))
    (s-edge g :mentions narrow (s-beta f))
    (let ((prose (getf (structure-report g) :prose)))
      (is (equal '("docs/broad.md" "docs/narrow.md")
                 (mapcar (lambda (row) (getf row :document)) prose))
          "the document naming more of the codebase is read first: ~a"
          (mapcar (lambda (row) (getf row :document)) prose)))))

(test the-prose-section-points-and-does-not-paraphrase
  ;; The line this must not cross. Summarising a document into generated prose
  ;; is the plausible unfalsifiable text R6 exists to stop; naming it with the
  ;; count that earned the pointer is a measurement.
  (let* ((f (make-s-fixture))
         (g (s-graph f))
         (doc (s-doc "docs/alpha-design.md" '("alpha-entry"))))
    (add-entity g doc)
    (s-edge g :mentions doc (s-alpha f))
    (let ((text (render-structure (structure-report g))))
      (is (search "docs/alpha-design.md" text) "the document is named")
      (is (search "described by" text) "and attached to its system")
      (is (search "no index can supply" text)
          "and the section says why a reader should go and read it"))))
