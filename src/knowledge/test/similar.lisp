;;;
;;; Tests for src/knowledge/similar.lisp -- REQ-0042 and DES-0041.
;;;
;;; Nothing here reaches ollama. The stores are built by hand from vectors
;;; chosen so that the ordering is decided by the fixture rather than by a
;;; model, which is what lets the assertions be about the query and not about
;;; nomic-embed-text.
;;;

(in-package :synoptik-knowledge-test)

(def-suite similar
  :in all-tests
  :description "RESEMBLING, the reasons a pair is suspicious, and name equality.")

(in-suite similar)

;;; ------------------------------------------------------------------
;;; Fixtures
;;; ------------------------------------------------------------------

;;; SIM- rather than S- or R-, and both of those were tried. S-FUNCTION and
;;; S-GRAPH already exist in the structure suite, which loads before this file,
;;; so a same-named helper here silently redefined theirs and broke tests in
;;; another file. R-FUNCTION already exists in src/graph/test/resolve.lisp,
;;; which is a different package and so breaks nothing at runtime -- but Synoptik
;;; indexes itself, cannot place a package for a test file, and falls back to
;;; matching on the spelling (DES-0015), so every one of the 50 calls below
;;; became an ambiguous call site in Synoptik's own index. The ambiguous population
;;; is what *CALL-SITE-CEILING* watches as the number that moves when something
;;; has gone wrong, and it went 16 to 70.

(defun sim-function (name start &key documentation arguments)
  (make-instance 'function-entity :name name
                 :origin-file "src/lib.lisp"
                 :properties (properties-table
                              (append (list :file "src/lib.lisp"
                                            :start-line start
                                            :end-line (+ start 8)
                                            :language :lisp)
                                      (when documentation
                                        (list :documentation documentation))
                                      (when arguments
                                        (list :arguments arguments))))))

(defun sim-store (entities-and-vectors &key (dimensions 3))
  "A store over ENTITIES-AND-VECTORS, an alist of entity to vector."
  (let* ((count (length entities-and-vectors))
         (flat (make-array (* count dimensions) :element-type 'single-float
                                                :initial-element 0.0)))
    (loop for (nil . v) in entities-and-vectors
          for i from 0
          do (replace flat (synoptik-embed::normalise v) :start1 (* i dimensions)))
    (synoptik-embed:make-vector-store
     :embedder-id "fixed:test" :dimensions dimensions :count count
     :ids (map 'simple-vector (lambda (pair) (princ-to-string (id (car pair))))
               entities-and-vectors)
     :digests (make-array count :initial-element 0)
     :vectors flat)))

(defun sim-graph (entities)
  (let ((g (make-graph)))
    (dolist (e entities g) (add-entity g e))))


;;; ------------------------------------------------------------------
;;; The primitive (DES-0041 D3)
;;; ------------------------------------------------------------------

