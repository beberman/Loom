;;;; Launcher: start the Loom service, with or without a console attached.
;;;;
;;;;   sbcl --script loom-serve.lisp [/path/to/repo ...]
;;;;   sbcl --script loom-serve.lisp --headless [/path/to/repo ...]
;;;;
;;;; Parallel to loom.lisp and loading it rather than replacing it: loom.lisp
;;;; is still the way to get a console alone, and nothing about it changes.
;;;; ARCH-0006 R5 makes zero edits to console.lisp, loom.lisp, loom-process.asd
;;;; and src/process/package.lisp the mechanism by which the console cannot
;;;; regress, so this script wraps MAIN rather than modifying it.
;;;;
;;;; Two modes, because one assumption does not hold in both.
;;;;
;;;; INTERACTIVE-WITH-SERVICE, the default: start the listener, hand over to
;;;; loom-process:main completely unmodified -- the same `loom>' prompt, the
;;;; same commands -- and stop the listener when MAIN returns. `stop' or stdin
;;;; EOF ends both together.
;;;;
;;;; HEADLESS, with --headless: loom-serve:serve-forever, which never enters
;;;; the console. MAIN's return path depends on CONSOLE reading EOF from
;;;; *STANDARD-INPUT*, so under a detached run with stdin closed READ-LINE
;;;; returns :EOF immediately and this script would exit within its first
;;;; second, taking the listener with it. That is the difference the mode
;;;; exists for, and it is observable: run the default mode with stdin from
;;;; /dev/null and watch it exit; run --headless the same way and it stays up
;;;; until SIGTERM.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

;; A top-level parameter rather than the LET this used to be: ARCH-0007 R1 has
;; both lifecycle modes self-watch this root unconditionally, so the value the
;; registry pushes are computed from is needed again further down. *LOAD-TRUENAME*
;; is only bound while this file is being loaded, which is why it is captured
;; here rather than re-derived at the point of use.
(defparameter *here* (make-pathname :name nil :type nil :defaults *load-truename*))

(dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                  "workspace/" "process/" "serve/" "rest/" "mcp/"))
  (pushnew (merge-pathnames (concatenate 'string "src/" system) *here*)
           asdf:*central-registry* :test #'equal))

;; drakma is deliberately absent: it is the test suites' HTTP client and no
;; part of the service needs one.
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid"
             "hunchentoot" "cl-json")
           :silent t)
  ;; The two protocol systems register their handlers on loom-serve's seam in
  ;; a top-level form at load time, so loading them is what puts the routes and
  ;; the MCP endpoint on the acceptor. Neither names the other, and neither
  ;; names loom-process.
  (asdf:load-system :loom-serve)
  (asdf:load-system :loom-rest)
  (asdf:load-system :loom-mcp)
  (asdf:load-system :loom-process))

(defun pidfile-path ()
  "/tmp/loom-serve-<sanitized root>.pid, for this script's own tree.

The rule, stated once here and restated in shell in tools/loom-serve.sh so the
two agree without either passing the other an argument: the root's namestring,
leading and trailing `/' trimmed, every remaining `/' replaced by `-'. For this
tree that is /tmp/loom-serve-home-beberman-lisp-Loom.pid.

Under /tmp rather than at the tree's root, per ARCH-0007's fifth PROBLEM
finding: a watched tree is not guaranteed writable, and a fixed name inside one
collides the moment a second checkout of Loom runs its own service on the same
machine. Nothing under /tmp is ever inside a watched repository either, so this
needs no dot-prefix or exclusion rule to keep the self-watch from indexing it."
  (let ((sanitized (substitute #\- #\/ (string-trim "/" (namestring *here*)))))
    (format nil "/tmp/loom-serve-~a.pid" sanitized)))

(defun write-pidfile ()
  (with-open-file (stream (pidfile-path) :direction :output
                                         :if-exists :supersede
                                         :if-does-not-exist :create)
    (format stream "~d~%" (sb-unix:unix-getpid))))

(defun delete-pidfile ()
  (ignore-errors (delete-file (pidfile-path))))

(let* ((arguments (rest sb-ext:*posix-argv*))
       (headless (and (member "--headless" arguments :test #'string=) t))
       ;; ARCH-0007 R1: this script's own root is watched in both modes, always,
       ;; first. Without it the staleness comparison `tools/loom-serve.sh status'
       ;; makes has no repository to read an :indexed-at from, and would have to
       ;; guess "current" -- CON-0001's fabricated fact in operational clothing.
       ;; WATCH-REPOSITORY dedupes, so naming the same root again on the command
       ;; line reindexes rather than double-registering.
       (paths (cons (namestring *here*)
                    (remove "--headless" arguments :test #'string=))))
  (if headless
      ;; Not one opaque call to SERVE-FOREVER, for ARCH-0007's fifth PROBLEM
      ;; finding: the pidfile must be written strictly after START-SERVER
      ;; succeeds and strictly before the blocking loop, and SERVE-FOREVER's own
      ;; body has no seam there. So the watching and the START-SERVER call are
      ;; performed from this frame -- the same calls SERVE-FOREVER would make,
      ;; in the same order -- and SERVE-FOREVER is then asked to skip its own.
      (handler-case
          (progn
            (dolist (path paths)
              ;; The guard is SERVE-FOREVER's own, moved with the call it
              ;; wraps: a path that cannot be watched is one repository
              ;; missing, not a reason for the service not to start. Naming
              ;; LOOM-SERVE:GUARDED-CONDITION rather than ERROR is RULE-0004 --
              ;; cl-yaml's conditions are direct subtypes of CONDITION and an
              ;; ERROR clause would miss them.
              (handler-case
                  (funcall (read-from-string "loom-workspace:watch-repository")
                           path :quiet t)
                (loom-serve:guarded-condition (condition)
                  (format *error-output* "~&[loom-serve] cannot watch ~a: ~a~%"
                          path condition))))
            (funcall (read-from-string "loom-serve:start-server"))
            ;; Only now, and never speculatively: a process that loses the bind
            ;; race never touches this file, so there is nothing for it to
            ;; overwrite or wrongly delete out from under the actual winner.
            (write-pidfile)
            (unwind-protect
                 (funcall (read-from-string "loom-serve:serve-forever")
                          paths :already-started t)
              (delete-pidfile)))
        ;; What a lost bind race actually produces, unwrapped: Hunchentoot does
        ;; not catch or translate it and START-SERVER is not edited to either.
        (usocket:address-in-use-error ()
          (format *error-output*
                  "~&[loom-serve] another Loom service is already listening; exiting.~%")
          (finish-output *error-output*)))
      (handler-case
          (progn
            (funcall (read-from-string "loom-serve:start-server"))
            ;; UNWIND-PROTECT rather than a plain sequence: MAIN unwinds through
            ;; a THROW when the console says `stop', and a listener left running
            ;; after the process meant to end is the one failure this mode can
            ;; have.
            (unwind-protect
                 (apply (read-from-string "loom-process:main") paths)
              (funcall (read-from-string "loom-serve:stop-server"))))
        ;; No pidfile in this mode -- tools/loom-serve.sh only ever spawns
        ;; --headless -- so this branch has nothing to clean up, only a message
        ;; to print instead of a backtrace from --disable-debugger.
        (usocket:address-in-use-error ()
          (format *error-output*
                  "~&[loom-serve] another Loom service is already listening; exiting.~%")
          (finish-output *error-output*)))))
