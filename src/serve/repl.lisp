;;;; The REPL tier: a stateful session, not a fresh eval per call (R9).
;;;;
;;;; DES-0006 traced what a terminal REPL actually preserves between lines and
;;;; found it is less than it looks: no lexical binding survives a form
;;;; finishing, and what does survive is only what ordinary Common Lisp already
;;;; makes global -- *PACKAGE*, and any symbol a form gave a value through SETQ,
;;;; DEFPARAMETER or DEFVAR, because a special variable's binding lives on the
;;;; symbol rather than on a stack frame. So a session needs exactly one thing a
;;;; stateless design cannot give: a package of its own that persists between
;;;; calls. Everything else falls out of Lisp.
;;;;
;;;; The distinction this file exists to keep is the one DES-0006 names
;;;; explicitly so a later implementer does not collapse it: a condition
;;;; signalled by the *submitted form* is the answer, returned as :CONDITION
;;;; inside a successful result, exactly as a real REPL prints a condition and
;;;; returns to its prompt. Only an unknown session id, text that fails at READ
;;;; before EVAL runs, or a missing argument is a request-level error. Getting
;;;; it backwards makes the REPL useless for the debugging case it exists for
;;;; while every other test still passes.
;;;;
;;;; Granting :repl is not granting a bigger :write. A submitted form can call
;;;; APPLY-TRANSACTION directly and get the graph's own lock (DES-0003) but not
;;;; DES-0004's repository-level torn-view protection, which is a property of
;;;; INDEX-REPOSITORY, POLL-ONCE and REINDEX-REPOSITORY rather than of the
;;;; graph. That is why the tier is separate and never implied.

(in-package :loom-serve)

(defstruct (repl-session (:conc-name repl-session-))
  "One open session: an opaque id, the package it reads and evaluates in, and
when it was last used.

PACKAGE and PACKAGE-NAME are both kept, and they are not the same thing. A
submitted (in-package :loom-workspace) moves PACKAGE to a package this session
does not own, and a close that deleted whatever PACKAGE pointed at would delete
LOOM-WORKSPACE out of the running image. PACKAGE-NAME is the name of the
package this session minted, and the only one it may delete."
  (id "")
  (package nil)
  (package-name "")
  (created-at 0)
  (last-used 0))

