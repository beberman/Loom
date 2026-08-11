;;;
;;; Main test runner
;;;

(defpackage #:loom-knowledge-test
  (:use #:cl #:fiveam #:loom-ontology #:loom-graph #:loom-knowledge)
  (:export #:test-runner #:all-tests))

(in-package :loom-knowledge-test)

(def-suite all-tests
  :description "Master suite of all loom-knowledge tests")

(in-suite all-tests)

;;; ------------------------------------------------------------------
;;; Shared fixture: a miniature of what the analyzer produces, using the real
;;; taxonomy so the SS9 impact metadata is the metadata under test.
;;;
;;;   overlay.lisp --contains--> resolve-overlay, compose-view, reset-overlay
;;;   compose-view   --calls-->  resolve-overlay
;;;   reset-overlay  --calls-->  compose-view
;;;   overlay-test   --tests-->  resolve-overlay
;;;   ADR-7          --decides-> resolve-overlay
;;; ------------------------------------------------------------------

(defun k-function (name start)
  (make-instance 'function-entity :name name
                 :origin-file "src/workspace/overlay.lisp"
                 :properties (properties-table
                              (list :file "src/workspace/overlay.lisp"
                                    :start-line start :end-line (+ start 12)
                                    :language :lisp))))

(defun k-edge (graph type from to)
  (add-relationship graph (make-instance 'relationship :rel-type type
                                                       :from-id (id from)
                                                       :to-id (id to)
                                                       :origin-file (origin-file from))))

(defstruct (k-fixture (:conc-name k-) (:constructor %make-k-fixture))
  graph file resolve compose reset test adr)

(defun make-k-fixture ()
  (let* ((g (make-graph))
         (file    (make-instance 'file-entity :name "src/workspace/overlay.lisp"
                                 :origin-file "src/workspace/overlay.lisp"
                                 :properties (properties-table
                                              '(:path "src/workspace/overlay.lisp"
                                                :language :lisp))))
         (resolve (k-function "resolve-overlay" 41))
         (compose (k-function "compose-view" 80))
         (reset   (k-function "reset-overlay" 120))
         (test    (make-instance 'test-entity :name "overlay-resolution-test"
                                 :origin-file "test/overlay.lisp"
                                 :properties (properties-table
                                              '(:file "test/overlay.lisp"
                                                :start-line 1 :end-line 9))))
         (adr     (make-instance 'decision-entity :name "ADR-7"
                                 :origin-file "docs/decisions/ADR-7.yaml"
                                 :properties (properties-table
                                              '(:doc-id "ADR-7"
                                                :decision "Branch switches reset the overlay rather than diffing it."
                                                :rationale "Diffing an overlay across a branch switch is not worth the complexity.")))))
    (dolist (e (list file resolve compose reset test adr)) (add-entity g e))
    (dolist (m (list resolve compose reset)) (k-edge g :contains file m))
    (k-edge g :calls compose resolve)
    (k-edge g :calls reset compose)
    (k-edge g :tests test resolve)
    (k-edge g :decides adr resolve)
    (%make-k-fixture :graph g :file file :resolve resolve :compose compose
                     :reset reset :test test :adr adr)))

(defun test-runner ()
  (run! 'all-tests))
