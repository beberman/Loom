;;;
;;; DES-0006 R3, verified under the caller shape that only now exists.
;;;
;;; This lives here and not at the end of PLAN-0005 because loom-rest is the
;;; first thing in the tree that can produce two simultaneous callers. Before
;;; it, at most two threads could contend for one repository's analysis lock --
;;; the console thread and that repository's monitor -- because console.lisp's
;;; read loop dispatches one line at a time and cannot issue a second reindex
;;; while the first is running. N Hunchentoot worker threads remove that
;;; structural serialization, which is the whole of what R3 asks about.
;;;
;;; Modelled directly on a-reindex-and-a-poll-do-not-corrupt-the-index
;;; (src/workspace/test/workspace.lisp:343-420), reusing its instrument rather
;;; than inventing one. Two traps, both mechanical and both copied from that
;;; test's own comments. fiveam's IS records into thread-local specials, so
;;; every assertion below runs on the main thread after every join -- a test
;;; whose checks live in workers passes unconditionally. And
;;; REINDEX-REPOSITORY clears the recorded error list as its third act, so a
;;; check made only after joining sees an empty list however bad the run was:
;;; the errors have to be sampled between iterations.
;;;
;;; The requests go over TCP. A direct call to INVOKE-OPERATION does not run in
;;; a Hunchentoot worker thread and therefore does not test the thing R3 is
;;; about.
;;;

(in-package :loom-rest-test)

(def-suite concurrency
  :in all-tests
  :description "Concurrent HTTP callers against one repository, and against the registry.")

(in-suite concurrency)

