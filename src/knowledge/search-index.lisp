;;;; A tokenised postings index, and BM25 over it -- DES-0026 D4, PLAN-0032 S4.
;;;;
;;;; What this replaces is a substring scan. FIND-ENTITIES walks every entity in
;;;; the graph and calls SEARCH on each name, once per query token, and that is
;;;; the retrieval layer under the seeder. It is wrong three ways and only one of
;;;; them is speed.
;;;;
;;;; It matches substrings, which is why MATCH-RANK needs four bands to sort out
;;;; the damage: "for" matches FORMAT and "data" matches every name containing
;;;; it. Prefix and substring ranks are artifacts of not having tokens.
;;;;
;;;; And it cannot count. Nothing in the pipeline can ask how many entities a
;;;; term matches, which is precisely the number every hand-tuned constant in
;;;; SEED-SCORE is approximating -- the 48-word stopword list, the coverage
;;;; band's 8, the seed share cap, and the two patches around the "data"
;;;; fragment. Document frequency is the quantity they were all standing in for,
;;;; and it is a postings list length.
;;;;
;;;; The field set is six since REQ-0035, and the sixth is what makes length
;;;; normalisation the point rather than a refinement: a 5,639-character
;;;; docstring and a 12-character function name are now fields on one entity.
;;;; DES-0028 D6 declined to invent a normalisation for that on the grounds that
;;;; BM25 would bring one, which is this file's obligation to discharge.

(in-package :loom-knowledge)

;;;; ==================================================================
;;;; One tokeniser, used by both sides
;;;; ==================================================================

