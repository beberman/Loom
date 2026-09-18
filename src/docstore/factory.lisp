;;;; Choosing a document store: the registry and the factory.
;;;;
;;;; DES-0052. A store kind registers itself at the bottom of its own file, and
;;;; MAKE-DOCSTORE is the one place a store is built from a declaration. The
;;;; workspace parses a kind out of the repository's declaration and hands the
;;;; rest over; which keys a kind takes is the kind's own business and is
;;;; written down once, in its constructor.
;;;;
;;;; Two arguments and not one. CONFIG is what the repository declared and the
;;;; workspace never read. SERVICES is what the workspace constructed and the
;;;; same shape for every kind. A declaration is a file, so keeping them apart
;;;; is what makes a line in that file unable to supply a service.

(in-package #:loom-docstore)

(defvar *docstore-kinds* '()
  "Registered store kinds: an alist of keyword to constructor.

A constructor takes two plists, CONFIG and SERVICES, and returns a store.")

(defun register-docstore-kind (kind constructor)
  "Register CONSTRUCTOR for KIND, replacing any previous one.

Replacing rather than accumulating, for the reason REGISTER-ANALYZER gives:
recompiling a file in a live image runs its registration form again, and a
second entry for one kind would make which constructor runs depend on load
order."
  (setf *docstore-kinds*
        (cons (cons kind constructor) (remove kind *docstore-kinds* :key #'car)))
  kind)

(defun docstore-kinds ()
  "Every registered kind, sorted, for a refusal to name."
  (sort (mapcar #'car *docstore-kinds*) #'string< :key #'symbol-name))

(defun make-docstore (kind &key config services)
  "The store KIND names, built from CONFIG and SERVICES.

CONFIG is the repository's declaration, passed through untouched. SERVICES is
what the workspace supplies: the root, the functions a store may need to reach
the tree it sits on, and the two CON-0004 tables. A kind takes what it uses.

Refuses a kind nothing registered, and names the kinds that did. Falling back
to the file store would index a checkout's docs/ while the caller believed they
were reading from somewhere else, which is the one failure no count reveals."
  (let ((constructor (cdr (assoc kind *docstore-kinds*))))
    (unless constructor
      (error 'docstore-refused :ref kind
             :reason (format nil "~(~s~) is not a document store kind. Registered: ~{~(~s~)~^, ~}."
                             kind (docstore-kinds))))
    (funcall constructor config services)))

(defun config-value (config key kind &key required)
  "CONFIG's value for KEY, or NIL. Refuses when REQUIRED and absent."
  (let ((value (getf config key)))
    (when (and required (null value))
      (error 'docstore-refused :ref kind
             :reason (format nil "A ~(~a~) document store needs ~(~a~), and the ~
declaration does not give one." kind key)))
    value))

(defun check-config-keys (config known kind)
  "Refuse any key of CONFIG not in KNOWN, naming it.

Ignoring an unknown key would make a typo invisible: the workspace no longer
reads a store's declaration, so nothing else is looking. CON-0001 -- a recorded
gap beats a fact nobody wrote."
  (let ((unknown (loop for (key value) on config by #'cddr
                       do (progn value)
                       unless (member key known) collect key)))
    (when unknown
      (error 'docstore-refused :ref kind
             :reason (format nil "A ~(~a~) document store does not take ~{~(~a~)~^, ~}. ~
It takes ~{~(~a~)~^, ~}." kind unknown known)))))
