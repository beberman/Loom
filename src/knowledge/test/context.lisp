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

(test a-word-a-code-tree-names-things-with-is-searched-rather-than-dropped
  ;; DES-0038. Every one of these was a stopword, and each was measured losing
  ;; a case whose answer is named after it: `game add definition' for
  ;; GAME.ADDDEFINITION, `get feature layer' for GETFEATURELAYER, `pin set' for
  ;; PINSET, `make table handler' for MAKE-TABLE-HANDLER.
  ;;
  ;; "pin set" is the one to read. Dropping `set' left that query one token
  ;; long, so the word carrying the whole distinction between PIN and PINSET
  ;; never reached the index at all.
  (let ((tokens (loom-knowledge::task-tokens "get type from obj")))
    (is (member "get" tokens :test #'string=)
        "the commonest verb in a code tree is a word the caller meant")
    (is (member "from" tokens :test #'string=)
        "and FROMPOJO and FROMLL are named after this one"))
  (dolist (word '("set" "add" "make" "test" "file" "class" "new" "update"))
    (is (member word (loom-knowledge::task-tokens (format nil "pin ~a" word))
                :test #'string=)
        (format nil "~a reaches the index" word))))

(test and-stays-a-stopword-because-a-judged-case-says-so
  ;; The one word DES-0038 measured and did not free. Freeing it scored 3 of
  ;; the 450 generated cases better and cost REQ-0016 R8, whose query is
  ;; `data-api handler database connection acquire and test connectivity' and
  ;; which stopped returning CONNECTION-CONNECT-DATABASE at all. REQ-0036 R11
  ;; makes the judged set the held-out one; a generated case does not outvote
  ;; it.
  (is (not (member "and" (loom-knowledge::task-tokens "namespace add and find")
                   :test #'string=))
      "and is English here, whatever TEST-NAMESPACE-ADD-AND-FIND is called")
  (is (member "add" (loom-knowledge::task-tokens "namespace add and find")
              :test #'string=)
      "which is not an argument about the word beside it"))

(test a-candidate-answering-only-a-weak-word-is-not-a-seed
  ;; The half of DES-0038 that makes the other half safe. `get' names something
  ;; in almost any code tree, so searching it without this admits every GETX in
  ;; the repository as a seed in its own right -- measured on game-server, `get
  ;; database config' returned GET-GAME-DB-ID and GET-TYPEID and lost
  ;; GET-DATABASE-CONFIG, which it had found while `get' was a stopword.
  (let ((names (seed-names (seed-graph "get-database-config" "get-typeid"
                                       "get-game-db-id" "database-alert")
                           "get database config")))
    (is (string= "get-database-config" (first names))
        "three terms answered beats one, and only this candidate answers three")
    (is (not (member "get-typeid" names :test #'string=))
        "a candidate whose only answer is `get' is not a candidate")
    (is (member "database-alert" names :test #'string=)
        "while a candidate answering a term that is not weak stays one")))

(test a-task-written-entirely-out-of-weak-words-still-seeds
  ;; The relaxation, the same shape ADMIT-SEEDS uses and for the same reason.
  ;; The filter drops a candidate that answered nothing but weak terms, which
  ;; for this task is every candidate there is -- and a bundle of nothing is a
  ;; worse answer than a bundle of what the words actually reached.
  (let ((names (seed-names (seed-graph "get-set" "settings" "getter")
                           "get set")))
    (is (plusp (length names))
        "an empty pool is returned whole rather than as no seeds at all")
    (is (member "get-set" names :test #'string=)
        "and the candidate answering both of the task's words is among them")))

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
  ;; tools/test/acceptance.py cannot see it. It scores a set of names, so one
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

(defun band-names (bundle band)
  "The names of BUNDLE's admitted items in BAND. DES-0020 D6: the band on each
item is what groups the bundle now that DES-0046 removed the four lists."
  (loop for item in (getf bundle :items)
        when (eq band (getf item :band))
          collect (getf (getf item :entity) :name)))

(test a-bundle-contains-the-seeds-and-their-neighbourhood
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "resolve-overlay" (band-names bundle :seed) :test #'string=))
    (let ((names (mapcar (lambda (i) (getf (getf i :entity) :name))
                         (getf bundle :items))))
      (is (member "resolve-overlay" names :test #'string=))
      (is (member "compose-view" names :test #'string=)
          "one hop out from the seed"))))

(test a-bundle-carries-the-decisions-bearing-on-what-it-found
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "ADR-7" (band-names bundle :decision) :test #'string=)
        "why the code is the way it is, which no amount of re-reading recovers")))

(test a-bundle-excludes-stale-knowledge
  (let* ((f (make-k-fixture)))
    (setf (stale-p (k-adr f)) t)
    (let ((bundle (build-context (k-graph f) "change resolve-overlay")))
      (is (null (band-names bundle :decision))
          "SS-provenance: stale facts stay out of agent context until re-verified")
      (is (zerop (getf (getf (getf bundle :bands) :decision) :found))
          "DES-0046: the band count agrees -- nothing found, nothing sent"))))

(test a-bundle-that-matches-nothing-says-so-rather-than-inventing
  (let ((bundle (build-context (k-graph (make-k-fixture)) "rewrite the leaflet map")))
    (is (null (getf bundle :seeds)))
    (is (zerop (getf (getf (getf bundle :bands) :seed) :found)))
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


(test a-document-that-declares-it-bears-on-the-code-reaches-the-bundle
  ;; REQ-0026's whole complaint. REQ-9001 is a :DOCUMENT, which is what
  ;; requirements, plans, bugs and reviews all are, and it declares affects:
  ;; -- so it earns a :DOCUMENTS edge that DECISIONS-TOUCHING collected and
  ;; then threw away for having the wrong type. Delete the documents band and
  ;; this fails.
  (let* ((f (banded-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay")))
    (is (member "REQ-9001" (band-names bundle :document) :test #'string=)
        "a declared claim on this code belongs in the bundle whatever its type")
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
  ;; tree: measured on game-server, eight seeds and their relations spent
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

;;; ------------------------------------------------------------------
;;; The absent embedder -- REQ-0048 R6, PLAN-0043 S3
;;; ------------------------------------------------------------------

(test with-no-embedder-configured-nothing-is-asked
  ;; The step whose failure has no symptom. A bundle comes back either way,
  ;; still correct, and the damage is latency or a stray condition that no
  ;; recall count would show. So the assertion is about what was *not* done.
  (let ((loom-knowledge::*context-embedder* nil)
        (loom-knowledge::*context-vector-store* nil))
    (is (null (loom-knowledge::semantic-candidates
               (seed-graph "alpha" "beta") "alpha"))
        "no embedder means no candidates and no call")))

(test an-embedder-with-no-store-asks-nothing-either
  ;; Three ways to get nothing -- no embedder, no store, a store that refuses --
  ;; and REQ-0048 R6 gives them one meaning. A caller that had to tell them
  ;; apart would have three paths where the requirement asks for one.
  (let ((loom-knowledge::*context-embedder*
          (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3))
        (loom-knowledge::*context-vector-store* nil))
    (is (null (loom-knowledge::semantic-candidates
               (seed-graph "alpha" "beta") "alpha")))))

(test the-bundle-is-unchanged-by-the-seam
  ;; The seam appends SEMANTIC-CANDIDATES to the candidate pool. With no
  ;; embedder that is APPEND to NIL, and this asserts the identity rather than
  ;; assuming it: a seam that reordered or copied would move ties, and a tie
  ;; moved is a seed lost at the eighth slot.
  (let ((expected '("database-handler-health" "check-slot")))
    (let ((loom-knowledge::*context-embedder* nil))
      (is (equal expected
                 (subseq (seed-names (seed-graph "database-handler-health"
                                                 "check-slot" "check-obj")
                                     "database handler health check")
                         0 2))))))

(test only-an-integer-is-a-name-rank
  ;; DES-0040 D5 claimed BEST-NAME-RANK already handled a non-integer rank
  ;; because :PROSE is one. It did not: the code removed :PROSE by name and
  ;; took the minimum of what was left, so a cosine survived and won. A
  ;; semantic candidate that matched no word the caller wrote would have ranked
  ;; ahead of a prefix match on a word they did.
  (is (= 3 (loom-knowledge::best-name-rank '(("x" . :prose))))
      "prose-only still has no rank to give")
  (is (= 3 (loom-knowledge::best-name-rank '((:similarity . 0.83))))
      "and neither does similarity, whatever the number looks like")
  (is (= 1 (loom-knowledge::best-name-rank '(("x" . 1) (:similarity . 0.83))))
      "a real name match is not displaced by a cosine that sorts lower")
  (is (= 0 (loom-knowledge::best-name-rank '(("x" . 2) ("y" . 0)))))
  (is (= 3 (loom-knowledge::best-name-rank '()))))

(test a-semantic-candidate-carries-similarity-and-answers-no-term
  ;; DES-0040 D5. The shape is what makes REQ-0048 R4 hold by construction:
  ;; CLASSIFY-TERMS marks a term ANSWERED when an admitted seed carries it in
  ;; its name, it walks the matched terms, and :SIMILARITY is not one of the
  ;; caller's words. Cosine returns nearest neighbours for every query ever
  ;; asked, so a mechanism that let similarity answer a word would make the
  ;; absence report unable to report an absence.
  (let* ((graph (seed-graph "compose-view" "unrelated-thing"))
         (target (first (find-entities graph :name-like "compose-view")))
         (store (loom-embed:make-vector-store
                 :embedder-id "fixed:test" :dimensions 3 :count 1
                 :ids (vector (id target))
                 :digests (vector 0)
                 :vectors (make-array 3 :element-type 'single-float
                                        :initial-contents '(1.0 0.0 0.0))))
         (loom-knowledge::*context-vector-store* store)
         (loom-knowledge::*context-embedder*
           (loom-embed:make-fixed-embedder
            :id "fixed:test" :dimensions 3
            :vectors '(("the bit that merges edits" . #(1.0 0.0 0.0)))))
         (candidates (loom-knowledge::semantic-candidates
                      graph "the bit that merges edits")))
    (is (= 1 (length candidates)) "the scan proposes the entity it is nearest")
    (is (eq target (car (first candidates))))
    (let ((matches (cdr (first candidates))))
      (is (= 1 (length matches)))
      (is (eq :similarity (car (first matches))))
      (is (< 0.99 (cdr (first matches))) "and carries the cosine it scored"))
    ;; The consequence, asserted rather than assumed.
    (let ((coverage (loom-knowledge::term-coverage candidates '("merges" "edits"))))
      (is (every (lambda (row) (null (getf (cdr row) :name))) coverage)
          "a semantic candidate answers no term by name")
      (is (equal '(:unmatched :unmatched)
                 (mapcar #'cdr (loom-knowledge::classify-terms
                                coverage (list target))))
          "so the report still says the query's words reached nothing"))))

(test an-embedder-that-cannot-answer-is-an-embedder-that-is-not-there
  ;; REQ-0048 R6 again, on the path that only exists once there is a scan: the
  ;; store and the embedder are both configured and the call fails.
  (let* ((graph (seed-graph "alpha"))
         (loom-knowledge::*context-vector-store*
           (loom-embed:make-vector-store :embedder-id "fixed:test" :dimensions 3
                                         :count 0))
         (loom-knowledge::*context-embedder*
           (loom-embed:make-memoing-embedder
            (make-instance 'loom-embed-test::failing-embedder))))
    (is (null (loom-knowledge::semantic-candidates graph "alpha"))
        "a failure is nothing, not a condition reaching the caller")))

(test a-stale-id-in-the-store-is-dropped-rather-than-fabricated
  ;; The store is derived from an index that has since moved. PLAN-0043 S2b
  ;; makes that rare and not impossible, and an id nothing in the view holds is
  ;; CON-0001's fabricated fact if it is returned anyway.
  (let* ((graph (seed-graph "alpha"))
         (loom-knowledge::*context-vector-store*
           (loom-embed:make-vector-store
            :embedder-id "fixed:test" :dimensions 3 :count 1
            :ids (vector "function:src/gone.lisp:deleted-thing")
            :digests (vector 0)
            :vectors (make-array 3 :element-type 'single-float
                                   :initial-contents '(1.0 0.0 0.0))))
         (loom-knowledge::*context-embedder*
           (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
    (is (null (loom-knowledge::semantic-candidates graph "alpha")))))

;;; ------------------------------------------------------------------
;;; Fusion -- PLAN-0043 S5, DES-0040 D4 and D6
;;; ------------------------------------------------------------------

(defmacro with-rank-fusion (&body body)
  "Run BODY under :RECIPROCAL-RANK.

Every test below it asserts reciprocal-rank arithmetic -- who outranks whom for
a given pair of positions -- and its fixtures carry positions rather than
scores. DES-0050 made :RELATIVE-SCORE the default, and a relative-score fusion
of a list with no scores is refused rather than guessed at, so the binding is
what keeps these tests about the thing they were written for. The
relative-score path has its own tests further down."
  `(let ((loom-knowledge::*fusion* :reciprocal-rank)) ,@body))

(defun fused-names (lexical semantic)
  (with-rank-fusion
    (mapcar (lambda (pair) (name (car pair)))
            (loom-knowledge::fuse-rankings lexical semantic))))

(defun ranked-pair (entity &rest matches)
  (cons entity matches))

(test with-no-semantic-list-the-lexical-order-is-returned-unchanged
  ;; REQ-0048 R6 as an identity rather than an arithmetic coincidence. Fusing
  ;; one list would reproduce its order, and returning it outright is what
  ;; makes that true by construction on every query on a machine with no
  ;; embedder -- which is every query today.
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (lexical (list (ranked-pair a '("x" . 0)) (ranked-pair b '("y" . 1)))))
    (is (eq lexical (with-rank-fusion (loom-knowledge::fuse-rankings lexical nil)))
        "the very list, not a copy of it")))

(test a-candidate-on-both-lists-outranks-one-on-either-alone
  ;; The property RRF is chosen for: agreement between two mechanisms that
  ;; share no scale is worth more than a good place on one of them.
  (let* ((both (k-function "on-both" 10))
         (lex  (k-function "lexical-only" 30))
         (sem  (k-function "semantic-only" 50))
         (lexical (list (ranked-pair lex '("x" . 0))
                        (ranked-pair both '("y" . 1))))
         (semantic (list (ranked-pair sem '(:similarity . 0.9))
                         (ranked-pair both '(:similarity . 0.8)))))
    (is (string= "on-both" (first (fused-names lexical semantic)))
        "second on each list beats first on one")))

(test a-fused-candidate-carries-both-kinds-of-match
  ;; DES-0040 D6: a candidate on both lists is not dense-only, so ADMIT-SEEDS
  ;; charges it to the slice its terms make, exactly as it would have without
  ;; an embedder.
  (let* ((e (k-function "both" 10))
         (fused (with-rank-fusion
                  (loom-knowledge::fuse-rankings
                   (list (ranked-pair e '("term" . 0)))
                   (list (ranked-pair e '(:similarity . 0.8)))))))
    (is (= 1 (length fused)) "one entity, not two")
    (let ((matches (cdr (first fused))))
      (is (= 2 (length matches)))
      (is (not (loom-knowledge::dense-only-p matches)))
      (is (string= "term" (loom-knowledge::seed-slice matches))
          "and similarity is not part of the slice"))))

(test similarity-is-not-part-of-a-slice
  ;; Left in, every dense candidate would share one slice and
  ;; *SEED-TERM-SHARE* would hold the whole bundle to two of them.
  (is (string= "" (loom-knowledge::seed-slice '((:similarity . 0.9)))))
  (is (loom-knowledge::dense-only-p '((:similarity . 0.9))))
  (is (not (loom-knowledge::dense-only-p '(("word" . 1) (:similarity . 0.9))))))

(test dense-only-candidates-are-exempt-from-the-slice-cap
  ;; They all share the empty slice, so the cap would admit two and hold back
  ;; the rest -- a cap written to stop one English word filling the set,
  ;; applied to candidates that answered no word at all.
  (let ((ranked (loop for i from 0 below 6
                      collect (ranked-pair (k-function (format nil "dense-~d" i) (* 10 i))
                                           (cons :similarity (- 0.9 (* 0.01 i)))))))
    (is (= 6 (length (loom-knowledge::admit-seeds ranked 8)))
        "six dense-only candidates all reach the bundle")))

(test dense-only-candidates-still-pay-the-name-cap
  ;; BUG-0041 bounds definitions of one name however the candidate arrived.
  ;; Five other names as well, because ADMIT-SEEDS relaxes rather than
  ;; enforces: with nothing else waiting the held-back copies come back and the
  ;; count would measure the fixture instead of the cap. BUG-0041's own test
  ;; needed the same fixture for the same reason.
  (let* ((ranked (append
                  (loop for i from 0 below 8
                        collect (ranked-pair
                                 (k-def 'function-entity "delete-obj"
                                        (format nil "src/f~d.lisp" i))
                                 (cons :similarity (- 0.9 (* 0.01 i)))))
                  (loop for i from 0 below 5
                        collect (ranked-pair
                                 (k-function (format nil "other-~d" i) (* 10 i))
                                 (cons :similarity (- 0.5 (* 0.01 i)))))))
         (chosen (loom-knowledge::admit-seeds ranked 8)))
    (is (= 8 (length chosen)) "the bundle still fills")
    (is (= loom-knowledge::*seed-name-share*
           (count "delete-obj" chosen :key #'name :test #'string=))
        "but eight vectors for one name are still three seeds")))

(test one-classes-methods-cannot-take-the-whole-bundle
  ;; BUG-0060. The two existing caps charge a slice and a name, and a method
  ;; family escapes both: five methods of one class carry five distinct names
  ;; and answer five different slices, so nothing counted them and
  ;; `LayerEditorState' took six of eight slots on a front-end task while
  ;; `RenderEngineLeaflet' -- which that task named by its exact full name --
  ;; got none.
  ;;
  ;; Five other names as well, and for DENSE-ONLY-CANDIDATES-STILL-PAY-THE-NAME-
  ;; CAP's reason: ADMIT-SEEDS relaxes every cap rather than return fewer seeds
  ;; than there are candidates, so with nothing else waiting the held-back
  ;; members come back and the count measures the fixture instead of the cap.
  (let* ((ranked (append
                  (loop for i from 0 below 6
                        for n = (format nil "Owner.member~d" i)
                        collect (ranked-pair (k-def 'function-entity n
                                                    (format nil "src/o~d.js" i))
                                             (cons (format nil "term~d" i) 0)))
                  (loop for i from 0 below 5
                        collect (ranked-pair
                                 (k-def 'function-entity (format nil "other-~d" i)
                                        (format nil "src/x~d.js" i))
                                 (cons (format nil "w~d" i) 0)))))
         (chosen (loom-knowledge::admit-seeds ranked 8)))
    (is (= 8 (length chosen)) "the bundle still fills")
    (is (= loom-knowledge::*seed-owner-share*
           (count-if (lambda (e) (string= "Owner" (loom-knowledge::seed-owner e)))
                     chosen))
        "six members of one class are three seeds")))

(test a-name-that-spells-no-parent-is-charged-to-no-family
  ;; The NIL owner must not become one bucket every unqualified name shares --
  ;; that would cap the whole of a Lisp tree at three seeds. Six plain names,
  ;; six distinct slices, no cap.
  (let ((ranked (loop for i from 0 below 6
                      collect (ranked-pair
                               (k-def 'function-entity (format nil "plain-~d" i)
                                      (format nil "src/p~d.lisp" i))
                               (cons (format nil "t~d" i) 0)))))
    (is (null (loom-knowledge::seed-owner (car (first ranked)))))
    (is (= 6 (length (loom-knowledge::admit-seeds ranked 8)))
        "six unqualified names all reach the bundle")))

(test a-file-name-with-an-extension-is-not-a-family
  ;; SEED-OWNER reads the part before the last dot, and a :FILE's name is a
  ;; path -- so without the type exclusion every .js file in a directory would
  ;; be one family and three of them would cap the rest.
  (let ((f (k-def 'file-entity "src/ui/RenderEngineLeaflet.js" "src/ui/RenderEngineLeaflet.js")))
    (is (null (loom-knowledge::seed-owner f)))))

(test a-dense-only-seed-does-not-answer-a-term
  ;; REQ-0048 R4 through the whole path rather than at SEMANTIC-CANDIDATES.
  ;; Cosine returns nearest neighbours for every query ever asked, so a
  ;; mechanism that let similarity answer a word would make the absence report
  ;; unable to report an absence.
  (let* ((e (k-function "compose-view" 10))
         (ranked (list (ranked-pair e '(:similarity . 0.87))))
         (chosen (loom-knowledge::admit-seeds ranked 8))
         (coverage (loom-knowledge::term-coverage ranked '("merges" "edits"))))
    (is (equal (list e) chosen))
    (is (equal '(:unmatched :unmatched)
               (mapcar #'cdr (loom-knowledge::classify-terms coverage chosen))))))

(test a-named-candidate-is-not-displaced-by-one-that-merely-resembles-it
  ;; REQ-0016 R1 through the fusion, and REQ-0048 R2. Measured on game-server,
  ;; `mapper to native' put MAPMAPPER.TONATIVE at cosine 0.982 and
  ;; MAPPER.TONATIVE at 0.635 -- the elaborated siblings all beat the plain
  ;; name, because a document is a name plus a docstring and the barest member
  ;; of a family is the one whose document is least dominated by its own name.
  ;; No threshold separates that: the wrong answers score higher.
  ;; The named candidate sits low in the lexical list and not on the semantic
  ;; one at all, which is the shape the real failure has: RRF already rewards
  ;; agreement, so a candidate on both lists needs no protecting.
  (let* ((named    (k-function "mapper" 10))
         (resembles (k-function "map-mapper-to-native" 30))
         (lexical  (append (loop for i from 0 below 4
                                 collect (ranked-pair
                                          (k-function (format nil "other-~d" i) (* 10 i))
                                          '("other" . 2)))
                           (list (ranked-pair named '("mapper" . 0)))))
         (semantic (list (ranked-pair resembles '(:similarity . 0.98)))))
    (is (string= "map-mapper-to-native"
                 (first (fused-names lexical semantic)))
        "unprotected, the resemblance wins")
    (is (string= "mapper"
                 (name (car (first (with-rank-fusion
                                     (loom-knowledge::fuse-rankings
                                      lexical semantic :protected (list named)))))))
        "protected, the name the caller wrote wins")))

(test protection-is-a-band-and-not-a-weight
  ;; Protected candidates keep their order among themselves, and nothing
  ;; unprotected climbs past one however high its cosine.
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (loud (k-function "loud" 50))
         (lexical (list (ranked-pair a '("alpha" . 0)) (ranked-pair b '("beta" . 0))))
         (semantic (list (ranked-pair loud '(:similarity . 0.99)))))
    (is (equal '("alpha" "beta" "loud")
               (mapcar (lambda (p) (name (car p)))
                       (with-rank-fusion
                         (loom-knowledge::fuse-rankings lexical semantic
                                                        :protected (list a b))))))))

(test protecting-nothing-leaves-the-fusion-as-it-was
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (lexical (list (ranked-pair a '("x" . 1))))
         (semantic (list (ranked-pair b '(:similarity . 0.9)))))
    (is (equal (mapcar (lambda (p) (name (car p)))
                       (with-rank-fusion
                         (loom-knowledge::fuse-rankings lexical semantic)))
               (mapcar (lambda (p) (name (car p)))
                       (with-rank-fusion
                         (loom-knowledge::fuse-rankings lexical semantic
                                                        :protected '())))))))


;;; ------------------------------------------------------------------
;;; Relative score fusion -- DES-0050
;;; ------------------------------------------------------------------

(defun score-table (&rest entity-score-pairs)
  "A LEXICAL-SCORE function over ENTITY-SCORE-PAIRS."
  (let ((table (make-hash-table :test #'eq)))
    (loop for (entity score) on entity-score-pairs by #'cddr
          do (setf (gethash entity table) score))
    (lambda (entity) (gethash entity table))))

(test a-relative-score-fusion-without-scores-is-refused
  ;; The lexical side has nothing to normalise, so the fusion would be the
  ;; dense list alone -- an answer that looks like a fusion and is not one.
  ;; CON-0001's posture on a value that cannot be derived.
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (loom-knowledge::*fusion* :relative-score))
    (signals error
      (loom-knowledge::fuse-rankings (list (ranked-pair a '("x" . 0)))
                                     (list (ranked-pair b '(:similarity . 0.9)))))))

(test a-relative-score-fusion-with-no-lexical-candidates-is-the-dense-list
  ;; BUG-0075. A task whose words match no name and no prose -- `pa', `siteses'
  ;; -- leaves the lexical list empty, and the dense list is then all there is.
  ;; The fusion took the best and worst of an empty list with REDUCE and no
  ;; initial value, which calls MAX with no arguments, and the query answered
  ;; 500. That is the case the dense list exists for.
  (let* ((b (k-function "beta" 30))
         (c (k-function "gamma" 40))
         (semantic (list (ranked-pair b '(:similarity . 0.9))
                         (ranked-pair c '(:similarity . 0.7))))
         (loom-knowledge::*fusion* :relative-score))
    (is (equal '("beta" "gamma")
               (mapcar (lambda (pair) (name (car pair)))
                       (loom-knowledge::fuse-rankings
                        nil semantic
                        :lexical-weight 0.5
                        :lexical-score (lambda (entity) (declare (ignore entity)) 0))))
        "the dense list, in its own order")))

(test a-named-cliff-outranks-a-flat-dense-list
  ;; BUG-0060's shape, as arithmetic rather than as a bundle. Two lexical
  ;; candidates the caller named sit 100000 below everything else, which is
  ;; SEED-SCORE's `named' band; three dense candidates sit within 5% of each
  ;; other, which is what *SEMANTIC-RELATIVE-FLOOR* builds. Under
  ;; :RECIPROCAL-RANK the dense list takes the head -- that is the defect --
  ;; and under :RELATIVE-SCORE the named pair keeps it.
  (let* ((named-1 (k-function "render-engine-leaflet" 10))
         (named-2 (k-function "terrain-partition" 20))
         (unnamed (k-function "some-method" 30))
         (dense-1 (k-function "near-1" 40))
         (dense-2 (k-function "near-2" 50))
         (dense-3 (k-function "near-3" 60))
         (lexical (list (ranked-pair named-1 '("renderengineleaflet" . 0))
                        (ranked-pair named-2 '("terrainpartition" . 0))
                        (ranked-pair unnamed '("render" . 1))))
         (semantic (list (ranked-pair dense-1 '(:similarity . 0.757))
                         (ranked-pair dense-2 '(:similarity . 0.735))
                         (ranked-pair dense-3 '(:similarity . 0.714))))
         (scores (score-table named-1 600 named-2 600 unnamed 100101))
         (rank-fused (with-rank-fusion
                       (mapcar (lambda (p) (name (car p)))
                               (loom-knowledge::fuse-rankings lexical semantic))))
         (score-fused (let ((loom-knowledge::*fusion* :relative-score)
                            (loom-knowledge::*lexical-weight* 0.5))
                        (mapcar (lambda (p) (name (car p)))
                                (loom-knowledge::fuse-rankings
                                 lexical semantic :lexical-score scores)))))
    (is (string= "near-1" (first rank-fused))
        "reciprocal rank hands the head to the dense list")
    (is (string= "render-engine-leaflet" (first score-fused))
        "relative score keeps it with the name the caller wrote")
    (is (< (position "terrain-partition" score-fused :test #'string=)
           (position "near-1" score-fused :test #'string=))
        "and the whole cliff, not only its first member")))

(test a-head-of-equal-scores-normalises-together
  ;; A lexical head nothing separates divides by a span of zero. Every member
  ;; normalises to 1.0 rather than signalling, because they are equally good
  ;; and that is the answer.
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (dense (k-function "dense" 50))
         (loom-knowledge::*fusion* :relative-score)
         ;; Bound rather than defaulted: at an even split every candidate here
         ;; scores alike, which is what makes the tie visible. The shipped
         ;; *LEXICAL-WEIGHT* is not 0.5 and would decide the order by weight.
         (loom-knowledge::*lexical-weight* 0.5)
         (fused (loom-knowledge::fuse-rankings
                 (list (ranked-pair a '("x" . 0)) (ranked-pair b '("y" . 0)))
                 (list (ranked-pair dense '(:similarity . 0.9)))
                 :lexical-score (score-table a 600 b 600))))
    (is (= 3 (length fused)) "no candidate was lost to a division by zero")
    (is (equal '("alpha" "beta") (subseq (mapcar (lambda (p) (name (car p))) fused) 0 2))
        "tied lexical candidates keep SEED-SCORE's order between them")))

(test only-the-fusion-head-contributes-a-lexical-score
  ;; *FUSION-HEAD* bounds the normalisation because SEED-SCORE's type band is
  ;; worth 1000000 and one :FILE inside the head would compress the named
  ;; boundary this fusion exists to find. A candidate past the head is treated
  ;; the way a candidate absent from the dense list is treated.
  (let* ((a (k-function "alpha" 10))
         (b (k-function "beta" 30))
         (dense (k-function "dense" 50))
         (loom-knowledge::*fusion* :relative-score)
         (loom-knowledge::*fusion-head* 1)
         (fused (loom-knowledge::fuse-rankings
                 (list (ranked-pair a '("x" . 0)) (ranked-pair b '("y" . 0)))
                 (list (ranked-pair dense '(:similarity . 0.9)))
                 :lexical-score (score-table a 600 b 100601))))
    (is (= 2 (length fused)) "the candidate past the head is not in the fusion")
    (is (not (member "beta" fused :key (lambda (p) (name (car p))) :test #'string=)))))

(test an-unnamed-lexical-head-weighs-less
  ;; DES-0050 D8. The mismatch family is 120 queries built so that no lexical
  ;; candidate can be the answer, and on those every slot the lexical list
  ;; takes is one the dense list needed. What marks the case is that the task
  ;; named nothing at lexical rank 1.
  (let* ((flat-1 (k-function "flat-one" 10))
         (flat-2 (k-function "flat-two" 20))
         (dense  (k-function "dense" 30))
         (lexical (list (ranked-pair flat-1 '("word" . 1))
                        (ranked-pair flat-2 '("word" . 2))))
         (semantic (list (ranked-pair dense '(:similarity . 0.9))))
         (scores (score-table flat-1 100502 flat-2 100602))
         (loom-knowledge::*fusion* :relative-score))
    (is (string= "flat-one"
                 (name (car (first (loom-knowledge::fuse-rankings
                                    lexical semantic :lexical-score scores
                                    :lexical-weight 0.6)))))
        "weighted towards the lexical side, its head leads")
    (is (string= "dense"
                 (name (car (first (loom-knowledge::fuse-rankings
                                    lexical semantic :lexical-score scores
                                    :lexical-weight 0.2)))))
        "weighted away from it, the dense candidate does")))

;;; ------------------------------------------------------------------
;;; What the budget refused (PLAN-0045 S1, DES-0042 D3)
;;; ------------------------------------------------------------------

(test a-truncated-bundle-counts-what-it-withheld
  ;; :TRUNCATED said that a bundle was cut and never how much, so a caller
  ;; could not tell one that lost its last neighbour from one that lost forty
  ;; entities -- nor whether asking again with a bigger number was worth
  ;; anything.
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 150)))
    (is-true (getf bundle :truncated) "the budget has to actually bite")
    (is (plusp (getf bundle :withheld-items)))
    (is (plusp (getf bundle :withheld-tokens)))
    (is (> (getf bundle :found-tokens) (getf bundle :tokens))
        "what the walk found exceeds what this budget sent")))

(test the-per-band-count-and-the-remainder-list-are-two-halves-of-one-fact
  ;; DES-0046. Each candidate list now carries only what its band did not
  ;; admit; :BANDS carries the count. For every band, FOUND minus SENT is the
  ;; length of the remainder list -- so the two cannot disagree -- and the
  ;; SENT counts sum to the item count. On an unbounded budget every list is
  ;; empty and FOUND equals SENT. Without the change there is no :BANDS and
  ;; every GETF into it is NIL.
  (let* ((f (make-k-fixture))
         (tight (build-context (k-graph f) "change resolve-overlay" :budget 150))
         (loose (build-context (k-graph f) "change resolve-overlay" :budget 100000))
         (walk-bands '(:seed :decision :document :mention :neighbour))
         (list-bands '((:seed . :seeds) (:decision . :decisions)
                       (:document . :documents) (:mention . :mentions))))
    (flet ((found (b band) (getf (getf (getf b :bands) band) :found))
           (sent  (b band) (getf (getf (getf b :bands) band) :sent)))
      (is (= (length (getf tight :items))
             (reduce #'+ (mapcar (lambda (band) (sent tight band)) walk-bands)))
          "every admitted item is counted under exactly one band")
      (is (> (found tight :neighbour) (sent tight :neighbour))
          "the neighbour band is what a tight budget clips")
      (dolist (pair list-bands)
        (is (= (- (found tight (car pair)) (sent tight (car pair)))
               (length (getf tight (cdr pair))))
            "~(~a~): FOUND minus SENT is the remainder list's length" (car pair)))
      (dolist (band walk-bands)
        (is (= (found loose band) (sent loose band))
            "~(~a~): an unbounded budget sends every candidate it found" band))
      (dolist (pair list-bands)
        (is (null (getf loose (cdr pair)))
            "~(~a~): nothing was refused, so the remainder list is empty" (cdr pair))))))

(test a-truncated-bundle-names-the-candidates-the-budget-refused
  ;; DES-0046 D4, REQ-0061 R2. C3 was rejected because after truncation nothing
  ;; would name what the walk found and did not send. The remainder list does.
  ;; :NEIGHBOUR keeps a count only -- it is the cost-ordered tail, recoverable
  ;; by `describe' on a seed -- so the named refusals are the four banded
  ;; lists, and a budget below the document reserve forces at least one.
  (multiple-value-bind (f) (banded-fixture)
    (let* ((tight (build-context (k-graph f) "change resolve-overlay" :budget 30))
           (sent-names (mapcar (lambda (i) (getf (getf i :entity) :name))
                               (getf tight :items)))
           (refused (append (getf tight :seeds) (getf tight :decisions)
                            (getf tight :documents) (getf tight :mentions))))
      (is-true (getf tight :truncated))
      (is (plusp (length refused))
          "a budget below the document reserve refuses a named candidate")
      (dolist (r refused)
        (is (not (member (getf r :name) sent-names :test #'string=))
            "a remainder entry is a candidate NOT among the sent items: ~a"
            (getf r :name))))))

(test the-cutoff-block-names-the-bands-a-tight-budget-clipped
  ;; DES-0046 D5. RENDER-CUTOFF reads the same :BANDS plist a REST caller does,
  ;; and prints a per-band line only when the bundle truncated. A bundle that
  ;; fit prints nothing after its first line.
  (let* ((f (make-k-fixture))
         (tight (render-context
                 (build-context (k-graph f) "change resolve-overlay" :budget 150)))
         (loose (render-context
                 (build-context (k-graph f) "change resolve-overlay" :budget 100000))))
    (is (search "neighbours" tight)
        "the clipped band is named in the cutoff block: ~a" tight)
    (is (search " sent" tight))
    (is (not (search "of what this walk found" loose))
        "a bundle that fit has nothing after its first cutoff line")))

(test what-was-sent-plus-what-was-withheld-is-what-an-unbounded-budget-sends
  ;; The identity the whole signal rests on, and the one an off-by-one breaks
  ;; without any reading finding it. Stated without naming a number, so the
  ;; fixture can change and the claim cannot.
  (let* ((f (make-k-fixture))
         (tight (build-context (k-graph f) "change resolve-overlay" :budget 150))
         (loose (build-context (k-graph f) "change resolve-overlay" :budget 100000)))
    (is (zerop (getf loose :withheld-items)) "nothing is withheld at this budget")
    (is (= (getf loose :tokens) (getf tight :found-tokens))
        "a tight bundle's :FOUND-TOKENS is what the same walk costs unbounded")
    (is (= (getf tight :found-tokens)
           (+ (getf tight :tokens) (getf tight :withheld-tokens)))
        "found is sent plus withheld, by construction")))

(test a-bundle-that-fits-withholds-nothing-and-says-so
  ;; The inert half, and it is what S1 could be checked against before the
  ;; tiers shared a budget: with room to spare the counts are zero rather than
  ;; absent, so a consumer reads them unconditionally.
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 100000)))
    (is (null (getf bundle :truncated)))
    (is (eql 0 (getf bundle :withheld-items)))
    (is (eql 0 (getf bundle :withheld-tokens)))
    (is (= (getf bundle :tokens) (getf bundle :found-tokens)))))

(test a-body-that-was-never-available-is-not-reported-as-withheld
  ;; WANTED is bounded by the seeds as well as by the count. A bundle with
  ;; fewer seeds than source slots withheld nothing -- there were fewer bodies
  ;; to carry -- and reporting the difference would send a caller to raise a
  ;; number that would buy them nothing.
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"
                                ;; A source plist, which is DEFINITION-SOURCE's
                                ;; shape: :status, :text, :range, :file.
                                :source-fn (lambda (id)
                                             (declare (ignore id))
                                             (list :status :current
                                                   :text "(defun x ())"
                                                   :range "1-1"
                                                   :file "src/lib.lisp"))
                                :source-definitions 50)))
    (is (eql 0 (getf bundle :withheld-bodies))
        "50 slots against a handful of seeds withholds nothing")
    (is (< (getf bundle :sourced) (getf bundle :source-definitions))
        "fewer bodies were carried than slots were offered")
    (is (eql 50 (getf bundle :source-definitions))
        "and the count asked for is still reported as asked for, so the
difference is visible without being called a withholding")))


;;; ------------------------------------------------------------------
;;; Provenance on the answer (REQ-0050 R1)
;;; ------------------------------------------------------------------

(test a-bundle-says-which-tree-it-was-built-from
  ;; REQ-0050 R1. A bundle is read into a session and worked from for an hour,
  ;; and it was the surface carrying no revision at all -- the context *record*
  ;; has carried the commit and diff hash since REQ-0036 R4, and a record is
  ;; Loom's bookkeeping rather than the caller's answer.
  (let ((text (render-context
               (build-context (k-graph (make-k-fixture)) "change resolve-overlay"
                              :provenance (list :commit "abc1234def567" :branch "main"
                                                :dirty nil :drift 0)))))
    (is (search "# index built from abc1234def56" text))
    (is (search "(main)" text))
    (is (search "current with the tree" text))))

(test a-bundle-whose-index-is-behind-says-so-and-by-how-much
  (let ((text (render-context
               (build-context (k-graph (make-k-fixture)) "change resolve-overlay"
                              :provenance (list :commit "abc1234def567" :branch "main"
                                                :dirty t :drift 3)))))
    (is (search "+ uncommitted edits" text))
    (is (search "3 claimed files have changed since" text))))

(test a-bundle-with-no-provenance-claims-none
  ;; Nothing invented for a caller that passed nothing. A bundle built by a
  ;; test or by a tool that never had a repository would otherwise claim a
  ;; freshness nobody measured, in the place it would be least visible.
  (let ((text (render-context
               (build-context (k-graph (make-k-fixture)) "change resolve-overlay"))))
    (is (not (search "index built from" text)))))

(test an-unreadable-commit-is-a-recorded-gap-on-a-bundle-too
  ;; CON-0001. Drift comes from REPOSITORY-STAMPS and answers on a tree with no
  ;; git in it, so the two halves fail independently and the readable one is
  ;; still reported.
  (let ((text (render-context
               (build-context (k-graph (make-k-fixture)) "change resolve-overlay"
                              :provenance (list :commit nil
                                                :commit-reason "not a git repository"
                                                :drift 0)))))
    (is (search "an unreadable commit -- not a git repository" text))
    (is (search "current with the tree" text))))

;;; ------------------------------------------------------------------
;;; The description band (REQ-0049 R1 and R3)
;;; ------------------------------------------------------------------

(defun k-documented-fixture ()
  "The shared fixture with a docstring on every function in it."
  (let ((f (make-k-fixture)))
    (setf (getp (k-resolve f) :documentation)
          "Resolve OVERLAY against the base view.
The second sentence, which is not the summary.")
    (setf (getp (k-compose f) :documentation)
          "Compose a view from the overlay and the base.")
    (setf (getp (k-reset f) :documentation)
          "Discard the overlay and start again.")
    f))

(defun k-documented-chain ()
  "A documented seed and a documented chain of callers leading away from it.

Built rather than borrowed from MAKE-K-FIXTURE, whose five entities are all
named for the overlay and are therefore all seeds of any task about it -- a
bundle with no neighbour band cannot show where the neighbour cut falls."
  (let ((seed   (k-def 'function-entity "parse-manifest" "src/a.lisp"
                       :documentation "Read the manifest at PATH.
The second sentence, which is not the summary."))
        (near   (k-def 'function-entity "checksum-blob" "src/a.lisp"
                       :documentation "A checksum over BLOB's octets."))
        (far    (k-def 'function-entity "hex-digits" "src/a.lisp"
                       :documentation "N as lowercase hexadecimal."))
        (g      (make-graph)))
    (dolist (e (list seed near far)) (add-entity g e))
    (k-edge g :calls seed near)
    (k-edge g :calls near far)
    g))

(test a-seed-carrying-its-body-does-not-also-carry-its-description
  ;; REQ-0049 R3. The description is the docstring's first sentence and the
  ;; body holds the whole docstring a few lines below it, so on an item with
  ;; both the band pays twice for one sentence. Measured on the tree:
  ;; `context refactor Loom to use utils where needed' printed a body for 5 of
  ;; its 8 seeds.
  (let* ((f (k-documented-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"
                                :budget 100000
                                :source-fn (lambda (id)
                                             (declare (ignore id))
                                             (list :status :current
                                                   :text "(defun resolve-overlay ())"
                                                   :range "41-53"
                                                   :file "src/workspace/overlay.lisp"))))
         (sourced (find-if (lambda (i) (getf i :source)) (getf bundle :items))))
    (is (not (null sourced)) "the source tier has to actually carry something")
    (is (string= "Resolve OVERLAY against the base view." (getf sourced :summary))
        "the item still carries it, for a REST or MCP consumer")
    (is (null (search "Resolve OVERLAY against the base view."
                      (loom-knowledge::render-item sourced)))
        "and the rendered text does not, because the body says it already")))

(test a-seed-with-no-body-carries-its-description
  (let* ((f (k-documented-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay" :budget 100000))
         (seed (find :seed (getf bundle :items) :key (lambda (i) (getf i :band)))))
    (is (search "Resolve OVERLAY against the base view." (loom-knowledge::render-item seed)))
    (is (null (search "The second sentence" (loom-knowledge::render-item seed)))
        "the first sentence, not the paragraph")))

(test the-cut-on-a-neighbours-description-is-its-walk-cost
  ;; REQ-0049 R3 asked whether the cut is a count or a cost and left it
  ;; unmeasured. A cost: the walk already orders the bundle by one, where a
  ;; count would take the first N neighbours of whichever seed was expanded
  ;; first.
  ;;
  ;; One neighbour on both sides of the cut rather than two neighbours on one
  ;; side each, so the assertion is about the cut and not about the fixture's
  ;; shape. CHECKSUM-BLOB is one outgoing :CALLS from the seed, which
  ;; *EDGE-COSTS* prices at 3.
  (flet ((rendered (cut)
           (let* ((*context-summary-cost* cut)
                  (bundle (build-context (k-documented-chain) "change parse-manifest"
                                         :budget 100000))
                  (item (find "checksum-blob" (getf bundle :items)
                              :key (lambda (i) (getf (getf i :entity) :name))
                              :test #'equal)))
             (is (not (null item)) "the neighbour has to be in the bundle at all")
             (is (eql 3 (getf item :cost)) "and to be where the cut is being tested")
             (loom-knowledge::render-item item))))
    (is (search "A checksum over BLOB's octets." (rendered 3))
        "a neighbour within the cut says what it is")
    (is (null (search "A checksum over BLOB's octets." (rendered 2)))
        "and one past it is skimmed on its name")))

(test the-description-band-is-charged-to-the-budget
  ;; The band is not free, and a bundle that printed it without paying for it
  ;; would overflow the budget by exactly the amount REQ-0040 exists to bound.
  ;; RENDER-ITEM is the costing function as well as the printing one, so this
  ;; holds by construction -- and it held by construction before PLAN-0045 S2
  ;; too, when the estimate was taken from the serialised plist and over-counted
  ;; the rendered line fivefold.
  (let ((with (let ((*context-summary-cost* 5))
                (build-context (k-documented-chain) "change parse-manifest"
                               :budget 100000)))
        (without (let ((*context-summary-cost* -1))
                   (build-context (k-documented-chain) "change parse-manifest"
                                  :budget 100000))))
    (is (> (getf with :tokens) (getf without :tokens))
        "descriptions cost tokens and the total says so")))

;;; ------------------------------------------------------------------
;;; The cutoff signal (PLAN-0045 S3/S4, DES-0042 D1 and D3)
;;; ------------------------------------------------------------------

(defun fat-source-fn (lines)
  "A source callback whose every body is LINES lines long."
  (lambda (id)
    (declare (ignore id))
    (list :status :current
          :text (format nil "~{~a~%~}"
                        (loop repeat lines collect "(some-fairly-long-form-of-source a b c)"))
          :range "1-1" :file "src/lib.lisp")))

(test the-budget-a-bundle-suggests-is-one-that-withholds-nothing
  ;; The whole claim the signal makes, and it is not the same as "what the walk
  ;; cost". The source tier is capped at *CONTEXT-SOURCE-SHARE* of the total, so
  ;; a bundle whose bodies are expensive needs a total large enough that the
  ;; share covers them. Measured while this was being written: a suggestion
  ;; computed as the walk's cost delivered 4 of 5 bodies and reported a fifth
  ;; still withheld, which is a false answer to the only question the number is
  ;; asked.
  (let* ((f (make-k-fixture))
         (tight (build-context (k-graph f) "change resolve-overlay"
                               :budget 400 :source-fn (fat-source-fn 40)))
         (suggested (getf tight :found-tokens))
         (again (build-context (k-graph f) "change resolve-overlay"
                               :budget suggested :source-fn (fat-source-fn 40))))
    (is-true (getf tight :truncated) "the tight budget has to actually bite")
    (is (zerop (getf again :withheld-items))
        "at the suggested budget no item is withheld")
    (is (zerop (getf again :withheld-bodies))
        "at the suggested budget no body is withheld either, which is the half
a suggestion computed from the walk's cost alone gets wrong")))

(test the-reported-token-count-covers-both-tiers
  ;; DES-0042's subject in one assertion. :TOKENS reported the index tier while
  ;; the source tier was exempt, so a bundle said 2477 of 4000 and handed the
  ;; caller 7777. Since the budget covers both, the number does.
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"
                                :budget 100000 :source-fn (fat-source-fn 20))))
    (is (plusp (getf bundle :source-tokens)) "the fixture has to carry bodies")
    (is (= (getf bundle :tokens)
           (+ (getf bundle :index-tokens) (getf bundle :source-tokens)))
        "the headline number is both tiers, not the cheaper one")))

(test a-body-that-does-not-fit-costs-its-body-and-not-its-seed
  ;; A seed the task named is what the bundle is for. Dropping it to save a
  ;; body would spend the answer on the illustration.
  (let* ((f (make-k-fixture))
         (roomy (build-context (k-graph f) "change resolve-overlay"
                               :budget 100000 :source-fn (fat-source-fn 40)))
         (tight (build-context (k-graph f) "change resolve-overlay"
                               :budget 900 :source-fn (fat-source-fn 40))))
    (is (< (getf tight :sourced) (getf roomy :sourced))
        "the tight budget carries fewer bodies")
    (is (plusp (getf tight :withheld-bodies)))
    (is (find "resolve-overlay" (getf tight :items)
              :key (lambda (i) (getf (getf i :entity) :name)) :test #'equal)
        "and the seed itself is still named")))

(test the-signal-claims-only-what-the-walk-found
  ;; The wording is the requirement. *CONTEXT-EXPANSION-HORIZON* bounds the
  ;; search before any budget is consulted, so a larger budget prints more of
  ;; what was reached and never more of what was searched. A line reading
  ;; "sends everything" would be a completeness claim about the graph.
  (let* ((f (make-k-fixture))
         (text (render-context (build-context (k-graph f) "change resolve-overlay"
                                              :budget 400
                                              :source-fn (fat-source-fn 40)))))
    (is (search "of what this walk found" text)
        "the claim is scoped to the walk, in those words")
    (is (null (search "sends everything" text)))))

(test a-bundle-that-fits-prints-no-cutoff-lines
  ;; Four lines of accounting on every answer would spend the budget this
  ;; exists to report.
  (let* ((f (make-k-fixture))
         (text (render-context (build-context (k-graph f) "change resolve-overlay"
                                              :budget 100000))))
    (is (null (search "of what this walk found" text)))
    (is (null (search "withheld" text)))))



;;; ------------------------------------------------------------------
;;; Who pays, and in what currency (BUG-0054)
;;; ------------------------------------------------------------------
;;;
;;; The budget was charged against RENDER-ITEM -- the text a console reader
;;; receives -- and honoured exactly for every caller, including the ones that
;;; receive something else. Measured on front-end 2026-08-27: `budget=6000'
;;; reported `tokens: 5988' and delivered 81,793 characters of JSON, which an
;;; MCP client refused.

(test item-cost-prices-the-console-rendering-unless-told-otherwise
  (let* ((f (make-k-fixture))
         (bundle (build-context (k-graph f) "change resolve-overlay"))
         (item (first (getf bundle :items))))
    (is-true item)
    (is (= (loom-knowledge::estimate-tokens (loom-knowledge::render-item item))
           (loom-knowledge::item-cost item))
        "the default is what it always was, so the console is unchanged")
    (let ((loom-knowledge::*context-item-cost* (lambda (i) (declare (ignore i)) 77)))
      (is (= 77 (loom-knowledge::item-cost item))
          "and a skin that delivers something else prices its own answer"))))

(test a-dearer-currency-buys-fewer-items-for-the-same-budget
  ;; The seam has to reach the truncation decision, not merely be readable.
  ;; A pricer charging ten times the console's must fill the same budget with
  ;; fewer items -- which is exactly what a JSON caller was not getting.
  (let* ((f (banded-fixture))
         (cheap (build-context (k-graph f) "change resolve-overlay" :budget 400))
         (dear (let ((loom-knowledge::*context-item-cost*
                       (lambda (item)
                         (* 10 (loom-knowledge::estimate-tokens
                                (loom-knowledge::render-item item))))))
                 (build-context (k-graph f) "change resolve-overlay" :budget 400))))
    (is (> (length (getf cheap :items)) (length (getf dear :items)))
        "cheap ~d items, dear ~d"
        (length (getf cheap :items)) (length (getf dear :items)))
    (is-true (getf dear :truncated)
             "and the dear bundle says it was cut rather than looking complete")))

(test the-reported-total-is-in-the-currency-that-was-charged
  ;; :TOKENS is what a caller compares against the budget it set. Reporting a
  ;; console total for a bundle priced in JSON would leave the number wrong in
  ;; the one place a caller reads it.
  (let* ((f (banded-fixture))
         (bundle (let ((loom-knowledge::*context-item-cost*
                         (lambda (item) (declare (ignore item)) 5)))
                   (build-context (k-graph f) "change resolve-overlay" :budget 400))))
    (is (= (* 5 (length (getf bundle :items))) (getf bundle :tokens))
        "~d items at 5 apiece against a reported ~d"
        (length (getf bundle :items)) (getf bundle :tokens))))


;;; BUG-0080. SEED-MATCHES looks prose up in a word table kept per graph change
;;; where it used to split every entity's prose on every query. The old
;;; function is kept here, verbatim in its logic, as the oracle: the two must
;;; return the same entities with the same ranks in the same order.

(defun reference-seed-matches (view origins types &key property-filters)
  (let ((hits  (make-hash-table :test #'eq))
        (order '())
        (frequencies '())
        (tokens (mapcar #'car origins)))
    (flet ((record (entity token rank)
             (unless (gethash entity hits)
               (push entity order))
             (push (cons token rank) (gethash entity hits))))
      (dolist (token tokens)
        ;; The length of this list is TOKEN's document frequency in this
        ;; repository -- taken on every query since REQ-0016 and discarded
        ;; until DES-0036 D1. Recorded before the type filter, because how
        ;; common a word is in a tree is a fact about the tree and not about
        ;; which types a caller asked for.
        (let ((reached (find-entities view :name-like token
                                        :property-filters property-filters)))
          (push (cons token (length reached)) frequencies)
        (dolist (entity reached)
          (when (or (null types) (member (entity-type entity) types))
            ;; MATCH-RANK, not ANALYZED-RANK. DES-0034 measured the analyzer
            ;; at 38 of 45 against 40, and its own closing line predicted why:
            ;; promoting an exact part match to 0 flattens the band that was
            ;; breaking ties between equal-coverage candidates, and nothing
            ;; else discriminates them. REQ-0046 first.
            (let ((rank (loom-knowledge::match-rank entity token)))
              (unless (= rank 3)
                (record entity token rank)))))))
      ;; The prose pass, second so that a name match wins the de-duplication
      ;; below: one entry per (entity, token) is what keeps SEED-SCORE's
      ;; coverage band a count of *distinct terms* rather than of matches.
      ;;
      ;; One walk over the entities rather than one per token, because the cost
      ;; here is splitting the prose and that should happen once per entity.
      ;; It is a linear scan and it is the second reason DES-0026 D4's inverted
      ;; index is worth building -- the first being that FIND-ENTITIES above is
      ;; already one.
      (dolist (entity (find-entities view :property-filters property-filters))
        (let ((prose (getp entity :documentation)))
          (when (and prose (or (null types) (member (entity-type entity) types)))
            (let ((words (make-hash-table :test #'equal)))
              ;; Whole words, per DES-0028 D4. Substring-matching "test"
              ;; against 549 KB of English across three trees finds "latest",
              ;; "contest" and "attestation", and the noise would arrive in
              ;; proportion to how much a project documented -- worst on the
              ;; trees that invested most in prose.
              (dolist (word (loom-knowledge::plain-words prose)) (setf (gethash word words) t))
              (dolist (token tokens)
                (when (and (gethash token words)
                           (not (assoc token (gethash entity hits) :test #'string=)))
                  (record entity token :prose))))))))
    (values (loop for entity in (nreverse order)
                  collect (cons entity (nreverse (gethash entity hits))))
            (nreverse frequencies))))

(defparameter *prose-vocabulary*
  '("cache" "widget" "stop" "fixture" "overlay" "base" "view" "resolve" "digest"
    "manifest" "checksum" "stale" "retry" "parse" "emit" "render"))

(defun prose-fixture-graph (count)
  "COUNT functions, each with a docstring of words chosen by arithmetic from a
fixed vocabulary, so that the tokens of a task meet many of them."
  (let ((graph (make-graph))
        (size (length *prose-vocabulary*)))
    (dotimes (i count graph)
      (add-entity graph
                  (k-def 'function-entity (format nil "fn-~d" i)
                         (format nil "src/f~d.lisp" (mod i 7))
                         :documentation
                         (format nil "~{~a~^ ~}."
                                 (loop for j below 5
                                       collect (nth (mod (+ (* i 3) (* j 5) (floor i 4)) size)
                                                    *prose-vocabulary*))))))))

(defun same-seed-matches-p (graph task &key types property-filters)
  (let ((origins (loom-knowledge::task-token-origins task)))
    (equal (multiple-value-list
            (loom-knowledge::seed-matches graph origins types
                                          :property-filters property-filters))
           (multiple-value-list
            (reference-seed-matches graph origins types
                                    :property-filters property-filters)))))

(test prose-matches-through-the-word-table-are-those-of-the-walk
  (let ((graph (prose-fixture-graph 120)))
    (dolist (task '("cache widget" "stop the fixture overlay" "resolve digest manifest checksum"
                    "nothing here matches" "render emit parse retry stale"))
      (is-true (same-seed-matches-p graph task) "~a" task))
    (is-true (same-seed-matches-p graph "cache widget" :types '(:function)))
    (is-true (same-seed-matches-p graph "cache widget"
                                  :property-filters '(:file "src/f3.lisp")))))

(test the-word-table-follows-the-graph-when-it-changes
  ;; The cache is keyed to the graph's generation. A table that outlived a
  ;; change would answer for the graph as it was.
  (let ((graph (prose-fixture-graph 30)))
    (is-true (same-seed-matches-p graph "zebra crossing"))
    (add-entity graph (k-def 'function-entity "late" "src/late.lisp"
                             :documentation "A zebra crossing, added afterwards."))
    (is-true (same-seed-matches-p graph "zebra crossing"))
    (is (find "late" (mapcar (lambda (pair) (name (car pair)))
                             (loom-knowledge::seed-matches
                              graph (loom-knowledge::task-token-origins "zebra crossing") nil))
              :test #'string=)
        "an entity added after the table was built was not found")
    (let ((late (find "late" (all-entities graph) :key #'name :test #'string=)))
      (setf (stale-p late) t))
    (remove-entity graph (id (find "fn-3" (all-entities graph) :key #'name :test #'string=)))
    (is-true (same-seed-matches-p graph "cache widget zebra"))))

(test the-word-table-is-built-once-per-change-and-not-once-per-query
  ;; BUG-0080. Without it every query split every entity's prose again.
  (let ((graph (prose-fixture-graph 20)))
    (let ((first (loom-knowledge::prose-word-index graph)))
      (loom-knowledge::seed-matches graph (loom-knowledge::task-token-origins "cache widget") nil)
      (is (eq first (loom-knowledge::prose-word-index graph))
          "a query rebuilt the word table though the graph had not changed")
      (add-entity graph (k-def 'function-entity "extra" "src/x.lisp" :documentation "more words"))
      (is (not (eq first (loom-knowledge::prose-word-index graph)))
          "the word table survived a change to the graph"))))
