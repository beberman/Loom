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
  '("the" "and" "for" "with" "that" "this" "into" "when" "what" "which"
    "using" "should" "would" "need" "needs" "want" "please" "can" "does"
    "how" "why" "where" "are" "was" "will" "not" "its" "have" "has"
    "had" "them" "they" "then" "than")
  "Words dropped before matching begins: English a code tree names nothing after.

Not a language model -- just enough that \"how does the drawing tool work\"
seeds on \"drawing\" and \"tool\" rather than on \"does\" and \"work\".

One list until DES-0038, which is where sixteen of these went. \"Too common to
match a name against\" was two claims wearing one coat: a word can be common in
English and name nothing, or common *because* a code tree names things with it.
GET, SET, ADD, MAKE, TEST and FILE are the second, and dropping them cost the
queries that meant them -- \"wrapped logger set level\" competed on three words
of four, and `set' is the one that separates SETLEVEL from eight bare LOGGERs.
They are in *CONTEXT-WEAK-TERMS* now, searched but unable to seed alone.

What is left is the first claim only. Every word here is English function
vocabulary, and no measured case wants one of them matched against a name.")

(defparameter *context-weak-terms*
  '("add" "new" "use" "make" "get" "set" "fix" "change" "update" "code"
    "function" "class" "file" "test" "tests" "from")
  "Words searched for, but never enough on their own to make a candidate a seed.

The second population. A stopword is dropped before matching begins; these are
matched and count toward coverage like any other term, and only a candidate
that answered *nothing else* is dropped. So `get type from obj' reaches
GETTYPEFROMOBJ on three terms, while GETTYPEID -- which answered to `get' and
to nothing else -- is not a candidate at all.

Every one of these was a stopword until this list existed, and each is among
the commonest words a code tree names things with. Measured over the 450
known-item cases, 21 of the 57 remaining misses lost a word from this list
before matching began, and the word was in the expected name every time:
GAME.ADDDEFINITION, WRAPPEDLOGGER.SETLEVEL, GETDEFINITIONLIST, PINSET,
MAKE-TABLE-HANDLER, TEST-FNS.

\"and\" is not here and stays a stopword. Freeing it measured 3 known-item
cases better and cost REQ-0016 R8, which is a judged acceptance case: `data-api
handler database connection acquire and test connectivity' stopped returning
CONNECTION-CONNECT-DATABASE at all. REQ-0036 R11 makes the judged set the
held-out one, and a generated case does not outvote it.")

