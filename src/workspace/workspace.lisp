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
  (monitor nil))

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

(defun repository-files (repository)
  "Every file under the repository root that some analyzer claims.
Skips .git and any dot-directory: nothing in them is source, and .git in
particular churns constantly."
  (remove-if-not
   (lambda (path)
     (and (pathname-name path)
          (notany (lambda (segment)
                    (and (stringp segment) (plusp (length segment))
                         (char= #\. (char segment 0))))
                  (rest (pathname-directory path)))
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

Order matters and is the reason this function exists: document links resolve
against entities the code analyzers produced, and the rules of SS10.4 are
queries over the finished graph, so they run last."
  (let ((graph (repository-graph repository))
        (workspace (repository-name repository)))
    (flet ((submit (label ops)
             (when ops
               (handler-case (apply-transaction graph ops)
                 (error (condition)
                   (note-error repository label condition)
                   (unless quiet
                     (format *standard-output* "~&  ! ~a: ~a~%" label condition)))))))
      (submit "resolve-calls"          (resolve-calls graph :workspace-id workspace))
      (submit "resolve-document-links" (resolve-document-links graph :workspace-id workspace))
      (submit "check-rules"            (violation-ops graph :workspace-id workspace)))))

(defun index-repository (repository &key quiet)
  "Analyze every analyzable file, then resolve and check.

SS3.4: \"Because files are truth, this is always available and always correct,
and its only cost is time.\""
  (let ((files (repository-files repository))
        (indexed 0))
    (unless quiet
      (format t "~&Indexing ~a (~d files)...~%" (repository-name repository) (length files)))
    (dolist (path files)
      (when (index-file repository path :quiet quiet) (incf indexed)))
    (resolve-and-check repository :quiet quiet)
    (setf (repository-file-count repository) indexed
          (repository-indexed-at repository) (get-universal-time))
    indexed))

(defun reindex-repository (repository &key quiet)
  "Discard the index and rebuild it from disk.

SS3.2: \"Always safe, because files are truth; the escape hatch for any
suspected divergence.\" A fresh graph rather than a cleared one, so nothing
from the old index can survive by accident."
  (setf (repository-graph repository) (make-graph))
  (clrhash (repository-stamps repository))
  (setf (repository-errors repository) '())
  (index-repository repository :quiet quiet))

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
DETECT-DELETIONS exists below."
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
    (length changed)))

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
    (setf (repository-monitor repository)
          (bt:make-thread
           (lambda ()
             (loop
               (handler-case (poll-once repository :quiet t)
                 (error (condition) (note-error repository "monitor" condition)))
               (sleep *poll-interval*)))
           :name (format nil "loom-monitor ~a" (repository-name repository)))))
  repository)

(defun stop-monitor (repository)
  (let ((thread (repository-monitor repository)))
    (when (and thread (bt:thread-alive-p thread))
      (ignore-errors (bt:destroy-thread thread)))
    (setf (repository-monitor repository) nil))
  repository)

;;;; ==================================================================
;;;; Lifecycle
;;;; ==================================================================

(defun watch-repository (path &key (monitor t) quiet)
  "Register the repository at PATH, index it, and begin watching.
SS3.2's watch command. Re-watching an already-registered repository reindexes
it rather than registering a second copy."
  (let* ((root (normalize-root path))
         (existing (find (namestring root) *repositories*
                         :key (lambda (r) (namestring (repository-root r)))
                         :test #'string=)))
    (if existing
        (progn (reindex-repository existing :quiet quiet) existing)
        (let ((repository (make-repository
                           :root root
                           :name (or (car (last (pathname-directory root))) "repository"))))
          (push repository *repositories*)
          (index-repository repository :quiet quiet)
          (when monitor (start-monitor repository))
          repository))))

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
          :monitor (if (monitor-running-p repository) :running :stopped)
          :documents (+ (length (entities-of-type graph :decision))
                        (length (entities-of-type graph :rule))
                        (length (entities-of-type graph :concept))
                        (length (entities-of-type graph :document)))
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
