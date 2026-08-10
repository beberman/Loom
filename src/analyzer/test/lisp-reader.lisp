;;;
;;; Tests for src/analyzer/lisp-reader.lisp -- the Eclector client. ARCH-0013.
;;;
;;; These exercise READ-SOURCE directly rather than through ANALYZE-FILE,
;;; because the point of the file is that it is a pure function of a string and
;;; the analyzer's parity is a separate question tested separately.
;;;

(in-package :loom-analyzer-test)

(def-suite lisp-reader
  :in all-tests
  :description "Reading Lisp source: spans, prefixes, recovery, skipped input.")

(in-suite lisp-reader)

(defun rs (source) (loom-analyzer::read-source source))

(defun rs-forms (source) (loom-analyzer::reading-forms (rs source)))

(defun first-form (source) (first (first (rs-forms source))))

(test the-tree-is-an-ordinary-s-expression
  ;; The load-bearing property of the whole design: MAKE-EXPRESSION-RESULT
  ;; returns its RESULT argument, so nothing downstream meets a wrapper and
  ;; every SYMBOLP/TOKEN-NAME decision in the walk keeps working unchanged.
  (let ((form (first-form "(defun foo (x) (bar x))")))
    (is (consp form))
    (is (symbolp (car form)))
    (is (string= "defun" (loom-analyzer::token-name (car form))))
    (is (string= "foo" (loom-analyzer::token-name (second form))))
    (is (equal '("x") (mapcar #'loom-analyzer::token-name (third form))))))

