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
  ;; REQ-0050 R2. The commit and diff hash of the tree *as the analyzer read
  ;; it*, captured when indexing finishes rather than when a caller asks.
  ;;
  ;; Reading git at request time is the defect this field exists to fix, and
  ;; the first attempt at REQ-0050 R4 made exactly that mistake: a status that
  ;; shells out to `git rev-parse HEAD' when asked reports the tree now, so a
  ;; service whose index is two hours old still answers with today's commit and
  ;; today's diff, and a harness comparing the two sees agreement. Three things
  ;; move independently -- the commit, the working tree, the index -- and only
  ;; a value recorded at index time speaks for the third.
  (indexed-fingerprint nil)
  (file-count 0)
  ;; REQ-0050 R3. How many claimed files had no stamp the last time something
  ;; walked the tree. Recorded there rather than computed on demand because the
  ;; walk is REPOSITORY-FILES -- a recursive directory scan plus a `git
  ;; check-ignore' subprocess -- and asking for it per query made `status' over
  ;; nine repositories take 8.9 seconds, front-end alone 7.1 of them.
  ;;
  ;; NIL until something has walked, which is a recorded gap rather than a
  ;; zero: nought means "the walk found none" and nobody may read it as
  ;; "nobody has looked".
  (unindexed nil)
  ;; REQ-0059. What the tree holds that no analyzer claims, as a plist --
  ;; :COUNT, :BY-EXTENSION, and :REASON when git could not be asked. NIL until
  ;; something has walked, for the same reason UNINDEXED is: nought means the
  ;; walk found none, and nobody may read it as nobody having looked.
  (unclaimed nil)
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
  ;; The vector sidecar for this repository, DEC-0006. :UNLOADED until first
  ;; asked for, then the store or NIL. Cached because LOAD-VECTOR-STORE reads
  ;; 5 MB off disk and a context query must not do that per call, and marked
  ;; rather than left NIL so that "there is no store" is looked up once too.
  (cached-vectors :unloaded)
  ;; The thread building this repository's vector store, or NIL. A query that
  ;; wants the store waits on it rather than answering without one, which is
  ;; the whole reason the build is a thread and not a blocking call: the
  ;; launcher starts it and returns, and the wait -- if there is one at all --
  ;; is paid by whoever asks first.
  (vector-build nil)
  ;; The thread building this repository's graph, or NIL. Same shape and same
  ;; reason as VECTOR-BUILD one slot up: the listener binds its port before any
  ;; tree has been read, and a reader waits for the index rather than being
  ;; answered from an empty one.
  (index-build nil)
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

(define-condition unknown-domain (loom-utils:refusal) ()
  (:documentation "A designator named a domain the repository does not declare."))

