;;;; Family census for REQ-0029 R8 / PLAN-0028 S7.
;;;;
;;;;   sbcl --script tools/family-census.lisp /path/to/repo FAMILY
;;;;
;;;; The acceptance measurement DES-0024 cannot get from the suite. Loom's own
;;;; packages are dash-flat, so no rule in docs/rules/ writes from-family: and
;;;; nothing on this tree exercises a family match end to end. game-server has
;;;; two real families; this indexes it, partitions every :system value the
;;;; analyzer actually wrote by whether it satisfies (:family FAMILY), and then
;;;; runs a real rule through CHECK-RULES so the number reported is the rule
;;;; engine's answer and not a re-implementation of it agreeing with itself.
;;;;
;;;; Every function is prefixed FC-, for the reason tools/package-census.lisp
;;;; states at length: Loom indexes its own tree, and a measuring script that
;;;; defines REPORT or TALLY changes the numbers it is about to report.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(loom-harness:load-systems "tools/family-census.lisp"
                           :systems '("embed/" "ontology/" "graph/" "analyzer/" "knowledge/" "workspace/")
                           :libraries '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :loom-workspace)

(defpackage #:family-census
  (:use #:cl #:loom-ontology #:loom-graph #:loom-workspace))
(in-package #:family-census)

(defun fc-systems (graph)
  "Every distinct :system value the analyzer wrote, sorted."
  (let ((seen '()))
    (dolist (e (all-entities graph))
      (let ((s (entity-system e)))
        (when s (pushnew s seen))))
    (sort seen #'string< :key #'symbol-name)))

(defun fc-partition (systems family)
  (let ((in '()) (out '()))
    (dolist (s systems)
      (if (system-satisfies-p (list :family family) s)
          (push s in)
          (push s out)))
    (values (nreverse in) (nreverse out))))

(defun fc-rule (graph family)
  "A real RULE entity carrying a from-family: check, added to GRAPH.
Built the way PARSE-CHECK builds one, so what CHECK-RULES runs here is what it
would run against a rule document in docs/rules/."
  (add-entity graph
              (make-instance 'rule-entity
                             :name "RULE-9001"
                             :origin-file "docs/rules/RULE-9001.yaml"
                             :properties (properties-table
                                          (list :doc-id "RULE-9001"
                                                :status :active
                                                :severity :error
                                                :check (list :kind :no-edge
                                                             :from-system (list :family family)
                                                             :to-system :outside
                                                             :rel-types '(:calls)))))))

(defun fc-main (root family)
  (let* ((repository (watch-repository root :monitor nil :quiet nil))
         (graph (repository-graph repository))
         (systems (fc-systems graph)))
    (multiple-value-bind (in out) (fc-partition systems family)
      (format t "~&~%==== ~a, family ~s ====~%" root family)
      (format t "~&~d distinct systems indexed~%" (length systems))
      (format t "~&~%IN the family (~d):~%" (length in))
      (dolist (s in) (format t "  ~(~a~)~%" s))
      (format t "~&~%OUT, and beginning with the same letters (the raw-prefix trap):~%")
      (let ((trap (remove-if-not
                   (lambda (s)
                     (let ((f (symbol-name family)) (n (symbol-name s)))
                       (and (<= (length f) (length n))
                            (string-equal f n :end2 (length f)))))
                   out)))
        (if trap
            (dolist (s trap) (format t "  ~(~a~)~%" s))
            (format t "  none~%")))
      ;; What each member of the family is, by entity type and origin. The
      ;; family is derived from package names, and a system nobody declared a
      ;; package for got its value from DEFAULT-SYSTEM-FOR-PATH instead
      ;; (DES-0009 R3) -- which is worth seeing rather than counting past.
      (format t "~&~%WHAT EACH MEMBER IS:~%")
      (dolist (s in)
        (let ((files (remove-duplicates
                      (loop for e in (all-entities graph)
                            when (eq s (entity-system e))
                              collect (or (getp e :file) (origin-file e)))
                      :test #'equal)))
          (format t "  ~(~30a~) ~d entities, e.g. ~a~%"
                  s
                  (count s (all-entities graph) :key #'entity-system)
                  (or (first files) "?"))))
      ;; The comparison that says whether the feature earned its place: how
      ;; much traffic inside the family an EQ-only rule would have reported as
      ;; violations. REQ-0029 R6 -- one rule per member package is not merely
      ;; tedious, it is loud.
      (let ((internal (loop for member in in
                            sum (length (edges-between-systems
                                         graph member :outside
                                         :rel-types '(:calls))))))
        (format t "~&~%EQ-only cost: ~d calls leave one member package for another system,~%~
                     ~13tof which the family rule reports only those leaving the family.~%"
                internal))
      (fc-rule graph family)
      (let ((violations (check-rules graph)))
        (format t "~&~%CHECK-RULES on a from-family: rule: ~d violations~%"
                (length violations))
        (dolist (v (subseq violations 0 (min 5 (length violations))))
          (format t "  ~a~%" (violation-detail v)))
        (when (> (length violations) 5)
          (format t "  ... and ~d more~%" (- (length violations) 5)))))))

(let ((args (cdr sb-ext:*posix-argv*)))
  (if (< (length args) 2)
      (format t "~&usage: sbcl --script tools/family-census.lisp /path/to/repo FAMILY~%")
      (fc-main (first args)
               (intern (string-upcase (second args)) :keyword))))