(test the-nearest-definition-in-another-repository-comes-first
  ;; R1 and R2 in one assertion: the subject is in one repository, every
  ;; candidate is in another, and no name is shared with any of them.
  (let* ((subject (sim-function "fnv-1a" 10))
         (near    (sim-function "content-fingerprint" 10))
         (far     (sim-function "parse-config" 30))
         (source-store (sim-store (list (cons subject #(1.0 0.0 0.0)))))
         (target-store (sim-store (list (cons near #(0.9 0.1 0.0))
                                      (cons far  #(0.0 0.0 1.0)))))
         (target-view  (sim-graph (list near far)))
         (rows (resembling subject source-store target-view target-store)))
    (is (= 2 (length rows)))
    (is (string= "content-fingerprint" (getf (first rows) :name)))
    (is (> (getf (first rows) :similarity) (getf (second rows) :similarity))
        "best first")))

(test the-subject-is-not-returned-as-its-own-nearest-neighbour
  ;; An entity's cosine with itself is 1.0 and would take the first row of
  ;; every same-repository answer. The fixture puts the subject's own vector
  ;; nearest by construction, so this fails rather than passes if the
  ;; exclusion is dropped.
  (let* ((subject (sim-function "seed-score" 10))
         (other   (sim-function "seed-matches" 30))
         (store (sim-store (list (cons subject #(1.0 0.0 0.0))
                               (cons other   #(0.9 0.1 0.0)))))
         (view (sim-graph (list subject other)))
         (rows (resembling subject store view store)))
    (is (= 1 (length rows)))
    (is (string= "seed-matches" (getf (first rows) :name))
        "the subject is dropped and the next candidate is not")))

(test a-subject-the-store-has-no-vector-for-returns-nothing
  ;; A definition indexed since the store was built. Not an error: the store is
  ;; derived and lags the index by construction.
  (let* ((subject (sim-function "brand-new" 10))
         (other   (sim-function "old-thing" 30))
         (store (sim-store (list (cons other #(1.0 0.0 0.0)))))
         (view (sim-graph (list other))))
    (is (null (resembling subject store view store)))))

(test an-id-the-target-view-no-longer-holds-is-passed-over
  ;; CON-0001: a store derived from an index that has since moved holds a stale
  ;; id, and the row it would produce is a fabricated fact. The entity is in the
  ;; store and absent from the graph, which is exactly that state.
  (let* ((subject (sim-function "fnv-1a" 10))
         (gone    (sim-function "deleted-thing" 20))
         (kept    (sim-function "content-fingerprint" 30))
         (source-store (sim-store (list (cons subject #(1.0 0.0 0.0)))))
         (target-store (sim-store (list (cons gone #(0.99 0.01 0.0))
                                      (cons kept #(0.9 0.1 0.0)))))
         ;; GONE is in the store and not in the view.
         (target-view (sim-graph (list kept)))
         (rows (resembling subject source-store target-view target-store)))
    (is (= 1 (length rows)))
    (is (string= "content-fingerprint" (getf (first rows) :name)))))

(test the-cut-drops-a-candidate-and-the-limit-truncates
  (let* ((subject (sim-function "a" 10))
         (near    (sim-function "b" 20))
         (far     (sim-function "c" 30))
         (source-store (sim-store (list (cons subject #(1.0 0.0 0.0)))))
         (target-store (sim-store (list (cons near #(1.0 0.05 0.0))
                                      (cons far  #(0.0 1.0 0.0)))))
         (target-view (sim-graph (list near far))))
    (is (= 1 (length (resembling subject source-store target-view target-store
                                 :cut 0.5)))
        "the orthogonal candidate is below the cut")
    (is (= 1 (length (resembling subject source-store target-view target-store
                                 :limit 1)))
        "the limit truncates what the cut admitted")))


;;; ------------------------------------------------------------------
;;; The reasons (DES-0041 D6)
;;; ------------------------------------------------------------------

(test a-pair-sharing-a-docstring-sentence-reports-the-shared-words
  ;; Four of REQ-0042's ten pairs share whole sentences, which is the cheap
  ;; signal the requirement is built on.
  (let* ((subject (sim-function "fnv-1a" 10
                              :documentation "Deterministic across images, which SXHASH is not."))
         (candidate (sim-function "content-fingerprint" 20
                                :documentation "Deterministic across images, which SXHASH is not.")))
    (let ((shared (getf (resemblance-reasons subject candidate) :shared-prose-words)))
      (is (member "deterministic" shared :test #'string=))
      (is (member "sxhash" shared :test #'string=))
      (is (not (member "fnv" shared :test #'string=))
          "a word only one side carries is not shared"))))

(test a-pair-sharing-nothing-reports-no-reason-and-is-still-returned
  ;; D7: the query points at a pair, it does not justify one. A candidate with
  ;; no shared word is the case the cosine found and the words cannot explain,
  ;; which is the whole reason this query exists.
  (let* ((subject (sim-function "fnv-1a" 10 :documentation "A hash."))
         (candidate (sim-function "content-fingerprint" 20 :documentation "Digests text."))
         (reasons (resemblance-reasons subject candidate)))
    (is (null (getf reasons :shared-name-words)))
    (is (null (getf reasons :shared-prose-words)))))

(test arity-is-reported-for-both-sides-and-never-filters
  ;; 415 of Synoptik's 933 functions that take arguments are arity 1, so agreeing
  ;; on arity separates almost nothing. It says whether a swap is even shaped
  ;; like a swap, and it is a field rather than a term in the ranking -- the
  ;; disagreeing pair below is still returned.
  (let* ((subject (sim-function "text-lines" 10 :arguments '("string")))
         (same    (sim-function "string-lines" 20 :arguments '("s")))
         (differs (sim-function "string-split" 30 :arguments '("s" "separator"))))
    (let ((r (resemblance-reasons subject same)))
      (is (eql 1 (getf r :subject-arity)))
      (is (eql 1 (getf r :arity)))
      (is-true (getf r :same-arity)))
    (let ((r (resemblance-reasons subject differs)))
      (is (eql 2 (getf r :arity)))
      (is (null (getf r :same-arity))))
    ;; And the disagreement does not remove it from an answer.
    (let* ((source-store (sim-store (list (cons subject #(1.0 0.0 0.0)))))
           (target-store (sim-store (list (cons differs #(0.9 0.1 0.0)))))
           (view (sim-graph (list differs))))
      (is (= 1 (length (resembling subject source-store view target-store)))))))

(test a-zero-argument-function-has-arity-zero-rather-than-no-arity
  ;; :ARGUMENTS NIL is what a zero-argument DEFUN writes, and 354 of Synoptik's
  ;; 1303 functions are in that state. Reading it as "unrecorded" would report
  ;; a gap where the index holds a fact.
  (is (eql 0 (entity-arity (sim-function "pidfile-path" 10))))
  (is (eql 2 (entity-arity (sim-function "dot-at" 20 :arguments '("flat" "query"))))))

(test arity-stops-at-the-first-lambda-list-marker
  ;; BUG-0044. :ARGUMENTS is documented as a parsed parameter list and holds the
  ;; whole lambda list flattened to strings, markers included. FIND-ENTITIES
  ;; stores six tokens and takes one argument, and reading LENGTH as the arity
  ;; -- which is what this function did when it was first written -- reports it
  ;; as six.
  (is (eql 1 (entity-arity
              (sim-function "find-entities" 10
                            :arguments '("view" "&key" "entity-type" "name-like"
                                         "property-filters" "include-stale")))))
  (is (eql 4 (entity-arity
              (sim-function "resembling" 20
                            :arguments '("subject" "source-store" "target-view"
                                         "target-store" "&key" "limit" "cut")))))
  (is (eql 1 (entity-arity
              (sim-function "summarize" 30 :arguments '("x" "&optional" "y"))))))

(test a-type-with-no-parameter-list-reports-no-arity
  ;; A :CLASS and a zero-argument DEFUN both read as NIL in the property table,
  ;; so the type decides. 0 for a class would claim it takes no arguments, which
  ;; is a statement about something a class does not have.
  (is (null (entity-arity
             (make-instance 'class-entity :name "protected-table"
                            :origin-file "src/graph/protected-table.lisp"
                            :properties (properties-table
                                         '(:file "src/graph/protected-table.lisp"
                                           :start-line 1 :end-line 9)))))))


;;; ------------------------------------------------------------------
;;; Name equality (DES-0041 D4)
;;; ------------------------------------------------------------------

(test two-names-are-equal-when-the-embedder-could-not-have-told-them-apart
  ;; The comparison runs through NAME-AS-WORDS because that is the text the
  ;; store embedded. If it ran over the raw name instead, these two would read
  ;; as different names while scoring 1.0000 against each other -- and a survey
  ;; would report a pair it believed it had filtered.
  (is-true (name-equal-p (sim-function "getTypeFromObj" 10)
                         (sim-function "get-type-from-obj" 20)))
  (is-true (name-equal-p (sim-function "fnv-1a" 10) (sim-function "fnv-1a" 20)))
  (is (null (name-equal-p (sim-function "fnv-1a" 10)
                          (sim-function "content-fingerprint" 20)))))