(defvar *repl-sessions* (make-hash-table :test #'equal)
  "Open sessions by id.")

(defvar *repl-session-lock* (bt:make-recursive-lock "loom-serve-repl-sessions")
  "Guards *REPL-SESSIONS*.

New state that N Hunchentoot worker threads share, so it needs a lock of its
own. This is not the \"no new locking code\" DES-0006 rules out, which is
about loom-workspace and loom-graph: nothing below this system knows these
sessions exist.

Held for lookup and mutation only, and never across an EVAL. A submitted form
may run for as long as it likes, and a second caller's REPL-CLOSE should not
wait for it.")

(defparameter *max-repl-sessions* 8
  "How many sessions may be open at once. DES-0006 asks for a small cap and a
structured error naming it, rather than an unbounded table.")

(defparameter *repl-session-idle-timeout* 1800
  "Seconds a session may go unused before the next repl call sweeps it.

Lazily, on every repl-tier operation, and deliberately not by a supervising
thread. Loom already has one thread pattern needing its own supervision story
(the per-repository monitor, DES-0003/0004), and a session retaining a little
memory until the next repl call sweeps it is a bounded, cheap cost next to a
second kind of supervised thread with the same RULE-0004 discipline to uphold.")

(defparameter *repl-session-use-list*
  '(#:cl #:loom-ontology #:loom-graph #:loom-analyzer #:loom-workspace
    #:loom-knowledge)
  "What a session's package uses: loom-serve's own list, which is known
conflict-free, so short names resolve as they do at a console `repl' prompt.

Deliberately without #:loom-process, for two reasons. loom-serve may not depend
on it at all (R5), and a form typed at a REST REPL that called CONSOLE would
hand the service's stdin to a caller who does not have one.")

(defun repl-session-count ()
  (bt:with-recursive-lock-held (*repl-session-lock*)
    (hash-table-count *repl-sessions*)))

(defun drop-repl-session (session)
  "Forget SESSION and delete the package it minted.

DES-0006 does not say to delete it. Leaving it interned leaks one package per
session for the life of the process, which is exactly the unbounded cost the
cap exists to prevent."
  (remhash (repl-session-id session) *repl-sessions*)
  (let ((package (find-package (repl-session-package-name session))))
    (when package (ignore-errors (delete-package package)))))

(defun sweep-repl-sessions ()
  "Drop every session idle longer than *REPL-SESSION-IDLE-TIMEOUT*.
Returns how many were dropped."
  (let ((cutoff (- (get-universal-time) *repl-session-idle-timeout*))
        (stale '()))
    (bt:with-recursive-lock-held (*repl-session-lock*)
      (maphash (lambda (id session)
                 (declare (ignore id))
                 (when (<= (repl-session-last-used session) cutoff)
                   (push session stale)))
               *repl-sessions*)
      (dolist (session stale) (drop-repl-session session)))
    (length stale)))

(defun require-repl-session (id)
  "The session ID names, or a request-level error.

An unknown id is a malformed request and not a REPL answer: there is no session
to have answered it. This is the near half of the distinction this file exists
to keep."
  (or (bt:with-recursive-lock-held (*repl-session-lock*) (gethash id *repl-sessions*))
      (error 'malformed-request
             :message (format nil "No REPL session ~a. It may have been swept; open another."
                              id))))

(defun repl-open ()
  "Mint a session. Returns (:session <id> :package <name>)."
  (sweep-repl-sessions)
  (bt:with-recursive-lock-held (*repl-session-lock*)
    (when (>= (hash-table-count *repl-sessions*) *max-repl-sessions*)
      ;; A request-level refusal rather than an operation outcome: nothing ran,
      ;; and the caller's next move is to close a session rather than to read a
      ;; result.
      (error 'malformed-request
             :message (format nil "~d REPL sessions are already open, which is the limit. Close one first."
                              *max-repl-sessions*)))
    (let* ((id (random-uuid:to-string (random-uuid:make-uuid)))
           (name (format nil "LOOM-REPL-~a" (string-upcase id)))
           (package (make-package name :use *repl-session-use-list*))
           (now (get-universal-time)))
      (setf (gethash id *repl-sessions*)
            (make-repl-session :id id :package package :package-name name
                               :created-at now :last-used now))
      (list :session id :package name))))

(defun repl-read (text)
  "TEXT as one form, or a request-level error.

READ failing is the caller's text being unreadable, which happened before
anything was evaluated and is therefore a malformed request rather than a
condition the session answered with. Only the first form is read: a line
carrying two is a REPL line carrying two, and a real REPL would have prompted
between them."
  (handler-case (read-from-string text)
    (guarded-condition (condition)
      (error 'malformed-request
             :message (format nil "Could not read ~s: ~a" text condition)))))

(defun repl-eval (session-id text)
  "Evaluate TEXT in SESSION-ID's package. Returns (:output :values :condition).

:CONDITION is NIL on success and a (:name :message) plist when the submitted
form signalled -- which is an answer and not a failure, so the result is a
successful one and the session is still usable afterwards."
  (sweep-repl-sessions)
  (let* ((session (require-repl-session session-id))
         (output (make-string-output-stream))
         (printed '())
         (failure nil))
    (let ((*package* (repl-session-package session)))
      (let ((form (repl-read text)))
        (handler-case
            (let ((results (multiple-value-list
                            (let ((*standard-output* output)) (eval form)))))
              (setf printed (mapcar #'prin1-to-string results)))
          (guarded-condition (condition)
            (setf failure (operation-error->plist condition)))))
      ;; Whatever *PACKAGE* ended as, so a submitted (in-package :loom-workspace)
      ;; sticks for the *next* call, matching a real REPL line by line. Stored
      ;; even when the form signalled: a failing form can still have moved it.
      (setf (repl-session-package session) *package*))
    (bt:with-recursive-lock-held (*repl-session-lock*)
      (setf (repl-session-last-used session) (get-universal-time)))
    (list :output (get-output-stream-string output)
          :values printed
          :condition failure)))

(defun repl-close (session-id)
  "Drop SESSION-ID and delete the package it minted."
  (sweep-repl-sessions)
  (let ((session (require-repl-session session-id)))
    (bt:with-recursive-lock-held (*repl-session-lock*)
      (drop-repl-session session))
    (list :session session-id :closed t)))

;;;; ==================================================================
;;;; The three registry entries
;;;; ==================================================================

(define-operation :repl-open :repl ()
    "Open a REPL session in this image and return its id."
  (repl-open))

(define-operation :repl-eval :repl (session text)
    "Evaluate one form in an open session."
  (repl-eval session text))

(define-operation :repl-close :repl (session)
    "Close a session and delete the package it was using."
  (repl-close session))
