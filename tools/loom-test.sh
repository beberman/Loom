#!/bin/bash
# Run Loom's full test suite: six systems, per-system pass/fail summary.
#
#   tools/loom-test.sh          summary only
#   tools/loom-test.sh -v       everything, including compile output
#
# Note this is /usr/bin/sbcl, not the SBCL behind SLIME. Where the two could
# disagree, say which one you ran.

set -u
cd /home/beberman/lisp/Loom || exit 1

driver=$(mktemp /tmp/loom-fulltest-XXXXXX.lisp)
trap 'rm -f "$driver"' EXIT

cat > "$driver" <<'LISP'
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((here #p"/home/beberman/lisp/Loom/"))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "process/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid") :silent t))
(load "/home/beberman/lisp/Loom/src/full-test.lisp")
(funcall (read-from-string "loom-test:full-test"))
LISP

if [ "${1:-}" = "-v" ]; then
    sbcl --script "$driver" 2>&1
else
    sbcl --script "$driver" 2>&1 | grep -E 'ok  |FAIL|fail|passed|Pass:|Fail:|====|Did not|error'
fi
