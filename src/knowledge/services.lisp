;;;; Knowledge Services: the read side of the graph.
;;;; Implements the SS2 Knowledge Services box and the read-only tools of SS11.
;;;;
;;;; The queries themselves live in the Graph Manager (SS5.3, SS9). What this
;;;; layer adds is the shape an agent can use: locations it can open, paths it
;;;; can read, and plain data both LOOM-REST and LOOM-MCP can serve without
;;;; touching the graph again.
;;;;
;;;; The design test for everything here is the one the vision document sets:
;;;; tokens spent re-reading the same code. An answer that makes an agent open
;;;; a file to understand it has not earned its place -- which is why every
;;;; summary carries file and line range, and why impact paths name the
;;;; entities they ran through rather than just counting hops.

(in-package :loom-knowledge)

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
;;;; search-entities -- SS11 loom_find, "where is X defined"
;;;; ==================================================================

(defun significant-name (entity)
  "The part of ENTITY's name worth matching a task word against.

For most entities that is the whole name. For a :FILE, whose name is a path,
it is the basename without its extension -- \"graph/transaction.lisp\" matches
on \"transaction\", not on \"graph\". Without this, every word that happens to
name a directory prefix-matches every file beneath it, which outranks the
definitions the word was actually about."
  (let ((name (and (slot-boundp entity 'name) (name entity))))
    (when name
      (if (member (entity-type entity) '(:file :document))
          (let* ((slash (position #\/ name :from-end t))
                 (base  (if slash (subseq name (1+ slash)) name))
                 (dot   (position #\. base :from-end t)))
            (if (and dot (plusp dot)) (subseq base 0 dot) base))
          name))))

(defun match-rank (entity pattern)
  "How well ENTITY's name matches PATTERN: 0 exact, 1 prefix, 2 substring,
3 no match.
Ranking rather than filtering, because an agent asking for \"impact-set\" wants
IMPACT-SET first and IMPACT-SET-TRUNCATED-P second, not both in hash order."
  (let ((name (significant-name entity)))
    (cond ((null name) 3)
          ((string-equal name pattern) 0)
          ((and (<= (length pattern) (length name))
                (string-equal pattern name :end2 (length pattern))) 1)
          ((search pattern name :test #'char-equal) 2)
          (t 3))))

(defun search-rank (entity pattern)
  "MATCH-RANK, with a :CALL-SITE placed below every entity that is not one.

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
leaves room, which on this tree is every term with 20 hits or fewer."
  (let ((rank (match-rank entity pattern)))
    ;; 4 is one past MATCH-RANK's worst, so the two bands cannot overlap.
    (if (eq :call-site (entity-type entity)) (+ rank 4) rank)))

(defun search-entities (view &key name type limit property-filters)
  "Entities matching NAME (substring, case-insensitive) and TYPE, best match
first. Returns summaries."
  (let ((hits (find-entities view :entity-type type :name-like name
                                  :property-filters property-filters)))
    (when name
      (setf hits (stable-sort hits #'< :key (lambda (e) (search-rank e name)))))
    (summarize-entities (if limit (subseq hits 0 (min limit (length hits))) hits))))

;;;; ==================================================================
;;;; describe-entity -- SS11 loom_describe
;;;; ==================================================================

(defun neighbor-summary (n)
  (list :direction (neighbor-direction n)
        :rel-type  (rel-type (neighbor-relationship n))
        :stale     (and (stale-p (neighbor-relationship n)) t)
        :entity    (entity-summary (neighbor-entity n))))

(defun group-neighbors (neighbors)
  "Neighbours grouped by relationship type and direction, so an answer reads
as \"calls: these; called-by: those\" rather than as a flat edge dump."
  (let ((groups '()))
    (dolist (n neighbors)
      (let* ((key  (list (neighbor-direction n) (rel-type (neighbor-relationship n))))
             (cell (or (assoc key groups :test #'equal)
                       (car (push (cons key '()) groups)))))
        (push (entity-summary (neighbor-entity n)) (cdr cell))))
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
;;;; for a load-order reason: loom-knowledge.asd is :serial with services
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

(defun describe-entity (view id)
  "Full detail for one entity: its own properties plus its neighbours grouped
by edge type -- the \"tell me about this function\" call. NIL when ID is
unknown."
  (let ((entity (get-entity view id)))
    (when entity
      (list :entity     (entity-summary entity)
            :properties (loop for key being the hash-keys of (properties entity)
                                using (hash-value value)
                              unless (null value) append (list key value))
            :neighbors  (group-neighbors (neighbors view id))
            ;; Added rather than substituted: :PROPERTIES still carries the
            ;; complete untruncated table, so a caller wanting the full text
            ;; has lost nothing. NIL for a code entity, whose type has no
            ;; summary shape.
            :document   (document-summary entity)))))

;;;; ==================================================================
;;;; impact-report -- SS11 loom_impact
;;;; ==================================================================

(defun render-path (view path)
  "An impact path as the names it ran through: \"calls>apply-op calls>plan-op\".
SS9 requires the path be carried; a chain of entity names is what makes it
usable, because an agent can see *why* something is impacted and judge whether
that reason matters."
  (format nil "~{~a~^ ~}"
          (loop for hop in path
                for entity = (get-entity view (hop-entity-id hop))
                collect (format nil "~(~a~)>~a" (hop-rel-type hop)
                                (if (and entity (slot-boundp entity 'name))
                                    (name entity)
                                    (hop-entity-id hop))))))

(defun impact-entry-summary (view entry)
  (append (entity-summary (impact-entry-entity entry))
          (list :depth (impact-entry-depth entry)
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
            (summarize-entities (impact-result-possibly-affected result))))))
