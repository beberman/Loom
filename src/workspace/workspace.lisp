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
  ;; DES-0011 R8: per-unit statuses, inspector absences, drop counts and a run
  ;; counter from the last ENRICH-REPOSITORY, or NIL if there has not been one.
  ;; In memory only, and DEC-0001 is satisfied rather than bent: the report is
  ;; derivable by re-running the pass, so it is cache and says so.
  (enrichment nil)
  ;; DES-0025 D4. What .loom/frameworks.yaml declared, re-read on every index
  ;; pass so an edit to it takes effect on the next reindex rather than on the
  ;; next restart. NIL is the normal case: every repository Loom indexed before
  ;; this existed has no such file and needs none.
  (frameworks nil)
  ;; DES-0018 D5. Why git could not be asked what this tree ignores, or NIL
  ;; when it answered. Set on every pass, so it clears itself as soon as the
  ;; cause goes away. Reported by `status' rather than logged as an error: a
  ;; directory that is legitimately not a repository would otherwise push a
  ;; line onto the error list on every poll, for a condition that is stable and
  ;; expected.
  (ignore-reason nil)
  ;; DES-0004 R1. One lock per repository rather than a process-wide one:
  ;; *REPOSITORIES* can hold more than one entry and two repositories share no
  ;; state, so serializing one's rebuild against another's poll would cost
  ;; latency for no correctness reason. Recursive because REINDEX-REPOSITORY
  ;; calls INDEX-REPOSITORY and both wrap their own body, so the inner
  ;; acquisition has to be a re-entry rather than a self-deadlock. Safe as an
  ;; initform in a way the graph's lock is not: it reads no other slot.
  (analysis-lock (bt:make-recursive-lock "loom-repository-analysis")))

(defmacro with-repository-lock ((repository) &body body)
  "Run BODY holding REPOSITORY's analysis lock. DES-0004 R2.

Internal and unexported, and that is load-bearing rather than tidiness:
DES-0004 R5 requires loom-knowledge's read path to stay lock-free, and the
only way to keep that true is for the lock to be unreachable from outside this
file. A blocking acquire, with no timed or non-blocking variant anywhere in
the design -- the measured worst-case hold is around a tenth of one poll
interval, which is what retired the earlier skip-and-retry draft.

One holder is outside that measurement by orders of magnitude and is named
here rather than left for a reader to discover: ENRICH-REPOSITORY holds it
across one child SBCL per unit, each bounded by the inspector's own
TIMEOUT-SECONDS (300 by default), so the monitor thread can park for minutes
on a tree that builds slowly. Accepted rather than fixed. The hold is bounded
by a timeout the caller sets, an enrich is explicit and rare (DES-0011 R9),
and what a parked monitor costs is a delayed poll rather than a wrong index.
The alternative -- hold the lock only around the merge and let the read-only
out-of-process inspection run outside it -- would let a poll reindex between
the two, so the facts would be read against one tree state and merged into
another; the shorter hold is not worth buying with that."
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
Accepts a name, so a developer types \"reindex Loom\" rather than a path.

Three branches, and the middle one is the whole point. A repository's root is
stored as WATCH-REPOSITORY's NORMALIZE-ROOT left it -- a truename, so `~' is
already expanded and every symlink already followed -- while a designator
arrives as whatever was typed. Comparing the two as strings therefore fails on
exactly the spelling the console encourages: `watch \"~/lisp/Loom\"' registers
/home/beberman/lisp/Loom/, and `unwatch \"~/lisp/Loom\"' used to match neither
the name branch (the name is the last path component, \"Loom\") nor the string
branch, so a repository could be watched by a path it could not be unwatched
by. Normalising the designator the same way the root was normalised is what
makes the two comparable.

The raw string branch is kept last rather than replaced, because
NORMALIZE-ROOT probes the filesystem and a root that has since been deleted
would otherwise become unreachable by path -- and unwatching a directory that
is gone is a thing someone will want to do. IGNORE-ERRORS rather than a
PROBE-FILE test because the designator is usually a name and not a path at
all, and NORMALIZE-ROOT signals on those."
  (flet ((rooted-at (namestring)
           (find namestring *repositories*
                 :key (lambda (r) (namestring (repository-root r)))
                 :test #'string-equal)))
    (or (find designator *repositories* :key #'repository-name :test #'string-equal)
        (let ((root (ignore-errors (normalize-root designator))))
          (and root (rooted-at (namestring root))))
        (rooted-at (namestring (pathname-as-directory (pathname designator)))))))

(defun all-repositories () (reverse *repositories*))

;;;; ==================================================================
;;;; Indexing (SS3.4)
;;;; ==================================================================

(defun dot-prefixed-p (name)
  (and (stringp name) (plusp (length name)) (char= #\. (char name 0))))

;;;; ------------------------------------------------------------------
;;;; What the repository says is not part of it (DES-0018)
;;;;
;;;; Loom does not interpret .gitignore. The pattern language has anchoring,
;;;; directory-only matches, ** and negation whose meaning depends on whether a
;;;; parent was already excluded, and the inputs are not only .gitignore --
;;;; git also reads one per directory, .git/info/exclude, and whatever
;;;; core.excludesFile points at, which may be outside the tree. Since the
;;;; question is literally "what does git ignore here", git is asked.
;;;; ------------------------------------------------------------------

(defparameter *ignore-query-timeout-seconds* 20
  "Bound on the check-ignore subprocess. Generous: it is one process for a
whole tree, and the cost of it running long is a slow poll rather than a wrong
answer.")

(defun ignored-paths (root relative-paths)
  "The subset of RELATIVE-PATHS that git ignores under ROOT, as a hash table.

One subprocess for the whole list, not one per file: `git check-ignore --stdin'
reads paths and writes back only the ignored ones.

Two things this must not do. It must not treat exit status 1 as a failure --
that status means none of the paths were ignored, which is the ordinary answer
for a clean repository, and reading it as an error would make every tree behave
as though git were missing. And it must not pass --no-index, which is what
keeps DES-0018 D3 true: git consults the index by default and does not report a
*tracked* file as ignored, so a checked-in dist/ keeps being indexed while a
generated one does not.

Returns an empty table, and a second value naming the reason, when git cannot
answer -- no repository, no git, a timeout, a signal. The caller indexes
everything in that case (D5): a known unknown beats both a crash and a false
clean."
  (let ((ignored (make-hash-table :test #'equal)))
    (if (null relative-paths)
        (values ignored nil)
        (handler-case
            (multiple-value-bind (out err status)
                ;; `timeout' rather than thread machinery, on DES-0011's
                ;; precedent: the inspector bounds its child the same way and
                ;; reads 124 as the timeout having fired. No new dependency --
                ;; the binary is already required by that path.
                (uiop:run-program (list "timeout"
                                        (princ-to-string *ignore-query-timeout-seconds*)
                                        "git" "-C" (namestring root)
                                        "check-ignore" "--stdin")
                                  :input (make-string-input-stream
                                          (format nil "~{~a~%~}" relative-paths))
                                  :output :string
                                  :error-output :string
                                  :ignore-error-status t)
              (declare (ignore err))
              (cond ((member status '(0 1))
                     (with-input-from-string (in out)
                       (loop for line = (read-line in nil nil)
                             while line
                             for trimmed = (string-trim '(#\Return #\Space) line)
                             unless (zerop (length trimmed))
                               do (setf (gethash trimmed ignored) t)))
                     (values ignored nil))
                    (t
                     ;; 128 and friends: not a repository, or git refused.
                     ;; 124 is `timeout' having fired. Either way the tree is
                     ;; indexed whole and the reason is carried back.
                     (values (make-hash-table :test #'equal)
                             (if (eql status 124)
                                 "git check-ignore timed out"
                                 (format nil "git check-ignore exited ~a" status))))))
          (error (condition)
            (values (make-hash-table :test #'equal)
                    (princ-to-string condition)))))))

(defun repository-commit (repository)
  "Two values: REPOSITORY's HEAD commit, and why it could not be read.

DES-0022 D5. A structural report has to name the tree it described, or a reader
meeting a generated architecture document six months later cannot tell whether
it was ever true. One `git rev-parse HEAD', bounded and guarded the way
IGNORED-PATHS is, and NIL with a reason when git cannot answer -- not a
repository, no git, a tree with no commits yet. A known gap beats a fabricated
commit, and a tree with no commits is exactly the case REQ-0025's first open
question is about."
  (handler-case
      (multiple-value-bind (out err status)
          (uiop:run-program (list "timeout"
                                  (princ-to-string *ignore-query-timeout-seconds*)
                                  "git" "-C" (namestring (repository-root repository))
                                  "rev-parse" "HEAD")
                            :output :string :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (if (zerop status)
            (values (string-trim '(#\Newline #\Return #\Space) out) nil)
            (values nil (if (eql status 124)
                            "git rev-parse timed out"
                            (format nil "git rev-parse exited ~a" status)))))
    (error (condition) (values nil (princ-to-string condition)))))

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
they have the real file open.

Skips what git ignores, which is DES-0018 and the reason BUG-0024 was opened:
node_modules is not dot-prefixed, so a vendored dependency tree was walked like
source. The ignore query runs once for the whole candidate list and after
ANALYZABLE-P rather than before -- most of a node_modules tree is JavaScript no
analyzer currently claims, so filtering by analyzer first cuts what git is
asked about from thousands to hundreds.

A tree git cannot answer for -- not a repository, no git, a timeout -- is
indexed whole, and the reason is recorded on the repository for `status' to
report. That is a gap a reader can see rather than a silent clean."
  (let* ((root (repository-root repository))
         (claimed (remove-if-not
                   (lambda (path)
                     (and (pathname-name path)
                          (not (dot-prefixed-p (file-namestring path)))
                          (notany #'dot-prefixed-p (rest (pathname-directory path)))
                          (analyzable-p path)))
                   (directory (merge-pathnames "**/*.*" root)))))
    (multiple-value-bind (ignored reason)
        (ignored-paths root (mapcar (lambda (p) (workspace-relative-path p root))
                                    claimed))
      (setf (repository-ignore-reason repository) reason)
      (if (zerop (hash-table-count ignored))
          claimed
          (remove-if (lambda (path)
                       (gethash (workspace-relative-path path root) ignored))
                     claimed)))))

(defun note-error (repository path condition)
  "Record CONDITION against PATH on REPOSITORY, newest first.

A plist and not a `(cons path message)`, which is what this recorded until
BUG-0030 D2. REPOSITORY-STATUS puts the first entry on :LAST-ERROR, that plist
is serialized for every REST and MCP caller, and JSON-VALUE reaches a dotted
pair through its LISTP clause and hands an improper list to LENGTH or to MAP.
Both signal `The value <message> is not of type LIST` -- and the entry stays on
REPOSITORY-ERRORS, so every later `status` re-encoded the same cons and
re-signalled until the process was restarted. A plist is what the rest of this
codebase carries structured values in and what JSON-OBJECT-FROM-PLIST already
encodes."
  (push (list :path (princ-to-string path) :message (princ-to-string condition))
        (repository-errors repository))
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
are load-bearing for the same kind of reason (DES-0002). A definer macro's
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
      (submit "resolve-definitions"    (resolve-definitions graph :workspace-id workspace
                                                                 :external-packages
                                                                 (external-package-exports)))
      ;; Then the generated definitions, before RESOLVE-CALLS: a macro call
      ;; site mints an entity carrying the names its argument list invokes, and
      ;; a pass that has not run yet has nothing for the next one to resolve.
      ;;
      ;; *MACRO-GENERATORS* is handed in rather than reached for. loom-graph
      ;; depends on loom-ontology alone and RULE-0001 to RULE-0003 keep it
      ;; that way, so the pass cannot see the analyzer's table -- and this is
      ;; the first system that uses both packages, which is exactly the job
      ;; this one exists to do.
      ;;
      ;; The registry is per repository since DES-0025 D4: FRAMEWORKS-REGISTRY
      ;; returns *MACRO-GENERATORS* plus whatever this tree declared in
      ;; .loom/frameworks.yaml, in a fresh table. game-server declaring
      ;; easy-routes:defroute must not make Loom's own tree start looking for
      ;; one, which is exactly what pushing into the global would do.
      (submit "resolve-generated-definitions"
              (resolve-generated-definitions graph :workspace-id workspace
                                                   :registry (repository-registry repository)
                                                   :external-packages
                                                   (external-package-exports)))
      ;; EXTERNAL-PACKAGES is handed in for the same reason *MACRO-GENERATORS*
      ;; above is: loom-graph depends on loom-ontology alone, so it cannot see
      ;; the analyzer's table -- and what COMMON-LISP exports is a fact about a
      ;; language, which DES-0012 puts in an analyzer and CON-0005 keeps out
      ;; of the writer. This system is the one that may know both.
      (submit "resolve-calls"          (resolve-calls graph :workspace-id workspace
                                                            :external-packages
                                                            (external-package-exports)))
      ;; And RESOLVE-TESTS after RESOLVE-CALLS, which is the second half of why
      ;; this sequence is load-bearing rather than merely tidy: coverage is
      ;; derived from the :CALLS edges a test's body produced, so a pass that
      ;; has not run yet leaves every test covering nothing.
      (submit "resolve-tests"          (resolve-tests graph :workspace-id workspace))
      (submit "resolve-document-links" (resolve-document-links graph :workspace-id workspace))
      ;; After RESOLVE-DOCUMENT-LINKS and before the rules, because it writes a
      ;; property that same pass's siblings read, and because a rule check is a
      ;; query over the finished graph. It takes the repository rather than the
      ;; graph -- the only pass here that does -- since the question it asks is
      ;; about the disk (BUG-0027).
      (submit "check-document-links"   (check-document-links repository
                                                             :workspace-id workspace))
      (submit "check-rules"            (violation-ops graph :workspace-id workspace)))))

(defun repository-registry (repository)
  "The generator registry this repository's resolution passes should use.

*MACRO-GENERATORS* when it declared nothing, which is every tree Loom indexed
before DES-0025. Otherwise a fresh table holding the shipped entries plus its
own -- fresh so that two watched repositories cannot teach each other their
frameworks, which is the whole reason this is a function rather than a
REGISTER-MACRO-GENERATOR call at startup."
  (let ((frameworks (repository-frameworks repository)))
    (if frameworks
        (frameworks-registry frameworks)
        *macro-generators*)))

(defun index-repository (repository &key quiet)
  "Analyze every analyzable file, then resolve and check.

SS3.4: \"Because files are truth, this is always available and always correct,
and its only cost is time.\"

Locked for its whole body (DES-0004 R3). It wraps itself rather than relying
on REINDEX-REPOSITORY's lock because it is a real independent entry point:
WATCH-REPOSITORY calls it directly on first registration, before any monitor
thread exists."
  (with-repository-lock (repository)
    (let ((files (repository-files repository))
          (indexed 0))
      (unless quiet
        (format t "~&Indexing ~a (~d files)...~%" (repository-name repository) (length files)))
      ;; Before the files, not after: RESOLVE-AND-CHECK reads the registry this
      ;; builds, and re-reading here rather than at registration is what makes
      ;; an edit to .loom/frameworks.yaml take effect on a reindex.
      (setf (repository-frameworks repository)
            (read-frameworks (repository-root repository)))
      ;; DES-0025 D1. Bound around this repository's files and nothing else, so
      ;; front-end's `sendGet' convention cannot make another watched tree read
      ;; its own string literals as routes.
      (let ((*route-callers* (getf (repository-frameworks repository) :route-callers)))
        (dolist (path files)
          (when (index-file repository path :quiet quiet) (incf indexed))))
      (resolve-and-check repository :quiet quiet)
      (setf (repository-file-count repository) indexed
            (repository-indexed-at repository) (get-universal-time))
      ;; DES-0025. Outside RESOLVE-AND-CHECK because it is not a pass over this
      ;; repository: it re-derives every cross-repository edge everywhere, which
      ;; is how a retraction here cannot leave a dangling edge there (REQ-0027
      ;; R2). Last, because it reads the graph this function has just finished
      ;; building. Deferred through a function cell so loom-workspace's own load
      ;; order does not have to put federate.lisp before this file.
      (federate-after-index repository :quiet quiet)
      indexed)))

(defun federate-after-index (repository &key quiet)
  "Re-derive cross-repository edges, if federation is loaded.

Split out and guarded so INDEX-REPOSITORY does not name a function defined in
a later component. A single watched repository still pays one claim scan that
finds nothing to pair with, which is cheap and unconditional on purpose --
guarding on a repository count would mean the pass behaves differently the
first time a second tree is watched."
  (declare (ignorable repository quiet))
  (let ((federate (and (find-package :loom-workspace)
                       (find-symbol "FEDERATE-REPOSITORIES" :loom-workspace))))
    (when (and federate (fboundp federate))
      (funcall federate :quiet quiet))))

(defun reindex-repository (repository &key quiet)
  "Discard the index and rebuild it from disk.

SS3.2: \"Always safe, because files are truth; the escape hatch for any
suspected divergence.\" A fresh graph rather than a cleared one, so nothing
from the old index can survive by accident.

The graph swap and the stamp clear are inside the lock, not merely the nested
INDEX-REPOSITORY call (DES-0004 R3). BUG-0004's CAUSE names the clrhash as
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
;;;; Enrichment (DES-0011)
;;;; ==================================================================
;;;;
;;;; The second pass, and the second thing this system exists to own an
;;;; ordering for. It is not part of the pipeline above and nothing on a timer
;;;; calls it: a run loads the whole target in a fresh process, seconds to
;;;; minutes, where a poll cycle is designed to cost milliseconds. DES-0008 is
;;;; the precedent and BUG-0008 is the trap -- a heavyweight lifecycle
;;;; operation wired into a path that runs on a clock.
;;;;
;;;; What makes that affordable is that an un-rerun pass is never wrong, only
;;;; old: image facts carry an origin file like every other fact, so
;;;; RETRACT-FILE ages them out as their files are edited and the index
;;;; degrades toward today's text index rather than keeping a claim nobody
;;;; re-verified.

(defparameter *enrichment-count-keys*
  '(:confirmed :added :dropped-no-location :dropped-not-under-root
    :dropped-unknown-kind :edges-confirmed :edges-added :edges-dropped)
  "The ENRICH-OPS report keys that are counts, and so can be summed across
inspectors. Named once because a key missing from this list would be silently
dropped from a multi-inspector report rather than mis-added.")

(defun add-enrichment-counts (accumulated report)
  "The element-wise sum of two ENRICH-OPS reports. NIL is the empty sum."
  (loop for key in *enrichment-count-keys*
        append (list key (+ (or (getf accumulated key) 0)
                            (or (getf report key) 0)))))

(defun repository-languages (repository)
  "Every language the index has :FILE facts for."
  (remove-duplicates
   (remove nil (mapcar (lambda (file) (getp file :language))
                       (entities-of-type (repository-graph repository) :file)))))

(defun inspectors-for-repository (repository inspectors)
  "Two values: the inspectors to run, and the absences to record.

INSPECTORS overrides the registry entirely, which is what lets a caller ask one
toolchain and a test run a stub. Otherwise every language the index has facts
for is looked up, and a language with no inspector is REQ-0018 R2's recorded
absence -- reported with a reason, never as an error, and never as silence."
  (if inspectors
      (values inspectors '())
      (let ((found '())
            (absent '()))
        (dolist (language (repository-languages repository))
          (let ((candidates (find-inspectors language)))
            (if candidates
                (setf found (append found candidates))
                (push (list :language language
                            :reason (format nil "no inspector for ~(~a~)" language))
                      absent))))
        (values found (nreverse absent)))))

(defun enrich-repository (repository &key quiet inspectors)
  "Ask each language's toolchain to enrich the index, and return the report.

The order is a chain of dependencies rather than a preference, exactly as
RESOLVE-AND-CHECK's is:

  find inspectors -> INSPECTOR-AVAILABLE-P -> INSPECT-REPOSITORY
  -> ENRICH-OPS -> APPLY-TRANSACTION -> RESOLVE-AND-CHECK
  -> ENRICH-OPS -> APPLY-TRANSACTION

RESOLVE-AND-CHECK in the middle and not first, which is where the two passes
compose. An image-minted definition is exactly what an unresolved text call
name has been waiting for, so a text-recorded call to a DEFENTITY accessor
becomes a :structural edge in the same run the accessor appears. Running it
first would defer every such edge to the next poll.

The merge again after it, which is BUG-0015 and is explained where it happens
below: resolution re-asserts every text-derivable edge, which clears the
agreement the merge just recorded on the ones both passes see.

Locked for its whole body (DES-0004 R3), for INDEX-REPOSITORY's reason: this
writes to the graph, and a poll running concurrently would interleave two
writers.

CONDITION and not INDEX-FILE's ERROR -- BUG-0014, and RULE-0004 read against
what is actually being guarded: a subprocess, a reader over its output, and a
per-language inspector nobody in this file wrote. The comment on the handler
has the measurement, and the HANDLER-BIND inside it is the other half, since
CONDITION reaches warnings too."
  (with-repository-lock (repository)
    (let* ((started (get-internal-real-time))
           (graph (repository-graph repository))
           (root (repository-root repository))
           (workspace (repository-name repository))
           (previous (repository-enrichment repository))
           (units '())
           (inspections '())
           (counts nil))
      (multiple-value-bind (found absences) (inspectors-for-repository repository inspectors)
        (dolist (inspector found)
          (handler-case
              ;; Inside the guard and around the whole body, so it runs first.
              ;; BUG-0014 widened the guard below to CONDITION, which is right
              ;; for cl-yaml's shape and wrong in the other direction: WARNING
              ;; is a CONDITION too, and HANDLER-CASE unwinds on any match, so
              ;; an inspector that merely calls WARN mid-INSPECT-REPOSITORY
              ;; would have its whole inspection discarded and the warning text
              ;; filed as the reason it was absent. Muffling here keeps the
              ;; guard's RULE-0004 width without treating a warning as fatal.
              (handler-bind ((warning #'muffle-warning))
                (multiple-value-bind (available reason) (inspector-available-p inspector root)
                  (if (not available)
                      (push (list :language (inspector-language inspector) :reason reason)
                            absences)
                      (let ((inspection (inspect-repository inspector root)))
                        (setf units (append units (inspection-units inspection)))
                        (push inspection inspections)
                        (multiple-value-bind (ops report)
                            (enrich-ops graph inspection :workspace-id workspace)
                          (apply-transaction graph ops)
                          ;; The parent refused some definitions a range before
                          ;; ENRICH-OPS ever saw them; both refusals are the same
                          ;; fact to a reader, so they are one count.
                          (incf (getf report :dropped-no-location)
                                (or (getf inspection :dropped-no-location) 0))
                          (setf counts (add-enrichment-counts counts report)))))))
            ;; CONDITION, not SERIOUS-CONDITION -- measured, not assumed.
            ;; RULE-0004's own example is a library that defines its
            ;; conditions as (define-condition foo () ...), a direct subtype
            ;; of CONDITION and of neither ERROR nor SERIOUS-CONDITION; probed
            ;; directly under /usr/bin/sbcl, a HANDLER-CASE naming
            ;; SERIOUS-CONDITION does not catch an instance of such a type
            ;; even when it is signalled with ERROR the function, because
            ;; HANDLER-CASE matches on the condition's own class and not on
            ;; how it was raised. "A per-language inspector nobody in this
            ;; file wrote" is exactly RULE-0004's case, so the guard has to be
            ;; RULE-0004's "or wider": CONDITION, the only type a
            ;; hand-written inspector cannot fail to be an instance of.
            (condition (condition)
              (note-error repository "enrich" condition)
              (unless quiet
                (format *standard-output* "~&  ! enrich: ~a~%" condition))
              (push (list :language (inspector-language inspector)
                          :reason (princ-to-string condition))
                    absences))))
        (resolve-and-check repository :quiet quiet)
        ;; BUG-0015, and the reason the merge runs twice rather than once.
        ;; RESOLVE-AND-CHECK's RESOLVE-CALLS re-derives every text-derivable
        ;; :CALLS edge and re-asserts it through ASSERT-EDGE, which takes no
        ;; properties and defaults :SOURCE to :STRUCTURAL -- so the absorb that
        ;; lands on a confirmed edge CLRHASHes the :SOURCES union the merge just
        ;; wrote, and DES-0011 R6 is inert for the majority case. Measured
        ;; before this line existed: source=:INTROSPECTED sources=(:STRUCTURAL
        ;; :INTROSPECTED) after the merge, source=:STRUCTURAL sources=NIL after
        ;; resolution.
        ;;
        ;; RESOLVE-CALLS is not the thing to change. Rebuilding its whole output
        ;; on every run is DEC-0003's derive-never-consume, and it is what lets
        ;; an edge a retract destroyed come back at all; teaching it about
        ;; provenance would trade that away for this. So the merge is re-derived
        ;; against the graph resolution left behind. Re-derived rather than
        ;; re-applied: the ops hold relationship instances, and re-applying an
        ;; instance the graph already stores would absorb it onto itself and
        ;; CLRHASH its own table.
        ;;
        ;; The second run adds nothing new by construction -- every definition
        ;; it names is now present, so it emits no ASSERT-ENTITY -- and computes
        ;; the same union it computed the first time, because the edge it reads
        ;; is the :STRUCTURAL edge resolution has just restored. That stability
        ;; is what makes this a second transaction rather than two passes
        ;; fighting.
        (dolist (inspection inspections)
          (apply-transaction graph (enrich-ops graph inspection
                                               :workspace-id workspace)))
        (setf (repository-enrichment repository)
              (append (list :runs (1+ (or (getf previous :runs) 0))
                            :at (get-universal-time)
                            :duration (/ (- (get-internal-real-time) started)
                                         internal-time-units-per-second)
                            :units units
                            :absences (nreverse absences))
                      (or counts (add-enrichment-counts nil nil))))))))

(defun enrichment-unit-count (report status)
  (count status (getf report :units) :key (lambda (unit) (getf unit :status))))

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
mutating tail (DES-0004 R3). The FILE-CHANGED-P loop reads REPOSITORY-STAMPS,
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
          (resolve-and-check repository :quiet quiet)
          ;; DES-0007: until this line, INDEX-REPOSITORY (line 241) was the
          ;; only writer of this slot, so REPOSITORY-STATUS reported "last
          ;; indexed" as the time of the last explicit watch or reindex, and a
          ;; caller comparing it against a process start time would read
          ;; "current" for a tree the monitor had silently absorbed a dozen
          ;; edits from -- CON-0001's fabricated fact, arrived at by omission.
          ;; Inside the `when` and not above it: the slot means "when this
          ;; index last changed", so a poll that found nothing must leave it
          ;; alone. `now' rather than a fresh GET-UNIVERSAL-TIME, because it is
          ;; the instant the change was observed at.
          (setf (repository-indexed-at repository) now)))
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

(defun count-file-regions (graph property)
  "How many regions PROPERTY records across every :FILE entity in GRAPH.

Regions rather than files: two suppressed branches in one file are two things
a reader might go and look at, and reporting it as one file would hide the
second. The analyzer writes the property only when it has something to say, so
a file with nothing to report contributes nothing rather than an empty list."
  (loop for file in (entities-of-type graph :file)
        sum (length (getp file property))))

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
                        (length (entities-of-type graph :design))
                        (length (entities-of-type graph :architecture))
                        (length (entities-of-type graph :rule))
                        (length (entities-of-type graph :concept))
                        (length (entities-of-type graph :document)))
          ;; DES-0002 R10, following the precedent :DOCUMENTS set: a named sum
          ;; rather than a raw total. These three are the console-readable
          ;; acceptance check for the whole of DES-0002 -- fiveam's TEST and
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
          ;; analyzer owns (DES-0002 R1).
          :unhandled-definer-macros
          (+ (length (unhandled-definer-macros graph))
             (length (generated-definition-collisions graph *macro-generators*)))
          ;; DES-0018 D5: NIL on a healthy tree, so `status' prints nothing.
          :ignore-reason (repository-ignore-reason repository)
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
          ;; DES-0011 R8, and four scalars rather than the report itself. The
          ;; constraint is not style: loom-serve's :STATUS operation
          ;; (src/serve/operations.lisp) serializes this plist to JSON for REST
          ;; and MCP callers, no rule covers that boundary and no impact query
          ;; reports it, and a nested plist is the shape most likely to
          ;; serialize into something a client cannot read. The report itself is
          ;; on the repository for the console to print.
          ;;
          ;; :ENRICHMENT-AT is what tells "never run" from "run and found
          ;; nothing"; the three counts are always numbers, on DES-0002 R10's
          ;; precedent that a count which vanishes when it is nought cannot be
          ;; told from a count nobody computed.
          :enrichment-runs (or (getf (repository-enrichment repository) :runs) 0)
          :enriched-units (enrichment-unit-count
                           (repository-enrichment repository) :loaded)
          :enrichment-gaps (+ (enrichment-unit-count
                               (repository-enrichment repository) :failed)
                              (length (getf (repository-enrichment repository)
                                            :absences)))
          :enrichment-at (getf (repository-enrichment repository) :at)
          ;; DES-0013, PLAN-0013 step 5. Two scalars, for the reason the
          ;; enrichment block above gives: this plist is serialized to JSON for
          ;; REST and MCP callers, so a count travels where a nested region
          ;; list would not. The regions themselves are on the :FILE entities,
          ;; which is where a reader who wants the line numbers goes.
          ;;
          ;; Always numbers, never absent when nought, on the same DES-0002
          ;; R10 precedent: zero suppressed regions and an indexer that never
          ;; looked are different facts, and a vanishing count conflates them.
          ;; Both read zero on this tree, which is what makes them a regression
          ;; guard as well as a report -- the day one moves, a definition
          ;; stopped being indexed and this is the only place that says so.
          :suppressed-regions (count-file-regions graph :suppressed-regions)
          :recovered-regions (count-file-regions graph :recovered-regions)
          ;; BUG-0030 F1, and beside the two counts above for the reason
          ;; their comment gives: an edge the ontology would not permit is a
          ;; relationship the index knows it is missing. Zero on all three
          ;; watched trees, and unconditional so that zero can be read.
          :dropped-edges (dropped-edge-count graph)
          :errors (length (repository-errors repository))
          :last-error (first (repository-errors repository)))))

;;;; ==================================================================
;;;; Link targets against the filesystem (BUG-0027)
;;;; ==================================================================
;;;;
;;;; The one check in the pipeline that asks the disk rather than the index,
;;;; and it lives here because this is the layer that knows a repository has a
;;;; root. loom-graph resolves names against entities and has no filesystem;
;;;; an analyzer has neither and must not acquire either (SS8.1).
;;;;
;;;; The distinction is not pedantry, it is the difference between a report and
;;;; a fabrication. A link target that does not resolve in the index has not
;;;; been shown to be broken: game-server links to CLAUDE.md, which REQ-0028
;;;; excludes by name, and to data-api/sql/test.sql, which no analyzer claims.
;;;; Both files are present. Reporting them as broken would put five confident
;;;; falsehoods in front of a reader alongside the two real findings, which is
;;;; how a staleness report stops being read.

(defun check-document-links (repository &key workspace-id)
  "Operations recording, per document, the link targets that name no file.

Existence on disk, not presence in the index. A document may legitimately link
to a licence, a .sql fixture, a CLAUDE.md -- things Loom does not index and has
no opinion about. What it may not do is link to nothing."
  (let ((graph (repository-graph repository))
        (root (repository-root repository))
        (ops '()))
    (dolist (type *document-types*)
      (dolist (document (entities-of-type graph type))
        (let ((targets (getp document :link-targets)))
          ;; Only documents that carry link targets are touched, so a YAML
          ;; document -- which has none -- keeps whatever it had rather than
          ;; being handed an empty list on every pass.
          (when targets
            (let ((broken (remove-if (lambda (target)
                                       (probe-file (merge-pathnames target root)))
                                     targets)))
              (push (update-properties (id document)
                                       (list :broken-links broken)
                                       workspace-id)
                    ops))))))
    (nreverse ops)))
