;;;
;;; Tests for concurrent access to one graph -- BUG-0004, DES-0003.
;;;
;;; The only tests in the suite that run several threads at once, and they
;;; exist because nothing else in it can see this defect: BUG-0004's "WHY IT
;;; HID" names the absence of a test that runs two threads at one graph as the
;;; third reason the race survived. The failure is a property of when two call
;;; paths run, not of which calls which, so no single-threaded test can reach
;;; it.
;;;
;;; Two mechanical traps govern how every test here is written.
;;;
;;; fiveam's IS records into special variables, which SBCL makes thread-local,
;;; so a check evaluated inside a spawned thread is lost rather than counted --
;;; a test whose assertions all live in workers passes unconditionally. Every
;;; assertion below therefore runs on the main thread after BT:JOIN-THREAD.
;;;
;;; SBCL signals "Unsafe concurrent operations on #<HASH-TABLE ...>" from
;;; inside whichever thread touched the table, and an unhandled condition in a
;;; worker is re-signaled by JOIN-THREAD in the joiner -- which would report
;;; this as a suite that fell over rather than as a test that failed. Each
;;; worker body therefore catches SERIOUS-CONDITION and *returns* what it
;;; caught, so the main thread can assert on it. SERIOUS-CONDITION and not
;;; ERROR, per RULE-0004 and for the same reason MONITOR-LOOP uses it.
;;;

(in-package :synoptik-graph-test)

(def-suite concurrency
  :in all-tests
  :description "Two threads against one graph (BUG-0004, DES-0003).")

(in-suite concurrency)

;;; ------------------------------------------------------------------
;;; Fixtures with derived ids
;;; ------------------------------------------------------------------
;;;
;;; A second node type rather than graph-manager.lisp's GRAPH-TEST-NODE, and
;;; the reason it was introduced is now history rather than a live hazard.
;;; GRAPH-TEST-NODE declares no natural key, so every instance takes a random
;;; uuid from FRESH-ID -- and FRESH-ID was not thread-safe. Measured directly:
;;; two threads generating 20,000 uuids each produced 26,039 distinct strings
;;; out of 40,000, where one thread generating 40,000 produced 40,000. Built on
;;; that fixture, the tests below lost a handful of entities per run to
;;; duplicate ids and read as a graph-locking failure, which they were not.
;;; That figure is kept because it is the record of why this file was reshaped.
;;;
;;; PLAN-0003 fixed FRESH-ID, closing BUG-0005: it now holds a lock of its own
;;; across RANDOM-UUID:MAKE-UUID, and the test below,
;;; TWO-THREADS-MINTING-KEY-LESS-ENTITIES-LOSE-NONE, is the check BUG-0005
;;; asked for. So GRAPH-TEST-NODE is safe to build concurrently, and this
;;; fixture is not a workaround for anything.
;;;
;;; It stays for the other half of the original reason, which never depended on
;;; the defect: keying on (:file :name) is the faithful shape, because every
;;; entity type an analyzer actually emits declares a natural key. The tests
;;; below are about the graph's locking, and they should exercise the id path
;;; the graph actually sees.

(defentity :graph-test-keyed-node
  :documentation "Fixture entity type whose id derives from its natural key."
  :properties ((:file string :required t))
  :natural-key (:file :name))

(defrelationship :graph-test-keyed-edge
  :from (:graph-test-keyed-node) :to (:graph-test-keyed-node)
  :documentation "Fixture relationship type between GRAPH-TEST-KEYED-NODEs.")

