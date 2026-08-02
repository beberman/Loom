;;;
;;; Tests for src/workspace/workspace.lisp -- the indexing pipeline.
;;;
;;; Level 1 in SS14.1's ordering: this runs the real analyzers over a real
;;; directory, so it is the first test that can tell you the pieces fit
;;; together. The fixture is a temporary repository rather than Loom itself,
;;; because these tests need to edit and delete files.
;;;

(in-package :loom-workspace-test)

(def-suite workspace
  :in all-tests
  :description "Indexing, resolution ordering, and change detection.")

(in-suite workspace)

(defparameter *fixture-root* nil)

(defun write-file (relative contents)
  (let ((path (merge-pathnames relative *fixture-root*)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    path))

(defun make-fixture-repository ()
  "A small two-file repository with a docs/ tree, in a fresh temp directory."
  (setf *fixture-root*
        (merge-pathnames (format nil "loom-fixture-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *fixture-root*)
  (write-file "src/alpha.lisp"
              "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
  (write-file "src/beta.lisp"
              "(defun beta (x) (alpha x))
")
  (write-file "docs/design/DEC-0001.yaml"
              "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
affects: [alpha]
rationale: |
  Keeping alpha-twice free of side effects makes it testable.
")
  (write-file "docs/rules/RULE-0001.yaml"
              "id: RULE-0001
type: rule
title: Nothing in src may call into docs
status: active
severity: error
check:
  kind: no-edge
  from-system: src
  to-system: docs
  rel-types: [calls]
")
  (watch-repository *fixture-root* :monitor nil :quiet t))

(defun cleanup-fixture ()
  (when *fixture-root*
    (ignore-errors (uiop:delete-directory-tree *fixture-root* :validate t))
    (setf *fixture-root* nil)))

(defmacro with-workspace-fixture ((repository) &body body)
  `(let ((,repository (make-fixture-repository)))
     (unwind-protect (progn ,@body)
       (unwatch-repository (repository-name ,repository))
       (cleanup-fixture))))

;;; ------------------------------------------------------------------
;;; Indexing (SS3.4)
;;; ------------------------------------------------------------------

(test watching-a-repository-indexes-source-and-documents-together
  (with-workspace-fixture (repository)
    (let ((g (repository-graph repository)))
      (is (= 3 (length (entities-of-type g :function))))
      (is (= 1 (length (entities-of-type g :decision))))
      (is (= 1 (length (entities-of-type g :rule)))
          "one watcher, one pipeline, both kinds of file"))))

(test the-pipeline-resolves-cross-file-calls
  ;; The reason the ordering in RESOLVE-AND-CHECK exists: beta calls alpha,
  ;; and no file-scoped analyzer can see that.
  (with-workspace-fixture (repository)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=))
           (callers (mapcar (lambda (r) (name (get-entity g (from-id r))))
                            (relationships-to g (id alpha) :rel-type :calls))))
      (is (member "beta" callers :test #'string=)
          "resolved across a file boundary")
      (is (member "alpha-twice" callers :test #'string=)
          "and within one"))))

(test the-pipeline-resolves-document-links
  (with-workspace-fixture (repository)
    (let* ((g (repository-graph repository))
           (decision (first (entities-of-type g :decision)))
           (targets (mapcar (lambda (r) (name (get-entity g (to-id r))))
                            (relationships-from g (id decision) :rel-type :decides))))
      (is (equal '("alpha") targets)))))

(test the-pipeline-runs-the-rule-checks
  (with-workspace-fixture (repository)
    (let ((g (repository-graph repository)))
      (is (null (entities-of-type g :rule-violation))
          "the fixture is clean, and a clean tree must report nothing"))))

(test status-reports-what-a-developer-needs-to-see
  (with-workspace-fixture (repository)
    (let ((status (repository-status repository)))
      (is (= 4 (getf status :files)))
      (is (plusp (getf status :entities)))
      (is (= 2 (getf status :documents)))
      (is (zerop (getf status :unresolved-references)))
      (is (zerop (getf status :errors)))
      ;; ARCH-0002 R10. Asserted present *and* zero, not merely zero: the
      ;; fixture has no definer calls, so a key that is absent and a count that
      ;; is genuinely nought both read as NIL through GETF, and only the
      ;; membership check tells them apart. Zero is also what these read at
      ;; every step before the generated definitions land, which is what makes
      ;; them the acceptance instrument on Loom's own tree.
      (dolist (key '(:test-entities :tested-units :unhandled-definer-macros))
        (is (member key status) "~s is missing from status" key)
        (is (eql 0 (getf status key))
            "~s must be nought for a fixture with no definer calls" key)))))

(test re-watching-a-registered-repository-starts-watching-it-again
  ;; The console's lifecycle in a live image: MAIN stops the monitors on its
  ;; way out but leaves *REPOSITORIES* populated, so the next (main) re-watches
  ;; a repository that is already registered and not being watched. That branch
  ;; used to reindex without starting a monitor, which reported `watcher:
  ;; stopped' for a repository the developer had just asked to watch.
  (with-workspace-fixture (repository)
    (start-monitor repository)
    (is-true (monitor-running-p repository))
    (stop-monitor repository)                    ; what MAIN does on exit
    (is-false (monitor-running-p repository))
    (let ((again (watch-repository *fixture-root* :quiet t)))
      (is (eq repository again) "the same repository, not a second copy")
      (is-true (monitor-running-p again)
               "and watching it means watching it")
      (stop-monitor again))))

(test pause-keeps-the-index-and-unwatch-does-not
  ;; DEC-0004: two named states and three commands between them. The reason
  ;; pause exists at all is that this assertion has to hold -- if pausing cost
  ;; the index there would be no difference from unwatch and no reason for it.
  (with-workspace-fixture (repository)
    (start-monitor repository)
    (is (eq :watching (getf (repository-status repository) :monitor)))
    (let ((entities (length (all-entities (repository-graph repository)))))
      (pause-repository (repository-name repository))
      (is (eq :paused (getf (repository-status repository) :monitor)))
      (is (= entities (length (all-entities (repository-graph repository))))
          "paused keeps every fact it had")
      (is (find repository (all-repositories))
          "and stays registered, so status still reports it")
      ;; watch is the resume command; there is deliberately no second name.
      (watch-repository *fixture-root* :quiet t)
      (is (eq :watching (getf (repository-status repository) :monitor)))
      (stop-monitor repository))
    (unwatch-repository (repository-name repository))
    (is (null (find repository (all-repositories)))
        "unwatch is the one that discards")))

;;; ------------------------------------------------------------------
;;; Change detection (SS8.3)
;;; ------------------------------------------------------------------

(test a-changed-file-is-reanalyzed
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
(defun alpha-thrice (x) (alpha (alpha-twice x)))
")
    (poll-once repository :quiet t)
    (is (= 4 (length (entities-of-type (repository-graph repository) :function))))))

(test a-deleted-definition-leaves-the-index
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp" "(defun alpha (x) (+ x 1))
")
    (poll-once repository :quiet t)
    (let ((names (mapcar #'name (entities-of-type (repository-graph repository)
                                                  :function))))
      (is (not (member "alpha-twice" names :test #'string=))
          "retract-file plus fresh asserts, driven by the monitor"))))

(test a-deleted-file-leaves-the-index
  (with-workspace-fixture (repository)
    (delete-file (merge-pathnames "src/beta.lisp" *fixture-root*))
    (poll-once repository :quiet t)
    (let ((g (repository-graph repository)))
      (is (null (find "beta" (entities-of-type g :function)
                      :key #'name :test #'string=)))
      (is (not (member "src/beta.lisp" (origin-files g) :test #'string=))))))

(test cross-file-edges-survive-a-reanalysis
  ;; The TODO that RETRACT-FILE-OP left open: retracting a file drops the
  ;; inbound cross-file edges, and only the pipeline's ordering puts them back.
  ;; This is the test that says the ordering is right.
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 2))
(defun alpha-twice (x) (alpha (alpha x)))
")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=)))
      (is (member "beta" (mapcar (lambda (r) (name (get-entity g (from-id r))))
                                 (relationships-to g (id alpha) :rel-type :calls))
                  :test #'string=)
          "beta -> alpha was destroyed by the retract and rebuilt by resolution"))))

;;; ------------------------------------------------------------------
;;; Rebuild equivalence (SS14.4)
;;; ------------------------------------------------------------------

(test reindexing-produces-an-identical-index
  ;; SS14.4 wants B and C "identical -- not merely equivalent, since ids are
  ;; derived from natural keys rather than generated".
  (with-workspace-fixture (repository)
    (let ((before (sort (mapcar #'id (all-entities (repository-graph repository)))
                        #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal before
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<))))))

(test an-incremental-update-matches-a-full-rebuild
  (with-workspace-fixture (repository)
    (write-file "src/beta.lisp" "(defun beta (x) (alpha-twice x))
")
    (poll-once repository :quiet t)
    (let ((incremental (sort (mapcar #'id (all-entities (repository-graph repository)))
                             #'string<))
          (edges-incremental
            (sort (mapcar #'id (all-relationships (repository-graph repository)))
                  #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal incremental
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<)))
      (is (equal edges-incremental
                 (sort (mapcar #'id (all-relationships (repository-graph repository)))
                       #'string<))
          "the highest-value assertion in the suite: the index agrees with
the files whichever way it got there"))))

;;; ------------------------------------------------------------------
;;; Generated definitions (ARCH-0002): the lifecycle
;;; ------------------------------------------------------------------

(test a-macro-that-stops-being-a-definer-un-mints-what-it-generated
  ;; PLAN-0001 step 5c, and ARCH-0002's "dangerous step" -- RESOLVE-GENERATED-
  ;; DEFINITIONS owns a lifecycle no earlier resolution pass has had to carry.
  ;; A macro can stop qualifying as a definer in its own file while the call
  ;; site's file never changes, so no single RETRACT-FILE is guaranteed to
  ;; invalidate the entity the call site used to mint. Both new files are
  ;; written inside the test body rather than into MAKE-FIXTURE-REPOSITORY, per
  ;; PLAN-0001's own warning that the fixture's entity counts are asserted
  ;; exactly elsewhere.
  (with-workspace-fixture (repository)
    (write-file "src/gen.lisp"
                "(defmacro def-widget (name)
  `(defun ,name () :widget))
")
    (write-file "src/call.lisp"
                "(def-widget my-widget)
")
    (let ((reindexed (poll-once repository :quiet t)))
      (is (= 2 reindexed) "both new files were seen and analyzed"))
    (let ((g (repository-graph repository)))
      (is (not (null (find "my-widget" (entities-of-type g :function)
                           :key #'name :test #'string=)))
          "the call site minted an entity that exists nowhere as a defun"))
    ;; The macro edited so its template no longer qualifies as a definer -- a
    ;; PROGN around a SETF, the false-positive shape ARCH-0002 predicts for
    ;; DEFINE-COMMAND -- while the call site's own file is left untouched.
    (write-file "src/gen.lisp"
                "(defmacro def-widget (name)
  `(progn (setf *last-widget* ',name)))
")
    (let ((reindexed (poll-once repository :quiet t)))
      (is (= 1 reindexed) "only gen.lisp changed; call.lisp is untouched"))
    (let ((g (repository-graph repository)))
      ;; THE ASSERTION THAT MATTERS: the disappearance, not merely the earlier
      ;; appearance. Without the retract half the entity survives, because
      ;; nothing about call.lisp changed for RETRACT-FILE to act on.
      (is (null (find "my-widget" (entities-of-type g :function)
                      :key #'name :test #'string=))
          "the macro no longer produces it, so this pass's own recomputed
output must take it back -- no single file's retraction would have"))
    ;; The drift question PLAN-0001 asks be checked here specifically: a fresh
    ;; rebuild has to land on exactly the incrementally-polled index, or the
    ;; retract half under- or over-corrected and only this comparison shows it.
    (let ((incremental (sort (mapcar #'id (all-entities (repository-graph repository)))
                             #'string<))
          (edges-incremental
            (sort (mapcar #'id (all-relationships (repository-graph repository)))
                  #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal incremental
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<))
          "a rebuild must not still hold the entity the incremental poll took back")
      (is (equal edges-incremental
                 (sort (mapcar #'id (all-relationships (repository-graph repository)))
                       #'string<))))))

;;; ------------------------------------------------------------------
;;; Concurrency (BUG-0004, ARCH-0004 R8(b) and R8(c))
;;; ------------------------------------------------------------------
;;;
;;; The one test here that runs two threads, and the reason BUG-0004 survived
;;; as long as it did: every other test in this file drives POLL-ONCE directly,
;;; which is the right way to test analysis but means the thread the monitor
;;; would have run it on never exists.
;;;
;;; It drives REINDEX-REPOSITORY and POLL-ONCE from separate threads with no
;;; sleep between calls rather than starting a real monitor, because the
;;; monitor's own two-second cadence would need luck to collide even once
;;; inside a sensible test budget (ARCH-0004 R8(b)).
;;;
;;; Two traps, both mechanical. fiveam's IS records into thread-local special
;;; variables, so every assertion below runs on the main thread after both
;;; joins -- a test whose checks live in workers passes unconditionally. And
;;; DETECT-DELETIONS calls APPLY-TRANSACTION with no handler of its own, so a
;;; collision can escape POLL-ONCE entirely and kill the worker, which
;;; JOIN-THREAD would then re-signal in the main thread and report as a suite
;;; that fell over rather than a test that failed. Each worker catches
;;; SERIOUS-CONDITION -- RULE-0004's type, and MONITOR-LOOP's -- and returns it.

(defparameter *stress-iterations* 200
  "Rebuilds and polls each worker performs. Chosen by measurement, not by
feel: against the unlocked tree 60 iterations reproduced the collision in
1 run of 5 and 200 in 4 of 5, and a test that fires one time in five is a
coin toss dressed as evidence (CON-0003).")

(defun stress-call (repository n thunk)
  "Call THUNK N times, sampling REPOSITORY's recorded errors after each call.
Returns (condition texts): the SERIOUS-CONDITION this thread caught or NIL,
and every error text seen along the way.

The sampling is what makes this an instrument rather than a formality.
REINDEX-REPOSITORY clears the error list as its third act, so a collision
INDEX-FILE recorded during one iteration is erased by the next one, and a
check made only after both threads have joined sees an empty list however bad
the run was. Reading the list from this thread is safe in the one way that
matters: NOTE-ERROR conses a fresh head or a fresh list and never mutates a
cons this loop is already holding."
  (let ((texts '()))
    (list (handler-case
              (dotimes (i n nil)
                (funcall thunk)
                (dolist (entry (repository-errors repository))
                  (push (cdr entry) texts)))
            (serious-condition (condition) condition))
          texts)))

(defun concurrency-text-p (text)
  (and (search "Unsafe concurrent operations" text) t))

(defun stress-counts (repository)
  "The three numbers BUG-0004 saw drift: entities, relationships, tested units.
All three, because the failure this plan reproduced had a correct entity count
and the whole of its damage in the other two."
  (let ((status (repository-status repository)))
    (list (getf status :entities)
          (getf status :relationships)
          (getf status :tested-units))))

(test a-reindex-and-a-poll-do-not-corrupt-the-index
  (with-workspace-fixture (repository)
    (let* ((rebuilder
             (bt:make-thread
              (lambda ()
                (stress-call repository *stress-iterations*
                             (lambda () (reindex-repository repository :quiet t))))
              :name "stress-reindex"))
           (poller
             (bt:make-thread
              (lambda ()
                (stress-call repository *stress-iterations*
                             (lambda () (poll-once repository :quiet t))))
              :name "stress-poll"))
           (from-rebuilder (bt:join-thread rebuilder))
           (from-poller (bt:join-thread poller))
           (after-threads (stress-counts repository)))
      (is (null (first from-rebuilder))
          "the rebuilding thread signaled ~a" (first from-rebuilder))
      (is (null (first from-poller))
          "the polling thread signaled ~a" (first from-poller))
      ;; The recorded errors are where a swallowed collision lands: INDEX-FILE
      ;; and RESOLVE-AND-CHECK's SUBMIT both catch and record rather than
      ;; signal, so a run can end with both threads returning NIL and a third
      ;; of the index missing. That is exactly BUG-0004's console transcript.
      (let ((collisions (remove-if-not #'concurrency-text-p
                                       (append (second from-rebuilder)
                                               (second from-poller)))))
        (is (null collisions)
            "a collision was caught and recorded rather than signaled: ~a"
            (first collisions)))
      ;; ARCH-0004 R8(c): the direct check that no batch was lost to a torn
      ;; view, not merely that nothing crashed. Compared against a rebuild
      ;; taken with both threads joined, which is the only state that can be
      ;; trusted as a reference.
      (reindex-repository repository :quiet t)
      (is (equal (stress-counts repository) after-threads)
          "the state the threads left differs from a quiet rebuild of the same
files: ~a against ~a" after-threads (stress-counts repository)))))

;;; ------------------------------------------------------------------
;;; Failure containment (SS3.3)
;;; ------------------------------------------------------------------

(test a-file-that-will-not-parse-does-not-stop-the-pass
  (with-workspace-fixture (repository)
    (write-file "src/gamma.lisp" "(defun gamma (")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (gamma (find "src/gamma.lisp" (entities-of-type g :file)
                        :key #'name :test #'string=)))
      (is (not (null gamma)) "the file is indexed as a known unknown")
      (is-true (getp gamma :analysis-failed-p))
      (is (= 3 (length (entities-of-type g :function)))
          "and the rest of the repository is still there"))))

(test a-rule-violation-is-detected-and-recorded
  (with-workspace-fixture (repository)
    ;; Make src call into docs, which RULE-0001 forbids. A decision entity is
    ;; not callable, so the violation is manufactured directly on the graph.
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=))
           (target (make-instance 'function-entity
                                  :name "doc-helper"
                                  :origin-file "docs/design/DEC-0001.yaml"
                                  :properties (properties-table
                                               '(:file "docs/design/helper.lisp"
                                                 :start-line 1 :end-line 2)))))
      (add-entity g target)
      (add-relationship g (make-instance 'relationship :rel-type :calls
                                         :from-id (id alpha) :to-id (id target)
                                         :origin-file "src/alpha.lisp"))
      (apply-transaction g (violation-ops g))
      (is (= 1 (length (entities-of-type g :rule-violation))))
      (is (string= "RULE-0001" (getp (first (entities-of-type g :rule-violation))
                                     :rule-id))))))
