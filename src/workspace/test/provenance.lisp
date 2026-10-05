;;;
;;; Tests for INDEX-PROVENANCE -- REQ-0050 R1 and R3.
;;;
;;; The question these answer is the one the requirement was written from: an
;;; answer reports a commit, and a reader takes that for a statement about the
;;; index. Three things move independently -- the commit, the working tree, the
;;; index -- and a fingerprint read at query time speaks for the first two only.
;;;
;;; After "gitignore": these take WITH-SCRATCH-REPOSITORY, WRITE-SCRATCH-FILE
;;; and RUN-GIT, because a real git repository is the only fixture that can
;;; tell a commit from a working tree.
;;;

(in-package :loom-workspace-test)

(def-suite provenance
  :in all-tests
  :description "What tree an index was built from, and how far behind it is.")

(in-suite provenance)

(defun commit-everything (root message)
  (run-git root "add" "-A")
  (run-git root "commit" "-q" "-m" message))

(defmacro with-committed-repository ((repository root) &body body)
  "A scratch git repository with one indexed source file, committed and indexed."
  `(with-scratch-repository (,root)
     (write-scratch-file ,root "src/alpha.lisp"
                         (format nil "(defun alpha ()~%  \"A function.\"~%  1)~%"))
     (commit-everything ,root "initial")
     (let ((,repository (watch-repository ,root :monitor nil :quiet t)))
       (unwind-protect (progn ,@body)
         (unwatch-repository (repository-name ,repository))))))

(test a-freshly-indexed-clean-tree-reports-its-commit-and-no-drift
  (with-committed-repository (repository root)
    (let ((provenance (index-provenance repository)))
      (is (stringp (getf provenance :commit)))
      (is (null (getf provenance :commit-reason)))
      (is (stringp (getf provenance :branch)))
      (is (null (getf provenance :dirty))
          "nothing uncommitted, so the commit is the whole of what was read")
      (is (eql 0 (getf provenance :drift))
          "the index was built from these bytes a moment ago"))))

(test an-edit-the-index-has-not-read-is-drift
  ;; The acceptance clause, in the direction that matters. The monitor is off,
  ;; so this is exactly the state a service is in between polls -- and the
  ;; state in which its commit field still agrees with `git rev-parse HEAD'.
  (with-committed-repository (repository root)
    (write-scratch-file root "src/alpha.lisp"
                        (format nil "(defun alpha ()~%  \"A function.\"~%  2)~%"))
    (let ((provenance (index-provenance repository)))
      (is (eql 1 (getf provenance :drift))
          "one claimed file has changed since the index read it")
      (is (null (getf provenance :dirty))
          "and :DIRTY still describes the tree the analyzer read, which was
clean -- the two fields answer about different instants and that is the point"))))

(test an-edit-to-a-file-no-analyzer-claims-is-not-drift
  ;; The false positive that sent the first attempt at this back. A diff hash
  ;; moves when any file in the tree moves, and most of a tree is not indexed:
  ;; editing a Ruby tool script -- a language Loom does not index -- made
  ;; the harness report a stale service whose index was perfectly current.
  ;; A staleness signal that fires on every document and tool edit is one that
  ;; gets ignored.
  (with-committed-repository (repository root)
    ;; Ruby. The case that was actually measured was a Python script, and
    ;; DES-0053 made .py claimed. Not a .txt: since REQ-0028 a .md, .markdown or
    ;; .txt file is claimed wherever it lives, so a note file would be drift and
    ;; would be right to be.
    (write-scratch-file root "tools/harness.rb" "puts 'not indexed by any analyzer'")
    (is (eql 0 (getf (index-provenance repository) :drift))
        "the index is not behind on anything it claims")))

(test a-source-file-the-index-has-never-seen-is-unindexed-rather-than-drift
  ;; REQ-0050 asks as an open question whether the diff hash should cover
  ;; untracked files -- `git diff HEAD\' does not, so a new source file is
  ;; claimed by an analyzer and invisible to the fingerprint. Drift does not
  ;; see it either, and for a different reason: a stamp walk compares what the
  ;; index read against disk, and a file with no stamp has nothing to disagree
  ;; with.
  ;;
  ;; Two counts rather than one number that quietly covers both, because they
  ;; cost three orders of magnitude apart -- 1.6ms of stats against a 179ms
  ;; tree walk on Loom -- and only one of them can travel on every answer.
  (with-committed-repository (repository root)
    (write-scratch-file root "src/beta.lisp" (format nil "(defun beta () 2)~%"))
    (is (eql 0 (getf (index-provenance repository) :drift))
        "nothing the index read has moved")
    (is (eql 1 (unindexed-files repository))
        "and one file it has never read is there")))

(test a-deleted-file-is-drift
  ;; The case FILE-CHANGED-P answers the other way, correctly for its own
  ;; question: there is nothing to reanalyze. The index and the tree still
  ;; disagree, which is what drift is about.
  (with-committed-repository (repository root)
    (delete-file (merge-pathnames "src/alpha.lisp" root))
    (is (eql 1 (getf (index-provenance repository) :drift)))))

(test drift-and-the-commit-fail-independently
  ;; CON-0001, and the reason both halves are reported rather than one summary
  ;; verdict. DRIFT comes from REPOSITORY-STAMPS, which is Loom's own record of
  ;; the bytes it read, so it answers on a tree with no git in it at all.
  (with-scratch-repository (root :init nil)
    (write-scratch-file root "src/alpha.lisp" (format nil "(defun alpha () 1)~%"))
    (let ((repository (watch-repository root :monitor nil :quiet t)))
      (unwind-protect
           (let ((provenance (index-provenance repository)))
             (is (null (getf provenance :commit)))
             (is (stringp (getf provenance :commit-reason))
                 "a recorded gap rather than a blank where a commit should be")
             (is (eql 0 (getf provenance :drift))
                 "and the half that needs no git still answers"))
        (unwatch-repository (repository-name repository))))))

(test the-fingerprint-is-the-tree-the-analyzer-read-not-the-tree-now
  ;; The defect the field exists to fix, asserted directly: commit the edit and
  ;; the index's commit stays what it was, because nothing has reindexed.
  (with-committed-repository (repository root)
    (let ((before (getf (index-provenance repository) :commit)))
      (write-scratch-file root "src/alpha.lisp" (format nil "(defun alpha () 3)~%"))
      (commit-everything root "second")
      (let ((provenance (index-provenance repository)))
        (is (string= before (getf provenance :commit))
            "the index still says the commit it was built from")
        (is (string/= before (loom-workspace::git-commit root))
            "while the tree has moved on")
        (is (eql 1 (getf provenance :drift))
            "and the drift is what says the two are not the same tree")))))

;;; ------------------------------------------------------------------
;;; One file rather than the tree (REQ-0050 R1 on `describe')
;;; ------------------------------------------------------------------

(test a-single-file-answers-for-itself-and-carries-the-same-fingerprint
  (with-committed-repository (repository root)
    (let ((provenance (file-provenance repository "src/alpha.lisp")))
      (declare (ignorable root))
      (is (stringp (getf provenance :commit)))
      (is (stringp (getf provenance :branch))
          "the same fingerprint the tree-wide answer carries")
      (is (null (getf provenance :file-stale)))
      (is (null (getf provenance :drift))
          "absent rather than nought: a caller reading 0 here would take it for
a statement about the repository, which this never asked"))))

(test a-changed-file-says-so-without-walking-the-tree
  (with-committed-repository (repository root)
    (write-scratch-file root "src/alpha.lisp" (format nil "(defun alpha () 9)~%"))
    (is-true (getf (file-provenance repository "src/alpha.lisp") :file-stale))))

(test a-file-that-did-not-move-says-nothing-when-another-one-did
  ;; The whole reason this is per-file. Tree-wide drift would report 1 here and
  ;; a reader of an answer about ALPHA would take it as being about ALPHA.
  (with-committed-repository (repository root)
    (write-scratch-file root "src/beta.lisp" (format nil "(defun beta () 2)~%"))
    (watch-repository root :monitor nil :quiet t)   ; index BETA too
    (write-scratch-file root "src/beta.lisp" (format nil "(defun beta () 3)~%"))
    (is (null (getf (file-provenance repository "src/alpha.lisp") :file-stale))
        "alpha has not moved")
    (is-true (getf (file-provenance repository "src/beta.lisp") :file-stale)
             "and beta has")))

;;; ------------------------------------------------------------------
;;; The count that must not cost a tree walk (REQ-0050 R3, BUG-0048)
;;; ------------------------------------------------------------------

(test the-unindexed-count-is-recorded-by-the-walk-that-was-happening-anyway
  ;; It was computed per query, and REPOSITORY-FILES is a recursive directory
  ;; scan plus a `git check-ignore' subprocess: `status' over nine repositories
  ;; took 8.9 seconds, front-end 7.1 of them. The index build and every poll
  ;; already walk, so the count rides along.
  (with-committed-repository (repository root)
    (is (eql 0 (loom-workspace::repository-unindexed repository))
        "the index build filled it in, and it read every file it found")
    root))

(test a-file-nobody-has-indexed-is-counted-by-the-next-poll
  (with-committed-repository (repository root)
    (write-scratch-file root "src/beta.lisp" (format nil "(defun beta () 2)~%"))
    (is (eql 1 (unindexed-files repository))
        "the on-demand answer sees it at once")
    (loom-workspace::poll-once repository :quiet t)
    (is (eql 0 (loom-workspace::repository-unindexed repository))
        "and the poll that read it leaves nothing unindexed behind")))

(test the-count-is-unknown-rather-than-nought-before-anything-has-walked
  ;; CON-0001. Nought means the walk found none; a repository nobody has
  ;; indexed has not been looked at, and the two must not read alike.
  (is (null (loom-workspace::repository-unindexed (loom-workspace::make-repository :name "never-indexed")))))