(defparameter *stress-iterations* 20
  "Requests each client thread issues.

Smaller than src/workspace/test/workspace.lisp's 200 because each iteration
here is a whole HTTP round trip and a full rebuild rather than a direct call,
and PLAN-0005 asks that this be kept in the same order of magnitude as that
test rather than scaled up until it feels convincing.")

(defparameter *registry-iterations* 10
  "Watch/unwatch cycles each thread performs against its own repository.")

(defparameter *registry-threads* 6)

(defparameter *lock-hold-seconds* 0.5
  "How long THE-REGISTRY-ENTRIES-SERIALIZE-ON-THE-REGISTRY-LOCK holds the lock
from outside. Two orders of magnitude above a watch of a one-file repository,
which is what makes the assertion below discriminating rather than a timing
guess.")

(defvar *worst-write-latency* nil
  "The slowest write-tier request seen by the last run, in seconds.

DES-0006 declines to estimate request latency and says a future document
should measure it once there is a listener. This is the first opportunity, and
one number written down is worth more than the paragraph explaining why nobody
has one.")

;;; ------------------------------------------------------------------
;;; A single repository under concurrent read and write
;;; ------------------------------------------------------------------

(defun stress-http (repository iterations thunk)
  "Call THUNK ITERATIONS times, sampling REPOSITORY's recorded errors after each.
Returns (condition status-codes error-texts).

The sampling is what makes this an instrument rather than a formality, for
STRESS-CALL's reason: a collision INDEX-FILE recorded during one iteration is
erased by the next REINDEX-REPOSITORY, so a list read after the joins says
nothing. Reading it from this thread is safe in the one way that matters --
NOTE-ERROR conses a fresh head and never mutates a cons this loop holds."
  (let ((texts '())
        (statuses '()))
    (list (handler-case
              (dotimes (i iterations nil)
                (push (funcall thunk) statuses)
                (dolist (entry (repository-errors repository))
                  (push (getf entry :message) texts)))
            ;; SERIOUS-CONDITION, not ERROR: a condition escaping a worker
            ;; would be re-signalled by JOIN-THREAD on the main thread and
            ;; reported as a suite that fell over rather than a test that
            ;; failed.
            (serious-condition (condition) condition))
          statuses
          texts)))

(defun timed-status (thunk)
  "Call THUNK, returning its status and recording the elapsed time if it is the
worst seen."
  (let* ((start (get-internal-real-time))
         (status (funcall thunk))
         (elapsed (/ (- (get-internal-real-time) start)
                     internal-time-units-per-second)))
    (when (or (null *worst-write-latency*) (> elapsed *worst-write-latency*))
      (setf *worst-write-latency* elapsed))
    status))

(defun counts-of (repository)
  "The three numbers BUG-0004 saw drift: entities, relationships, tested units."
  (let ((status (repository-status repository)))
    (list (getf status :entities)
          (getf status :relationships)
          (getf status :tested-units))))

(test concurrent-rest-callers-do-not-corrupt-one-repository
  ;; DES-0006 R3 exactly as stated, and it passes with no new locking code,
  ;; which is the claim: both locks were already written to make no assumption
  ;; narrower than "some thread holds it", and a Hunchentoot worker satisfies
  ;; a recursive lock's reentrancy test identically to the console thread.
  (with-operations-fixture (repository)
    ;; With the monitor *running*, so the poll thread is a third contender
    ;; rather than a thing the fixture switched off.
    (start-monitor repository)
    (with-test-server ()
      (setf *worst-write-latency* nil)
      (let* ((name (repository-name repository))
             (writer
               (bt:make-thread
                (lambda ()
                  (stress-http repository *stress-iterations*
                               (lambda ()
                                 (timed-status
                                  (lambda ()
                                    (nth-value 1
                                               (http-call (route :reindex)
                                                          :method :post
                                                          :content-type "application/json"
                                                          :content (format nil "{\"repository\":\"~a\"}" name))))))))
                :name "stress-rest-write"))
             (reader
               (bt:make-thread
                (lambda ()
                  (stress-http repository *stress-iterations*
                               (lambda ()
                                 (nth-value 1
                                            (http-call (route :describe)
                                                       :parameters (list (cons "repository" name)
                                                                         (cons "term" "alpha")))))))
                :name "stress-rest-describe"))
             (walker
               (bt:make-thread
                (lambda ()
                  (stress-http repository *stress-iterations*
                               (lambda ()
                                 (nth-value 1
                                            (http-call (route :impact)
                                                       :parameters (list (cons "repository" name)
                                                                         (cons "term" "alpha")
                                                                         (cons "depth" "3")))))))
                :name "stress-rest-impact"))
             (seeker
               (bt:make-thread
                (lambda ()
                  (stress-http repository *stress-iterations*
                               (lambda ()
                                 (nth-value 1
                                            (http-call (route :context)
                                                       :parameters (list (cons "repository" name)
                                                                         (cons "task" "alpha arithmetic")))))))
                :name "stress-rest-context"))
             (results (mapcar #'bt:join-thread (list writer reader walker seeker)))
             (after-threads (counts-of repository)))
        (stop-monitor repository)
        (dolist (result results)
          (is (null (first result))
              "a client thread signalled ~a" (first result))
          ;; 200 or 404, and the 404 is not a defect: DES-0004 R5 keeps
          ;; loom-knowledge's read path lock-free, so a read arriving between
          ;; REINDEX-REPOSITORY's graph swap and the moment the file is
          ;; re-analyzed sees an index that does not contain the term yet and
          ;; says so. That is the accepted cost of an unlocked read, not a torn
          ;; view -- the counts below are what would catch a torn view. A 500
          ;; is the thing this asserts against, per DES-0006 R3.
          (let ((unexpected (find-if-not (lambda (status) (member status '(200 404)))
                                         (second result))))
            (is (null unexpected) "a request answered ~a" unexpected)))
        (let ((collisions (remove-if-not
                           (lambda (text) (search "Unsafe concurrent operations" text))
                           (loop for result in results append (third result)))))
          (is (null collisions)
              "a collision was caught and recorded rather than signalled: ~a"
              (first collisions)))
        ;; The direct check that no batch was lost to a torn view, not merely
        ;; that nothing crashed. Against a rebuild taken with every thread
        ;; joined, which is the only state that can be trusted as a reference.
        (reindex-repository repository :quiet t)
        (is (equal (counts-of repository) after-threads)
            "the state the threads left differs from a quiet rebuild: ~a against ~a"
            after-threads (counts-of repository))
        (format t "~&;; worst write-tier request under load: ~,3f s~%"
                *worst-write-latency*)))))

;;; ------------------------------------------------------------------
;;; The registry itself (PLAN-0005 FINDING 2)
;;; ------------------------------------------------------------------

(defun make-tiny-repository (label)
  "A one-file repository in a fresh temp directory, not watched."
  (let* ((root (merge-pathnames (format nil "loom-reg-~a-~36r/" label (random (expt 2 40)))
                                (uiop:temporary-directory)))
         (path (merge-pathnames "src/only.lisp" root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun only (x) x)" out))
    root))

(defun repository-label (root)
  (car (last (pathname-directory root))))

(defun watch-over-http (root)
  (nth-value 1 (http-call (route :watch)
                          :method :post
                          :content-type "application/json"
                          :content (format nil "{\"path\":\"~a\"}" (namestring root)))))

(defun unwatch-over-http (name)
  (nth-value 1 (http-call (route :unwatch)
                          :method :post
                          :content-type "application/json"
                          :content (format nil "{\"repository\":\"~a\"}" name))))

(defun registry-cycle (root)
  "Watch and unwatch ROOT repeatedly, then leave it watched.
Returns (condition lost), where LOST names the iterations after which the
repository this thread had just watched was not in the registry."
  (let ((label (repository-label root))
        (lost '()))
    (list (handler-case
              (progn
                (dotimes (i *registry-iterations*)
                  (watch-over-http root)
                  (unless (find-repository label) (push i lost))
                  (unwatch-over-http label))
                (watch-over-http root)
                (unless (find-repository label) (push :final lost))
                nil)
            ;; SERIOUS-CONDITION for MONITOR-LOOP's reason: a condition
            ;; escaping here would be re-signalled by JOIN-THREAD and reported
            ;; as a suite that fell over rather than a test that failed.
            (serious-condition (condition) condition))
          (nreverse lost))))

(defun watched-names ()
  (mapcar (lambda (status) (getf status :name))
          (getf (invoke-operation (find-operation :status) '(:read) '()) :repositories)))

(test concurrent-watch-and-unwatch-do-not-lose-a-registration
  ;; PLAN-0005 FINDING 2, and a different question from the one above.
  ;; *REPOSITORIES* (src/workspace/workspace.lisp:52) is a bare DEFVAR that
  ;; line 424 PUSHes and line 446 SETFs, and WITH-REPOSITORY-LOCK cannot cover
  ;; either -- it takes its lock out of the struct being added or removed.
  ;;
  ;; What this test is, and what it is not, measured rather than assumed. It
  ;; asserts the property FINDING 2 is about: every repository watched and not
  ;; unwatched appears exactly once. It is *not* the CON-0003 witness for the
  ;; lock, because it was run with *WORKSPACE-REGISTRY-LOCK* removed from both
  ;; entries and passed -- 6 threads and 20 cycles each, twice. The reason is
  ;; arithmetic rather than luck: the unguarded region is a read, a CONS and a
  ;; write, some tens of nanoseconds, inside a cycle that spends ~200 ms
  ;; indexing and stopping a monitor, so two threads overlapping inside it is a
  ;; one-in-ten-million event per cycle. PLAN-0005 says to raise the iteration
  ;; count rather than weaken the assertion; the honest finding is that the
  ;; count needed is millions, which is not a test. The assertion stays, and
  ;; the discriminating evidence for the lock is the test below it, which fails
  ;; the moment the lock is removed.
  (let ((roots (loop for i below *registry-threads*
                     collect (make-tiny-repository i))))
    (unwind-protect
         (with-test-server ()
           (let* ((threads
                    (loop for root in roots
                          collect (let ((root root))
                                    (bt:make-thread
                                     (lambda () (registry-cycle root))
                                     :name "stress-registry"))))
                  (results (mapcar #'bt:join-thread threads))
                  (names (watched-names)))
             (dolist (result results)
               (is (null (first result))
                   "a registry thread signalled ~a" (first result))
               ;; The mid-run sample, and the reason this test can detect
               ;; anything at all. A lost PUSH is repaired by the next
               ;; iteration's watch, so an end-state check alone can only catch
               ;; a race in each thread's *last* call -- a window narrow enough
               ;; that the unlocked version passed. Checking after every watch
               ;; widens the observable window to the whole run.
               (is (null (second result))
                   "a registration vanished mid-run: ~a" (second result)))
             (dolist (root roots)
               (let ((label (repository-label root)))
                 (is (= 1 (count label names :test #'string=))
                     "~a appears ~d times in the registry, not once"
                     label (count label names :test #'string=))))))
      (dolist (root roots)
        (ignore-errors (unwatch-repository (repository-label root)))
        (ignore-errors (uiop:delete-directory-tree root :validate t))))))

(test the-registry-entries-serialize-on-the-registry-lock
  ;; The CON-0003 witness the test above cannot be. It asserts the mechanism
  ;; rather than the symptom: if :watch holds *WORKSPACE-REGISTRY-LOCK* across
  ;; its whole body, then a thread holding that lock from outside must delay
  ;; the watch by however long it holds it. Remove the lock from the entry and
  ;; this fails immediately and by two orders of magnitude, which is the
  ;; evidence PLAN-0005 asks for and the reason the lock is there.
  ;;
  ;; It also states the acquisition order as a fact: this test takes the
  ;; registry lock and never a repository's analysis lock, and the entry takes
  ;; the registry lock before the analysis lock WATCH-REPOSITORY acquires
  ;; underneath it. A lock added above DES-0004's is only safe if it never
  ;; inverts, and this is the shape that keeps that true.
  (let ((root (make-tiny-repository "serialize")))
    (unwind-protect
         (with-test-server ()
           (let ((holder (bt:make-thread
                          (lambda ()
                            (bt:with-recursive-lock-held (*workspace-registry-lock*)
                              (sleep *lock-hold-seconds*)))
                          :name "registry-lock-holder")))
             ;; Long enough for the holder to have acquired it. Counted out of
             ;; the measurement below, so the assertion is about the wait the
             ;; watch actually did.
             (sleep 0.05)
             (let* ((start (get-internal-real-time))
                    (status (watch-over-http root))
                    (elapsed (/ (- (get-internal-real-time) start)
                                internal-time-units-per-second)))
               (bt:join-thread holder)
               (is (= 200 status))
               (is (> elapsed (* 0.5 *lock-hold-seconds*))
                   "the watch entry did not wait on the registry lock: ~,3f s"
                   elapsed))))
      (ignore-errors (unwatch-repository (repository-label root)))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))
