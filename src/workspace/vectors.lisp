;;;; Building the vector sidecar: what gets embedded, and updating a store
;;;; without rebuilding it.
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

(defun embed-documents (embedder documents batch)
  "Embed DOCUMENTS, a list of strings, BATCH at a time. A list of vectors."
  (let ((out '()))
    (loop for rest on documents by (lambda (l) (nthcdr batch l))
          for chunk = (subseq rest 0 (min batch (length rest)))
          do (let ((vectors (loom-embed:embed-texts embedder chunk)))
               (loop for i from 0 below (length vectors)
                     do (push (aref vectors i) out))))
    (nreverse out)))

(defun assemble-vector-store (repository embedder rows dimensions)
  "Write a store from ROWS, each (id digest . vector), and return it."
  (let* ((count (length rows))
         (ids (make-array count))
         (digests (make-array count))
         (flat (make-array (* count dimensions) :element-type 'single-float
                                                :initial-element 0.0))
         (index 0))
    (dolist (row rows)
      (destructuring-bind (id digest . vector) row
        (unless (= (length vector) dimensions)
          (error 'loom-embed:embedder-unavailable
                 :detail (format nil "vector for ~a has ~d components, not ~d"
                                 id (length vector) dimensions)))
        (setf (svref ids index) id
              (svref digests index) digest)
        (replace flat vector :start1 (* index dimensions))
        (incf index)))
    (let ((store (loom-embed:make-vector-store
                  :embedder-id (loom-embed:embedder-id embedder)
                  :dimensions dimensions
                  :count count
                  :built-at (get-universal-time)
                  :ids ids
                  :digests digests
                  :vectors flat)))
      (loom-embed:write-vector-store store (repository-name repository))
      store)))

(defun build-vector-store (repository embedder &key (batch *vector-batch*))
  "Embed every definition in REPOSITORY and write the store. Returns it.

Signals LOOM-EMBED:EMBEDDER-UNAVAILABLE if the embedder cannot answer, and
writes nothing in that case -- a half-written store whose header claims a count
the data does not have is the one state the loader cannot tell from a good one.

Slow, and unavoidably so: the cost is the model's forward pass, measured at
about 3.7 documents a second on this machine and flat across every batch size
from 8 to 128 and across two, four and eight concurrent requests. 1655
definitions take 319 seconds. UPDATE-VECTOR-STORE is what makes that a
one-time cost rather than the price of every reindex."
  (let* ((entities (vector-candidates (repository-graph repository)))
         (documents (mapcar #'entity-document entities))
         (vectors (embed-documents embedder documents batch)))
    (assemble-vector-store
     repository embedder
     (loop for entity in entities
           for document in documents
           for vector in vectors
           collect (list* (princ-to-string (id entity))
                          (loom-embed:document-digest document)
                          vector))
     (if vectors (length (first vectors)) 0))))

(defun update-vector-store (repository embedder &key (batch *vector-batch*))
  "Bring REPOSITORY's store up to date, embedding only what changed.

Returns the store, or NIL when there is no store to update -- which is what
makes this opt-in. A repository nobody has built a store for stays without one,
and REQ-0048 R6's absent case is reached by doing nothing rather than by
deciding not to.

What is re-embedded is a document that changed, not an entity that did. The
document is the name as words and the docstring, so a body rewritten line by
line embeds to the same text and keeps its vector. Editing one docstring in a
tree of 1655 definitions costs one embedding call.

Signals LOOM-EMBED:EMBEDDER-UNAVAILABLE if there is work to do and the embedder
cannot answer. When nothing changed it does not reach the embedder at all,
which is the ordinary case on a reindex."
  (let ((existing (loom-embed:load-vector-store (repository-name repository) embedder)))
    (when existing
      (let ((known (make-hash-table :test #'equal))
            (dimensions (loom-embed:vector-store-dimensions existing)))
        (dotimes (i (loom-embed:vector-store-count existing))
          (setf (gethash (loom-embed:vector-store-entity-id existing i) known) i))
        (let* ((entities (vector-candidates (repository-graph repository)))
               (rows '())
               (fresh '()))
          ;; First pass: reuse what is unchanged, and collect what is not.
          (dolist (entity entities)
            (let* ((id (princ-to-string (id entity)))
                   (document (entity-document entity))
                   (digest (loom-embed:document-digest document))
                   (index (gethash id known)))
              (if (and index (eql digest (svref (loom-embed:vector-store-digests existing) index)))
                  (push (list* id digest
                               (subseq (loom-embed:vector-store-vectors existing)
                                       (* index dimensions)
                                       (* (1+ index) dimensions)))
                        rows)
                  (push (list id digest document) fresh))))
          (setf rows (nreverse rows) fresh (nreverse fresh))
          ;; Second pass: one embedding call per batch of what actually moved.
          (when fresh
            (let ((vectors (embed-documents embedder (mapcar #'third fresh) batch)))
              (loop for (id digest nil) in fresh
                    for vector in vectors
                    do (push (list* id digest vector) rows))))
          ;; An entity gone from the index takes its vector with it: it is
          ;; simply not in ENTITIES, so nothing collected it.
          (assemble-vector-store repository embedder rows dimensions))))))

(defun vector-store-staleness (repository embedder)
  "How many of REPOSITORY's documents an update would have to embed, or NIL
when there is no store. Reaches no embedder; for `status' and for tests."
  (let ((existing (loom-embed:load-vector-store (repository-name repository) embedder)))
    (when existing
      (let ((known (make-hash-table :test #'equal))
            (changed 0))
        (dotimes (i (loom-embed:vector-store-count existing))
          (setf (gethash (loom-embed:vector-store-entity-id existing i)
                         known)
                (svref (loom-embed:vector-store-digests existing) i)))
        (dolist (entity (vector-candidates (repository-graph repository)) changed)
          (let ((known-digest (gethash (princ-to-string (id entity)) known)))
            (unless (eql known-digest (loom-embed:document-digest (entity-document entity)))
              (incf changed))))))))


;;; ------------------------------------------------------------------
;;; What a query gets
;;; ------------------------------------------------------------------

(defparameter *embedder* nil
  "The embedder every repository uses, or NIL to build the default on demand.

A parameter so a test can bind one and so a deployment can install a different
implementation without touching a call site. DEC-0006 put the protocol in
loom-embed precisely so that this is the only line that names ollama.")

(defun current-embedder ()
  "The configured embedder, memoing, built once.

Constructing one opens no socket -- OLLAMA-EMBEDDER holds a host string and a
model name -- so this is free on a machine that has no ollama and never asks
for one."
  (or *embedder*
      (setf *embedder*
            (loom-embed:make-memoing-embedder (loom-embed:make-ollama-embedder)))))

(defun repository-vectors (repository)
  "REPOSITORY\'s vector store, or NIL when there is not one worth using.

Read from disk once and remembered, including the answer NIL: a repository with
no store must not re-probe the filesystem on every query, and a 5 MB read must
not happen per call.

REQ-0048 R6 falls out of the order of operations here. Loading a store is file
I/O and nothing else, so a machine with no store never reaches the network at
all -- the embedder is constructed, asked for its id, and never called. Only a
repository that has a store can cost a query anything."
  (let ((cached (repository-cached-vectors repository)))
    (if (eq cached :unloaded)
        (setf (repository-cached-vectors repository)
              (loom-embed:load-vector-store (repository-name repository)
                                            (current-embedder)))
        cached)))

(defun forget-repository-vectors (repository)
  "Drop the cached store so the next query reads from disk again."
  (setf (repository-cached-vectors repository) :unloaded))
