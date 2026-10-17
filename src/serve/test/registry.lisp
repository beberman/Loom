;;;
;;; Tests for src/serve/registry.lisp, capability.lisp and errors.lisp --
;;; the tier check, the argument check, and the condition guard every
;;; operation invocation passes through.
;;;
;;; Fixture operations rather than the real ones: this file is about the
;;; mechanism, and a test that needed a watched repository to prove that a
;;; missing argument is refused would be testing two things and failing for
;;; either. *OPERATIONS* is rebound around each one so a fixture entry cannot
;;; survive into the real table.
;;;

(in-package :synoptik-serve-test)

(def-suite registry
  :in all-tests
  :description "The operation registry, the capability seam, and the error contract.")

(in-suite registry)

(define-condition fixture-yaml-condition (yaml.error:yaml-error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (write-string "malformed fixture document" stream)))
  (:documentation "Shaped exactly like cl-yaml's own conditions: a direct
subtype of CONDITION, reached through YAML-ERROR, and therefore neither an
ERROR nor a SERIOUS-CONDITION. RULE-0004 exists because of this shape, and a
fixture that was an ordinary ERROR would let a handler naming ERROR pass the
test it is written to fail."))

;;; ------------------------------------------------------------------
;;; The tier check (R6, R9)
;;; ------------------------------------------------------------------

(test an-unknown-tier-is-refused-rather-than-ranked
  ;; The CON-0003 witness for R6. A tier system implemented as an ordered
  ;; level -- read < write < repl -- passes every other test in this system
  ;; and fails only this one, because a caller holding the top of the order
  ;; would be handed the tier that can reach beneath DES-0004's locks.
  (let ((*operations* '()))
    (define-operation :fixture-repl :repl () "A fixture at the repl tier."
      (list :ran t))
    (signals capability-error
      (invoke-operation (find-operation :fixture-repl) '(:read :write) '()))
    ;; And the same entry runs for a caller that was actually granted it, so
    ;; the refusal above is a tier check rather than an entry that never works.
    (is (equal '(:ran t)
               (invoke-operation (find-operation :fixture-repl) '(:repl) '())))))

(test a-granted-tier-is-not-implied-by-any-other
  ;; The other half of "a set, not a level": :write does not imply :read.
  (let ((*operations* '()))
    (define-operation :fixture-read :read () "A fixture at the read tier."
      (list :ran t))
    (signals capability-error
      (invoke-operation (find-operation :fixture-read) '(:write) '()))))

;;; ------------------------------------------------------------------
;;; The error contract (R8)
;;; ------------------------------------------------------------------

(test a-condition-becomes-a-name-and-a-message
  (let ((*operations* '()))
    (define-operation :fixture-boom :read () "A fixture that signals."
      (error "boom"))
    (multiple-value-bind (result failure)
        (invoke-operation (find-operation :fixture-boom) '(:read) '())
      (is (null result))
      (is (equal '(:name "SIMPLE-ERROR" :message "boom") failure)
          "the condition reached the caller as ~s" failure))))

(test a-condition-that-is-not-an-error-is-still-caught
  ;; RULE-0004. cl-yaml defines its conditions as direct subtypes of
  ;; CONDITION, so a guard naming ERROR does not catch them and one naming
  ;; SERIOUS-CONDITION alone does not either. Both are plausible
  ;; implementations and both fail here, which is the point of shaping the
  ;; fixture condition like cl-yaml's rather than like an ordinary error.
  ;;
  ;; What it costs when the guard has this hole is not a bad message: it is
  ;; the whole process. Hunchentoot's own net names ERROR, and under
  ;; `sbcl --script' -- which implies --disable-debugger -- a condition that
  ;; escapes it ends the process rather than the worker thread.
  (let ((*operations* '()))
    (define-operation :fixture-yaml :read () "A fixture that signals like cl-yaml."
      (error 'fixture-yaml-condition))
    (multiple-value-bind (result failure)
        (invoke-operation (find-operation :fixture-yaml) '(:read) '())
      (is (null result))
      (is (equal "FIXTURE-YAML-CONDITION" (getf failure :name)))
      (is (equal "malformed fixture document" (getf failure :message))))))

(test a-request-error-signalled-inside-an-operation-is-not-swallowed
  ;; The witness for INVOKE-OPERATION's clause order. REQUEST-ERROR is a
  ;; subtype of ERROR, so the obvious implementation -- one guard around the
  ;; call -- returns an unknown repository through the same path as an analyzer
  ;; blowing up, and the skin above has nothing left to tell 400 from 500 with.
  ;; This is what the first draft of this file did.
  (let ((*operations* '()))
    (define-operation :fixture-refuses :read () "A fixture that refuses."
      (error 'malformed-request :message "no such thing"))
    (signals malformed-request
      (invoke-operation (find-operation :fixture-refuses) '(:read) '()))))

;;; ------------------------------------------------------------------
;;; The argument check
;;; ------------------------------------------------------------------

(test a-missing-required-argument-is-a-malformed-request
  ;; The flag is the assertion that matters. A validation step that runs
  ;; after the function has already been called is not a validation step,
  ;; and nothing else in this test would notice.
  (let ((*operations* '())
        (ran nil))
    (define-operation :fixture-args :read (target (depth)) "A fixture with arguments."
      (setf ran (list target depth)))
    (signals malformed-request
      (invoke-operation (find-operation :fixture-args) '(:read) '(:depth 3)))
    (is-false ran "the function ran before its arguments were validated")
    ;; The optional one is genuinely optional.
    (is (equal '("x" nil)
               (invoke-operation (find-operation :fixture-args) '(:read) '(:target "x"))))))

(test a-malformed-request-names-the-argument-it-wanted
  (let ((*operations* '()))
    (define-operation :fixture-args :read (target) "A fixture with arguments."
      target)
    (let ((condition (handler-case
                         (progn (invoke-operation (find-operation :fixture-args)
                                                  '(:read) '())
                                nil)
                       (malformed-request (c) c))))
      (is-true condition)
      (when condition
        (let ((text (princ-to-string condition)))
          (is (search "target" text) "the message does not name the argument: ~a" text)
          (is (search "fixture-args" text)
              "the message does not name the operation: ~a" text))))))

;;; ------------------------------------------------------------------
;;; The table itself
;;; ------------------------------------------------------------------

(test defining-an-operation-twice-replaces-it
  (let ((*operations* '()))
    (define-operation :fixture-twice :read () "first" (list :ran :first))
    (define-operation :fixture-twice :read () "second" (list :ran :second))
    (is (= 1 (length (all-operations))))
    (is (equal "second" (operation-summary (find-operation :fixture-twice))))))

(test an-operation-is-found-by-keyword-or-by-string
  ;; Both skins arrive with a string: a route prefix, an MCP tool name.
  (let ((*operations* '()))
    (define-operation :fixture-named :read () "A fixture." nil)
    (is (not (null (find-operation :fixture-named))))
    (is (not (null (find-operation "fixture-named"))))
    (is (null (find-operation "no-such-operation")))))

(test the-static-grant-set-withholds-repl
  ;; resolve-caller-grants is a seam returning a static answer, which is what
  ;; DES-0006 commits to and REQ-0008 excludes the rest of. The assertion
  ;; worth making about it today is the one that is a decision rather than a
  ;; placeholder: no caller is granted :repl while the credential story is
  ;; unfinished.
  (let ((grants (resolve-caller-grants nil)))
    (is-true (member :read grants))
    (is-true (member :write grants))
    (is-false (member :repl grants))))
