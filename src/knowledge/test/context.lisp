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
;;; Seeding on a prose task -- REQ-0016 R7 and R8.
;;;
;;; The defect these cover was measured on game-server: "start-server startup
;;; sequence and database handler health check" seeded seven of eight entities
;;; on the English word "check", none of which had anything to do with
;;; startup, databases or health. The bundle then truncated at 1979 of 2000
;;; tokens, so the noise cost the neighbour band that carried the answer.
;;; ------------------------------------------------------------------

(defun seed-graph (&rest names)
  "A graph of one function per name in NAMES, all in one file.
Deliberately flat -- these tests are about which names the seeder reaches for
and in what order, and an edge would only add a neighbourhood nobody reads."
  (let ((g (make-graph)))
    (loop for name in names
          for line from 10 by 20
          do (add-entity g (k-function name line)))
    g))

(defun seed-names (graph task &key (limit 8))
  (mapcar #'name (loom-knowledge::seed-entities graph task :limit limit)))

(test every-recorded-seed-carries-the-terms-it-was-admitted-on
  ;; BUG-0037, and the same destructive-sort defect THE-COUNTS-AGREE-WITH-THE-
  ;; LIST-THEY-COUNT guards in prose.lisp. STABLE-SORT rearranges the conses it
  ;; is given, so a variable read again after the sort names the sorted list
  ;; from its old head onwards -- and the ASSOC building this second value then
  ;; found nothing for any seed that sorted ahead of that head. Those rows were
  ;; recorded with `terms' NIL and a score of 100813, which is SEED-SCORE of no
  ;; matches at all.
  ;;
  ;; The fixture puts the loss on the seed that answers the task. SEED-MATCHES
  ;; walks the tokens in order, so "check" makes CHECK-SLOT the head of the
  ;; alist; DATABASE-HANDLER-HEALTH covers three terms to CHECK-SLOT's one and
  ;; sorts first. Without COPY-LIST, MATCHES names the four-element suffix from
  ;; CHECK-SLOT on, and the rank-1 seed is the one recorded with nothing.
  (multiple-value-bind (seeds detail)
      (loom-knowledge::seed-entities
       (seed-graph "check-slot" "check-obj" "database-handler-health"
                   "database-alert" "connection-connect-database")
       "check the database handler health")
    (is (= (length seeds) (length detail))
        "one recorded row per admitted seed")
    ;; The sentinel is computed rather than written down. It was the literal
    ;; 100813 until DES-0036 multiplied SEED-SCORE's bands by ten, at which
    ;; point a test asserting a number from the old scale failed for a reason
    ;; that had nothing to do with what it covers. SEED-SCORE of no matches is
    ;; the thing being guarded against, so ask for it.
    (let ((matched-nothing
            (loom-knowledge::seed-score (first seeds) '()
                                        :demote-tests t
                                        :terms '()
                                        :production (make-hash-table :test #'equalp))))
      (dolist (row detail)
        (is (getf row :terms)
            (format nil "~a was recorded with no terms" (getf row :name)))
        (is (< (getf row :score) matched-nothing)
            (format nil "~a scored ~a, as if it had matched nothing"
                    (getf row :name) (getf row :score)))))))

(test a-noun-ending-in-ing-is-not-stemmed-as-a-verb
  ;; BUG-0040, DES-0033 D4, CON-0007. The four hand-written suffix rules that
  ;; stood in STEM-VARIANTS fired the -ing rule on any word of six characters
  ;; or more. "string" is exactly six, so it emitted "str" and "stre" -- and
  ;; "stre" prefix-matched STRESS-PUSHER and STRESS-WRITER at rank 1, taking
  ;; two of eight seed slots on a query about string prefixes.
  ;;
  ;; The assertions are a pair on purpose. Dropping the rule would pass the
  ;; first and fail the second: "saving" -> "save" is what reaches SAVEDESIGN
  ;; on front-end, is acceptance case fe-10, and is the one measured gain the
  ;; hand-written rules were ever kept for.
  (let ((tokens (loom-knowledge::task-tokens "trim whitespace from a string")))
    (is (not (member "str" tokens :test #'string=))
        "\"string\" is not the -ing form of \"str\"")
    (is (not (member "stre" tokens :test #'string=))
        "and \"stre\" is not a word anybody typed")
    (is (member "string" tokens :test #'string=)
        "the word the caller wrote survives"))
  (let ((tokens (loom-knowledge::task-tokens "saving a piece design")))
    (is (member "save" tokens :test #'string=)
        "a real inflection still stems, which is what reaches SAVEDESIGN")
    (is (member "saving" tokens :test #'string=)
        "added beside the word rather than replacing it")))

(test the-reported-terms-are-the-caller-s-words-the-seeder-searched-on
  ;; DES-0032, PLAN-0038 S1. Neither list alone is the right one to report.
  ;; TASK-TERMS keeps stopwords; TASK-TOKENS holds the fragments Loom split
  ;; compounds into. The intersection is what the caller wrote and the seeder
  ;; looked for, and it is what keeps one absent word from being reported as
  ;; three.
  (let ((reported (loom-knowledge::reported-terms
                   "reading a file with an encoding fallback when it is not UTF-8")))
    (is (member "utf-8" reported :test #'string=)
        "the caller wrote utf-8 and the seeder searched it")
    (is (not (member "utf" reported :test #'string=))
        "utf is Loom's fragment of the caller's word, not a word of the task")
    (is (not (member "encod" reported :test #'string=)))
    (dolist (stopword '("a" "with" "when" "it" "is" "not"))
      (is (not (member stopword reported :test #'string=))
          (format nil "~a is a stopword and would report as an absence" stopword)))))

(test a-term-nothing-matched-still-gets-a-row
  ;; The row the whole report exists for. A table built by walking the matches
  ;; holds a row per term that matched something, which is every term except
  ;; the one worth naming.
  (let* ((a (k-function "parse-document" 10))
         (matches (list (cons a (list (cons "parse" 1)))))
         (coverage (loom-knowledge::term-coverage matches '("parse" "number"))))
    (is (= 2 (length coverage)) "one row per reported term, matched or not")
    (let ((row (assoc "number" coverage :test #'string=)))
      (is (not (null row)) "the unmatched term has a row")
      (is (null (getf (cdr row) :name)))
      (is (null (getf (cdr row) :prose))))))

(test a-term-is-answered-only-when-an-admitted-seed-carries-it-in-its-name
  ;; DES-0032 D2's three states, and the two boundaries that matter. A term
  ;; matched only in prose is WEAK, not ANSWERED -- that is the join case,
  ;; where two candidates use the word in a docstring and no name has it. A
  ;; term whose name matches were all held back by the cap is WEAK too: the
  ;; caller cannot see an answer, and calling it answered would describe the
  ;; ranking rather than the bundle.
  (let* ((named    (k-function "parse-document" 10))
         (prosed   (k-function "comment-extent" 30))
         (unchosen (k-function "parse-verdicts" 50))
         (matches (list (cons named    (list (cons "parse" 1)))
                        (cons prosed   (list (cons "number" :prose)))
                        (cons unchosen (list (cons "verdict" 1)))))
         (coverage (loom-knowledge::term-coverage
                    matches '("parse" "number" "verdict" "separator")))
         (states (loom-knowledge::classify-terms coverage (list named prosed))))
    (is (eq :answered  (cdr (assoc "parse" states :test #'string=)))
        "an admitted seed has parse in its name")
    (is (eq :weak      (cdr (assoc "number" states :test #'string=)))
        "matched in prose only, by an admitted seed -- still not a name")
    (is (eq :weak      (cdr (assoc "verdict" states :test #'string=)))
        "a name match on a candidate no slot went to is not an answer")
    (is (eq :unmatched (cdr (assoc "separator" states :test #'string=)))
        "nothing in the index matched it at all")))

(test a-name-answering-more-of-the-task-outranks-one-answering-a-common-word
  ;; Match quality alone cannot tell these apart: every candidate here matches
  ;; some token as a prefix, so before REQ-0016 R7 they all scored identically
  ;; and the tie fell to token order -- which put the last word of the task
  ;; first.
  (let ((names (seed-names (seed-graph "database-handler-health"
                                       "check-ok-response" "check-unknown-response"
                                       "check-alist" "check-slot" "check-obj"
                                       "check-not-found-response")
                           "database handler health check"
                           :limit 2)))
    (is (string= "database-handler-health" (first names))
        "three of the task's terms beats one of them, whatever the match rank")))

(test no-single-common-term-may-fill-the-seed-set
  ;; R7 proper. The six CHECK-* names are the population the word "check"
  ;; drags in; DATABASE-ALERT and CONNECTION-CONNECT-DATABASE are what the
  ;; task was actually about and were crowded out entirely.
  (let* ((names (seed-names (seed-graph "start-server" "database-alert"
                                        "connection-connect-database"
                                        "check-ok-response" "check-unknown-response"
                                        "check-alist" "check-slot" "check-obj"
                                        "check-not-found-response")
                            "start-server startup sequence and database handler health check"
                            :limit 4))
         (from-check (count-if (lambda (n) (eql 0 (search "check-" n))) names)))
    (is (string= "start-server" (first names))
        "the name the task opens with is still the first seed")
    (is (<= from-check loom-knowledge::*seed-term-share*)
        "one English word must not take the bundle")
    (is (member "database-alert" names :test #'string=)
        "and what it was crowding out has to arrive")))

(defun same-name-graph (name count &rest others)
  "COUNT definitions of NAME, one per file, plus one definition of each of OTHERS.

One file each because the graph keys an entity by its natural key, and a name
asserted twice against one file is one entity -- which is the wrong fixture
entirely for a bound that counts entities per name."
  (let ((g (make-graph)))
    (dotimes (i count)
      (add-entity g (k-def 'function-entity name (format nil "src/one/f~d.lisp" i))))
    (loop for other in others
          for i from 0
          do (add-entity g (k-def 'function-entity other
                                  (format nil "src/other/g~d.lisp" i))))
    g))

(test one-name-may-not-take-every-seed-slot
  ;; BUG-0041. Eight definitions of DELETE-OBJ answer the same two terms, so
  ;; they are one name and one charge against their slice -- and until DES-0037
  ;; nothing counted the eight. Measured on game-server, `mp deleting obj'
  ;; returned eight methods named DELETE-OBJ and nothing else; 9 of the 450
  ;; known-item cases returned a single name eight times.
  ;;
  ;; Five other candidates and not fewer, spread over three slices, because
  ;; that is what fills the five slots the bound frees: the slice cap lets
  ;; {delete, obj} contribute two names, {delete} two and {obj} two. With fewer
  ;; the relaxation hands slots back to DELETE-OBJ and the count measures the
  ;; fixture rather than the bound.
  (let* ((names (seed-names (same-name-graph "delete-obj" 8
                                             "delete-obj-cascade"
                                             "delete-game" "delete-media"
                                             "obj-encode" "obj-decode")
                            "delete obj"))
         (copies (count "delete-obj" names :test #'string-equal)))
    (is (= 8 (length names))
        "the bound holds candidates back, it does not shorten the bundle")
    (is (= copies loom-knowledge::*seed-name-share*)
        "some definitions of a name are evidence; eight of them are a listing")
    (is (member "delete-obj-cascade" names :test #'string-equal)
        "and the slots the bound freed carry something else the task matched")))

(test three-definitions-of-one-name-are-all-seeds
  ;; REQ-0016 R8, in a unit test rather than only over the network. The clause
  ;; is an acceptance case whose finding is the triplication itself -- `data-api
  ;; handler database connection acquire and test connectivity' must return all
  ;; three CONNECTION-CONNECT-DATABASE definitions -- and it is the reason the
  ;; slice cap counts names rather than entities. It is also what pins
  ;; *SEED-NAME-SHARE* at three: a bound of two fails this.
  ;;
  ;; tools/acceptance.py cannot see it. It scores a set of names, so one
  ;; definition and three read alike there.
  (let ((names (seed-names (same-name-graph "connection-connect-database" 3
                                            "check-database" "database-alert"
                                            "db-handler" "table-handler"
                                            "connection-pool" "connection-close")
                           "data-api handler database connection acquire and test connectivity")))
    (is (= 3 (count "connection-connect-database" names :test #'string-equal))
        "three files defining one name is the finding the query exists to produce")))

(test a-name-with-nothing-to-crowd-out-still-fills-the-set
  ;; The relaxation, which the bound must not take away. ADMIT-SEEDS holds a
  ;; candidate back rather than refusing it, and returns the held ones in score
  ;; order when nothing else is waiting -- so a tree that offers eight
  ;; definitions of one name and nothing else seeds on all eight, exactly as it
  ;; did before either count existed.
  ;;
  ;; Not a test of the bound: it passes without DES-0037. It is what a bound
  ;; written as a refusal rather than as a charge would break, and 5 of the 449
  ;; measured bundles reach their eighth seed this way.
  (let ((names (seed-names (same-name-graph "to-alist" 8) "to-alist")))
    (is (= 8 (length names))
        "a full set, from the only candidates there are")
    (is (every (lambda (n) (string-equal "to-alist" n)) names)
        "all of them, because there is nothing the bound could admit instead")))

;;; ------------------------------------------------------------------
;;; Which candidate a match is worth having -- REQ-0016 R1 and R4.
;;;
;;; Measured on game-server: `context data-handler' ranked four loosely
;;; matched functions above the DATA-HANDLER class the query is named after,
;;; because the type band put :CLASS below :FUNCTION; and `context restructure
;;; data handler protocol encode decode' came back predominantly test
;;; fixtures for a different subsystem.
;;; ------------------------------------------------------------------

(defun k-def (class name file &rest properties)
  "One definition of CLASS named NAME in FILE, plus any extra PROPERTIES."
  (make-instance class :name name :origin-file file
                 :properties (properties-table
                              (list* :file file :start-line 10 :end-line 20
                                     properties))))

(defun graph-of (&rest entities)
  (let ((g (make-graph)))
    (dolist (e entities g) (add-entity g e))))

(test a-class-the-task-names-outranks-functions-that-merely-matched
  ;; R1. Every one of these functions matches some word of the task, and
  ;; before the type tiers were flattened every one of them outranked the
  ;; class the task is named after.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "database-alert" "src/server.lisp")
                          (k-def 'function-entity "handler-exists-p" "src/pkg.lisp")
                          (k-def 'function-entity "data-encoder" "src/encode.lisp")
                          (k-def 'class-entity "data-handler" "src/data/handler.lisp")
                          (k-def 'class-entity "data-handler-error" "src/data/handler.lisp"))
                "data-handler")))
    (is (string= "data-handler" (first names))
        "the entity the query is named after seeds first, class or not")))

(test an-exact-match-on-a-fragment-loom-invented-does-not-promote
  ;; TASK-TOKENS splits "data-handler" into "data" and "handler" to widen the
  ;; search. An entity named exactly DATA therefore matches a token exactly --
  ;; but the caller never wrote that word, so it is Loom's guess and must not
  ;; buy the promotion R1 gives a name the task really contains.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "data" "src/data.lisp")
                          (k-def 'class-entity "data-handler" "src/data/handler.lisp")
                          (k-def 'class-entity "data-handler-error" "src/data/handler.lisp"))
                "data-handler")))
    (is (string= "data-handler" (first names)))
    (is (string= "data-handler-error" (second names))
        "answering to two of the task's terms beats matching an invented one exactly")))

(test a-slot-accessor-does-not-seed-ahead-of-what-it-accesses
  ;; A :GENERATED-BY :INTERFACE is a name a slot declaration synthesised.
  ;; game-server has five DATA accessors in five files and they took five of
  ;; eight seeds on `data-handler'.
  (let ((names (seed-names
                (graph-of (k-def 'interface-entity "data" "src/a.lisp"
                                 :generated-by "holder-a")
                          (k-def 'interface-entity "data" "src/b.lisp"
                                 :generated-by "holder-b")
                          (k-def 'class-entity "data-holder" "src/holder.lisp"))
                "data")))
    (is (string= "data-holder" (first names))
        "the class is the seed; its accessors are one hop away from it")))

(test test-code-ranks-below-production-code-that-matched-the-same-task
  ;; R4, and the fixture is inserted first so that insertion order cannot be
  ;; what produces the answer.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "encode-helper" "src/test/fixture.lisp")
                          (k-def 'function-entity "encode-thing" "src/encode.lisp"))
                "encode helper")))
    (is (string= "encode-thing" (first names))
        "the fixture answers to more of the task and still ranks below it")))

(test a-task-that-asks-about-tests-gets-them
  ;; The other half of R4. "test" is a TASK-TOKENS stopword -- too common to
  ;; match a name against -- so this is read off the raw task instead.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "encode-helper" "src/test/fixture.lisp")
                          (k-def 'function-entity "encode-thing" "src/encode.lisp"))
                "encode helper test")))
    (is (string= "encode-helper" (first names))
        "asked about tests, the demotion must not fire")))

