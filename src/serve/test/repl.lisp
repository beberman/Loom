;;;
;;; Tests for src/serve/repl.lisp -- what a session preserves, what it does
;;; not, and which failures are answers rather than request errors.
;;;
;;; Every test opens its own sessions and closes them in an UNWIND-PROTECT: a
;;; leaked session leaves a package interned and counts against the cap, which
;;; would make the cap test fail somewhere else entirely.
;;;

(in-package :loom-serve-test)

(def-suite repl
  :in all-tests
  :description "REPL sessions: persistence, bounds, and the two kinds of failure.")

(in-suite repl)

(defmacro with-repl-session ((id) &body body)
  `(let ((,id (getf (repl-open) :session)))
     (unwind-protect (progn ,@body)
       (ignore-errors (repl-close ,id)))))

;;; ------------------------------------------------------------------
;;; What a session preserves (R9's whole argument for a session)
;;; ------------------------------------------------------------------

(test in-package-persists-between-calls
  ;; The argument for a session over a stateless eval, as an assertion. A
  ;; stateless design fails this by construction, and DES-0006's point is
  ;; that in-package persisting is baseline terminal-REPL behaviour rather
  ;; than an enhancement over it.
  (with-repl-session (id)
    (repl-eval id "(in-package :loom-workspace)")
    (let ((result (repl-eval id "*package*")))
      (is (null (getf result :condition)))
      (is (search "LOOM-WORKSPACE" (first (getf result :values)))
          "the package did not survive the call: ~s" (getf result :values)))))

(test a-defparameter-persists-and-a-let-does-not
  ;; The negative half is what makes this a description of a real REPL rather
  ;; than of an aspiration: no lexical binding survives a form finishing, at a
  ;; terminal prompt or here.
  (with-repl-session (id)
    (repl-eval id "(defparameter *x* 1)")
    (let ((result (repl-eval id "*x*")))
      (is (null (getf result :condition)))
      (is (equal '("1") (getf result :values))))
    (repl-eval id "(let ((y 2)) y)")
    (let ((result (repl-eval id "y")))
      (is (not (null (getf result :condition)))
          "a lexical binding survived the form that made it"))))

(test output-written-by-a-form-comes-back-as-output
  (with-repl-session (id)
    (let ((result (repl-eval id "(progn (princ \"hello\") 42)")))
      (is (equal "hello" (getf result :output)))
      (is (equal '("42") (getf result :values))))))

;;; ------------------------------------------------------------------
;;; The two kinds of failure (DES-0006's named risk)
;;; ------------------------------------------------------------------

(test a-form-that-signals-is-an-answer-not-a-failure
  ;; The CON-0003 witness for this step. The natural wrong implementation --
  ;; treat every condition a submitted form raises as a failed request --
  ;; passes every other test in this file and makes the REPL useless for
  ;; exactly the debugging case R9 exists for.
  (with-repl-session (id)
    (let ((result (repl-eval id "(error \"boom\")")))
      (is (equal "SIMPLE-ERROR" (getf (getf result :condition) :name)))
      (is (equal "boom" (getf (getf result :condition) :message))))
    ;; And the session is still usable, which is the other half of "a real
    ;; REPL prints the condition and returns to its prompt".
    (let ((result (repl-eval id "(+ 1 1)")))
      (is (null (getf result :condition)))
      (is (equal '("2") (getf result :values))))))

(test an-unknown-session-id-is-a-request-error
  ;; Asserted beside the case above so the difference is visible in one place:
  ;; there is no session to have answered, so this is a malformed request and
  ;; not a :CONDITION inside a result.
  (signals malformed-request (repl-eval "no-such-session" "(+ 1 1)"))
  (with-repl-session (id)
    (is (not (null (getf (repl-eval id "(error \"boom\")") :condition)))
        "and a real session answers rather than signalling")))

(test text-that-will-not-read-is-a-request-error
  ;; READ fails before EVAL ever runs, so nothing was asked and nothing
  ;; answered. DES-0006 names this case explicitly.
  (with-repl-session (id)
    (signals malformed-request (repl-eval id "(+ 1"))))

;;; ------------------------------------------------------------------
;;; Bounds
;;; ------------------------------------------------------------------

(test the-cap-is-refused-and-says-what-it-is
  (let ((*max-repl-sessions* 2)
        (opened '()))
    (unwind-protect
         (progn
           (push (getf (repl-open) :session) opened)
           (push (getf (repl-open) :session) opened)
           (let ((condition (handler-case (progn (repl-open) nil)
                              (malformed-request (c) c))))
             (is-true condition "a third session opened past a cap of two")
             (when condition
               (is (search "2" (princ-to-string condition))
                   "the refusal does not name the limit: ~a" condition))))
      (dolist (id opened) (ignore-errors (repl-close id))))))

(test an-idle-session-is-swept-by-the-next-call
  (let ((*repl-session-idle-timeout* 0))
    (let* ((first-session (repl-open))
           (id (getf first-session :session))
           (package-name (getf first-session :package)))
      (unwind-protect
           (let ((second-id (getf (repl-open) :session)))
             (unwind-protect
                  (progn
                    (signals malformed-request (repl-eval id "(+ 1 1)"))
                    ;; The DELETE-PACKAGE half: a session that is forgotten but
                    ;; whose package stays interned leaks one package per
                    ;; session for the life of the process.
                    (is (null (find-package package-name))))
               (ignore-errors (repl-close second-id))))
        (ignore-errors (repl-close id))))))

(test a-session-deletes-only-the-package-it-minted
  ;; The trap this avoids is not hypothetical: a close that deleted whatever
  ;; the session's *PACKAGE* currently points at would delete LOOM-WORKSPACE
  ;; out of the running image the moment a caller typed (in-package
  ;; :loom-workspace).
  (let* ((session (repl-open))
         (id (getf session :session))
         (package-name (getf session :package)))
    (repl-eval id "(in-package :loom-workspace)")
    (repl-close id)
    (is (null (find-package package-name)))
    (is (not (null (find-package "LOOM-WORKSPACE")))
        "closing a session deleted a package it did not mint")))

;;; ------------------------------------------------------------------
;;; The tier (R9, at the real entry rather than at a fixture)
;;; ------------------------------------------------------------------

(test repl-is-never-implied-by-write
  ;; Overlaps the fixture test in registry.lisp deliberately: that one tests
  ;; the mechanism, this one tests the entry a caller actually reaches, and
  ;; R9 is explicit enough about it to deserve both. Granting :repl is
  ;; granting the ability to reach beneath every lock DES-0003 and DES-0004
  ;; built, not merely the four write operations sitting on top of them.
  (signals capability-error
    (invoke-operation (find-operation :repl-open) '(:read :write) '()))
  (dolist (name '(:repl-eval :repl-close))
    (signals capability-error
      (invoke-operation (find-operation name) '(:read :write)
                        (list :session "x" :text "(+ 1 1)")))))
