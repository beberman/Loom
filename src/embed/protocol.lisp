;;;; The embedder protocol: three generic functions and what they promise.
;;;;
;;;; DEC-0006 adopted dense retrieval behind an interface rather than against a
;;;; particular model, and DES-0040 D1 fixed the shape. The interface exists
;;;; mostly so that EMBEDDER-ID has somewhere to live: vectors from two
;;;; embedders are not comparable, a cosine between them is a number with no
;;;; property that marks it wrong, and no arithmetic anywhere reports it.

(in-package :loom-embed)

(define-condition embedder-unavailable (error)
  ((detail :initarg :detail :reader embedder-unavailable-detail :initform nil))
  (:report (lambda (condition stream)
             (format stream "The embedder could not be reached: ~a"
                     (or (embedder-unavailable-detail condition) "no detail"))))
  (:documentation
   "Signalled when an embedder cannot answer: nothing listening, a refused
connection, a malformed reply.

A condition rather than a NIL return, and an ERROR rather than a bare
CONDITION, because RULE-0004 is about exactly this: a guard written as
HANDLER-CASE over ERROR does not catch a condition defined as a direct subtype
of CONDITION, and the library that taught this tree that lesson is one Loom
already depends on.

Callers are expected to handle it rather than propagate it. REQ-0048 R6 makes
an unreachable embedder indistinguishable from a configured absence: the
lexical seeder answers alone and nothing is reported. That policy belongs to
the caller, so this layer signals and says nothing about what to do."))

(defgeneric embed-texts (embedder texts)
  (:documentation
   "The embedding of each string in TEXTS, in order, as a simple-vector of
vectors of SINGLE-FLOAT.

Order is part of the contract. Every caller pairs the result positionally with
what it sent -- the sidecar builder against the definitions it enumerated, the
seeder against the one query it asked about -- and an embedder that reordered
or dropped would corrupt the store rather than fail it.

Returns vectors already normalised to unit length, so a cosine is a dot
product. Normalising here rather than at each call site is a decision about
where the arithmetic lives: every consumer wants cosine, none wants magnitude,
and an unnormalised vector reaching a dot-product loop is a silent wrong
answer of the kind this protocol exists to prevent.

Signals EMBEDDER-UNAVAILABLE rather than returning NIL or a short vector."))

(defgeneric embedder-id (embedder)
  (:documentation
   "A string identifying what would produce these vectors, exactly.

Written into the sidecar beside the vectors and compared on every load. Two
stores whose ids differ hold vectors that cannot be compared, and this string
is the only place that fact is recoverable -- the numbers themselves are in the
same range and have no property that distinguishes them.

So it names everything that changes the vectors: the implementation, the model,
and the model's version where one is known. \"ollama:nomic-embed-text\" is such
a string. \"local\" is not."))

(defgeneric embedder-dimensions (embedder)
  (:documentation
   "How many components a vector from this embedder has, or NIL when unknown.

NIL is honest for an embedder that has not been asked yet: a hosted model's
width is documented, an ollama model's is whatever the pull produced, and
guessing it would put a number in the sidecar's header that nothing measured.
The store records the width it actually wrote and checks that instead, so this
is a convenience for callers sizing a buffer rather than a second source of
truth."))

;;; ------------------------------------------------------------------
;;; Shared mechanics
;;; ------------------------------------------------------------------

(defun normalise (vector)
  "VECTOR scaled to unit length, as a (simple-array single-float (*)).

A zero vector is returned as-is rather than divided by zero. An embedder that
returns one has failed in a way this layer cannot diagnose, and a vector of
NaNs would fail later, further away, in a cosine that quietly stopped ordering
anything."
  (let* ((n (length vector))
         (out (make-array n :element-type 'single-float))
         (sum 0.0d0))
    (dotimes (i n)
      (let ((x (float (elt vector i) 1.0)))
        (setf (aref out i) x)
        (incf sum (* (float x 1.0d0) (float x 1.0d0)))))
    (let ((norm (sqrt sum)))
      (when (plusp norm)
        (dotimes (i n)
          (setf (aref out i) (float (/ (aref out i) norm) 1.0))))
      out)))

;;; ------------------------------------------------------------------
;;; A stand-in with no dependencies
;;; ------------------------------------------------------------------

(defclass fixed-embedder ()
  ;; The protocol's two readers are DEFMETHODs below rather than :READER slot
  ;; options, which is how OLLAMA-EMBEDDER already reads and is what keeps
  ;; RULE-0006 quiet. A generated :READER for a name this file also declares
  ;; with DEFGENERIC derives one natural key twice, and the analyzer's
  ;; accessor carve-out exempts only the pair where *both* names were
  ;; generated (DES-0012). Adding a method to a generic function shadows
  ;; nothing in Common Lisp, so the finding would be false -- and a false
  ;; warning standing in `check' is how BUG-0009 started.
  ((id         :initarg :id         :initform "fixed:test")
   (dimensions :initarg :dimensions :initform 4)
   (table      :initarg :table      :reader fixed-embedder-table
               :initform (make-hash-table :test #'equal)))
  (:documentation
   "An embedder that answers from a table and never opens a socket.

Every test in this system and in the systems above it runs against one of
these. That is what lets REQ-0048 R6 -- Loom with no embedder behaves exactly
as Loom does today -- be tested rather than asserted: a suite that needed
ollama running could not distinguish `absent embedder handled correctly' from
`ollama happened to be up'.

A text the table does not hold embeds to a deterministic vector derived from
the string, so a fixture can supply the few vectors a test reasons about and
ignore the rest without either arm being special-cased."))

(defmethod embedder-id ((embedder fixed-embedder))
  (slot-value embedder 'id))

(defmethod embedder-dimensions ((embedder fixed-embedder))
  (slot-value embedder 'dimensions))

(defun make-fixed-embedder (&key (id "fixed:test") (dimensions 4) vectors)
  "A FIXED-EMBEDDER answering from VECTORS, an alist of text to vector."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (text . vector) in vectors
          do (setf (gethash text table) vector))
    (make-instance 'fixed-embedder :id id :dimensions dimensions :table table)))

(defun derived-vector (text dimensions)
  "A vector determined by TEXT alone, so an unseeded text still embeds.

Deterministic and deliberately crude: it is a fixture's floor, not a model.
Two different strings can collide and that costs a test nothing, because a
test reasoning about a particular similarity supplies the vector it means."
  (let ((out (make-array dimensions :element-type 'single-float
                                    :initial-element 0.0)))
    (loop for char across text
          for i from 0
          do (incf (aref out (mod i dimensions))
                   (float (1+ (mod (char-code char) 17)) 1.0)))
    ;; A text of no characters would otherwise normalise to zeros and sit at
    ;; cosine 0 from everything, which reads as a bug in whatever consumed it.
    (when (zerop (length text))
      (setf (aref out 0) 1.0))
    out))

(defmethod embed-texts ((embedder fixed-embedder) texts)
  (let ((table (fixed-embedder-table embedder))
        (dimensions (embedder-dimensions embedder)))
    (map 'simple-vector
         (lambda (text)
           (normalise (or (gethash text table)
                          (derived-vector text dimensions))))
         (coerce texts 'list))))
