#!/bin/bash
# Run Loom's full test suite: nine systems, per-system pass/fail summary.
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
  (dolist (system '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "process/" "serve/" "rest/" "mcp/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid" "eclector" "stem")
           :silent t))
(load "/home/beberman/lisp/Loom/src/full-test.lisp")
(funcall (read-from-string "loom-test:full-test"))
LISP

# The filter is stateful because FiveAM's failure block is not greppable.
# BUG-0058: a run reported `Fail: 1' and every line naming the test was
# discarded -- `Failure Details:' is not `Fail:', and grep -E is case-sensitive
# so `fail' does not match `Failure' either. The one line that did survive
# matched `FAIL' inside a test called NOT-A-FAILURE and was not the failing
# test, which is worse than printing nothing.
#
# Matching the detail lines individually is not possible: the message is
# arbitrary text and the separators are dashes. So the block is passed whole,
# switched on by its own heading and off by the next system header.
if [ "${1:-}" = "-v" ]; then
    sbcl --script "$driver" 2>&1
else
    sbcl --script "$driver" 2>&1 | awk '
        /^=====/                                    { detail = 0 }
        /Failure Details/                           { detail = 1 }
        detail                                      { print; next }
        /ok  |FAIL|passed|Pass:|Fail:|====|Did not|error/ { print }
    '
fi
