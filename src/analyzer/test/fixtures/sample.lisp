;;;; Fixture: a tiny Lisp file for the analyzer to walk.

(defparameter *tally* 0
  "A trivial special variable, to exercise :variable extraction.")

(defun add-on (x)
  (+ x 1))

(defun triple-add-on (x)
  (add-on (add-on (add-on x))))

(defun summarize (x)
  (format t "~a~%" (triple-add-on x))
  (incf *tally*))
