;;;
;;; Tests for the prose-against-index report (REQ-0021 R7, DES-0022 D3a).
;;;
;;; The report's whole risk is a reader treating a candidate as a finding, so
;;; most of what is asserted here is about what it declines to claim.
;;;

(in-package :synoptik-knowledge-test)

(def-suite prose
  :in all-tests
  :description "PROSE-REPORT: candidates for review, never a verdict.")

(in-suite prose)

(defun p-markdown (name tokens)
  (make-instance 'document-entity :name name :origin-file name
                 :properties (properties-table
                              (list :path name :format :markdown :mentions tokens))))

(defun p-fixture ()
  "Two markdown documents with opposite resolution rates.

The pair is the report's central distinction, taken from real measurements on
game-server: semantic-validators.md resolves 24 of 42 and its misses are
candidate drift, while piece-editor-req.md resolves 2 of 27 and its misses are
about a repository this one does not contain."
  (let* ((f (make-k-fixture))
         (g (k-graph f))
         ;; Resolves two of four: about this codebase.
         (engaged (p-markdown "docs/engaged.md"
                              '("resolve-overlay" "compose-view" "delete-obj" "data")))
         ;; Resolves none of four: about something else.
         (foreign (p-markdown "docs/foreign.md"
                              '("src/ui/thing.jsx" "sprite" "latlng" "rendertexture"))))
    (dolist (d (list engaged foreign)) (add-entity g d))
    (k-edge g :mentions engaged (k-resolve f))
    (k-edge g :mentions engaged (k-compose f))
    (values f engaged foreign)))

(defun prose-row (report name)
  (find name (getf report :documents)
        :key (lambda (row) (getf row :document)) :test #'string=))

(test a-document-about-this-codebase-is-told-from-one-that-is-not
  ;; The measurement the whole report turns on. Without it, a .jsx path in a
  ;; front-end design note is reported beside a renamed Lisp function as though
  ;; they were the same kind of thing.
  (multiple-value-bind (f) (p-fixture)
    (let* ((report (prose-report (k-graph f)))
           (engaged (prose-row report "docs/engaged.md"))
           (foreign (prose-row report "docs/foreign.md")))
      (is-true (getf engaged :about-this-tree))
      (is-false (getf foreign :about-this-tree))
      (is (string= "docs/engaged.md"
                   (getf (first (getf report :documents)) :document))
          "and the engaged document is read first"))))

(test an-ordinary-word-is-not-offered-as-a-candidate
  ;; REQ-0014 drops unresolved mentions in silence because prose is full of
  ;; ordinary words in backticks. A report that listed every one would bury the
  ;; signal it exists to surface.
  (multiple-value-bind (f) (p-fixture)
    (let* ((report (prose-report (k-graph f)))
           (engaged (prose-row report "docs/engaged.md")))
      (is (member "delete-obj" (getf engaged :candidates) :test #'string=)
          "a hyphenated name that resolved to nothing is a candidate: ~a"
          (getf engaged :candidates))
      (is (not (member "data" (getf engaged :candidates) :test #'string=))
          "and a bare English word is not"))))

(test a-resolved-name-is-not-a-candidate
  (multiple-value-bind (f) (p-fixture)
    (let* ((report (prose-report (k-graph f)))
           (engaged (prose-row report "docs/engaged.md")))
      (is (= 2 (getf engaged :resolved)))
      (is (not (member "resolve-overlay" (getf engaged :candidates) :test #'string=))))))

(test the-report-never-calls-anything-stale
  ;; The distinction this file exists to keep. A name that did not resolve
  ;; means the prose and the index disagree; which of them moved is not in the
  ;; index, and the document may be the last record of something deleted by
  ;; mistake.
  (multiple-value-bind (f) (p-fixture)
    (let ((text (render-prose (prose-report (k-graph f)))))
      ;; "wrong" is deliberately not in this list: the disclaimer below uses it
      ;; -- "not that the prose is wrong" -- and an assertion that forbade the
      ;; word while requiring that sentence contradicts itself. The words here
      ;; are the ones that would be a verdict wherever they appeared.
      (dolist (word '("stale" "out of date" "outdated"))
        (is (not (search word text))
            "the report says ~s; it may only report a disagreement" word))
      (is (search "not that the prose is wrong" text)
          "and it says so where a reader will see it")
      (is (search "heuristic" text)
          "and admits the identifier filter is one"))))

(test a-tree-with-no-prose-says-so
  (let ((report (prose-report (k-graph (make-k-fixture)))))
    (is (zerop (getf report :reviewed)))
    (is (search "No indexed prose" (render-prose report)))))

(test the-counts-agree-with-the-list-they-count
  ;; A regression guard for a destructive sort. CL:SORT may rearrange the conses
  ;; it is given, so a plist that sorted the row list in one slot and measured it
  ;; in the next read a truncated tail. Measured on a prepared game-server copy
  ;; before the fix: the header said eleven documents and one engaged while the
  ;; body printed twelve and two.
  ;;
  ;; Asserting the two against each other rather than against a literal is what
  ;; makes this survive the fixture changing.
  (multiple-value-bind (f) (p-fixture)
    (let ((report (prose-report (k-graph f))))
      (is (= (getf report :reviewed) (length (getf report :documents)))
          "reviewed ~d against ~d rows"
          (getf report :reviewed) (length (getf report :documents)))
      (is (= (getf report :engaged)
             (count-if (lambda (row) (getf row :about-this-tree))
                       (getf report :documents)))
          "engaged ~d against ~d rows marked so"
          (getf report :engaged)
          (count-if (lambda (row) (getf row :about-this-tree))
                    (getf report :documents))))))

