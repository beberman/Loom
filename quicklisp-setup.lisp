;;;; Load Quicklisp's setup.lisp from the first place that has one.
;;;;
;;;; Every entry point loads this file instead of naming ~/quicklisp itself, so
;;;; that a machine with several users can keep one Quicklisp for all of them.
;;;; The places, in order:
;;;;
;;;;   $SYNOPTIK_QUICKLISP/setup.lisp   a directory the caller names
;;;;   ~/quicklisp/setup.lisp       the default Quicklisp install
;;;;   /usr/local/lib/quicklisp/setup.lisp
;;;;                                one copy for the machine
;;;;
;;;; A shared copy has to hold every library already, because the people using
;;;; it cannot write into it. SBCL compiles into each user's own ~/.cache, so
;;;; the copy stays unchanged. BUG-0074.
;;;;
;;;; Loaded with LOAD and not through ASDF, because it runs before Quicklisp
;;;; exists. It defines nothing, so that loading it twice is harmless.

(let* ((named (sb-ext:posix-getenv "SYNOPTIK_QUICKLISP"))
       (places (append (when (and named (plusp (length named)))
                         (list (merge-pathnames "setup.lisp"
                                                (uiop:ensure-directory-pathname named))))
                       (list (merge-pathnames "quicklisp/setup.lisp"
                                              (user-homedir-pathname))
                             #p"/usr/local/lib/quicklisp/setup.lisp")))
       (setup (find-if #'probe-file places)))
  (unless setup
    (format *error-output*
            "Synoptik needs Quicklisp and found none. It looked in:~%~{  ~A~%~}~
             Install it (INSTALL.md, \"Quicklisp\"), or name a directory with ~
             SYNOPTIK_QUICKLISP.~%"
            (mapcar #'namestring places))
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t))
  (load setup))
