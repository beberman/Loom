;;;
;;; Tests for src/workspace/search.lisp -- `find' across every watched
;;; repository. REQ-0051, DES-0043.
;;;
;;; Two repositories on disk rather than one, because every property here is
;;; about the seam between them: a row that names its tree, a merged ranking, a
;;; per-repository count, and a tree that could not be asked. A one-repository
;;; fixture would pass all of them by accident.
;;;

(in-package :loom-workspace-test)

(def-suite search
  :in all-tests
  :description "find across every watched repository (REQ-0051).")

(in-suite search)

(defun write-search-file (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    path))

(defun make-search-repository (files)
  "A watched repository in a fresh temp directory holding FILES.

FILES is an alist of relative path to contents. Its own builder rather than
MAKE-FIXTURE-REPOSITORY, which stores one root in a special and so cannot make
the second repository these tests are entirely about."
  (let ((root (merge-pathnames (format nil "loom-search-~36r/" (random (expt 2 48) (make-random-state t)))
                               (uiop:temporary-directory))))
    (ensure-directories-exist root)
    (loop for (relative . contents) in files
          do (write-search-file root relative contents))
    (values (watch-repository root :monitor nil :quiet t) root)))

(defmacro with-two-repositories ((one two) &body body)
  "Two watched repositories, and nothing else in the registry.

*REPOSITORIES* is rebound rather than added to, so SEARCH-REPOSITORIES' default
of ALL-REPOSITORIES sees exactly these two whatever else a session has watched.

Both are declared IGNORABLE, because most of these tests care about the answer
and not about the structs -- and a DECLARE written in the caller's body would
be spliced below the PUSH forms, which is not a declaration position."
  `(let* ((*repositories* '())
          (roots '()))
     (unwind-protect
          (multiple-value-bind (,one one-root)
              (make-search-repository
               '(("src/alpha.lisp" . "(defun overlay (x) x)
(defun overlay-twice (x) (overlay (overlay x)))
")))
            (declare (ignorable ,one))
            (push one-root roots)
            (multiple-value-bind (,two two-root)
                (make-search-repository
                 '(("src/beta.lisp" . "(defun overlay (y) y)
(defun beta-only (y) y)
")))
              (declare (ignorable ,two))
              (push two-root roots)
              ,@body))
       (dolist (root roots)
         (ignore-errors (uiop:delete-directory-tree root :validate t))))))

;;; ------------------------------------------------------------------
;;; The ranking rule, split so a summary can be ranked (DES-0043 D3)
;;; ------------------------------------------------------------------

(test the-name-form-of-the-rank-agrees-with-the-entity-form
  ;; S1 restated SEARCH-RANK on a name and a type so SEARCH-REPOSITORIES can
  ;; rank merged summaries. Two rules that disagree would put `find''s
  ;; federated answer in a different order from its single-tree one, which is
  ;; the failure this pins. Fails if the split dropped the :FILE basename rule
  ;; or the :CALL-SITE demotion.
  (let ((cases '(("overlay"                 :function "overlay"  0)
                 ("overlay-twice"           :function "overlay"  1)
                 ("the-overlay-of"          :function "overlay"  2)
                 ("unrelated"               :function "overlay"  3)
                 ;; A file's name is a path and matches on its basename.
                 ("src/overlay.lisp"        :file     "overlay"  0)
                 ("src/overlay.lisp"        :file     "src"      3)
                 ;; A call site is demoted a whole band below every entity
                 ;; that is not one, so its prefix match loses to a substring.
                 ("overlay@src/a.lisp:3"    :call-site "overlay" 5))))
    (loop for (name type pattern expected) in cases
          do (is (= expected (name-search-rank name type pattern))
                 "~a as a ~a ranks ~d against ~s" name type expected pattern))))

;;; ------------------------------------------------------------------
;;; The federated search
;;; ------------------------------------------------------------------

(test a-search-with-no-repository-answers-from-every-watched-one
  ;; REQ-0051 R1. The measurement the requirement came from: a name defined in
  ;; two trees, asked without naming either.
  (with-two-repositories (repo-a repo-b)
    (let* ((report (search-repositories "overlay"))
           (names (mapcar (lambda (row) (getf row :repository))
                          (getf report :entities))))
      (is (member (repository-name repo-a) names :test #'string=)
          "the first repository's definition is in the answer")
      (is (member (repository-name repo-b) names :test #'string=)
          "and so is the second's, which is the whole requirement")
      (is (= 2 (length (getf report :searched)))
          "both trees are named as searched")
      (is (null (getf report :skipped))
          "and neither was passed over"))))

(test every-row-says-which-repository-it-came-from
  ;; REQ-0051 R2. A row that does not name its tree reads as a claim about one
  ;; system, which is REQ-0027 R5's rule applied to a band it did not cover.
  (with-two-repositories (repo-a repo-b)
    (let ((rows (getf (search-repositories "overlay") :entities)))
      (is (plusp (length rows)) "there is something to check")
      (is (every (lambda (row) (stringp (getf row :repository))) rows)
          "every row carries a repository name"))))

(test the-merged-answer-is-ranked-across-repositories-not-concatenated
  ;; DES-0043 D3. OVERLAY-TWICE is in the first repository and OVERLAY is in
  ;; both, so a concatenation would put the first tree's prefix match above the
  ;; second tree's exact one. Fails without the STABLE-SORT over the merge.
  (with-two-repositories (repo-a repo-b)
    (let ((rows (getf (search-repositories "overlay") :entities)))
      (is (string-equal "overlay" (getf (first rows) :name))
          "an exact match leads, whichever tree holds it")
      (let ((exact (remove-if-not (lambda (row) (string-equal "overlay" (getf row :name)))
                                  rows)))
        (is (= 2 (length exact))
            "both trees' exact matches are above every prefix match")
        (is (string-equal "overlay" (getf (second rows) :name))
            "and they are adjacent, which a concatenation would not give")))))

(test a-per-repository-limit-does-not-lose-a-row-that-belongs-in-the-merge
  ;; DES-0043 D3's correctness argument, as a test. Each tree is searched at
  ;; the caller's own limit rather than unlimited, which is only sound because
  ;; a row in the merged top-N is in its own repository's top-N. With a limit
  ;; of 1 the answer must still be the best row across both trees.
  (with-two-repositories (repo-a repo-b)
    (let ((rows (getf (search-repositories "overlay" :limit 1) :entities)))
      (is (= 1 (length rows)) "the limit is honoured")
      (is (string-equal "overlay" (getf (first rows) :name))
          "and the row kept is an exact match, not a prefix one"))))

(test the-total-is-summed-over-what-was-searched
  ;; BUG-0002's count, federated. A caller that received the limit and nothing
  ;; else cannot tell a complete answer from a cut one.
  (with-two-repositories (repo-a repo-b)
    (let ((whole (search-repositories "overlay"))
          (cut (search-repositories "overlay" :limit 1)))
      (is (= (getf whole :total) (getf cut :total))
          "the total does not depend on the limit")
      (is (> (getf whole :total) 1) "and it counts both trees")
      (is-true (getf cut :truncated) "a cut answer says it was cut")
      (is-false (getf whole :truncated) "an uncut one does not"))))

(test the-cost-is-reported-per-search
  ;; REQ-0051 R5. `find' is the cheapest command Loom has and this walks every
  ;; watched tree, so the answer carries what it cost rather than leaving the
  ;; caller to time it.
  (with-two-repositories (repo-a repo-b)
    (let ((report (search-repositories "overlay")))
      (is (numberp (getf report :seconds)) "the elapsed time travels on the data")
      (is (>= (getf report :seconds) 0) "and is not negative"))))

;;; ------------------------------------------------------------------
;;; What was not searched (REQ-0051 R4, CON-0001)
;;; ------------------------------------------------------------------

(test a-repository-still-indexing-is-named-rather-than-counted-absent
  ;; CON-0001, and the clause REQ-0051 R4 exists for. An answer of "absent from
  ;; every tree" is a strong claim and must not be produced by a search that
  ;; only ran against some. A repository whose index build is still alive lands
  ;; on :SKIPPED, is not on :SEARCHED, and contributes nothing to :TOTAL.
  (with-two-repositories (repo-a repo-b)
    (let ((gate (bt:make-semaphore)))
      (setf (loom-workspace::repository-index-build repo-b)
            (bt:make-thread (lambda () (bt:wait-on-semaphore gate :timeout 30))
                            :name "loom-search-test-indexing"))
      (unwind-protect
           (let ((report (search-repositories "overlay")))
             (is (equal (list (repository-name repo-b))
                        (mapcar (lambda (row) (getf row :repository))
                                (getf report :skipped)))
                 "the tree being indexed is named as not searched")
             (is (equal (list (repository-name repo-a))
                        (mapcar (lambda (row) (getf row :repository))
                                (getf report :searched)))
                 "and only the other one is claimed as searched")
             (is (every (lambda (row)
                          (string= (repository-name repo-a) (getf row :repository)))
                        (getf report :entities))
                 "no row comes from the tree that was passed over")
             (is (= (getf report :total)
                    (getf (first (getf report :searched)) :total))
                 "and the total counts only what was actually asked"))
        (bt:signal-semaphore gate)
        (setf (loom-workspace::repository-index-build repo-b) nil)))))

;;; ------------------------------------------------------------------
;;; The zero-hit probe (REQ-0051 R3)
;;; ------------------------------------------------------------------

(test a-name-absent-here-is-counted-in-the-other-repositories
  ;; REQ-0051 R3, and the half the requirement is for: a name absent from this
  ;; repository and present in another is a migration telling you where it
  ;; went. BETA-ONLY is in the second tree and nowhere else.
  (with-two-repositories (repo-a repo-b)
    (let ((held (repositories-holding "beta-only"
                                      :exclude (repository-name repo-a))))
      (is (= 1 (length held)) "one other tree holds it")
      (is (string= (repository-name repo-b) (getf (first held) :repository))
          "and it is named")
      (is (plusp (getf (first held) :total)) "with a count"))))

(test the-repository-already-searched-is-excluded-from-the-probe
  ;; Otherwise a `find' that found nothing in a tree would report that same
  ;; tree back as holding the name, which is the one answer it has ruled out.
  (with-two-repositories (repo-a repo-b)
    (is (null (find (repository-name repo-a)
                    (repositories-holding "overlay" :exclude (repository-name repo-a))
                    :key (lambda (row) (getf row :repository))
                    :test #'string=))
        "the excluded tree is not in the counts")))

(test a-name-in-no-watched-tree-probes-to-nothing
  ;; REQ-0051 R4's other half. `get-package-file' was caught this way: found
  ;; dead because both trees were asked and neither held it.
  (with-two-repositories (repo-a repo-b)
    (is (null (repositories-holding "get-package-file"
                                    :exclude (repository-name repo-a)))
        "no tree holds a name no tree holds")))
