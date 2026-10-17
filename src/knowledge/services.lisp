;;;; Knowledge Services: the read side of the graph.
;;;; Implements the SS2 Knowledge Services box and the read-only tools of SS11.
;;;;
;;;; The queries themselves live in the Graph Manager (SS5.3, SS9). What this
;;;; layer adds is the shape an agent can use: locations it can open, paths it
;;;; can read, and plain data both SYNOPTIK-REST and SYNOPTIK-MCP can serve without
;;;; touching the graph again.
;;;;
;;;; The design test for everything here is the one the vision document sets:
;;;; tokens spent re-reading the same code. An answer that makes an agent open
;;;; a file to understand it has not earned its place -- which is why every
;;;; summary carries file and line range, and why impact paths name the
;;;; entities they ran through rather than just counting hops.

(in-package :synoptik-knowledge)

;;;; ==================================================================
;;;; A name as English -- what an embedder is given, and what two names are
;;;; compared on (DES-0040 D3, DES-0041 D4)
;;;; ==================================================================

(defun name-as-words (name)
  "NAME split on separators and at a lower-to-upper boundary, space-joined.

DES-0040 D3. An embedder tokenizes English and GETTYPEFROMOBJ is not English;
split, it is three words the model has seen a great many times. The same
reasoning TASK-TOKENS applies to a compound before matching it, for the same
reason, against a different consumer.

In synoptik-knowledge rather than beside ENTITY-DOCUMENT, which is the only thing
that called it until PLAN-0044 S1. DES-0041 D4 has the survey call two entities
name-equal when this function agrees on them, and that is the same statement as
`their vectors cannot tell them apart' only while one function answers both
questions. synoptik-workspace depends on this system (DES-0022 S3), so the builder
still reaches it; a second copy down here would drift, and the drift would
surface as a survey reporting a pair it had already filtered."
  (let ((words '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((word (get-output-stream-string current)))
               (when (plusp (length word)) (push (string-downcase word) words)))))
      (loop for i from 0 below (length name)
            for char = (char name i)
            do (cond ((not (alphanumericp char)) (finish))
                     ;; A lower-to-upper boundary starts a word, so "getType"
                     ;; splits and "URL" does not fragment into three.
                     ((and (upper-case-p char)
                           (plusp i)
                           (lower-case-p (char name (1- i))))
                      (finish)
                      (write-char char current))
                     (t (write-char char current)))
            finally (finish)))
    (format nil "~{~a~^ ~}" (nreverse words))))


;;;; ==================================================================
;;;; A definition's parameter list (BUG-0044)
;;;; ==================================================================

(defun lambda-marker-p (token)
  "True for a lambda-list keyword: &optional, &key, &rest and the rest."
  (let ((text (princ-to-string token)))
    (and (plusp (length text)) (char= #\& (char text 0)))))

(defun entity-arity (entity)
  "How many arguments ENTITY must be called with, or NIL for a type with no
parameter list at all.

The *required* count, stopping at the first lambda-list marker, and the
stopping is the whole of this function. :ARGUMENTS is documented as a parsed
parameter list and is in fact the entire lambda list flattened to strings --
FIND-ENTITIES stores (\"view\" \"&key\" \"entity-type\" \"name-like\"
\"property-filters\" \"include-stale\"), so its LENGTH is 6 and it takes one
argument. Reading the length as the arity, which is the obvious thing to do and
what this function did when it was written, reports a one-argument function as
a six-argument one. BUG-0044.

NIL for an entity type that has no parameter list, decided on the type rather
than on the property. An absent :ARGUMENTS and an empty one are both NIL in the
property table, so a :CLASS and a zero-argument DEFUN are indistinguishable
there -- 354 of Synoptik's 1303 :FUNCTION entities are the second kind. The type
tells them apart where the value cannot."
  (when (member (entity-type entity) '(:function :method))
    (let ((arguments (getp entity :arguments)))
      (if (eq :python (getp entity :language))
          (python-arity entity arguments)
          (loop for token in arguments
                until (lambda-marker-p token)
                count t)))))

(defun python-parameter-stops-p (token)
  "True when TOKEN, a Python parameter as written, ends the required ones: `*',
`*args' and `**kwargs', or a parameter with a default.

The annotation is skipped before looking for the default, because `x: int = 1'
and `x=1' both have one and `x: Literal[\"a\"]' does not. A `=' inside a string
in an annotation is not handled: the child writes the default as ` = ' after an
annotation, and an annotation holding that spelling is not worth the code."
  (let ((colon (position #\: token))
        (equals (position #\= token)))
    (or (char= #\* (char token 0))
        (if (and colon (or (null equals) (< colon equals)))
            (search " = " token :start2 colon)
            (and equals t)))))

(defun python-arity (entity arguments)
  "ENTITY's required parameter count in Python's terms (DES-0053 R12): those
before the first with a default, `*', `*args' or `**kwargs'. `/' is skipped. The
first parameter of a method is skipped unless it is decorated @staticmethod,
since a caller does not pass self or cls. The child writes :ARGUMENTS as the
source did, so the tokens are read here and not stored twice."
  (let ((tokens (if (and (eq :method (entity-type entity))
                         (notany (lambda (decorator)
                                   (equal "staticmethod" (getf decorator :name)))
                                 (getp entity :decorators)))
                    (rest arguments)
                    arguments)))
    (loop for token in tokens
          until (python-parameter-stops-p token)
          count (string/= token "/"))))

(defparameter *signature-styles*
  '((:javascript . :call) (:typescript . :call) (:python . :call))
  "How a language writes a signature, defaulting to :FORM.

  :form   (find-entities view &key entity-type)   the name is inside
  :call   findEntities(view, opts)                the name is outside

The one job :SIGNATURE was declared for and the only part worth keeping. The
two differ in more than punctuation: a Lisp signature is a form and a
JavaScript one is a call, so printing either in the other's shape is a small
lie about the source. Two entries rather than a generic function, because there
are two analyzers and a protocol for this would cost more than the fact.")

(defparameter *definition-summary-budget* 24
  "Tokens a definition's own description may spend in an answer. REQ-0049 R1.

Small on purpose and much smaller than *SUMMARY-TOKEN-BUDGET*'s 120, which
bounds a *document's* summary. A document's summary is the thing the reader
came for; a definition's is a label deciding whether to read further, and this
tree's docstrings run to paragraphs -- inlining one would be the readability
defect REQ-0040 exists for, arriving from the other direction.

Twenty-four tokens is about one line of prose. What it is not is measured:
REQ-0049 R3 asks which band carries a description at all, and that needs usage
the corpus does not yet hold.")

(defun whitespace-char-p (char)
  "True when CHAR separates words."
  (member char '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun sentence-end (text)
  "The index in TEXT of the period ending its first sentence, or NIL.

BUG-0046. The period must be followed by whitespace or the end of the string,
and must not itself be preceded by whitespace. POSITION of #\. alone answered
`<synoptik>/.' for a docstring opening `<synoptik>/.synoptik/vectors/, beside the context
log ...' -- a summary that costs tokens and carries no claim. Measured over
Synoptik's non-test source, 24 of 890 docstrings cut inside a path, a decimal, a
quoted token or an ellipsis.

The preceding-character half is for Lisp's dotted pair: `Alist of (from . to)'
puts whitespace on both sides of a period that ends no sentence, and the
following-character test alone accepts it.

No floor on how short the result may be. `Mirrors REMHASH.' is two words and is
the whole claim; a rule that reached past it for something longer would return a
second sentence as the first."
  (loop for i from 1 below (length text)
        when (and (char= #\. (char text i))
                  (not (whitespace-char-p (char text (1- i))))
                  (or (= (1+ i) (length text))
                      (whitespace-char-p (char text (1+ i)))))
          return i))

(defun definition-summary (entity)
  "The first sentence of ENTITY's documentation, bounded, or NIL if it has none.

REQ-0049. An index line says where a definition is and never what it does,
while the only tier carrying prose costs 348 to 1208 tokens -- so a caller
judging relevance could guess from the name or spend a body. This is the middle
tier: about 24 tokens to say what the thing is for.

The first sentence rather than the first line, because a docstring's opening
sentence is where this tree's convention puts the claim and a line break is a
fact about formatting. Falling back to the whole bounded text when there is no
sentence break keeps a one-clause docstring intact.

NIL rather than a placeholder when there is no documentation. 3861 of 5268
definitions across the indexed trees carry none, so absence is the common case
and must not read as a claim about the entity (CON-0001)."
  (let ((documentation (getp entity :documentation)))
    (when (and (stringp documentation) (plusp (length documentation)))
      (let* ((stop (sentence-end documentation))
             (sentence (if stop (subseq documentation 0 (1+ stop)) documentation))
             (flat (substitute #\Space #\Newline sentence)))
        (bounded-text (string-trim " " flat) *definition-summary-budget*)))))

(defun render-signature (entity)
  "ENTITY's signature as its own language writes it, or NIL for a type that has
no parameter list.

Built here rather than stored, which is BUG-0044's decision. The tokens are
already in :ARGUMENTS, so a rendering of them is derived from a derived index,
and DEC-0001 has the graph hold what files say rather than what a console wants
to print. A stored copy would be a second thing to keep true: the property it
renders can change under it and nothing would report the disagreement -- which
is how :SIGNATURE came to be declared and written zero times without anything
noticing.

NIL for a :CLASS and \"(name)\" for a function that takes nothing. Those are
different facts and the entity type separates them, because an absent
:ARGUMENTS and an empty one are both NIL in the property table."
  (when (member (entity-type entity) '(:function :method))
    (let* ((name (if (slot-boundp entity 'name) (princ-to-string (name entity)) ""))
           (arguments (mapcar #'princ-to-string (getp entity :arguments)))
           (style (or (cdr (assoc (getp entity :language) *signature-styles*)) :form)))
      (ecase style
        (:form (format nil "(~{~a~^ ~})" (cons name arguments)))
        (:call (format nil "~a(~{~a~^, ~})" name arguments))))))


;;;; ==================================================================
;;;; Summaries -- the shared vocabulary of every answer
;;;; ==================================================================

(defun entity-location (entity)
  "ENTITY's source location as \"path:start-line-end-line\", or NIL.
The single most useful thing the graph can hand an agent: the exact region to
open, instead of a filename and a search."
  (let ((file  (or (getp entity :file) (getp entity :path)))
        (start (getp entity :start-line))
        (end   (getp entity :end-line)))
    (cond ((and file start end) (format nil "~a:~a-~a" file start end))
          ((and file start)     (format nil "~a:~a" file start))
          (file                 (format nil "~a" file))
          (t nil))))

(defun entity-summary (entity)
  "ENTITY as plain data: what it is, where it is, and how far to trust it.
Deliberately not the whole property table -- a summary an agent reads in bulk
should carry what is true of every entity, and DESCRIBE-ENTITY is where the
type-specific detail lives."
  (list :id        (id entity)
        :type      (entity-type entity)
        :name      (and (slot-boundp entity 'name) (name entity))
        :location  (entity-location entity)
        :language  (getp entity :language)
        :source    (source entity)
        :confidence (confidence entity)
        ;; NIL for every type but :CALL-SITE, and read with GETP so it stays
        ;; that way without a type test here. DES-0014 R7 obliges a call site
        ;; to be shown with its line and kind rather than as a bare id: the line
        ;; is already in :LOCATION, and the kind is the one fact distinguishing
        ;; an ambiguous fan-out from a definer body's call, which a reader will
        ;; otherwise read as a missing edge. It belongs in the summary rather
        ;; than in DESCRIBE-ENTITY's type-specific detail because the neighbour
        ;; lines are built from summaries, and the neighbour is exactly where it
        ;; has to appear.
        :referrer-kind (getp entity :referrer-kind)
        :stale     (and (stale-p entity) t)))

(defun summarize-entities (entities)
  (mapcar #'entity-summary entities))

;;;; ==================================================================
;;;; search-entities -- SS11 synoptik_find, "where is X defined"
;;;; ==================================================================

;;;; The ranking rule is written once on a name and a type, and twice more as
;;;; the entity-taking calls its nine callers already make. DES-0043 D3 is why:
;;;; SEARCH-REPOSITORIES merges rows from several graphs and has only the
;;;; summaries by then, and a second ranking written on summaries would be a
;;;; second thing to keep in agreement with this one.

(defun significant-name-of (name type)
  "The part of NAME worth matching a task word against, for an entity of TYPE.

For most entities that is the whole name. For a :FILE, whose name is a path,
it is the basename without its extension -- \"graph/transaction.lisp\" matches
on \"transaction\", not on \"graph\". Without this, every word that happens to
name a directory prefix-matches every file beneath it, which outranks the
definitions the word was actually about."
  (when name
    (if (member type '(:file :document))
        (let* ((slash (position #\/ name :from-end t))
               (base  (if slash (subseq name (1+ slash)) name))
               (dot   (position #\. base :from-end t)))
          (if (and dot (plusp dot)) (subseq base 0 dot) base))
        name)))

(defun significant-name (entity)
  "SIGNIFICANT-NAME-OF, read off ENTITY."
  (significant-name-of (and (slot-boundp entity 'name) (name entity))
                       (entity-type entity)))

(defun name-match-rank (name type pattern)
  "How well NAME matches PATTERN: 0 exact, 1 prefix, 2 substring, 3 no match.
Ranking rather than filtering, because an agent asking for \"impact-set\" wants
IMPACT-SET first and IMPACT-SET-TRUNCATED-P second, not both in hash order."
  (let ((name (significant-name-of name type)))
    (cond ((null name) 3)
          ((string-equal name pattern) 0)
          ((and (<= (length pattern) (length name))
                (string-equal pattern name :end2 (length pattern))) 1)
          ((search pattern name :test #'char-equal) 2)
          (t 3))))

(defun match-rank (entity pattern)
  "NAME-MATCH-RANK, read off ENTITY."
  (name-match-rank (and (slot-boundp entity 'name) (name entity))
                   (entity-type entity) pattern))

(defparameter *seed-type-preference*
  '((:function :method :class :interface :variable :test)
    (:module :package :file)
    (:concept :architecture :design :decision :rule :document))
  "Entity types in tiers, by how much a seed match on one is worth having.

Definitions first, containers next, and that much earns its keep: a task
mentioning \"the graph manager\" matches the *file* graph-manager.lisp on the
word \"graph\" as readily as it matches any function in it, and a file's
neighbourhood is every definition it holds. Seeded on the file, a bundle
spends its whole budget listing a directory back at the agent. Seeded on the
definitions, it spends it on code.

Tiers rather than a total order since REQ-0016 R1, and the flattening is the
point. This was a fifteen-entry list in which :CLASS sat two places below
:FUNCTION for no recorded reason, and because the type band dominates the
score, that gap meant every function matching any word of the task outranked
the class the task was *named after*. On game-server `context data-handler`
put four functions above the DATA-HANDLER class and never reached DB-HANDLER,
TABLE-HANDLER or the DHANDLER-* protocol at all -- a CLOS subsystem is classes
and methods, so a ranking that prefers functions cannot describe one. A class
and a function are both definitions and the argument above says nothing to
separate them; what it separates is definitions from the things that contain
them.

Documents rank last rather than mid-list: they reach a bundle through the
decision, document and mention bands DES-0020 built for them, and a document
arriving as a *seed* would be counted twice and expand as though it were code.

A type named in no tier -- :CALL-SITE, which prefix-matches its own callee's
name and would otherwise seed as readily as the callee -- sorts after all of
them. PLAN-0014 step 10 made the same judgement for `find'.
Read by two callers since BUG-0032, which is why it lives here rather than
beside the seeder that first needed it. `context' seeds with it and
RESOLUTION-RANK breaks a `describe' tie with it, and both are asking the same
question -- when two entities match a name equally well, which one did the
caller mean -- so the answer belongs in one list.")

(defun seed-type-rank (entity)
  (or (position-if (lambda (tier) (member (entity-type entity) tier))
                   *seed-type-preference*)
      (length *seed-type-preference*)))

(defun name-search-rank (name type pattern)
  "NAME-MATCH-RANK, with a :CALL-SITE placed below every entity that is not one.

PLAN-0014 step 10's recorded fallback, taken because the measurement it asked
for showed it was needed. A call site's name is \"<call-name>@<file>:<line>\"
(DES-0014), so the pattern that names its callee matches it as a *prefix* --
rank 1 -- and it therefore outranks every rank-2 substring match among the real
definitions. Measured on this tree: 7 of 86 terms lost between one and five real
definitions off `find''s silent 20-hit cap (REQ-0005), `id' losing two
interfaces and `name' three functions, all to call sites ranked above them.

Demoting by a whole rank band rather than breaking ties within one is the point:
at the same match rank the call site was already losing, and interleaving would
have left every one of those 7 terms displaced. Demoting rather than filtering
is equally deliberate -- a filtered entity is invisible, and this design exists
to stop calls being invisible, so a call site still appears whenever the cap
leaves room, which on this tree is every term with 20 hits or fewer.

Written on a name and a type so that a caller holding a summary rather than an
entity ranks by the same rule (DES-0043 D3). SEARCH-REPOSITORIES is that
caller: it merges rows from several graphs and has only summaries by then."
  (let ((rank (name-match-rank name type pattern)))
    ;; 4 is one past NAME-MATCH-RANK's worst, so the two bands cannot overlap.
    (if (eq :call-site type) (+ rank 4) rank)))

(defun search-rank (entity pattern)
  "NAME-SEARCH-RANK, read off ENTITY."
  (name-search-rank (and (slot-boundp entity 'name) (name entity))
                    (entity-type entity) pattern))

(defparameter *find-kinds* '(:code :documentation)
  "The two families `find' can be narrowed to.

Two rather than more, because these are the two a caller confuses: `find
repository' on this tree returns twenty code definitions and Synoptik also holds
documents about repositories, and there was no way to ask for one without the
other. A third family would need a question somebody actually asks.")

(defun kind-types (kind)
  "The entity types KIND covers, or NIL for no narrowing.

The document family is SYNOPTIK-GRAPH:*DOCUMENT-TYPES*, which already exists and is
what the document analyzers mint. The code family is its complement over the
types the ontology declares -- computed rather than listed, so a type added
later joins the right family without anybody editing this function.

The complement is the half worth watching. A type the ontology declares and no
document analyzer mints lands in `code' whether or not it is code:
:RULE-VIOLATION, :WORKSPACE, :SNAPSHOT, :REPOSITORY, :BRANCH and :COMMIT are all
in that position. None is a definition `find' would return, so the effect is
nil and the partition test says which side each falls on rather than only that
the two do not overlap."
  (ecase (or kind :none)
    (:none nil)
    (:documentation synoptik-graph:*document-types*)
    (:code (remove-if (lambda (type) (member type synoptik-graph:*document-types*))
                      (synoptik-ontology:all-entity-types)))))

(defun search-entities (view &key name type limit property-filters kind)
  "Entities matching NAME (substring, case-insensitive) and TYPE, best match
first, and how many matched before LIMIT cut the list.

Two values, because one of them was a false answer. BUG-0002: the console asked
for twenty and printed twenty with nothing to say a twenty-first existed, so
`find \"\" test\' answered 20 where Synoptik holds 798 tests -- a population question
answered with a location answer, and no way for the caller to tell. The count
is what IMPACT-REPORT already carries for the same reason one command over.

The total is the length before truncation, so a caller comparing it with what
it received knows whether it saw everything."
  (when (and kind type (not (member type (kind-types kind))))
    ;; Refused rather than resolved. `find x class --documentation' names a
    ;; code type and a document family, and either answer -- the type or the
    ;; family -- is a guess about which the caller meant.
    (error 'synoptik-utils:refusal
           :message (format nil "~(~a~) is not a ~(~a~) type, so the two cannot both hold."
                            type kind)))
  (let ((hits (find-entities view :entity-type type :name-like name
                                  :entity-types (kind-types kind)
                                  :property-filters property-filters)))
    (when name
      (setf hits (stable-sort hits #'< :key (lambda (e) (search-rank e name)))))
    (values (summarize-entities
             (if limit (subseq hits 0 (min limit (length hits))) hits))
            (length hits))))

;;;; ------------------------------------------------------------------
;;;; Picking one entity, which is a different question from listing several
;;;; ------------------------------------------------------------------
;;;;
;;;; BUG-0032. `find' lists and `describe' picks, and a tie means opposite
;;;; things to them. On front-end a file is named after the component
;;;; it exports, so SIGNIFICANT-NAME reduces
;;;; src/ui/edit/terrain/Editor/LayerEditor.jsx to "LayerEditor" and the file
;;;; and the 251-line component are both exact matches. `find' printing the
;;;; file first is right and argued -- the caller asked where to look, and the
;;;; definition is the next line of the same listing. `describe' picking the
;;;; file answers three questions badly at once: its neighbours are a
;;;; directory listing, it has no :START-LINE so REQ-0031's --source prints
;;;; "this entity records no line range", and the component is three lines
;;;; away. 37 of 60 sampled front-end basenames resolved that way.
;;;;
;;;; So the tie-break is here rather than in SEARCH-RANK, which `find' shares.

(defun resolution-rank (entity pattern)
  "SEARCH-RANK, with a definition preferred to the container that holds it.

Multiplied out rather than consed into a list, so this stays a single number a
STABLE-SORT can compare: the match rank keeps its bands -- an exact match still
beats a prefix, whatever either one is -- and the type tier orders only what is
left tied inside a band. That order is exactly the one `context' seeds with,
which is the point of *SEED-TYPE-PREFERENCE* having moved up here: a caller
that must choose one entity for a name is asking the question the seeder
already answers."
  (+ (* 10 (search-rank entity pattern)) (seed-type-rank entity)))

(defun best-name-match (view term &key property-filters)
  "The summary of the one entity TERM most likely names, or NIL.

For a caller that has to choose -- `describe' and `impact' -- rather than list.
Nothing here filters on type: a file still wins where no definition shares its
name, which is every entity on both Lisp trees.

PROPERTY-FILTERS narrows the candidates before the choice is made, which is how
a domain address reaches `describe' and `impact'. Applied inside FIND-ENTITIES
rather than to the result, so this returns the best match within the domain
rather than the best match overall when it happens to fall in one."
  (let ((hits (find-entities view :name-like term :property-filters property-filters)))
    (when hits
      (first (summarize-entities
              (list (first (stable-sort hits #'<
                                        :key (lambda (e)
                                               (resolution-rank e term))))))))))

;;;; ==================================================================
;;;; describe-entity -- SS11 synoptik_describe
;;;; ==================================================================

(defun neighbor-summary (n)
  (list :direction (neighbor-direction n)
        :rel-type  (rel-type (neighbor-relationship n))
        :stale     (and (stale-p (neighbor-relationship n)) t)
        :entity    (entity-summary (neighbor-entity n))))

(defun group-neighbors (neighbors)
  "Neighbours grouped by relationship type and direction, so an answer reads
as \"calls: these; called-by: those\" rather than as a flat edge dump.

Each row carries the *edge's* provenance beside the entity's, which is
BUG-0055. ENTITY-SUMMARY reports `:source' and `:confidence' for the
definition -- what kind of fact the entity itself is -- and every row therefore
read `structural, 1.0' whether the edge reaching it was resolved or guessed.
Three of `ingestModel's four outbound calls were one `.get()' on a plain Map
fanned out across every class in front-end with a `get' method, asserted at
0.33 apiece, and printed indistinguishably from the one real callee.

:EDGE-SOURCE and :EDGE-CONFIDENCE rather than reusing the two names: a row
naming an entity and an edge needs both provenances, and collapsing them would
make a caller unable to tell a guessed edge to a certain definition from a
certain edge to an inferred one. Always emitted, including the ordinary
`:structural 1.0', because a field that appears only on the bad rows makes its
own absence carry meaning, and a reader then cannot tell a resolved edge from a
build older than the marker."
  (let ((groups '()))
    (dolist (n neighbors)
      (let* ((relationship (neighbor-relationship n))
             (key  (list (neighbor-direction n) (rel-type relationship)))
             (cell (or (assoc key groups :test #'equal)
                       (car (push (cons key '()) groups)))))
        (push (append (entity-summary (neighbor-entity n))
                      (list :edge-source (source relationship)
                            :edge-confidence (confidence relationship)))
              (cdr cell))))
    (loop for (key . entities) in (reverse groups)
          collect (list :direction (first key)
                        :rel-type  (second key)
                        :entities  (reverse entities)))))

;;;; ------------------------------------------------------------------
;;;; A bounded answer for a document-shaped entity (DES-0005)
;;;;
;;;; A document's :BODY is however long its author made it -- COLLECT-BODY
;;;; concatenates up to eight prose fields with no cap -- so a caller that
;;;; prints it has no bound on its output. What follows picks one named field
;;;; and budgets it, and always reports which field it picked: a fallback that
;;;; did not say it was a fallback would be indistinguishable from a summary
;;;; the author actually wrote, which is the fabrication CON-0001 forbids.
;;;;
;;;; *SUMMARY-TOKEN-BUDGET* and BOUNDED-TEXT sit here rather than beside
;;;; *CONTEXT-TOKEN-BUDGET* in context.lisp, which is where DES-0005 put them,
;;;; for a load-order reason: synoptik-knowledge.asd is :serial with services
;;;; before context, and a compile-time reference to a DEFPARAMETER not yet
;;;; seen is a full WARNING in SBCL, which sets COMPILE-FILE's failure-p and so
;;;; fails the build. A forward reference to a *function* is only a
;;;; STYLE-WARNING, deferred and resolved inside ASDF's compilation unit, so
;;;; ESTIMATE-TOKENS stays in context.lisp and is called across the boundary.
;;;; ------------------------------------------------------------------

(defparameter *summary-fields-by-type*
  '((:document . (:summary))
    (:concept  . (:summary))
    (:design   . (:summary))
    (:architecture . (:summary :invariants))
    (:decision . (:summary :rationale))
    (:rule     . (:summary :statement)))
  "Per document type, the properties to try for a summary, best first.

:DECISION and :RULE list a second candidate because every DEC and RULE
document predates the :SUMMARY field, and :RATIONALE and :STATEMENT are each
type's own primary prose property -- individually stored, never a slice of
:BODY. Choosing which existing fact to show is not synthesis; inventing one
from the first paragraph of :BODY would be, and is why no such fallback exists.

A type absent from this alist has no summary shape and gets none: that is the
correct default for a type nobody has designed one for yet.")

(defun summary-field-and-text (entity)
  "(values field text): the first of ENTITY's type's candidates holding a
non-empty string, or (values nil nil).

Two values rather than one so a caller can label a fallback. See
*SUMMARY-FIELDS-BY-TYPE*."
  (loop for key in (cdr (assoc (entity-type entity) *summary-fields-by-type*))
        for text = (getp entity key)
        when (and (stringp text) (plusp (length (string-trim '(#\Space #\Tab #\Newline)
                                                             text))))
          return (values key text)
        finally (return (values nil nil))))

(defparameter *summary-token-budget* 120
  "How much of a document's summary a bounded answer may show, in tokens.

An order of magnitude under *CONTEXT-TOKEN-BUDGET*'s 2000 because the two are
budgeting different things: a context bundle is a set of entities, a summary is
one paragraph.")

(defun bounded-text (text budget)
  "(values shown truncated-p): TEXT whole when it fits BUDGET, else its longest
prefix within BUDGET backed off to the nearest preceding whitespace.

No word is split, so the cut reads as a sentence stopping rather than as
corruption. BUILD-CONTEXT's discipline applied to one string: report what was
shown against the budget, never cut silently and never overflow."
  (if (<= (estimate-tokens text) budget)
      (values text nil)
      ;; ESTIMATE-TOKENS is four characters to the token by its own admission,
      ;; so the budget is inverted the same way rather than by a search: any
      ;; other arithmetic would disagree with the function callers report
      ;; against.
      (let* ((limit (min (length text) (* 4 budget)))
             (space (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline)))
                                 text :end limit :from-end t)))
        (values (subseq text 0 (or space limit)) t))))

(defun document-summary (entity)
  "A bounded, self-describing summary of ENTITY, or NIL if its type has none.

The plist is (:title :status :field :text :truncated :full-tokens). The NIL
result and a plist whose :FIELD is NIL mean different things -- \"no summary
shape for this type\" and \"a summary shape nobody filled\" -- and a caller
that conflates them reports a gap it has not checked for."
  (when (assoc (entity-type entity) *summary-fields-by-type*)
    (multiple-value-bind (field text) (summary-field-and-text entity)
      (multiple-value-bind (shown truncated)
          (if text (bounded-text text *summary-token-budget*) (values nil nil))
        (list :title       (getp entity :title)
              :status      (getp entity :status)
              :field       field
              :text        shown
              :truncated   truncated
              ;; The size of what was cut, not of what was shown: R6 asks the
              ;; caller be told how much it is not seeing.
              :full-tokens (and text (estimate-tokens text)))))))

(defun federated-summaries (view id &key (direction :out))
  "The other repositories' code this entity reaches, as plain data.

Read entirely off the edges. A federated edge carries the far end's
repository, name, file, line and the commit that tree was at when the edge was
derived, so answering this needs no second graph and takes no lock on a
repository that may be mid-reindex.

REQ-0027 R5 is discharged here: every entry names the working tree and commit
it describes, because a federated answer is about two checkouts and must not
read as a claim about a deployed system."
  (loop for r in (federated-relationships view id :direction direction)
        collect (list :repository (getp r :foreign-repository)
                      :name       (getp r :foreign-name)
                      :type       (getp r :foreign-type)
                      :file       (getp r :foreign-file)
                      :line       (getp r :foreign-line)
                      :commit     (getp r :foreign-commit)
                      :rel-type   (rel-type r)
                      :via        (getp r :route)
                      :confidence (confidence r))))

(defun module-dependency (entity)
  "What a :MODULE declares, for `describe', or NIL for anything else. DES-0055 D9.

:UNMAPPED is true for a PyPI module with no :PROVIDES. npm maps every name to
itself, so an npm module is never unmapped."
  (when (eq :module (entity-type entity))
    (list :manifest (getp entity :file)
          :ecosystem (getp entity :ecosystem)
          :specs (getp entity :specs)
          :sections (getp entity :sections)
          :provides (getp entity :provides)
          :unmapped (and (eq :pypi (getp entity :ecosystem))
                         (null (getp entity :provides))))))

;;;; ------------------------------------------------------------------
;;;; The call shapes at one callee (DES-0055 D11, D12; PLAN-0060 step 7)
;;;;
;;;; The caller holds the signatures and the edge's :VIA names which of its
;;;; keys reached this callee, so a callee's distribution is a join over its
;;;; incoming :CALLS edges. Nothing is resolved here: matching on the callee's
;;;; name would re-derive RESOLVE-CALLS and miss a Python class call that
;;;; reaches Class.__init__ under the key "Class".
;;;;
;;;; A call-site source is a caller like any other. An :AMBIGUOUS one is a
;;;; guess among several candidates, so its sites are counted apart as fan-out
;;;; and left out of the site total. A :DEFINER-CALL, :VARIABLE, :CLASS or
;;;; :MODULE site counts as an ordinary caller, with the file and the lines its
;;;; own :CALL-SHAPES carry. Its row in `sites' is named by the site's label,
;;;; "<call-name>@<file>:<line>", because that is what the entity is called.
;;;; ------------------------------------------------------------------

(defun caller-occurrences (shapes via)
  "The call forms SHAPES holds under the keys in VIA, as ((line key signature) . n)
cells, where N is how many times this one caller records that line.

SHAPES is a :CALL-SHAPES value, ((key (signature line ...) ...) ...). The join
is VIA, never the callee's name (D11). N is above 1 when a caller makes two
calls with one signature on one line, which the grouped value keeps as a
repeated line."
  (let ((tally '()))
    (loop for (key . entries) in shapes
          when (member key via :test #'equal)
            do (loop for (signature . lines) in entries
                     do (dolist (line lines)
                          (let* ((form (list line key signature))
                                 (cell (assoc form tally :test #'equal)))
                            (if cell
                                (incf (cdr cell))
                                (push (cons form 1) tally))))))
    tally))

(defun note-call-site (sites key n name)
  "Record N occurrences of KEY in the SITES table, keeping the larger N.

A site is counted at the largest multiplicity any one caller records for it
(PLAN-0060 FINDINGS 5): a beforeEach line that N test cases inherit is one
source occurrence, and summing the callers would count it N times. A tie keeps
the caller whose name sorts first, so the row `sites' prints does not depend on
the order the graph hands the edges back."
  (let ((old (gethash key sites)))
    (when (or (null old)
              (> n (car old))
              (and (= n (car old)) (string< name (cdr old))))
      (setf (gethash key sites) (cons n name)))))

(defun call-site-tally (view id)
  "(values sites edges without-form) for the incoming :CALLS edges of ID.

SITES maps (fan-out-p file line key signature) to (n . caller-name). EDGES is
how many incoming edges there are, and WITHOUT-FORM how many of them name no
key their source holds a shape for -- a Lisp #'f designator, a JSX usage, an
edge `enrich' added from the image (DES-0055 D10, PLAN-0060 FINDINGS 4)."
  (let ((sites (make-hash-table :test #'equal))
        (edges 0)
        (without-form 0))
    (dolist (r (relationships-to view id :rel-type :calls))
      (let ((source (get-entity view (from-id r))))
        (when source
          (incf edges)
          (let ((found (caller-occurrences (getp source :call-shapes) (getp r :via)))
                (fan-out (eq :ambiguous (getp source :referrer-kind)))
                (file (or (getp source :file) (getp source :path)))
                (name (if (slot-boundp source 'name) (name source) "")))
            (if (null found)
                (incf without-form)
                (loop for ((line key signature) . n) in found
                      do (note-call-site sites (list fan-out file line key signature)
                                         n name)))))))
    (values sites edges without-form)))

(defun call-shape-distribution (view id)
  "How the calls that reach ID are written, or NIL when nothing calls it.

(:SITES n :SIGNATURES ((signature count) ...) :FAN-OUT n :WITHOUT-FORM n
:PRE-EXPANSION boolean). :SIGNATURES is most common first, ties by signature.
:FAN-OUT counts the sites reached through an :AMBIGUOUS call site and is not in
:SITES. :WITHOUT-FORM counts edges that name no key their source holds a shape
for. :PRE-EXPANSION is true when ID is a macro, whose call forms are as written
and not as expanded (DES-0055 D10)."
  (multiple-value-bind (sites edges without-form) (call-site-tally view id)
    (when (plusp edges)
      (let ((counts (make-hash-table :test #'equal))
            (total 0)
            (fan-out 0))
        (maphash (lambda (key cell)
                   (if (first key)
                       (incf fan-out (car cell))
                       (progn (incf total (car cell))
                              (incf (gethash (fifth key) counts 0) (car cell)))))
                 sites)
        (list :sites total
              :signatures (sort (loop for signature being the hash-keys of counts
                                        using (hash-value count)
                                      collect (list signature count))
                                (lambda (a b)
                                  (or (> (second a) (second b))
                                      (and (= (second a) (second b))
                                           (string< (first a) (first b))))))
              :fan-out fan-out
              :without-form without-form
              :pre-expansion (and (getp (get-entity view id) :macro-p) t))))))

(defun site-row< (a b)
  "Rows of (file line caller-name) in file, line, name order."
  (destructuring-bind (file-a line-a name-a) a
    (destructuring-bind (file-b line-b name-b) b
      (cond ((not (equal file-a file-b)) (string< (or file-a "") (or file-b "")))
            ((/= line-a line-b) (< line-a line-b))
            (t (string< name-a name-b))))))

(defun shape-sites (view id &key (per-group 20))
  "The sites that call ID, grouped by signature with the rarest group first.

Each group is (:SIGNATURE s :COUNT n :SITES ((file line caller-name) ...) :MORE m):
at most PER-GROUP rows, in file and line order, and M the rows not shown. A site
counted twice, two calls with one signature on one line, is two rows, so :COUNT
is the number of rows there would be. The groups hold the sites
CALL-SHAPE-DISTRIBUTION counts in :SITES; fan-out sites are not listed. Ties
between groups are by signature. NIL when no site is counted.

The rarest group is first because the question `sites' answers is which calls
differ from the rest (REQ-0041 R4), and the 5 three-argument calls of 454 are
the answer to it."
  (let ((groups (make-hash-table :test #'equal)))
    (maphash (lambda (key cell)
               (destructuring-bind (fan-out file line k signature) key
                 (declare (ignore k))
                 (unless fan-out
                   (dotimes (i (car cell))
                     (push (list file line (cdr cell)) (gethash signature groups))))))
             (call-site-tally view id))
    (let ((rows (loop for signature being the hash-keys of groups
                        using (hash-value sites)
                      collect (cons signature (sort sites #'site-row<)))))
      (loop for (signature . sites)
              in (sort rows (lambda (a b)
                              (let ((na (length (cdr a))) (nb (length (cdr b))))
                                (or (< na nb)
                                    (and (= na nb) (string< (car a) (car b)))))))
            for shown = (min per-group (length sites))
            collect (list :signature signature
                          :count (length sites)
                          :sites (subseq sites 0 shown)
                          :more (- (length sites) shown))))))

(defun describe-entity (view id &key provenance)
  "Full detail for one entity: its own properties plus its neighbours grouped
by edge type -- the \"tell me about this function\" call. NIL when ID is
unknown.

PROVENANCE is REQ-0050 R1: which tree the index was built from, and whether
this entity's own file has moved since the index read it, from
SYNOPTIK-WORKSPACE:FILE-PROVENANCE. One file rather than the repository, because
this answer is about one definition -- and because a tree-wide drift on the
second cheapest command Synoptik has took it from 4.7ms to 25.6ms over REST.

Carried on the data for a REST or MCP consumer, which has no other way to ask.
The console prints one line and only when the file has moved, because this
command is issued dozens of times in a session and a freshness line on each of
them is noise on the answers where nothing is wrong."
  (let ((entity (get-entity view id)))
    (when entity
      (list :entity     (entity-summary entity)
            :provenance provenance
            ;; BUG-0044. Here rather than in ENTITY-SUMMARY, which is read in
            ;; bulk by `find' and `impact' and is deliberately what is true of
            ;; every entity. What a definition takes is type-specific detail,
            ;; and this is where that lives. NIL for anything but a :FUNCTION or
            ;; a :METHOD, so a consumer can print it unconditionally.
            :signature  (render-signature entity)
            :arity      (entity-arity entity)
            ;; REQ-0049 R2. DESCRIBE-ENTITY already returned the whole
            ;; docstring inside :PROPERTIES and no surface printed it, so a
            ;; caller could read where a definition is and not what it does.
            :summary    (definition-summary entity)
            ;; DES-0054 D8. What a framework registered this for, derived by
            ;; RESOLVE-ENTRY-POINTS. The same list is in :PROPERTIES; it is
            ;; lifted so the console and a REST caller need not search a table.
            :entry-point (getp entity :entry-point)
            ;; DES-0055 D9. NIL for anything but a :MODULE.
            :dependency (module-dependency entity)
            ;; DES-0055 D12. How the calls that reach this entity are written,
            ;; joined through the edges' :VIA; NIL when nothing calls it.
            :call-shapes (call-shape-distribution view id)
            :properties (loop for key being the hash-keys of (properties entity)
                                using (hash-value value)
                              unless (null value) append (list key value))
            :neighbors  (group-neighbors (neighbors view id))
            ;; DES-0025. Separate from :NEIGHBORS rather than folded into it,
            ;; and the separation is the honest part: a neighbour is an entity
            ;; this graph holds, and the far end of a federated edge is not one.
            ;; Reporting it in the same list would make a reader think `find'
            ;; could then be asked about it in this repository.
            :federated  (federated-summaries view id)
            ;; Added rather than substituted: :PROPERTIES still carries the
            ;; complete untruncated table, so a caller wanting the full text
            ;; has lost nothing. NIL for a code entity, whose type has no
            ;; summary shape.
            :document   (document-summary entity)))))

;;;; ==================================================================
;;;; impact-report -- SS11 synoptik_impact
;;;; ==================================================================

(defun render-path (view path)
  "An impact path as the names it ran through: \"calls>apply-op calls>plan-op\".
SS9 requires the path be carried; a chain of entity names is what makes it
usable, because an agent can see *why* something is impacted and judge whether
that reason matters.

An inferred hop is written `calls?>name' rather than `calls>name', which is
BUG-0055. The path is the evidence a reader judges the row by, and a hop the
resolver guessed at is different evidence from one it resolved: on front-end a
single `.get()' on a plain Map puts every class with a `get' method one hop
from its caller, and everything behind those is in the set on the strength of a
0.33 edge. One character, because the path is already the longest field in the
row."
  (format nil "~{~a~^ ~}"
          (loop for hop in path
                for entity = (get-entity view (hop-entity-id hop))
                collect (format nil "~(~a~)~a>~a" (hop-rel-type hop)
                                (if (eq :inferred (hop-edge-source hop)) "?" "")
                                (if (and entity (slot-boundp entity 'name))
                                    (name entity)
                                    (hop-entity-id hop))))))

(defun path-inferred-p (path)
  "True when any hop of PATH crossed an edge a resolution pass guessed at.

Any rather than all. A path is a chain of claims and one guess in it makes the
conclusion a guess."
  (some (lambda (hop) (eq :inferred (hop-edge-source hop))) path))

(defun path-confidence (path)
  "The confidence of PATH's least certain hop. 1.0 for a path of resolved edges.

The minimum rather than the product. Multiplying four structural 1.0s by one
0.33 gives 0.33 either way, but on a longer path a product decays with length
and would report a chain of certainties as progressively less certain -- a
number that reads like a measurement of something and is an artefact of depth.
The weakest link is the claim actually being made."
  (reduce #'min path :key #'hop-edge-confidence :initial-value 1.0))

(defun impact-entry-summary (view entry)
  ;; :INFERRED and :CONFIDENCE-OF-PATH are BUG-0055. The row already carried
  ;; its depth and its path; what it did not carry was whether the path is a
  ;; fact. `impact ingestModel' on front-end reaches every class in the tree
  ;; with a `get', `add', `has' or `set' method at depth 1, and those rows
  ;; were the same shape as the ones reached by a resolved call.
  (append (entity-summary (impact-entry-entity entry))
          ;; DES-0054 D8. Nothing calls an entry point, so traversal already ends
          ;; at one and the chain is not cut; the marker says why it ends.
          (let ((trigger (getp (impact-entry-entity entry) :trigger)))
            (when trigger (list :trigger trigger)))
          (list :depth (impact-entry-depth entry)
                :inferred (and (path-inferred-p (impact-entry-path entry)) t)
                :confidence-of-path (path-confidence (impact-entry-path entry))
                :via   (render-path view (impact-entry-path entry)))))

(defun impact-report (view id &key (max-depth *default-impact-depth*)
                                   (include-tests t) (include-docs t))
  "What changing the entity ID may require attention to, as plain data.
NIL when ID is unknown."
  (let ((result (impact-set view id :max-depth max-depth
                                    :include-tests include-tests
                                    :include-docs include-docs)))
    (when result
      (list :seed      (entity-summary (impact-result-seed result))
            :count     (length (impact-result-impacted result))
            ;; BUG-0050 F2. The depth the walk was asked for, so a reader can
            ;; tell it from the depths the rows carry. A one-step relationship
            ;; is followed as a single hop from everything already impacted, so
            ;; a base found at the cap yields a neighbour at cap+1 and the row
            ;; honestly says so -- 7 of 822 on game-server's `impact
            ;; data-handler 5'. The number is the true path length; what was
            ;; missing is anything saying the band lies outside what was asked
            ;; for, which left a reader comparing `d6' against the 5 they typed
            ;; and reading a defect.
            :depth     max-depth
            :truncated (and (impact-result-truncated-p result) t)
            :impacted  (loop for entry in (impact-result-impacted result)
                             collect (impact-entry-summary view entry))
            :tests     (summarize-entities (impact-result-tests result))
            :documents (summarize-entities (impact-result-documents result))
            ;; Its own field, never folded into :DOCUMENTS or :DECISIONS.
            ;; REQ-0014 R5: a file that names this entity must not arrive
            ;; looking like a decision governing it.
            :mentions  (summarize-entities (impact-result-mentions result))
            :decisions (summarize-entities (impact-result-decisions result))
            :possibly-affected
            (summarize-entities (impact-result-possibly-affected result))
            ;; DES-0025, REQ-0027 R1 and R6. Gathered from every entity the
            ;; impact set reached, not only from the seed: the question is
            ;; "change this handler, what breaks over there", and the handler
            ;; is usually several hops from the function actually being edited.
            ;; DHANDLER-DELETE-SELECTOR does not serve a route; the endpoint
            ;; that calls it does.
            :federated (federated-band view result)))))

(defun federated-band (view result)
  "Every other repository's code the impact set reaches, deduplicated.

Its own band for the same reason :MENTIONS is one (REQ-0014 R5): this is a
different kind of claim from the rest of the report, and folding it in would
make code in another repository read like code in this one. The band names
the repository and the commit, so what a reader is looking at is two working
trees rather than a system."
  (let ((seen (make-hash-table :test #'equal))
        (out '()))
    (dolist (entry (cons (impact-result-seed result)
                         (mapcar #'impact-entry-entity
                                 (impact-result-impacted result))))
      (let ((id (if (listp entry) nil (id entry))))
        (when id
          (dolist (summary (federated-summaries view id))
            (let ((key (list (getf summary :repository) (getf summary :name)
                             (getf summary :via))))
              (unless (gethash key seen)
                (setf (gethash key seen) t)
                (push summary out)))))))
    (nreverse out)))
