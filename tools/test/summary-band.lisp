;;;; What the description band costs, at each cut. REQ-0049 R3.
;;;;
;;;;   sbcl --script tools/test/summary-band.lisp [<root> <task> ...]
;;;;
;;;; R3 says the band cannot be uniform -- 130 items at 24 tokens is the whole
;;;; budget -- and leaves open whether the cut is a count or a cost. This
;;;; measures the cost cut *CONTEXT-SUMMARY-COST* makes, over the four tasks
;;;; PLAN-0045's outcome table reports, at every value the walk can produce.
;;;;
;;;; Per task and setting: the entities sent, how many carried a description,
;;;; the tokens delivered, and the ratio against the budget. The floor to hold
;;;; is PLAN-0045's -- every task inside its budget -- and the thing to buy is
;;;; descriptions on the band where relevance is still undecided.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(synoptik-harness:load-systems "tools/test/summary-band.lisp"
                           :systems '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/" "docstore/" "workspace/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :synoptik-workspace)

(defpackage #:synoptik-summary-band
  (:use #:cl #:synoptik-ontology #:synoptik-graph #:synoptik-knowledge #:synoptik-workspace))
(in-package #:synoptik-summary-band)

(defparameter *cuts* '(-1 1 2 3 4)
  "Every cut the walk can produce. *CONTEXT-EXPANSION-HORIZON* is 4, so a cut
of 4 is every neighbour and -1 is none of them -- seeds carry a description at
any setting, having no arriving edge and therefore no cost.")

(defun described (bundle)
  "How many of BUNDLE's items printed a description, and their tokens."
  (let ((count 0) (tokens 0))
    (dolist (item (getf bundle :items) (values count tokens))
      (let ((summary (synoptik-knowledge::item-summary-line item)))
        (when summary
          (incf count)
          (incf tokens (synoptik-knowledge::estimate-tokens summary)))))))

(defun measure (root task)
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (view (repository-graph repository)))
    (format t "~&~%~a  [~a]~%" task (pathname-name (string-right-trim "/" root)))
    (format t "~&  cut   items  described  desc-tokens  tokens  xbudget~%")
    (dolist (cut *cuts*)
      (let* ((synoptik-knowledge::*context-summary-cost* cut)
             (bundle (build-context view task
                                    :source-fn (lambda (id)
                                                 (definition-source repository id)))))
        (multiple-value-bind (count tokens) (described bundle)
          (format t "~&  ~3d ~7d ~10d ~12d ~7d ~8,2f~%"
                  cut (length (getf bundle :items)) count tokens
                  (getf bundle :tokens)
                  (/ (float (getf bundle :tokens)) (getf bundle :budget))))))))

;;; PLAN-0045's two Synoptik tasks, on the tree this script was loaded from, then any
;;; <root> <task> pairs on the command line, two at a time. The dogfooding rule:
;;; Synoptik is the most prose-heavy repository in the set at 62% of a body, and a
;;; band tuned on it alone is tuned on its best case. A code-heavy tree is where
;;; a description band can be empty and still be paid for, so name one:
;;;
;;;   sbcl --script tools/test/summary-band.lisp /path/to/tree "a task"
;;;
;;; Written inline, with calls to Common Lisp only: a call here to a function
;;; defined in this file would be one more site for tools/test/call-site-census.lisp
;;; to count, and it is read against a pinned figure (512 minted on this tree).
(dolist (pair (append
               (let ((here (string-right-trim
                            "/" (namestring (truename (merge-pathnames
                                                       "../../"
                                                       (make-pathname :name nil :type nil
                                                                      :defaults *load-truename*)))))))
                 (list (cons here "context bundle token budget and how it is spent")
                       (cons here "how a context bundle is rendered")))
               (loop for (root task) on (rest sb-ext:*posix-argv*) by #'cddr
                     when task collect (cons root task))))
  (handler-case (measure (car pair) (cdr pair))
    (error (c) (format t "~&~a: ~a~%" (car pair) c))))
