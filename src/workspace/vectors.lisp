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

The same five tools/test/entity-dump.lisp dumps, and for its reason: a :FILE's name
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

(defparameter *vector-build-wait* 0
  "Seconds a query waits for a vector build before answering without it.

Zero, and the reason is that the two builds are not the same kind of absence.

An index still building cannot be answered from at all: an empty graph makes
`find\' report that nothing matches, which is indistinguishable from the
truthful version of itself, so REQUIRE-REPOSITORY refuses and says so. A vector
store still building is different. The answer without it is the answer Loom
gave for its whole existence before DEC-0006 -- correct, complete, and merely
without the semantic candidates it would have had a minute later. REQ-0048 R6
is precisely the promise that this answer is a good one.

So a query during an index build is refused and a query during a vector build
is answered. `status\' reports :EMBEDDING for the second, which is how a caller
who cares can tell that asking again shortly would do better.

This was 300 and did wait. What changed is a decision about the caller rather
than about the store: waiting a minute for a better answer is a trade a person
might make and cannot be asked to make by a tool that has not told them it is
happening, and an agent holding a tool call for that long has no way to know
anything is happening at all. A caller who would rather block binds this.")

(defun start-vector-build (repository &key (embedder (current-embedder))
                                          existing-only)
  "Build or update REPOSITORY's store on another thread. Returns the thread.

EXISTING-ONLY returns NIL without starting anything when there is no store yet.
That is what the watcher passes: a tree nobody has embedded must not acquire a
store because somebody saved a file in it, and building one is minutes of CPU
that nothing asked for. Building is `embed'; this is refreshing.

Update when there is a store and build when there is not, which is
UPDATE-VECTOR-STORE's own distinction: it returns NIL rather than inventing one,
so the fallback here is a full build and the incremental path costs nothing to
try.

A build already in flight is left alone rather than joined by a second one.
Two threads embedding the same repository would race on one file and the loser
would write a store whose header and data came from different passes."
  (with-repository-lock (repository)
    (let ((running (repository-vector-build repository)))
      (if (or (and running (bordeaux-threads:thread-alive-p running))
              (and existing-only
                   (not (loom-embed:vector-store-present-p
                         (repository-name repository)))))
          (and running (bordeaux-threads:thread-alive-p running) running)
          (setf (repository-vector-build repository)
                (bordeaux-threads:make-thread
                 (lambda ()
                   (handler-case
                       (let ((store (or (update-vector-store repository embedder)
                                        (build-vector-store repository embedder))))
                         (setf (repository-cached-vectors repository) store))
                     ;; REQ-0048 R6: an embedder that cannot answer is an
                     ;; embedder that is not there. The thread ends, the store
                     ;; stays whatever it was, and no query is told about it.
                     (loom-embed:embedder-unavailable (condition)
                       (note-error repository "vector build" condition))
                     (serious-condition (condition)
                       (note-error repository "vector build" condition))))
                 :name (format nil "loom-vectors-~a" (repository-name repository))))))))

(defun await-vector-build (repository &optional (seconds *vector-build-wait*))
  "Wait for a build in flight, up to SECONDS. True when there is none left."
  (let ((thread (repository-vector-build repository)))
    (or (null thread)
        (not (bordeaux-threads:thread-alive-p thread))
        (loop repeat (* 10 seconds)
              do (sleep 0.1)
              until (not (bordeaux-threads:thread-alive-p thread))
              finally (return (not (bordeaux-threads:thread-alive-p thread)))))))

(defun repository-vectors (repository)
  "REPOSITORY\'s vector store, or NIL when there is not one worth using.

Read from disk once and remembered, including the answer NIL: a repository with
no store must not re-probe the filesystem on every query, and a 5 MB read must
not happen per call.

REQ-0048 R6 falls out of the order of operations here. Loading a store is file
I/O and nothing else, so a machine with no store never reaches the network at
all -- the embedder is constructed, asked for its id, and never called. Only a
repository that has a store can cost a query anything."
  ;; A build in flight means no store yet, not a wait. See *VECTOR-BUILD-WAIT*.
  (unless (await-vector-build repository *vector-build-wait*)
    (return-from repository-vectors nil))
  (let ((cached (repository-cached-vectors repository)))
    (if (eq cached :unloaded)
        (setf (repository-cached-vectors repository)
              (loom-embed:load-vector-store (repository-name repository)
                                            (current-embedder)))
        cached)))

(defun forget-repository-vectors (repository)
  "Drop the cached store so the next query reads from disk again."
  (setf (repository-cached-vectors repository) :unloaded))

(defun vector-build-status (repository)
  "What EMBED would say about REPOSITORY, as a plist. Reaches no embedder."
  (let* ((store (let ((cached (repository-cached-vectors repository)))
                  (if (eq cached :unloaded) nil cached)))
         (thread (repository-vector-build repository)))
    (list :building (and thread (bordeaux-threads:thread-alive-p thread) t)
          :vectors (and store (loom-embed:vector-store-count store))
          :dimensions (and store (loom-embed:vector-store-dimensions store))
          :embedder (loom-embed:embedder-id (current-embedder))
          :definitions (length (vector-candidates (repository-graph repository)))
          :stale (vector-store-staleness repository (current-embedder)))))

(defun repository-state (repository)
  "Where REPOSITORY is in its boot sequence, as one keyword.

    :indexing   the tree is being read; nothing can be answered yet
    :embedding  the graph is built and answerable, the vector store is not
    :ready      both

A state rather than two booleans because the two builds are sequential and a
caller wants to know which one it is waiting behind. They mean different things
to a reader too: :INDEXING is a query that cannot be answered at all, and
:EMBEDDING is one that will be answered lexically, correctly, and without the
semantic candidates it would have had a minute later."
  (let ((index (repository-index-build repository))
        (vectors (repository-vector-build repository)))
    (cond ((and index (bordeaux-threads:thread-alive-p index)) :indexing)
          ((and vectors (bordeaux-threads:thread-alive-p vectors)) :embedding)
          (t :ready))))
