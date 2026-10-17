;;;; A refusal: a decision about a request, carrying the sentence to show for it.
;;;;
;;;; REV-0002 A2. The vector-store guard was written twice -- REQUIRE-VECTORS in
;;;; synoptik-serve and REPOSITORY-FOR-SIMILAR in synoptik-process -- with nearly the
;;;; same four-sentence docstring and the same sentence handed to the caller,
;;;; differing only in whether it signalled MALFORMED-REQUEST or a plain ERROR.
;;;; The guard itself could not move here: its body calls REPOSITORY-VECTORS,
;;;; which is synoptik-workspace's, and this system depends on no Synoptik system. What
;;;; moved is the vocabulary, so the guard could move once to synoptik-workspace
;;;; and both skins call it.
;;;;
;;;; A subtype of ERROR and not of CONDITION, which is RULE-0004 stated as code
;;;; rather than as a caution. Every existing handler around these call sites is
;;;; written as (handler-case ... (error ...)), and a condition defined as a
;;;; direct subtype of CONDITION would pass straight through all of them --
;;;; the exact failure RULE-0004 was written from.

(in-package :synoptik-utils)

(define-condition refusal (error)
  ((message :initarg :message
            :initform "refused"
            :reader refusal-message))
  (:report (lambda (condition stream)
             (write-string (refusal-message condition) stream)))
  (:documentation "A request that will not be acted on, and the reason to show.

The reason is a finished sentence addressed to whoever made the request, not a
diagnostic: it says what is missing and what command supplies it. A surface
renders it -- the console prints it, the REST skin puts it in a 400 -- so it is
written once, where the condition is signalled, rather than once per skin.

synoptik-serve's MALFORMED-REQUEST is a subtype, so an operation may signal either
and INVOKE-OPERATION's classification is unchanged."))

(defun refuse (format &rest arguments)
  "Signal a REFUSAL whose message is FORMAT applied to ARGUMENTS."
  (error 'refusal :message (apply #'format nil format arguments)))
