#!/bin/bash
# Run Loom console commands non-interactively.
#
#   tools/loom.sh 'status | find repository | impact repository 3'
#   tools/loom.sh 'status' 'find repository' 'impact repository 3'
#
# Both forms work and may be mixed. Every argument is split on '|', so a whole
# session fits in one quoted string; surrounding whitespace is trimmed and
# empty segments are dropped. Commands run in the order written.
#
# The tree is watched before the first command and stopped after the last, so
# each invocation is self-contained. Compile chatter is filtered out.
#
# The '|' is inside the quotes and is never seen by the shell -- that is the
# point. Exists so agents can drive Loom through a single argv with no shell
# operators: `bash -lc "... | ..."` trips the permission prompt every time.
# .claude/settings.json carries a PreToolUse hook that decides this script's
# permission directly, because Claude Code's own matcher splits a command on
# '|' even inside quotes and would otherwise prompt on every invocation.

set -u
# BUG-0072. The pipeline ends in grep, whose status says whether it printed
# anything. With pipefail a console that died is not reported as a success.
set -o pipefail
# REQ-0072 R1. The checkout this script lives in, resolved through any symlink,
# so a `loom' on PATH that points here reaches the tree it points into rather
# than whatever directory the caller happened to be standing in. `readlink -f'
# because the link is the whole point: $0 is /usr/local/bin/loom, and its
# dirname is /usr/local/bin, which contains no Loom.
#
# Hardcoded until 2026-09-10, on all three of loom.sh, loom-test.sh and
# loom-serve.sh, which made the tree unmovable and the scripts unlinkable.
# next-doc-id.sh had derived its own root correctly since it was written.
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd) || exit 1
cd "$root" || exit 1

emit_commands() {
    local arg cmd
    for arg in "$@"; do
        # The trailing newline matters: `read` returns false on a final line
        # that has none, so without it the last command of every invocation is
        # silently dropped and its output never appears.
        while IFS= read -r cmd; do
            # trim leading and trailing whitespace
            cmd="${cmd#"${cmd%%[![:space:]]*}"}"
            cmd="${cmd%"${cmd##*[![:space:]]}"}"
            [ -n "$cmd" ] && printf '%s\n' "$cmd"
        done < <(printf '%s\n' "$arg" | tr '|' '\n')
    done
}

{
    # The checkout this script lives in, not a fixed path: a clone elsewhere
    # indexed that path, or failed to find it. REQ-0079 R1. Double quotes so
    # $root expands; the console reads the line as `watch "<root>"'.
    echo "watch \"$root\""
    emit_commands "$@"
    echo 'stop'
} | sbcl --script loom.lisp 2>&1 | grep -v -e '^; ' -e '^;$' -e '^ *$'
