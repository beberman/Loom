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
  `(unwind-protect (progn (delete-vector-store ,name) ,@body)
     (delete-vector-store ,name)))

(defun sample-store (&key (embedder-id "fixed:test") (dimensions 3)
                          (ids #("a" "b")) (vectors #(1.0 0.0 0.0  0.0 1.0 0.0)))
  (make-vector-store :embedder-id embedder-id
                     :dimensions dimensions
                     :count (length ids)
                     :built-at (get-universal-time)
                     :ids ids
                     :vectors (make-array (length vectors)
                                          :element-type 'single-float
                                          :initial-contents (coerce vectors 'list))))

(test a-store-reads-back-as-it-was-written
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (write-vector-store (sample-store) *test-repository-name*)
      (let ((loaded (load-vector-store *test-repository-name* embedder)))
        (is (not (null loaded)) "a store written by this embedder must load")
        (is (string= "fixed:test" (vector-store-embedder-id loaded)))
        (is (= 3 (vector-store-dimensions loaded)))
        (is (= 2 (vector-store-count loaded)))
        (is (string= "a" (vector-store-entity-id loaded 0)))
        (is (string= "b" (vector-store-entity-id loaded 1)))
        (is (= 6 (length (vector-store-vectors loaded))))
        (is (= 1.0 (aref (vector-store-vectors loaded) 0)))
        (is (= 1.0 (aref (vector-store-vectors loaded) 4)))))))

(test a-negative-component-survives-the-round-trip
  ;; WRITE-BYTE writes an unsigned word and SB-KERNEL:MAKE-SINGLE-FLOAT takes a
  ;; signed one, so without the conversion in READ-VECTOR-DATA every negative
  ;; component reads back as a huge positive number. That is not an error
  ;; anywhere: it is a cosine that quietly stops meaning anything, on a store
  ;; that loaded cleanly and reports the right count.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 2)))
      (write-vector-store (sample-store :dimensions 2 :ids #("x")
                                        :vectors #(-0.6 0.8))
                          *test-repository-name*)
      (let ((loaded (load-vector-store *test-repository-name* embedder)))
        (is (not (null loaded)))
        (is (< (abs (- -0.6 (aref (vector-store-vectors loaded) 0))) 1e-6)
            "a negative component must not come back positive")
        (is (< (abs (- 0.8 (aref (vector-store-vectors loaded) 1))) 1e-6))))))

(test a-store-another-embedder-wrote-is-refused
  ;; DEC-0006's invariant and the reason the whole file exists. A cosine
  ;; between vectors from two models is a number in the ordinary range with no
  ;; property that marks it wrong, so this check is the only thing standing
  ;; between a model swap and plausible nonsense forever.
  (with-clean-store ()
    (write-vector-store (sample-store :embedder-id "ollama:nomic-embed-text")
                        *test-repository-name*)
    (let ((other (loom-embed:make-fixed-embedder :id "ollama:bge-m3" :dimensions 3)))
      (is (null (load-vector-store *test-repository-name* other))
          "a store written by another embedder must not load"))
    (let ((same (loom-embed:make-fixed-embedder :id "ollama:nomic-embed-text"
                                                :dimensions 3)))
      (is (not (null (load-vector-store *test-repository-name* same)))
          "and the one that wrote it must, or every restart rebuilds"))))

(test a-truncated-data-file-is-refused
  ;; The count in the header and the length of the data are two statements
  ;; about one thing. A build interrupted between them leaves a store that
  ;; parses, reports a plausible count, and holds fewer vectors than it claims.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (write-vector-store (sample-store) *test-repository-name*)
      (is (not (null (load-vector-store *test-repository-name* embedder))))
      (multiple-value-bind (header-path data-path)
          (vector-store-paths *test-repository-name*)
        (declare (ignore header-path))
        ;; Drop the last word: six floats and a magic word become six words.
        (let ((words '()))
          (with-open-file (in data-path :element-type '(unsigned-byte 32))
            (loop for word = (read-byte in nil nil) while word do (push word words)))
          (with-open-file (out data-path :direction :output
                                         :element-type '(unsigned-byte 32)
                                         :if-exists :supersede)
            (dolist (word (rest (nreverse words))) (write-byte word out)))))
      (is (null (load-vector-store *test-repository-name* embedder))
          "a data file short of what the header promises must not load"))))

(test a-data-file-without-the-magic-word-is-refused
  ;; The vectors are the host's native word order, so a store carried to a
  ;; machine of the other byte order reads as noise rather than failing. Every
  ;; bit pattern is a valid single-float and the count still matches, so
  ;; nothing else in the format could catch it.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder :id "fixed:test" :dimensions 3)))
      (write-vector-store (sample-store) *test-repository-name*)
      (multiple-value-bind (header-path data-path)
          (vector-store-paths *test-repository-name*)
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
      (is (null (load-vector-store *test-repository-name* embedder))
          "a data file whose first word is not the magic must not load"))))

(test a-missing-store-is-nil-rather-than-an-error
  ;; REQ-0048 R6. No store is one of the three states that mean "the lexical
  ;; seeder answers alone", and a condition here would make the caller decide
  ;; between them.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder)))
      (is (null (load-vector-store *test-repository-name* embedder))))))

(test a-corrupt-header-is-nil-rather-than-an-error
  ;; RULE-0004's reflex applied here: a malformed sidecar must not take a query
  ;; down, and cl-json signals on text that is not JSON.
  (with-clean-store ()
    (let ((embedder (loom-embed:make-fixed-embedder)))
      (multiple-value-bind (header-path data-path)
          (vector-store-paths *test-repository-name*)
        (ensure-directories-exist header-path)
        (with-open-file (out header-path :direction :output :if-exists :supersede)
          (write-string "this is not json {{{" out))
        (with-open-file (out data-path :direction :output
                                       :element-type '(unsigned-byte 32)
                                       :if-exists :supersede)
          (write-byte 0 out)))
      (is (null (load-vector-store *test-repository-name* embedder))))))

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