(test a-test-definition-sharing-a-production-name-is-not-demoted
  ;; Where R4 would otherwise eat R8: two of the three
  ;; CONNECTION-CONNECT-DATABASE definitions live in test files, and demoting
  ;; them does not remove a fixture, it removes the triplication that is the
  ;; whole finding.
  (let* ((shared-prod (k-def 'function-entity "connect-db" "src/server.lisp"))
         (shared-test (k-def 'function-entity "connect-db" "src/test/fixture.lisp"))
         (fixture     (k-def 'function-entity "connect-helper" "src/test/fixture.lisp"))
         (matches     (list (cons shared-prod nil) (cons shared-test nil)
                            (cons fixture nil)))
         (production  (loom-knowledge::production-names matches)))
    (is (not (loom-knowledge::demoted-test-p shared-test t production))
        "a test definition of a name production also defines is evidence, not a fixture")
    (is (loom-knowledge::demoted-test-p fixture t production)
        "a name only test code defines is exactly what R4 demotes")
    (is (not (loom-knowledge::demoted-test-p fixture nil production))
        "and nothing is demoted when the task asked about tests")))

(test a-task-naming-one-thing-still-seeds-on-that-thing
  ;; R8. The cap is advisory: when the terms it holds back are the only
  ;; candidates there are, they come back anyway. A fix that suppressed a
  ;; common term hard enough to lose this would trade one defect for a worse
  ;; one -- on game-server this is the shape of the query that works, where
  ;; CONNECTION-CONNECT-DATABASE arrives three times from three files and the
  ;; triplication is the finding.
  (let ((names (seed-names (seed-graph "connect-database" "connect-database-pool"
                                       "connect-database-retry")
                           "connect-database")))
    (is (= 3 (length names))
        "three candidates, one term, and the share is 2 -- all three still come")
    (is (string= "connect-database" (first names))
        "the exact name first, as before")))

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

(test a-bundle-says-which-of-the-task-s-words-reached-nothing
  ;; REQ-0037 R2 and R5, DES-0032 D4. The defect this covers is not that the
  ;; bundle was empty -- it never was. It is that a task naming a capability
  ;; the tree does not have returned eight lexical matches typeset exactly like
  ;; a bundle whose answer was present, and four judged records in .loom/context
  ;; say in the agent's own words that the caller could not tell the two apart.
  ;;
  ;; The fixture's graph holds RESOLVE-OVERLAY and its neighbours and nothing
  ;; about separators, so "overlay" is answered and "separator" reached nothing.
  (let* ((bundle (build-context (k-graph (make-k-fixture))
                                "resolve the overlay with a separator"))
         (text (render-context bundle)))
    (is (search "No indexed entity matches: separator" text)
        "the word that reached nothing is named, which is what `find' says and
what the bundle could not")
    (is (find :answered (getf bundle :terms) :key (lambda (r) (getf r :state)))
        "and a word that did reach something is not reported as an absence")
    (is (not (search "No word of this task is answered" text))
        "the whole-task finding is for a task where nothing is answered")))

(test a-task-answered-by-nothing-says-so-as-a-finding
  ;; R2 proper: the stated finding, not an empty list the caller has to
  ;; interpret. The seeds are still printed -- REQ-0037's acceptance requires
  ;; the negative without buying it with the positives, so nothing is withheld.
  (let ((text (render-context
               (build-context (k-graph (make-k-fixture))
                              "rewrite the leaflet cartography"))))
    (is (search "No word of this task is answered by any name" text))
    (is (search "No indexed entity matches:" text)
        "and the words themselves are named")))

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
  ;; The number is chosen so the budget bites in exactly the interesting place:
  ;; the seeds alone cost more than it, so without the reserve they fill it and
  ;; no document survives. CON-0003 -- remove the reserve and this fails.
  ;;
  ;; It was 450 until PLAN-0032 S3, and the move is not a recalibration to make
  ;; a test pass. The budget used to be estimated from (PRINC-TO-STRING ITEM) --
  ;; the serialised plist, keys and all -- which over-counts the rendered line
  ;; about fivefold, so every token figure this system reported was inflated by
  ;; roughly that factor. RENDER-ITEM now costs what it prints, so the same
  ;; bundle measures about a fifth of what it used to and 450 stopped biting.
  ;; The constant follows the estimator; the estimator is the thing that got
  ;; correct. 150 was found by probing rather than divided: the shape this test
  ;; needs -- truncated, the document surviving, the first seed surviving -- holds
  ;; from 120 to about 200 and stops truncating around 300, so 150 sits in the
  ;; middle of the window rather than on its edge.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 150)))
    (is-true (getf bundle :truncated) "the budget has to actually bite")
    (is (member "REQ-9001" (band-names bundle :document) :test #'string=)
        "the declared document survives a budget the seeds would have eaten: ~a"
        (mapcar (lambda (i) (list (getf i :band) (getf (getf i :entity) :name)))
                (getf bundle :items)))
    (is (member "resolve-overlay" (band-names bundle :seed) :test #'string=)
        "and the reserve did not cost the best seed, which it may never do")
    (is (<= (getf bundle :tokens) 150) "and the budget is still a budget")))

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

;;; ------------------------------------------------------------------
;;; Prose as a seeding signal -- REQ-0035 R4/R7, DES-0028 D4/D5, PLAN-0031 S4
;;; ------------------------------------------------------------------

(test prose-can-seed-an-entity-whose-name-answers-to-nothing
  ;; The defect REQ-0035 was opened on, in miniature. STOPPER matches one
  ;; English word of the task through its name; EXPLAINED matches four through
  ;; its docstring and none through its name. Before the prose pass EXPLAINED
  ;; was not a candidate at all -- no ranking change could have reached it,
  ;; because the text that makes it one was never indexed.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "stopper" "src/a.lisp")
                          (k-def 'function-entity "explained" "src/b.lisp"
                                 :documentation
                                 "stop a fixture displacing the definitions a task asked about"))
                "stop a fixture displacing the definitions a task asked about")))
    (is (member "explained" names :test #'string=))
    (is (string= "explained" (first names))
        "coverage decides: four terms through prose beats one through a name")))

