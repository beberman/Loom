;;;; Expanding a context bundle -- DES-0026 D6 and D8, PLAN-0032 S1.
;;;;
;;;; What this replaces was fourteen lines: NEIGHBORS on each seed, PUSHNEW the
;;;; results, done. Every edge cost the same, every neighbour sat at the same
;;;; distance, and nothing ordered them but whatever order the adjacency list
;;;; happened to yield.
;;;;
;;;; The finding that decided the shape is that a one-hop expansion cannot
;;;; satisfy REQ-0016 R6 at any budget. Measured on game-server, 2026-08-17:
;;;; `context data-handler' returns 6 of 10 expected entities, and the four it
;;;; misses -- NULL-HANDLER, TABLE-HANDLER, MODEL-HANDLER, GAME-HANDLER -- are
;;;; two or more :INHERITS hops from the seed. No amount of ranking reaches an
;;;; entity the expansion never visits, so this is a reachability defect that
;;;; had been read as a ranking one.
;;;;
;;;; So: a multi-source best-first walk over edges that cost different amounts,
;;;; bounded by a distance horizon rather than by a hop count. The point of a
;;;; cost horizon over a depth limit is that one number then serves two shapes
;;;; of query -- a hierarchy runs three or four hops deep inside the horizon
;;;; while a call fan reaches one, and the query does not choose which, the
;;;; edges available from its seeds do.

(in-package :loom-knowledge)

;;;; ==================================================================
;;;; What crossing an edge costs
;;;; ==================================================================

(defparameter *edge-costs*
  '((:inherits   1 1)
    (:implements 1 1)
    (:uses       2 2)
    (:serves     2 2)
    (:calls      3 4)
    (:contains   3 3)
    (:belongs-to 3 3)
    (:tests      5 5))
  "(rel-type outgoing-cost incoming-cost), lower being nearer. DES-0026 D6.

:INHERITS and :IMPLEMENTS are cheapest because R2 says so and because the
ontology agrees: both are declared by an author in a definition form, both carry
:TRANSITIVE-IMPACT T, and neither can be inferred. A class and its subclass are
the same subsystem in a way a caller and its callee are not.

:CALLS is the interesting row and the asymmetry carries the argument. Outgoing --
what this thing calls -- is its implementation: bounded by the body, and it
describes the entity. Incoming -- what calls this thing -- is its client set:
unbounded, and it describes them. That asymmetry is why REQ-0016 R7's
startup-sequence query works at all, since START-SERVER's callees are an
outgoing fan and READ-CONFIG, CONFIG-GET and INITIALIZE-GAME-API are the startup
sequence in order.

:USES rather than :IMPLEMENTS is what carries a CLOS protocol, which DES-0026
D1a had to correct after measuring: a method specialised on a class reaches it
by :USES, and :IMPLEMENTS targets an :INTERFACE. The table was right and the
acceptance clause that named :IMPLEMENTS was not.

A type absent from this table is uncrossable rather than free. That is the safe
default and it is why there is no fallback cost -- a relationship type added to
the ontology without being priced here loses reach, which is a recorded gap,
rather than gaining free reach, which would be a fabricated one. The document
edges are absent deliberately: DES-0020 gives documents their own three bands,
and a walk that followed :MENTIONS would spend its horizon in prose and arrive
at code those bands then have to subtract.")

(defparameter *context-expansion-horizon* 4
  "The furthest accumulated cost the walk will travel. DES-0026 D6.

Not a depth limit in disguise. At 4 an :INHERITS chain runs four deep and stays
inside; an outgoing :CALLS reaches depth 1 at cost 3 and a second call hop costs
6; an incoming :CALLS reaches depth 1 at cost 4 exactly and stops. So a
hierarchy goes deep and a call fan stays shallow, from one number, and the query
does not choose -- the edges available from its seeds do.

4 is the smallest value admitting an incoming call hop and three hierarchy hops,
which is the pair of behaviours R6 and R7 respectively need. Under CON-0006 it
bounds work rather than judging relevance: what it excludes was going to be an
index-tier line at best.")

(defparameter *container-types* '(:file :package :module :repository :workspace)
  "Types that may be reached and may not be expanded from. DES-0026 D8.

Without this the cost table is unusable at any price. :CONTAINS runs from a file
to every definition in it, so one seed reaching its own file at cost 3 would put
all forty of that file's definitions at cost 6 -- and worse, would make two
seeds in the same file mutually reachable through it, convergent under D7 for no
reason but co-location. The directory listing REQ-0016 R1 fought out of the seed
band would arrive in the neighbour band instead.

Reached-but-not-expanded keeps co-location as a signal without letting it become
a transit network: a seed's file still appears and still says where the seed
lives, for one line. The definitions behind it are not lost to the reader --
they are one `describe' away, and under DES-0026 D2 the file's own index-tier
line names it.")

