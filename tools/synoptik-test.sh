#!/bin/bash
# Run Synoptik's full test suite: twelve systems, per-system pass/fail summary.
#
#   tools/synoptik-test.sh          summary only
#   tools/synoptik-test.sh -v       everything, including compile output
#
# Note this is /usr/bin/sbcl, not the SBCL behind SLIME. Where the two could
# disagree, say which one you ran.

set -u
# BUG-0072. The run ends in a filter, and without pipefail the script's status
# was awk's, which is 0 whatever sbcl did.
set -o pipefail
# REQ-0072 R1. The checkout this script lives in, resolved through any symlink,
# so a `synoptik' on PATH that points here reaches the tree it points into rather
# than whatever directory the caller happened to be standing in. `readlink -f'
# because the link is the whole point: $0 is /usr/local/bin/synoptik, and its
# dirname is /usr/local/bin, which contains no Synoptik.
#
# Hardcoded until 2026-09-10, on all three of synoptik.sh, synoptik-test.sh and
# synoptik-serve.sh, which made the tree unmovable and the scripts unlinkable.
# next-doc-id.sh had derived its own root correctly since it was written.
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd) || exit 1
cd "$root" || exit 1

driver=$(mktemp /tmp/synoptik-fulltest-XXXXXX.lisp)
trap 'rm -f "$driver"' EXIT

# REQ-0079 R1. The driver learns the checkout from SYNOPTIK_ROOT, which this script
# sets for the sbcl calls below, rather than from a path written into the
# heredoc: a copy of the tree anywhere else tested whatever the old path held.
cat > "$driver" <<'LISP'
(require :asdf)
(load (merge-pathnames "quicklisp-setup.lisp"
                       (uiop:ensure-directory-pathname (sb-ext:posix-getenv "SYNOPTIK_ROOT"))))
(let ((here (uiop:ensure-directory-pathname (sb-ext:posix-getenv "SYNOPTIK_ROOT"))))
  (dolist (system '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/"
                    "docstore/" "workspace/" "process/" "serve/" "rest/" "mcp/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid" "eclector" "stem")
           :silent t))
(load (merge-pathnames "src/full-test.lisp"
                       (uiop:ensure-directory-pathname (sb-ext:posix-getenv "SYNOPTIK_ROOT"))))
;; BUG-0072. FULL-TEST returns NIL when a system failed, and a script that ends
;; there exits 0 whatever it returned.
(sb-ext:exit :code (if (funcall (read-from-string "synoptik-test:full-test")) 0 1))
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
    SYNOPTIK_ROOT="$root" sbcl --script "$driver" 2>&1
else
    SYNOPTIK_ROOT="$root" sbcl --script "$driver" 2>&1 | awk '
        /^=====/                                    { detail = 0 }
        /Failure Details/                           { detail = 1 }
        detail                                      { print; next }
        /ok  |FAIL|passed|Pass:|Fail:|====|Did not|error/ { print }
    '
fi
