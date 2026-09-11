;;;; Finding a definition by resemblance to another definition.
;;;;
;;;; REQ-0042 and DES-0041. The question a shared library creates: does this
;;;; codebase already have its own version of what that library provides. It is
;;;; the one question `find' structurally cannot answer, because a duplicate is
;;;; precisely the case where the two names differ -- slurp-file and read-file,
;;;; fnv-1a and content-fingerprint, plist-shaped-p and plistp.
;;;;
;;;; Nothing here embeds anything. DES-0041 D1: the subject is a definition
;;;; Loom already indexed, so its vector was written into the sidecar when the
;;;; store was built and VECTOR-FOR reads it. `context' pays 31 ms per query
;;;; for one embedding call and this pays none, which leaves the 0.87 ms scan
;;;; as the whole cost.
;;;;
;;;; Two stores are comparable here without a check of this file's own, and
;;;; that is DEC-0006's doing rather than an assumption. LOAD-VECTOR-STORE
;;;; refuses a store whose embedder identity is not the configured embedder's,
;;;; and every repository loads through it against one CURRENT-EMBEDDER, so two
;;;; stores held at once carry the same embedder or one of them was never
;;;; loaded. A cosine between vectors from two models is a number in the
;;;; ordinary range that no arithmetic can mark wrong, which is CON-0001's
;;;; fabricated fact in the shape no count would reveal.
;;;;
;;;; No repository concept appears below. loom-knowledge is handed a graph and
;;;; never learns which repository it belongs to; resolving a designator to a
;;;; graph and a store is the caller's, the way BUILD-CONTEXT takes SOURCE-FN
;;;; rather than reaching for REPOSITORY-ROOT.

(in-package :loom-knowledge)

