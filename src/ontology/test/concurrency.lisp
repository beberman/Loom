;;;
;;; Tests for concurrent id minting -- BUG-0005, PLAN-0003.
;;;
;;; The first threaded test in synoptik-ontology/test, and the tight instrument for
;;; BUG-0005: FRESH-ID and nothing else. No graph, no transaction, no analyzer,
;;; so nothing but FRESH-ID can be what makes it pass.
;;;
;;; Two mechanical traps govern how every test here is written. They are stated
;;; in full rather than cross-referenced to src/graph/test/concurrency.lisp,
;;; because a reader of this file has no other place in this system to learn
;;; them.
;;;
;;; fiveam's IS records into special variables, which SBCL makes thread-local,
;;; so a check evaluated inside a spawned thread is lost rather than counted --
;;; a test whose assertions all live in workers passes unconditionally. Every
;;; assertion below therefore runs on the main thread after BT:JOIN-THREAD.
;;;
;;; An unhandled condition in a worker is re-signaled by JOIN-THREAD in the
;;; joiner, which would report a surprise as a suite that fell over rather than
;;; as a test that failed. Each worker body therefore catches SERIOUS-CONDITION
;;; and *returns* what it caught, so the main thread can assert on it.
;;; SERIOUS-CONDITION and not ERROR, per RULE-0004.
;;;

(in-package :root-ontology-test)

(def-suite concurrency
  :in all-tests
  :description "Two threads minting ids at once (BUG-0005, PLAN-0003).")

(in-suite concurrency)

(defparameter *ids-per-thread* 20000
  "Ids each thread mints. Two threads at this count lost roughly 6,000 of
40,000 against the unguarded FRESH-ID, which is a margin no interleaving can
turn into a pass by luck.")

(defun mint-ids (n)
  "Mint N ids, returning the list of them, or the SERIOUS-CONDITION this thread
caught. See the file header for why it returns rather than signals."
  (handler-case (loop repeat n collect (fresh-id))
    (serious-condition (condition) condition)))

(defun count-distinct (strings)
  "How many of STRINGS are distinct. A hash table rather than
REMOVE-DUPLICATES, which is quadratic and would take longer over 40,000 ids
than the minting it is checking."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (s strings (hash-table-count seen))
      (setf (gethash s seen) t))))

(test two-threads-minting-ids-produce-no-duplicates
  ;; BUG-0005 reduced to the unit that carries the defect: FRESH-ID reaches
  ;; RANDOM-UUID:MAKE-UUID, which with no generator supplied draws from
  ;; CL:*RANDOM-STATE* -- one global object per image that SBCL threads inherit
  ;; by value and mutate without atomicity.
  (let* ((one (bt:make-thread (lambda () (mint-ids *ids-per-thread*))
                              :name "mint-one"))
         (two (bt:make-thread (lambda () (mint-ids *ids-per-thread*))
                              :name "mint-two"))
         (from-one (bt:join-thread one))
         (from-two (bt:join-thread two)))
    (is (listp from-one) "the first minting thread signaled ~a" from-one)
    (is (listp from-two) "the second minting thread signaled ~a" from-two)
    (let* ((all (append from-one from-two))
           (distinct (count-distinct all)))
      (is (= (* 2 *ids-per-thread*) (length all)))
      ;; The whole assertion. A duplicate here is an entity silently
      ;; overwriting another one in the graph's entity table.
      (is (= (* 2 *ids-per-thread*) distinct)
          "~d distinct ids of ~d minted" distinct (length all)))))
