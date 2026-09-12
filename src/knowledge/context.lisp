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

(defparameter *context-source-share* 1/2
  "The fraction of the budget the source tier may spend. DES-0042 D1, PLAN-0045 S3.

Until PLAN-0045 the source tier was outside the budget entirely (DES-0026 D2),
so a bundle reporting 2477 of 4000 tokens handed the caller 7777 -- three of
four measured tasks exceeded their stated budget, the worst by 2.08 times.

D2's reasoning for the exemption was about *ordering* and is still right: a
body and a line drawn from one undifferentiated pot means the first three
bodies eat the bundle, measured there as 31 items for 3979 tokens naming 14 of
157 entities reached. What was wrong was concluding that the way to stop that
is to exempt bodies rather than to ration them. Two allowances inside one total
keeps the ordering and gives the caller a number that means something.

A half, and PLAN-0045 S5 measured 1/3, 1/2 and 2/3 against tools/test/acceptance.py
on a service restarted for each. All three score 43 of 45 with the same two
misses, fe-5 and r39-3, so recall does not choose between them:

    share   judged   bundle at a 4000 budget, two tasks
    1/3     43/45    154 items 2 bodies 3879 tokens | 111 items 4 bodies 2972
    1/2     43/45    131 items 3 bodies 4080        | 111 items 2 bodies 3757
    2/3     43/45    104 items 4 bodies 4091        |  93 items 4 bodies 4065

What separates them is composition, and no instrument scores that. 2/3 carries
the most bodies and would be the setting REQ-0040 R2's argument picks; 1/3
leaves a fifth of the budget unspent on two of the four tasks measured.

A half is chosen because it is the one that leans on nothing. Adopting 2/3
would be asserting R2 -- that depth beats breadth -- and R2 is the clause
DES-0042 D6 declined to settle, because the evidence for it is three judged
calls and the evidence against it is PLAN-0032 S1's 157 entities reached and 2
printed. Whether a caller who asked for depth wants five bodies or one is
REQ-0040's own open question and is still unmeasured.

DES-0042 D3 is what makes that acceptable: a wrong default now costs one call
with a larger number rather than a silently smaller answer.")

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

(defparameter *context-item-cost* nil
  "How to price one bundle item against the budget, or NIL for the console's.

A function of one item returning a token count. NIL means ITEM-COST prices
RENDER-ITEM, which is the text a console reader receives -- right for a console
and wrong for every other skin, which is BUG-0054.

The defect the variable exists for, measured on front-end 2026-08-27:
`loom_context budget=6000` reported `tokens: 5988` and delivered 81,793
characters of JSON, 13.7 per counted token against the four a token spells.
The budget was honoured exactly, in a currency the caller does not spend. An
MCP client refused the message and spilled it to a file -- which is REQ-0040
R1's own failure case, arriving through the knob written to prevent it.

A special variable rather than a keyword argument because three sites charge --
the document reserve, ADMIT-ITEM, and the source plan -- and because the two
callers that need to set it already bind *CONTEXT-VECTOR-STORE* and
*CONTEXT-EMBEDDER* around this call for the same layering reason: loom-knowledge
cannot name loom-serve's encoder, so the skin passes its own pricing in.")

(defun item-cost (item)
  "ITEM's cost against the budget, in the currency of whoever is paying.

ESTIMATE-TOKENS over RENDER-ITEM by default. RENDER-ITEM's own docstring
records why it is not PRINC-TO-STRING of the plist -- that over-counted the
console line fivefold -- and the correction was right for the console and left
every other skin paying a console price for a JSON answer."
  (if *context-item-cost*
      (funcall *context-item-cost* item)
      (estimate-tokens (render-item item))))

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

(defparameter *seed-owner-share* 3
  "How many members of one class may be seeds of one bundle.

ADMIT-SEEDS' third count, and BUG-0060 is why it exists. The first two charge a
slice and a name, and a method family escapes both: `LayerEditorState' has five
methods answering five different slices -- {active, partition}, {map},
{active, map}, {layer, partition}, {layer} -- under five distinct names. Neither
existing cap fires, both behave exactly as designed, and one class took six of
eight slots on a front-end task while `RenderEngineLeaflet', which the task
named by its exact full name, got none.

ADMIT-SEEDS' own docstring already contains the argument, one step short of
this case: \"A family sharing a slice is the same crowding as a family sharing a
word.\" A family sharing a *parent* is the same crowding again.

Three, to match *SEED-NAME-SHARE*, and advisory the same way: a task about one
class still seeds on that class as many times as the tree offers, because
ADMIT-SEEDS relaxes every cap rather than return fewer seeds than there are
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

(defun seed-matches (view origins types &key property-filters)
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
      (dolist (entity (find-entities view :property-filters property-filters))
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
whitespace from a string\". The design records the measurement.

INTEGERP rather than removing :PROSE by name, and the difference is not
cosmetic. A MATCH-RANK is an integer; every other value in that position marks
a match that did not come from a name and has no rank to contribute. Written as
(REMOVE :PROSE ...) it happened to be right while :PROSE was the only such
value, and stopped being right the moment DES-0040 D5 added (:SIMILARITY .
<cosine>): a cosine of 0.83 is not :PROSE, so it survived the remove and became
the minimum -- ranking a semantic candidate that matched no word at all as
better than a prefix match on a word the caller wrote."
  (let ((ranks (remove-if-not #'integerp (mapcar #'cdr matches))))
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

(defun lexical-terms (matches)
  "The terms of MATCHES that are words of the task.

A term is a string. DES-0040 D5 puts (:SIMILARITY . <cosine>) in the same
position, and a keyword there is the marker that this match came from a vector
rather than from a word -- so everything reasoning about *what the task asked*
filters on STRINGP and everything reasoning about *how a candidate arrived*
does not."
  (remove-if-not #'stringp matches :key #'car))

(defun dense-only-p (matches)
  "True when MATCHES holds similarity and nothing else.

Such a candidate answered no word the caller wrote. It is exempt from
ADMIT-SEEDS' slice cap, which counts how much of the *task* a group of seeds
answers -- a question a similarity match does not participate in."
  (and matches (null (lexical-terms matches))))

(defun seed-slice (matches)
  "The slice of the task a seed answers to: its matched terms, sorted.
The key the share in ADMIT-SEEDS is counted against.

Similarity is not part of a slice. Left in, every dense candidate in a bundle
would share one slice and *SEED-TERM-SHARE* would hold them to two -- which is
the wrong reading of a cap written to stop one English word filling the set."
  (format nil "~{~a~^ ~}" (sort (mapcar #'car (lexical-terms matches)) #'string<)))

(defparameter *rrf-k* 60
  "Reciprocal rank fusion's constant. DES-0040 D4.

60 is what the RRF literature settles on and is not tuned here. What it buys is
that the difference between rank 1 and rank 2 is small next to the difference
between appearing on a list and not appearing on it, which is the property that
makes fusion robust to two scores that share no scale.")

(defparameter *semantic-weight* 1.5
  "How much a place on the semantic list is worth against a place on the
lexical one.

Simulated at the seed level before the fusion existed: equal weight reached 448
of 450 on known-item -- the union ceiling exactly, losing none of the eleven
exact-name cases REQ-0048 R2 protects -- and 24 of 120 on the mismatch family
against dense-alone's 34. At 1.5 and above those invert to 443 and 34.

Equal, because the simulation could not see the neighbour band and the band is
where every one of the mismatch family's nine lexical hits comes from. A fused
seed set gets an expansion too, and whether the ten cases equal weight appears
to lose return as items is a question only a measurement with the band running
can answer. PLAN-0043 S6 is that measurement and is what sets this number.")

(defparameter *fusion* :reciprocal-rank
  "How FUSE-RANKINGS combines the lexical and the dense list.

:RECIPROCAL-RANK reads positions and ignores scores, which is what DES-0040 D4
built and what every number recorded before DES-0050 was measured against.

:RELATIVE-SCORE normalises each list against its own best and worst and adds
them with *LEXICAL-WEIGHT*. DES-0050 D5.

Two values rather than one, so the change can be measured against itself: bound
to :RECIPROCAL-RANK, nothing downstream can behave differently than it did
before relative score fusion existed. That identity is step 1 of DES-0050's
order and it is what makes the numbers after step 2 readable.")

(defparameter *fusion-head* 20
  "How many lexical candidates enter the relative-score normalisation.

Bounded rather than the whole list, and DES-0050 D6 is why. SEED-SCORE carries
the entity type in a band worth 1000000, so one :FILE or :DOCUMENT inside the
head multiplies the range by ten and compresses the named boundary -- the
100000 band that normalisation exists here to find -- into a tenth of the
interval, handing the head back to the dense list.

50 keeps the odds low and does not remove the case. Measured at 20, 50 and 200
on DES-0050's three tasks, all three place the target identically, because no
type-band candidate falls inside any of them. That is luck rather than a
property and nothing detects it yet.

A candidate outside the head contributes nothing from the lexical side, which
is the treatment a candidate absent from the dense list already gets.")

(defparameter *lexical-weight* 0.4
  "The lexical list's share of a relative-score fusion, in [0,1].

The dense list takes the rest. *SEMANTIC-WEIGHT* at 1.5 against a lexical 1.0
is the same split written as a ratio and corresponds to 0.4 here.

Used when the task named the candidate at lexical rank 1.
*LEXICAL-WEIGHT-UNNAMED* is used when it did not, and DES-0050 D8 is why the
two are separate.")

(defparameter *lexical-weight-unnamed* 0.1
  "The lexical list's share when the task named nothing at lexical rank 1.

A task whose top lexical candidate was not named by the caller has a lexical
list with no discontinuity in it -- every candidate sits in one band, and the
ordering inside that band is coverage and match quality rather than anything
the caller wrote. `tools/test/cases/mismatch.json' is 120 queries built to be
exactly that case: each describes an entity in words its author did not use,
checked mechanically, so no lexical candidate can be the answer and every slot
the lexical list takes is a slot the dense list needed.

Equal to *LEXICAL-WEIGHT* is the fixed-weight behaviour and is the value to set
to turn this off.

Measured at 0.4 fixed, relative score fusion holds known-item at 435 of 450 and
takes acceptance from 33 to 35 strict and 39 to 44 lenient, and drops mismatch
from 31 to 25. The two families want opposite things from one number, which is
what makes it two.")

(defun fuse-rankings (lexical semantic &key protected lexical-score
                                            (lexical-weight *lexical-weight*))
  "One ranked list from two, by *FUSION*. DES-0040 D4 and DES-0050 D5.

    :RECIPROCAL-RANK   score(c) = sum over the lists holding c of
                                    w / (*RRF-K* + rank(c))

    :RELATIVE-SCORE    each list normalised to [0,1] against its own best and
                       worst, then *LEXICAL-WEIGHT* * lexical + the rest * dense

Rank fusion was chosen because a cosine and a SEED-SCORE band are not on one
scale and nothing here should pretend they are. DES-0032 refused to place a
threshold in a quantity it had measured across six queries; this refused to
calibrate two.

What it cannot do is tell a list whose ordering carries information from one
whose ordering carries almost none, and both lists that reach here are eight
long. The dense list spans 5 to 7% of its best cosine, because
*SEMANTIC-RELATIVE-FLOOR* builds it to sit within 10%. The lexical list opens
with a 100000-unit jump wherever the caller named something, because SEED-SCORE
is a band vector. Rank fusion flattens the second into the first.

It also cannot be retuned out of it. Lexical rank 1 outranks semantic rank N
only when N > *RRF-K*/2 + 1.5, which at 60 needs a dense list of 32 against a
*SEMANTIC-LIMIT* of 8 -- and dropping the constant does not fix it either:
measured at 60, 30, 10, 3 and 0 against BUG-0060's recorded lists, the target
stays at fused rank 12, 12, 12, 12 and 10. DES-0050 D3.

:RELATIVE-SCORE reaches rank 4. It needs no code to find the cliff: normalising
over *FUSION-HEAD* candidates divides by a range of about 1000, so a
100000-unit jump lands past the top of the interval and every named candidate
normalises to approximately 1.0. That is also how it can go wrong silently, and
DES-0050 D6 names both ways.

LEXICAL-SCORE reads one entity\'s SEED-SCORE and is required for
:RELATIVE-SCORE, which has nothing to normalise without it. The rank path
ignores it.

A candidate on both lists carries both kinds of match: its lexical terms and
its similarity. That is what makes it not dense-only, so ADMIT-SEEDS charges it
to the slice its terms make, exactly as it would have without an embedder.

PROTECTED is the entities the task named, and they sort ahead of everything
else. A named candidate is one whose name *is* one of the words the caller
wrote -- NAMED-BY-TASK-P, rank 0 on a term from TASK-TERMS -- and REQ-0016 R1
has required since it was written that such a query seed from such an entity.

Without it, dense displaces them, and PLAN-0043 S6 measured that costing three
of REQ-0048 R2\'s eleven cases. The reason is a property of the embedder rather
than a tuning failure: a document is a name and a docstring, so the barest
member of a family has the document least dominated by its own name, and a
query that *is* a name resembles its longer relatives more than itself.
`mapper to native\' returns MAPMAPPER.TONATIVE at 0.982 and MAPPER.TONATIVE at
0.635. No threshold separates those, because the wrong answers score higher.

The plainest statement of why this band exists: grep would find MAPPER.TONATIVE
for `mapper to native\'. A retrieval mechanism that does worse than grep on a
query naming a thing has not earned the right to rank it.

The bonus is 1.0 against a reciprocal-rank sum that cannot exceed about 0.04,
so it is a band and not a weight -- protected candidates keep their order among
themselves and nothing unprotected can climb past one.

LEXICAL is returned unchanged when SEMANTIC is empty. Fusing one list would
reproduce its order -- the weights are positive and the ranks distinct -- but
returning it outright is what makes REQ-0048 R6 an identity rather than an
arithmetic coincidence, and it is the path every query takes on a machine with
no embedder."
  (if (null semantic)
      lexical
      (let ((scores (make-hash-table :test #'eq))
            (matches (make-hash-table :test #'eq))
            (order '()))
        (flet ((note (entity contribution found)
                 (unless (nth-value 1 (gethash entity scores))
                   (push entity order))
                 (incf (gethash entity scores 0.0d0) contribution)
                 (setf (gethash entity matches)
                       (append (gethash entity matches) found))))
          (ecase *fusion*
            (:reciprocal-rank
             (loop for (entity . found) in lexical
                   for rank from 1
                   do (note entity (/ 1.0d0 (+ *rrf-k* rank)) found))
             (loop for (entity . found) in semantic
                   for rank from 1
                   do (note entity (/ (float *semantic-weight* 1.0d0)
                                      (+ *rrf-k* rank))
                            found)))
            (:relative-score
             (unless lexical-score
               (error "FUSE-RANKINGS was asked for a relative-score fusion ~
                       without LEXICAL-SCORE. The lexical side has no scores to ~
                       normalise, and the fusion would silently be the dense ~
                       list alone."))
             (let* ((head (subseq lexical 0 (min *fusion-head* (length lexical))))
                    (values (mapcar (lambda (pair) (funcall lexical-score (car pair)))
                                    head))
                    ;; SEED-SCORE is lower-is-better, so the best is the least
                    ;; of these and the normalisation runs down from the worst.
                    (worst (reduce #'max values))
                    (best (reduce #'min values))
                    (span (- worst best))
                    (weight (float lexical-weight 1.0d0))
                    (cosines (mapcar (lambda (pair)
                                       (or (cdr (assoc :similarity (cdr pair))) 0))
                                     semantic))
                    (top (reduce #'max cosines))
                    (bottom (reduce #'min cosines))
                    (spread (- top bottom)))
               ;; A list whose members all score alike holds candidates nothing
               ;; separates. They normalise together at 1.0 rather than through
               ;; a division by zero, which is the same answer with the
               ;; degenerate case named.
               (loop for pair in head
                     for value in values
                     do (note (car pair)
                              (* weight (if (zerop span)
                                            1.0d0
                                            (/ (- worst value) (float span 1.0d0))))
                              (cdr pair)))
               (loop for pair in semantic
                     for cosine in cosines
                     do (note (car pair)
                              (* (- 1.0d0 weight)
                                 (if (zerop spread)
                                     1.0d0
                                     (/ (- cosine bottom) (float spread 1.0d0))))
                              (cdr pair)))))))
        (dolist (entity protected)
          (when (nth-value 1 (gethash entity scores))
            (incf (gethash entity scores) 1.0d0)))
        (let ((fused (loop for entity in (nreverse order)
                           collect (cons entity (gethash entity matches)))))
          ;; STABLE-SORT so that a tie keeps the order the lists gave it, which
          ;; on a tie between two lexical candidates is SEED-SCORE\'s order.
          (stable-sort fused #'> :key (lambda (pair) (gethash (car pair) scores)))))))

(defun seed-owner (entity)
  "The class a method belongs to, from its own name, or NIL when it has none.

Read off the name because that is where it is: a JavaScript method is minted as
`RenderEngineLeaflet.renderLayer' and carries no edge to its class and no owner
property, so the qualified name is the only record of the family.

NIL for a :FILE and a :DOCUMENT, whose names are paths and whose dots are
extensions, and NIL for any name with no dot -- which is every Lisp definition
in this tree, so the cap this feeds is inert on a Lisp-only repository rather
than guessing at a family that is not spelled."
  (unless (member (entity-type entity) '(:file :document))
    (let* ((name (and (slot-boundp entity 'name) (name entity)))
           (dot  (and name (position #\. name :from-end t))))
      (when (and dot (plusp dot))
        (subseq name 0 dot)))))

(defun admit-seeds (ranked limit &key protected)
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
        (family (make-hash-table :test #'equalp))
        (chosen '())
        (held   '())
        (taken  0))
    (dolist (pair ranked)
      (when (< taken limit)
        (let* ((slice (seed-slice (cdr pair)))
               (names (gethash slice spent))
               (name  (significant-name (car pair)))
               ;; BUG-0060's third charge. NIL for anything whose name does not
               ;; spell a parent, and a NIL owner is uncharged rather than
               ;; sharing one bucket -- every unqualified name in the tree would
               ;; otherwise be one family and cap each other at three.
               (owner (seed-owner (car pair))))
          (cond ((and (or (dense-only-p (cdr pair))
                          (< (length names) *seed-term-share*)
                          (member name names :test #'string-equal))
                      (< (gethash name copies 0) *seed-name-share*)
                      (or (null owner)
                          (< (gethash owner family 0) *seed-owner-share*)))
                 (pushnew name (gethash slice spent) :test #'string-equal)
                 (incf (gethash name copies 0))
                 (when owner (incf (gethash owner family 0)))
                 (incf taken)
                 (push (car pair) chosen))
                (t (push (car pair) held))))))
    (setf chosen (nreverse chosen)
          held   (nreverse held))
    (let ((admitted (append chosen
                            (subseq held 0 (min (- limit taken) (length held))))))
      ;; PROTECTED is guaranteed a slot, not a place. A candidate the task named
      ;; by its own word must appear -- grep would find it -- and *PROTECT-NAMED*
      ;; measured that promoting such candidates to the front instead costs more
      ;; than it recovers: acceptance 43 to 41, because NAMED-BY-TASK-P fires on
      ;; every entity whose whole name is a common word the caller happened to
      ;; type. Inclusion is the requirement; rank one was never the requirement.
      (let ((missing (remove-if (lambda (entity) (member entity admitted :test #'eq))
                                protected)))
        (if (null missing)
            admitted
            ;; Each missing one displaces the lowest-ranked admitted candidate
            ;; that is not itself protected, so the order of everything that
            ;; stays is the order the fusion gave it.
            (let ((result (copy-list admitted)))
              (dolist (entity missing result)
                (let ((victim (find-if-not (lambda (e) (member e protected :test #'eq))
                                           (reverse result))))
                  (when victim
                    (setf result (substitute entity victim result :test #'eq
                                                                  :count 1)))))))))))

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

(defparameter *semantic-limit* 8
  "How many entities the scan proposes.

The same eight ADMIT-SEEDS may admit, and deliberately not more. DES-0040 D4
fuses two ranked lists by reciprocal rank, and a dense list twice as long as
the lexical one would win slots by being longer rather than by being better.")

(defparameter *protect-named* nil
  "Whether an entity the task named sorts ahead of everything else in the fusion.

Off, because it was measured and it was worse. At weight 1.5 and list length 6
it took acceptance from 43 of 45 to 41 and known-item from 443 to 441, losing
POLYGONSTOPARTITION and ARCH-0001 -- two cases that were being found -- while
recovering none of the three it was written for.

The mechanism is too blunt for what it was aimed at. NAMED-BY-TASK-P fires on
any entity whose whole name is one of the caller\'s words, which on a real tree
is a great many short common ones, so promoting all of them ahead of everything
floods the slots rather than protecting a specific answer.

It gates two mechanisms and both measured worse, at weight 1.5, list length 8
and a relative cut of 0.90 -- the best setting otherwise found, 443 of 450 on
known-item, 39 of 120 on mismatch and 43 of 45 judged:

    promoting named candidates to the front   441 / 39 / 41
    guaranteeing them a slot without a place  433 / 38 / 42

The second was the more careful idea and did worse. Both fail the same way and
for the same reason: NAMED-BY-TASK-P fires on every entity whose whole name is a
word the caller happened to type, and on a real query -- \"segment terrain into
region polygons\" -- SEGMENT is such an entity. Protecting a set that large
displaces candidates that were being found, wherever in the pipeline the
protection is applied.

Kept, gated and measured rather than deleted: the *idea* -- that a query naming
a thing must reach that thing, because grep would -- is REQ-0016 R1 and is not
in doubt. What is refused is protecting everything NAMED-BY-TASK-P calls named.
A predicate that picked out the three cases REQ-0048 R2 names, and not SEGMENT,
would be a different matter and does not exist yet.")

(defparameter *semantic-relative-floor* 0.90
  "How close to the best cosine a semantic candidate must be, as a fraction.

0.0 admits the whole list. 0.9 admits only what scores within ten per cent of
the best match this query found.

Relative rather than absolute, which is what *SEMANTIC-FLOOR* is and why that
one is 0.0 and staying there: an absolute threshold asks \"is this similar\",
and the measurement showed the wrong answers scoring higher than the right one,
so no absolute number separates them. This asks a different question -- \"did
anything stand out\" -- and the answer differs per query rather than per
repository. A query with one clear match contributes one candidate; a query
whose top six are all equally mediocre contributes six, or none if the caller
would rather it did not.")

(defparameter *semantic-floor* 0.0
  "The cosine below which a semantic candidate is not proposed at all.

0.0 admits everything the scan returns, which is what PLAN-0043 S6 measured
first and where REQ-0048 R2 failed: three of the eleven cases only the lexical
seeder finds were displaced by candidates that were merely the nearest
available rather than near.

MEASURED AND LEFT AT 0.0. A floor cannot fix what it was proposed for. The
three displaced cases, with the cosine of every candidate that displaced them
and of the answer itself:

    slot defn            -> slot-defn         0.927 0.911 0.911 0.876 0.807
                            the answer:       0.792
    mapper to native     -> Mapper.toNative   0.982 0.942 0.929 0.924 0.916
                            the answer:       0.635
    capability whose
      referenced ...     -> piece-type-speed  0.769 0.769 0.738 0.720 0.715
                            the answer:       0.592

In every case the displacing candidates score *higher* than the answer, so a
floor that removed them would remove the answer first. The parameter stays at
0.0 and the measurement stays here, because a floor is the obvious idea and
this is what it is worth.

What the numbers show instead is a property of the embedder rather than of the
threshold. `mapper to native\' is the name MAPPER.TONATIVE written as words,
and what comes back is every elaborated sibling -- MAPMAPPER.TONATIVE,
STYLEMAPPER.TONATIVE, MARKMAPPER.TONATIVE -- ahead of the plain one. Same for
`slot defn\': DEFN-SLOT, FIND-SLOT-DEFN and SLOT-DEFN-ERROR all beat SLOT-DEFN.
A document is a name and a docstring, so the barest member of a family is the
one whose document is least dominated by the words of its own name, and a query
that *is* a name resembles its longer relatives more than itself.

That is REQ-0045 R4's territory -- lexical stays authoritative for a query that
names a thing -- and the fix it points at is a rule rather than a number: a
candidate the task named must not be displaced by one that merely resembles it.
NAMED-BY-TASK-P is that predicate and already exists.")

(defun semantic-candidates (view task)
  "Candidates the embedder proposes for TASK, as an alist of entity to matches.

Each carries one match, (:SIMILARITY . <cosine>), which is DES-0040 D5 and does
three things no extra code is needed for. CLASSIFY-TERMS walks matched terms
and :SIMILARITY is not one of the task\'s words, so a semantic seed can never
mark a term ANSWERED -- REQ-0048 R4 holds by construction rather than by a
guard. BEST-NAME-RANK keeps only integers, so a cosine contributes no name
rank. And the record shows the caller that this seed arrived on similarity
rather than on a word they wrote.

NIL for every reason there is: no embedder configured, no store, a store whose
identity does not match, an embedder that cannot be reached, an id in the store
that is no longer in the view. REQ-0048 R6 gives them one meaning, so they get
one return value and the caller needs no branch.

An id the view does not hold is dropped rather than reported. The store is
derived from an index that has since moved -- PLAN-0043 S2b makes that rare and
does not make it impossible -- and a stale id is exactly the fabricated fact
CON-0001 refuses, not an error to raise at a caller who asked about something
else."
  (when (and *context-embedder* *context-vector-store*)
    (handler-case
        (let* ((vectors (loom-embed:embed-texts *context-embedder* (list task)))
               (query (and (plusp (length vectors)) (aref vectors 0)))
               (hits (and query (loom-embed:nearest *context-vector-store*
                                                    query *semantic-limit*))))
          (let ((best (if hits (cdr (first hits)) 0.0)))
            (loop for (id . cosine) in hits
                  for entity = (and (>= cosine *semantic-floor*)
                                    (>= cosine (* *semantic-relative-floor* best))
                                    (get-entity view id))
                  when entity
                    collect (cons entity (list (cons :similarity cosine))))))
      ;; REQ-0048 R6: an embedder that cannot answer is an embedder that is not
      ;; there, and neither is reported. The memo is what stops the next query
      ;; paying for the discovery again.
      (loom-embed:embedder-unavailable () nil))))

(defun seed-entities (view task &key (limit 8) types property-filters)
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
      (seed-matches view (task-token-origins task) types
                    :property-filters property-filters)
   (let* ((demote-tests (not (task-wants-tests-p task)))
         (terms      (task-terms task))
         (origins    (task-token-origins task))
         (corpus-size (length (all-entities view)))
         ;; MATCHES stays whole for the term report below: a term answered only
         ;; by candidates this drops is WEAK, and calling it UNMATCHED would say
         ;; the index holds nothing of the kind. CANDIDATES is what the ranking
         ;; and the admission see.
         (candidates (strong-candidates matches origins))
         (semantic   (semantic-candidates view task))
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
         ;; Scored once into a table rather than inside the sort key, because
         ;; DES-0050's fusion reads the same numbers the sort does and
         ;; recomputing them there would let the two drift. One entry per
         ;; entity: SEED-MATCHES keys its alist by entity, so CANDIDATES holds
         ;; no duplicates to disagree about.
         (scored     (let ((table (make-hash-table :test #'eq)))
                       (dolist (pair candidates table)
                         (setf (gethash (car pair) table)
                               (seed-score (car pair) (cdr pair)
                                           :demote-tests demote-tests
                                           :terms terms
                                           :production production
                                           :origins origins
                                           :frequencies frequencies
                                           :corpus-size corpus-size)))))
         (lexical    (stable-sort (copy-list candidates) #'<
                                  :key (lambda (pair) (gethash (car pair) scored))))
         ;; DES-0040 D4. With no embedder this is LEXICAL itself, so nothing
         ;; below this line can behave differently than it did before dense
         ;; retrieval existed.
         ;; REQ-0016 R1 through the fusion: an entity the task named by its own
         ;; word is not displaced by one that merely resembles it.
         ;; The entities the task named by a word the caller wrote. Used two
         ;; ways and they are not the same thing: *PROTECT-NAMED* sorts them
         ;; first, which measured worse, and ADMIT-SEEDS guarantees them a slot,
         ;; which is what REQ-0016 R1 actually asks for.
         (named      (loop for (entity . found) in candidates
                           when (named-by-task-p entity found terms)
                             collect entity))
         (protected  (when *protect-named* named))
         ;; The weight the fusion gives the lexical side turns on whether the
         ;; caller named the candidate at the head of it. A lexical list whose
         ;; first entry was not named has no discontinuity: every candidate is
         ;; in one band and the ordering inside it is coverage rather than
         ;; anything the caller wrote. DES-0050 D8.
         (lexical-named (and lexical (member (car (first lexical)) named :test #'eq)))
         (ranked     (fuse-rankings lexical semantic :protected protected
                                    :lexical-weight (if lexical-named
                                                        *lexical-weight*
                                                        *lexical-weight-unnamed*)
                                    :lexical-score (lambda (entity)
                                                     (gethash entity scored))))
         (chosen     (admit-seeds ranked limit :protected protected)))
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
    ;; and tools/test/acceptance.py reads it positionally. DES-0032 D2's report goes
    ;; after it.
    (values chosen
            (loop for entity in chosen
                  for rank from 1
                  ;; RANKED and not MATCHES: a dense-only candidate is not in
                  ;; SEED-MATCHES at all, and ASSOC would return NIL -- which
                  ;; SEED-SCORE reads as "matched nothing" and the record
                  ;; writer writes as a null `terms\'. That is precisely the
                  ;; shape BUG-0037 left behind when a destructive sort lost
                  ;; the matches, and 207 of 246 recorded bundles carried it.
                  for pair = (assoc entity ranked :test #'eq)
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
                                ;; record is read by tools/test/acceptance.py.
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

(defun band-remainder (band candidates items)
  "The summaries of CANDIDATES whose band was BAND and that ITEMS did not admit.

DES-0046. The four candidate lists a bundle carries -- :SEEDS, :DECISIONS,
:DOCUMENTS, :MENTIONS -- were SUMMARIZE-ENTITIES over the whole set the walk
found, and a bundle that fit carried every one of them again in :ITEMS under
its :BAND. Deduplicated against :ITEMS the list is empty on a bundle that fit
and names exactly the candidates the budget refused on one that truncated,
which is REQ-0061 R2's what-the-walk-could-not-send in the units the caller
can act on -- names, not a count. The count is :BANDS.

An admitted candidate is one an ITEMS entry of the same BAND carries by id."
  (let ((admitted (loop for item in items
                        when (eq band (getf item :band))
                          collect (getf (getf item :entity) :id))))
    (summarize-entities
     (remove-if (lambda (e) (member (id e) admitted :test #'equal))
                candidates))))

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
          ;; REQ-0049 R1. Computed for every item and printed only for a seed
          ;; (ITEM-SUMMARY-LINE), so a consumer over REST or MCP can read it on
          ;; any band while the rendered text stays inside its budget.
          :summary (definition-summary entity)
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
                                     (seed-limit 8) types source-fn provenance
                                     property-filters
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
  ;; PROVENANCE is REQ-0050 R1: which tree this answer came from and how far
  ;; behind it the index is, supplied by the caller for the reason SOURCE-FN is
  ;; -- loom-knowledge is handed a graph and never learns which repository it
  ;; belongs to. Carried whole and rendered by RENDER-CONTEXT, so a bundle
  ;; pasted into a session an hour later still says what it was built from.
  (multiple-value-bind (seeds seed-detail term-states)
      (seed-entities view task :limit seed-limit :types types
                     :property-filters property-filters)
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
         (truncated nil)
         ;; PLAN-0045 S1, DES-0042 D3. What the budget refused, kept rather
         ;; than discarded: ADMIT-ITEM already computes the cost of every item
         ;; it rejects and threw it away to set the boolean above. The sum is
         ;; what lets a bundle say what a larger budget would buy, which is the
         ;; number a caller cannot compute from anything they are sent.
         (withheld-items 0)
         (withheld-tokens 0)
         (withheld-source-tokens 0))
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
                                   :key (lambda (i) (item-cost i))))))
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
                 (let ((cost (item-cost item)))
                   (cond (free
                          (incf sourced-tokens cost)
                          (push item items)
                          t)
                         ((<= (+ used cost) cap)
                          (incf used cost)
                          (push item items)
                          t)
                         (t (setf truncated t)
                            (incf withheld-items)
                            (incf withheld-tokens cost)
                            nil))))
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
          ;;
          ;; PLAN-0045 S3. The bodies are decided before any line is charged,
          ;; rather than interleaved with them, and the reason is that a seed
          ;; carries its line and its body as one item: costing them in one
          ;; pass would mean the index allowance was known only after it had
          ;; already been spent. So the source plan is settled first -- at most
          ;; *CONTEXT-SOURCE-DEFINITIONS* items, five today -- and the index
          ;; tier is then capped at what the source tier did not use, so an
          ;; unspent source allowance becomes lines rather than being wasted.
          ;;
          ;; A body that does not fit costs its body and not its seed. The item
          ;; is admitted without :SOURCE and charged to the index tier like any
          ;; other line, because a seed the task named is what the bundle is
          ;; for and dropping it to save a body would spend the answer on the
          ;; illustration.
          (let* ((source-cap (floor (* budget *context-source-share*)))
                 (planned
                   (when source-fn
                     (loop with spent = 0
                           for entity in seeds
                           for rank from 0
                           while (< rank source-definitions)
                           for source = (funcall source-fn (id entity))
                           for item = (context-item view entity :relations t
                                                              :band :seed :source source)
                           for cost = (item-cost item)
                           if (<= (+ spent cost) source-cap)
                             collect (cons (id entity) item)
                             and do (incf spent cost) (incf sourced-tokens cost)
                           else
                             ;; Costed even though it was refused. Without this
                             ;; the suggested budget under-states what it would
                             ;; take to receive everything by exactly the bodies
                             ;; a caller most wants -- and a caller who raises
                             ;; the budget to the number they were given and
                             ;; still does not get them has been told something
                             ;; false.
                             do (setf truncated t)
                                (incf withheld-source-tokens cost))))
                 (index-cap (- budget sourced-tokens)))
            (dolist (pair planned) (push (cdr pair) items))
            (loop for entity in seeds
                  for rank from 0
                  ;; Already admitted with its body above.
                  unless (assoc (id entity) planned :test #'equal)
                    do (admit-item (item-for entity t :seed)
                                   (if (zerop rank) index-cap (- index-cap reserve)))))
          ;; Then the reserve is released: these are measured against the full
          ;; budget, and fit by construction unless the ceiling clipped them.
          ;; The reserve is released: these are measured against the whole
          ;; index allowance, and fit by construction unless the ceiling
          ;; clipped them. BUDGET minus what the bodies took, not BUDGET --
          ;; that difference is the whole of DES-0042 D1.
          (let ((index-cap (- budget sourced-tokens)))
            (dolist (item document-items) (admit-item item index-cap))
            (dolist (r reaches)
              (admit-item (context-item view (reach-entity r)
                                        :relations nil :band :neighbour :reach r)
                          index-cap)))))
      (let* ((sourced (count-if (lambda (i) (getf i :source)) items))
             (wanted (if source-fn (min source-definitions (length seeds)) 0))
             (bundle (list :task task
                          :provenance provenance
                          ;; DES-0032 D3. What the task's words reached, so a
                          ;; caller can tell a bundle whose subject is here
                          ;; from one whose seeds all rode a common word.
                          :terms (loop for (term . state) in term-states
                                       collect (list :term term
                                                     :state state))
                          :items (reverse items)
                          ;; DES-0046. The four candidate lists were 26% of a
                          ;; measured bundle, and every entry a bundle that fit
                          ;; also carried in :ITEMS under a :BAND (DES-0020 D6).
                          ;; Each now carries only what its band did NOT admit:
                          ;; empty on a bundle that fit, the refused candidates
                          ;; by name on one that truncated. A client
                          ;; reconstructs the whole set as a band's :ITEMS
                          ;; unioned with its list -- which is what
                          ;; `tools/test/recall.py' scores strict recall on,
                          ;; and the reason C3 (drop the lists) was rejected:
                          ;; the seed band truncates, and a target the seeder
                          ;; ranked but the budget dropped must still count.
                          :seeds     (band-remainder :seed     seeds     items)
                          :decisions (band-remainder :decision decisions items)
                          :documents (band-remainder :document documents items)
                          :mentions  (band-remainder :mention  mentions  items)
                          ;; The count beside the lists: :FOUND is what the
                          ;; walk produced for a band before the budget, :SENT
                          ;; is the :ITEMS of that band, and :FOUND minus :SENT
                          ;; is the length of the list above -- so :BANDS and
                          ;; the lists cannot disagree. :NEIGHBOUR's :FOUND is
                          ;; REACHES after the band-duplicate removal, so a
                          ;; document one hop from a seed is counted once, in
                          ;; its own band. RENDER-CUTOFF prints this; a REST
                          ;; caller reads it without unioning anything.
                          :bands (flet ((sent (band)
                                          (count band items
                                                 :key (lambda (i) (getf i :band)))))
                                   (list :seed      (list :found (length seeds)
                                                          :sent (sent :seed))
                                         :decision  (list :found (length decisions)
                                                          :sent (sent :decision))
                                         :document  (list :found (length documents)
                                                          :sent (sent :document))
                                         :mention   (list :found (length mentions)
                                                          :sent (sent :mention))
                                         :neighbour (list :found (length reaches)
                                                          :sent (sent :neighbour))))
                          :budget budget
                          ;; Both tiers, because since PLAN-0045 S3 the budget
                          ;; is both tiers. Reporting the index alone here is
                          ;; the defect DES-0042 was written about, and it
                          ;; survived being written about: this field said
                          ;; `used' until the cutoff signal made the shortfall
                          ;; visible on screen.
                          :tokens (+ used sourced-tokens)
                          :index-tokens used
                          :truncated truncated
                          ;; DES-0042 D3. :FOUND-TOKENS is used plus withheld:
                          ;; what this walk found, and therefore the budget that
                          ;; would send all of it. All of what the *walk* found
                          ;; -- *CONTEXT-EXPANSION-HORIZON* bounds the search
                          ;; before any budget is consulted, so a larger budget
                          ;; prints more of what was reached and never more of
                          ;; what was searched. Anything here that read as a
                          ;; claim about the graph would be CON-0001's
                          ;; fabricated fact wearing a percentage.
                          :withheld-items withheld-items
                          ;; The total, for the arithmetic below; the two tiers
                          ;; separately, because the per-tier lines say which
                          ;; budget to raise and a line that folded the other
                          ;; tier's shortfall into its own would send a caller
                          ;; to the wrong one.
                          :withheld-tokens (+ withheld-tokens withheld-source-tokens)
                          :withheld-index-tokens withheld-tokens
                          :withheld-source-tokens withheld-source-tokens
                          ;; The budget that would withhold nothing, which is
                          ;; not simply what the walk cost. The source tier is
                          ;; capped at *CONTEXT-SOURCE-SHARE* of the total, so a
                          ;; bundle whose bodies are expensive needs a total
                          ;; large enough that the share covers them -- and a
                          ;; caller who raises the budget to the number they
                          ;; were given and still does not get the bodies has
                          ;; been told something false. Measured while building
                          ;; this: a suggestion of 10019 delivered 4 of 5 bodies
                          ;; and reported a fifth still withheld.
                          :found-tokens
                          (let ((total (+ used sourced-tokens
                                          withheld-tokens withheld-source-tokens))
                                (source-needed (+ sourced-tokens withheld-source-tokens)))
                            (max total (ceiling source-needed *context-source-share*)))
                          ;; What the source tier actually spent, reported rather
                          ;; than inferred: a caller comparing two bundles wants
                          ;; to know whether it got bodies without scanning for
                          ;; them.
                          :source-tokens sourced-tokens
                          :source-definitions (if source-fn source-definitions 0)
                          :sourced sourced
                          ;; Bodies asked for and not carried. Not a counter in
                          ;; ADMIT-ITEM: the source tier is admitted with :FREE
                          ;; and never reaches the rejecting branch, so a
                          ;; counter written there would report the index tier
                          ;; and read as correct until the tiers share a budget.
                          ;;
                          ;; WANTED is bounded by the seeds as well as by the
                          ;; count, because a bundle with three seeds and five
                          ;; slots withheld nothing -- there were two fewer
                          ;; bodies to carry, which is a fact about the query
                          ;; rather than about the budget. Reporting those two
                          ;; as withheld would send a caller to raise a number
                          ;; that would buy them nothing.
                          :withheld-bodies (max 0 (- wanted sourced)))))
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

(defparameter *context-summary-cost* 3
  "The highest walk cost at which an item still carries a description.

REQ-0049 R3, which asked whether the cut is a count or a cost and left it
unmeasured. A cost, because the walk already orders the bundle by one and a
count would cut across bands: twenty items by count takes the first twenty
neighbours of whichever seed was expanded first.

3 is where an outgoing :CALLS and a :CONTAINS land, so a definition says what
it is made of and what file holds it. 4 is an *incoming* :CALLS, and the
asymmetry *EDGE-COSTS* already records is the reason to stop before it: an
outgoing call is the entity's implementation, an incoming one is its client
set, and a client's docstring describes the client rather than the thing the
task asked about.

Measured by tools/test/summary-band.lisp over five tasks on three trees, 2026-08-23.
Raising 3 to 4 added 5 descriptions across all five and cost no item on any of
them; the cut that costs something is 3, which on game-server's `data-handler'
trades 18 index lines for 32 descriptions at 354 tokens. Every task at every
cut stays inside its budget, worst 1.00 -- the budget makes the trade rather
than admitting an overflow, and the thing traded is index lines.

NIL on a seed and on the three document bands, which are therefore never cut by
this -- a seed is the subject and a document line has no docstring to print.")

(defun item-summary-line (item)
  "ITEM's own description, indented, or NIL when it does not carry one.

REQ-0049 R1 and R3. Two cuts, and the first is not the one R1 anticipated.

An item printing its body does not also print its description. The description
is the first sentence of the docstring and the body holds the whole docstring
three lines below it. Measured on `context refactor Loom to use utils where
needed\': 5 of the 8 seeds printed a body, so the band as first built spent
three quarters of its tokens restating what the reader was about to read. The
three seeds that gained anything were the ones with no body -- which is the
case the description exists for, and which the seed-only rule reached by
accident rather than by aim.

The second cut is cost. A seed and a near neighbour are where relevance is
still undecided; the tail of a cost-ordered walk is a list to skim on names,
and 130 items at *DEFINITION-SUMMARY-BUDGET* would be 3120 tokens against a
4000 budget."
  (when (and (null (getf item :source))
             (let ((cost (getf item :cost)))
               (or (null cost) (<= cost *context-summary-cost*))))
    (getf item :summary)))

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
  (let ((entity (getf item :entity))
        (summary (item-summary-line item)))
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
      ;; REQ-0049 R1, on its own line rather than appended to the one above:
      ;; the entity line is already five fields wide and a sentence on the end
      ;; of it would wrap unpredictably against every terminal.
      (when summary (format out "    ~a~%" summary))
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

(defun render-cutoff (bundle out)
  "The bundle\'s size, and what a larger budget would buy. DES-0042 D3.

Three facts answering three questions. The percentage says whether the answer
in hand is most of the answer. The suggested budget says what to ask for, which
is the one number a caller cannot compute from anything they are sent. The
per-tier lines say *which* budget to raise, because index budget buys names and
source budget buys bodies and one figure cannot tell them apart.

`what this walk found\' is the exact claim and the wording is not a matter of
taste. *CONTEXT-EXPANSION-HORIZON* bounds the search by accumulated cost before
any budget is consulted, so a larger budget prints more of what was reached and
never more of what was searched. A line reading `8000 sends everything\' would
be a completeness claim about the graph, which is CON-0001\'s fabricated fact
wearing a percentage.

Printed only when something was withheld. A bundle that fits says so in its
first line by having nothing after it, and four lines of accounting on every
answer would spend the budget this exists to report."
  (let* ((tokens (getf bundle :tokens))
         (found (or (getf bundle :found-tokens) tokens))
         (withheld-items (or (getf bundle :withheld-items) 0))
         (withheld-bodies (or (getf bundle :withheld-bodies) 0))
         (withheld-tokens (or (getf bundle :withheld-tokens) 0))
         (sourced (or (getf bundle :sourced) 0))
         (wanted (or (getf bundle :source-definitions) 0)))
    (format out "~&# ~d entities, ~~~d/~d tokens~@[ (truncated)~]~%"
            (length (getf bundle :items)) tokens
            (getf bundle :budget) (getf bundle :truncated))
    (when (or (plusp withheld-items) (plusp withheld-bodies))
      (format out "~&#   sent ~d% of what this walk found; ~d tokens sends all of it~%"
              (round (* 100 tokens) (max 1 found)) found)
      (when (plusp withheld-items)
        (format out "~&#   index    ~d items sent, ~d withheld at ~d tokens~%"
                (length (getf bundle :items)) withheld-items
                (or (getf bundle :withheld-index-tokens) 0))
        ;; DES-0046 D5. Which bands the index budget clipped, from the same
        ;; :BANDS plist the REST caller reads. Only a band whose walk found
        ;; more than the budget sent, and only inside this block -- an
        ;; untruncated bundle has FOUND equal to SENT everywhere and prints
        ;; nothing here.
        (loop for (band label) in '((:seed "seeds") (:decision "decisions")
                                    (:document "documents") (:mention "mentions")
                                    (:neighbour "neighbours"))
              for pair = (getf (getf bundle :bands) band)
              when (and pair (> (getf pair :found) (getf pair :sent)))
                do (format out "~&#   ~10a ~d of ~d sent~%"
                           label (getf pair :sent) (getf pair :found))))
      (when (plusp withheld-bodies)
        (format out "~&#   source   ~d of ~d bodies sent, ~d withheld at ~d tokens~%"
                sourced wanted withheld-bodies
                (or (getf bundle :withheld-source-tokens) 0))))
    (terpri out)))

(defun render-provenance (bundle out)
  "Which tree BUNDLE was built from, and whether the index had caught up.

REQ-0050 R1. A bundle is the answer with the longest life in this system: it is
read into a session and worked from for an hour, where a `status\' line is read
and forgotten. It was also the one surface carrying no revision at all -- the
context *record* has carried the commit and the diff hash since REQ-0036 R4,
and the record is Loom\'s bookkeeping rather than the caller\'s answer.

One line, and only when the caller supplied one. Nothing is invented for a
caller that passed nothing: a bundle built by a test or by a tool that never
had a repository would otherwise claim a freshness nobody measured, which is
CON-0001 in the place it would be least visible."
  (let ((provenance (getf bundle :provenance)))
    (when provenance
      (let ((commit (getf provenance :commit))
            (drift (getf provenance :drift)))
        (format out "~&# index built from ~a~@[ (~a)~]~@[ ~a~]; ~a~%"
                (or (and commit (subseq commit 0 (min 12 (length commit))))
                    (format nil "an unreadable commit -- ~a"
                            (or (getf provenance :commit-reason) "no reason recorded")))
                (getf provenance :branch)
                (and (getf provenance :dirty) "+ uncommitted edits")
                (cond ((null drift) "freshness unmeasured")
                      ((zerop drift) "current with the tree")
                      (t (format nil "~d claimed file~:p have changed since" drift))))))))

(defun render-context (bundle)
  "BUNDLE as the text block an agent receives.

Kept next to the builder rather than in LOOM-MCP because the rendering is
where the token budget is really spent, and a bundle whose data is compact but
whose text is not has not saved anybody anything."
  (let ((band nil))
   (with-output-to-string (out)
    (format out "~&# Context for: ~a~%" (getf bundle :task))
    (render-provenance bundle out)
    (render-cutoff bundle out)
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
