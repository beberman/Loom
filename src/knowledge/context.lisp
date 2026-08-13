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

(defparameter *context-token-budget* 2000
  "Default size of a context bundle, in tokens.")

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
    (nreverse tokens)))

(defparameter *seed-type-preference*
  '(:function :method :class :interface :concept :architecture :design :decision :rule
    :variable :test :module :package :document :file)
  "Entity types in the order a seed match is worth having.

Definitions first, containers last, and this ordering earns its keep: a task
mentioning \"the graph manager\" matches the *file* graph-manager.lisp on the
word \"graph\" as readily as it matches any function in it, and a file's
neighbourhood is every definition it holds. Seeded on the file, a bundle
spends its whole budget listing a directory back at the agent. Seeded on the
definitions, it spends it on code.")

(defun seed-type-rank (entity)
  (or (position (entity-type entity) *seed-type-preference*)
      (length *seed-type-preference*)))

(defun seed-entities (view task &key (limit 8) types)
  "Entities whose names the words of TASK point at, best match first.

The naive half of SS11's \"first implementation is simple\", and the half most
obviously worth replacing: name matching finds RESOLVE-OVERLAY from the word
\"overlay\" and finds nothing at all from \"the bit that merges edits\".
Semantic seeding is what Qdrant is for in the target architecture."
  (let ((tokens (task-tokens task))
        (found '()))
    (dolist (token tokens)
      (dolist (entity (find-entities view :name-like token))
        (when (or (null types) (member (entity-type entity) types))
          (pushnew entity found))))
    ;; Type preference dominates, match quality breaks its ties -- the reverse
    ;; of what SEARCH-ENTITIES does, and deliberately so. loom_find answers
    ;; "where is this thing", where an exactly-named file is the right answer.
    ;; A context bundle answers "what should I know before editing", where a
    ;; function matched loosely is worth more than a file matched exactly: the
    ;; file's neighbourhood is a directory listing, the function's is the code
    ;; that will break.
    (let ((scored (loop for entity in found
                        for match = (reduce #'min tokens
                                            :key (lambda (token) (match-rank entity token))
                                            :initial-value 3)
                        unless (= match 3)   ; matched only on a path component
                          collect (cons entity (+ (* 100 (seed-type-rank entity)) match)))))
      (let ((ranked (mapcar #'car (stable-sort scored #'< :key #'cdr))))
        (subseq ranked 0 (min limit (length ranked)))))))

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

(defun context-item (view entity &key (relations t) (band :neighbour))
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
          :relation-count (length all)
          :relations
          (loop for n in shown
                collect (list :direction (neighbor-direction n)
                              :rel-type (rel-type (neighbor-relationship n))
                              :name (let ((e (neighbor-entity n)))
                                      (and (slot-boundp e 'name) (name e))))))))

(defun build-context (view task &key (budget *context-token-budget*)
                                     (seed-limit 8) types)
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
         (expanded  (let ((out '()))
                      (dolist (entity seeds)
                        (dolist (n (neighbors view (id entity)))
                          (let ((other (neighbor-entity n)))
                            (unless (or (member other seeds) (stale-p other))
                              (pushnew other out)))))
                      (nreverse out)))
         (items     '())
         (used      0)
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
      (setf expanded (remove-if (lambda (e)
                                  (or (member e decisions)
                                      (member e documents)
                                      (member e mentions)))
                                expanded))
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
                                   :key (lambda (i) (estimate-tokens (princ-to-string i)))))))
        (flet ((admit-item (item cap)
                 (let ((cost (estimate-tokens (princ-to-string item))))
                   (cond ((<= (+ used cost) cap)
                          (incf used cost)
                          (push item items)
                          t)
                         (t (setf truncated t) nil))))
               (item-for (entity relations band)
                 (context-item view entity :relations relations :band band)))
          ;; Seeds against the budget less the reserve, so the reasoning has
          ;; room left when they are done -- except the first, which is
          ;; measured against the whole budget. The seeds are ordered best
          ;; match first, and a bundle that answered "what is this code" with
          ;; nothing but the reasoning about it would have inverted the promise
          ;; this function's docstring makes. The reserve may cost the eighth
          ;; seed; it may not cost the first.
          (loop for entity in seeds
                for first = t then nil
                do (admit-item (item-for entity t :seed)
                               (if first budget (- budget reserve))))
          ;; Then the reserve is released: these are measured against the full
          ;; budget, and fit by construction unless the ceiling clipped them.
          (dolist (item document-items) (admit-item item budget))
          (dolist (entity expanded)
            (admit-item (item-for entity nil :neighbour) budget))))
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
                          :truncated truncated)))
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
      (let ((entity (getf item :entity)))
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
        (format out "~&~(~a~) ~a~@[  [~a]~]~@[  (stale)~]~%"
                (getf entity :type) (getf entity :name)
                (getf entity :location) (getf entity :stale))
        (dolist (rel (getf item :relations))
          (format out "    ~a ~(~a~) ~a~%"
                  (if (eq :out (getf rel :direction)) "->" "<-")
                  (getf rel :rel-type) (getf rel :name)))
        (let ((hidden (- (or (getf item :relation-count) 0)
                         (length (getf item :relations)))))
          (when (plusp hidden)
            (format out "    ... ~d more~%" hidden))))))))
