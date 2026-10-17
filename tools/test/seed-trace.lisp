;;;; Why a seed band holds what it holds: the two lists, the fusion, the caps.
;;;;
;;;;   sbcl --script tools/test/seed-trace.lisp <repository-root> <task words...>
;;;;
;;;; SEED-ENTITIES returns eight entities and no account of the seven stages
;;;; that chose them, so a bundle that came back wrong can only be argued about.
;;;; BUG-0060 was mis-diagnosed twice from the bundle alone -- first as an
;;;; analyzer gap, then as a candidate ranking below the cut -- and both
;;;; readings were settled in one run of this: the class was lexical rank 4 and
;;;; fused rank 12, so neither the analyzer nor SEED-SCORE was the subject.
;;;;
;;;; What it prints, in the order the seeder computes them:
;;;;
;;;;   matches     what SEED-MATCHES found, before STRONG-CANDIDATES
;;;;   lexical     SEED-SCORE's order, with each band of the score broken out
;;;;   semantic    SEMANTIC-CANDIDATES, with the cosine
;;;;   fused       FUSE-RANKINGS' order
;;;;   chosen      ADMIT-SEEDS' eight, and the cap each held-back candidate hit
;;;;
;;;; The vector store is read from disk when the tree has one, so this answers
;;;; for the service rather than for a fresh index. A run with no store is the
;;;; lexical answer alone, and the difference between the two runs is what says
;;;; whether dense retrieval is the subject.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(synoptik-harness:load-systems "tools/test/seed-trace.lisp"
                           :systems '("utils/" "embed/" "ontology/" "graph/" "analyzer/"
                                      "knowledge/" "docstore/" "workspace/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid"
                                        "eclector" "stem" "cl-json" "drakma")
                           :load :synoptik-workspace)

