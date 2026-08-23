;;;; The vector sidecar: build it, write it, and refuse to read one that was
;;;; written by a different embedder.
;;;;
;;;; DEC-0006 and DES-0040 D2. The store is derived and disposable in exactly
;;;; the sense DEC-0001 gives the index -- files are truth, this is an index
;;;; over them, and it can be discarded and rebuilt at 6976 definitions in 622
;;;; seconds. It is never committed.
;;;;
;;;; The refusal is the point of the file. Vectors from two embedders are not
;;;; comparable, a cosine between them is a number in the same range as a real
;;;; one with no property that marks it wrong, and no arithmetic anywhere
;;;; reports it. A store that cannot be shown to match the embedder in hand is
;;;; discarded rather than used, which is CON-0001 applied to a thing that
;;;; would otherwise fail silently forever.

(in-package :loom-workspace)

(defparameter *vector-definition-types*
  '(:function :method :class :interface :variable)
  "The entity types worth a vector.

The same five tools/entity-dump.lisp dumps, and for its reason: a :FILE's name
is a path and a :TEST is not what a task asks for, so both would put a vector
in the store whose nearest neighbour nobody wants returned.")

(defparameter *vector-batch* 64
  "Texts per embedding call while building.

Measured on 2026-08-22: 6976 definitions at this size took 622 seconds, about
twelve a second. The number trades a round trip against how much work one
failure discards, and neither side of that is sharp enough to tune.")

(defparameter *vector-store-magic* 1280461382
  "First word of the .dat file, checked on load.

The vectors are written as the host's native (unsigned-byte 32), so a file
carried to a machine of the other byte order would read as noise rather than
fail. Nothing else in the format could detect that: every bit pattern is a
valid single-float, the count would still match, and the cosines would come
back in the ordinary range. This word is the one thing that cannot survive the
journey unchanged.")

;;; ------------------------------------------------------------------
;;; Where it lives
;;; ------------------------------------------------------------------

(defun vector-store-directory ()
  "<loom>/.loom/vectors/, beside the context log and for the same two reasons.

In Loom's own tree rather than the searched one: writing into game-server or
front-end would put Loom's bookkeeping in somebody else's repository, and
tools/acceptance.py depends on those corpora holding still. Under a
dot-directory, where REPOSITORY-FILES skips it before any analyzer is
consulted, so the store cannot enter the index it serves."
  (merge-pathnames ".loom/vectors/" (loom-root)))

(defun vector-store-paths (repository-name)
  "The header and data paths for REPOSITORY-NAME, as two values."
  (let ((directory (vector-store-directory)))
    (values (merge-pathnames (format nil "~a.json" repository-name) directory)
            (merge-pathnames (format nil "~a.dat" repository-name) directory))))

;;; ------------------------------------------------------------------
;;; What is in memory
;;; ------------------------------------------------------------------

(defstruct (vector-store (:conc-name vector-store-))
  "Vectors for one repository, with the identity of what produced them.

VECTORS is one flat array of COUNT * DIMENSIONS single-floats rather than a
vector of vectors. The scan reads it end to end once per query -- 5268 by 768
is about four million multiply-adds -- and a flat array is one allocation, one
cache-friendly walk, and no pointer chase per candidate."
  (embedder-id "" :type string)
  (dimensions 0 :type fixnum)
  (count 0 :type fixnum)
  (built-at 0)
  (ids (make-array 0) :type simple-vector)
  (vectors (make-array 0 :element-type 'single-float)
   :type (simple-array single-float (*))))

(defun vector-store-entity-id (store index)
  "The entity id whose vector sits at INDEX."
  (svref (vector-store-ids store) index))

;;; ------------------------------------------------------------------
;;; What gets embedded
;;; ------------------------------------------------------------------

(defun name-as-words (name)
  "NAME split on separators and at a lower-to-upper boundary, space-joined.

DES-0040 D3. An embedder tokenizes English and GETTYPEFROMOBJ is not English;
split, it is three words the model has seen a great many times. The same
reasoning TASK-TOKENS applies to a compound before matching it, for the same
reason, against a different consumer."
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

(defun entity-document (entity)
  "The text embedded for ENTITY: its name as words, then its documentation.

An entity with no documentation embeds on its name alone. DES-0040 D3 decided
that rather than skipping it: 3861 of the tree's 5268 definitions carry no
docstring, their name is a weaker signal and not an absent one, and a store
whose count disagreed with the index would read as corruption to the check
below."
  (let ((words (name-as-words (or (and (slot-boundp entity 'name)
                                       (princ-to-string (name entity)))
                                  "")))
        (documentation (or (getp entity :documentation) "")))
    (if (plusp (length documentation))
        (format nil "~a. ~a" words documentation)
        words)))

(defun vector-candidates (graph)
  "Every entity in GRAPH worth a vector, in a stable order.

Sorted by id so two builds over one index write the same file. An order that
depended on hash iteration would make every rebuild a different file for the
same tree, which costs nothing functionally and makes any comparison of two
stores impossible."
  (let ((entities '()))
    (dolist (type *vector-definition-types*)
      (dolist (entity (entities-of-type graph type))
        (when (and (slot-boundp entity 'name)
                   (plusp (length (princ-to-string (name entity)))))
          (push entity entities))))
    (sort entities #'string< :key (lambda (e) (princ-to-string (id e))))))

;;; ------------------------------------------------------------------
;;; Building
;;; ------------------------------------------------------------------

(defun build-vector-store (repository embedder &key (batch *vector-batch*))
  "Embed REPOSITORY's definitions and write the store. Returns it.

Signals LOOM-EMBED:EMBEDDER-UNAVAILABLE if the embedder cannot answer, and
writes nothing in that case -- a half-written store whose header claims a count
the data does not have is the one state the loader cannot tell from a good
one."
  (let* ((entities (vector-candidates (repository-graph repository)))
         (count (length entities))
         (ids (make-array count))
         (dimensions nil)
         (flat nil)
         (index 0))
    (loop for rest on entities by (lambda (l) (nthcdr batch l))
          for chunk = (subseq rest 0 (min batch (length rest)))
          do (let ((vectors (loom-embed:embed-texts
                             embedder (mapcar #'entity-document chunk))))
               (loop for entity in chunk
                     for i from 0
                     for v = (aref vectors i)
                     do (when (null dimensions)
                          (setf dimensions (length v)
                                flat (make-array (* count dimensions)
                                                 :element-type 'single-float
                                                 :initial-element 0.0)))
                        (unless (= (length v) dimensions)
                          (error 'loom-embed:embedder-unavailable
                                 :detail (format nil "vector ~d has ~d components, not ~d"
                                                 index (length v) dimensions)))
                        (setf (svref ids index) (princ-to-string (id entity)))
                        (replace flat v :start1 (* index dimensions))
                        (incf index))))
    (let ((store (make-vector-store
                  :embedder-id (loom-embed:embedder-id embedder)
                  :dimensions (or dimensions 0)
                  :count count
                  :built-at (get-universal-time)
                  :ids ids
                  :vectors (or flat (make-array 0 :element-type 'single-float)))))
      (write-vector-store store (repository-name repository))
      store)))

;;; ------------------------------------------------------------------
;;; Writing
;;; ------------------------------------------------------------------

(defun write-vector-store (store repository-name)
  "Write STORE's two files. The data first, so a reader never sees a header
promising data that is not there yet."
  (multiple-value-bind (header-path data-path) (vector-store-paths repository-name)
    (ensure-directories-exist data-path)
    (with-open-file (out data-path :direction :output
                                   :element-type '(unsigned-byte 32)
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
      (write-byte *vector-store-magic* out)
      (let ((vectors (vector-store-vectors store)))
        (dotimes (i (length vectors))
          ;; LOGAND because SINGLE-FLOAT-BITS returns a *signed* word and the
          ;; stream takes an unsigned one, so every negative component would
          ;; otherwise be a type error on write. READ-VECTOR-DATA undoes it.
          ;; The pair has to move together: half of it turns every negative
          ;; component into a huge positive one, which no count and no checksum
          ;; would catch.
          (write-byte (logand (sb-kernel:single-float-bits (aref vectors i))
                              #xFFFFFFFF)
                      out))))
    (with-open-file (out header-path :direction :output
                                     :external-format :utf-8
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
      (json:encode-json
       `(("embedder-id" . ,(vector-store-embedder-id store))
         ("dimensions"  . ,(vector-store-dimensions store))
         ("count"       . ,(vector-store-count store))
         ("built-at"    . ,(vector-store-built-at store))
         ("ids"         . ,(coerce (vector-store-ids store) 'list)))
       out)
      (terpri out))
    store))

;;; ------------------------------------------------------------------
;;; Loading, which is mostly refusing
;;; ------------------------------------------------------------------

(defun load-vector-store (repository-name embedder)
  "The store for REPOSITORY-NAME, or NIL when there is not one worth using.

NIL rather than a condition, and NIL for every reason: no files, a header that
will not parse, an embedder-id that is not this embedder's, a dimension count
that disagrees, a data file of the wrong length, a magic word that is not the
magic word. REQ-0048 R6 gives them all one meaning -- the lexical seeder
answers alone -- so distinguishing them here would only invite a caller to
treat one of them as an error.

Every refusal is a store that would otherwise return plausible neighbours for
every query forever."
  (multiple-value-bind (header-path data-path) (vector-store-paths repository-name)
    (handler-case
        (when (and (probe-file header-path) (probe-file data-path))
          (let* ((header (with-open-file (in header-path :external-format :utf-8)
                           (json:decode-json in)))
                 (stored-id (cdr (assoc :embedder-id header)))
                 (dimensions (cdr (assoc :dimensions header)))
                 (count (cdr (assoc :count header)))
                 (built-at (cdr (assoc :built-at header)))
                 (ids (cdr (assoc :ids header))))
            (when (and (stringp stored-id)
                       (integerp dimensions) (plusp dimensions)
                       (integerp count)
                       (listp ids)
                       ;; The check DEC-0006 exists for. Anything else here is
                       ;; a corrupt file; this one is a *valid* file written by
                       ;; something else.
                       (string= stored-id (loom-embed:embedder-id embedder))
                       (= count (length ids)))
              (let ((flat (read-vector-data data-path (* count dimensions))))
                (when flat
                  (make-vector-store :embedder-id stored-id
                                     :dimensions dimensions
                                     :count count
                                     :built-at (or built-at 0)
                                     :ids (coerce ids 'simple-vector)
                                     :vectors flat))))))
      ;; SERIOUS-CONDITION, not ERROR: cl-yaml's conditions are not ERROR
      ;; subtypes and RULE-0004 is about exactly this reflex. A malformed
      ;; sidecar must not take a query down.
      (serious-condition () nil))))

(defun read-vector-data (path expected)
  "EXPECTED single-floats from PATH, or NIL if the file does not hold exactly
that many after its magic word."
  (with-open-file (in path :element-type '(unsigned-byte 32)
                           :if-does-not-exist nil)
    (when in
      (and (= (file-length in) (1+ expected))
           (= (read-byte in nil -1) *vector-store-magic*)
           (let ((flat (make-array expected :element-type 'single-float)))
             (dotimes (i expected flat)
               (setf (aref flat i)
                     (sb-kernel:make-single-float
                      ;; MAKE-SINGLE-FLOAT takes a signed 32-bit word and
                      ;; WRITE-BYTE wrote an unsigned one, so the top bit comes
                      ;; back as a large positive number rather than as a sign.
                      ;; Without this every negative component of every vector
                      ;; reads as a huge one, which is not an error anywhere --
                      ;; it is a cosine that quietly stops meaning anything.
                      (let ((word (read-byte in)))
                        (if (>= word 2147483648) (- word 4294967296) word))))))))))

(defun delete-vector-store (repository-name)
  "Remove REPOSITORY-NAME's store. Returns true when there was one."
  (multiple-value-bind (header-path data-path) (vector-store-paths repository-name)
    (let ((existed (or (probe-file header-path) (probe-file data-path))))
      (ignore-errors (delete-file header-path))
      (ignore-errors (delete-file data-path))
      (and existed t))))
