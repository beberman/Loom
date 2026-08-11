;;;; The read- and write-tier operations.
;;;;
;;;; Every entry here is a thin call onto a function console.lisp already
;;;; calls, stopping one step short of console.lisp's formatting. Nothing in
;;;; this file renders; DES-0005's argument is that the data is already
;;;; structured and only the console's last step is prose, so a second
;;;; rendering step would be a second thing to keep in agreement with the first.
;;;;
;;;; Repository selection is explicit and never guessed. CURRENT-REPOSITORY's
;;;; convenience -- imply the one watched repository, refuse to guess among
;;;; several -- is right for a human who forgot to type a name and wrong for a
;;;; program, which either knows which repository it means or should ask first.
;;;; REQUIRE-REPOSITORY is where that is enforced once rather than eleven times.

(in-package :loom-serve)

;;;; ==================================================================
;;;; Selecting what to operate on
;;;; ==================================================================

(defvar *workspace-registry-lock* (bt:make-recursive-lock "loom-serve-workspace-registry")
  "Serializes the two operations that add to or remove from *REPOSITORIES*.

PLAN-0005 FINDING 2. src/workspace/workspace.lisp:52 declares *REPOSITORIES* as
a bare DEFVAR; line 424 pushes onto it and line 446 SETFs it to a REMOVE, and
neither PUSH nor SETF is atomic on SBCL. WITH-REPOSITORY-LOCK (line 40) cannot
cover either: it takes its lock out of a repository struct, and at line 424 the
struct exists but nothing else can name it, while at line 446 the point of the
operation is that it stops existing. Under the console this can never fire --
one stdin loop dispatches one line at a time, so no two `watch` calls overlap.
Under N Hunchentoot worker threads two concurrent watches of different paths
can lose a registration and two concurrent unwatches can resurrect one.

The lock lives here and not in loom-workspace because REQ-0008 forbids editing
that system, and this is the caller that created the need.

Acquisition order, stated because DES-0004 states one and a lock added above
it is only safe if it never inverts: this lock is always acquired *before* any
repository's analysis-lock and never from inside one. The only things called
while holding it are the WATCH-REPOSITORY and UNWATCH-REPOSITORY calls it
exists to serialize, and both take a repository lock beneath it, never above.
Recursive for the same reason DES-0004's is: a re-entry must not self-deadlock.")

(defun require-repository (designator)
  "The repository DESIGNATOR names, or a malformed request naming it.

No default, no fallback to the sole watched repository, no CURRENT-REPOSITORY.
DES-0006 is explicit that an operation invoked without a designator is a
malformed request rather than an ambiguous one to be resolved by guessing."
  (cond ((null designator)
         (error 'malformed-request
                :message "This operation needs the name of a repository. Ask status for the list."))
        ((find-repository designator))
        (t (error 'malformed-request
                  :message (format nil "No repository named ~a. Ask status for the list."
                                   designator)))))

(defun resolve-entity (graph term)
  "The entity TERM names: an id if it is one, otherwise the best name match.

Re-implemented here rather than reached for. console.lisp has a function of
this name and shape, and calling it would make loom-serve depend on
loom-process, which DES-0006 R5 forbids and PLAN-0005's RISKS names as one of
the three ways that dependency arrives looking reasonable. CURRENT-REPOSITORY,
which sits beside it in that file, is deliberately *not* reproduced: refusing
to guess which repository a program meant is the point."
  (or (get-entity graph term)
      (let ((hits (search-entities graph :name term :limit 1)))
        (when hits (get-entity graph (getf (first hits) :id))))
      (error 'unknown-entity
             :message (format nil "Nothing in the index matches ~s." term))))

(defun repository-view (designator)
  "The graph REQUIRE-REPOSITORY's answer holds."
  (repository-graph (require-repository designator)))

(defun request-integer (value what)
  "VALUE as a non-negative integer, NIL when absent, or a malformed request.

Both skins reach the same entry with different types: an HTTP query parameter
is a string and a JSON body carries a number, and the entry should not have to
know which arrived. Junk is refused rather than truncated, which is
console.lisp's RESOLVE-COUNT answer and REV-0001 finding 4's reason -- `depth
3x' meaning 3 is a guess about intent, and a wrong guess about a bound is
invisible in the output, because the report is simply smaller than the caller
asked for."
  (cond ((null value) nil)
        ((and (integerp value) (not (minusp value))) value)
        ((stringp value)
         (multiple-value-bind (n end) (parse-integer value :junk-allowed t)
           (unless (and n (= end (length value)) (not (minusp n)))
             (error 'malformed-request
                    :message (format nil "~a must be a non-negative integer, not ~s."
                                     what value)))
           n))
        (t (error 'malformed-request
                  :message (format nil "~a must be a non-negative integer, not ~s."
                                   what value)))))

;;;; ==================================================================
;;;; Read tier (R2's seven names)
;;;; ==================================================================

(defparameter *find-limit* 20
  "How many hits :FIND returns when the caller does not say.
The console's own cap, so the two answer the same question the same way.")

;; ENTITY-TYPE rather than TYPE, and the argument a caller sends is named to
;; match. TYPE is an external symbol of COMMON-LISP, and SBCL's package lock
;; refuses to bind one as a local variable -- a compile-time failure, not a
;; style question.
(define-operation :find :read (repository term (entity-type) (limit))
    "Where something is defined."
  ;; Wrapped under :ENTITIES rather than returned as a bare list, so that every
  ;; operation in this system answers with a plist and every JSON response is
  ;; therefore an object. A bare list would also make an empty result encode as
  ;; null instead of [], which is the ambiguity *ARRAY-VALUED-KEYS* exists to
  ;; prevent and which a top-level value has no key to be rescued by.
  (list :entities
        (search-entities (repository-view repository)
                         :name term
                         :type (and entity-type
                                    (intern (string-upcase (string entity-type)) :keyword))
                         :limit (or (request-integer limit "limit") *find-limit*))))

(define-operation :describe :read (repository term)
    "Full detail for one entity, with its neighbours grouped by edge type."
  (let ((graph (repository-view repository)))
    (describe-entity graph (id (resolve-entity graph term)))))

(define-operation :impact :read (repository term (depth))
    "What may need attention if this changes, with paths and depths."
  (let ((graph (repository-view repository)))
    (impact-report graph (id (resolve-entity graph term))
                   :max-depth (or (request-integer depth "depth")
                                  *default-impact-depth*))))

(define-operation :context :read (repository task)
    "A budgeted context bundle for a task: what to know before editing."
  ;; BUILD-CONTEXT and no RENDER-CONTEXT. The rendering step is what turns the
  ;; bundle into the text a console prints, and a program wants the bundle.
  (build-context (repository-view repository) task))

(define-operation :status :read ((repository))
    "Index size, watcher health, unresolved references, rule violations."
  ;; The one operation with no designator requirement, because with none it is
  ;; the repository-discovery call a caller makes once before naming one to
  ;; everything else. Two shapes on purpose: a named repository answers with
  ;; its own status plist, and no name answers with the list under
  ;; :REPOSITORIES, which is what tells an empty answer from a single one.
  (if repository
      (repository-status (require-repository repository))
      (list :repositories (mapcar #'repository-status (all-repositories)))))

;;;; ------------------------------------------------------------------
;;;; check and rules: the assembly DES-0006 accepts as duplication
;;;;
;;;; CONSEQUENCES records this as a small, named duplication rather than
;;;; hiding it: console.lisp's `check` and `rules` commands already make this
;;;; same handful of loom-graph calls, as formatting rather than as data,
;;;; because no single loom-knowledge function bundles them and adding one
;;;; would edit loom-knowledge, which REQ-0008 excludes.
;;;;
;;;; This is the one place in this system where a future document adding
;;;; CHECK-REPORT and RULES-REPORT to loom-knowledge would delete code: both
;;;; this file and console.lisp would call it, and neither's external behaviour
;;;; would change.
;;;; ------------------------------------------------------------------

(defun violation-summary (violation)
  (list :rule-id (getp violation :rule-id)
        :severity (getp violation :severity)
        :detail (getp violation :detail)))

(defun rule-summary (rule)
  (list :doc-id (getp rule :doc-id)
        :title (getp rule :title)
        :severity (getp rule :severity)
        ;; The console prints "[prose only]" here. The same fact, as a boolean
        ;; a program can branch on.
        :enforceable (and (enforceable-rule-p rule) t)))

(defun pair-summary (pair)
  (list :from (car pair) :to (cdr pair)))

(define-operation :check :read (repository)
    "Rule violations, unresolved document references, and unread definers."
  (let ((graph (repository-view repository)))
    (list :violations (mapcar #'violation-summary
                              (entities-of-type graph :rule-violation))
          :unenforced (mapcar #'rule-summary (unenforced-rules graph))
          :unresolved (mapcar #'pair-summary (unresolved-references graph))
          :unhandled-definer-macros
          (mapcar (lambda (macro)
                    (list :name (name macro)
                          :file (getp macro :file)
                          :start-line (getp macro :start-line)))
                  (unhandled-definer-macros graph))
          :collisions (mapcar #'pair-summary
                              (generated-definition-collisions graph *macro-generators*)))))

(define-operation :rules :read (repository)
    "Active rules and what they constrain."
  (list :rules (mapcar #'rule-summary (active-rules (repository-view repository)))))

;;;; ==================================================================
;;;; Write tier
;;;; ==================================================================

(define-operation :watch :write (path)
    "Register a repository, index it, and begin watching. Resumes a paused one."
  ;; Under the registry lock: this is one of the two entries that adds to or
  ;; removes from *REPOSITORIES*. See the lock's own comment for why the list
  ;; needs one and this file is where it goes.
  ;; :QUIET T, unlike console.lisp's `watch`, which prints its progress to the
  ;; developer watching it happen. A service has no such developer: the answer
  ;; is the status plist this returns, and per-file progress on the process's
  ;; own *STANDARD-OUTPUT* would be noise in a log nobody asked for.
  (bt:with-recursive-lock-held (*workspace-registry-lock*)
    (repository-status (watch-repository path :quiet t))))

(define-operation :pause :write (repository)
    "Stop watching but keep the index. Resume with watch."
  ;; No registry lock. PAUSE mutates no list -- it stops a monitor thread and
  ;; leaves the registration exactly where it was -- and taking the lock here
  ;; would look consistent while widening it for no reason.
  (let ((watched (require-repository repository)))
    (repository-status (pause-repository (repository-name watched)))))

(define-operation :unwatch :write (repository)
    "Stop watching and drop the index."
  (bt:with-recursive-lock-held (*workspace-registry-lock*)
    (let ((watched (require-repository repository)))
      (repository-status (unwatch-repository (repository-name watched))))))

(define-operation :reindex :write (repository)
    "Discard and rebuild the index from disk. Always safe."
  ;; No registry lock either, for PAUSE's reason: REINDEX-REPOSITORY replaces
  ;; the graph inside a repository that stays registered throughout, and
  ;; DES-0004's own lock is what makes that safe.
  (let ((watched (require-repository repository)))
    (reindex-repository watched :quiet t)
    (repository-status watched)))