(defun surface-variants (word)
  "WORD's plausible uninflected surface forms, by four suffix rules.

The generator half of the hybrid. These rules stood alone until DES-0033 D4 and
their outputs are *surface forms* -- \"saving\" gives \"sav\" and \"save\",
words as they would be written -- which matters because Loom matches a query
token against a raw name. Porter's output is a stem class, not a surface form:
it is correct only when both sides are stemmed, which is REQ-0045 and is not
built. \"key\" to \"kei\" is the case: neither a prefix of nor a word in
anything, and it cost acceptance case r39-4 when Porter emitted it alone.

The -e restoration is why both halves of a pair are emitted. Dropping -ing from
\"saving\" gives \"sav\", which matches nothing; restoring the -e gives
\"save\", which reaches SAVEDESIGN. Neither rule knows which is right, so both
are offered and the index decides.

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

(defun inflected-p (word)
  "True when Porter's algorithm finds an inflection to remove from WORD.

The gate half of the hybrid, and the only thing Porter is asked here. A suffix
rule asks what the last three characters are; Porter asks whether a measurable
stem remains once a suffix is removed, and that is the question the four rules
above cannot answer. \"string\" is six characters and ends in -ing and is not a
gerund, which is BUG-0040 -- the -ing rule fired and emitted \"str\" and
\"stre\", and \"stre\" reached STRESS-PUSHER at rank 1.

Used as a predicate rather than as a source of tokens. CON-0007 records why:
Porter's stems are meant to be compared against stemmed text, and Loom stems
only the query, so an emitted stem works only where it happens to be a prefix
of the surface form. \"encod\" is; \"kei\" is not."
  (let ((stemmed (stem:stem word)))
    (not (string= stemmed word))))

(defun stem-variants (word)
  "WORD's uninflected forms, or NIL when Porter says it is not inflected.

DES-0035: the four suffix rules generate, Porter decides whether to believe
them. Both halves earn their place and each fails alone.

  string      Porter: not inflected           -> nothing
              The rules alone gave \"str\" and \"stre\" (BUG-0040).
  saving      Porter: inflected, rules fire   -> \"sav\", \"save\"
              Porter alone gave \"save\" only, and the coverage band -- which
              counts matches rather than words -- then scored SaveDesign one
              lower and dropped it (acceptance case fe-10).
  key, value  Porter: inflected, no rule fires -> nothing
              Porter alone gave \"kei\" and \"valu\", which reach nothing by
              prefix and cost acceptance case r39-4.

Added rather than substituted, as always: a variant is an extra token beside
the word, never a replacement, so nothing that matches today stops matching.
DEC-0005 spends precision to buy recall and this spends none of either."
  (when (inflected-p word)
    (surface-variants word)))

(defun task-token-origins (task)
  "The tokens of TASK paired with the word each came from, in TASK-TOKENS order.

A word the caller wrote maps to itself. A compound part and a stem variant map
to the word that produced them, so \"str\" and \"stre\" both map to \"string\"
and the ranking can tell what a match cost the caller to write (DES-0033 D1).

Recorded here rather than reconstructed later, which is DES-0033 D3 and is not
a preference: \"str\" is derivable from \"string\" and from \"strings\" alike,
so a pass that asks afterwards which written word could have produced a
fragment has to guess between them, and a guess about provenance is the thing
CON-0001 refuses.

A token reachable two ways keeps the first origin recorded for it, because
PUSHNEW keeps the first and the alist has to agree with the token list it is
built beside."
  (let ((origins '())
        (current (make-string-output-stream)))
    (flet ((remember (token origin)
             (unless (assoc token origins :test #'string=)
               (push (cons token origin) origins))))
      (flet ((finish ()
               (let ((word (string-downcase (get-output-stream-string current))))
                 (when (and (>= (length word) 3)
                            (not (member word *context-stopwords* :test #'string=)))
                   (remember word word)
                   ;; a compound also seeds on its parts
                   (let ((start 0))
                     (dotimes (i (1+ (length word)))
                       (when (or (= i (length word))
                                 (member (char word i) '(#\- #\_)))
                         (let ((part (subseq word start i)))
                           (when (and (>= (length part) 3)
                                      (not (member part *context-stopwords* :test #'string=)))
                             (remember part word)))
                         (setf start (1+ i)))))))))
        (loop for char across task
              do (if (or (alphanumericp char) (member char '(#\- #\_ #\* #\%)))
                     (write-char char current)
                     (finish))
              finally (finish)))
      ;; Inflections last. "saving a piece design" reaches SAVEDESIGN, which it
      ;; could not while SAVING and SAVE were unrelated strings -- that entity
      ;; was the one measured gain of two reverted attempts to replace this
      ;; function with a postings index, and it was never the index that gained
      ;; it.
      ;;
      ;; Added rather than substituted, so a wrong guess costs nothing: a stem
      ;; matching no name simply never matches. The stopword filter is not
      ;; re-applied to a variant, because a variant of a word that passed the
      ;; filter is a word the caller wrote.
      ;;
      ;; BUG-0040 measured that claim as false and this pass is half of what
      ;; makes it true: "string" is six characters and ends in -ing, so it
      ;; stems to "str" and "stre", and "stre" reached STRESS-PUSHER at the
      ;; strongest rank the scale has. A variant carries its origin from here
      ;; so that SEED-SCORE can rank it below the word it came from rather
      ;; than beside it.
      ;; ORIGINS is in reverse insertion order here, exactly as the token list
      ;; it replaced was when the loop that used to stand here read
      ;; (COPY-LIST TOKENS). Iterating it forwards rather than reversing it
      ;; first is not a detail: the variants are emitted in the order this walk
      ;; reaches their base words, that order survives the NREVERSE below, and
      ;; SEED-MATCHES reaches candidates in token order -- which is the tie
      ;; break for every candidate scoring the same. Reversing it here reordered
      ;; "start stre str" to "stre str start" for "test whether a string
      ;; starts with a prefix", and cost acceptance case log-1 its JS-TRIM.
      (dolist (pair origins)
        (dolist (variant (stem-variants (car pair)))
          (remember variant (cdr pair)))))
    (nreverse origins)))

(defun task-tokens (task)
  "The candidate identifiers in TASK: words and hyphenated or underscored
compounds, lowercased, three characters or more, stopwords dropped.

Compounds are kept whole *and* split, so \"impact-set\" seeds on the exact
name and, failing that, on \"impact\".

The keys of TASK-TOKEN-ORIGINS, which is where the list is actually built.
Splitting the two keeps this function's contract -- every caller wants the
tokens and only the ranking wants their provenance -- without two functions
walking the same string and drifting apart."
  (mapcar #'car (task-token-origins task)))

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

(defparameter *seed-name-share* 3
  "How many definitions of one name may be seeds of one bundle.

The second of ADMIT-SEEDS' two counts, and the one BUG-0041 found missing.
*SEED-TERM-SHARE* bounds how many distinct names a slice of the task may
contribute; one name is one charge against that however many definitions carry
it, and nothing bounded how many of them were admitted. `wrapped logger set
level' returned eight variables named LOGGER and `mp deleting obj' eight
methods named DELETE-OBJ.

Three because REQ-0016 R8 pins it there. That clause is an acceptance case --
`data-api handler database connection acquire and test connectivity' must
return all three CONNECTION-CONNECT-DATABASE definitions, because three files
defining one name is the finding the query exists to produce -- so two fails
it, and a larger number bounds less than the evidence allows.

Advisory in the same way and for the same reason as *SEED-TERM-SHARE*: a task
whose candidates are all one name still fills its set from them.")

(defun derived-token-p (token origins)
  "True when TOKEN is something Loom made from the task rather than a word of it.

A compound part or a stem variant. The distinction is TASK-TERMS' -- \"those
are Loom's own manufacture rather than anything the caller typed\" -- which
NAMED-BY-TASK-P has applied to the 100000 band since REQ-0016 R1 and which the
two bands below it do not apply at all.

Nothing reads this today. DES-0033 D1 ranked a derived match three worse than a
written one and the acceptance run refused it, at 41 of 45 against a baseline
of 42. Kept because REQ-0045 and REQ-0046 both need the distinction and the
predicate is not what was wrong: what was wrong was spending precision for it,
which DEC-0005 does not permit."
  (let ((origin (cdr (assoc token origins :test #'string=))))
    (and origin (not (string= token origin)))))

(defun split-name-parts (name)
  "NAME split on - and _ and on a lower-to-upper case change, lowercased.

The half of CON-0007's first mechanism Loom has never had. TASK-TOKENS splits a
compound in the *query* on - and _; nothing has ever split an entity's name,
and nothing split either on case, so MapElementTypeEditor was one token to this
index and SaveDesign was another.

Case change is a boundary and a run of capitals is not: HTTPServer yields http
and server rather than h, t, t, p and server. The rule is a lowercase or a
digit followed by an uppercase, which is what leaves an acronym whole."
  (let ((parts '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((part (string-downcase (get-output-stream-string current))))
               (when (plusp (length part)) (push part parts)))))
      (loop for i below (length name)
            for char = (char name i)
            do (cond ((or (char= char #\-) (char= char #\_) (char= char #\/))
                      (finish))
                     ((and (upper-case-p char)
                           (plusp i)
                           (let ((previous (char name (1- i))))
                             (or (lower-case-p previous) (digit-char-p previous))))
                      (finish)
                      (write-char char current))
                     (t (write-char char current))))
      (finish))
    (nreverse parts)))

(defun name-tokens (entity)
  "ENTITY's name as the seeder matches it: parts, their stems, and the whole.

DES-0034 D1, and the side of CON-0007's rule Loom did not have. A query was
analysed -- split, stemmed -- and the result was compared against a raw name,
where every text search analyses index and query alike. So \"prefix\" reached
DOT-PREFIXED-P as a substring and never as the word it is, because nothing
split that name into dot/prefixed/p or stemmed \"prefixed\" to \"prefix\".

The whole is kept beside the parts, which is Lucene's preserve_original and
what TASK-TOKENS already does on the query side.

Computed per candidate at match time rather than stored on the entity: the
candidates are the few hundred FIND-ENTITIES already returned, and a stored
form would make the graph carry a retrieval decision when DEC-0001 has it
derivable from files instead."
  (let ((name (significant-name entity)))
    (when name
      (let* ((whole (string-downcase name))
             (parts (split-name-parts name))
             (tokens (list whole)))
        (dolist (part parts)
          (pushnew part tokens :test #'string=)
          (let ((stemmed (stem:stem part)))
            (unless (string= stemmed part)
              (pushnew stemmed tokens :test #'string=))))
        tokens))))

(defun analyzed-rank (entity token)
  "How well TOKEN matches ENTITY's analyzed name: 0 exact, 1 prefix, 2 substring.

DES-0034 D2. The same three ranks MATCH-RANK returns, over NAME-TOKENS rather
than over the raw name, and with the token's own stem tried as well.

MATCH-RANK's answer is the floor: this never returns worse than the rank the
raw name would have earned, so a candidate that matches today cannot rank lower
tomorrow. That is what keeps an analyzer inside DEC-0005 -- it promotes and
never demotes.

`find' does not call this. REQ-0045 R1 makes the token set a property of the
operation, and this is that at its smallest: one function the seeder uses and
the navigational commands do not."
  (let ((raw (match-rank entity token)))
    ;; 3 is not a rank, it is MATCH-RANK saying the name does not contain this
    ;; token at all -- SEED-MATCHES drops it so that a token which reached an
    ;; entity only through its path is not recorded as evidence. Promoting from
    ;; 3 would turn every such non-match into a match, which is a wider change
    ;; than analysing the ones that already matched.
    (if (or (zerop raw) (= raw 3))
        raw
        (let ((analyzed (name-tokens entity))
              (stemmed  (stem:stem token))
              (best raw))
          (dolist (candidate analyzed best)
            (dolist (probe (if (string= stemmed token) (list token) (list token stemmed)))
              (cond ((string= candidate probe) (setf best (min best 0)))
                    ((and (<= (length probe) (length candidate))
                          (string= probe candidate :end2 (length probe)))
                     (setf best (min best 1))))))))))

(defun seed-matches (view origins types)
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
explaining it. SEED-SCORE bands them separately for that reason.

ORIGINS is TASK-TOKEN-ORIGINS' alist rather than a bare token list, and a
match on a token the caller did not write is recorded three ranks worse than
the same match on one they did (DES-0033 D1). BUG-0040 is why: \"string\" stems
to \"str\" and \"stre\", and a prefix match on \"stre\" scored 1 while a
substring match on \"string\" scored 2, so STRESS-PUSHER and STRESS-WRITER
took two of eight slots on a query about string prefixes."
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
        (let ((reached (find-entities view :name-like token)))
          (push (cons token (length reached)) frequencies)
        (dolist (entity reached)
          (when (or (null types) (member (entity-type entity) types))
            ;; MATCH-RANK, not ANALYZED-RANK. DES-0034 measured the analyzer
            ;; at 38 of 45 against 40, and its own closing line predicted why:
            ;; promoting an exact part match to 0 flattens the band that was
            ;; breaking ties between equal-coverage candidates, and nothing
            ;; else discriminates them. REQ-0046 first.
            (let ((rank (match-rank entity token)))
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
    (values (loop for entity in (nreverse order)
                  collect (cons entity (nreverse (gethash entity hits))))
            (nreverse frequencies))))

(defun weak-term-p (token origins)
  "True when TOKEN is one of *CONTEXT-WEAK-TERMS*, or came from one.

Both, because a weak word reaches SEED-MATCHES two ways. It is written -- `get
definition list' -- or it is the part a compound was split into, and
\"get-definition-list\" splits to a `get' whose origin is the compound rather
than itself. Asking only the origin misses the second; asking only the token
misses \"tests\" reaching the index as its own stem."
  (let ((origin (cdr (assoc token origins :test #'string=))))
    (and (or (member token *context-weak-terms* :test #'string=)
             (and origin (member origin *context-weak-terms* :test #'string=)))
         t)))

(defun strong-candidates (matches origins)
  "MATCHES, less every candidate whose terms are all weak ones.

Relaxed rather than enforced, in ADMIT-SEEDS' sense and for its reason: a task
written entirely out of weak words -- `get set' -- would otherwise have no
candidates at all, so when the filter empties the pool the pool is returned
whole.

The filter and not the stopword list is what makes a weak term safe to search
on. A word like `get' names something in almost any code tree, so dropping it
costs the queries that meant it; searching it without this admits every GETX in
the repository as a seed in its own right. Measured on game-server, `get
database config' with `get' searched and unfiltered returned GET-GAME-DB-ID,
GET-TYPEID and GAME-GET-DEFAULT-CONFIG and lost GET-DATABASE-CONFIG, which it
had found when `get' was a stopword."
  (let ((kept (remove-if (lambda (pair)
                           (every (lambda (m) (weak-term-p (car m) origins))
                                  (cdr pair)))
                         matches)))
    (or kept matches)))

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
separated by PROSE-ONLY-P one band above.

DES-0033 D1 moved this to 6 as part of ranking a derived token below a written
one, and the acceptance run took that back: 41 of 45, losing JS-TRIM on \"trim
whitespace from a string\". The design records the measurement."
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

Read off the raw task rather than off TASK-TOKENS, and still, though the reason
has changed. TASK-TOKENS dropped \"test\" as a stopword until DES-0038; it now
returns it as a weak term, so the two lists would agree today. The raw task
stays the source because this asks what the caller *wants*, which the words
they wrote answer directly, while TASK-TOKENS also holds compound parts and
stem variants Loom manufactured -- \"latest\" is not one, but nothing here
should depend on that."
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

(defun match-coverage (matches origins)
  "How many distinct words of the task MATCHES answers to.

Distinct *words*, not distinct matches: a candidate reached by \"string\" and
by \"str\" answered one word of the task twice. SEED-SCORE's coverage band has
always been described as \"how many of the task's distinct terms this name
answers to\", and this computes that.

It is nonetheless NOT what the coverage band uses, and the measurement is why.
DES-0033 D2 proposed it and PLAN-0039 S3 built it; the acceptance run went from
42 of 45 to 40, losing WorkingSet (fe-1) and SaveDesign (fe-10) on front-end --
a tree that work did not commit to, so neither loss is corpus drift.

SaveDesign is the case. \"saving a piece design\" reaches it through the stem
\"save\", and folding \"save\" and \"sav\" back into \"saving\" drops its
coverage from 3 to 2 while a rival answering \"design\" and \"piece\" keeps 2.
Correcting the count cost the stemmer its one recorded gain, and DEC-0005 does
not buy a more defensible band with two entities that stop being recalled.

Kept rather than deleted so the next attempt starts from the measurement. The
inflated count is a real defect; what is wrong with this correction is that it
deflates a true positive and a false one by the same amount."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (m matches (hash-table-count seen))
      (let* ((token (car m))
             (origin (or (cdr (assoc token origins :test #'string=)) token)))
        (setf (gethash origin seen) t)))))

(defun term-weight (token frequencies corpus-size)
  "How much a match on TOKEN is worth, from 1 for a term naming one entity down
towards 0 for one naming everything.

Inverse document frequency, normalised by log of the corpus size:

    w(t) = log(N / df(t)) / log(N)

The normalisation is what makes a weight comparable between repositories.
front-end holds 3457 definitions to game-server's 1811, and an unnormalised idf
would make every front-end term look rarer than every game-server one; REQ-0023
put several repositories behind one service precisely so that \"check\" could be
common in one and absent from another.

Measured on Loom, where N is about 3000: separator at df 0 and fallback at df 1
weigh 1.00, join at df 2 weighs 0.91, starts at df 4 weighs 0.83, parse at df 26
weighs 0.59, and entity at df 150 weighs 0.38. A rare term is worth about two
and a half times a common one, which is the whole spread -- REQ-0046 asks for a
continuous weight rather than a cutoff, and DES-0032 refused a threshold because
the gap between `starts' at 4 entities and `join' at 2 is two entities.

1 when the frequency is unknown or the corpus is too small to say anything. A
token with no recorded frequency is one the prose pass reached and the name pass
did not, and treating it as rare is the reading that does not silently demote a
docstring match."
  (let ((df (cdr (assoc token frequencies :test #'string=))))
    (cond ((or (null df) (<= corpus-size 1)) 1)
          ((<= df 1) 1)
          ((>= df corpus-size) 0)
          (t (/ (log (/ corpus-size df)) (log corpus-size))))))

(defparameter *coverage-resolution* 1
  "Steps per whole term in the coverage band.

1 until the weighting was measured. With weights running from 0.38 for the
commonest term on this tree to 1.00 for a term naming one entity, a whole-number
count puts almost every candidate on 1, 2 or 3 and throws the weighting away in
the rounding: three common terms and one rare one both count 1.

10 gives the band a tenth of a term, which is finer than the spread between any
two terms this tree has. SEED-SCORE's other constants are multiplied to match --
the deficit now runs 0 to 80 rather than 0 to 8, so it is worth 100 a step
rather than 100 a term, and the bands above it move up a decade each.")

(defun weighted-coverage (matches frequencies corpus-size)
  "How many of the task's terms MATCHES answers to, counting each by its rarity.

DES-0036 D3. The band this feeds stays an integer from 0 to 8 and stays worth
100, so no other band moves: what changes is that a candidate answering three
words nearly every file uses now counts about 1 where it counted 3, and one
answering three words peculiar to this repository still counts 3.

Rounded rather than kept continuous. A fractional coverage puts a continuous
quantity in the digits SEED-SCORE gives to the prose band at 10 and the rank
band at 0-3, and needs every constant in that function multiplied.

NOT CALLED BY SEED-SCORE. DES-0036 records the measurement. At a whole term the
weighting returned 42 of 45 and 390 of 450 -- exactly the numbers REQ-0046 set
as the bar, unchanged. At tenths of a term, with every band above multiplied to
make room, it returned 40 of 45 and 389 of 450, losing ColorEditor and
EditorModeToggle.

The diagnosis is that idf discriminates between the terms *within* a query, and
the queries REQ-0046 R1 was written for have no rare term to find. "game add
definition" against front-end weighs game at df 252, add at 38 and definition
at 17; every candidate matching them is weighted alike, and three of the four
named misses came back with byte-identical item counts.

Kept because the frequency it rests on is recorded by SEED-MATCHES at no cost,
and because what those queries need -- a candidate whose name carries all of the
terms beating one that carries the commonest of them -- is a proximity signal
that no per-term weight expresses."
  (round (* *coverage-resolution*
            (reduce #'+ matches
                    :key (lambda (m) (term-weight (car m) frequencies corpus-size))
                    :initial-value 0))))

(defun seed-score (entity matches &key demote-tests terms production origins
                                        frequencies (corpus-size 0))
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
  (declare (ignore frequencies corpus-size))
  (+ (* 1000000 (seed-type-rank entity))
     (*  100000 (if (named-by-task-p entity matches terms) 0 1))
     (*   10000 (if (slot-accessor-p entity) 1 0))
     (*    1000 (if (demoted-test-p entity demote-tests production) 1 0))
     ;; (LENGTH MATCHES), not WEIGHTED-COVERAGE, and the constants are back
     ;; where they were. DES-0036 built the weighting and measured it at exactly
     ;; the two numbers it set out to beat, both unchanged; that design records
     ;; why, and WEIGHTED-COVERAGE keeps the mechanism.
     (*     100 (max 0 (- 8 (length matches))))
     (*      10 (if (prose-only-p matches) 1 0))
     (best-name-rank matches)))

(defun seed-slice (matches)
  "The slice of the task a seed answers to: its matched terms, sorted.
The key the share in ADMIT-SEEDS is counted against."
  (format nil "~{~a~^ ~}" (sort (mapcar #'car matches) #'string<)))

(defun admit-seeds (ranked limit)
  "The first LIMIT entities of RANKED, holding back a slice past its share and
a name past its own.

The cap is a filter on the way in rather than another term in the score,
because it is a property of the set being built and not of any candidate in
it: whether a seventh \"check\" is worth admitting depends entirely on whether
anything else is still waiting.

Two counts against two keys, because a candidate crowds a bundle two ways.

  A slice -- the *set* of terms a seed answers to -- may contribute
  *SEED-TERM-SHARE* distinct names, and what it counts is names rather than
  entities. Both halves were measured rather than reasoned to, and each fixes
  what the simpler rule got wrong:

    Charging each seed to one term -- its narrowest -- cost REQ-0016 R8's query
    one of the three CONNECTION-CONNECT-DATABASE definitions, the one in
    server/server.lisp. Three files defining one name is the finding that query
    exists to produce, and a cap counting entities destroys it. Counting names
    does not: they are one name, so they are one charge.

    Exempting anything that answered to more than one term let five members of
    the CHECK-DATABASE-* family take five of eight slots, because they all
    match {check, database} and nothing capped a pair of words the way a single
    word was capped. A family sharing a slice is the same crowding as a family
    sharing a word.

  A name may be *SEED-NAME-SHARE* entities. One charge is right; the slots that
  charge could take were unbounded until BUG-0041, because the branch admitting
  a name already charged to its slice asked nothing further. Measured over the
  450 known-item cases on 2026-08-22, 34 returned eight seeds carrying three or
  fewer distinct names and 9 returned a single name eight times.

Relaxed rather than enforced, both of them. When the held-back candidates are
all there is they are admitted in score order, so a task naming one thing still
seeds on that thing as many times as the tree offers and a small tree behaves
exactly as it did before either cap existed."
  (let ((spent  (make-hash-table :test #'equal))
        ;; EQUALP hashes a string the way STRING-EQUAL compares one -- by
        ;; character, ignoring case -- so this table and the MEMBER below agree
        ;; on what counts as the same name.
        (copies (make-hash-table :test #'equalp))
        (chosen '())
        (held   '())
        (taken  0))
    (dolist (pair ranked)
      (when (< taken limit)
        (let* ((slice (seed-slice (cdr pair)))
               (names (gethash slice spent))
               (name  (significant-name (car pair))))
          (cond ((and (or (< (length names) *seed-term-share*)
                          (member name names :test #'string-equal))
                      (< (gethash name copies 0) *seed-name-share*))
                 (pushnew name (gethash slice spent) :test #'string-equal)
                 (incf (gethash name copies 0))
                 (incf taken)
                 (push (car pair) chosen))
                (t (push (car pair) held))))))
    (setf chosen (nreverse chosen)
          held   (nreverse held))
    (append chosen (subseq held 0 (min (- limit taken) (length held))))))

(defun reported-terms (task)
  "The task's words that the seeder actually looked for, in the caller's spelling.

The intersection of TASK-TERMS and TASK-TOKENS, which is what makes the term
report a statement about the query rather than about Loom's handling of it.
Each list alone is the wrong one. TASK-TERMS keeps stopwords, so a report built
from it says `a' and `to' matched nothing, which is true and is noise.
TASK-TOKENS holds the fragments compounds were split into, so a report built
from it says `utf-8', `utf' and `encod' each matched nothing, which is one
absence counted three times and two words the caller never wrote.

Their intersection is the words the caller typed that the seeder searched on:
for \"reading a file with an encoding fallback when it is not UTF-8\", the four
terms reading, encoding, fallback and utf-8 out of nine tokens and twelve
terms."
  (let ((tokens (task-tokens task)))
    (remove-if-not (lambda (term) (member term tokens :test #'string=))
                   (task-terms task))))

(defun term-coverage (matches terms)
  "Per term of TERMS, the candidates in MATCHES that answered it, split by how.

An alist of (term :name (entity ...) :prose (entity ...)), in the order TERMS
gives. MATCHES is SEED-MATCHES' alist, keyed by entity; this is the same data
keyed by term, which is the direction nothing has needed until now -- the
seeder reads a candidate's terms to score it, and never asks a term which
candidates it reached.

Every term of TERMS gets a row, including one no candidate matched at all. A
table built from the matches alone would hold no row for it, and the term with
nothing under it is the one the whole report exists to name."
  (let ((rows (mapcar (lambda (term) (list term :name '() :prose '())) terms)))
    (dolist (pair matches)
      (loop for (term . rank) in (cdr pair)
            for row = (assoc term rows :test #'string=)
            when row
              do (if (eq rank :prose)
                     (push (car pair) (getf (cdr row) :prose))
                     (push (car pair) (getf (cdr row) :name)))))
    rows))

(defun classify-terms (coverage chosen)
  "Each term of COVERAGE as :ANSWERED, :WEAK or :UNMATCHED. DES-0032 D2.

  :ANSWERED   an admitted seed carries this term in its name
  :WEAK       candidates matched it, but no admitted seed matched it by name --
              which is where a prose-only term lands, and where a term whose
              name matches all ranked below the eighth slot lands too
  :UNMATCHED  nothing in the index matched it, by name or in prose

Three states and not a number. REQ-0037's WHAT THIS IS NOT rules out a
confidence score per seed, and :UNMATCHED needs no judgement to be true of an
index: it is what `find' returning nothing says, which is what all four of the
judged records behind REQ-0037 ran by hand once the bundle had failed to say
it.

CHOSEN is what separates the first two, so this runs after ADMIT-SEEDS. A term
answered only by a candidate the cap held back is a term the caller cannot see
an answer to, and calling it answered would describe the ranking rather than
the bundle."
  (loop for (term . how) in coverage
        collect (cons term
                      (cond ((intersection (getf how :name) chosen :test #'eq)
                             :answered)
                            ((or (getf how :name) (getf how :prose))
                             :weak)
                            (t :unmatched)))))

(defparameter *context-embedder* nil
  "The embedder semantic seeding uses, or NIL for none. REQ-0048 R6.

NIL is the default and is not a degraded mode. Loom answers from the lexical
seeder alone, returns what it returns today, and reports nothing -- an optional
dependency that announced its absence would not be optional.

Set by whoever knows the deployment rather than read from the environment here:
loom-serve configures it at startup, a test binds it, and a library consumer
that never sets it never reaches an embedder. The same argument DES-0030 D1
makes for the context log.")

(defparameter *context-vector-store* nil
  "The vector store for the repository being searched, or NIL for none.

Passed in rather than loaded here, because loom-knowledge is handed a VIEW and
never learns which repository it belongs to. The caller knows, and the caller
is where the store is loaded.")

(defun semantic-candidates (view task)
  "Candidates the embedder proposes for TASK, or NIL when there is no embedder.

NIL for every reason there is: no embedder configured, no store, a store whose
identity does not match, an embedder that cannot be reached. REQ-0048 R6 gives
them one meaning, so they get one return value and the caller needs no branch.

Empty until PLAN-0043 S4 puts a scan behind it. The seam is here rather than
there because S3's whole subject is the path where this returns nothing, and
that path is the one whose failure has no symptom: a bundle is still returned,
still correct, and merely slower or -- worse -- occasionally wrong in a way no
recall count would show."
  (declare (ignore view task))
  (when (and *context-embedder* *context-vector-store*)
    ;; S4. Until then the answer is the same as having no embedder, which is
    ;; what every test of R6 is written against.
    nil))

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
  (multiple-value-bind (matches frequencies)
      (seed-matches view (task-token-origins task) types)
   (let* ((demote-tests (not (task-wants-tests-p task)))
         (terms      (task-terms task))
         (origins    (task-token-origins task))
         (corpus-size (length (all-entities view)))
         ;; MATCHES stays whole for the term report below: a term answered only
         ;; by candidates this drops is WEAK, and calling it UNMATCHED would say
         ;; the index holds nothing of the kind. CANDIDATES is what the ranking
         ;; and the admission see.
         (candidates (append (strong-candidates matches origins)
                             ;; Nothing today, and the call is here rather than
                             ;; in S4 so that the absent path is the one that
                             ;; has been exercised by every run since.
                             (semantic-candidates view task)))
         (production (production-names candidates))
         ;; COPY-LIST because STABLE-SORT is destructive on a list and MATCHES
         ;; is read again below -- and CANDIDATES is MATCHES itself whenever
         ;; STRONG-CANDIDATES removed nothing, so sorting it in place is sorting
         ;; MATCHES. Without the copy MATCHES names whatever cons cell was
         ;; first before the sort, which after the sort is a *suffix* of the
         ;; sorted list -- so the ASSOC building the record detail searched part
         ;; of the alist and missed the rest. BUG-0037: 207 of 246 recorded
         ;; bundles carried a null `terms' and a score recomputed from no matches
         ;; at all, which is the corpus REQ-0036 measures the ranking against.
         (ranked     (stable-sort (copy-list candidates) #'<
                                  :key (lambda (pair)
                                         (seed-score (car pair) (cdr pair)
                                                     :demote-tests demote-tests
                                                     :terms terms
                                                     :production production
                                                     :origins origins
                                                     :frequencies frequencies
                                                     :corpus-size corpus-size))))
         (chosen     (admit-seeds ranked limit)))
    ;; Second value: the chosen seeds with the score and the terms each
    ;; answered to. DES-0030 D3 -- a record holding the seeds without their
    ;; scores cannot show why the eighth slot went where it did, and the score
    ;; is the number every ranking change moves.
    ;;
    ;; Recomputed for the chosen few rather than threaded through ADMIT-SEEDS,
    ;; which reads (entity . terms) pairs and would have to read something else.
    ;; Eight SEED-SCORE calls against a bundle that has already walked the graph
    ;; is not a cost the latency clauses can see.
    ;; Third value, not second: the record detail BUG-0037 fixed is the second
    ;; and tools/acceptance.py reads it positionally. DES-0032 D2's report goes
    ;; after it.
    (values chosen
            (loop for entity in chosen
                  for rank from 1
                  for pair = (assoc entity matches :test #'eq)
                  collect (list :id (id entity)
                                :name (name entity)
                                :rank rank
                                :score (seed-score entity (cdr pair)
                                                   :demote-tests demote-tests
                                                   :terms terms
                                                   :production production
                                                   :origins origins
                                                   :frequencies frequencies
                                                   :corpus-size corpus-size)
                                ;; The terms as objects rather than the
                                ;; (term . weight) conses SEED-MATCHES builds.
                                ;; A dotted pair is not a shape JSON has, and a
                                ;; record is read by tools/acceptance.py.
                                :terms (loop for (term . weight) in (cdr pair)
                                             collect (list :term term
                                                           :weight weight))))
            (classify-terms (term-coverage matches (reported-terms task))
                            chosen)))))

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
  (multiple-value-bind (seeds seed-detail term-states)
      (seed-entities view task :limit seed-limit :types types)
   (let* (;; DES-0026 D6/D8, PLAN-0032 S1. Was: NEIGHBORS on each seed, PUSHNEW,
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
                          ;; DES-0032 D3. What the task's words reached, so a
                          ;; caller can tell a bundle whose subject is here
                          ;; from one whose seeds all rode a common word. The
                          ;; seeder's evidence reached the record writer and
                          ;; nothing else before this: :SEEDS is
                          ;; SUMMARIZE-ENTITIES output, so the REST response
                          ;; carried "score": null and "terms": [] on every
                          ;; seed and no caller could see it.
                          :terms (loop for (term . state) in term-states
                                       collect (list :term term
                                                     :state state))
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
        ;; Second value: what a durable record needs and a reader does not
        ;; (DES-0030 D3). The bundle is unchanged, so nothing that renders or
        ;; encodes one sees this unless it asks.
        (values bundle
                (list :tokens (task-tokens task)
                      :seeds seed-detail
                      :items (loop for item in (getf bundle :items)
                                   collect (list :id (getf (getf item :entity) :id)
                                                 :name (getf (getf item :entity) :name)
                                                 :band (getf item :band))))))))))

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

(defun terms-in-state (bundle state)
  "The reported terms of BUNDLE in STATE, in the order the caller wrote them."
  (loop for row in (getf bundle :terms)
        when (eq state (getf row :state))
          collect (getf row :term)))

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
    ;; DES-0032 D4, above the seeds rather than below them: the caller reads
    ;; this to decide whether to read the rest. REQ-0037's evidence is four
    ;; judged records in which the answer was that nothing exists and the
    ;; bundle returned eight lexical matches typeset exactly like a bundle
    ;; whose answer was present.
    (let ((unmatched (terms-in-state bundle :unmatched))
          (weak      (terms-in-state bundle :weak))
          (said nil))
      (when unmatched
        (format out "No indexed entity matches: ~{~a~^, ~}~%" unmatched)
        (setf said t))
      (when weak
        (format out "Matched only in prose, or below the last seed: ~{~a~^, ~}~%"
                weak)
        (setf said t))
      ;; R2's stated finding. Not an empty list for the caller to interpret,
      ;; and not an error -- the seeds are still printed below, because the
      ;; acceptance clause requires the negatives without buying them with the
      ;; positives.
      (when (and (getf bundle :terms)
                 (null (terms-in-state bundle :answered)))
        (format out "No word of this task is answered by any name in this ~
repository.~%")
        (setf said t))
      ;; Only when something was said. A bundle whose every term is answered
      ;; renders exactly as it did before this design, blank lines included.
      (when said (terpri out)))
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
