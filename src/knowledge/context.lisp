;;;; Context building -- SS11's loom_context.
;;;;
;;;; "loom_context is the tool that directly attacks the original problem
;;;; statement -- tokens wasted re-reading the same code."
;;;;
;;;; SS11 specifies both the algorithm and the discipline. The algorithm: "seed
;;;; entities from the task text via name matching, expand one hop, include
;;;; non-stale decisions touching those entities, truncate to budget." The
;;;; discipline: "it should be instrumented from day one: logging what agents
;;;; asked for and what they got is exactly the feedback that tells us whether
;;;; the graph is earning its keep." Both are here, and the second is the more
;;;; important of the two -- a context tool nobody can measure is a context
;;;; tool nobody can improve.

(in-package :loom-knowledge)

;;;; ==================================================================
;;;; Budget
;;;; ==================================================================

(defparameter *context-token-budget* 4000
  "Tokens the index tier may spend. DES-0026 D3, PLAN-0032 S3.

Was 2000, and 2000 was right for the bundle it was sized for -- one carrying
names and locations. REQ-0016 argued explicitly that the budget was not the
defect, and under a names-only bundle that was true: ~1960 of 2000 was being
spent on the wrong entities, which is a selection problem.

It stopped being true twice over. A padded source block is 200-600 tokens, so
under *CONTEXT-SOURCE-DEFINITIONS* a single pot of 2000 holds three to eight
definitions and nothing else. And PLAN-0032 S1 measured the other half: the
cost-ordered walk reaches 157 entities on `context data-handler` and the old
budget printed 2 of them, so REQ-0016 R6 was failing on room rather than on
reach.

An index-tier line costs 15-30 tokens, so 4000 holds well over a hundred of
them. That is CON-0006's asymmetry bought cheaply: the reader discards a wrong
line for almost nothing and cannot recover from a missing one without the grep
this whole tool exists to remove.")

(defparameter *context-source-definitions* 5
  "How many entities carry their source. DES-0026 D2.

A count of definitions rather than a token figure, because that is the unit a
caller reasons in -- \"show me the five things this is about\" -- and a token
count for it is a consequence rather than a choice.

Five is a judgement and the shape of the trade is what argues it: source is the
expensive tier and the index tier is what makes being wrong about the order
cheap. A caller who wanted the sixth entity's body spends one `describe`, which
is the failure DES-0026 D2 says a wrong ranking costs. Raising this buys fewer
`describe` calls and spends tokens on bodies the reader may not want.")

;; The other budget in this system is *SUMMARY-TOKEN-BUDGET* (120), in
;; services.lisp -- one document's summary rather than a bundle of entities.
;; It lives there rather than here because services.lisp compiles first and
;; DOCUMENT-SUMMARY reads it; see the section comment beside it.

(defun estimate-tokens (string)
  "A rough token count for STRING: four characters to the token.

Deliberately crude. Loom has no tokenizer and should not grow one to spend a
budget approximately -- the number exists to stop a bundle running away, not
to fill it exactly. Swap this for a real count when a caller needs the budget
honoured to the token."
  (ceiling (length string) 4))

;;;; ==================================================================
;;;; Seeding from task text
;;;; ==================================================================

(defparameter *context-stopwords*
  '("the" "and" "for" "with" "that" "this" "from" "into" "when" "what" "which"
    "add" "new" "use" "using" "make" "get" "set" "fix" "change" "update" "code"
    "function" "class" "file" "test" "tests" "should" "would" "need" "needs"
    "want" "please" "can" "does" "how" "why" "where" "are" "was" "will" "not"
    "its" "have" "has" "had" "them" "they" "then" "than")
  "Words too common to be worth matching an entity name against.
Not a language model -- just enough that \"how does the drawing tool work\"
seeds on \"drawing\" and \"tool\" rather than on \"does\" and \"work\".")

(defun stem-variants (word)
  "WORD's plausible uninflected forms, or NIL.

Not a stemmer in the Porter sense and deliberately not one. Four suffixes cover
the inflections that appear in task descriptions -- saving a piece design,
changing the type, edited layers, reporting rejections -- and a full stemmer
would also fold identifiers this index depends on keeping apart.

Variants are *added* to the token set rather than replacing the word, so nothing
can be lost by a wrong guess: a stem corresponding to no real term simply never
matches. That is why SAVING emits both SAV and SAVE instead of picking one --
dropping -ing gives SAV, which matches nothing, and the -e restoration is what
reaches SAVEDESIGN.

The minimum lengths stop the rules eating short identifiers: -ing needs six
characters so RING survives, and -s needs four and refuses a double so CLASS and
ADDRESS survive."
  (let ((n (length word))
        (out '()))
    (flet ((ends (suffix)
             (let ((k (length suffix)))
               (and (> n k) (string= suffix word :start2 (- n k))))))
      (when (and (ends "ies") (>= n 5))
        (push (concatenate 'string (subseq word 0 (- n 3)) "y") out))
      (when (and (ends "s") (>= n 4) (not (ends "ss")) (not (ends "ies")))
        (push (subseq word 0 (1- n)) out))
      (when (and (ends "ing") (>= n 6))
        (push (subseq word 0 (- n 3)) out)
        (push (concatenate 'string (subseq word 0 (- n 3)) "e") out))
      (when (and (ends "ed") (>= n 5))
        (push (subseq word 0 (- n 2)) out)
        (push (concatenate 'string (subseq word 0 (- n 2)) "e") out)))
    out))

(defun task-tokens (task)
  "The candidate identifiers in TASK: words and hyphenated or underscored
compounds, lowercased, three characters or more, stopwords dropped.

Compounds are kept whole *and* split, so \"impact-set\" seeds on the exact
name and, failing that, on \"impact\"."
  (let ((tokens '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((word (string-downcase (get-output-stream-string current))))
               (when (and (>= (length word) 3)
                          (not (member word *context-stopwords* :test #'string=)))
                 (pushnew word tokens :test #'string=)
                 ;; a compound also seeds on its parts
                 (let ((start 0))
                   (dotimes (i (1+ (length word)))
                     (when (or (= i (length word))
                               (member (char word i) '(#\- #\_)))
                       (let ((part (subseq word start i)))
                         (when (and (>= (length part) 3)
                                    (not (member part *context-stopwords* :test #'string=)))
                           (pushnew part tokens :test #'string=)))
                       (setf start (1+ i)))))))))
      (loop for char across task
            do (if (or (alphanumericp char) (member char '(#\- #\_ #\* #\%)))
                   (write-char char current)
                   (finish))
            finally (finish)))
    ;; Inflections last. "saving a piece design" reaches SAVEDESIGN, which it
    ;; could not while SAVING and SAVE were unrelated strings -- that entity was
    ;; the one measured gain of two reverted attempts to replace this function
    ;; with a postings index, and it was never the index that gained it.
    ;;
    ;; Added rather than substituted, so a wrong guess costs nothing: a stem
    ;; matching no name simply never matches. The stopword filter is not
    ;; re-applied to a variant, because a variant of a word that passed the
    ;; filter is a word the caller wrote.
    (dolist (token (copy-list tokens))
      (dolist (variant (stem-variants token))
        (pushnew variant tokens :test #'string=)))
    (nreverse tokens)))

(defun task-terms (task)
  "The task's words as written: compounds intact, stopwords kept.

What REQ-0016 R1 means by a query *naming* an entity. TASK-TOKENS is the
wrong list to ask, because it also returns the parts it split compounds into,
and those are Loom's own manufacture rather than anything the caller typed:
\"data-handler\" splits to \"data\", game-server has five slot accessors named
exactly DATA, and promoting them for an exact match would be promoting on the
strength of Loom's guess about what the caller might have meant."
  (let ((terms '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((word (string-downcase (get-output-stream-string current))))
               (when (plusp (length word))
                 (pushnew word terms :test #'string=)))))
      (loop for char across task
            do (if (or (alphanumericp char) (member char '(#\- #\_ #\* #\%)))
                   (write-char char current)
                   (finish))
            finally (finish)))
    terms))

(defun slot-accessor-p (entity)
  "True when ENTITY is an accessor the analyzer synthesised from a slot.

A DEFCLASS or DEFINE-CONDITION slot declaring :accessor NAME mints an
:INTERFACE carrying :GENERATED-BY, the class it came from -- so this is a fact
the graph holds rather than a guess about a name. It matters to R1 because
such a name is often short, common and defined once per class that happens to
use it: game-server has five DATA accessors in five files, and on the query
`data-handler' they took five of the eight seeds by matching a fragment
exactly. The class they hang off is the better seed and the neighbour band
reaches them through it.

Only :INTERFACE. A :FUNCTION with :GENERATED-BY came from a definer macro,
which in a tree that leans on definer macros is the API itself."
  (and (eq :interface (entity-type entity))
       (getp entity :generated-by)
       t))

(defparameter *test-path-segments* '("test" "tests")
  "Path segments that mark a definition as test code, for ranking only.

Loom has one notion of test code and it is the :TEST entity type -- a `test'
form the analyzer recognised. That is not the population REQ-0016 R4 is about:
game-server's CHECK-OK-RESPONSE and ENCODE-TEST-OBJ are ordinary :FUNCTIONs
that happen to live in test/, and they are exactly what crowded out the
production code the query asked for.

So this is a path guess, and this project has been burned by one before --
BUG-0006 derived an entity's :SYSTEM from its path, every file in the tree
read as system \"src\", and every layering rule matched nothing until DES-0009
replaced it with the file's own package name. The difference worth stating is
what a wrong answer costs. A wrong :SYSTEM is a fact asserted into the graph
and read by rules; a wrong answer here moves one candidate down one band in
one bundle, and is invisible to every other query. Ranking may guess where
assertion may not.

Whole segments only, split on /, - and . -- so data-api/test/fixture.lisp and
connection-test.lisp both match while latest-config.lisp does not.")

(defparameter *seed-term-share* 2
  "How many distinct names one slice of the task may contribute as seeds.

A judgement rather than a measurement, and it needs no scaling with how common
a term is: a slice with fewer than two names never reaches the cap, so a rare
word is untouched by it while a common one has its contribution held to the
same two however many hundred entities it matches. That is REQ-0016 R7's
\"proportionately less\" expressed as a share rather than as a weight, and a
share is the form that does not need a tuned constant per tree.

Advisory: ADMIT-SEEDS relaxes it rather than return fewer seeds than there are
candidates.")

(defun seed-matches (view tokens types)
  "How TOKENS meet the index: an alist of (entity . ((token . rank) ...)).

In the order the entities were first reached, so a bundle does not reorder
itself between two calls over one index -- the old seeder's ties fell to a
PUSHNEW accumulator, which put the *last* word of the task first and is half
of why a trailing \"check\" was so expensive.

Rank 3 is dropped rather than recorded. FIND-ENTITIES matches a path component
as readily as a name, and a token that reached an entity only through its path
is neither a seed nor evidence about the token.

A rank of :PROSE is a match in the entity's :DOCUMENTATION rather than in its
name (REQ-0035 R4, DES-0028). It is a keyword and not a fourth integer because
the two are not points on one scale -- a name match is evidence an author chose
that word *for this thing*, and a prose match is evidence they used it while
explaining it. SEED-SCORE bands them separately for that reason."
  (let ((hits  (make-hash-table :test #'eq))
        (order '()))
    (flet ((record (entity token rank)
             (unless (gethash entity hits)
               (push entity order))
             (push (cons token rank) (gethash entity hits))))
      (dolist (token tokens)
        (dolist (entity (find-entities view :name-like token))
          (when (or (null types) (member (entity-type entity) types))
            (let ((rank (match-rank entity token)))
              (unless (= rank 3)
                (record entity token rank))))))
      ;; The prose pass, second so that a name match wins the de-duplication
      ;; below: one entry per (entity, token) is what keeps SEED-SCORE's
      ;; coverage band a count of *distinct terms* rather than of matches.
      ;;
      ;; One walk over the entities rather than one per token, because the cost
      ;; here is splitting the prose and that should happen once per entity.
      ;; It is a linear scan and it is the second reason DES-0026 D4's inverted
      ;; index is worth building -- the first being that FIND-ENTITIES above is
      ;; already one.
      (dolist (entity (find-entities view))
        (let ((prose (getp entity :documentation)))
          (when (and prose (or (null types) (member (entity-type entity) types)))
            (let ((words (make-hash-table :test #'equal)))
              ;; Whole words, per DES-0028 D4. Substring-matching "test"
              ;; against 549 KB of English across three trees finds "latest",
              ;; "contest" and "attestation", and the noise would arrive in
              ;; proportion to how much a project documented -- worst on the
              ;; trees that invested most in prose.
              (dolist (word (plain-words prose)) (setf (gethash word words) t))
              (dolist (token tokens)
                (when (and (gethash token words)
                           (not (assoc token (gethash entity hits) :test #'string=)))
                  (record entity token :prose))))))))
    (loop for entity in (nreverse order)
          collect (cons entity (nreverse (gethash entity hits))))))

(defun prose-only-p (matches)
  "True when every one of MATCHES came from prose rather than from a name.

The test is `only', not `any'. An entity whose name answered to one term and
whose prose answered to four is not a prose-only candidate -- it is a name match
with corroboration, and demoting it would punish the documentation."
  (every (lambda (m) (eq :prose (cdr m))) matches))

(defun best-name-rank (matches)
  "The best MATCH-RANK among MATCHES, or 3 when every match came from prose.

3 rather than an error, because the band this feeds is about how well a *name*
matched and a prose-only candidate has no answer to give -- it is already
separated by PROSE-ONLY-P one band above."
  (let ((ranks (remove :prose (mapcar #'cdr matches))))
    (if ranks (reduce #'min ranks) 3)))

(defun plain-words (string)
  "STRING split into whole words at every non-alphanumeric character, lowercased.

Used on a path and on the raw task alike, which is why the separator set is
\"everything else\" rather than the punctuation a path happens to use:
data-api/test/fixture.lisp yields TEST, and so must \"rework the test
fixture\". Splitting a path on /-. alone was enough for the first and silently
made the second one long word."
  (let ((words '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((word (string-downcase (get-output-stream-string current))))
               (when (plusp (length word)) (push word words)))))
      (loop for char across string
            do (if (alphanumericp char)
                   (write-char char current)
                   (finish))
            finally (finish)))
    words))

(defun test-code-p (entity)
  "True when ENTITY looks like test code: a :TEST, or defined under a test path.
The type is the fact and the path is the guess; see *TEST-PATH-SEGMENTS*."
  (or (eq :test (entity-type entity))
      (let ((path (or (getp entity :file)
                      (and (slot-boundp entity 'origin-file) (origin-file entity)))))
        (and path
             (intersection (plain-words path) *test-path-segments*
                           :test #'string=)
             t))))

(defun production-names (matches)
  "The names among MATCHES that some non-test candidate carries.

What keeps REQ-0016 R4 from eating R8. R4 demotes test code so that fixtures
stop displacing the definitions a task asked about -- but two of the three
CONNECTION-CONNECT-DATABASE definitions R8 protects live in test files, and
demoting those does not remove a fixture from the bundle, it removes the
evidence that one name is defined in three places. A test definition sharing
its name with a production one is not a fixture competing for the slot; it is
part of what the seed is telling you about that name."
  (let ((table (make-hash-table :test #'equalp)))
    (dolist (pair matches table)
      (unless (test-code-p (car pair))
        (setf (gethash (significant-name (car pair)) table) t)))))

(defun task-wants-tests-p (task)
  "True when TASK asks about tests, so R4's demotion must not fire.

Whole words, because \"the latest handler\" is not a question about tests.
Read off the raw task rather than off TASK-TOKENS, which drops \"test\" as a
stopword -- it is too common to *match a name* against and is perfectly good
evidence of what the caller wants."
  (intersection (plain-words task) '("test" "tests" "testing" "fixture" "fixtures")
                :test #'string=))

(defun named-by-task-p (entity matches terms)
  "True when the task named ENTITY: it matched one of TERMS exactly.

A rank-0 match is a name equal to the token, and TERMS is the task's own words
rather than TASK-TOKENS' -- so the match has to be on something the caller
wrote. A slot accessor is excluded whatever it matched; SLOT-ACCESSOR-P says
why."
  (and (not (slot-accessor-p entity))
       ;; EQL rather than ZEROP: a prose match's rank is the keyword :PROSE,
       ;; and naming is about a name. An author who used a word in a paragraph
       ;; did not thereby name the thing after it.
       (find-if (lambda (m) (and (eql 0 (cdr m))
                                 (member (car m) terms :test #'string=)))
                matches)
       t))

(defun demoted-test-p (entity demote-tests production)
  "True when ENTITY is test code that R4 should rank below production code.
Exempt when a non-test candidate carries the same name; PRODUCTION-NAMES says
why."
  (and demote-tests
       (test-code-p entity)
       (not (gethash (significant-name entity) production))))

(defun seed-score (entity matches &key demote-tests terms production)
  "Sort key for one candidate seed, lower first: type, then coverage, then match.

Coverage -- how many of the task's distinct terms this name answers to -- is
the signal the original ranking had no way to express. It scored an entity by
the *best* of its matches, and a best is the same number whether one term
produced it or five, so an entity matching one common word tied with the
entity matching half the sentence and the tie fell to whatever order the
tokens happened to be in. On a task described in prose that is the whole
defect: measured on game-server, \"start-server startup sequence and database
handler health check\" seeded seven of its eight entities on the English word
\"check\" (REQ-0016 R7).

The bands are separated rather than blended, widest first:

  type       *SEED-TYPE-PREFERENCE*, now three tiers rather than fifteen.

  named      the task named this entity, as a whole word it wrote. REQ-0016
             R1: \"a query naming an entity that exists must seed from that
             entity\".

             Below type, and that is load-bearing rather than arbitrary. R1's
             defect was a type band outranking an exact name, so the obvious
             repair is to put naming on top -- and measured, it hands a bundle
             to whatever container shares a word with the task. `context
             data-api handler database connection acquire and test
             connectivity' then seeded the DATA-API package, data-api.asd,
             three more files, and one lone definition, because a file's
             SIGNIFICANT-NAME is its basename and \"connectivity\" names
             connectivity.lisp exactly. What R1 actually needed was the type
             band to stop ordering *definitions* among themselves, which the
             tiers above now do; a class and a function tie there, so naming
             decides between them without ever lifting a directory listing
             over code.

  accessor   SLOT-ACCESSOR-P. A name a slot declaration synthesised is worth
             less as a seed than any definition someone wrote, because it is
             usually short, usually common, and defined once per class that
             happens to use the word: five DATA accessors in five files on
             game-server. Excluded from `named' as well, so this band is what
             stops them winning on an exact match rank instead.

  test       REQ-0016 R4: test code ranks below production code that matched
             the same task, unless the task asked about tests. Beneath type,
             so a production *file* never outranks a test *function* -- R4 is
             about fixtures displacing definitions, and a directory listing
             displaces both.

  coverage   how many of the task's distinct terms this name answers to. The
             signal the original ranking had no way to express: it scored an
             entity by the *best* of its matches, and a best is the same
             number whether one term produced it or five, so an entity
             matching one common word tied with the entity matching half the
             sentence and the tie fell to whatever order the tokens happened
             to be in. Measured on game-server, \"start-server startup
             sequence and database handler health check\" seeded seven of its
             eight entities on the English word \"check\" (REQ-0016 R7).

  prose      REQ-0035 R4, DES-0028 D5. The task matched this entity's
             :DOCUMENTATION and never its name.

             Below coverage, and that placement is the whole of what REQ-0035
             buys. Measured on this tree before the change, `context stop a
             fixture displacing the definitions a task asked about' returned
             STOP-JS-CHILD, STOP-SERVER and FIXTURE-ROOT -- each seeded on one
             English word -- while PRODUCTION-NAMES and DEMOTED-TEST-P, whose
             docstring is where that sentence comes from, appeared nowhere.
             PRODUCTION-NAMES answers to five of the task's terms through its
             prose and STOP-SERVER to one through its name; coverage is what
             separates five from one. A prose band *above* coverage would rank
             STOP-SERVER first again and would have shipped the defect it was
             written to remove.

             `Only', not `any': an entity whose name matched one term and whose
             prose matched four is a name match with corroboration, and
             demoting it would punish the documentation.

             An entity with no prose at all is not in this band and scores
             exactly as it did before (REQ-0035 R7). On game-server 86% of
             functions carry no docstring, and ranking undocumented code below
             documented code would be a recall defect on the tree the
             requirement is measured against.

  match      quality of the best match, which is what keeps a single-term task
             ranked exactly as it was: every candidate then has coverage 1 and
             that band cancels."
  (+ (* 1000000 (seed-type-rank entity))
     (*  100000 (if (named-by-task-p entity matches terms) 0 1))
     (*   10000 (if (slot-accessor-p entity) 1 0))
     (*    1000 (if (demoted-test-p entity demote-tests production) 1 0))
     (*     100 (max 0 (- 8 (length matches))))
     (*      10 (if (prose-only-p matches) 1 0))
     (best-name-rank matches)))

(defun seed-slice (matches)
  "The slice of the task a seed answers to: its matched terms, sorted.
The key the share in ADMIT-SEEDS is counted against."
  (format nil "~{~a~^ ~}" (sort (mapcar #'car matches) #'string<)))

(defun admit-seeds (ranked limit)
  "The first LIMIT entities of RANKED, holding back a slice past its share.

The cap is a filter on the way in rather than another term in the score,
because it is a property of the set being built and not of any candidate in
it: whether a seventh \"check\" is worth admitting depends entirely on whether
anything else is still waiting.

What it counts against is the *set* of terms a seed answers to, and what it
counts is names rather than entities. Both halves were measured rather than
reasoned to, and each fixes what the simpler rule got wrong:

  Charging each seed to one term -- its narrowest -- cost REQ-0016 R8's query
  one of the three CONNECTION-CONNECT-DATABASE definitions, the one in
  server/server.lisp. Three files defining one name is the finding that query
  exists to produce, and a cap counting entities destroys it. Counting names
  does not: they are one name, so they are one charge.

  Exempting anything that answered to more than one term let five members of
  the CHECK-DATABASE-* family take five of eight slots, because they all match
  {check, database} and nothing capped a pair of words the way a single word
  was capped. A family sharing a slice is the same crowding as a family
  sharing a word.

Relaxed rather than enforced. When the held-back candidates are all there is
they are admitted in score order, so a task naming one thing still seeds on
that thing as many times as the tree offers and a small tree behaves exactly
as it did before the cap existed."
  (let ((spent  (make-hash-table :test #'equal))
        (chosen '())
        (held   '())
        (taken  0))
    (dolist (pair ranked)
      (when (< taken limit)
        (let* ((slice (seed-slice (cdr pair)))
               (names (gethash slice spent))
               (name  (significant-name (car pair))))
          (cond ((or (< (length names) *seed-term-share*)
                     (member name names :test #'string-equal))
                 (pushnew name (gethash slice spent) :test #'string-equal)
                 (incf taken)
                 (push (car pair) chosen))
                (t (push (car pair) held))))))
    (setf chosen (nreverse chosen)
          held   (nreverse held))
    (append chosen (subseq held 0 (min (- limit taken) (length held))))))

(defun seed-entities (view task &key (limit 8) types)
  "Entities whose names the words of TASK point at, best match first.

The naive half of SS11's \"first implementation is simple\", and the half most
obviously worth replacing: name matching finds RESOLVE-OVERLAY from the word
\"overlay\" and finds nothing at all from \"the bit that merges edits\".
Semantic seeding is what Qdrant is for in the target architecture.

Naive, but since REQ-0016 R7 no longer indifferent to *which* word did the
matching. A task described in prose carries words -- \"check\", \"handler\",
\"value\", \"create\" -- that name something in almost any codebase, so
matching on one of them is not evidence about the task, and lexical seeding
therefore gets worse as a query gets longer and more descriptive rather than
better. Two things follow and both are here: coverage outranks match quality
(SEED-SCORE), and no single term fills the set while another has a candidate
waiting (ADMIT-SEEDS)."
  ;; Type preference outranks match quality -- the reverse of what
  ;; SEARCH-ENTITIES does, and deliberately so. loom_find answers "where is
  ;; this thing", where an exactly-named file is the right answer. A context
  ;; bundle answers "what should I know before editing", where a function
  ;; matched loosely is worth more than a file matched exactly: the file's
  ;; neighbourhood is a directory listing, the function's is the code that
  ;; will break.
  (let* ((demote-tests (not (task-wants-tests-p task)))
         (terms      (task-terms task))
         (matches    (seed-matches view (task-tokens task) types))
         (production (production-names matches))
         (ranked     (stable-sort matches #'<
                                  :key (lambda (pair)
                                         (seed-score (car pair) (cdr pair)
                                                     :demote-tests demote-tests
                                                     :terms terms
                                                     :production production)))))
    (admit-seeds ranked limit)))

;;;; ==================================================================
;;;; Instrumentation (SS11)
;;;; ==================================================================

(defstruct (context-log-entry (:conc-name context-log-))
  "One answered context request: what was asked, and what came back."
  (at (get-universal-time))
  (task "")
  (seeds 0)
  (entities 0)
  (budget 0)
  (tokens 0))

(defvar *context-log* '()
  "Answered context requests, most recent first.

SS11 asks for this from day one. It is the only evidence that will settle
whether the graph is earning its keep: a log full of requests that seeded on
nothing says name matching is not enough, and a log of bundles that never
approach their budget says the expansion is too timid.")

(defun clear-context-log ()
  (setf *context-log* '())
  (values))

(defun context-log-summary ()
  "The log as plain data: how many requests, how many found nothing, and how
much of the budget a bundle typically used."
  (let ((n (length *context-log*)))
    (list :requests n
          :seeded-nothing (count 0 *context-log* :key #'context-log-seeds)
          :mean-entities (if (zerop n) 0
                             (round (reduce #'+ *context-log* :key #'context-log-entities)
                                    n))
          :mean-budget-used
          (if (zerop n) 0
              (round (* 100 (/ (reduce #'+ *context-log* :key #'context-log-tokens)
                               (max 1 (reduce #'+ *context-log* :key #'context-log-budget)))))))))

;;;; ==================================================================
;;;; The bundle
;;;; ==================================================================

(defparameter *governing-types* '(:decision :design :architecture :rule :concept)
  "Document types whose claim on code is to govern it.

CON-0004's distinction, and the same one *GOVERNING-DOCUMENT-TYPES* draws in
loom-graph one system down: a decision or a design says how that code is
shaped, while a requirement asks for it, a plan sequences it and a bug reports
on it. Named here rather than written inline because DOCUMENTS-TOUCHING now
tests it once instead of using it as the whole filter.")

(defparameter *declared-document-edges* '(:decides :applies-to :documents)
  "Edges that exist because an author wrote a field.

:DECIDES from a decision's or design's affects:, :APPLIES-TO from a rule's,
:DOCUMENTS from a requirement's, plan's or bug's affects: and from an
architecture document's describes:. Every one of them resolved against the
index when it was written and is reported by `check' when it rots.

The markdown analyzer cannot produce any of them -- it has no field to read one
from and emits :MENTIONS alone (REQ-0014, DES-0016). That is what makes the
edge a stronger test than the entity type: a declared edge means a human
claimed this document bears on this code, and no amount of prose can
manufacture one.")

(defparameter *context-mention-limit* 5
  "Most prose-mention documents to admit to one bundle.

A cap, for *CONTEXT-RELATION-LIMIT*'s reason and a sharper version of it. Since
REQ-0014 every backticked identifier in every markdown file earns a :MENTIONS
edge, so the mention band is unbounded in a way the others are not -- the
documents band is as large as the number of authors who declared something,
which is small and self-limiting. Ranked before it is capped, so this is the
tail that gets dropped rather than an arbitrary five.")

(defun mention-rank (view document entities)
  "How many of ENTITIES DOCUMENT names. DES-0020 D4's ranking.

The discriminator that makes the mention band worth having at all: a document
naming many of the entities a task reached is more likely to be about that task
than one that backticked a single name in passing. Measured rather than
guessed, and measured from edges that are already in the index -- the
alternative, *MENTION-CONFIDENCE*, is a constant for every mention edge there
is, so ranking by it would produce an arbitrary order wearing a number that
made it look principled."
  (let ((ids (mapcar #'id entities)))
    (count-if (lambda (n) (member (id (neighbor-entity n)) ids :test #'equal))
              (neighbors view (id document) :rel-types '(:mentions) :direction :out))))

(defun documents-touching (view entities)
  "Three values: the decisions, documents and prose mentions bearing on ENTITIES.

The part of a bundle that cannot be recovered by reading the source, and so the
part most worth the tokens: why the code is the way it is.

Banded by the edge each document arrived on rather than by its entity type,
which is DES-0020 and the fix for REQ-0026. The type cannot tell a requirement
declaring affects: from a README that backticked a name, because REQ-0014
deliberately types both as :DOCUMENT -- a markdown file must never be a REQ or
a DEC, since directory-names-the-type is this tree's convention and not a fact
about markdown. The edge tells them apart exactly: see
*DECLARED-DOCUMENT-EDGES*.

The old version collected over these same four edge types and then kept only
the five governing types, so a requirement, plan, bug report or review -- all
of which are :DOCUMENT -- was collected and thrown away, and on a tree whose
documents are all markdown every one of them was. What it discarded to make
that mistake possible was the NEIGHBOR struct: by the time the filter ran, the
edge was gone and the type was all that was left to test.

Strongest band wins, assigned per document rather than per edge, so a design
reached by both a :DECIDES and a :MENTIONS is a decision and appears once. The
first band is the old behaviour exactly, mentions included -- a governing type
reached only by a backtick in someone's prose still lands there, which is what
walking :MENTIONS was always for. So nothing that reached a bundle before
stops reaching one."
  (let ((declared (make-hash-table :test #'equal))   ; id -> entity, any declared edge
        (mentioned (make-hash-table :test #'equal))  ; id -> entity, :MENTIONS only
        (order '()))
    (dolist (entity entities)
      (dolist (n (neighbors view (id entity)
                            :rel-types (cons :mentions *declared-document-edges*)
                            :direction :in))
        (let ((other (neighbor-entity n)))
          (unless (stale-p other)
            (pushnew other order)
            (if (member (rel-type (neighbor-relationship n)) *declared-document-edges*)
                (setf (gethash (id other) declared) other)
                (setf (gethash (id other) mentioned) other))))))
    (let ((decisions '()) (documents '()) (mentions '()))
      (dolist (other (nreverse order))
        (cond ((member (entity-type other) *governing-types*) (push other decisions))
              ((gethash (id other) declared)                  (push other documents))
              ((gethash (id other) mentioned)                 (push other mentions))))
      (values (nreverse decisions)
              (nreverse documents)
              ;; Ranked, then capped. Ties break on name so that two runs over
              ;; one index agree -- without it the order follows whatever the
              ;; graph yielded, which is the arbitrary answer that looks
              ;; definite.
              (let ((ranked (sort (nreverse mentions)
                                  (lambda (a b)
                                    (let ((ra (mention-rank view a entities))
                                          (rb (mention-rank view b entities)))
                                      (if (= ra rb)
                                          (string< (princ-to-string (name a))
                                                   (princ-to-string (name b)))
                                          (> ra rb)))))))
                (if (> (length ranked) *context-mention-limit*)
                    (subseq ranked 0 *context-mention-limit*)
                    ranked))))))

(defparameter *context-relation-limit* 12
  "Most relationships to list for one entity in a bundle.

A cap, not a preference. Entities are not uniformly connected -- a function
has a handful of neighbours and a file has one per definition it holds -- and
without a cap a single well-connected entity consumes a bundle that was meant
to describe eight.")

(defun context-item (view entity &key (relations t) (band :neighbour) reach source)
  "One entity as a context line plus, optionally, its immediate relationships.

BAND is why this entity is in the bundle -- :SEED, :DECISION, :DOCUMENT,
:MENTION or :NEIGHBOUR -- and is carried on the item rather than inferred by a
reader. RENDER-CONTEXT groups on it, and without it a bundle is a flat list in
which the code an agent asked about, the reasoning governing it and a
neighbour two hops out all read as the same kind of line."
  (let* ((all (when relations (neighbors view (id entity))))
         (shown (if (> (length all) *context-relation-limit*)
                    (subseq all 0 *context-relation-limit*)
                    all)))
    (list :entity (entity-summary entity)
          :band band
          ;; DES-0026 D10. A neighbour at distance 1 on :IMPLEMENTS and one at
          ;; distance 4 on :CALLS are worth different amounts of reading, and
          ;; before this they printed identically. NIL on a seed, which has no
          ;; arriving edge -- it was reached by a name.
          :cost (and reach (reach-cost reach))
          :via (and reach (reach-via reach))
          :direction (and reach (reach-direction reach))
          ;; DES-0026 D7. How many of the bundle's own seeds converged here, and
          ;; the effective cost that count bought. Printed because a discount a
          ;; reader cannot see is a discount a reader cannot argue with -- and
          ;; convergence is the weakest evidence in the design, so it is the one
          ;; most worth showing.
          :convergence (and reach (reach-convergence reach))
          :effective-cost (and reach (effective-cost reach))
          ;; DES-0026 D2's source tier. NIL on every index-tier item, which is
          ;; most of them -- and the asymmetry is the design: the expensive tier
          ;; is small and the cheap one is where recall lives.
          :source source
          :relation-count (length all)
          :relations
          (loop for n in shown
                collect (list :direction (neighbor-direction n)
                              :rel-type (rel-type (neighbor-relationship n))
                              :name (let ((e (neighbor-entity n)))
                                      (and (slot-boundp e 'name) (name e))))))))

(defun build-context (view task &key (budget *context-token-budget*)
                                     (seed-limit 8) types source-fn
                                     (source-definitions *context-source-definitions*))
  "A budgeted context bundle for TASK: the entities its words point at, their
immediate relationships, and the decisions bearing on them.

SS11's algorithm, in order -- seed by name, expand one hop, add the non-stale
documents bearing on all of it, truncate to budget. Items are added
cheapest-first within each band, so a bundle that runs out of room loses
distant neighbours rather than the entities the task actually named.

The document half is three bands rather than one since DES-0020, ordered by the
strength of the claim each makes: a decision governs, a requirement or plan
declares that it bears on this code, and a piece of prose merely names it.

The admission order puts mentions ahead of the one-hop expansion, which is the
one debatable placement here and is deliberate. The expansion is recoverable --
it is what `describe' on a seed returns -- while the prose is exactly what
re-reading the source cannot give back, and the mention band is capped at
*CONTEXT-MENTION-LIMIT* so it cannot crowd out much. A bundle that truncates
now loses its fortieth structural neighbour rather than the document explaining
the design.

Every call is logged to *CONTEXT-LOG*."
  (let* ((seeds     (seed-entities view task :limit seed-limit :types types))
         ;; DES-0026 D6/D8, PLAN-0032 S1. Was: NEIGHBORS on each seed, PUSHNEW,
         ;; every edge the same price and nothing ordering the result. A one-hop
         ;; expansion cannot satisfy REQ-0016 R6 at any budget -- the four
         ;; classes it misses are two or more :INHERITS hops out -- so the fix
         ;; is reachability and not ranking.
         (reaches   (expand-from-seeds view seeds
                                       :wants-tests (task-wants-tests-p task)))
         (expanded  (mapcar #'reach-entity reaches))
         (items     '())
         (used      0)
         (sourced-tokens 0)
         (truncated nil))
    (multiple-value-bind (decisions documents mentions)
        (documents-touching view (append seeds expanded))
      ;; A document one hop from a seed is in EXPANDED as well as in its band,
      ;; and both were admitted -- so every such document has been printed
      ;; twice and paid for twice since bundles existed. Invisible until
      ;; DES-0020 labelled the bands, because two identical lines in a flat
      ;; list read as one entity mentioned twice rather than as waste.
      ;;
      ;; Subtracted here rather than inside the expansion, because EXPANDED is
      ;; what DOCUMENTS-TOUCHING is asked about: a document that mentions a
      ;; seed's neighbour is reached through that neighbour, so removing it
      ;; before the bands are computed would lose the band rather than the
      ;; duplicate. Nothing stops reaching a bundle -- it arrives once, under
      ;; the stronger claim.
      (setf reaches (remove-if (lambda (r)
                                 (let ((e (reach-entity r)))
                                   (or (member e decisions)
                                       (member e documents)
                                       (member e mentions))))
                               reaches)
            expanded (mapcar #'reach-entity reaches))
      ;; DES-0020 D5a. The document bands are budgeted before the seeds are,
      ;; because otherwise they are never reached at all: measured on
      ;; ~/lisp/game-server, `context dhandler-delete soft deletion' spent
      ;; 1968 of its 2000 tokens on eight seeds and their twelve relations
      ;; apiece and truncated before the first document, so the band this
      ;; whole design exists to add was empty on exactly the tree it was
      ;; built for.
      ;;
      ;; The reserve is what those bands actually cost rather than a fixed
      ;; fraction, and they are cheap by construction -- one line each, no
      ;; relations, and the mention band already capped. Half the budget is
      ;; the ceiling, so a tree with a hundred governing decisions cannot
      ;; starve the code the task asked about. This is the same judgement the
      ;; admission order encodes, applied one level up: what re-reading the
      ;; source cannot give back is the part worth the tokens.
      (let* ((document-items
               (append (mapcar (lambda (e) (context-item view e :relations nil :band :decision))
                               decisions)
                       (mapcar (lambda (e) (context-item view e :relations nil :band :document))
                               documents)
                       (mapcar (lambda (e) (context-item view e :relations nil :band :mention))
                               mentions)))
             (reserve (min (floor budget 2)
                           (reduce #'+ document-items :initial-value 0
                                   :key (lambda (i) (estimate-tokens (render-item i)))))))
        (flet ((admit-item (item cap &key free)
                 ;; FREE is the source tier, and it is what makes "two budgets"
                 ;; true rather than merely stated. Charging a 400-token body to
                 ;; the index budget spends the cheap tier on the expensive one:
                 ;; measured before this guard, `context data-handler' printed 31
                 ;; items for 3979 tokens -- 128 tokens for an entry that is
                 ;; supposed to be a line -- and named 14 of the 157 entities the
                 ;; walk had reached. A body is rationed by *CONTEXT-SOURCE-
                 ;; DEFINITIONS*, a line by tokens, and neither may spend the
                 ;; other's allowance.
                 (let ((cost (estimate-tokens (render-item item))))
                   (cond (free
                          (incf sourced-tokens cost)
                          (push item items)
                          t)
                         ((<= (+ used cost) cap)
                          (incf used cost)
                          (push item items)
                          t)
                         (t (setf truncated t) nil))))
               (item-for (entity relations band)
                 (context-item view entity :relations relations :band band)))
          ;; DES-0026 D2's source tier, admitted first and outside the index
          ;; budget entirely. It is bounded by a count of definitions, which is
          ;; the whole point of two budgets: a body is expensive and is rationed
          ;; by how many bodies a reader wants, where a line is cheap and is
          ;; rationed by tokens.
          ;;
          ;; SOURCE-FN is a callback rather than a call, and the layering is why.
          ;; DEFINITION-SOURCE lives in loom-workspace because an entity's :FILE
          ;; is repository-relative and REPOSITORY-ROOT is a slot up there
          ;; (DES-0027 D1); loom-workspace depends on loom-knowledge, so this
          ;; function cannot reach it. The caller that has the repository passes
          ;; the fetch in, and the tier logic and the rendering stay here where
          ;; they belong. NIL means a caller that wants no bodies, which is every
          ;; caller that existed before this step.
          ;;
          ;; The first N *seeds*, in seed order, which is an interim and is worth
          ;; naming as one: DES-0026 D9 makes the cut fall on one order over the
          ;; whole recalled set, and that order does not exist until PLAN-0032
          ;; S6. Until then a neighbour cannot outrank a seed for a body, however
          ;; near it is.
          (loop for entity in seeds
                for rank from 0
                for wants-source = (and source-fn (< rank source-definitions))
                do (admit-item (context-item view entity :relations t :band :seed
                                             :source (when wants-source
                                                       (funcall source-fn (id entity))))
                               (if (zerop rank) budget (- budget reserve))
                               :free wants-source))
          ;; Then the reserve is released: these are measured against the full
          ;; budget, and fit by construction unless the ceiling clipped them.
          (dolist (item document-items) (admit-item item budget))
          (dolist (r reaches)
            (admit-item (context-item view (reach-entity r)
                                      :relations nil :band :neighbour :reach r)
                        budget))))
      (let ((bundle (list :task task
                          :seeds (summarize-entities seeds)
                          :items (reverse items)
                          :decisions (summarize-entities decisions)
                          ;; Beside :DECISIONS rather than folded into it. A
                          ;; requirement does not govern the code it names, and
                          ;; filing it under "decisions" would be the small lie
                          ;; `impact' already declines to tell -- it reports
                          ;; these as three headings, and two services answering
                          ;; one question with two vocabularies is worse than
                          ;; either vocabulary.
                          :documents (summarize-entities documents)
                          :mentions (summarize-entities mentions)
                          :budget budget
                          :tokens used
                          :truncated truncated
                          ;; What the source tier actually spent, reported rather
                          ;; than inferred: a caller comparing two bundles wants
                          ;; to know whether it got bodies without scanning for
                          ;; them.
                          :source-tokens sourced-tokens
                          :source-definitions (if source-fn source-definitions 0)
                          :sourced (count-if (lambda (i) (getf i :source)) items))))
        (push (make-context-log-entry :task task
                                      :seeds (length seeds)
                                      :entities (length items)
                                      :budget budget
                                      :tokens used)
              *context-log*)
        bundle))))

;;;; ==================================================================
;;;; Rendering -- what an agent actually reads
;;;; ==================================================================

(defun band-heading (band)
  "What a band means, for a reader deciding what to read next.

Prose rather than the keyword, because the audience is an agent choosing where
to spend its attention and \"mention\" does not say what a mention is worth.
Every band is named, seeds included, so no line in the block is unlabelled."
  (case band
    (:seed      "the task named these")
    (:decision  "decisions governing them")
    (:document  "documents bearing on them")
    (:mention   "prose that names them")
    (:neighbour "one hop away")
    (t          (string-downcase (princ-to-string band)))))

(defun render-item (item)
  "One bundle item as the text a reader sees.

Extracted so that costing and printing cannot disagree, which they did. The
budget was estimated from (PRINC-TO-STRING ITEM) -- the serialised plist, keys
and all -- and that over-counts the rendered line about fivefold. It did not
matter much while a bundle held eight seeds; it mattered a great deal once
DES-0026 D3 sized an index tier on the premise that a line costs 15 tokens,
because the tier then bought a fifth of what it was budgeted for. Measured:
`context data-handler' named 35 of the 157 entities the walk reached.

This function's docstring is the reason RENDER-CONTEXT gives for living beside
the builder -- \"the rendering is where the token budget is really spent\" --
made true rather than merely asserted."
  (let ((entity (getf item :entity)))
    (with-output-to-string (out)
      (format out "~(~a~) ~a~@[  [~a]~]~@[  (stale)~]~@[  ~a~]~%"
              (getf entity :type) (getf entity :name)
              (getf entity :location) (getf entity :stale)
              (when (getf item :cost)
                (format nil "~a~(~a~) ~d~@[ x~d~]"
                        (if (eq :out (getf item :direction)) "->" "<-")
                        (getf item :via) (getf item :cost)
                        (let ((c (getf item :convergence)))
                          (and c (> c 1) c)))))
      (dolist (rel (getf item :relations))
        (format out "    ~a ~(~a~) ~a~%"
                (if (eq :out (getf rel :direction)) "->" "<-")
                (getf rel :rel-type) (getf rel :name)))
      (let ((hidden (- (or (getf item :relation-count) 0)
                       (length (getf item :relations)))))
        (when (plusp hidden) (format out "    ... ~d more~%" hidden)))
      (let ((src (getf item :source)))
        (when (and src (getf src :text))
          (format out "    source ~a~@[ (~d line~:p withheld)~]:~%"
                  (getf src :range)
                  (and (getf src :truncated) (getf src :withheld)))
          (with-input-from-string (in (getf src :text))
            (loop for line = (read-line in nil nil)
                  while line do (format out "      ~a~%" line))))))))

(defun render-context (bundle)
  "BUNDLE as the text block an agent receives.

Kept next to the builder rather than in LOOM-MCP because the rendering is
where the token budget is really spent, and a bundle whose data is compact but
whose text is not has not saved anybody anything."
  (let ((band nil))
   (with-output-to-string (out)
    (format out "~&# Context for: ~a~%" (getf bundle :task))
    (format out "~&# ~d entities, ~~~d/~d tokens~@[ (truncated)~]~2%"
            (length (getf bundle :items)) (getf bundle :tokens)
            (getf bundle :budget) (getf bundle :truncated))
    (when (null (getf bundle :items))
      (format out "No indexed entity matched this task.~%"))
    (dolist (item (getf bundle :items))
      ;; The heading changes when the band does, so an agent can tell the code
      ;; it asked about from the reasoning about it and from a neighbour two
      ;; hops out. Before DES-0020 every item printed as the same kind of line
      ;; and the bundle's :DECISIONS field was not rendered at all -- decisions
      ;; reached the text only by being admitted among the functions, which
      ;; made "why is the code this way" indistinguishable from "what else is
      ;; nearby" at exactly the moment an agent is deciding what to read.
      (unless (eq band (getf item :band))
        (setf band (getf item :band))
        (format out "~&~%## ~a~%" (band-heading band)))
      ;; The body is RENDER-ITEM's, which is also what the budget was measured
      ;; against. Two copies of this loop is how costing and printing came to
      ;; disagree by a factor of five.
      (write-string (render-item item) out)))))
