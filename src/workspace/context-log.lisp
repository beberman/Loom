;;;; The retrieval log: what was asked, what came back, and what was used.
;;;;
;;;; REQ-0036 and DES-0030. Every `context' call already computes everything a
;;;; relevance judgement needs -- the task, the tokens TASK-TOKENS derived, the
;;;; seeds in rank order with their scores, the items with their bands, the
;;;; latency -- and discards all of it. This keeps it, and a later call quoting
;;;; the record's id adds the half no offline scorer can supply: what the agent
;;;; on the other end actually went on to use, including what it found by grep
;;;; or by reading a file.
;;;;
;;;; Off unless an operator turns it on. *CONTEXT-LOG-DIRECTORY* is NIL by
;;;; default, no request can set it, and with it NIL nothing here writes
;;;; anything or creates a directory. That is what makes DES-0030 D1's answer
;;;; to REQ-0036 R9 narrow enough to be honest: a :READ operation may write to
;;;; Loom's own state directory, and a deployment that never enables it never
;;;; acquires a write.

(in-package :loom-workspace)

(defvar *context-log-directory* nil
  "Where context records are written, or NIL for not at all.

NIL by default and settable only by an operator -- no operation takes it as an
argument, because a caller that could switch on a write would be a caller that
had been granted one. DEFAULT-CONTEXT-LOG-DIRECTORY is what an operator
usually wants and is not the default value, so that turning the log on is a
line somebody wrote rather than a state the service arrives in.")

(defun loom-root ()
  "The tree this image was loaded from.

The ASDF source directory of loom-workspace, up two: src/workspace/ ->
<loom>/. Not the current directory, which is whatever the operator started the
service in, and not a watched repository named \"Loom\", which a deployment
answering for other trees need not have."
  (let ((here (asdf:system-source-directory :loom-workspace)))
    (merge-pathnames "../../" here)))

(defun default-context-log-directory ()
  "<loom>/.loom/context/, which is REQ-0036 R6 and R7 together.

In Loom's own tree rather than the searched one, because writing a record into
game-server or front-end would end their corpora holding still -- and that
property is what tools/acceptance.py depends on. Under a dot-directory, where
REPOSITORY-FILES already skips it before any analyzer is consulted, so the log
cannot enter the index it judges."
  (merge-pathnames ".loom/context/" (loom-root)))

(defun configure-context-log-from-environment ()
  "Turn the log on when the operator's environment says so, and return where.

LOOM_CONTEXT_LOG names the directory, or is any other non-empty value to mean
DEFAULT-CONTEXT-LOG-DIRECTORY. An environment variable rather than a request
field is the whole of DES-0030 D1: the operator running the service decides,
and no caller can decide for them. Called by the entry points, so a library
consumer that never calls it gets the default of writing nothing."
  (let ((value (uiop:getenv "LOOM_CONTEXT_LOG")))
    (setf *context-log-directory*
          (cond ((or (null value) (string= value "")) nil)
                ((find #\/ value) (pathname (if (char= #\/ (char value (1- (length value))))
                                                value
                                                (concatenate 'string value "/"))))
                (t (default-context-log-directory))))))

(defun context-record-path (id &optional (directory *context-log-directory*))
  (merge-pathnames (format nil "~a.json" id) directory))

(defun proper-list-p (value)
  "True when VALUE is a list that ends in NIL."
  (and (listp value) (null (cdr (last value)))))

(defun plist-object-p (value)
  "True when VALUE is a plist meant to encode as a JSON object.

A keyword in the first position, a proper list, and an even length. CL-JSON's
own plist encoder treats only the top level as an object and encodes a nested
plist as an array, which is how a record's `repository' block arrived as an
array of its own keys and values instead of an object. The rule is stated
rather than inferred because it is the one place this file guesses: a record
never holds a list of keywords, so nothing else can match it."
  (and (consp value)
       (keywordp (first value))
       (proper-list-p value)
       (evenp (length value))))

