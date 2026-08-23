;;;; Tests for the vector sidecar.
;;;;
;;;; Every one runs against LOOM-EMBED:FIXED-EMBEDDER, so none of them needs
;;;; ollama installed or listening. That is deliberate and is what makes the
;;;; refusal tests meaningful: a suite that reached a real embedder could not
;;;; tell a store rejected for the right reason from one that was never built.

(in-package :loom-workspace-test)

(def-suite vectors :in all-tests)
(in-suite vectors)

(defparameter *test-repository-name* "loom-vector-store-test"
  "A name no watched repository has, because these tests write and delete
files under <loom>/.loom/vectors/ and must not touch a real store.")

(defmacro with-clean-store ((&optional (name '*test-repository-name*)) &body body)
  "Run BODY with no store for NAME, and leave none behind."
  `(unwind-protect (progn (loom-embed:delete-vector-store ,name) ,@body)
     (loom-embed:delete-vector-store ,name)))

(defun sample-store (&key (embedder-id "fixed:test") (dimensions 3)
                          (ids #("a" "b")) (digests #(1 2))
                          (vectors #(1.0 0.0 0.0  0.0 1.0 0.0)))
  (loom-embed:make-vector-store :embedder-id embedder-id
                     :dimensions dimensions
                     :count (length ids)
                     :built-at (get-universal-time)
                     :ids ids
                     :digests digests
                     :vectors (make-array (length vectors)
                                          :element-type 'single-float
                                          :initial-contents (coerce vectors 'list))))

(test a-store-reads-back-as-it-was-written
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (loom-embed:write-vector-store (sample-store) *test-repository-name*)
      (let ((loaded (loom-embed:load-vector-store *test-repository-name* embedder)))
        (is (not (null loaded)) "a store written by this embedder must load")
        (is (string= "fixed:test" (loom-embed:vector-store-embedder-id loaded)))
        (is (= 3 (loom-embed:vector-store-dimensions loaded)))
        (is (= 2 (loom-embed:vector-store-count loaded)))
        (is (string= "a" (loom-embed:vector-store-entity-id loaded 0)))
        (is (string= "b" (loom-embed:vector-store-entity-id loaded 1)))
        (is (= 6 (length (loom-embed:vector-store-vectors loaded))))
        (is (= 1.0 (aref (loom-embed:vector-store-vectors loaded) 0)))
        (is (= 1.0 (aref (loom-embed:vector-store-vectors loaded) 4)))))))

(test a-negative-component-survives-the-round-trip
  ;; WRITE-BYTE writes an unsigned word and SB-KERNEL:MAKE-SINGLE-FLOAT takes a
  ;; signed one, so without the conversion in READ-VECTOR-DATA every negative
  ;; component reads back as a huge positive number. That is not an error
  ;; anywhere: it is a cosine that quietly stops meaning anything, on a store
  ;; that loaded cleanly and reports the right count.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 2)))
      (loom-embed:write-vector-store (sample-store :dimensions 2 :ids #("x") :digests #(9)
                                        :vectors #(-0.6 0.8))
                          *test-repository-name*)
      (let ((loaded (loom-embed:load-vector-store *test-repository-name* embedder)))
        (is (not (null loaded)))
        (is (< (abs (- -0.6 (aref (loom-embed:vector-store-vectors loaded) 0))) 1e-6)
            "a negative component must not come back positive")
        (is (< (abs (- 0.8 (aref (loom-embed:vector-store-vectors loaded) 1))) 1e-6))))))

(test a-store-another-embedder-wrote-is-refused
  ;; DEC-0006's invariant and the reason the whole file exists. A cosine
  ;; between vectors from two models is a number in the ordinary range with no
  ;; property that marks it wrong, so this check is the only thing standing
  ;; between a model swap and plausible nonsense forever.
  (with-clean-store ()
    (loom-embed:write-vector-store (sample-store :embedder-id "ollama:nomic-embed-text")
                        *test-repository-name*)
    (let ((other (loom-embed:make-fixed-embedder :id "ollama:bge-m3" :dimensions 3)))
      (is (null (loom-embed:load-vector-store *test-repository-name* other))
          "a store written by another embedder must not load"))
    (let ((same (loom-embed:make-fixed-embedder :id "ollama:nomic-embed-text"
                                                :dimensions 3)))
      (is (not (null (loom-embed:load-vector-store *test-repository-name* same)))
          "and the one that wrote it must, or every restart rebuilds"))))

(test a-truncated-data-file-is-refused
  ;; The count in the header and the length of the data are two statements
  ;; about one thing. A build interrupted between them leaves a store that
  ;; parses, reports a plausible count, and holds fewer vectors than it claims.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (loom-embed:write-vector-store (sample-store) *test-repository-name*)
      (is (not (null (loom-embed:load-vector-store *test-repository-name* embedder))))
      (multiple-value-bind (header-path data-path)
          (loom-embed:vector-store-paths *test-repository-name*)
        (declare (ignore header-path))
        ;; Drop the last word: six floats and a magic word become six words.
        (let ((words '()))
          (with-open-file (in data-path :element-type '(unsigned-byte 32))
            (loop for word = (read-byte in nil nil) while word do (push word words)))
          (with-open-file (out data-path :direction :output
                                         :element-type '(unsigned-byte 32)
                                         :if-exists :supersede)
            (dolist (word (rest (nreverse words))) (write-byte word out)))))
      (is (null (loom-embed:load-vector-store *test-repository-name* embedder))
          "a data file short of what the header promises must not load"))))

(test a-data-file-without-the-magic-word-is-refused
  ;; The vectors are the host's native word order, so a store carried to a
  ;; machine of the other byte order reads as noise rather than failing. Every
  ;; bit pattern is a valid single-float and the count still matches, so
  ;; nothing else in the format could catch it.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (loom-embed:write-vector-store (sample-store) *test-repository-name*)
      (multiple-value-bind (header-path data-path)
          (loom-embed:vector-store-paths *test-repository-name*)
        (declare (ignore header-path))
        (let ((words '()))
          (with-open-file (in data-path :element-type '(unsigned-byte 32))
            (loop for word = (read-byte in nil nil) while word do (push word words)))
          (setf words (nreverse words))
          (setf (first words) 12345)
          (with-open-file (out data-path :direction :output
                                         :element-type '(unsigned-byte 32)
                                         :if-exists :supersede)
            (dolist (word words) (write-byte word out)))))
      (is (null (loom-embed:load-vector-store *test-repository-name* embedder))
          "a data file whose first word is not the magic must not load"))))

(test a-missing-store-is-nil-rather-than-an-error
  ;; REQ-0048 R6. No store is one of the three states that mean "the lexical
  ;; seeder answers alone", and a condition here would make the caller decide
  ;; between them.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder)))
      (is (null (loom-embed:load-vector-store *test-repository-name* embedder))))))

(test a-corrupt-header-is-nil-rather-than-an-error
  ;; RULE-0004's reflex applied here: a malformed sidecar must not take a query
  ;; down, and cl-json signals on text that is not JSON.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder)))
      (multiple-value-bind (header-path data-path)
          (loom-embed:vector-store-paths *test-repository-name*)
        (ensure-directories-exist header-path)
        (with-open-file (out header-path :direction :output :if-exists :supersede)
          (write-string "this is not json {{{" out))
        (with-open-file (out data-path :direction :output
                                       :element-type '(unsigned-byte 32)
                                       :if-exists :supersede)
          (write-byte 0 out)))
      (is (null (loom-embed:load-vector-store *test-repository-name* embedder))))))

;;; ------------------------------------------------------------------
;;; What gets embedded
;;; ------------------------------------------------------------------

(defun vec-entity (name &optional documentation)
  "One function entity, with DOCUMENTATION when given."
  (make-instance 'function-entity :name name :origin-file "src/thing.lisp"
                 :properties (properties-table
                              (append (list :file "src/thing.lisp"
                                            :start-line 1 :end-line 5
                                            :language :lisp)
                                      (when documentation
                                        (list :documentation documentation))))))

(test a-compound-name-is-split-into-words-before-embedding
  ;; DES-0040 D3. An embedder tokenizes English and GETTYPEFROMOBJ is not
  ;; English. This is the same split TASK-TOKENS makes on a query, for the same
  ;; reason, against a different consumer.
  (is (string= "get type from obj" (name-as-words "getTypeFromObj")))
  (is (string= "connection connect database" (name-as-words "connection-connect-database")))
  (is (string= "piece type editor state set value"
               (name-as-words "PieceTypeEditorState.setValue")))
  (is (string= "min scale meters" (name-as-words "*min-scale-meters*")))
  (is (string= "url" (name-as-words "URL"))
      "an all-capitals name is one word, not three letters"))

(test an-undocumented-definition-still-gets-a-document
  ;; 3861 of the tree's 5268 definitions carry no docstring. DES-0040 D3
  ;; embeds them on their name rather than skipping them: a name is a weaker
  ;; signal and not an absent one, and a store whose count disagreed with the
  ;; index is what the loader reads as corruption.
  (let ((bare (vec-entity "make-hex-cell"))
        (documented (vec-entity "make-hex-cell" "Build one empty cell.")))
    (is (string= "make hex cell" (entity-document bare)))
    (is (string= "make hex cell. Build one empty cell." (entity-document documented)))))

;;; ------------------------------------------------------------------
;;; Updating without rebuilding
;;; ------------------------------------------------------------------

(defun vec-repository (name &rest entities)
  "A repository named NAME whose graph holds ENTITIES."
  (let ((graph (make-graph)))
    (dolist (entity entities) (add-entity graph entity))
    (loom-workspace::make-repository :root #p"/tmp/vec/" :name name :graph graph)))

(defun store-vector-for (store id)
  "The vector STORE holds for ID, as a list, or NIL."
  (let ((dimensions (loom-embed:vector-store-dimensions store)))
    (dotimes (i (loom-embed:vector-store-count store))
      (when (string= id (loom-embed:vector-store-entity-id store i))
        (return (coerce (subseq (loom-embed:vector-store-vectors store)
                                (* i dimensions) (* (1+ i) dimensions))
                        'list))))))

(defclass counting-embedder (loom-embed:fixed-embedder)
  ((calls :initform 0 :accessor counting-embedder-calls)
   (texts :initform 0 :accessor counting-embedder-texts))
  (:documentation "A FIXED-EMBEDDER that records how much it was asked to do.

The point of an incremental update is the work it does *not* do, and a test
that only compared the resulting store could not tell a correct update from a
full rebuild that happened to produce the same vectors."))

(defmethod loom-embed:embed-texts ((embedder counting-embedder) texts)
  (incf (counting-embedder-calls embedder))
  (incf (counting-embedder-texts embedder) (length (coerce texts 'list)))
  (call-next-method))

(defun counting-embedder (&key (dimensions 4))
  (make-instance 'counting-embedder :id "fixed:test" :dimensions dimensions
                                    :table (make-hash-table :test #'equal)))

(test an-unchanged-document-is-not-embedded-again
  ;; The whole point. Building Loom's own store takes 319 seconds at about 3.7
  ;; documents a second, and that cost is the model's forward pass rather than
  ;; anything a batch size can move. A reindex that re-embedded everything
  ;; would make the file watcher unusable.
  (with-clean-store ()
    (let* ((embedder (counting-embedder))
           (repository (vec-repository *test-repository-name*
                                       (vec-entity "alpha" "The first thing.")
                                       (vec-entity "beta" "The second thing."))))
      (build-vector-store repository embedder)
      (let ((after-build (counting-embedder-texts embedder)))
        (is (= 2 after-build) "the build embeds both documents")
        (let ((store (update-vector-store repository embedder)))
          (is (not (null store)))
          (is (= 2 (loom-embed:vector-store-count store)) "both entities survive")
          (is (= after-build (counting-embedder-texts embedder))
              "an update with nothing changed must not reach the embedder"))))))

(test only-the-document-that-changed-is-embedded-again
  (with-clean-store ()
    (let* ((embedder (counting-embedder))
           (repository (vec-repository *test-repository-name*
                                       (vec-entity "alpha" "The first thing.")
                                       (vec-entity "beta" "The second thing."))))
      (build-vector-store repository embedder)
      (let ((baseline (counting-embedder-texts embedder))
            (before (store-vector-for (loom-embed:load-vector-store *test-repository-name* embedder)
                                      "function:src/thing.lisp:alpha")))
        ;; One docstring rewritten, the other untouched.
        (setf repository (vec-repository *test-repository-name*
                                         (vec-entity "alpha" "The first thing.")
                                         (vec-entity "beta" "Something else entirely.")))
        (let ((store (update-vector-store repository embedder)))
          (is (= (1+ baseline) (counting-embedder-texts embedder))
              "exactly one document is re-embedded, not both")
          (is (= 2 (loom-embed:vector-store-count store)))
          (is (equal before (store-vector-for store "function:src/thing.lisp:alpha"))
              "and the unchanged entity keeps the vector it had"))))))

(test a-changed-body-is-not-a-changed-document
  ;; What is embedded is the name and the docstring. A function rewritten line
  ;; by line embeds to the same text, so the commonest edit in a working tree
  ;; costs no embedding at all.
  (let ((before (vec-entity "alpha" "The first thing."))
        (after (vec-entity "alpha" "The first thing.")))
    (setf (gethash :end-line (properties after)) 400)
    (is (eql (loom-embed:document-digest (entity-document before))
             (loom-embed:document-digest (entity-document after))))))

(test an-entity-that-left-the-index-leaves-the-store
  (with-clean-store ()
    (let* ((embedder (counting-embedder))
           (repository (vec-repository *test-repository-name*
                                       (vec-entity "alpha" "The first thing.")
                                       (vec-entity "beta" "The second thing."))))
      (build-vector-store repository embedder)
      (let ((store (update-vector-store
                    (vec-repository *test-repository-name*
                                    (vec-entity "alpha" "The first thing."))
                    embedder)))
        (is (= 1 (loom-embed:vector-store-count store)))
        (is (string= "function:src/thing.lisp:alpha" (loom-embed:vector-store-entity-id store 0)))))))

(test updating-a-repository-with-no-store-does-nothing
  ;; Opt-in. A repository nobody built a store for stays without one, so
  ;; REQ-0048 R6's absent case is reached by doing nothing rather than by
  ;; deciding not to.
  (with-clean-store ()
    (let ((embedder (counting-embedder)))
      (is (null (update-vector-store
                 (vec-repository *test-repository-name*
                                 (vec-entity "alpha" "The first thing."))
                 embedder)))
      (is (= 0 (counting-embedder-texts embedder))
          "and it must not reach the embedder to find that out"))))

(test staleness-counts-what-an-update-would-embed
  (with-clean-store ()
    (let* ((embedder (counting-embedder))
           (repository (vec-repository *test-repository-name*
                                       (vec-entity "alpha" "The first thing.")
                                       (vec-entity "beta" "The second thing."))))
      (build-vector-store repository embedder)
      (is (= 0 (vector-store-staleness repository embedder)))
      (is (= 1 (vector-store-staleness
                (vec-repository *test-repository-name*
                                (vec-entity "alpha" "The first thing.")
                                (vec-entity "beta" "Changed."))
                embedder)))
      (let ((calls (counting-embedder-texts embedder)))
        (vector-store-staleness repository embedder)
        (is (= calls (counting-embedder-texts embedder))
            "and it answers without reaching the embedder")))))

(test a-store-written-before-digests-existed-is-refused
  ;; It would load and query fine and could never be updated, so it would be
  ;; answered against an index that had moved on, forever.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (loom-embed:write-vector-store (sample-store) *test-repository-name*)
      (multiple-value-bind (header-path data-path)
          (loom-embed:vector-store-paths *test-repository-name*)
        (declare (ignore data-path))
        (let ((header (with-open-file (in header-path) (json:decode-json in))))
          (with-open-file (out header-path :direction :output :if-exists :supersede)
            (json:encode-json (remove :digests header :key #'car) out))))
      (is (null (loom-embed:load-vector-store *test-repository-name* embedder))))))
