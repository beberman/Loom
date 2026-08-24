;;;; The vector sidecar's file format: where it lives, how it is written, and
;;;; every reason to refuse one.
;;;;
;;;; DEC-0006 and DES-0040 D2. In loom-embed rather than loom-workspace because
;;;; both sides of the system need it and they sit on opposite sides of the
;;;; layering: loom-workspace builds a store because it owns the write path and
;;;; has the graph, and loom-knowledge reads one at query time because it owns
;;;; seeding. loom-workspace depends on loom-knowledge, so a loader living
;;;; there could not be called by the reader. The format is about vectors and
;;;; not about repositories, so the leaf is where it belongs.
;;;;
;;;; The refusal is the point of the file. Vectors from two embedders are not
;;;; comparable, a cosine between them is a number in the same range as a real
;;;; one with no property that marks it wrong, and no arithmetic anywhere
;;;; reports it. A store that cannot be shown to match the embedder in hand is
;;;; discarded rather than used, which is CON-0001 applied to a thing that
;;;; would otherwise fail silently forever.

(in-package :loom-embed)

(defparameter *vector-store-magic* 1280461382
  "First word of the .dat file, checked on load.

The vectors are written as the host's native (unsigned-byte 32), so a file
carried to a machine of the other byte order would read as noise rather than
fail. Nothing else in the format could detect that: every bit pattern is a
valid single-float, the count would still match, and the cosines would come
back in the ordinary range. This word is the one thing that cannot survive the
journey unchanged.")


(defun vector-store-directory ()
  "<loom>/.loom/vectors/, beside the context log and for the same two reasons.

In Loom's own tree rather than the searched one: writing into game-server or
front-end would put Loom's bookkeeping in somebody else's repository, and
tools/test/acceptance.py depends on those corpora holding still. Under a
dot-directory, where REPOSITORY-FILES skips it before any analyzer is
consulted, so the store cannot enter the index it serves."
  (merge-pathnames ".loom/vectors/"
                   ;; src/embed/ up two, the same arithmetic LOOM-ROOT does
                   ;; from src/workspace/. Restated rather than shared because
                   ;; loom-embed is a leaf and may not call upward for it.
                   (merge-pathnames "../../"
                                    (asdf:system-source-directory :loom-embed))))

(defun vector-store-paths (repository-name)
  "The header and data paths for REPOSITORY-NAME, as two values."
  (let ((directory (vector-store-directory)))
    (values (merge-pathnames (format nil "~a.json" repository-name) directory)
            (merge-pathnames (format nil "~a.dat" repository-name) directory))))


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
  ;; One digest per id, of the text that was embedded. What makes an update
  ;; incremental: an entity whose document is unchanged keeps its vector, and
  ;; the document is the name and the docstring, so editing a function's *body*
  ;; changes nothing here at all.
  (digests (make-array 0) :type simple-vector)
  (vectors (make-array 0 :element-type 'single-float)
   :type (simple-array single-float (*))))

(defun vector-store-entity-id (store index)
  "The entity id whose vector sits at INDEX."
  (svref (vector-store-ids store) index))


(defun vector-for (store id)
  "STORE's vector for entity ID as a fresh FLOAT-VECTOR, or NIL if it holds none.

The other direction of VECTOR-STORE-ENTITY-ID, and what makes a resemblance
query cost no embedding call: the subject of DES-0041's `similar' is a
definition Loom already indexed, so its vector was written here when the store
was built and is read rather than computed. NEAREST takes the result unchanged.

A copy, never a displaced array into VECTOR-STORE-VECTORS. DOT-AT walks that
array at safety 0 while it scans, so an alias handed to a caller turns one
caller's mutation into wrong cosines for every query afterwards -- no error, no
symptom, and nothing in the arithmetic that could report it. That is DEC-0006's
two-embedder cosine in a second place, and the copy is what keeps the store's
bytes reachable only from here.

NIL for an id the store does not hold, which happens whenever the index has
moved since the store was written. A caller reads that the way
SEMANTIC-CANDIDATES reads a stale id: something to pass over, not to raise."
  (let ((index (position id (vector-store-ids store) :test #'equal)))
    (when index
      (let* ((dimensions (vector-store-dimensions store))
             (vector (make-array dimensions :element-type 'single-float))
             (base (* index dimensions)))
        (replace vector (vector-store-vectors store)
                 :start2 base :end2 (+ base dimensions))
        vector))))


(defun document-digest (text)
  "A 32-bit FNV-1a hash of TEXT.

Written out rather than SXHASH because a store outlives the image that wrote
it, and SXHASH's value for a string is only promised to be consistent within
one implementation -- which is a promise about the wrong axis. FNV-1a is four
lines and is the same number on every run of every build.

A collision means a changed document keeps its old vector. Over a few thousand
documents against a 32-bit space that is not a risk worth a wider hash, and the
failure is one stale vector rather than a corrupt store."
  (let ((hash 2166136261))
    (declare (type (unsigned-byte 32) hash))
    (loop for char across text
          do (setf hash (logand #xFFFFFFFF
                                (* (logxor hash (logand (char-code char) #xFFFF))
                                   16777619))))
    hash))


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
         ("ids"         . ,(coerce (vector-store-ids store) 'list))
         ("digests"     . ,(coerce (vector-store-digests store) 'list)))
       out)
      (terpri out))
    store))


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
                 (ids (cdr (assoc :ids header)))
                 (digests (cdr (assoc :digests header))))
            (when (and (stringp stored-id)
                       (integerp dimensions) (plusp dimensions)
                       (integerp count)
                       (listp ids)
                       ;; The check DEC-0006 exists for. Anything else here is
                       ;; a corrupt file; this one is a *valid* file written by
                       ;; something else.
                       (string= stored-id (embedder-id embedder))
                       (= count (length ids))
                       ;; A store written before digests existed cannot be
                       ;; updated incrementally, and a store that loads but
                       ;; cannot be updated is worse than none: it would be
                       ;; queried forever against an index that had moved.
                       (listp digests)
                       (= count (length digests)))
              (let ((flat (read-vector-data data-path (* count dimensions))))
                (when flat
                  (make-vector-store :embedder-id stored-id
                                     :dimensions dimensions
                                     :count count
                                     :built-at (or built-at 0)
                                     :ids (coerce ids 'simple-vector)
                                     :digests (coerce digests 'simple-vector)
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

(defun vector-store-present-p (repository-name)
  "True when a store exists on disk for REPOSITORY-NAME.

PROBE-FILE and not LOAD-VECTOR-STORE. The watcher asks this on every pass that
changed something, and loading front-end's store to answer it would read ten
megabytes to decide whether to read ten megabytes."
  (multiple-value-bind (header-path data-path) (vector-store-paths repository-name)
    (and (probe-file header-path) (probe-file data-path) t)))
