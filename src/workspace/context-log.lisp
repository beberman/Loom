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
property is what tools/test/acceptance.py depends on. Under a dot-directory, where
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

;;; PROPER-LIST-P and ALIST-OBJECT-P are the library's now: UTILS:PROPER-LIST-P
;;; and (UTILS:ALISTP value :KEY-TEST #'KEYWORDP). The alist rule they encoded
;;; is unchanged and is the reason the encoder below needs no guess -- one shape
;;; for an object, one for an array, an entry being a cons whose cdr is the
;;; value. That rule came from game-server's serialize.lisp, which had an ALISTP
;;; branch and no plist branch at all, and the library is where it lives now.
;;;
;;; The library's PROPER-LIST-P is also the stronger of the two: it records the
;;; tails it has visited, so a circular list returns NIL where the LAST-based
;;; version here would not have returned at all.

(defun encode-record-value (value stream)
  "Write VALUE to STREAM as JSON, recursively.

Five cases and no guess: NIL is null, T is true, :FALSE is false, an alist is an
object, any other proper list is an array, and everything else is a scalar
CL-JSON escapes. The escaping is CL-JSON's because a task string is arbitrary
text with quotes and newlines in it, and that is the half a hand-rolled emitter
gets wrong.

Written out rather than delegated because CL-JSON's own dispatch encodes an
alist as an array, which is the opposite of what a record needs."
  (cond ((null value) (write-string "null" stream))
        ((eq value t) (write-string "true" stream))
        ;; JSON false, which NIL cannot express here: NIL is also how a record
        ;; says a value is absent, and a boolean field writes :FALSE so a reader
        ;; sees a boolean rather than a null it has to interpret.
        ((eq value :false) (write-string "false" stream))
        ((alistp value :key-test #'keywordp)
         (write-char #\{ stream)
         (loop for (key . sub) in value
               for first = t then nil
               do (unless first (write-char #\, stream))
                  (json:encode-json (json:lisp-to-camel-case (symbol-name key))
                                    stream)
                  (write-char #\: stream)
                  (encode-record-value sub stream))
         (write-char #\} stream))
        ((proper-list-p value)
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

(defun strict-value-to-record (value)
  "One strictly-decoded JSON value as the shape a record is held in.

BUG-0045. A strict decode distinguishes what the default one collapses:
:TRUE, :FALSE and :NULL arrive as three values where CL-JSON hands back NIL for
two of them and T for the third. This maps them onto what ENCODE-RECORD-VALUE
writes -- T, :FALSE and NIL respectively -- so the pair is a round trip.

:FALSE stays :FALSE rather than becoming NIL, and that is the whole fix. The
marker exists because NIL is also how a record says a value is absent, and a
boolean field writes :FALSE so a reader sees a boolean rather than a null it
has to interpret. Decoding it to NIL destroyed exactly the distinction it was
introduced to preserve, silently, on 47 of 88 files.

Keys come back as strings from ST-JSON and are interned through
UTILS:*JSON-KEY-TO-LISP*, the decoding counterpart of the *JSON-KEY-NAME* the
writer binds -- so `tokensUsed' reads back as :TOKENS-USED and re-encodes as
`tokensUsed'. Set as a pair or neither direction round-trips."
  (typecase value
    (st-json:jso
     (let ((pairs '()))
       (st-json:mapjso (lambda (key sub)
                         (push (cons (intern (funcall utils:*json-key-to-lisp* key)
                                             :keyword)
                                     (strict-value-to-record sub))
                               pairs))
                       value)
       (nreverse pairs)))
    (cons (mapcar #'strict-value-to-record value))
    (t (case value
         (:true t)
         (:false :false)
         (:null nil)
         (t value)))))

(defun read-json-record (path)
  "The record at PATH as an alist, or NIL when there is no such file.

Decoded strictly and mapped back rather than read with JSON:DECODE-JSON, which
answers NIL to both `false' and `null' and so cannot round-trip a record
(BUG-0045). The shape returned is unchanged: an alist with keyword keys, which
is what every caller here already reads."
  (when (probe-file path)
    (with-open-file (in path :direction :input :external-format :utf-8)
      ;; The binding wraps the *conversion*, not the decode. A strict decode
      ;; keeps keys as strings and never consults the policy; it is
      ;; STRICT-VALUE-TO-RECORD that interns them, so a LET around
      ;; UTILS:JSON-DECODE alone has no effect and the default policy applies.
      ;; Scoped that way first, and the symptom was `latencySeconds' reading
      ;; back and re-encoding as `latencyseconds' -- a key-spelling regression
      ;; that no Lisp test sees, which is what PLAN-0036 S5 warned this file
      ;; was exposed to.
      ;;
      ;; CAMEL-CASE-TO-LISP because the writer uses LISP-TO-CAMEL-CASE:
      ;; :LATENCY-SECONDS writes `latencySeconds' and must read back as
      ;; :LATENCY-SECONDS. The two are policy and belong set as a pair.
      (let ((utils:*json-key-to-lisp* #'json:camel-case-to-lisp))
        (strict-value-to-record (utils:json-decode in :strict t))))))

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
        (list (cons :branch branch)
              (cons :commit commit)
              (cons :diff-hash diff)
              (cons :reason (or commit-reason diff-reason branch-reason)))))))

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
           (head (list (cons :id id)
                       (cons :at (format-timestamp (get-universal-time)))
                       ;; REQ-0038 R2: one schema with an operation field, so a
                       ;; reader of this directory can tell what it is looking at
                       ;; without inferring it from which keys are present.
                       (cons :operation "context")
                       (cons :task (getf bundle :task))
                       (cons :tokens (getf instrumentation :tokens))
                       (cons :latency-seconds (or seconds 0))))
           (returned
             (list (cons :returned
                         (list (cons :seeds (mapcar #'seed-alist
                                                    (getf instrumentation :seeds)))
                               (cons :items (mapcar #'item-alist
                                                    (getf instrumentation :items)))
                               (cons :budget (getf bundle :budget))
                               (cons :tokens-used (getf bundle :tokens))
                               (cons :truncated (if (getf bundle :truncated)
                                                    t :false)))))))
      (write-record-async
       id directory
       (lambda ()
         (append head
                 (list (cons :repository
                             (cons (cons :name name) (git-fingerprint root)))
                       (cons :loom (git-fingerprint (loom-root))))
                 returned)))
      id)))

(defun write-record-async (id directory build)
  "Write the record BUILD returns to DIRECTORY, on another thread, as ID.

Factored out of RECORD-CONTEXT-CALL when REQ-0038 added a second kind of record:
the thread bookkeeping, the failure handling and the reason for both are one
decision and were about to be two copies of it. BUILD is a thunk rather than the
record because the fingerprints are six `git' invocations at about 13ms each,
and DES-0030's measurement is that they belong off the caller's path -- a bundle
is not worth delaying for Loom's own bookkeeping. Facts that could change under
the caller are read before this is called; what is deferred is only the cost."
  (let ((thread
          (bt:make-thread
           (lambda ()
             (unwind-protect
                  (handler-case
                      (write-json-record (context-record-path id directory)
                                         (funcall build))
                    ;; A log that cannot be written must not take the answer down
                    ;; with it -- and on another thread it could not anyway,
                    ;; which is why the reason is recorded where an operator can
                    ;; read it.
                    (error (condition) (note-log-failure condition)))
               (bt:with-lock-held (*context-log-thread-lock*)
                 (setf *context-log-threads*
                       (remove (bt:current-thread) *context-log-threads*)))))
           :name "loom-query-record")))
    (bt:with-lock-held (*context-log-thread-lock*)
      (push thread *context-log-threads*))
    id))

(defparameter *record-argument-limit* 200
  "Longest argument value a record keeps, in characters.

A record says what was asked, not what was sent. CHECK-DOCUMENT takes a whole
document in its `contents' argument, and a log holding those is a second copy of
docs/ that nobody asked for and that ages badly. Longer values are recorded as
their length instead, which is what a judgement about retrieval needs to know
about them.")

(defun query-argument-alist (arguments)
  "ARGUMENTS, a decoded request plist, as the alist a record holds.

Keys as they arrived, values only where a value is small enough to be a fact
about the question rather than a copy of its payload."
  (loop for (key value) on arguments by #'cddr
        collect (cons key
                      (cond ((null value) :false)
                            ((stringp value)
                             (if (<= (length value) *record-argument-limit*)
                                 value
                                 (format nil "(~d characters)" (length value))))
                            ((or (numberp value) (keywordp value)) value)
                            ((eq value t) t)
                            (t (format nil "~a" (type-of value)))))))

(defun answer-shape (result)
  "What RESULT amounts to, as the alist a record holds: how many, and whether
none.

REQ-0038 R3. An empty answer is the single most informative event in the log --
`find' returning nothing is the cheapest true answer the service gives -- and it
is the one that leaves no trace today. So the count is recorded for every read,
and NONE is recorded separately rather than inferred from a zero, because an
operation whose answer has no countable collection returns a zero that means
`not applicable'.

The keys are tried in the order the operations return them and the first one
present wins. A result shape nothing here recognises records its type and no
count, which is honest and is what makes a new operation visible as unmodelled
rather than silently counted as empty."
  (let* ((countable '(:entities :impacted :items :seeds :documents :unresolved
                      :violations :repositories :systems :changed :problems))
         ;; Presence, not truth. GETF cannot tell a key that is absent from one
         ;; whose value is NIL, and the second is the whole subject: an empty
         ;; :ENTITIES list is `find' answering nothing, which R3 calls the most
         ;; informative event in the log. Selecting on GETF skipped exactly it
         ;; and recorded the empty answer as unremarkable.
         (key (and (listp result)
                   (find-if (lambda (k) (nth-value 0 (get-properties result (list k))))
                            countable)))
         (count (cond (key (length (getf result key)))
                      ((and (listp result) (not (keywordp (first result))))
                       (length result))
                      (t nil))))
    (append (list (cons :kind (cond (key (string-downcase (symbol-name key)))
                                    ((null result) "empty")
                                    ((listp result) "plist")
                                    (t (string-downcase (princ-to-string
                                                         (type-of result)))))))
            (when count (list (cons :count count)))
            (list (cons :none (if (or (null result) (eql count 0)) t :false))))))

(defun record-query (operation arguments result
                     &key repository seconds (directory *context-log-directory*))
  "Write one record for an answered read query, and return its id.

REQ-0038 R1. NIL and no write when DIRECTORY is NIL, which is the default and
keeps this off unless somebody turned it on -- the same tier argument DES-0030 D1
makes for the context record.

Every read operation, not only `context', because the judgements REQ-0036
collected say the answers that decided the work came from `describe',
`structure' and `find', and none of those is recorded: the operation under
measurement is the one that performed worst and the three that performed best
appear in the corpus only as its failures.

REPOSITORY is the one the query named, when it named one. STATUS names none and
that is a fact about the query rather than a gap."
  (when directory
    (let* ((id (context-record-id))
           (name (and repository (repository-name repository)))
           (root (and repository (repository-root repository)))
           (head (list (cons :id id)
                       (cons :at (format-timestamp (get-universal-time)))
                       (cons :operation (string-downcase (symbol-name operation)))
                       (cons :arguments (query-argument-alist arguments))
                       (cons :latency-seconds (or seconds 0))
                       (cons :answer (answer-shape result)))))
      (write-record-async
       id directory
       (lambda ()
         (append head
                 (list (cons :repository
                             (if repository
                                 (cons (cons :name name) (git-fingerprint root))
                                 :false))
                       (cons :loom (git-fingerprint (loom-root)))))))
      id)))

(defun seed-alist (seed)
  "One seed of BUILD-CONTEXT's instrumentation, as the alist a record holds.

Written out rather than converted, because converting a plist to an alist has
to decide where a nested plist stops and a list of them begins -- which is the
guess ALIST-OBJECT-P exists not to make. The keys are five and they are known."
  (list (cons :id (getf seed :id))
        (cons :name (getf seed :name))
        (cons :rank (getf seed :rank))
        (cons :score (getf seed :score))
        (cons :terms (loop for term in (getf seed :terms)
                           collect (list (cons :term (getf term :term))
                                         (cons :weight (getf term :weight)))))))

(defun item-alist (item)
  "One bundle item, as the alist a record holds."
  (list (cons :id (getf item :id))
        (cons :name (getf item :name))
        (cons :band (getf item :band))))

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

Not a Lisp universal time: the record is read by tools/test/acceptance.py, and a
number counting seconds from 1900 is a fact about Common Lisp rather than about
when the query was asked."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal-time 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

(define-condition context-record-error (error)
  ((id :initarg :id :reader context-record-error-id)
   (reason :initarg :reason :initform :unknown-id
           :reader context-record-error-reason))
  (:report (lambda (condition stream)
             (ecase (context-record-error-reason condition)
               (:unknown-id
                (format stream "No context record ~a."
                        (context-record-error-id condition)))
               (:feedback-off
                (format stream "Feedback is off for this deployment: no ~
context log directory is set, so no record was written and none can be. Every ~
context answer says which state it is in, on its `feedback\' field.")))))
  (:documentation "A feedback call that cannot be honoured, and which of two reasons.

A refusal rather than a new file. A record minted because somebody quoted a
wrong id is a judgement about a query nobody asked, which is CON-0001's
fabricated fact wearing the shape of evidence.

:FEEDBACK-OFF is BUG-0053. Both reasons printed \"No context record <id>\"
until 2026-08-28, and that sentence is true of a wrong id and false of a
deployment with no log directory -- where the id was never wrong, nothing was
ever written, and nothing the caller does will change that. An agent following
the prepared guidance, which instructs it to send feedback, was told its id was
bad."))

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
    (error 'context-record-error :id id :reason :feedback-off))
  ;; The record is written off the caller's path, so a caller quoting the id it
  ;; was just handed can arrive before the file does. Waited for here because
  ;; the feedback call is not what R8's latency ceiling is about, and because
  ;; the alternative is refusing a judgement over a race.
  (drain-context-log)
  (let ((record-path (context-record-path id directory))
        (entries (mapcar #'used-alist used)))
    (unless (probe-file record-path)
      (error 'context-record-error :id id))
    (write-json-record (context-use-path id directory)
                       (list (cons :id id) (cons :used entries)))
    (list :id id
          :record (read-json-record record-path)
          :used (cdr (assoc :used (read-json-record (context-use-path id directory)))))))


(defun used-alist (entry)
  "One used entry, as the alist a record holds.

ENTRY is a plist because that is what the operation layer builds from the JSON
array a caller sent. Two keys, both known."
  (if (and (consp entry) (consp (car entry)))
      entry
      (list (cons :name (getf entry :name))
            (cons :how (getf entry :how)))))