(test a-prose-match-loses-a-tie-to-a-name-match
  ;; The band exists, and it sits *below* coverage rather than above it. Equal
  ;; coverage is where it gets to speak: an author who chose a word for a thing
  ;; said more than one who used it while explaining the thing.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "widget" "src/a.lisp")
                          (k-def 'function-entity "unrelated" "src/b.lisp"
                                 :documentation "a widget of some kind"))
                "widget")))
    (is (string= "widget" (first names)))))

(test prose-matching-is-whole-word
  ;; DES-0028 D4. Substring-matching a word across 549 KB of English finds it
  ;; inside longer words, and the noise would arrive in proportion to how much a
  ;; project documented -- worst on the trees that invested most in prose.
  ;;
  ;; Not spelled with "test", which would have been the natural example: that
  ;; word is on *CONTEXT-STOPWORDS* and never reaches the prose pass at all. A
  ;; hardcoded guess about English deciding what can be matched is the defect
  ;; DES-0028 D5 argues IDF should retire, met here while writing its test.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "alpha" "src/a.lisp"
                                 :documentation "the cached uncacheable recaching")
                          (k-def 'function-entity "beta" "src/b.lisp"
                                 :documentation "writes to a cache"))
                "cache")))
    (is (member "beta" names :test #'string=))
    (is (not (member "alpha" names :test #'string=))
        "\"cached\" and \"recaching\" contain the token and are not the word")))

(test an-undocumented-definition-is-not-penalised-for-being-undocumented
  ;; REQ-0035 R7. On game-server 86% of functions carry no docstring, so a score
  ;; that ranked undocumented code below documented code would be a recall
  ;; defect on the tree the requirement is measured against -- and under
  ;; CON-0006 a recall defect is the expensive kind. The band demotes prose-ONLY
  ;; matches, and an entity with no prose is not in it.
  (let ((names (seed-names
                (graph-of (k-def 'function-entity "widget-maker" "src/a.lisp")
                          (k-def 'function-entity "other" "src/b.lisp"
                                 :documentation "concerns the widget maker also"))
                "widget-maker")))
    (is (string= "widget-maker" (first names))
        "no prose, and still first: absence is neutral, not negative")))

(test task-tokens-reaches-a-definition-named-for-the-task
  ;; The one entity two reverted attempts at a postings index gained, gained
  ;; here instead. "saving a piece design" tokenised to SAVING and SAVEDESIGN
  ;; tokenises to SAVE, so the definition named after the task matched none of
  ;; the query.
  (let ((tokens (loom-knowledge::task-tokens "saving a piece design")))
    (is (member "save" tokens :test #'string=)))
  (is (member "edit" (loom-knowledge::task-tokens "editing colours") :test #'string=))
  (is (member "layer" (loom-knowledge::task-tokens "edited layers") :test #'string=)))

(test a-stem-is-added-and-never-substituted
  ;; A wrong guess then costs nothing: a stem matching no name never matches,
  ;; where a substitution would have lost the word the caller wrote.
  ;;
  ;; This asserted a third token, "sav", until DES-0033 D4 -- and described it
  ;; in its own failure message as "dropping -ing, which matches nothing". It
  ;; was an artefact of the hand-written rule, which dropped the suffix and
  ;; then restored an -e as two separate guesses and emitted both. Porter makes
  ;; one guess and emits "save". Asserting the useless half of a discarded
  ;; mechanism is not a property of stemming, and its absence is the point of
  ;; the change rather than a casualty of it.
  (let ((tokens (loom-knowledge::task-tokens "saving")))
    (is (member "saving" tokens :test #'string=)
        "the word the caller wrote is never replaced")
    (is (member "save" tokens :test #'string=)
        "and its stem is added beside it, which is what reaches SAVEDESIGN")))

(test stemming-keeps-short-identifiers-whole
  (is (not (member "clas" (loom-knowledge::task-tokens "class") :test #'string=))
      "a double s is refused")
  (is (not (member "addres" (loom-knowledge::task-tokens "address") :test #'string=)))
  (is (member "type" (loom-knowledge::task-tokens "types") :test #'string=)
      "and an ordinary plural still folds"))