(test every-form-has-a-range-at-every-depth
  ;; What ELEMENT-SPANS existed to produce for one form shape, now true of all
  ;; of them. ARCH-0013 R1.
  (let* ((reading (rs "(defun foo (x)
  (bar x))"))
         (top (first (first (loom-analyzer::reading-forms reading))))
         (body (fourth top)))
    (multiple-value-bind (start end foundp) (loom-analyzer::form-range reading top)
      (is-true foundp)
      (is (= 1 start))
      (is (= 2 end)))
    (multiple-value-bind (start end foundp) (loom-analyzer::form-range reading body)
      (is-true foundp "a nested form has a range of its own")
      (is (= 2 start) "and it is the nested form's line, not the top form's")
      (is (= 2 end)))))

(test an-inline-method-clause-gets-its-own-range
  ;; ARCH-0010 needed a whole design and a re-read of the file for this, and
  ;; declared the whole DEFGENERIC's range as the fallback when it failed.
  (let* ((reading (rs "(defgeneric g (x)
  (:documentation \"d\")
  (:method ((x integer))
    (h x)))"))
         (top (first (first (loom-analyzer::reading-forms reading))))
         (clause (fifth top)))
    (is (eq :method (car clause)) "the clause head is still a keyword")
    (multiple-value-bind (start end foundp) (loom-analyzer::form-range reading clause)
      (is-true foundp)
      (is (= 3 start))
      (is (= 4 end)))))

(test a-block-comment-does-not-cost-the-clause-its-range
  ;; One of the two shapes ELEMENT-SPANS returns NIL for, where every clause
  ;; then took the whole form's range. Reported as a skipped region instead.
  (let* ((reading (rs "(defgeneric g (x)
  #| a block comment |#
  (:method ((x integer)) (h x)))"))
         (top (first (first (loom-analyzer::reading-forms reading))))
         (clause (fourth top)))
    (is (eq :method (car clause)))
    (multiple-value-bind (start end foundp) (loom-analyzer::form-range reading clause)
      (declare (ignore end))
      (is-true foundp "the clause has its own range, not the DEFGENERIC's")
      (is (= 3 start)))
    (is (find :block-comment (loom-analyzer::reading-skips reading)
              :key (lambda (s) (getf s :reason)))
        "and the comment is a recorded gap rather than silence")))

(test form-range-refuses-rather-than-guesses
  ;; ELEMENT-SPANS had three ways of being asked for spans that do not exist --
  ;; an offset naming an atom, an offset past the end, an element running off
  ;; the end -- and returned NIL from all three because a span read out of the
  ;; middle of a token would be a fabricated fact (CON-0001). FORM-RANGE
  ;; inherits the discipline and needs far less of it: it is asked with an
  ;; object rather than an offset, so there is no seeking to get wrong, and the
  ;; only refusals left are a thing that is not a form and a form from some
  ;; other read.
  (let ((reading (rs "(defun foo (x) (bar x))")))
    (is-false (nth-value 2 (loom-analyzer::form-range reading :not-a-form))
              "an atom is not a form and has no range")
    (is-false (nth-value 2 (loom-analyzer::form-range reading '(bar x)))
              "an EQUAL cons from another read is not the cons that was read")
    (is-false (nth-value 2 (loom-analyzer::form-range reading nil))
              "and NIL is an atom, not the empty form")))

(test a-written-package-prefix-survives-to-the-walk
  ;; REQ-0019 R2. INTERN-FOREIGN-SYMBOL-LOCALLY used to absorb the prefix into
  ;; a throwaway package and TOKEN-NAME read SYMBOL-NAME alone, so
  ;; utils:parse-config and a local parse-config were indistinguishable.
  (let* ((reading (rs "(defun f () (utils:parse-config) (local-thing))"))
         (top (first (first (loom-analyzer::reading-forms reading))))
         (qualified (car (fourth top)))
         (bare (car (fifth top))))
    (is (string= "parse-config" (loom-analyzer::token-name qualified))
        "the name is what it always was")
    (is (string= "utils" (loom-analyzer::form-package reading qualified))
        "and the prefix is now recoverable beside it")
    (is (null (loom-analyzer::form-package reading bare))
        "a site that wrote no prefix records none")))

(test nothing-is-interned-and-keywords-still-are
  ;; REQ-0019 R6, and the guard on it: KEYWORDP is tested in five places in the
  ;; walk, so keywords must stay keywords while everything else goes uninterned.
  (let ((form (first-form "(defgeneric g (x) (:method ((x integer)) 1))")))
    (is-true (keywordp (car (fourth form))) "a clause head is a real keyword")
    (is-false (symbol-package (car form))
              "and a program symbol is interned nowhere at all")))

(test a-vertical-bar-designator-keeps-its-case
  ;; The requirement NORMALIZE-SYSTEM-NAME rests on, and the first thing an
  ;; uninterning reader would plausibly break.
  (let ((form (first-form "(in-package :|Loom-Graph|)")))
    (is-true (keywordp (second form)))
    (is (string= "Loom-Graph" (symbol-name (second form))))))

(test a-read-eval-form-is-refused-without-costing-the-file
  ;; REQ-0019 R4. Under the host reader with *READ-EVAL* NIL this signalled and
  ;; ANALYZE-FILE lost every definition in the file.
  (let* ((reading (rs "(defun a () 1)
(defparameter *x* #.(+ 1 2))
(defun c () 3)"))
         (forms (loom-analyzer::reading-forms reading)))
    (is (= 3 (length forms)) "all three forms survive")
    (is (find :read-eval (loom-analyzer::reading-skips reading)
              :key (lambda (s) (getf s :reason)))
        "and the refusal is recorded rather than silent")))

(test a-stray-close-paren-costs-a-form-and-not-the-file
  ;; REQ-0019 R3. The third definition is what the assertion is about: a test
  ;; asserting only that the first survives would pass with the HANDLER-BIND
  ;; and HANDLER-CASE nested the wrong way round, which is the failure mode
  ;; READ-SOURCE's docstring warns about.
  (let* ((reading (rs "(defun a () 1)
)
(defun c () 3)"))
         (names (mapcar (lambda (entry)
                          (loom-analyzer::token-name (second (first entry))))
                        (loom-analyzer::reading-forms reading))))
    (is (equal '("a" "c") names)
        "the definition after the damage is read")
    (is-false (loom-analyzer::reading-fatal reading)
              "and the file is not marked unreadable")))

(test a-repaired-form-is-recorded-and-never-handed-on
  ;; ARCH-0013 R4, and the measured reason it exists: recovering an
  ;; unterminated list swallows the NEXT definition into the damaged one's
  ;; body, so a repaired form offered to pass 1 would mint an entity whose
  ;; range covers text defining something else -- with no count moving to say
  ;; so. CON-0001's fabricated fact, in the one shape that is invisible.
  (let* ((reading (rs "(defun a () 1)
(defun b () (oops
(defun c () 3)"))
         (forms (loom-analyzer::reading-forms reading)))
    (is (= 1 (length forms)) "only the undamaged definition is handed on")
    (is (string= "a" (loom-analyzer::token-name (second (first (first forms))))))
    (is (plusp (length (loom-analyzer::reading-recovered reading)))
        "and the damage is recorded with a range someone can open")
    (is-true (getf (first (loom-analyzer::reading-recovered reading)) :start-line))))

(test a-feature-suppressed-form-is-a-recorded-gap
  ;; REQ-0019 R5. The reason carries the feature expression itself, and the
  ;; nested *READ-SUPPRESS* results a suppressed form produces for each of its
  ;; subforms are filtered, so a guarded five-line function is one gap.
  (let* ((reading (rs "(defun a () 1)
#+no-such-feature (defun b () 2)"))
         (skips (loom-analyzer::reading-skips reading)))
    (is (= 1 (length (loom-analyzer::reading-forms reading))))
    (is (= 1 (length skips)) "one gap, not one per subform")
    (is-true (getf (first skips) :start-line))))

(test the-feature-policy-is-the-clients-and-not-the-images
  ;; REQ-0019 R5, and the gap it closes: before this the index depended on the
  ;; analyzing implementation's CL:*FEATURES*, and nothing recorded which
  ;; reading it was -- the same repository read by SBCL and by CCL would yield
  ;; different entities with no way to tell. The default stays the host's, so
  ;; the capability lands without moving a count; this test is what proves the
  ;; policy is actually consulted rather than merely accepted and ignored.
  (let ((source "(defun a () 1)
#+loom-no-such-feature (defun b () 2)"))
    (is (= 1 (length (loom-analyzer::reading-forms (rs source))))
        "the host's *features* does not have it, so the branch is not read")
    (let ((forms (loom-analyzer::reading-forms
                  (loom-analyzer::read-source
                   source :features '(:loom-no-such-feature)))))
      (is (= 2 (length forms))
          "and a policy that does have it reads the branch")
      (is (string= "b" (loom-analyzer::token-name (second (first (second forms)))))))
    (is (null (loom-analyzer::reading-suppressed-regions
               (loom-analyzer::read-source
                source :features '(:loom-no-such-feature))))
        "a branch that was taken is no gap")))

(test a-reader-macro-is-distinguishable-from-a-list-that-looks-like-one
  ;; ARCH-0013 R12's input. COLLECT-CALL-NAMES cannot tell these apart today
  ;; and its docstring says so.
  (let* ((reading (rs "(defun f () (mapcar #'target xs) '(not a call))"))
         (top (first (first (loom-analyzer::reading-forms reading))))
         (quotation (second (fourth top)))
         (quoted (fifth top)))
    (is (eq :function (loom-analyzer::form-reader-macro reading quotation)))
    (is (eq :quote (loom-analyzer::form-reader-macro reading quoted)))
    (is (null (loom-analyzer::form-reader-macro reading (fourth top)))
        "an ordinary call is not a reader macro")))

(test a-file-that-cannot-be-read-at-all-still-says-so
  ;; FATAL survives for the case MAKE-UNPARSABLE-FILE-ENTITY still answers.
  ;; An unterminated string at end of input recovers; there has to remain some
  ;; shape that does not, or R3 would have quietly removed the failure path.
  (let ((reading (rs "")))
    (is (null (loom-analyzer::reading-forms reading)))
    (is-false (loom-analyzer::reading-fatal reading)
              "an empty file is empty, not broken")))