(defun index-tokens (string)
  "STRING as index terms: lowercased words, split at every non-alphanumeric
character and at every lower-to-upper case boundary.

One function for indexing and for querying, and PLAN-0032 names why: a postings
map that tokenises differently from the query path silently returns nothing for
terms that should match, and the symptom is a smaller bundle rather than an
error -- CON-0006's expensive error at the mechanism level. There is no second
tokeniser to drift from this one.

The case boundary is what makes a JavaScript tree searchable at all: LayerEditor
yields LAYER and EDITOR, so a task saying \"layer editor\" reaches it. The
non-alphanumeric split covers Lisp's hyphens and the stars around a special:
*CALL-SITE-CEILING* yields CALL, SITE and CEILING.

The whole spelling is kept as well, so an exact name is still a term of its own
and a query naming one thing hits it directly rather than through its parts."
  (let ((tokens '())
        (current (make-string-output-stream)))
    (flet ((emit ()
             (let ((word (get-output-stream-string current)))
               (when (plusp (length word))
                 (pushnew (string-downcase word) tokens :test #'string=)))))
      (loop for i from 0 below (length string)
            for c = (char string i)
            do (cond ((not (alphanumericp c)) (emit))
                     ;; a lower-to-upper transition starts a new word, so
                     ;; LayerEditor is two terms and URL stays one
                     ((and (upper-case-p c) (plusp i)
                           (lower-case-p (char string (1- i))))
                      (emit)
                      (write-char c current))
                     (t (write-char c current)))
            finally (emit)))
    (let ((whole (string-downcase string)))
      (when (and (plusp (length whole)) (not (member whole tokens :test #'string=)))
        (push whole tokens)))
    tokens))

;;;; ==================================================================
;;;; The fields, and what each is worth
;;;; ==================================================================

(defparameter *field-weights*
  '((:name          4.0)
    (:documentation 1.5)
    (:signature     1.0)
    (:arguments     1.0)
    (:package       0.5)
    (:path          0.25))
  "How much a match in each field is worth. DES-0026 D4.

Name highest because an identifier is chosen: an author naming a thing said more
about it than an author mentioning it. Prose next, and above the signature
because a docstring is about the definition where an argument list is about its
shape.

Path lowest rather than absent, and that is the rank-3 drop turned into a weight.
SEED-MATCHES discards a match that reached an entity only through its file path
-- \"a token that reached an entity only through its path is neither a seed nor
evidence about the token\" -- which is true of it being a *seed* and false of it
being *nothing*. Under CON-0006 a weak signal belongs at the bottom of the index
tier rather than in the bin, and D1's inventory listed that drop as a recall
gate to be turned into a weight.")

(defun entity-field-text (entity field)
  "ENTITY's text for FIELD, or NIL."
  (case field
    (:name (and (slot-boundp entity 'name) (name entity)))
    (:documentation (getp entity :documentation))
    (:signature (getp entity :signature))
    (:arguments (let ((args (getp entity :arguments)))
                  (and args (format nil "~{~a~^ ~}" args))))
    (:package (let ((system (getp entity :system)))
                (and system (princ-to-string system))))
    (:path (or (getp entity :file) (getp entity :path)))
    (t nil)))

(defun entity-field-tokens (entity)
  "ENTITY as an alist of (field . tokens), fields with no text omitted."
  (loop for (field) in *field-weights*
        for text = (entity-field-text entity field)
        when text collect (cons field (index-tokens text))))

;;;; ==================================================================
;;;; The index
;;;; ==================================================================

(defstruct (search-index (:conc-name sx-))
  "Term to entities, plus what BM25 needs to weigh a hit.

POSTINGS is term -> list of entities, which is both the candidate set for a
query and, by its length, the document frequency that makes IDF possible.

FIELD-TOKENS is entity id -> the alist ENTITY-FIELD-TOKENS produced, cached
because BM25 asks for a term frequency per field per candidate and recomputing
it would re-split 315 KB of prose per query.

AVERAGE-LENGTH is per field, which is what length normalisation needs and what
a single global average would get wrong: a name averages three tokens and a
docstring sixty, so one average across both would treat every documented entity
as pathologically long."
  (postings (make-hash-table :test #'equal))
  (field-tokens (make-hash-table :test #'equal))
  (document-count 0)
  (average-length (make-hash-table :test #'eq)))

(defun build-search-index (view)
  "A SEARCH-INDEX over every non-stale entity in VIEW."
  (let ((sx (make-search-index))
        (totals (make-hash-table :test #'eq))
        (counts (make-hash-table :test #'eq)))
    (dolist (entity (find-entities view))
      (let ((fields (entity-field-tokens entity)))
        (setf (gethash (id entity) (sx-field-tokens sx)) fields)
        (incf (sx-document-count sx))
        (loop for (field . tokens) in fields
              do (incf (gethash field totals 0) (length tokens))
                 (incf (gethash field counts 0))
                 (dolist (token tokens)
                   (pushnew entity (gethash token (sx-postings sx)) :test #'eq)))))
    (maphash (lambda (field total)
               (setf (gethash field (sx-average-length sx))
                     (/ (float total) (max 1 (gethash field counts 1)))))
             totals)
    sx))

(defun document-frequency (sx term)
  (length (gethash term (sx-postings sx))))

(defun inverse-document-frequency (sx term)
  "Robertson-Sparck-Jones IDF, floored at zero.

The floor matters on a small tree: a term appearing in more than half the
entities gives a negative weight under the unfloored formula, and a negative
weight would make a common word *penalise* the entities carrying it rather than
merely failing to help them. Zero is the honest answer -- this term says
nothing -- and it is the whole retirement of the 48-word stopword list, measured
per tree instead of guessed at once."
  (let ((n (sx-document-count sx))
        (df (document-frequency sx term)))
    (max 0.0 (log (/ (+ (- n df) 0.5) (+ df 0.5))))))

(defparameter *bm25-k1* 1.2
  "BM25's term-frequency saturation. The textbook value.")

(defparameter *bm25-b* 0.75
  "BM25's length-normalisation strength. The textbook value, and the parameter
DES-0028 D6 was deferring to when it declined to normalise prose by hand: at
0.75 a 5,639-character docstring is discounted against the average rather than
counted term by term.")

(defun bm25-saturation (tf len avg)
  "BM25's term-frequency component, normalised by field length.

Two behaviours in one expression, and both are why this replaces a count. The
numerator saturates: a term appearing ten times in a paragraph is worth a little
more than five times and not twice as much. The denominator penalises length
against the field's own average, which is what DES-0028 D6 deferred to when it
declined to hand-normalise a 5,639-character docstring against a 12-character
name."
  (/ (* tf (+ *bm25-k1* 1))
     (+ tf (* *bm25-k1* (+ 1 (- *bm25-b*) (* *bm25-b* (/ len avg)))))))

(defun bm25-score (sx entity terms)
  "BM25 over ENTITY's six fields for TERMS, weighted by *FIELD-WEIGHTS*.

Summed per field rather than over a concatenation, because the fields have
different lengths and different worth and a concatenation loses both."
  (let ((fields (gethash (id entity) (sx-field-tokens sx)))
        (total 0.0))
    (loop for (field . tokens) in fields
          for weight = (or (second (assoc field *field-weights*)) 0.0)
          for len = (length tokens)
          for avg = (max 1.0 (gethash field (sx-average-length sx) 1.0))
          do (dolist (term terms)
               (let ((tf (count term tokens :test #'string=)))
                 (when (plusp tf)
                   (incf total (* weight
                                  (inverse-document-frequency sx term)
                                  (bm25-saturation tf len avg)))))))
    total))

(defun search-candidates (sx terms)
  "Every entity carrying at least one of TERMS, as a list.

The postings lookup that replaces a linear scan per token. A term nothing
carries contributes nothing rather than costing a walk."
  (let ((seen (make-hash-table :test #'eq))
        (out '()))
    (dolist (term terms)
      (dolist (entity (gethash term (sx-postings sx)))
        (unless (gethash entity seen)
          (setf (gethash entity seen) t)
          (push entity out))))
    out))
