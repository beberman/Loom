#!/bin/bash
# Run Loom console commands non-interactively.
#
#   tools/loom.sh 'status' 'find repository' 'impact repository 3'
#
# The tree is watched before the first command and stopped after the last, so
# each invocation is self-contained. Compile chatter is filtered out.
#
# Exists so agents can drive Loom through a single argv with no shell
# operators -- `bash -lc "... | ..."` trips the permission prompt every time.

set -u
cd /home/beberman/lisp/Loom || exit 1

{
    echo 'watch "~/lisp/Loom"'
    for cmd in "$@"; do
        echo "$cmd"
    done
    echo 'stop'
} | sbcl --script loom.lisp 2>&1 | grep -v -e '^; ' -e '^;$' -e '^ *$'
