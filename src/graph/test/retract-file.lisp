;;;
;;; Tests for RETRACT-FILE-OP and the origin-file index -- Revision 2's
;;; files-as-truth machinery (SS5.1, SS5.4, SS7).
;;;

(in-package :loom-graph-test)

(def-suite retract-file
  :in all-tests
  :description "Origin-file indexing and file-scoped retraction.")

(in-suite retract-file)

(defun rf-function (name file &key (start 1))
  (make-instance 'function-entity :name name :origin-file file
                 :properties (properties-table
                              (list :file file :start-line start
                                    :end-line (+ start 4) :language :lisp))))

(defun rf-file (path)
  (make-instance 'file-entity :name path :origin-file path
                 :properties (properties-table
                              (list :path path :language :lisp))))

(defun rf-populate (graph path names)
  "Assert PATH's file entity and one function per name, as an analysis pass
would, and return the ops applied."
  (let* ((file (rf-file path))
         (ops (list (retract-file path)
                    (assert-entity file))))
    (dolist (name names)
      (let ((fn (rf-function name path)))
        (setf ops (append ops (list (assert-entity fn)
                                    (assert-edge :contains file fn))))))
    (apply-transaction graph ops)
    ops))

;;; ------------------------------------------------------------------
;;; The origin-file index
;;; ------------------------------------------------------------------

(test every-fact-records-the-file-it-came-from
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("one" "two"))
    ;; 1 file + 2 functions + 2 contains edges
    (is (= 5 (length (facts-from-file g "a.lisp"))))
    (is (every (lambda (f) (string= "a.lisp" (origin-file f)))
               (facts-from-file g "a.lisp")))
    (is (equal '("a.lisp") (origin-files g)))))

(test the-origin-index-is-maintained-through-removal
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("one"))
    (let ((fn (find "one" (all-entities g) :key #'name :test #'string=)))
      (remove-entity g (id fn)))
    (is (= 1 (length (facts-from-file g "a.lisp")))
        "the file entity survives; the function and its contains edge are gone")))

;;; ------------------------------------------------------------------
;;; File-scoped retraction (SS5.4)
;;; ------------------------------------------------------------------

(test retracting-a-file-removes-everything-it-contributed
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("one" "two"))
    (rf-populate g "b.lisp" '("three"))
    (apply-transaction g (list (retract-file "a.lisp")))
    (is (null (facts-from-file g "a.lisp")))
    (is (= 3 (length (facts-from-file g "b.lisp")))
        "and touches nothing that came from anywhere else")))

(test retracting-a-file-the-index-has-never-seen-is-a-no-op
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("one"))
    (let ((before (length (all-entities g))))
      (apply-transaction g (list (retract-file "never-analyzed.lisp")))
      (is (= before (length (all-entities g)))
          "which is what lets every analysis pass open with a retract-file,
first pass or hundredth"))))

;;; ------------------------------------------------------------------
;;; The point of it all: a deleted definition leaves the index
;;; ------------------------------------------------------------------

(test reanalysis-drops-a-definition-that-was-deleted-from-the-file
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("kept" "deleted"))
    (is (= 2 (length (entities-of-type g :function))))
    ;; the same file, reanalyzed after one defun was removed
    (rf-populate g "a.lisp" '("kept"))
    (is (equal '("kept") (mapcar #'name (entities-of-type g :function)))
        "SS5.4: retract-file plus fresh asserts is how absence gets expressed --
an analyzer can only report what it found, never what it stopped finding")))

(test reanalysis-of-an-unchanged-file-is-still-a-no-op
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("one" "two"))
    (let ((entities (length (all-entities g)))
          (edges    (length (all-relationships g)))
          (ids      (sort (mapcar #'id (all-entities g)) #'string<)))
      (rf-populate g "a.lisp" '("one" "two"))
      (is (= entities (length (all-entities g))))
      (is (= edges (length (all-relationships g))))
      (is (equal ids (sort (mapcar #'id (all-entities g)) #'string<))
          "ids survive the retract because they are derived, not minted"))))

;;; ------------------------------------------------------------------
;;; Derived ids across an independent rebuild (SS14.4)
;;; ------------------------------------------------------------------

(test an-independent-rebuild-produces-identical-ids
  ;; SS14.4 asserts that an incrementally updated index and an independently
  ;; rebuilt one are "identical -- not merely equivalent, since ids are derived
  ;; from natural keys rather than generated". Two separate graphs, built by
  ;; separate passes, must agree down to the id.
  (let ((a (make-graph))
        (b (make-graph)))
    (rf-populate a "a.lisp" '("one" "two"))
    (rf-populate b "a.lisp" '("one" "two"))
    (is (equal (sort (mapcar #'id (all-entities a)) #'string<)
               (sort (mapcar #'id (all-entities b)) #'string<)))
    (is (equal (sort (mapcar #'id (all-relationships a)) #'string<)
               (sort (mapcar #'id (all-relationships b)) #'string<))
        "edges too, since an edge id is derived from its endpoints")))

;;; ------------------------------------------------------------------
;;; The documented cost (see the TODO in transaction.lisp)
;;; ------------------------------------------------------------------

(test reanalysis-loses-inbound-cross-file-edges-until-resolution-reruns
  (let ((g (make-graph)))
    (rf-populate g "a.lisp" '("caller"))
    (rf-populate g "b.lisp" '("callee"))
    (let ((caller (find "caller" (all-entities g) :key #'name :test #'string=)))
      (setp caller :unresolved-calls '("callee")))
    (apply-transaction g (resolve-calls g))
    (is (= 1 (count :calls (all-relationships g) :key #'rel-type)))
    ;; b.lisp is reanalyzed; the callee comes back with the same derived id,
    ;; but the edge from a.lisp went with the entity it pointed at.
    (rf-populate g "b.lisp" '("callee"))
    (is (= 0 (count :calls (all-relationships g) :key #'rel-type))
        "documented in the TODO on APPLY-TRANSACTION")
    ;; and re-running resolution puts it back, which is why the fix is
    ;; sequencing in the workspace monitor rather than logic here.
    (let ((caller (find "caller" (all-entities g) :key #'name :test #'string=)))
      (setp caller :unresolved-calls '("callee")))
    (apply-transaction g (resolve-calls g))
    (is (= 1 (count :calls (all-relationships g) :key #'rel-type)))))
