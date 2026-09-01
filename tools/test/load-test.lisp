;;;; The structural check `check` cannot make.
;;;;
;;;;   sbcl --script tools/test/load-test.lisp loom-serve
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
;;;;
;;;; Two of those three stopped being temptations in REV-0002: LOG-EVENT and
;;;; INSTALL-DEBUGGER-HOOK are LOOM-UTILS' now, which both peers reach downward
;;;; rather than sideways. This check is what says the move went down and not
;;;; across, so `utils/' is in the registry below and `process/' still is not.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

;;;; Conspicuously not "process/": a registry entry for it would let the system
;;;; under test load it without saying so, which is the whole question.
(loom-harness:load-systems "tools/test/load-test.lisp"
                           :systems '("utils/" "embed/" "ontology/" "graph/" "analyzer/"
                                      "knowledge/" "workspace/" "serve/" "rest/" "mcp/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "stem"))

(let* ((name (or (second sb-ext:*posix-argv*)
                 (error "Usage: sbcl --script tools/load-test.lisp <system>")))
       (system (intern (string-upcase name) :keyword)))
  ;; REQ-0050 R5. A system that will not load is not a failed peer check -- it
  ;; is no check at all, and the two must not read alike. `loom-process' itself
  ;; is the case worth naming: it is absent from the registry above on purpose,
  ;; so asking for it by name fails here rather than being answered.
  (handler-case
      (handler-bind ((warning #'muffle-warning))
        (funcall (read-from-string "ql:quickload") system :silent t))
    (error (condition)
      (format *error-output*
              "~&tools/load-test.lisp did not run.~%~
                 ~2t~a failed to load: ~a~%~
                 ~2tNothing was checked. ~a~%"
              system condition
              (if (string-equal name "loom-process")
                  "loom-process is deliberately absent from this registry -- it is
  the system every other one is being checked against, and an entry for it
  would let the system under test load it without saying so."
                  "The peer property is unmeasured until it loads."))
      (finish-output *error-output*)
      (sb-ext:exit :code 2)))
  (let ((clean (null (find-package "LOOM-PROCESS"))))
    (format t "~&~a loaded; (find-package \"LOOM-PROCESS\") => ~a~%" system clean)
    (finish-output)
    (sb-ext:exit :code (if clean 0 1))))