(defun encode-record-value (value stream)
  "Write VALUE to STREAM as JSON, recursively.

Written out rather than delegated because the shapes a record holds are a
closed set -- plists, lists, strings, numbers, T, :FALSE and NIL -- and
CL-JSON's plist encoder flattens the nested ones. Nothing decoded is ever
encoded again: see RECORD-CONTEXT-USE for why a record is never rewritten. The string escaping is still CL-JSON's, which is the half a
hand-rolled emitter gets wrong."
  (cond ((null value) (write-string "null" stream))
        ((eq value t) (write-string "true" stream))
        ;; JSON false, which NIL cannot express here: NIL is how a plist says
        ;; "no value" and a record uses it for a reason that is absent. A
        ;; boolean field writes :FALSE so that a reader sees a boolean rather
        ;; than a null it has to interpret.
        ((eq value :false) (write-string "false" stream))
        ((plist-object-p value)
         (write-char #\{ stream)
         (loop for (key sub) on value by #'cddr
               for first = t then nil
               do (unless first (write-char #\, stream))
                  (json:encode-json (json:lisp-to-camel-case (symbol-name key))
                                    stream)
                  (write-char #\: stream)
                  (encode-record-value sub stream))
         (write-char #\} stream))
        ;; A dotted pair is not a shape JSON has, and LENGTH signals on one, so
        ;; this is tested before anything measures the list. Encoded as a
        ;; two-element array so a record carrying one is readable rather than a
        ;; write that fails and loses the whole judgement.
        ((and (consp value) (not (proper-list-p value)))
         (write-char #\[ stream)
         (encode-record-value (car value) stream)
         (write-char #\, stream)
         (encode-record-value (cdr value) stream)
         (write-char #\] stream))
        ((consp value)
         (write-char #\[ stream)
         (loop for item in value
               for first = t then nil
               do (unless first (write-char #\, stream))
                  (encode-record-value item stream))
         (write-char #\] stream))
        ((keywordp value) (json:encode-json (string-downcase (symbol-name value))
                                            stream))
        (t (json:encode-json value stream)))) 

(defun write-json-record (path record)
  "Write RECORD, a plist, to PATH as JSON."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (encode-record-value record out)
    (terpri out))
  path)

(defun read-json-record (path)
  "The record at PATH as an alist, or NIL when there is no such file."
  (when (probe-file path)
    (with-open-file (in path :direction :input :external-format :utf-8)
      (json:decode-json in))))

(defun git-fingerprint (root)
  "ROOT's branch, commit and diff hash, as a plist, with the reason any of them
is missing.

Two of these travel on every record, for the searched repository and for Loom
itself, because the two move independently and one field cannot separate their
effects (REQ-0036 R5). Two records against one game-server commit whose
returned sets differ, differ because the ranking changed; two against one Loom
commit whose scores differ, differ because the corpus did."
  (multiple-value-bind (commit commit-reason) (git-commit root)
    (multiple-value-bind (diff diff-reason) (git-diff-hash root)
      (multiple-value-bind (branch branch-reason) (git-branch root)
        (list :branch branch
              :commit commit
              :diff-hash diff
              :reason (or commit-reason diff-reason branch-reason))))))

(defvar *record-random-state* nil
  "A time-seeded random state for record ids.

SBCL starts every image with the same *RANDOM-STATE*, so RANDOM-UUID mints the
same first UUID in every process. Measured: a console call and a service call
in two processes produced one id, and the second record would have overwritten
the first. A judgement lost to a filename collision is the one failure this log
cannot detect afterwards, so the state is seeded from the clock at first use.")

(defun context-record-id ()
  "An id for one record: the timestamp it was minted at, and a random tail.

The timestamp is in the id rather than only in the record so that a directory
listing sorts chronologically, and so that two processes starting together
still differ in the tail."
  (unless *record-random-state*
    (setf *record-random-state* (make-random-state t)))
  (let* ((*random-state* *record-random-state*)
         (uuid (random-uuid:to-string (random-uuid:make-uuid))))
    (multiple-value-bind (second minute hour day month year)
        (decode-universal-time (get-universal-time) 0)
      (format nil "ctx-~4,'0d~2,'0d~2,'0dT~2,'0d~2,'0d~2,'0d-~a"
              year month day hour minute second (subseq uuid 0 8)))))

(defvar *context-log-threads* '()
  "Writes still in flight, so a caller that needs the file can wait for it.")

(defvar *context-log-thread-lock* (bt:make-lock "loom-context-log"))

(defun drain-context-log (&key (timeout 10))
  "Wait for every outstanding record write, and return T when none is left.

The record is written off the caller's path, so anything that needs the file --
a test, a harness run, a session about to exit -- has to say so. TIMEOUT is a
ceiling rather than an expectation: a write is one git call and one file."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for threads = (bt:with-lock-held (*context-log-thread-lock*)
                          (copy-list *context-log-threads*))
          while threads
          do (dolist (thread threads)
               (when (bt:thread-alive-p thread)
                 (ignore-errors (bt:join-thread thread))))
             (when (> (get-internal-real-time) deadline) (return nil))
          finally (return t))))

(defun record-context-call (repository bundle instrumentation
                            &key seconds (directory *context-log-directory*))
  "Write one record for an answered context call, and return its id.

NIL and no write when DIRECTORY is NIL, which is the default and is the whole
of the tier argument in DES-0030 D1.

BUNDLE is what the caller received; INSTRUMENTATION is BUILD-CONTEXT's second
value, which carries what a judgement needs and a reader does not -- the
tokens, the seeds with their scores and terms, and the band each item landed
in. Both are recorded, because REQ-0036 R1 asks for the tokens and not only the
task: TASK-TOKENS is the layer where stopwords and stemming act, and a record
holding the raw string cannot show that the tokeniser dropped the
discriminating word.

The id is returned at once and the file is written on another thread, which is
REQ-0036 R8. Measured: the two fingerprints are six `git' invocations, and
spawning a process from an SBCL image of this size costs about 13ms each -- the
32 acceptance clauses went from 0.02-0.07s to 0.12-0.15s with the write on the
caller's path. Nothing in the record depends on the caller waiting, and a
bundle is not worth delaying for Loom's own bookkeeping. DRAIN-CONTEXT-LOG is
how a test or a harness says it needs the file now."
  (when directory
    (let* ((id (context-record-id))
           ;; Read off the repository here rather than on the writer thread:
           ;; these are the facts of the call, and a thread that read them later
           ;; could read a repository that had been unwatched in between.
           (name (repository-name repository))
           (root (repository-root repository))
           (record-head (list :id id
                              :at (format-timestamp (get-universal-time))
                              :task (getf bundle :task)
                              :tokens (getf instrumentation :tokens)
                              :latency-seconds (or seconds 0)))
           (returned (list :returned
                           (list :seeds (getf instrumentation :seeds)
                                 :items (getf instrumentation :items)
                                 :budget (getf bundle :budget)
                                 :tokens-used (getf bundle :tokens)
                                 :truncated (if (getf bundle :truncated) t :false)))))
      (let ((thread
              (bt:make-thread
               (lambda ()
                 (unwind-protect
                      (handler-case
                          (write-json-record
                           (context-record-path id directory)
                           (append record-head
                                   (list :repository (list* :name name
                                                            (git-fingerprint root))
                                         :loom (git-fingerprint (loom-root)))
                                   returned))
                        ;; A log that cannot be written must not take the answer
                        ;; down with it -- and on another thread it could not
                        ;; anyway, which is why the reason is recorded where an
                        ;; operator can read it.
                        (error (condition) (note-log-failure condition)))
                   (bt:with-lock-held (*context-log-thread-lock*)
                     (setf *context-log-threads*
                           (remove (bt:current-thread) *context-log-threads*)))))
               :name "loom-context-record")))
        (bt:with-lock-held (*context-log-thread-lock*)
          (push thread *context-log-threads*)))
      id)))

(defvar *context-log-failure* nil
  "The last reason a record could not be written, or NIL.

Recorded rather than signalled, and readable so that an operator who enabled
logging and sees no files has somewhere to look. A silent failure here would
leave a corpus that is quietly missing exactly the sessions where something
went wrong.")

(defun note-log-failure (condition)
  (setf *context-log-failure* (princ-to-string condition))
  nil)

(defun format-timestamp (universal-time)
  "UNIVERSAL-TIME as an ISO-8601 UTC string, which is what a record carries.

Not a Lisp universal time: the record is read by tools/acceptance.py, and a
number counting seconds from 1900 is a fact about Common Lisp rather than about
when the query was asked."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal-time 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

(define-condition context-record-error (error)
  ((id :initarg :id :reader context-record-error-id))
  (:report (lambda (condition stream)
             (format stream "No context record ~a."
                     (context-record-error-id condition))))
  (:documentation "A feedback call quoted an id no record has.

A refusal rather than a new file. A record minted because somebody quoted a
wrong id is a judgement about a query nobody asked, which is CON-0001's
fabricated fact wearing the shape of evidence."))

(defun context-use-path (id &optional (directory *context-log-directory*))
  (merge-pathnames (format nil "~a.used.json" id) directory))

(defun record-context-use (id used &key (directory *context-log-directory*))
  "Write what was used for the record ID names, and return both halves.

USED is a list of plists, each naming what was used and how it was found. Not
restricted to what the bundle returned, which is REQ-0036 R2's whole point: a
feedback channel sampling only from the returned items can never record a miss,
and the miss is the population that would raise recall. The eight seed slots
make that bias severe rather than theoretical.

One field and a free-text HOW rather than a graded relevance scale. An agent
may not reliably know at reporting time whether it read and acted or read and
discarded, and a grade it cannot assign honestly is worth less than a sentence
it can -- \"found by grepping the exact identifier\" and \"found three files
from something the bundle returned\" are different failures and imply different
repairs (R3).

A sibling file, <id>.used.json, rather than the used set merged into the
record. DES-0030 D5 wanted one file and this is the measured reason it is two:
merging means decoding the record and encoding it again, and JSON's distinction
between an object and an array does not survive that round trip through Lisp,
where both are lists. A record written once and never rewritten cannot be
corrupted by its own serialiser, and the join R3 asks for is two files with one
id rather than one file that might have changed shape.

An id naming no record is refused rather than given a file of its own. A
judgement about a query nobody asked is CON-0001's fabricated fact wearing the
shape of evidence."
  (unless directory
    (error 'context-record-error :id id))
  (let ((record-path (context-record-path id directory)))
    (unless (probe-file record-path)
      (error 'context-record-error :id id))
    (write-json-record (context-use-path id directory)
                       (list :id id :used used))
    (list :id id
          :record (read-json-record record-path)
          :used (cdr (assoc :used (read-json-record (context-use-path id directory)))))))

