;;;; Launcher: start the Synoptik process and hand over a console.
;;;;
;;;;   sbcl --script synoptik.lisp [/path/to/repo ...]
;;;;
;;;; Deliberately a script rather than a saved image. SS3.4 allows an on-disk
;;;; index cache and defers it -- "Phase 1 may ship without it -- indexing the
;;;; game engine takes seconds" -- and the same reasoning applies here: a few
;;;; seconds of compile at startup is not worth a build step yet. When it is,
;;;; the same forms go into an SB-EXT:SAVE-LISP-AND-DIE.

(require :asdf)
(load (merge-pathnames "quicklisp-setup.lisp" *load-truename*))

(let ((here (make-pathname :name nil :type nil :defaults *load-truename*)))
  (dolist (system '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/"
                    "docstore/" "workspace/" "process/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))

(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid" "eclector" "stem")
           :silent t)
  ;; Quickloaded rather than loaded, so that Quicklisp downloads whatever the
  ;; .asd files declare. The list above is not that set: it left out cl-json,
  ;; and a Quicklisp that had never run the suite stopped at synoptik-analyzer.
  ;; BUG-0074.
  (funcall (read-from-string "ql:quickload") :synoptik-process :silent t))

(apply (read-from-string "synoptik-process:main")
       (rest sb-ext:*posix-argv*))