(defpackage #:synoptik-seed-trace
  (:use #:cl #:synoptik-ontology #:synoptik-graph #:synoptik-knowledge #:synoptik-workspace))
(in-package #:synoptik-seed-trace)

(defun bands (entity matches terms demote production)
  "SEED-SCORE's summands, in its own order. The score is their weighted sum."
  (list :type   (synoptik-knowledge::seed-type-rank entity)
        :named  (if (synoptik-knowledge::named-by-task-p entity matches terms) 0 1)
        :acc    (if (synoptik-knowledge::slot-accessor-p entity) 1 0)
        :test   (if (synoptik-knowledge::demoted-test-p entity demote production) 1 0)
        :cover  (max 0 (- 8 (length matches)))
        :prose  (if (synoptik-knowledge::prose-only-p matches) 1 0)
        :rank   (synoptik-knowledge::best-name-rank matches)))

(defun trace-seeds (root task &key (limit 8) (depth 14))
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (view       (repository-graph repository))
         (store      (repository-vectors repository)))
    (format t "~&~a~%~a~%~%" root task)
    (format t "~&vector store: ~a~%" (if store "present" "none -- lexical only"))
    (let ((synoptik-knowledge:*context-vector-store* store)
          (synoptik-knowledge:*context-embedder* (and store (current-embedder))))
      (multiple-value-bind (matches frequencies)
          (synoptik-knowledge::seed-matches view (synoptik-knowledge::task-token-origins task) nil)
        (let* ((demote     (not (synoptik-knowledge::task-wants-tests-p task)))
               (terms      (synoptik-knowledge::task-terms task))
               (origins    (synoptik-knowledge::task-token-origins task))
               (corpus     (length (all-entities view)))
               (candidates (synoptik-knowledge::strong-candidates matches origins))
               (semantic   (synoptik-knowledge::semantic-candidates view task))
               (production (synoptik-knowledge::production-names candidates))
               (score      (lambda (pair)
                             (synoptik-knowledge::seed-score
                              (car pair) (cdr pair)
                              :demote-tests demote :terms terms :production production
                              :origins origins :frequencies frequencies
                              :corpus-size corpus)))
               (lexical    (stable-sort (copy-list candidates) #'< :key score))
               (named      (loop for (entity . found) in candidates
                                 when (synoptik-knowledge::named-by-task-p entity found terms)
                                   collect entity))
               (protected  (when synoptik-knowledge::*protect-named* named))
               (ranked     (synoptik-knowledge::fuse-rankings lexical semantic :protected protected))
               (chosen     (synoptik-knowledge::admit-seeds ranked limit :protected protected)))
          (format t "~&terms: ~{~a~^ ~}~%" terms)
          (format t "~&matches ~d, strong candidates ~d, named ~d, protected ~d~%"
                  (length matches) (length candidates) (length named) (length protected))
          (format t "~&rrf-k ~a  semantic-weight ~a  protect-named ~a~%"
                  synoptik-knowledge::*rrf-k* synoptik-knowledge::*semantic-weight*
                  synoptik-knowledge::*protect-named*)
          (format t "~&term-share ~a  name-share ~a  owner-share ~a~%~%"
                  synoptik-knowledge::*seed-term-share* synoptik-knowledge::*seed-name-share*
                  synoptik-knowledge::*seed-owner-share*)

          (format t "~&LEXICAL, first ~d of ~d~%" (min depth (length lexical)) (length lexical))
          (format t "~&~4a ~9a ~5a ~5a ~5a ~5a ~5a ~5a ~5a  ~a~%"
                  "pos" "score" "type" "named" "acc" "test" "cover" "prose" "rank" "name")
          (loop for pair in lexical for pos from 1 while (<= pos depth)
                do (let ((b (bands (car pair) (cdr pair) terms demote production)))
                     (format t "~&~4d ~9d ~5d ~5d ~5d ~5d ~5d ~5d ~5d  ~a~%"
                             pos (funcall score pair)
                             (getf b :type) (getf b :named) (getf b :acc) (getf b :test)
                             (getf b :cover) (getf b :prose) (getf b :rank)
                             (name (car pair)))))

          (format t "~&~%SEMANTIC, ~d candidates~%" (length semantic))
          (loop for pair in semantic for pos from 1 while (<= pos depth)
                do (format t "~&~4d ~8,4f  ~a~%" pos
                           (or (cdr (assoc :similarity (cdr pair))) 0)
                           (name (car pair))))

          (format t "~&~%FUSED, first ~d~%" (min depth (length ranked)))
          (loop for pair in ranked for pos from 1 while (<= pos depth)
                do (format t "~&~4d ~a [~a] owner=~a~a~%" pos (name (car pair))
                           (entity-type (car pair))
                           (or (synoptik-knowledge::seed-owner (car pair)) "-")
                           (if (member (car pair) chosen :test #'eq) "  CHOSEN" "")))

          (format t "~&~%CHOSEN ~d~%" (length chosen))
          (dolist (entity chosen) (format t "~&  ~a [~a]~%" (name entity) (entity-type entity)))

          ;; A candidate above the last chosen one that was not chosen was held
          ;; by a cap; one below it never reached the cut. The two are different
          ;; defects and the bundle alone cannot tell them apart.
          (let ((last-chosen (loop for pair in ranked for pos from 1
                                   when (member (car pair) chosen :test #'eq)
                                     maximize pos)))
            (format t "~&~%HELD BACK BY A CAP (ranked above the last chosen, at ~d)~%" last-chosen)
            (loop for pair in ranked for pos from 1 while (<= pos last-chosen)
                  unless (member (car pair) chosen :test #'eq)
                    do (format t "~&~4d ~a owner=~a~%" pos (name (car pair))
                               (or (synoptik-knowledge::seed-owner (car pair)) "-")))))))))

(let ((arguments (rest sb-ext:*posix-argv*)))
  (if (< (length arguments) 2)
      (format *error-output*
              "~&usage: sbcl --script tools/test/seed-trace.lisp <root> <task words...>~%")
      (trace-seeds (first arguments)
                   (format nil "~{~a~^ ~}" (rest arguments)))))
