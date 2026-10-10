;;;; Reading a scalar a human typed at a console or a client sent as a parameter.
;;;;
;;;; REV-0002 C2 and A2. These were loom-serve's, and console.lisp had its own
;;;; RESOLVE-COUNT doing the same PARSE-INTEGER walk with the same
;;;; full-length check. The two systems are peers and neither may depend on the
;;;; other, so the policy could only be stated once by moving it below both.
;;;;
;;;; The policy, unchanged by the move: junk is refused rather than truncated or
;;;; read as false. `depth 3x' meaning 3 is a guess about intent, and a wrong
;;;; guess about a bound is invisible in the output because the report is simply
;;;; smaller than the caller asked for. REV-0001 finding 4 is about exactly that.
;;;;
;;;; game-server BUG-0001 is what this shape answers. That tree decodes an
;;;; integer by signalling on junk and a boolean by returning false on junk,
;;;; three lines apart in one function, and has three exported predicates
;;;; disagreeing about what a number is. The lesson is not that strict beats
;;;; permissive -- it is that the policy must be stated once and shared, because
;;;; the two branches there were written by the same author on the same day and
;;;; still disagreed. Which is the argument for this file being one file.
;;;;
;;;; ~/lisp/utils carries STRING-IS-INT and STRING-TO-NUMBER, which REV-0002 C2
;;;; scored at 0.776 against IS-INTEGER-P, and they were not adopted. Two
;;;; contract differences decided it: STRING-IS-INT accepts a leading + or -,
;;;; where a negative depth is refused here by REQUEST-INTEGER's own range
;;;; check, and STRING-TO-NUMBER returns 3.5 for "3.5" where TO-INTEGER returns
;;;; NIL. Adopting it would also put an external dependency on the peer skins
;;;; to save four lines.

(in-package :loom-utils)

(defparameter *true-tokens* '("true" "t" "1" "yes" "on")
  "Spellings of true a caller may send. Compared case-insensitively.

Wider than a JSON boolean because a query string has no booleans: `?source=1'
and `?source=true' are both ordinary, and refusing one would make the REST
surface stricter than the MCP one for no reason a caller could discover.")

(defparameter *false-tokens* '("false" "nil" "0" "no" "off")
  "Spellings of false. An explicit false is a request and not junk, so it is
enumerated rather than left to fall through -- the whole point of BUG-0031's
sibling defect is that unreadable input must not arrive at the same answer an
author deliberately asked for.")

(defun to-integer (value)
  "VALUE as an integer, or NIL when it is not one.

A partial parse is not an integer: \"3x\" is a question about intent and
REV-0001 finding 4 is why it is not answered as 3."
  (typecase value
    (integer value)
    (string (multiple-value-bind (n end) (parse-integer value :junk-allowed t)
              (and n (= end (length value)) n)))
    (t nil)))

(defun is-integer-p (value)
  "True when VALUE can be read as an integer -- already one, or a string
spelling one exactly. TO-INTEGER is the reader.

Written in terms of TO-INTEGER rather than beside it. The two carried the same
PARSE-INTEGER walk in two functions until REV-0002 C2, and 0 is why that is safe
to collapse: TO-INTEGER answers 0 for \"0\", which is true, and NIL only for
input that is not an integer at all."
  (and (to-integer value) t))

(defun to-boolean (value)
  "VALUE as a boolean, and a second value saying whether it could be read.

Two values because one cannot carry the answer: NIL is both a legitimate false
and the only thing an unreadable value could return, and collapsing them is
precisely game-server BUG-0001's silent misread. A caller that ignores the
second value has written the bug that report is about."
  (cond ((eq value t) (values t t))
        ((eq value :true) (values t t))
        ((eq value :false) (values nil t))
        ((and (stringp value) (member value *true-tokens* :test #'string-equal))
         (values t t))
        ((and (stringp value) (member value *false-tokens* :test #'string-equal))
         (values nil t))
        (t (values nil nil))))

(defun is-boolean-p (value)
  "True when VALUE can be read as a boolean. TO-BOOLEAN is the reader.

T counts, and so does every spelling in *TRUE-TOKENS* and *FALSE-TOKENS*. NIL
does not: an absent argument and an argument spelled `false' are different
requests, and every caller distinguishes them by testing for NIL first."
  (nth-value 1 (to-boolean value)))

(defun to-cosine (value)
  "VALUE as a single float, or NIL when it does not spell a decimal number.

Digits and at most one point, parsed by hand. console.lisp reads its cut with
READ-FROM-STRING, which is safe at a console a human types at and not at a query
parameter: the reader interns whatever symbol it is handed, and with *READ-EVAL*
left alone a #. is evaluated. Restricting the character set first and doing the
arithmetic afterwards costs six lines and reaches no reader."
  (typecase value
    (real (float value 1.0))
    (string
     (let ((dot (position #\. value)))
       (when (and (some #'digit-char-p value)
                  (every (lambda (c) (or (digit-char-p c) (char= c #\.))) value)
                  (or (null dot) (null (position #\. value :start (1+ dot)))))
         (/ (float (parse-integer (remove #\. value)) 1.0)
            (expt 10 (if dot (- (length value) dot 1) 0))))))
    (t nil)))

(defun distribution-name-key (name)
  "NAME under PEP 503 normalisation: lower case, each run of `-', `_' and `.'
made one `-'. DES-0055 D6.

This is pip's own rule for when two names are one distribution, so comparing
keys is exact. It is for comparing a distribution name with a distribution
name only; an import name is never compared with one, because googleapiclient
and google-api-python-client differ by more than separators (U1)."
  (with-output-to-string (out)
    (let ((in-run nil))
      (loop for c across name
            do (if (find c "-_.")
                   (unless in-run
                     (setf in-run t)
                     (write-char #\- out))
                   (progn (setf in-run nil)
                          (write-char (char-downcase c) out)))))))
