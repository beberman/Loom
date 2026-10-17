;;;; The operation registry: one table, two protocol skins.
;;;;
;;;; DES-0006's central economy. This is not a reimplementation of the
;;;; console's command table; it is a small table of (name, permission tier,
;;;; underlying function, argument shape) entries that call the *same*
;;;; functions console.lisp calls and stop one step short of console.lisp's own
;;;; formatting. DES-0005 already made the argument this leans on: "the
;;;; underlying data is already structured; only the console's formatting step
;;;; is prose."
;;;;
;;;; The struct is shaped after console.lisp's COMMAND on purpose, with two
;;;; fields a console line does not need: the tier R6 requires be declared per
;;;; entry, and enough argument shape to refuse a decoded request before the
;;;; function runs.

(in-package :synoptik-serve)

(defstruct (operation (:conc-name operation-))
  "One callable operation: what a REST route and an MCP tool both reduce to."
  (name nil)
  (tier :read)
  (function nil :type (or null function))
  (arg-shape '())
  (summary ""))

(defvar *operations* '()
  "Operations in declaration order, which is the order ALL-OPERATIONS returns
them in and the order synoptik-rest walks when it checks every entry has a route.")

(defun register-operation (operation)
  "Add OPERATION, replacing any entry of the same name. Returns the name.

Replacing rather than pushing, for DEFINE-COMMAND's own reason: redefining an
entry in a live image is the point of being in Lisp, and two entries under one
name would make dispatch depend on table order."
  (setf *operations*
        (append (remove (operation-name operation) *operations* :key #'operation-name)
                (list operation)))
  (operation-name operation))

(defmacro define-operation (name tier arguments summary &body body)
  "Declare an operation. NAME is a keyword; TIER is :read, :write or :repl.

ARGUMENTS is a list of symbols, each naming a keyword argument the decoded
request may carry, bound in BODY under that name; a symbol wrapped in a list --
(depth) -- is optional and everything else is required. One list rather than a
lambda list and a separate argument shape, because the two would be the same
information written twice and the failure mode is a shape that validates an
argument the body never reads.

Declarative for the reason DEFINE-COMMAND is: synoptik-rest walks this table to
check every entry has a route and synoptik-mcp walks it to answer tools/list, so
an entry whose declared shape is wrong is a visible failure rather than a
stale comment."
  (let ((decoded (gensym "ARGUMENTS"))
        (shape (mapcar (lambda (spec)
                         (list (intern (string (if (consp spec) (first spec) spec))
                                       :keyword)
                               (not (consp spec))))
                       arguments))
        (keys (mapcar (lambda (spec) (if (consp spec) (first spec) spec)) arguments)))
    `(register-operation
      (make-operation
       :name ,name
       :tier ,tier
       :arg-shape ',shape
       :summary ,summary
       :function (lambda (,decoded)
                   (destructuring-bind (&key ,@keys &allow-other-keys) ,decoded
                     (declare (ignorable ,@keys))
                     ,@body))))))

(defun find-operation (name)
  "The entry NAME designates, or NIL. Accepts a keyword or a string.

Both skins arrive with a string -- a route prefix, an MCP tool name -- so the
one conversion lives here rather than at each of them."
  (find (if (keywordp name) name (intern (string-upcase (string name)) :keyword))
        *operations* :key #'operation-name))

(defun all-operations () *operations*)

(defun validate-arguments (operation arguments)
  "Refuse a request missing a required argument, before the function runs.

A required argument must be present *and* non-NIL. Over HTTP an absent query
parameter and one that decoded to NIL are the same thing, so the non-NIL test
is the one that actually holds at the protocol boundary; distinguishing them
would produce two messages for one caller mistake."
  (loop for (name required) in (operation-arg-shape operation)
        when (and required (null (getf arguments name)))
          do (error 'malformed-request
                    ;; ~:[a~;an~] rather than a bare "a". Every required
                    ;; argument was consonant-initial until :SURVEY took
                    ;; `against', and "survey needs a against argument" is the
                    ;; kind of sentence a reader stops on to work out whether
                    ;; the message is about their request or about Synoptik.
                    :message (format nil "~(~a~) needs ~:[a~;an~] ~(~a~) argument."
                                     (operation-name operation)
                                     (find (char (string-downcase (string name)) 0)
                                           "aeiou")
                                     name)))
  t)

(defun refuse-domain-on-write (operation arguments)
  "Refuse a write or repl operation whose repository argument names a domain.

PLAN-0050 S13, DES-0047 R16. A domain partitions an index. It is not one, so
there is nothing `reindex' on a domain could mean that is not either a lie or a
much larger feature.

Keyed on the tier the operation struct already carries rather than on a list of
names, so an operation added later is covered by what it declares itself to be.
Checked against the table as it stands: every operation whose subject is the
index is :WRITE and every one that selects from it is :READ.

Signalled before the body runs, so a refused call has no effect at all.

The check is skipped when the designator names a whole repository, which is the
ordinary case and the one that must stay free: SPLIT-DESIGNATOR looks the whole
designator up first, so a path with slashes in it is never read as a domain."
  (when (member (operation-tier operation) '(:write :repl))
    (let ((designator (getf arguments :repository)))
      (when (and (stringp designator) (plusp (length designator)))
        (multiple-value-bind (repository domain)
            (handler-case (split-designator designator)
              ;; An unknown domain is refused by SPLIT-DESIGNATOR with a better
              ;; message than this function could write, and that refusal is
              ;; already a REQUEST-ERROR. Let it out.
              (synoptik-utils:refusal (condition) (error condition)))
          (declare (ignore repository))
          (when domain
            (error 'malformed-request
                   :message
                   (format nil "~(~a~) acts on a whole index, and ~(~a~) is one ~
domain inside it. A domain partitions an index rather than being one. Name the ~
repository alone."
                           (operation-name operation)
                           (getf domain :name)))))))))

(defvar *read-holds* nil
  "While a :READ operation runs, a cons whose car lists the repositories it was
admitted to read; NIL otherwise. REQUIRE-REPOSITORY adds to it and
INVOKE-OPERATION releases every one when the operation ends, however it ends,
so no operation body has to remember to. BUG-0079.")

(defun hold-repository-read (repository)
  "Admit the running operation to READ REPOSITORY, once, until it finishes.
False when the repository is being rebuilt. Without a hold in force, true."
  (cond ((null *read-holds*) t)
        ((member repository (car *read-holds*)) t)
        ((synoptik-workspace:acquire-repository-read repository)
         (push repository (car *read-holds*))
         t)))

(defun invoke-operation (operation grants arguments)
  "Run OPERATION for a caller holding GRANTS. The one function both skins call.

Two values: the operation's result, and an error plist when the operation
itself signalled. The split is not arbitrary. A REQUEST-ERROR is a decision
about the request -- a refused tier, a missing argument, a designator naming no
repository, a term matching no entity -- and both skins must tell those apart
from each other and from everything else to answer 403, 400 and 404 rather than
one undifferentiated failure, so it leaves here as a condition whatever depth
it was signalled at. Anything else is an outcome, and R8 requires it never
reach the wire as a bare condition or a stack trace, so it is caught and
translated here.

The clause order is what makes that true, and it is the fix for a defect this
function had when it was first written: REQUEST-ERROR is a subtype of ERROR, so
without the first clause an unknown repository came back through the guard
below indistinguishable from an analyzer blowing up.

GUARDED-CONDITION rather than the type list written out; errors.lisp carries
the argument for what it names."
  (check-capability grants (operation-tier operation)
                    :operation (operation-name operation))
  (validate-arguments operation arguments)
  (refuse-domain-on-write operation arguments)
  (let ((started (get-internal-real-time)))
    (handler-case
        (let ((result (let ((*read-holds* (and (eq :read (operation-tier operation))
                                               (list '()))))
                        (unwind-protect (funcall (operation-function operation) arguments)
                          (dolist (repository (car *read-holds*))
                            (synoptik-workspace:release-repository-read repository))))))
          (record-read-query operation arguments result
                             (/ (float (- (get-internal-real-time) started))
                                internal-time-units-per-second))
          (values result nil))
      (request-error (condition) (error condition))
      (guarded-condition (condition)
        (values nil (operation-error->plist condition))))))

(defun record-read-query (operation arguments result seconds)
  "Log an answered read, per REQ-0038 R1. Silent unless the log is on.

Here rather than in each operation because this is the one function both skins
call, so a new operation is logged by existing -- which is R1's whole argument,
and the reason the alternative (a call at the bottom of twelve operation bodies)
is one refactor away from an operation nobody remembered to instrument.

:CONTEXT is skipped and writes its own record. It is not the same record: a
judgement about ranking needs the seeds with their scores and the band each item
landed in, and that lives where the bundle is built. Both carry :OPERATION so a
reader of the directory can tell them apart, which is R2.

Writes are the excluded tier and not an oversight -- set-status, complete, watch
and init change the tree, and an audit trail has different retention and a
different permission question than a retrieval corpus.

Failure to record must never reach the caller: the answer is computed, correct,
and about to be returned, and losing it to Synoptik's own bookkeeping would be the
worst trade in the file."
  (when (and (eq :read (operation-tier operation))
             (not (eq :context (operation-name operation))))
    (ignore-errors
     (record-query (operation-name operation) arguments result
                   :repository (let ((designator (getf arguments :repository)))
                                 (and designator (find-repository designator)))
                   :seconds seconds))))
