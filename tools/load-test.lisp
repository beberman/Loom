;;;; The structural check `check` cannot make.
;;;;
;;;;   sbcl --script tools/load-test.lisp loom-serve
;;;;
;;;; Loads one system into a fresh image and asserts that LOOM-PROCESS is not
;;;; in it. Prints T and exits 0 when the system is a peer of loom-process;
;;;; prints NIL and exits 1 when something in it, or under it, pulled the
;;;; console in.
;;;;
;;;; This exists because the rule engine cannot see the property. PLAN-0005
;;;; FINDING 1 measured it: RULE-0001 to RULE-0003 are :no-edge checks keyed on
;;;; from-system and to-system, both resolved through LOOM-GRAPH:ENTITY-SYSTEM,
;;;; which returns the text before the *first* slash of a fact's file. Every
;;;; source entity in this tree carries a :file like "src/knowledge/services.lisp",
;;;; so every one of them is in system :SRC, every layering rule matches zero
;;;; entities, and "No violations." is a vacuous pass -- CON-0003's failure mode
;;;; at the rule level rather than the test level. A clean `check` is therefore
;;;; not evidence that loom-serve, loom-rest and loom-mcp stayed peers. This is.
;;;;
;;;; The failure mode worth guarding is one line: #:loom-process appearing in
;;;; loom-serve.asd, loom-rest.asd or loom-mcp.asd. Three reasonable-looking
;;;; edits reach for it -- LOG-EVENT for the service's own log,
;;;; INSTALL-DEBUGGER-HOOK for headless mode, and CURRENT-REPOSITORY or
;;;; RESOLVE-ENTITY from console.lisp -- and all three are caught here.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((here #p"/home/beberman/lisp/Loom/"))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "serve/" "rest/" "mcp/"))
    (let ((directory (merge-pathnames (concatenate 'string "src/" system) here)))
      ;; The directory for a system a later step has not created yet is simply
      ;; skipped: this script has to be runnable at the step that introduces
      ;; the first of the three.
      (when (probe-file directory)
        (pushnew directory asdf:*central-registry* :test #'equal)))))

;;;; Conspicuously not "process/": a registry entry for it would let the
;;;; system under test load it without saying so, which is the whole question.

(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "random-uuid") :silent t))

(let* ((name (or (second sb-ext:*posix-argv*)
                 (error "Usage: sbcl --script tools/load-test.lisp <system>")))
       (system (intern (string-upcase name) :keyword)))
  (handler-bind ((warning #'muffle-warning))
    (funcall (read-from-string "ql:quickload") system :silent t))
  (let ((clean (null (find-package "LOOM-PROCESS"))))
    (format t "~&~a loaded; (find-package \"LOOM-PROCESS\") => ~a~%" system clean)
    (finish-output)
    (sb-ext:exit :code (if clean 0 1))))