(defparameter *resemblance-limit* 10
  "How many neighbours `similar' returns by default.

Ten rather than the eight DEC-0005 settled for a bundle, because the two counts
are charged against different things. A seed spends a slot in a bundle a caller
reads whole; a resemblance row is a line in a list a caller scans and stops
reading. Nothing measures this one.")

(defparameter *survey-limit* 40
  "The most rows a survey prints, whatever reaches the cut.

*SURVEY-CUT* is calibrated on a small pair and does not travel. Measured
2026-08-23: at 0.80, Loom against utils gives 9 differing-name rows and
front-end against game-server gives 486, because two large repositories built
from one domain resemble each other everywhere -- that survey\'s rows start at
0.9864 and stay above 0.80 for hundreds of entries.

So the cut alone cannot keep the table readable and a caller cannot be expected
to guess a per-pair cut. Forty rows and a count of what was left, which is
BUG-0002\'s answer to the same problem in `find\': a truncated list read as the
whole truth is worse than a long one.")

(defparameter *survey-cut* 0.80
  "The cosine a survey row has to reach.

DES-0041 D5 chose it off the measured table rather than by fitting a case: on
Loom against utils, best-match-per-entity returns 21 rows at 0.80 and 154 at
0.70, and 0.80 is where the list stays readable by hand. The parameter is the
escape hatch and the default is the answer -- a caller who sets 0.70 gets 139
differing-name rows they will not read.")


;;;; ==================================================================
;;;; Why a pair is suspicious (DES-0041 D6)
;;;; ==================================================================

(defun shared-words (a b)
  "The words A and B have in common, in A's order, lowercased and deduplicated."
  (let ((seen (make-hash-table :test #'equal))
        (other (make-hash-table :test #'equal)))
    (dolist (word b) (setf (gethash word other) t))
    (loop for word in a
          when (and (gethash word other) (not (gethash word seen)))
            do (setf (gethash word seen) t)
            and collect word)))

(defun content-words (words)
  "WORDS with the stopwords and the one- and two-letter words removed.

The same filter TASK-TOKENS applies, for a reason that is this file's rather
than the seeder's. A shared word here is shown to a human as the evidence a
pair is suspicious, and two docstrings in English share `a', `is', `and' and
`of' whatever they are about -- FNV-1A against CONTENT-FINGERPRINT reported
sixteen shared words before this filter and four of them carried the claim."
  (remove-if (lambda (word)
               (or (< (length word) 3)
                   (member word *context-stopwords* :test #'string=)))
             words))

(defun prose-words (entity)
  "ENTITY's documentation as content words, or NIL when it declares none."
  (let ((documentation (getp entity :documentation)))
    (when (and documentation (plusp (length documentation)))
      (content-words (plain-words documentation)))))

(defun entity-name-words (entity)
  "ENTITY's name as the embedder saw it: NAME-AS-WORDS, split into words.

The same function that built the document the vector came from, which is what
makes NAME-EQUAL-P below an identity rather than an approximation of one."
  (let ((name (and (slot-boundp entity 'name) (princ-to-string (name entity)))))
    (when name (plain-words (name-as-words name)))))

;;; NAME-EQUAL-P below compares the *unfiltered* words, because it is asking
;;; whether the embedder could have told two names apart and the embedder saw
;;; every word. RESEMBLANCE-REASONS filters, because it is showing a human why.

(defun resemblance-reasons (subject candidate)
  "Why SUBJECT and CANDIDATE might be the same thing, as a plist.

DES-0041 D6 and D7. Every field points and none of them concludes: five of the
ten pairs REQ-0042 was written from were read on both sides and were not
duplicates, so an answer that asserted equivalence would have invited a
mechanical rewrite half the time.

Arity is reported and never ranked on. 518 of Loom's 918 functions that take an
argument are arity 1, so agreeing on it separates almost nothing -- it tells a
reader whether a swap is even shaped like a swap, which is a different job from
saying the two do the same work.

Computed over the candidates that survived the scan rather than during it, so
none of this costs a pass over the store."
  (let ((subject-arity (entity-arity subject))
        (candidate-arity (entity-arity candidate)))
    (list :shared-name-words (shared-words (content-words (entity-name-words subject))
                                           (content-words (entity-name-words candidate)))
          :shared-prose-words (shared-words (prose-words subject)
                                            (prose-words candidate))
          :subject-arity subject-arity
          :arity candidate-arity
          :same-arity (and subject-arity candidate-arity
                           (= subject-arity candidate-arity)))))

(defun name-equal-p (a b)
  "True when A and B carry the same name once split into words.

DES-0041 D4's comparison, and NAME-AS-WORDS is deliberately the function doing
it: that is the text the store embedded, so two entities compare equal here
exactly when their vectors could not have told them apart. `getTypeFromObj' and
`get-type-from-obj' are one name by this test, which is the point -- they are
one name to the embedder too, and they score 1.0000 against each other."
  (equal (entity-name-words a) (entity-name-words b)))


;;;; ==================================================================
;;;; The primitive (DES-0041 D3, R1 and R2)
;;;; ==================================================================

(defun resembling (subject source-store target-view target-store
                   &key (limit *resemblance-limit*) (cut 0.0))
  "Definitions in TARGET-VIEW resembling SUBJECT, best first.

A list of plists, each carrying the candidate's ENTITY-SUMMARY, its cosine
against SUBJECT, and RESEMBLANCE-REASONS. NIL when SOURCE-STORE holds no vector
for SUBJECT, which is a caller naming an entity indexed since the store was
built.

SUBJECT is the entity rather than its id, and it is the entity from the
*source* view. Across repositories TARGET-VIEW cannot resolve it -- the id
means nothing there -- and D6's reasons need both sides, so passing the id
would have made every cross-repository answer reasonless. That is the case this
whole query exists for.

SOURCE-STORE and TARGET-STORE may be the same store. When they are, SUBJECT is
dropped from its own results: an entity's cosine with itself is 1.0000 and
would take the first row of every same-repository answer.

An id TARGET-VIEW no longer holds is passed over in silence. The store is
derived from an index that has since moved, which PLAN-0043 S2b makes rare and
does not make impossible, and a stale id is CON-0001's fabricated fact rather
than an error to raise at a caller who asked about something else."
  (let* ((subject-id (id subject))
         (query (loom-embed:vector-for source-store subject-id)))
    (when query
      ;; One extra candidate, because the subject occupies a slot in its own
      ;; results whenever the two stores are the same one.
      (let* ((same (eq source-store target-store))
             (hits (loom-embed:nearest target-store query (if same (1+ limit) limit)))
             (rows (loop for (id . cosine) in hits
                         for entity = (and (>= cosine cut)
                                           (not (equal id subject-id))
                                           (get-entity target-view id))
                         when entity
                           collect (list* :similarity cosine
                                          (append (entity-summary entity)
                                                  (resemblance-reasons subject entity))))))
        (if (> (length rows) limit) (subseq rows 0 limit) rows)))))


;;;; ==================================================================
;;;; The survey (DES-0041 D5, R3)
;;;; ==================================================================

(defun survey-candidates (view &key property-filters)
  "The entities of VIEW a survey compares, in a stable order.

The five types the store holds vectors for. A :FILE's name is a path and a
:TEST is not a definition anybody migrates, so both would put a row in the
table whose pair nobody wants."
  (loop for type in '(:function :method :class :interface :variable)
        append (find-entities view :entity-type type
                               :property-filters property-filters)))

(defun resemblance-survey (source-view source-store target-view target-store
                           &key (cut *survey-cut*))
  "Every definition of SOURCE-VIEW that resembles one in TARGET-VIEW, best first.

Three values: the rows, how many pairs were dropped for sharing a name, and
how many rows reached CUT before *SURVEY-LIMIT* truncated the list.

One row per source entity carrying its single best match, not every pair above
CUT. DES-0041 D5 measured the difference on Loom against utils: 21 rows at 0.80
against 301 distinct differing-name pairs at 0.70, and the flat form returns
DEFAULT-JSON-KEY-NAME four times against four different utils entities, which
is one fact reported four ways.

A pair whose two names are equal once split into words is counted and dropped.
Those are what `find' already answers -- REQ-0042 opens on `find' over the
library's 44 exported names returning two hits, and this table exists for the
other 42. They are also all of the top: an entity with no docstring embeds its
name as words, so two entities with the same name embed the same document and
score 1.0000. Ranking them in would put every one of them above FNV-1A against
CONTENT-FINGERPRINT at 0.8700.

The cost is |source| x |target| x dimensions multiply-adds through DOT-AT plus
one set of reasons per surviving row. Measured 2026-08-23 end to end: Loom by
utils, 1720 by 113, is 0.13 s; front-end by game-server, 3457 by 1811 and the
largest pair this tree holds, is 3.69 s. The scan alone is 0.08 s and 2.55 s,
so the reasons and the summaries are the other 45%."
  (let ((rows '())
        (name-equal 0))
    (dolist (subject (survey-candidates source-view))
      ;; A limit of 1 is the whole of D5: the scan keeps one candidate per
      ;; subject, so nothing here grows with how many things a subject
      ;; resembles.
      (let ((best (first (resembling subject source-store target-view target-store
                                     :limit 1 :cut cut))))
        (when best
          (let ((candidate (get-entity target-view (getf best :id))))
            (if (and candidate (name-equal-p subject candidate))
                (incf name-equal)
                (push (list* :subject-id (id subject)
                             :subject-name (and (slot-boundp subject 'name)
                                                (name subject))
                             :subject-location (entity-location subject)
                             best)
                      rows))))))
    (let ((ranked (sort (nreverse rows) #'> :key (lambda (row) (getf row :similarity)))))
      (values (if (> (length ranked) *survey-limit*)
                  (subseq ranked 0 *survey-limit*)
                  ranked)
              name-equal
              (length ranked)))))