(defun container-p (entity)
  (and (member (entity-type entity) *container-types*) t))

(defun edge-cost (rel-type direction &key wants-tests)
  "What crossing REL-TYPE in DIRECTION costs, or NIL when it may not be crossed.

WANTS-TESTS lowers :TESTS from 5 to 2. At the default horizon a cost of 5 is
uncrossable, which is the right answer for a task that did not ask about tests
and the wrong one for a task that did -- REQ-0016 R4's `unless the query asks
about tests' applied to the expansion rather than to the seeder."
  (let ((row (assoc rel-type *edge-costs*)))
    (when row
      (if (and wants-tests (eq :tests rel-type))
          2
          (if (eq :out direction) (second row) (third row))))))

;;;; ==================================================================
;;;; The walk
;;;; ==================================================================

(defstruct (reach (:conc-name reach-))
  "One entity the walk settled, and why it is in the bundle.

VIA and DIRECTION are the edge it arrived on and ORIGIN is the rank of the best
seed that reached it. All three exist so a reader can be told why a row is
there: DES-0026 D10, and the practical reason is that a walk whose output does
not explain itself cannot be checked by eye."
  (entity nil)
  (cost 0)
  (via nil)
  (direction nil)
  (origin 0))

(defun expand-from-seeds (view seeds &key (horizon *context-expansion-horizon*)
                                          wants-tests)
  "Every entity within HORIZON of SEEDS, as REACH records, nearest first.

Multi-source Dijkstra with a bucket queue. The queue is an array indexed by
cost rather than a heap because every edge cost is a small integer and the
horizon is one too, which makes push and pop constant time and the invariant
obvious: costs are popped in non-decreasing order, so the first time an entity
is settled it is settled at its cheapest.

The seeds are settled at cost 0 and excluded from the result. They are in the
bundle already under their own band, and leaving them settled is what stops the
walk offering one back as a neighbour of another.

Ordering is cost, then the rank of the best seed that reached it, then the type
tiers, then the name -- so a neighbour of the first seed precedes a neighbour of
the eighth, a definition precedes a container at equal distance, and the whole
answer is reproducible across two calls over one index."
  (let ((buckets (make-array (1+ horizon) :initial-element '()))
        (settled (make-hash-table :test #'equal))
        (out '()))
    (loop for seed in seeds
          for rank from 0
          do (push (make-reach :entity seed :cost 0 :origin rank) (aref buckets 0)))
    (loop for cost from 0 to horizon
          do (loop while (aref buckets cost)
                   for entry = (pop (aref buckets cost))
                   for entity = (reach-entity entry)
                   do (unless (gethash (id entity) settled)
                        (setf (gethash (id entity) settled) entry)
                        (unless (zerop (reach-cost entry))
                          (push entry out))
                        ;; D8: a container is an answer, never a route.
                        (unless (container-p entity)
                          (dolist (n (neighbors view (id entity)))
                            (let* ((other (neighbor-entity n))
                                   (rel (rel-type (neighbor-relationship n)))
                                   (step (edge-cost rel (neighbor-direction n)
                                                    :wants-tests wants-tests))
                                   (next (and step (+ cost step))))
                              (when (and next (<= next horizon)
                                         (not (stale-p other))
                                         (not (gethash (id other) settled)))
                                (push (make-reach :entity other :cost next
                                                  :via rel
                                                  :direction (neighbor-direction n)
                                                  :origin (reach-origin entry))
                                      (aref buckets next)))))))))
    (sort (nreverse out)
          (lambda (a b)
            (let ((ka (list (reach-cost a) (reach-origin a)
                            (seed-type-rank (reach-entity a))))
                  (kb (list (reach-cost b) (reach-origin b)
                            (seed-type-rank (reach-entity b)))))
              (cond ((not (equal ka kb))
                     (loop for x in ka for y in kb
                           unless (= x y) return (< x y)))
                    (t (string< (or (significant-name (reach-entity a)) "")
                                (or (significant-name (reach-entity b)) "")))))))))
