;;;; Capability checking (ARCH-0006 R6).
;;;;
;;;; One seam, checked once per request, for both protocols. That is what makes
;;;; "protocol is not a proxy for trust" a property of loom-serve rather than a
;;;; discipline each protocol adapter has to remember separately: a caller's
;;;; reachable operations are a function of its resolved grants alone, and are
;;;; identical whether the request arrived as an HTTP route or a JSON-RPC tool
;;;; call.

(in-package :loom-serve)

(define-condition capability-error (request-error)
  ((operation :initarg :operation :initform nil :reader capability-error-operation)
   (tier :initarg :tier :initform nil :reader capability-error-tier))
  (:report (lambda (condition stream)
             (format stream "~@[~(~a~) ~]requires the ~(~a~) capability."
                     (capability-error-operation condition)
                     (capability-error-tier condition))))
  (:documentation "A caller reached an operation whose tier it was not granted.
Named and caught like any other condition R8 translates, so it becomes a
403-shaped answer rather than a raw Lisp condition."))

(defparameter *static-grants* '(:read :write)
  "What RESOLVE-CALLER-GRANTS answers until a credential format is decided.

A variable rather than a literal inside the function for one reason worth
stating: the refusal path is the half of a capability system that has to be
tested, and a test cannot exercise it by binding a special -- the thread that
resolves grants is a Hunchentoot worker, and a binding made in the test thread
is invisible to it. A variable a test can SETF and restore is what makes
\"a read-only caller gets 403\" an assertion rather than a hope.")

(defun resolve-caller-grants (credential)
  "The set of tiers CREDENTIAL is granted.

The seam, and deliberately only the seam. REQ-0008 excludes the auth model and
ARCH-0006 R6 names this exact function as where it will land; what is
committed to today is that the seam exists, is single, and is called once per
request by both skins before dispatch. A static token-to-grants table is the
obvious first cut and is a future document's decision.

Until then every caller gets :read and :write, and deliberately not :repl. The
repl tier can reach beneath every safety property ARCH-0003 and ARCH-0004
built -- a submitted form can call APPLY-TRANSACTION directly and get the
graph's own lock but not the repository-level torn-view protection -- so it is
not a tier to hand out by default while the credential story is unfinished."
  (declare (ignore credential))
  *static-grants*)

(defun check-capability (grants required-tier &key operation)
  "Refuse unless REQUIRED-TIER is one of GRANTS. True when it is.

GRANTS is a set, tested with MEMBER, and never a magnitude compared against an
ordering. R6 and R9 both turn on that: :write must not imply :read, and :repl
must never be implied by :write. A tier system implemented as an ordered level
would pass every other test in this system and quietly hand every writer the
one tier that reaches beneath ARCH-0004's locks."
  (unless (member required-tier grants)
    (error 'capability-error :operation operation :tier required-tier))
  t)