(defun make-keyed-node (name)
  (let ((e (make-instance 'graph-test-keyed-node-entity :name name)))
    (setp e :file "src/concurrency.lisp")
    e))

(defun make-keyed-edge (from-e to-e)
  (make-instance 'relationship :rel-type :graph-test-keyed-edge
                               :from-id (id from-e) :to-id (id to-e)))

;;; ------------------------------------------------------------------
;;; protected-table, single-threaded (DES-0003 R2)
;;; ------------------------------------------------------------------
;;;
;;; The type's whole claim is that its single-threaded contract matches a bare
;;; hash table's, because that is what lets twenty functions in
;;; graph-manager.lisp be rewritten onto it with no existing test changing.
;;; These are the tests of that claim.

(test pt-get-mirrors-gethash-including-its-second-value
  (let ((pt (make-protected-table)))
    (setf (pt-get pt "a") 1)
    (is (equal '(1 t) (multiple-value-list (pt-get pt "a"))))
    (is (equal '(nil nil) (multiple-value-list (pt-get pt "missing"))))
    ;; The default is the distinction a caller loses if it reads only the
    ;; primary value, and REMOVE-RELATIONSHIP's kind of code depends on it.
    (is (equal '(:none nil) (multiple-value-list (pt-get pt "missing" :none))))))

(test pt-rem-and-pt-clear-and-pt-count-mirror-their-counterparts
  (let ((pt (make-protected-table)))
    (setf (pt-get pt "a") 1
          (pt-get pt "b") 2)
    (is (= 2 (pt-count pt)))
    (is-true (pt-rem pt "a"))
    (is-false (pt-rem pt "a") "remhash reports whether it removed anything")
    (is (= 1 (pt-count pt)))
    (pt-clear pt)
    (is (zerop (pt-count pt)))))

(test pt-keys-and-pt-values-return-fresh-lists
  (let ((pt (make-protected-table)))
    (setf (pt-get pt "a") 1
          (pt-get pt "b") 2)
    (is (equal '("a" "b") (sort (pt-keys pt) #'string<)))
    (is (equal '(1 2) (sort (pt-values pt) #'<)))))

(test pt-delete-from-list-drops-the-key-when-the-list-empties
  (let ((pt (make-protected-table)))
    (pt-push pt "k" :a)
    (pt-push pt "k" :b)
    (is (equal '(:b :a) (pt-get pt "k")))
    (pt-delete-from-list pt "k" :b)
    (is (equal '(:a) (pt-get pt "k")))
    (pt-delete-from-list pt "k" :a)
    ;; Not merely NIL at the key: the key gone. A multimap that keeps keys
    ;; mapped to NIL grows without bound, and PT-KEYS would report files the
    ;; origin index no longer holds a fact from.
    (is (equal '(nil nil) (multiple-value-list (pt-get pt "k"))))))

(test pt-delete-from-list-honours-its-test
  ;; UNINDEX-ORIGIN removes uuid strings by EQUAL and gets a different answer
  ;; from the EQL default, so the argument has to actually reach REMOVE.
  (let ((pt (make-protected-table)))
    (pt-push pt "k" (copy-seq "id-1"))
    (pt-delete-from-list pt "k" "id-1")
    (is (equal '("id-1") (pt-get pt "k")) "EQL must not match a copied string")
    (pt-delete-from-list pt "k" "id-1" :test #'equal)
    (is (null (pt-get pt "k")))))

;;; The test that earns the design rather than describing it: two tables built
;;; on one lock, two threads pushing onto the same key of each. A naive
;;; implementation composing a locked read with a locked write passes every
;;; test above and fails this one, losing pushes wherever the two interleave.

(defparameter *pushes* 2000
  "Pushes per thread. Large enough that an interleaving is certain rather than
likely -- a lost-update test that happens not to interleave is a test that
asserts nothing.")

(defun stress-pusher (pt key n)
  (handler-case (dotimes (i n nil) (pt-push pt key i))
    (serious-condition (condition) condition)))

(test two-threads-pushing-onto-one-key-lose-nothing
  (let* ((lock (synoptik-graph::make-gate))
         (one (make-protected-table :lock lock))
         (two (make-protected-table :lock lock))
         (threads (list (bt:make-thread (lambda () (stress-pusher one "k" *pushes*)))
                        (bt:make-thread (lambda () (stress-pusher one "k" *pushes*)))
                        (bt:make-thread (lambda () (stress-pusher two "k" *pushes*)))
                        (bt:make-thread (lambda () (stress-pusher two "k" *pushes*)))))
         (caught (remove nil (mapcar #'bt:join-thread threads))))
    (is (null caught) "a pushing thread signaled ~a" (first caught))
    (is (= (* 2 *pushes*) (length (pt-get one "k"))))
    (is (= (* 2 *pushes*) (length (pt-get two "k")))
        "two tables, one lock: sharing it must not cost either of them a push")))

;;; ------------------------------------------------------------------
;;; The two-thread stress test (DES-0003 R7)
;;; ------------------------------------------------------------------

;;; Two writers and one reader, not one writer and one reader. That is a
;;; correction to the shape this test was first written in, and the reason is
;;; worth keeping: SBCL 2.1.11 detects concurrent *mutation* of a hash table,
;;; not a read overlapping a write. Measured directly on a bare EQUAL table --
;;; one writer against a thread iterating it 100,000 times never signals;
;;; two writers signal within the first few hundred puthashes, every run.
;;;
;;; The two-writer shape is also the more faithful model of BUG-0004, whose
;;; collision pair is the console thread inside REINDEX-REPOSITORY and the
;;; monitor thread inside POLL-ONCE -- both of which write, through INDEX-FILE
;;; and RESOLVE-AND-CHECK. The reader is kept because DES-0003 R7 claims a
;;; separate benefit for it (a console query racing a poll), and a claim with
;;; no thread exercising it is a claim nobody checks.

(defparameter *stress-writes* 1000
  "Node pairs each writer adds. Two writers make it 4000 entities and 2000
edges across five of the graph's seven tables.")

(defparameter *stress-reads* 2000
  "Iterations of the reader. Matched to the writers so that the reader is
still walking the tables while they are still growing.")

(defun stress-writer (graph tag n)
  "Add N node pairs, and an edge between each pair, named uniquely under TAG.
Returns the SERIOUS-CONDITION this thread caught, or NIL. See the file header
for why it returns rather than signals.

TAG keeps the two writers' natural keys disjoint: two entities sharing a key
would upsert onto one another for an entirely legitimate reason, and the count
assertions below could then not tell a lost write from a merged one."
  (handler-case
      (dotimes (i n nil)
        (let ((a (make-keyed-node (format nil "~a-a-~d" tag i)))
              (b (make-keyed-node (format nil "~a-b-~d" tag i))))
          (add-entity graph a)
          (add-entity graph b)
          (add-relationship graph (make-keyed-edge a b))))
    (serious-condition (condition) condition)))

(defun stress-reader (graph n)
  "Walk the graph N times the way a resolution pass and a knowledge query do.
Returns the SERIOUS-CONDITION this thread caught, or NIL."
  (handler-case
      (dotimes (i n nil)
        (let ((entities (all-entities graph)))
          (all-relationships graph)
          ;; One traversal per iteration rather than one per entity: the point
          ;; is to touch FROM-INDEX while a writer pushes onto it, not to make
          ;; the reader quadratic in the writers' progress.
          (when entities
            (relationships-from graph (id (first entities))))))
    (serious-condition (condition) condition)))

(test concurrent-writers-and-a-reader-do-not-corrupt-one-graph
  ;; BUG-0004's whole shape, reduced to the layer that owns the tables. This
  ;; fails against an unlocked graph and is what DES-0003's protected-table
  ;; has to make pass; it is deliberately below synoptik-workspace, so the
  ;; repository lock cannot be what fixed it.
  (let* ((graph (make-graph))
         (first-writer (bt:make-thread
                        (lambda () (stress-writer graph "one" *stress-writes*))
                        :name "stress-writer-one"))
         (second-writer (bt:make-thread
                         (lambda () (stress-writer graph "two" *stress-writes*))
                         :name "stress-writer-two"))
         (reader (bt:make-thread (lambda () (stress-reader graph *stress-reads*))
                                 :name "stress-reader"))
         (from-first (bt:join-thread first-writer))
         (from-second (bt:join-thread second-writer))
         (from-reader (bt:join-thread reader)))
    (is (null from-first) "the first writing thread signaled ~a" from-first)
    (is (null from-second) "the second writing thread signaled ~a" from-second)
    (is (null from-reader) "the reading thread signaled ~a" from-reader)
    ;; Not only that nothing was signaled: that everything the writers thought
    ;; they stored is actually there. Lost writes are the failure mode with no
    ;; condition attached, and BUG-0004's "WHY IT HID" is entirely about
    ;; damage nobody was told about.
    (is (= (* 4 *stress-writes*) (length (all-entities graph)))
        "entities: ~d stored of ~d written"
        (length (all-entities graph)) (* 4 *stress-writes*))
    (is (= (* 2 *stress-writes*) (length (all-relationships graph)))
        "relationships: ~d stored of ~d written"
        (length (all-relationships graph)) (* 2 *stress-writes*))))

;;; ------------------------------------------------------------------
;;; Key-less entities, minted concurrently (BUG-0005, PLAN-0003)
;;; ------------------------------------------------------------------
;;;
;;; The check BUG-0005 names in its own FIX section: "two threads minting
;;; key-less entities into one graph, asserting the count". GRAPH-TEST-NODE
;;; rather than GRAPH-TEST-KEYED-NODE, deliberately and uniquely in this file --
;;; it declares no natural key, so DERIVE-ID returns NIL and every id is a
;;; FRESH-ID. A duplicate id is a second ADD-ENTITY upserting onto the first,
;;; with no condition signaled and no error counted: the count is the only
;;; place the loss is visible.
;;;
;;; The weaker of PLAN-0003's two instruments, and known to be: graph work
;;; between the mints spaces them out, so the losses here are single digits in
;;; four thousand where the ontology test's tight loop loses thousands in forty.
;;; Both are required.

(defparameter *keyless-mints* 2000
  "Key-less entities each thread builds. Two threads make it 4000, matching the
stress test above, so the two read against the same scale.")

(defun keyless-minter (graph tag n)
  "Build and add N key-less GRAPH-TEST-NODEs named uniquely under TAG.
Returns the SERIOUS-CONDITION this thread caught, or NIL. See the file header
for why it returns rather than signals.

TAG makes the two threads' names disjoint, so a failure can be read for which
thread's ids survived -- there is no natural key here for a name to collide
through, and that is the point: a lost entity is a uuid collision and nothing
else."
  (handler-case
      (dotimes (i n nil)
        (add-entity graph (make-node (format nil "~a-keyless-~d" tag i))))
    (serious-condition (condition) condition)))

(test two-threads-minting-key-less-entities-lose-none
  (let* ((graph (make-graph))
         (one (bt:make-thread (lambda () (keyless-minter graph "one" *keyless-mints*))
                              :name "keyless-minter-one"))
         (two (bt:make-thread (lambda () (keyless-minter graph "two" *keyless-mints*))
                              :name "keyless-minter-two"))
         (from-one (bt:join-thread one))
         (from-two (bt:join-thread two)))
    (is (null from-one) "the first minting thread signaled ~a" from-one)
    (is (null from-two) "the second minting thread signaled ~a" from-two)
    (is (= (* 2 *keyless-mints*) (length (all-entities graph)))
        "entities: ~d stored of ~d minted"
        (length (all-entities graph)) (* 2 *keyless-mints*))))

;;; ------------------------------------------------------------------
;;; with-graph-lock (DES-0003 R4)
;;; ------------------------------------------------------------------

(defun call-with-deadline (seconds thunk)
  "Run THUNK in a thread. Returns :DONE, or :TIMEOUT if it outlived SECONDS.

A deadline rather than a plain BT:JOIN-THREAD because the failure this guards
against is a self-deadlock, and a self-deadlock joined without a deadline is a
suite that hangs forever. A hung run is worse than a red one: nobody can tell
it from a slow one, and CI reports neither."
  (let* ((done nil)
         (thread (bt:make-thread (lambda () (funcall thunk) (setf done t))
                                 :name "deadline")))
    (loop repeat (ceiling seconds 0.05)
          until done
          do (sleep 0.05))
    (cond (done (bt:join-thread thread) :done)
          (t (ignore-errors (bt:destroy-thread thread)) :timeout))))

(test with-graph-lock-is-reentrant
  ;; The literal case the lock being recursive is for, in Brian's own words:
  ;; a guarded operation calling another guarded operation. ADD-RELATIONSHIP
  ;; wraps its own body, so calling it from inside a critical section is a
  ;; second acquisition of a lock this thread already holds -- which against a
  ;; non-reentrant lock does not fail, it hangs.
  (let* ((graph (make-graph))
         (a (make-keyed-node "reentrant-a"))
         (b (make-keyed-node "reentrant-b"))
         (nested nil))
    (add-entity graph a)
    (add-entity graph b)
    (is (eq :done
            (call-with-deadline
             5 (lambda ()
                 (synoptik-graph::with-graph-lock (graph)
                   (add-relationship graph (make-keyed-edge a b))
                   (synoptik-graph::with-graph-lock (graph)
                     (setf nested (length (all-entities graph))))))))
        "a nested acquisition of the graph lock did not return within 5 s")
    (is (= 2 nested) "the nested body ran")
    (is (= 1 (length (all-relationships graph))))))

;;; The torn-view test. Honest about what it is worth: the window between
;;; ADD-RELATIONSHIP's store into RELATIONSHIPS and its two index pushes is a
;;; few instructions wide, so this may well pass before with-graph-lock exists
;;; as well as after. Its failure count against the unwrapped code is recorded
;;; in PLAN-0002's OUTCOME rather than assumed, and it is not claimed as
;;; CON-0003 evidence for anything it did not actually catch.

(defun torn-view-checker (graph done)
  "Watch for a relationship visible in ALL-RELATIONSHIPS but not yet in
FROM-INDEX. Returns that relationship's id, a caught SERIOUS-CONDITION, or NIL."
  (handler-case
      (loop until (funcall done)
            do (dolist (r (all-relationships graph))
                 (unless (member (id r)
                                 (relationships-from graph (from-id r) :include-stale t)
                                 :key #'id :test #'equal)
                   (return-from torn-view-checker (id r))))
            finally (return nil))
    (serious-condition (condition) condition)))

(defparameter *torn-view-edges* 400
  "Edges the writer adds. Small next to the stress test above because the
checker is quadratic in them -- it walks every relationship on every pass.")

(test a-relationship-is-never-visible-before-its-own-index-entry
  (let* ((graph (make-graph))
         ;; One node more than there are edges, and edge I joins node I to node
         ;; I+1: a relationship's natural key is its type and its two
         ;; endpoints, so a cycle over a handful of nodes would re-derive the
         ;; same ids and leave the graph the size it started.
         (nodes (coerce (loop for i to *torn-view-edges*
                              for n = (make-keyed-node (format nil "torn-~d" i))
                              do (add-entity graph n)
                              collect n)
                        'vector))
         (finished nil)
         (writer (bt:make-thread
                  (lambda ()
                    (prog1 (handler-case
                               (dotimes (i *torn-view-edges* nil)
                                 (add-relationship
                                  graph (make-keyed-edge (aref nodes i)
                                                         (aref nodes (1+ i)))))
                             (serious-condition (condition) condition))
                      (setf finished t)))
                  :name "torn-writer"))
         (checker (bt:make-thread (lambda () (torn-view-checker graph (lambda () finished)))
                                  :name "torn-checker"))
         (from-writer (bt:join-thread writer))
         (from-checker (bt:join-thread checker)))
    (is (null from-writer) "the writing thread signaled ~a" from-writer)
    (is (null from-checker)
        "a relationship was reachable through ALL-RELATIONSHIPS but not through
RELATIONSHIPS-FROM on its own from-id: ~a" from-checker)))


;;; ------------------------------------------------------------------
;;; The gate: many readers or one writer (BUG-0081)
;;; ------------------------------------------------------------------

(test readers-hold-the-gate-together
  ;; Each of the two readers waits, inside its read, for the other to be inside
  ;; its own. Behind one mutex that never happens and the wait times out.
  (let* ((gate (synoptik-graph::make-gate))
         (inside 0)
         (lock (bt:make-lock))
         (both (lambda ()
                 (synoptik-graph::with-gate-read (gate)
                   (bt:with-lock-held (lock) (incf inside))
                   (loop repeat 200
                         until (= inside 2)
                         do (sleep 0.01))
                   (= inside 2))))
         (threads (list (bt:make-thread both) (bt:make-thread both))))
    (is (every #'bt:join-thread threads)
        "two readers were not inside the gate at the same time")))

(test a-writer-waits-for-a-reader-and-a-reader-waits-for-a-writer
  (let* ((gate (synoptik-graph::make-gate))
         (events '())
         (lock (bt:make-lock))
         (note (lambda (event) (bt:with-lock-held (lock) (push event events)))))
    (let ((reader (bt:make-thread
                   (lambda ()
                     (synoptik-graph::with-gate-read (gate)
                       (funcall note :reader-in)
                       (sleep 0.4)
                       (funcall note :reader-out))))))
      (sleep 0.1)
      (let ((writer (bt:make-thread
                     (lambda ()
                       (synoptik-graph::with-gate-write (gate)
                         (funcall note :writer-in)
                         (sleep 0.3)
                         (funcall note :writer-out))))))
        (sleep 0.1)
        (let ((late (bt:make-thread
                     (lambda ()
                       (synoptik-graph::with-gate-read (gate)
                         (funcall note :late-reader-in))))))
          (mapc #'bt:join-thread (list reader writer late)))))
    (is (equal '(:reader-in :reader-out :writer-in :writer-out :late-reader-in)
               (reverse events))
        "the order of entry was ~s" (reverse events))))

(test a-thread-in-a-write-reads-and-writes-again-without-waiting
  (let ((gate (synoptik-graph::make-gate)))
    (is (eq :done
            (synoptik-graph::with-gate-write (gate)
              (synoptik-graph::with-gate-read (gate)
                (synoptik-graph::with-gate-write (gate)
                  :done)))))))

(test readers-and-a-writer-on-one-table-agree-on-what-they-see
  ;; The writer keeps two keys equal. A reader that saw them differ read the
  ;; table while the writer was in it.
  (let* ((pt (make-protected-table))
         (stop nil)
         (torn 0)
         (readers (loop repeat 6
                        collect (bt:make-thread
                                 (lambda ()
                                   (loop until stop
                                         do (let ((a (pt-get pt "a")) (b (pt-get pt "b")))
                                              (declare (ignorable a b))
                                              (synoptik-graph::with-gate-read ((synoptik-graph::protected-table-lock pt))
                                                (unless (eql (gethash "a" (synoptik-graph::protected-table-table pt))
                                                             (gethash "b" (synoptik-graph::protected-table-table pt)))
                                                  (incf torn))))))))))
    (dotimes (i 20000)
      (synoptik-graph::with-gate-write ((synoptik-graph::protected-table-lock pt))
        (setf (gethash "a" (synoptik-graph::protected-table-table pt)) i)
        (setf (gethash "b" (synoptik-graph::protected-table-table pt)) i)))
    (setf stop t)
    (mapc #'bt:join-thread readers)
    (is (zerop torn) "~d reads saw the two keys differ" torn)))
