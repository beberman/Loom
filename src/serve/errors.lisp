;;;; The structured-error contract (DES-0006 R8).
;;;;
;;;; Two kinds of failure reach a caller, and keeping them apart is the whole
;;;; of this file. A request that cannot be acted on as asked -- a missing
;;;; argument, a designator naming no repository, a term matching no entity --
;;;; is a decision made about the request before any work happens, and both
;;;; skins have to tell those apart from each other to answer 400 rather than
;;;; one undifferentiated failure. A condition raised by an operation that ran
;;;; is an outcome, and R8 requires it reach the wire as data rather than as a
;;;; bare condition or a stack trace.
;;;;
;;;; The classification in :NAME is coarse on purpose and recorded as such
;;;; rather than papered over: most of today's call sites signal with
;;;; (error "..."), so :NAME is the single string "SIMPLE-ERROR" for most of
;;;; them. CON-0001's posture applied to error classification -- an honest
;;;; coarse answer beats an invented taxonomy. A future document minting
;;;; no-such-repository and ambiguous-repository replaces that string without
;;;; changing this shape at all, because OPERATION-ERROR->PLIST reads TYPE-OF
;;;; regardless of how fine-grained the type is.

(in-package :synoptik-serve)

(define-condition request-error (error) ()
  (:documentation "A decision about the request rather than an outcome of it.

The family exists so that INVOKE-OPERATION can tell the two apart wherever the
condition was signalled from. A missing argument is caught before the operation
function runs and a designator naming no repository is caught inside it, but
both are the same kind of answer to the caller, and a contract where one
arrives as a condition and the other as a result plist would make the protocol
skins branch on where the check happened rather than on what it decided.

Subtypes carry the status each skin gives it: MALFORMED-REQUEST is 400,
UNKNOWN-ENTITY and UNKNOWN-OPERATION are 404, CAPABILITY-ERROR is 403."))

(define-condition malformed-request (request-error synoptik-utils:refusal)
  ((message :initarg :message
            :initform "malformed request"
            :reader request-message))
  (:report (lambda (condition stream)
             (write-string (request-message condition) stream)))
  (:documentation "A request that cannot be acted on as asked.

R8's request-level error. DES-0006 is explicit that an operation invoked
without the repository it acts on is malformed rather than ambiguous:
CURRENT-REPOSITORY's convenience of implying the sole watched repository is
right for a human who forgot to type a name and wrong for a program, which
either knows which repository it means or should ask first."))

(define-condition unknown-entity (malformed-request) ()
  (:documentation "A term that resolved to nothing in the selected graph.

A subtype rather than a sibling, because two PLAN-0005 steps ask for different
things and subtyping is what satisfies both without a third rule: step 2 wants
an unresolvable term to be a malformed request, and step 6 wants an unknown
repository to answer 400 while an unknown entity answers 404. A HANDLER-CASE
naming this clause before MALFORMED-REQUEST gets the second; anything treating
the whole family alike still gets the first."))

(define-condition unknown-operation (request-error)
  ((name :initarg :name :initform nil :reader unknown-operation-name))
  (:report (lambda (condition stream)
             (format stream "No operation named ~a.~@[ This build carries: ~{~(~a~)~^, ~}.~]"
                     (unknown-operation-name condition)
                     (registered-operation-names))))
  (:documentation "A request naming a registry entry that does not exist.
Distinct from MALFORMED-REQUEST because the answer differs: a route asking for
an operation nobody registered is a 404, not a badly formed 400.

The message names what is registered, which is BUG-0052 F4. \"No operation
named similar.\" is true of a typo, of a verb this build does not carry, and of
one that was renamed, and a caller cannot act until it knows which -- BUG-0052
was found by an agent that read the sentence and could not tell whether Synoptik
had the query at all. The list is unfiltered by tier for the reason FIND-TOOL
is: a tier the caller may not reach answers 403 through CHECK-CAPABILITY, so an
operation missing from a 404 message would be the one case where the two
refusals are confused rather than told apart."))

(defun registered-operation-names ()
  "Every registered operation name, sorted, or NIL when the table is empty.

NIL rather than an empty list, so the ~@[ above prints one sentence instead of
one sentence and an empty clause. An empty table is the state a test that binds
*OPERATIONS* can produce, and DES-0006 is explicit that a skin loaded without
synoptik-serve's entries answers 404 -- so it is a state this report has to survive.

Forward reference: ALL-OPERATIONS is in registry.lisp, which this file is
compiled before because REGISTRY.LISP names the REQUEST-ERROR class and a type
must exist when the file naming it is compiled. A function is the other way
round -- a STYLE-WARNING deferred to the end of ASDF's compilation unit, and
resolved within it."
  (sort (mapcar (lambda (operation) (string-downcase (symbol-name (operation-name operation))))
                (all-operations))
        #'string<))

(define-condition repository-indexing (request-error)
  ((message :initarg :message
            :initform "the repository is still being indexed"
            :reader request-message))
  (:report (lambda (condition stream)
             (write-string (request-message condition) stream)))
  (:documentation "A request for a repository whose index is still being built.

Not an error about the request, which is well formed, and not an answer either.
The alternative to saying so is to answer from a half-built graph, and an empty
graph is not a slow answer but a confident wrong one -- `find\' would report
that nothing matches, indistinguishable from the truthful version of itself.
CON-0001 refuses that trade, and this is the shape of the refusal.

It reads as a message rather than as a status code because both surfaces make
the message the useful part. Over REST it is R8\'s (:name :message) pair like
any other request error. Over MCP it becomes a tool result with :error true and
the text intact, which is what an agent reads and acts on -- so the message
says what to do, not merely what went wrong."))

(defun operation-error->plist (condition)
  "CONDITION as the (:name :message) pair R8 commits to.

TYPE-OF rather than a hand-maintained mapping: the point of the shape is that
it survives a future condition hierarchy arriving underneath it."
  (list :name (string (type-of condition))
        :message (princ-to-string condition)))

(deftype guarded-condition ()
  "Everything a request handler must catch. R8's type, named once.

A type rather than the same list written at each HANDLER-CASE, because the list
is the part that must not drift. It is (or serious-condition
yaml.error:yaml-error) and not ERROR: RULE-0004 and
src/analyzer/yaml-analyzer.lisp:136-146 both record that cl-yaml defines its
conditions as direct subtypes of CONDITION, so ERROR misses them -- and so does
SERIOUS-CONDITION on its own, which is the hole RULE-0004 is really about.

Here the blast radius is larger than it is for console.lisp's RUN-COMMAND, and
that is why the same rule leaves that one alone and this one widens. A mistyped
console command is one line a human is already watching fail. Hunchentoot's own
net is `handler-bind ((error ...))` (acceptor.lisp:674) with *CATCH-ERRORS-P*
defaulting to T, which is narrower than this; a condition that slips past it
reaches WITH-DEBUGGER, and under `sbcl --script`, which implies
--disable-debugger, an unhandled condition ends the *process* rather than the
worker thread. That is RULE-0004's failure mode with the whole service as the
cost."
  '(or serious-condition yaml.error:yaml-error))
