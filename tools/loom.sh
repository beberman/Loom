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
cd /home/beberman/lisp/Loom || exit 1

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
    echo 'watch "~/lisp/Loom"'
    emit_commands "$@"
    echo 'stop'
} | sbcl --script loom.lisp 2>&1 | grep -v -e '^; ' -e '^;$' -e '^ *$'
