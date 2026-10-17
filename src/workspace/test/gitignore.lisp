;;;
;;; Tests for the ignore query of DES-0018 -- what a repository says is not
;;; part of it.
;;;
;;; These build their own git repositories, which is unusual here and is
;;; forced: BUG-0024's whole point is that neither Synoptik's own tree nor
;;; game-server vendors a dependency directory, so neither can exercise
;;; this. A fixture that ignores nothing would pass whatever the code did.
;;;

(in-package :synoptik-workspace-test)

(def-suite gitignore
  :in all-tests
  :description "REPOSITORY-FILES consulting git about what to skip (DES-0018).")

(in-suite gitignore)

(defun git-available-p ()
  (handler-case
      (zerop (nth-value 2 (uiop:run-program '("git" "--version")
                                            :output nil :error-output nil
                                            :ignore-error-status t)))
    (error () nil)))

(defun run-git (root &rest args)
  (uiop:run-program (append (list "git" "-C" (namestring root)) args)
                    :output nil :error-output nil :ignore-error-status t))

(defmacro with-scratch-repository ((root &key (init t)) &body body)
  "A throwaway directory, optionally a git repository, deleted afterwards."
  `(let ((,root (ensure-directories-exist
                 (merge-pathnames (format nil "synoptik-gitignore-~a/" (random 100000 (make-random-state t)))
                                  (uiop:temporary-directory)))))
     (unwind-protect
          (progn
            (when ,init
              (run-git ,root "init" "-q" ".")
              (run-git ,root "config" "user.email" "test@example.com")
              (run-git ,root "config" "user.name" "Synoptik Test"))
            ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun write-scratch-file (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string contents out))
    path))

;;; ------------------------------------------------------------------
;;; The query itself
;;; ------------------------------------------------------------------

(test an-ignored-file-is-reported-and-a-tracked-one-is-not
  ;; DES-0018 D3, and the assertion the whole design rests on. git consults the
  ;; index by default, so a file that was committed is part of the repository
  ;; however the patterns read -- a checked-in dist/ keeps being indexed while
  ;; a generated one does not. Committing is what makes this a real test; a
  ;; version that only wrote the file would pass for the wrong reason.
  (if (not (git-available-p))
      (skip "git is not on the path")
      (with-scratch-repository (root)
        (write-scratch-file root "docs/.gitignore" "")
        (write-scratch-file root ".gitignore" (format nil "dist/~%"))
        (write-scratch-file root "dist/kept.md" "# kept")
        (write-scratch-file root "dist/generated.md" "# generated")
        (run-git root "add" "-f" "dist/kept.md" ".gitignore")
        (run-git root "commit" "-qm" "keep one")
        (let ((ignored (synoptik-workspace::ignored-paths
                        root '("dist/kept.md" "dist/generated.md" "docs/real.md"))))
          (is-true  (gethash "dist/generated.md" ignored))
          (is-false (gethash "dist/kept.md" ignored)
                    "a tracked file is part of the repository whatever .gitignore says")
          (is-false (gethash "docs/real.md" ignored))))))

(test a-repository-that-ignores-nothing-is-not-a-failure
  ;; check-ignore exits 1 when no path matched. PLAN-0017 ranks reading that as
  ;; an error the most likely mistake, because it is the ordinary answer for a
  ;; clean tree and would make every repository behave as though git were gone.
  (if (not (git-available-p))
      (skip "git is not on the path")
      (with-scratch-repository (root)
        (write-scratch-file root "src/thing.lisp" "(defun thing () 1)")
        (multiple-value-bind (ignored reason)
            (synoptik-workspace::ignored-paths root '("src/thing.lisp"))
          (is (zerop (hash-table-count ignored)))
          (is (null reason) "exit status 1 means nothing matched, not that git failed")))))

(test a-directory-that-is-not-a-repository-ignores-nothing-and-says-why
  ;; DES-0018 D4/D5: index everything, record that git could not be consulted,
  ;; and do not fail the pass.
  (if (not (git-available-p))
      (skip "git is not on the path")
      (with-scratch-repository (root :init nil)
        (write-scratch-file root "src/thing.lisp" "(defun thing () 1)")
        (multiple-value-bind (ignored reason)
            (synoptik-workspace::ignored-paths root '("src/thing.lisp"))
          (is (zerop (hash-table-count ignored)))
          (is-true reason "a recorded absence, not a silent clean")))))

(test an-empty-candidate-list-asks-git-nothing
  (multiple-value-bind (ignored reason)
      (synoptik-workspace::ignored-paths #p"/nonexistent/" '())
    (is (zerop (hash-table-count ignored)))
    (is (null reason))))

;;; ------------------------------------------------------------------
;;; The filter, through REPOSITORY-FILES
;;; ------------------------------------------------------------------

(test repository-files-skips-what-git-ignores
  ;; BUG-0024 in miniature: a vendored directory holding a document an
  ;; analyzer claims. Before the fix this returns both files.
  (if (not (git-available-p))
      (skip "git is not on the path")
      (with-scratch-repository (root)
        (write-scratch-file root ".gitignore" (format nil "node_modules/~%"))
        (write-scratch-file root "docs/real.md" "# The project")
        (write-scratch-file root "node_modules/dep/docs/vendored.md" "# Somebody else")
        (let* ((repository (synoptik-workspace::make-repository :root root :name "scratch"))
               (files (mapcar #'namestring (synoptik-workspace::repository-files repository))))
          (is (= 1 (length files))
              "the vendored document is not part of this repository")
          (is-true (search "docs/real.md" (first files)))))))
