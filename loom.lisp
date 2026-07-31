;;;; Launcher: start the Loom process and hand over a console.
;;;;
;;;;   sbcl --script loom.lisp [/path/to/repo ...]
;;;;
;;;; Deliberately a script rather than a saved image. SS3.4 allows an on-disk
;;;; index cache and defers it -- "Phase 1 may ship without it -- indexing the
;;;; game engine takes seconds" -- and the same reasoning applies here: a few
;;;; seconds of compile at startup is not worth a build step yet. When it is,
;;;; the same forms go into an SB-EXT:SAVE-LISP-AND-DIE.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((here (make-pathname :name nil :type nil :defaults *load-truename*)))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "process/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))

(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid") :silent t)
  (asdf:load-system :loom-process))

(apply (read-from-string "loom-process:main")
       (rest sb-ext:*posix-argv*))
