;;;; Where the prose and the index disagree.
;;;;
;;;; REQ-0021 R7, DES-0022 D3a. Before a generated architecture document is
;;;; written, the markdown a repository already has should be read -- and where
;;;; it describes structure the index does not show, that disagreement is
;;;; reported rather than reconciled.
;;;;
;;;; The word "reported" is doing work. This file will not tell you a document
;;;; is stale, and the distinction is not pedantry: a name in prose that
;;;; resolves to nothing means the prose and the code disagree, and nothing in
;;;; an index says which of them moved. A document describing a function that
;;;; was renamed is stale; one describing a function that was deleted by mistake
;;;; is the only remaining record of it. So this produces candidates for a human
;;;; to read, and the renderer says so where a reader will see it.
;;;;
;;;; Two measurements make that a report rather than noise, and the second is
;;;; the one that matters.
;;;;
;;;; REQ-0014 drops an unresolved mention in silence on purpose, because prose
;;;; is full of ordinary words in backticks. Listing every one would bury the
;;;; signal in `data', `value' and `null'. So the tokens are filtered to those
;;;; shaped like identifiers -- which is a heuristic, is labelled as one, and is
;;;; the alternative to a report nobody reads.
;;;;
;;;; And a document's *resolution rate* decides whether its misses are drift at
;;;; all. Measured on game-server: semantic-validators.md resolves 24 of
;;;; 42 and its misses include `delete-obj'; piece-editor-req.md resolves 2 of
;;;; 27 and its misses are .jsx paths. The first is a document about this
;;;; codebase naming something it no longer has. The second is about a different
;;;; repository, and calling its names drift would be a finding about nothing.

(in-package :loom-knowledge)

(defparameter *prose-candidate-limit* 12
  "How many unresolved names the report shows per document.
A cap on the same grounds as every other here: the tail of a token list is
where the ordinary words live, and a reader who has seen twelve has the shape.")

(defparameter *prose-engaged-rate* 1/3
  "The resolution rate above which a document is treated as being about this
codebase.

A threshold, and therefore a judgement written where it can be argued with
rather than buried in a conditional. A third is deliberately generous: prose
mixes names with English, so a document genuinely about this code will not
resolve most of its tokens, and setting this high would file real documents
under `about something else' and hide exactly the drift the report is for.")

(defun identifier-shaped-p (token)
  "True when TOKEN looks like a name rather than an English word.

A heuristic, and the report says so. A hyphen, a dot, a slash or an underscore
is what separates `delete-obj', `map-element-type.representation' and
`utils/dict.lisp' from `data', `value' and `sprite'. It will admit an
occasional hyphenated phrase and exclude an occasional one-word function name;
both are acceptable against the alternative, which is every backtick in every
document."
  (and (stringp token)
       (> (length token) 2)
       (some (lambda (c) (member c '(#\- #\. #\/ #\_))) token)))

(defun document-prose-row (view document)
  "One markdown document's candidate names, or NIL when it has none at all.

The resolved set is read from the edges rather than recomputed, so this reports
what resolution actually did rather than a second opinion about what it should
have done."
  (let* ((tokens (remove-duplicates (remove nil (getp document :mentions))
                                    :test #'string-equal))
         (resolved (loop for n in (neighbors view (id document)
                                             :rel-types '(:mentions) :direction :out)
                         for entity = (neighbor-entity n)
                         when (slot-boundp entity 'name)
                           collect (princ-to-string (name entity))))
         (missed (remove-if (lambda (token)
                              (member token resolved :test #'string-equal))
                            tokens))
         (candidates (remove-if-not #'identifier-shaped-p missed)))
    (when tokens
      (let ((rate (if (zerop (length tokens)) 0
                      (/ (length resolved) (length tokens)))))
        (list :document (and (slot-boundp document 'name)
                             (princ-to-string (name document)))
              :path (or (getp document :path) (origin-file document))
              :tokens (length tokens)
              :resolved (length resolved)
              ;; A rational is exact and useless on a wire, so both: the ratio
              ;; for sorting and a percentage for a reader and a JSON client.
              :rate (float rate)
              :percent (round (* 100 rate))
              ;; The whole point of the threshold, said as a field rather than
              ;; left for a reader to infer from a number.
              :about-this-tree (>= rate *prose-engaged-rate*)
              :unresolved (length missed)
              :candidates (if (> (length candidates) *prose-candidate-limit*)
                              (subseq candidates 0 *prose-candidate-limit*)
                              candidates)
              :candidate-count (length candidates))))))

(defun prose-report (view &key repository)
  "What the prose claims that the index does not show. REQ-0021 R7.

Ordered by resolution rate, highest first, so the documents most likely to be
about this codebase -- and therefore whose misses are most likely to be real
disagreements -- are read first."
  (let* ((rows (loop for document in (entities-of-type view :document)
                     for row = (document-prose-row view document)
                     when row collect row))
         ;; Counted before the sort, and the sort takes a copy. CL:SORT is
         ;; destructive and may rearrange the conses it was given, so a plist
         ;; that sorted this list in one slot and measured it in the next read a
         ;; truncated tail -- which reported eleven documents while printing
         ;; twelve, and one engaged while showing two. The numbers a reader
         ;; checks the list against must not be computed from the list after
         ;; something else has had it.
         (reviewed (length rows))
         (engaged (count-if (lambda (row) (getf row :about-this-tree)) rows)))
    (list :repository repository
          :documents (sort (copy-list rows) #'> :key (lambda (row) (getf row :rate)))
          :reviewed reviewed
          :engaged engaged)))

(defun render-prose (report)
  "REPORT as the text a human reads before writing an architecture document."
  (with-output-to-string (out)
    (format out "~&# Prose against the index~@[ for ~a~]~%" (getf report :repository))
    (format out "~&# ~d document~:p with candidate names, ~d of them about this tree~%"
            (getf report :reviewed) (getf report :engaged))
    (when (zerop (getf report :reviewed))
      (format out "~&No indexed prose carries a name to check.~%"))
    ;; Said once, at the top, and not softened. The report's whole risk is a
    ;; reader treating a candidate as a finding.
    (format out "~&~%A name here did not resolve. That means the prose and the index~%")
    (format out "disagree -- not that the prose is wrong. The document may be the last~%")
    (format out "record of something deleted by mistake. These are candidates to read,~%")
    (format out "and the identifier filter is a heuristic that will miss some and~%")
    (format out "admit others.~%")
    (dolist (row (getf report :documents))
      (format out "~&~%~a~%" (getf row :document))
      (format out "  ~d of ~d names resolved (~d%)~a~%"
              (getf row :resolved) (getf row :tokens) (getf row :percent)
              (if (getf row :about-this-tree)
                  ""
                  " -- mostly about something this repository does not contain"))
      (when (getf row :candidates)
        (format out "  candidates~@[ (~d of ~d shown)~]:~%"
                (and (> (getf row :candidate-count) (length (getf row :candidates)))
                     (length (getf row :candidates)))
                (getf row :candidate-count))
        (dolist (candidate (getf row :candidates))
          (format out "    ~a~%" candidate))))))