(defun split-designator (designator)
  "DESIGNATOR as a repository and a domain, or a repository and NIL.

  (split-designator \"front-end/server\")  => repository, the server domain plist
  (split-designator \"front-end\")         => repository, NIL

The whole designator is looked up first, and only split when that finds
nothing. That ordering is the whole correctness of this function, not a
refinement. A repository is addressable by its path as well as its name, and
every path has slashes in it: splitting first would turn
\"/home/beberman/lisp/Loom\" into a repository named \"/home/beberman/lisp\"
and a domain named \"Loom\", and the path spelling the console encourages --
`unwatch \"~/lisp/Loom\"' -- would stop working.

Split at the LAST slash, and both halves must be non-empty.

An unknown domain is refused, naming what the repository does declare. That
refusal is why the lookup happens before the name is interned: a typo must not
add a keyword to the image, and the caller gets told what they could have
written.

Returns NIL for the repository when the designator names none, leaving the
caller to refuse in its own words -- the callers already have a message for
that and it is not this function's to duplicate."
  (let ((whole (find-repository designator)))
    (if whole
        (values whole nil)
        (let ((slash (position #\/ designator :from-end t)))
          (if (or (null slash) (zerop slash) (= slash (1- (length designator))))
              (values nil nil)
              (let* ((name (subseq designator 0 slash))
                     (domain-name (subseq designator (1+ slash)))
                     (repository (find-repository name)))
                (if (null repository)
                    (values nil nil)
                    (let* ((domains (repository-domains repository))
                           (declared (and domains
                                          (loop for key being the hash-keys of domains
                                                unless (eq key *default-domain*)
                                                  collect key))))
                      (let ((match (find domain-name declared
                                         :test (lambda (text key)
                                                 (string-equal text (symbol-name key))))))
                        (if match
                            (values repository (gethash match domains))
                            (error 'unknown-domain
                                   :message
                                   (if declared
                                       (format nil "~a declares no domain ~s. It declares ~{~(~a~)~^, ~}."
                                               (repository-name repository) domain-name
                                               (sort (mapcar #'symbol-name declared) #'string<))
                                       (format nil "~a declares no domains at all, so ~s names nothing. Add a domains: section to .loom/frameworks.yaml."
                                               (repository-name repository) domain-name)))))))))))))

(defun all-repositories () (reverse *repositories*))

;;;; ==================================================================
;;;; Indexing (SS3.4)
;;;; ==================================================================

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

(defun git-output (root &rest arguments)
  "Two values: what git printed for ARGUMENTS in ROOT, and why it could not.

One shape for every git question Loom asks, bounded by `timeout\' and guarded,
the way IGNORED-PATHS established and REPOSITORY-COMMIT followed. NIL and a
recorded reason when git cannot answer -- not a repository, no git, a tree with
no commits yet -- because a known gap beats a fabricated commit (CON-0001)."
  (handler-case
      (multiple-value-bind (out err status)
          (uiop:run-program (append (list "timeout"
                                          (princ-to-string *ignore-query-timeout-seconds*)
                                          "git" "-C" (namestring root))
                                    arguments)
                            :output :string :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (if (zerop status)
            (values out nil)
            (values nil (if (eql status 124)
                            (format nil "git ~a timed out" (first arguments))
                            (format nil "git ~a exited ~a" (first arguments) status)))))
    (error (condition) (values nil (princ-to-string condition)))))

(defun git-commit (root)
  "Two values: ROOT's HEAD commit, and why it could not be read."
  (multiple-value-bind (out reason) (git-output root "rev-parse" "HEAD")
    (if out
        (values (string-trim '(#\Newline #\Return #\Space) out) nil)
        (values nil reason))))

(defun git-branch (root)
  "Two values: the branch ROOT has checked out, and why it could not be read.

A detached HEAD answers \"HEAD\", which is what git prints and is the honest
answer rather than NIL: the tree is on no branch and saying so is a fact."
  (multiple-value-bind (out reason)
      (git-output root "rev-parse" "--abbrev-ref" "HEAD")
    (if out
        (values (string-trim '(#\Newline #\Return #\Space) out) nil)
        (values nil reason))))

(defun fnv-1a (text)
  "A 64-bit FNV-1a hash of TEXT, as sixteen hex digits.

Deterministic across images, which SXHASH is not, and needing no library.
DES-0030 D4: this identifies a working state so that two records can be
compared, and is not a security claim about anything."
  (let ((hash 14695981039346656037))
    (loop for char across text
          do (setf hash (ldb (byte 64 0)
                             (* (logxor hash (ldb (byte 8 0) (char-code char)))
                                1099511628211))))
    (format nil "~(~16,'0x~)" hash)))

(defun clean-diff-hash ()
  "What GIT-DIFF-HASH answers for a tree with nothing uncommitted.

REQ-0050 R1. GIT-DIFF-HASH hashes the output of `git diff HEAD\', and an empty
diff hashes to the hash of the empty string -- its docstring states that as the
convention rather than returning NIL for a clean tree. This is that convention
made callable, so a surface can say `and the tree had uncommitted edits\'
instead of printing sixteen hex digits nobody can compare by eye.

A function rather than a constant so it reads as the one arithmetic
GIT-DIFF-HASH does, rather than as a magic string beside it."
  (fnv-1a ""))

(defun git-diff-hash (root)
  "Two values: a hash of ROOT\'s uncommitted changes, and why it could not be
read.

The commit alone would attribute a judgement to code that was not what answered
it: a tree under active work is dirty for most of the sessions that produce
these records. An empty diff hashes to the hash of the empty string, which is a
clean tree and is reported as such rather than as NIL."
  (multiple-value-bind (out reason) (git-output root "diff" "HEAD")
    (if out (values (fnv-1a out) nil) (values nil reason))))

(defun repository-commit (repository)
  "Two values: REPOSITORY\'s HEAD commit, and why it could not be read.

DES-0022 D5. A structural report has to name the tree it described, or a reader
meeting a generated architecture document six months later cannot tell whether
it was ever true."
  (git-commit (repository-root repository)))

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

(defun tracked-paths (root)
  "Every path git tracks under ROOT, relative, or NIL and a reason.

`git ls-files\' rather than a walk plus `check-ignore\'. Tracked is the
question REQ-0059 asks -- a build directory is not a gap in coverage -- and it
is one subprocess answering directly instead of the walk-then-filter order
REPOSITORY-FILES has to use, which its own docstring says exists to keep git
from being asked about thousands of paths.

Bounded and status-tolerant on IGNORED-PATHS\' terms, and for its reasons: a
tree git cannot answer for is a known unknown, and the caller reports the
reason rather than a zero that reads like a clean answer."
  (handler-case
      (multiple-value-bind (out err status)
          (uiop:run-program (list "timeout"
                                  (princ-to-string *ignore-query-timeout-seconds*)
                                  "git" "-C" (namestring root) "ls-files")
                            :output :string :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (cond ((= status 124) (values nil "git ls-files timed out"))
              ((/= status 0) (values nil "not a git repository"))
              (t (values (remove "" (uiop:split-string out :separator '(#\Newline))
                                 :test #'string=)
                         nil))))
    (error (condition)
      (values nil (format nil "git could not be run: ~a" condition)))))

(defparameter *occurrence-limit* 12
  "How many textual occurrences a zero-hit `find' lists before it says it cut.

Twelve rather than the twenty `find' itself uses for entities. These are lines
rather than definitions, a caller reads them to decide whether the term is
worth grepping for properly, and the count that follows is what makes a short
list honest -- REQ-0054 R3.")

(defun textual-occurrences (root term &key (limit *occurrence-limit*))
  "Lines under ROOT whose text contains TERM, as a plist, or a reason for none.

REQ-0054. `find term=osm-import' against front-end answered
`{\"entities\":[],\"total\":0}' -- the same answer it gives for a name that
exists nowhere, though the string is a route the router declares, the mock
posts to and a comment explains. Two absences with opposite next moves, told
apart by nothing.

`git grep' rather than the `:mentions' edges, and the acceptance is what
settles it: those edges carry a markdown file's backticks and a document's
prose, and two of this case's three occurrences are a string literal and a
source comment, which no analyzer asserts anything about. Reading files answers
all three.

-F because a term is a name and not a pattern -- `a.b' must not match `axb' --
and -I because a match inside a binary is not something a reader can act on.
The `--' guards a term that begins with a dash.

The lines are under :LINES rather than a second :OCCURRENCES, and the name is
load-bearing: the encoder decides an empty list from an empty object by key
(*ARRAY-VALUED-KEYS*), so a plist whose own key repeats its caller's is emitted
as a flattened array. Measured before this was renamed -- the REST answer came
back as a flattened array beginning with the key name.

Bounded and status-tolerant on IGNORED-PATHS' terms: exit 1 is git's ordinary
`no matches', which must not read as a failure, and a tree git cannot answer
for gets a reason rather than an empty list that looks like an answer."
  (handler-case
      (multiple-value-bind (out err status)
          (uiop:run-program (list "timeout"
                                  (princ-to-string *ignore-query-timeout-seconds*)
                                  "git" "-C" (namestring root)
                                  "grep" "-n" "-F" "-I" "--" term)
                            :output :string :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (cond
          ((= status 124)
           (list :lines '() :total nil :truncated nil
                 :reason "git grep timed out"))
          ((> status 1)
           (list :lines '() :total nil :truncated nil
                 :reason "not a git repository"))
          (t
           (let* ((lines (remove "" (uiop:split-string out :separator '(#\Newline))
                                 :test #'string=))
                  (total (length lines))
                  (shown (subseq lines 0 (min limit total))))
             (list :lines (remove nil (mapcar #'parse-grep-line shown))
                   :total total
                   :truncated (> total limit)
                   :reason nil)))))
    (error (condition)
      (list :lines '() :total nil :truncated nil
            :reason (format nil "git could not be run: ~a" condition)))))

(defun parse-grep-line (line)
  "One `path:line:text' from git grep, as a plist, or NIL if it is not one.

The text half is taken from the second colon onward rather than by splitting,
because source lines contain colons and a split would truncate exactly the
lines worth reading. Trimmed, because leading indentation is most of a nested
line and carries nothing here."
  (let* ((first-colon (position #\: line))
         (second-colon (and first-colon (position #\: line :start (1+ first-colon)))))
    (when second-colon
      (let ((number (ignore-errors
                     (parse-integer line :start (1+ first-colon) :end second-colon))))
        (when number
          (list :file (subseq line 0 first-colon)
                :line number
                :text (string-trim '(#\Space #\Tab)
                                   (subseq line (1+ second-colon)))))))))

(defun unclaimed-summary (repository files)
  "What REPOSITORY tracks that no analyzer claims, as a plist.

REQ-0059 R1 and R2. `status\' reports FILES, UNINDEXED and UNPARSED, and all
three are counts about *claimed* files: a language nobody analyzes is in none
of them, so a tree can be 88% covered and say nothing about the rest. Measured
on Loom 2026-08-28: 424 tracked files, 376 claimed, and the 48 in the gap
include the nine Python files of tools/test/ -- the harness that measures Loom
is the part of the tree Loom cannot answer questions about.

The extensions are counted rather than the paths listed, because the answer a
reader acts on is which languages are missing, and a list of 48 paths on every
`status\' is a page. R2\'s own example is the shape: `48 unclaimed: 9 .py,
5 .sh, 34 other\'.

FILES is REPOSITORY-FILES\' output, which is the claimed set after the ignore
filter, so this costs one subprocess on top of a walk the caller already paid
for."
  (multiple-value-bind (tracked reason) (tracked-paths (repository-root repository))
    (if reason
        (list :count nil :by-extension '() :reason reason)
        (let* ((root (repository-root repository))
               (claimed (let ((table (make-hash-table :test #'equal)))
                          (dolist (path files table)
                            (setf (gethash (workspace-relative-path path root) table) t))))
               (counts (make-hash-table :test #'equal))
               (total 0))
          (dolist (path tracked)
            (unless (gethash path claimed)
              (incf total)
              (let* ((dot (position #\. (file-namestring path) :from-end t))
                     (type (if (and dot (plusp dot))
                               (string-downcase (subseq (file-namestring path) dot))
                               "(none)")))
                (incf (gethash type counts 0)))))
          ;; Plists rather than an alist, largest first. A dotted pair reaches
          ;; the JSON encoder through its IMPROPER-LIST-P clause and comes out
          ;; as the string "(.py . 9)", which is BUG-0030's shape and unusable
          ;; by a REST or MCP caller -- measured before this was changed.
          (list :count total
                :by-extension (sort (loop for type being the hash-keys of counts
                                            using (hash-value n)
                                          collect (list :type type :files n))
                                    (lambda (a b)
                                      (let ((na (getf a :files)) (nb (getf b :files)))
                                        (or (> na nb)
                                            (and (= na nb)
                                                 (string< (getf a :type)
                                                          (getf b :type)))))))
                :reason nil)))))

(defun count-unstamped (repository files)
  "How many of FILES the index has no stamp for.

The count REQ-0050 R3 wants, taken from a walk somebody was doing anyway. One
hash lookup per file against REPOSITORY-STAMPS, where the walk that produced
FILES is the part that costs anything."
  (let ((stamps (repository-stamps repository))
        (root (repository-root repository)))
    (count-if (lambda (path)
                (null (gethash (workspace-relative-path path root) stamps)))
              files)))

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
                       (sxhash (handler-case (read-file path)
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
        (let* ((contents (read-file path))
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
resolve-generated-definitions, resolve-imports, resolve-calls, resolve-tests,
resolve-document-links, check-document-links, check-rules.

Two of those arrows are not dependencies and the difference is worth keeping.
RESOLVE-IMPORTS before CHECK-RULES is one: RUN-CHECK's :NO-EDGE kind takes
:REL-TYPES, so a rule may name :IMPORTS, and a rule checked before the edges
exist reports no violation and looks enforced. CHECK-RULES was already last, so
satisfying it costs nothing.

RESOLVE-IMPORTS before RESOLVE-CALLS is a preference with a cost. The two
resolve the same specifiers, and building the module scope once rather than
twice is the whole reason RESOLVE-CALLS takes a :MODULE-SCOPE argument."
  (let* ((graph (repository-graph repository))
         (workspace (repository-name repository))
         (domains (repository-domains repository)))
    ;; Built once here, and both values kept: RESOLVE-IMPORTS needs the misses
    ;; and RESOLVE-CALLS needs the scope, and BUILD-MODULE-SCOPE computes them
    ;; together. Empty for a tree of Common Lisp, where MODULE-SCOPED-LANGUAGE-P
    ;; is false for every file, which is why seven of the nine watched trees
    ;; cannot move by anything in this sequence.
    (multiple-value-bind (module-scope unresolved-imports)
        (build-module-scope graph :domains domains)
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
      ;; PLAN-0050 S7. Before RESOLVE-CALLS so the scope is built once, and
      ;; before CHECK-RULES so a rule naming :IMPORTS is checked against edges
      ;; that exist.
      (submit "resolve-imports"        (resolve-imports graph :workspace-id workspace
                                                              :domains domains
                                                              :module-scope module-scope
                                                              :unresolved unresolved-imports))
      (submit "resolve-calls"          (resolve-calls graph :workspace-id workspace
                                                            :module-scope module-scope
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
      (submit "check-rules"            (violation-ops graph :workspace-id workspace))))))

(defun repository-domains (repository)
  "The domain table this repository declared, or NIL when it declared none.

NIL rather than a table holding only :DEFAULT, because DOMAIN-FOR-PATH tests
the special itself: a tree with no declaration should not pay a hash lookup per
file to be told what it already knows.

Beside REPOSITORY-REGISTRY and for its reason -- built per repository from that
repository's own frameworks plist, so two watched trees cannot place each
other's files."
  (let ((domains (getf (repository-frameworks repository) :domains)))
    (when domains (domain-table domains))))

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
      (let ((*route-callers* (getf (repository-frameworks repository) :route-callers))
            ;; PLAN-0050 S3, bound in the same LET and for the same reason: one
            ;; watched tree's declared roots must not place another's paths.
            (*domains* (repository-domains repository)))
        (dolist (path files)
          (when (index-file repository path :quiet quiet) (incf indexed))))
      (resolve-and-check repository :quiet quiet)
      (setf (repository-file-count repository) indexed
            ;; Free here: FILES is the walk already paid for, and a file that
            ;; failed to analyze is a file with no stamp.
            (repository-unindexed repository) (count-unstamped repository files)
            ;; REQ-0059, on the same walk and for the same reason: FILES is the
            ;; claimed set, and what git tracks beyond it is the coverage gap.
            (repository-unclaimed repository) (unclaimed-summary repository files)
            (repository-indexed-at repository) (get-universal-time)
            (repository-indexed-fingerprint repository)
            (index-fingerprint (repository-root repository)))
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
  (prog1
      (with-repository-lock (repository)
        (setf (repository-graph repository) (make-graph))
        (clrhash (repository-stamps repository))
        (setf (repository-errors repository) '())
        (index-repository repository :quiet quiet))
    ;; The graph was discarded and rebuilt, so every entity id in the store is
    ;; one this index has never seen unless the analyzer minted it again. Same
    ;; refresh POLL-ONCE does and for the same reason, outside the lock and only
    ;; for a repository that already has a store.
    (start-vector-build repository :existing-only t)))

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
                            ;; PLAN-0050 S3. loom-workspace is where both
                            ;; systems are reachable, so it is what hands the
                            ;; graph a domain function rather than the graph
                            ;; reaching for one.
                            (enrich-ops graph inspection :workspace-id workspace
                                        :domain-of-path #'domain-for-path)
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
                                               :workspace-id workspace
                                               :domain-of-path #'domain-for-path)))
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
  (let ((moved nil))
   (prog1
    (with-repository-lock (repository)
    (let* ((changed '())
           (now (get-universal-time))
           (files (repository-files repository)))
      (dolist (path files)
        (let ((relative (workspace-relative-path path (repository-root repository))))
          (when (file-changed-p repository relative path now)
            (push path changed))))
      (dolist (path changed) (index-file repository path :quiet quiet))
      ;; After the indexing pass, so what is left is what the analyzer could
      ;; not stamp rather than what this poll was about to read. REQ-0050 R3,
      ;; and free: FILES is the walk this poll already pays for.
      (setf (repository-unindexed repository) (count-unstamped repository files)
            (repository-unclaimed repository) (unclaimed-summary repository files))
      (let ((removed (detect-deletions repository)))
        (when (or changed removed)
          (setf moved t)
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
          (setf (repository-indexed-at repository) now
                (repository-indexed-fingerprint repository)
                (index-fingerprint (repository-root repository)))))
      (length changed)))
    ;; Outside the lock, and only when something actually moved. A store the
    ;; index has outgrown answers queries with vectors for definitions that no
    ;; longer exist and none for the ones that do -- stale in the one way that
    ;; does not announce itself, because a cosine against an old vector is a
    ;; perfectly ordinary number.
    ;;
    ;; EXISTING-ONLY, so a tree nobody has embedded does not acquire a store
    ;; because somebody saved a file in it. Refreshing is what a poll may do;
    ;; building is what `embed' is for.
    ;;
    ;; Outside the lock because the build reads the graph for minutes and the
    ;; monitor must not be parked behind it. Cheap when nothing of substance
    ;; changed: UPDATE-VECTOR-STORE re-embeds a document rather than an entity,
    ;; and a function body rewritten line by line has the same name and the same
    ;; docstring, so the commonest edit in a working tree reaches the embedder
    ;; not at all.
    (when moved
      (start-vector-build repository :existing-only t)))))

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
  "SLEEP, in slices, abandoned as soon as REPOSITORY is asked to stop."
  (sleep-until seconds (lambda () (repository-stopping repository))))

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

(defparameter *index-build-wait* 0
  "Seconds a reader waits for an index still being built before reporting it.

Zero: a request for a repository that is still indexing is answered at once
with REPOSITORY-INDEXING rather than held. A caller that would rather block
binds this.

Refusing rather than answering is the part that is not negotiable, and the
choice between refusing and waiting is a separate one. An empty graph is not a
slow answer, it is a confident wrong one -- `find\' would report that nothing
matches and `context\' would return an empty bundle, both indistinguishable
from the truthful versions of themselves. CON-0001 refuses that trade whichever
way this number goes.

What settles it at zero is the caller. Over MCP a wait is an agent holding a
tool call with no way to tell whether anything is happening; a message it can
read costs one round trip and says what to do next. Over REST the same, with a
client that can poll `status\'.")

(defun await-repository-index (repository &optional (seconds *index-build-wait*))
  "Wait for REPOSITORY's index if one is being built. True when none is left."
  (await-thread (repository-index-build repository) seconds))

(defun watch-repository (path &key (monitor t) quiet background)
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
          ;; BACKGROUND registers the repository and returns before it holds
          ;; anything. loom-serve.lisp uses it so the listener binds its port
          ;; while the trees are still being read: nine repositories index in
          ;; about twenty seconds today and that number only grows, and a
          ;; launcher that waits for it turns "start Loom" into dead time on
          ;; the one path everybody walks.
          ;;
          ;; What makes it safe is that nobody reads a half-built graph.
          ;; REQUIRE-REPOSITORY waits, so a query arriving during the build
          ;; blocks and then answers correctly rather than answering at once
          ;; and wrongly.
          (if background
              (setf (repository-index-build repository)
                    (bordeaux-threads:make-thread
                     (lambda ()
                       (handler-case
                           (progn (index-repository repository :quiet quiet)
                                  (when monitor (start-monitor repository))
                                  ;; BUG-0048. The vector build hangs off the
                                  ;; end of the index build rather than off an
                                  ;; HTTP call racing it. tools/loom-serve.sh
                                  ;; POSTs /v1/embed for every repository as
                                  ;; soon as the listener answers, which is
                                  ;; about two seconds in; *INDEX-BUILD-WAIT*
                                  ;; is 0, so REQUIRE-REPOSITORY refused eight
                                  ;; of nine of those with "still being
                                  ;; indexed" and nothing retried. Measured on
                                  ;; a boot: one of nine stores was refreshed,
                                  ;; and five had not been touched in an hour.
                                  ;;
                                  ;; EXISTING-ONLY, so this refreshes a store
                                  ;; somebody built and never builds a first
                                  ;; one. Building is minutes of embedder time
                                  ;; and stays opt-in through `embed'.
                                  (start-vector-build repository
                                                      :existing-only t))
                         (serious-condition (condition)
                           (note-error repository (namestring root) condition))))
                     :name (format nil "loom-index-~a" (repository-name repository))))
              (progn (index-repository repository :quiet quiet)
                     (when monitor (start-monitor repository))))
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

(defun test-files (graph)
  "The :FILE entities an analyzer marked as files the test runner would run.

REQ-0053 R7. Only the JavaScript analyzer writes :TEST-FILE-P, so this is
empty on a tree of Lisp -- which is the honest answer rather than a missing
one: a fiveam test file is recognised by its forms wherever it sits, and there
is no include glob to have missed."
  (remove-if-not (lambda (file) (getp file :test-file-p))
                 (entities-of-type graph :file)))

(defun test-files-without-cases (graph)
  "The test files no :TEST entity was minted from.

The report that keeps the recognition rule honest. A file the runner would run
and the analyzer found nothing in is a convention the analyzer does not know
about -- a suite built inside an exported function, a case titled by a
template -- and counting it turns that into a number a reader can chase
instead of an index that looks complete (CON-0001)."
  (let ((covered (make-hash-table :test #'equal)))
    (dolist (test (entities-of-type graph :test))
      (let ((path (getp test :file)))
        (when path (setf (gethash path covered) t))))
    (remove-if (lambda (file) (gethash (getp file :path) covered))
               (test-files graph))))

(defun index-drift (repository)
  "How many files the index read have changed since it read them.

REQ-0050 R2 and R3, done from Loom's own record rather than from git. The first
attempt fingerprinted `git diff HEAD', which answers a question nobody asked:
it moves when any file in the tree moves, including the ones no analyzer
claims. Within an hour of landing, editing tools/test/acceptance.py -- Python, which
Loom does not index -- made the harness report a stale service whose index was
perfectly current. A staleness signal that fires on every document, tool and
fixture edit is a signal that gets ignored, which restores the defect it was
built to remove.

REPOSITORY-STAMPS is the precise answer and it is also the cheap one: the
watcher already stores, per claimed file, the write date and a content hash of
the bytes the analyzer read, so a file whose stamp disagrees with the file on
disk is a file the index is behind on.

Over the stamps rather than over the tree, which is a correction and not a
detail. Walking the tree instead costs a recursive directory walk and a `git
check-ignore' subprocess -- measured on Loom, 179ms against 1.6ms for the stats
-- and REQ-0050's own open question is that a fingerprint in the latency path
of the cheapest command Loom has is not affordable. At 1.6ms it goes on every
answer; at 179ms it could go on `status' alone, which is the surface that needs
it least.

What a stamp walk cannot see is a file the index has never read. That is
UNINDEXED-FILES, which costs the walk and which `status' pays for."
  (let ((root (repository-root repository))
        (now (get-universal-time))
        (drift 0))
    (maphash (lambda (relative stamp)
               (declare (ignore stamp))
               (let ((path (merge-pathnames relative root)))
                 ;; PROBE-FILE as well as FILE-CHANGED-P, because the two
                 ;; disagree about a file that is gone and both are right for
                 ;; their own question. FILE-CHANGED-P answers "reanalyze
                 ;; this?" and says no -- there is nothing to read. Drift asks
                 ;; "do the index and the tree agree?" and a deleted file is
                 ;; the clearest case of no.
                 (when (or (null (probe-file path))
                           (file-changed-p repository relative path now))
                   (incf drift))))
             (repository-stamps repository))
    drift))

(defun unindexed-files (repository)
  "How many files an analyzer claims that the index has no stamp for.

The half INDEX-DRIFT cannot see. A stamp walk compares what the index read
against what is on disk now, and a file created since the last poll is in
neither -- it has no stamp to disagree with. `git diff HEAD' would not see it
either, which is the untracked-file gap REQ-0050 records as open in the
mechanism REQ-0036 R4 relies on.

Costs what REPOSITORY-FILES costs: a recursive directory walk and one `git
check-ignore' call, 179ms on Loom. Reported by `status', which is a deliberate
question asked rarely, and by nothing in a query's latency path."
  (let ((root (repository-root repository))
        (stamps (repository-stamps repository)))
    (loop for path in (repository-files repository)
          count (null (gethash (workspace-relative-path path root) stamps)))))

(defun index-fingerprint (root)
  "ROOT's branch, commit and diff hash as a plist, for recording at index time.

REQ-0050 R1 and R2. All three, because they answer different questions: a
commit is stable across hours of editing so it distinguishes weeks, the diff
hash moves on every save so it distinguishes the states an index is actually
built from, and the branch is the one of the three a reader recognises without
looking anything up. GIT-DIFF-HASH does not see untracked files, which is a
real gap in the pairing REQ-0036 R4 already relies on and is recorded as open
there.

The same triple GIT-FINGERPRINT puts on a context record, read at index time
rather than at record time. Two functions rather than one because the two are
asked at different moments about different things -- this one is about the
bytes the analyzer read, and a caller that shared it would be reporting the
index\'s tree as the record\'s."
  (multiple-value-bind (commit commit-reason) (git-commit root)
    (multiple-value-bind (diff diff-reason) (git-diff-hash root)
      (multiple-value-bind (branch branch-reason) (git-branch root)
        (list :commit commit :commit-reason commit-reason
              :diff diff :diff-reason diff-reason
              :branch branch :branch-reason branch-reason)))))

(defun file-provenance (repository relative)
  "The index's fingerprint, and whether the one file RELATIVE has moved since
the index read it.

REQ-0050 R1 for an answer about a single definition. `describe' is about one
entity in one file, so whether the answer is about code that is still there is
a question about that file and not about the tree -- and asking it precisely
costs one stat where INDEX-PROVENANCE's drift costs one per claimed file.
Measured over REST on Loom: 4.7ms to 25.6ms with the tree-wide drift on it,
against no measurable change with this.

:DRIFT is deliberately absent rather than nought. A caller reading a plist with
a :DRIFT of 0 would take it for a statement about the repository, which this
never asked."
  (let* ((fingerprint (repository-indexed-fingerprint repository))
         (diff (getf fingerprint :diff))
         (path (and relative (merge-pathnames relative (repository-root repository)))))
    (list :commit (getf fingerprint :commit)
          :commit-reason (getf fingerprint :commit-reason)
          :branch (getf fingerprint :branch)
          :diff diff
          :dirty (and diff (not (string= diff (clean-diff-hash))) t)
          :file relative
          :file-stale (and path
                           (or (null (probe-file path))
                               (file-changed-p repository relative path
                                               (get-universal-time)))
                           t))))

(defun answer-provenance (repository)
  "When the index was built and from what, with nothing computed now.

REQ-0065. `find', `impact', `check' and `rules' are the four surfaces an agent
calls in a loop while changing the tree they are about, which is the only
situation in which staleness is a live question -- and they carried no
provenance at all. The documented answer was \"ask `status' when it matters\",
which doubles the call count and requires knowing in advance that it matters.

Deliberately neither of the two beside it. FILE-PROVENANCE stats one file, and
these answers are not about one file. INDEX-PROVENANCE computes :DRIFT, which
is one stat per claimed file: measured over REST on Loom, that took `describe'
from 4.7ms to 25.6ms, and REQ-0065 R2 keeps it off the four cheapest commands
in the system for that reason.

Everything here is read off the repository struct. A caller that saved a file
and re-queried compares :DIFF against what it saw before and learns whether the
answer predates its own write, which is all R1 asks for.

No :DRIFT and no :FILE keys at all, rather than nought and NIL. FILE-PROVENANCE
omits :DRIFT on the same reasoning -- a caller reading 0 would take it for a
statement about the repository, which this never asked."
  (let* ((fingerprint (repository-indexed-fingerprint repository))
         (diff (getf fingerprint :diff)))
    (list :commit (getf fingerprint :commit)
          :commit-reason (getf fingerprint :commit-reason)
          :branch (getf fingerprint :branch)
          :diff diff
          :dirty (and diff (not (string= diff (clean-diff-hash))) t)
          :indexed-at (repository-indexed-at repository))))

(defun index-provenance (repository)
  "The tree REPOSITORY's index was built from, and how far behind it now is.

REQ-0050 R1 and R3, in one plist so that every surface reports provenance the
same way rather than each assembling its own half of it. :COMMIT, :BRANCH and
:DIFF are read from the fingerprint captured when indexing finished; :DRIFT is
computed now, because it is the comparison between then and the tree on disk.

:DIRTY rather than the caller comparing :DIFF against CLEAN-DIFF-HASH. The
comparison is one fact -- was the tree the analyzer read the commit it names --
and loom-knowledge, which renders one of these surfaces, may not call up here
to make it.

The two halves fail independently and both are reported. Drift is computed from
REPOSITORY-STAMPS and answers on a tree with no git in it at all; the commit
needs git and says why it is missing when there is none."
  (let* ((fingerprint (repository-indexed-fingerprint repository))
         (diff (getf fingerprint :diff)))
    (list :commit (getf fingerprint :commit)
          :commit-reason (getf fingerprint :commit-reason)
          :branch (getf fingerprint :branch)
          :diff diff
          :dirty (and diff (not (string= diff (clean-diff-hash))) t)
          :drift (index-drift repository))))

(defun domain-root-problems (repository domains)
  "R3's seventh refusal: a declared root under which no indexed file lies.

Decidable here and nowhere earlier. DOMAIN-PROBLEMS runs in the analyzer over
the declaration alone and cannot know what the tree holds; this has the file
list at hand, so the check costs a walk already paid for.

Worth reporting because it is the shape a stale declaration takes. A root
renamed in the tree and not in the file partitions nothing, every file that
should have been in it falls to :DEFAULT, and every alias it declared stops
applying -- with the file still looking exactly as correct as it did."
  (when domains
    (let ((paths (mapcar (lambda (f) (getp f :path))
                         (entities-of-type (repository-graph repository) :file)))
          (problems '()))
      (maphash
       (lambda (name domain)
         (let ((root (getf domain :root)))
           (when (and root (plusp (length root))
                      (notany (lambda (path)
                                (and path
                                     (<= (length root) (length path))
                                     (string= root path :end2 (length root))))
                              paths))
             (push (format nil "domain `~(~a~)' declares root ~s and no indexed ~
file lies under it"
                           name root)
                   problems))))
       domains)
      (nreverse problems))))

(defun import-summary (repository)
  "The import graph as five numbers: resolved, and one per cause.

Summed over the :FILE entities rather than recomputed, because RESOLVE-IMPORTS
already wrote both halves -- the edges and the causes -- and a second
resolution pass here could disagree with the graph a caller is about to query.

Always five numbers, zeroes included, which is DES-0002 R10's rule: a count
that vanishes when it is nought cannot be told from a count nobody computed."
  (let ((graph (repository-graph repository))
        (resolved 0)
        (by-cause (list :external 0 :out-of-domain 0
                        :unclaimed-target 0 :unresolved 0)))
    (dolist (file (entities-of-type graph :file))
      (dolist (r (relationships-from graph (id file)))
        (when (eq :imports (rel-type r)) (incf resolved)))
      (dolist (entry (getp file :unresolved-imports))
        (incf (getf by-cause (getf entry :cause) 0))))
    (list* :resolved resolved by-cause)))

(defun module-scoped-repository-p (repository)
  "True when any indexed file is in a language with its own module namespace.

What the imports line is printed on. A Common Lisp tree has no import graph,
and a row of zeroes there is a count of a question nobody asked."
  (some (lambda (file) (module-scoped-language-p (getp file :language)))
        (entities-of-type (repository-graph repository) :file)))

(defun repository-status (repository)
  "SS3.2's status, as plain data: \"indexing progress, entity and relationship
counts, watcher health, unresolved document references, unenforced rules, and
the last error per thread.\""
  (let ((graph (repository-graph repository))
        ;; Once. DRIFT is one stat per claimed file, and reading it out of the
        ;; plist six times would pay for the whole tree six times.
        (provenance (index-provenance repository)))
    (list :name (repository-name repository)
          :root (namestring (repository-root repository))
          ;; The docstring above promises "indexing progress" and until now the
          ;; only progress there was to report was finished or not. A background
          ;; index makes "still reading the tree" a state a caller can be in and
          ;; needs told about: every other operation waits for it, and status is
          ;; the one that says why the waiting would happen.
          :state (repository-state repository)
          :indexed-at (repository-indexed-at repository)
          ;; REQ-0050 R1 and R2. INDEXED-AT is a generation counter: it orders
          ;; reindexes and names no tree. The commit alone is not enough either
          ;; -- it moves on `git commit' where the working tree, which is what
          ;; the analyzer reads, moves on every save -- so a commit agreeing
          ;; with HEAD is consistent with an index built from entirely
          ;; different bytes. The pair is what REQ-0036 R4 already carries on
          ;; every context record and what nothing else carried.
          ;;
          ;; From the stored fingerprint, not from git: what is wanted is the
          ;; tree the index was built from, and asking git now answers about
          ;; the tree now.
          ;;
          ;; The commit is the coarse half and is kept because it is cheap and
          ;; names a shared reference point. DRIFT is the half that answers the
          ;; question -- how many claimed files the index is behind on, from
          ;; REPOSITORY-STAMPS rather than from `git diff HEAD', which moves
          ;; when a document or a tool moves and reported a perfectly current
          ;; index as stale within an hour of being introduced.
          :commit (getf provenance :commit)
          :commit-reason (getf provenance :commit-reason)
          :branch (getf provenance :branch)
          :diff (getf provenance :diff)
          :dirty (getf provenance :dirty)
          :drift (getf provenance :drift)
          ;; REQ-0050 R3's other half: files no analyzer has read, which a
          ;; stamp walk cannot see because they have no stamp to disagree with.
          ;;
          ;; From the slot, which the index build and every poll fill in from
          ;; the walk they already do. Computed here instead, it made `status'
          ;; over nine repositories take 8.9 seconds -- front-end 7.1 of them,
          ;; whose tree is large enough that enumerating it dwarfs everything
          ;; else this function does. UNINDEXED-FILES is still the exact answer
          ;; and still costs the walk; it is for a caller who asks for it.
          :unindexed (repository-unindexed repository)
          ;; REQ-0059. Read off the struct rather than recomputed: the walk and
          ;; the `git ls-files' behind it were paid at index time, and `status'
          ;; is asked over nine repositories at once.
          :unclaimed (getf (repository-unclaimed repository) :count)
          :unclaimed-by-extension (getf (repository-unclaimed repository) :by-extension)
          :unclaimed-reason (getf (repository-unclaimed repository) :reason)
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
          ;; REQ-0053 R7 and DES-0045 D7. The middle one is the report that
          ;; keeps the recognition honest: a file the runner would run and the
          ;; analyzer recognised no case in is a convention it does not know
          ;; about, and it shows up as a number rather than as an index that
          ;; looks complete. All three are nought on a Lisp tree, where no
          ;; analyzer writes :TEST-FILE-P.
          :test-files (length (test-files graph))
          :test-files-without-cases (length (test-files-without-cases graph))
          :unnamed-tests (loop for file in (test-files graph)
                               sum (or (getp file :unnamed-tests) 0))
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
          ;; REQ-0030 R6. Entries that stop being counted as unresolved are
          ;; counted here instead, on the same line, so a reader told to watch
          ;; `unresolved' sees where they went rather than an improvement.
          :ambiguous-references (length (ambiguous-references graph))
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
          ;; PLAN-0050 S9. DOMAIN-PROBLEMS answers over the declaration,
          ;; FRAMEWORKS-PROBLEMS over the file, and DOMAIN-ROOT-PROBLEMS over
          ;; the tree -- three questions about one declaration, reported as one
          ;; list because a reader repairing the file does not care which of the
          ;; three noticed.
          :domain-problems (append (frameworks-problems (repository-root repository))
                                   (domain-problems
                                    (getf (repository-frameworks repository) :domains))
                                   (domain-root-problems
                                    repository (repository-domains repository)))
          ;; Five numbers whenever the tree has a module-scoped file, and
          ;; absent when it has none: a Common Lisp tree has no import graph.
          :unresolved-imports (when (module-scoped-repository-p repository)
                                (import-summary repository))
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
          ;; BUG-0033, and first among the three gap counts because it is the
          ;; largest unit any of them measures: a suppressed region costs a
          ;; definition and a dropped edge costs a relationship, but an
          ;; unparsed file costs everything the file would have said. Zero on
          ;; all three watched trees, and printed even so, for the reason the
          ;; comment above gives.
          :unparsed (length (unparsed-facts graph))
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

(defun check-document-references (repository path &key contents)
  "What one document's declared references resolve to, without writing or
indexing it.

REQ-0034. The loop it replaces is write, wait for the monitor, run `check',
subtract the repository's own baseline, edit, repeat -- four round trips
through the filesystem and the indexer on the session that prompted the
requirement, to learn something the index could have answered before any file
existed.

PATH may name a file the repository does not hold and the index has never
seen. CONTENTS overrides what is on disk, which is DES-0029 D5: ANALYZE-PATH
has taken that argument since the analyzer protocol was written -- \"the hook
for analyzing an editor buffer that has not been saved\" -- so an agent
composing a document in memory needs no scratch file.

Returns a plist: the path, the document's id and type, and one entry per
declared name saying which field it was written in and what it resolved to --
:RESOLVED with the target, :AMBIGUOUS with the candidate ids, or :UNRESOLVED.
An :ERROR instead when no analyzer claims the path or the file holds no
document, because a path that produced nothing is a different answer from a
document with no references and reporting them alike would be the fabricated
fact CON-0001 forbids.

Nothing is asserted. The ops the analyzer returns are read for the entity they
carry and thrown away, so the graph after the call is the graph before it."
  (let* ((graph (repository-graph repository))
         (root (repository-root repository))
         (full (merge-pathnames path root))
         (source (or contents
                     (and (probe-file full) (read-file full)))))
    (cond
      ((null (find-analyzer full))
       (list :path path :error "no analyzer claims this path"))
      ((null source)
       (list :path path :error "no such file, and no contents given"))
      (t
       (let* ((ops (analyze-path full :workspace-root root :contents source))
              (document (loop for op in ops
                              when (and (typep op 'assert-entity-op)
                                        (member (entity-type (op-entity op))
                                                *document-types*))
                                return (op-entity op))))
         (if (null document)
             (list :path path :error "the file holds no document")
             (let ((index (linkable-index graph)))
               (list :path path
                     :document (or (getp document :doc-id) (name document))
                     :type (entity-type document)
                     :references
                     (loop for (field . nil) in *declared-link-fields*
                           append (loop for name in (getp document field)
                                        collect (document-reference-report
                                                 index field name document)))))))))))

(defun document-reference-report (index field name document)
  "One declared reference, as what the author needs to act on it.

A reference resolving to the document itself is reported as resolved and
carries that fact, since RESOLVE-DOCUMENT-LINKS declines to assert an edge
there and an author reading `resolved' about a self-reference would be told
an edge exists that does not. Compared by id rather than by identity: the
entity here came from the analyzer and is a different object from the one in
the index even when the document is already indexed."
  (multiple-value-bind (target candidates) (resolve-one index name)
    (cond
      ((and target (equal (id target) (id document)))
       (list :field field :name name :status :self))
      (target
       (list :field field :name name :status :resolved
             :target (id target) :type (entity-type target)))
      (candidates
       (list :field field :name name :status :ambiguous
             :candidates (mapcar #'id candidates)))
      (t (list :field field :name name :status :unresolved)))))

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
