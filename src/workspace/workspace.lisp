;;;; Workspace registry, indexing pipeline, and the file monitor.
;;;; Implements Phase 1 Software Architecture (Revision 2) SS8.3, and the
;;;; startup behaviour of SS3.4.
;;;;
;;;; The whole value of this system is one ordering, stated once. Analyzing a
;;;; file is not enough to leave the index correct, because two kinds of fact
;;;; are invisible to a file-scoped analyzer: a call whose callee is defined
;;;; elsewhere, and a document reference that names something the analyzer
;;;; cannot look up. Both are recorded as properties and resolved afterwards
;;;; against the whole repository. Then the rules of SS10.4 are checked, since
;;;; they are queries over the finished graph.
;;;;
;;;; So: analyze, resolve, check. Getting that order wrong produces an index
;;;; that is quietly missing its cross-file edges, which is exactly the
;;;; failure the TODO on APPLY-TRANSACTION describes. Owning it here is what
;;;; retires that TODO.

(in-package :loom-workspace)

(defstruct (repository (:conc-name repository-))
  "One watched Git repository and the index built from it."
  (root nil)
  (name "")
  (graph (make-graph))
  (indexed-at nil)
  (file-count 0)
  (errors '())                  ; (path . condition-text), most recent first
  (stamps (make-hash-table :test #'equal))   ; relative path -> FILE-STAMP
  (monitor nil)
  (stopping nil)                ; asks the monitor thread to return
  ;; ARCH-0004 R1. One lock per repository rather than a process-wide one:
  ;; *REPOSITORIES* can hold more than one entry and two repositories share no
  ;; state, so serializing one's rebuild against another's poll would cost
  ;; latency for no correctness reason. Recursive because REINDEX-REPOSITORY
  ;; calls INDEX-REPOSITORY and both wrap their own body, so the inner
  ;; acquisition has to be a re-entry rather than a self-deadlock. Safe as an
  ;; initform in a way the graph's lock is not: it reads no other slot.
  (analysis-lock (bt:make-recursive-lock "loom-repository-analysis")))

(defmacro with-repository-lock ((repository) &body body)
  "Run BODY holding REPOSITORY's analysis lock. ARCH-0004 R2.

Internal and unexported, and that is load-bearing rather than tidiness:
ARCH-0004 R5 requires loom-knowledge's read path to stay lock-free, and the
only way to keep that true is for the lock to be unreachable from outside this
file. A blocking acquire, with no timed or non-blocking variant anywhere in
the design -- the measured worst-case hold is around a tenth of one poll
interval, which is what retired the earlier skip-and-retry draft."
  `(bt:with-recursive-lock-held ((repository-analysis-lock ,repository))
     ,@body))

(defvar *repositories* '()
  "Watched repositories, most recently registered first.")

(defun normalize-root (path)
  (let ((truename (or (probe-file path)
                      (error "No such directory: ~a" path))))
    (pathname-as-directory truename)))

(defun pathname-as-directory (path)
  (if (pathname-name path)
      (make-pathname :directory (append (or (pathname-directory path) '(:absolute))
                                        (list (file-namestring path)))
                     :name nil :type nil :defaults path)
      path))

(defun find-repository (designator)
  "The repository named or rooted at DESIGNATOR.
Accepts a name, so a developer types \"reindex Loom\" rather than a path."
  (or (find designator *repositories* :key #'repository-name :test #'string-equal)
      (find (namestring (pathname-as-directory (pathname designator)))
            *repositories*
            :key (lambda (r) (namestring (repository-root r)))
            :test #'string-equal)))

(defun all-repositories () (reverse *repositories*))

;;;; ==================================================================
;;;; Indexing (SS3.4)
;;;; ==================================================================

(defun dot-prefixed-p (name)
  (and (stringp name) (plusp (length name)) (char= #\. (char name 0))))

(defun repository-files (repository)
  "Every file under the repository root that some analyzer claims.

Skips .git and any dot-directory: nothing in them is source, and .git in
particular churns constantly.

Skips dot-prefixed files for the same reason and one more. A name beginning
with a dot is an editor's or a tool's bookkeeping rather than source, and some
of it is not even a file: Emacs writes .#foo.yaml as a dangling symlink while a
buffer is open, which keeps the extension of the thing it locks, so an analyzer
claims it and then fails to read it. The developer sees an error naming a file
that does not exist, in a repository where nothing is wrong, for as long as
they have the real file open."
  (remove-if-not
   (lambda (path)
     (and (pathname-name path)
          (not (dot-prefixed-p (file-namestring path)))
          (notany #'dot-prefixed-p (rest (pathname-directory path)))
          (analyzable-p path)))
   (directory (merge-pathnames "**/*.*" (repository-root repository)))))

(defun note-error (repository path condition)
  (push (cons path (princ-to-string condition)) (repository-errors repository))
  (when (> (length (repository-errors repository)) 50)
    (setf (repository-errors repository)
          (subseq (repository-errors repository) 0 50))))

(defparameter *mtime-settle-seconds* 2
  "How old a write date has to be before an unchanged one is believed.

FILE-WRITE-DATE counts in whole seconds, so a file edited in the same second
the index read it carries the same write date afterwards and the edit is
invisible to any comparison of write dates alone. That is not a rare race: it
is what happens every time a developer saves twice quickly, and every time a
test writes a fixture and immediately polls it. Within this window the poll
stops trusting the clock and compares content instead.")

(defstruct (file-stamp (:constructor make-file-stamp (write-date content-hash)))
  "What a poll compares a file against to decide whether it moved."
  (write-date 0)
  (content-hash 0))

(defun stamp-file (path contents)
  (make-file-stamp (or (ignore-errors (file-write-date path)) 0) (sxhash contents)))

(defun file-changed-p (repository relative path now)
  "True when PATH needs reanalyzing.

Cheap in the common case and correct in the case that matters. An unseen file
or a moved write date is a change and costs one stat. An unchanged write date
older than *MTIME-SETTLE-SECONDS* is believed, so a steady repository costs
nothing but stats. Only inside the settle window -- where the write date
cannot answer the question -- is the file read and hashed."
  (let ((known (gethash relative (repository-stamps repository)))
        (write-date (ignore-errors (file-write-date path))))
    (cond ((null write-date) nil)      ; unreadable now; leave the index alone
          ((null known) t)             ; never indexed
          ((not (eql write-date (file-stamp-write-date known))) t)
          ((> (- now write-date) *mtime-settle-seconds*) nil)
          (t (not (eql (file-stamp-content-hash known)
                       (sxhash (handler-case (slurp-file path)
                                 (error () ""))))))))) ; unreadable => reanalyze

(defun index-file (repository path &key quiet)
  "Analyze one file into the repository's index. Returns T on success.

SS3.3: a condition here must not escape. A file that fails to analyze is
counted and reported; the pass continues."
  (let ((relative (workspace-relative-path path (repository-root repository))))
    (handler-case
        ;; Read once and hand the text to both the analyzer and the stamp:
        ;; ANALYZE-PATH takes :CONTENTS for exactly this, and the stamp has to
        ;; describe the bytes that were analyzed rather than whatever is on
        ;; disk by the time it is taken.
        (let* ((contents (slurp-file path))
               (ops (analyze-path path
                                  :contents contents
                                  :workspace-id (repository-name repository)
                                  :workspace-root (repository-root repository))))
          (when ops
            (apply-transaction (repository-graph repository) ops)
            (setf (gethash relative (repository-stamps repository))
                  (stamp-file path contents))
            t))
      (error (condition)
        (note-error repository relative condition)
        (unless quiet
          (format *standard-output* "~&  ! ~a: ~a~%" relative condition))
        nil))))

(defun resolve-and-check (repository &key quiet)
  "The passes that need the whole repository in one place.

Order matters and is the reason this function exists. Document links resolve
against entities the code analyzers produced, and the rules of SS10.4 are
queries over the finished graph, so they run last. Two stages in the middle
are load-bearing for the same kind of reason (ARCH-0002). A definer macro's
call site mints an entity, and that entity has to exist and carry its
:CALL-NAMES before RESOLVE-CALLS can turn them into edges; and coverage is
derived from those edges, so RESOLVE-TESTS has to follow RESOLVE-CALLS rather
than merely accompany it. The full sequence is resolve-definitions,
resolve-generated-definitions, resolve-calls, resolve-tests,
resolve-document-links, check-rules, and each arrow in it is a dependency
rather than a preference."
  (let ((graph (repository-graph repository))
        (workspace (repository-name repository)))
    (flet ((submit (label ops)
             (when ops
               (handler-case (apply-transaction graph ops)
                 (error (condition)
                   (note-error repository label condition)
                   (unless quiet
                     (format *standard-output* "~&  ! ~a: ~a~%" label condition)))))))
      ;; Definitions first: a dispatched call fans out to the methods on a
      ;; generic, and RESOLVE-METHOD-PROTOCOLS is what attaches them to it.
      (submit "resolve-definitions"    (resolve-definitions graph :workspace-id workspace))
      ;; Then the generated definitions, before RESOLVE-CALLS: a macro call
      ;; site mints an entity carrying the names its argument list invokes, and
      ;; a pass that has not run yet has nothing for the next one to resolve.
      ;;
      ;; *MACRO-GENERATORS* is handed in rather than reached for. loom-graph
      ;; depends on loom-ontology alone and RULE-0001 to RULE-0003 keep it
      ;; that way, so the pass cannot see the analyzer's table -- and this is
      ;; the first system that uses both packages, which is exactly the job
      ;; this one exists to do.
      (submit "resolve-generated-definitions"
              (resolve-generated-definitions graph :workspace-id workspace
                                                   :registry *macro-generators*))
      (submit "resolve-calls"          (resolve-calls graph :workspace-id workspace))
      ;; And RESOLVE-TESTS after RESOLVE-CALLS, which is the second half of why
      ;; this sequence is load-bearing rather than merely tidy: coverage is
      ;; derived from the :CALLS edges a test's body produced, so a pass that
      ;; has not run yet leaves every test covering nothing.
      (submit "resolve-tests"          (resolve-tests graph :workspace-id workspace))
      (submit "resolve-document-links" (resolve-document-links graph :workspace-id workspace))
      (submit "check-rules"            (violation-ops graph :workspace-id workspace)))))

(defun index-repository (repository &key quiet)
  "Analyze every analyzable file, then resolve and check.

SS3.4: \"Because files are truth, this is always available and always correct,
and its only cost is time.\"

Locked for its whole body (ARCH-0004 R3). It wraps itself rather than relying
on REINDEX-REPOSITORY's lock because it is a real independent entry point:
WATCH-REPOSITORY calls it directly on first registration, before any monitor
thread exists."
  (with-repository-lock (repository)
    (let ((files (repository-files repository))
          (indexed 0))
      (unless quiet
        (format t "~&Indexing ~a (~d files)...~%" (repository-name repository) (length files)))
      (dolist (path files)
        (when (index-file repository path :quiet quiet) (incf indexed)))
      (resolve-and-check repository :quiet quiet)
      (setf (repository-file-count repository) indexed
            (repository-indexed-at repository) (get-universal-time))
      indexed)))

(defun reindex-repository (repository &key quiet)
  "Discard the index and rebuild it from disk.

SS3.2: \"Always safe, because files are truth; the escape hatch for any
suspected divergence.\" A fresh graph rather than a cleared one, so nothing
from the old index can survive by accident.

The graph swap and the stamp clear are inside the lock, not merely the nested
INDEX-REPOSITORY call (ARCH-0004 R3). BUG-0004's CAUSE names the clrhash as
the step that opens the window: between it and the moment INDEX-FILE re-stamps
a file, that file reads as changed to a concurrent poll, which then starts its
own analysis into the graph this function is rebuilding. This is also the
function whose first act discards the graph object, which is why the graph's
own lock could not have closed this half -- the object a graph-scoped lock
would belong to does not exist yet at the instant protection has to begin."
  (with-repository-lock (repository)
    (setf (repository-graph repository) (make-graph))
    (clrhash (repository-stamps repository))
    (setf (repository-errors repository) '())
    (index-repository repository :quiet quiet)))

;;;; ==================================================================
;;;; Monitoring (SS8.3)
;;;; ==================================================================

(defparameter *poll-interval* 2
  "Seconds between mtime scans.

SS8.3 prefers OS notifications \"where a portable library behaves\" and falls
back to \"a two-second mtime poll otherwise -- the poll is the guaranteed path
and is adequate for one developer's save rate\". Only the guaranteed path is
implemented: it works identically on Windows and Linux, and the difference
between a two-second and an instant reaction does not matter to an agent that
queries between edits.")

(defun poll-once (repository &key quiet)
  "Reanalyze every file whose mtime moved, and every file that has appeared.
Returns the number of files reindexed.

A deleted file is handled by the retract-file that opens every analysis pass,
so nothing here has to notice deletions -- except that a file gone from disk
never comes up again, which is the one case this misses and the reason
DETECT-DELETIONS exists below.

Locked for its whole body, changed-file computation included and not only the
mutating tail (ARCH-0004 R3). The FILE-CHANGED-P loop reads REPOSITORY-STAMPS,
and computed outside the lock it could read a table REINDEX-REPOSITORY is
midway through clearing -- which is BUG-0004's CAUSE reproduced one level
down. Locking only the writing half would move the window rather than close
it."
  (with-repository-lock (repository)
    (let ((changed '())
          (now (get-universal-time)))
      (dolist (path (repository-files repository))
        (let ((relative (workspace-relative-path path (repository-root repository))))
          (when (file-changed-p repository relative path now)
            (push path changed))))
      (dolist (path changed) (index-file repository path :quiet quiet))
      (let ((removed (detect-deletions repository)))
        (when (or changed removed)
          (resolve-and-check repository :quiet quiet)))
      (length changed))))

(defun detect-deletions (repository)
  "Retract files the index knows about that are no longer on disk."
  (let ((graph (repository-graph repository))
        (gone '()))
    (dolist (file (origin-files graph))
      (unless (probe-file (merge-pathnames file (repository-root repository)))
        (push file gone)))
    (when gone
      (apply-transaction graph
                         (mapcar (lambda (file)
                                   (retract-file file (repository-name repository)))
                                 gone))
      (dolist (file gone) (remhash file (repository-stamps repository))))
    gone))

(defun monitor-running-p (repository)
  (let ((thread (repository-monitor repository)))
    (and thread (bt:thread-alive-p thread))))

(defun start-monitor (repository)
  "Begin polling. Idempotent.

SS3.3: the body runs inside a handler that logs and continues rather than
entering the debugger, because \"an analyzer signals a condition, the watcher
thread drops into the debugger, and the process stays alive and answers queries
while silently no longer indexing anything\" is the failure to design against.
Nothing in the developer's experience distinguishes that from a quiet
afternoon."
  (unless (monitor-running-p repository)
    (setf (repository-stopping repository) nil
          (repository-monitor repository)
          (bt:make-thread
           (lambda () (monitor-loop repository))
           :name (format nil "loom-monitor ~a" (repository-name repository)))))
  repository)

(defun monitor-loop (repository)
  "Poll until asked to stop.

SERIOUS-CONDITION rather than ERROR, because this thread existing at all is
SS3.3's answer to a watcher that dies quietly. A library whose conditions are
not ERROR subtypes -- cl-yaml's are not -- would otherwise end the loop through
the one path the loop was written to survive."
  (loop until (repository-stopping repository)
        do (handler-case (poll-once repository :quiet t)
             (serious-condition (condition)
               (note-error repository "monitor" condition)))
           (monitor-sleep repository *poll-interval*)))

(defun monitor-sleep (repository seconds)
  "SLEEP, in slices, abandoned as soon as a stop is requested.
One SLEEP of *POLL-INTERVAL* would make every stop wait out the full interval
for no reason."
  (loop with slice = 0.1
        for remaining = seconds then (- remaining slice)
        while (and (plusp remaining) (not (repository-stopping repository)))
        do (sleep (min slice remaining))))

(defparameter *monitor-stop-timeout* 10
  "Seconds to wait for a monitor to return before destroying it.
Generous on purpose: the thing being waited for is a poll finishing, and a poll
that is midway through APPLY-TRANSACTION should be allowed to finish it.")

(defun stop-monitor (repository)
  "Ask the monitor to return, and wait until it has.

Cooperative rather than a straight BT:DESTROY-THREAD. Destroying a thread
stops it wherever it happens to be, which for this thread means possibly
midway through a transaction, holding the graph half-written. Worse, the old
version dropped the thread reference whether or not the destroy took: a
monitor that survived it kept polling and kept writing to a graph nobody could
reach it through, while MONITOR-RUNNING-P reported it stopped. Under
`sbcl --script' that is invisible, because MAIN returning ends the process.
Under SLIME the image outlives the console and the thread outlives everything.

The reference is kept when the thread refuses to die, so status keeps telling
the truth and a later stop can try again."
  (let ((thread (repository-monitor repository)))
    (setf (repository-stopping repository) t)
    (when thread
      (loop repeat (ceiling *monitor-stop-timeout* 0.05)
            while (bt:thread-alive-p thread)
            do (sleep 0.05))
      (when (bt:thread-alive-p thread)
        (ignore-errors (bt:destroy-thread thread))))
    (setf (repository-monitor repository)
          (and thread (bt:thread-alive-p thread) thread)))
  repository)

;;;; ==================================================================
;;;; Lifecycle
;;;; ==================================================================

(defun watch-repository (path &key (monitor t) quiet)
  "Register the repository at PATH, index it, and begin watching.
SS3.2's watch command. Re-watching an already-registered repository reindexes
it rather than registering a second copy.

Both branches start the monitor, and the second one has to. MAIN stops every
monitor when the console exits but leaves the repositories registered, because
*REPOSITORIES* is a global that outlives one console session -- so the second
`(main)' in a live image finds the repository already there, took this branch,
and used to reindex it without ever watching it again. What a developer saw was
`watcher: stopped' on a repository they had just asked to watch, and watching
a subdirectory instead appearing to fix it, because a different root is a new
registration. START-MONITOR is idempotent, so saying it twice costs nothing."
  (let* ((root (normalize-root path))
         (existing (find (namestring root) *repositories*
                         :key (lambda (r) (namestring (repository-root r)))
                         :test #'string=)))
    (if existing
        (progn (reindex-repository existing :quiet quiet)
               (when monitor (start-monitor existing))
               existing)
        (let ((repository (make-repository
                           :root root
                           :name (or (car (last (pathname-directory root))) "repository"))))
          (push repository *repositories*)
          (index-repository repository :quiet quiet)
          (when monitor (start-monitor repository))
          repository))))

(defun pause-repository (designator)
  "Stop watching DESIGNATOR without dropping its index. DEC-0004's pause.

The distinction from UNWATCH-REPOSITORY is the whole of DEC-0004: a console
session and an index have different lifetimes, so leaving the console has to be
able to stop the polling without spending the seconds it took to build the
graph. WATCH-REPOSITORY on an already registered repository resumes it, which
is why there is no separate resume."
  (let ((repository (find-repository designator)))
    (when repository (stop-monitor repository))
    repository))

(defun unwatch-repository (designator)
  "Stop watching and drop the index. SS3.2's unwatch."
  (let ((repository (find-repository designator)))
    (when repository
      (stop-monitor repository)
      (setf *repositories* (remove repository *repositories*)))
    repository))

(defun repository-status (repository)
  "SS3.2's status, as plain data: \"indexing progress, entity and relationship
counts, watcher health, unresolved document references, unenforced rules, and
the last error per thread.\""
  (let ((graph (repository-graph repository)))
    (list :name (repository-name repository)
          :root (namestring (repository-root repository))
          :indexed-at (repository-indexed-at repository)
          :files (repository-file-count repository)
          :entities (length (all-entities graph))
          :relationships (length (all-relationships graph))
          ;; :PAUSED, not :STOPPED. A registered repository that is not being
          ;; polled is in a state DEC-0004 named and gave a command for; the
          ;; older word described it as something that had gone wrong.
          :monitor (if (monitor-running-p repository) :watching :paused)
          :documents (+ (length (entities-of-type graph :decision))
                        (length (entities-of-type graph :rule))
                        (length (entities-of-type graph :concept))
                        (length (entities-of-type graph :document)))
          ;; ARCH-0002 R10, following the precedent :DOCUMENTS set: a named sum
          ;; rather than a raw total. These three are the console-readable
          ;; acceptance check for the whole of ARCH-0002 -- fiveam's TEST and
          ;; DEF-SUITE are the most common macro calls in every
          ;; src/*/test/*.lisp, so all three read zero until generated
          ;; definitions reach the index and are expected to move when Loom
          ;; indexes itself. It does not need BUG-0002's general ability to
          ;; enumerate an entity type by name, which `find' still lacks.
          :test-entities (length (entities-of-type graph :test))
          :tested-units (length (remove-duplicates
                                 (loop for r in (all-relationships graph)
                                       when (eq :tests (rel-type r))
                                         collect (to-id r))
                                 :test #'equal))
          ;; Two counts summed because a reader wants one number: a definer
          ;; Loom could not characterise, and a call site it had to refuse, are
          ;; the same thing from where they stand -- a definition the index
          ;; knows it is missing. The collision half is recounted rather than
          ;; recorded, because the obvious place to store it is a property the
          ;; analyzer owns (ARCH-0002 R1).
          :unhandled-definer-macros
          (+ (length (unhandled-definer-macros graph))
             (length (generated-definition-collisions graph *macro-generators*)))
          :unresolved-references (length (unresolved-references graph))
          :unenforced-rules (length (unenforced-rules graph))
          :violations (length (entities-of-type graph :rule-violation))
          :uncategorized-documents
          (count-if (lambda (d)
                      (let ((category (getp d :category)))
                        (and category
                             (not (assoc category *document-type-directories*
                                         :test #'string-equal)))))
                    (entities-of-type graph :document))
          :errors (length (repository-errors repository))
          :last-error (first (repository-errors repository)))))
