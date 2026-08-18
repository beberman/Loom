#!/bin/bash
# Prepare a repository for the Loom workflow.
#
#   tools/loom-init.sh /path/to/repo
#   tools/loom-init.sh /path/to/repo --docs knowledge --yes
#   tools/loom-init.sh /path/to/repo --no-claude-md
#
# What only a script can do, which is the whole of why this exists alongside
# the `init' command rather than instead of it (DES-0022 D3). The commands do
# the writing and are covered by nine test systems; this asks REQ-0021 R16's
# two questions at a terminal, and drives the three commands in the one order
# that works -- init, watch, architecture -- because a structural report needs
# an index and init runs before there is one.
#
# It writes and never commits (R1a). `git status' in the target shows exactly
# what was added.
#
# Flags, so a non-interactive caller never reaches a prompt:
#   --yes            prepare without asking the first question
#   --claude-md      append the pointer without asking the second
#   --no-claude-md   do not append it, and do not ask
#   --docs <dir>     the document directory (default: docs)
#   --endpoint <h:p> where the service is (default: 127.0.0.1:4780)

set -u
LOOM_ROOT=/home/beberman/lisp/Loom
cd "$LOOM_ROOT" || exit 1

TARGET=""
DOCS="docs"
ENDPOINT="127.0.0.1:4780"
ASSUME_YES=0
CLAUDE_MD="ask"

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)          ASSUME_YES=1 ;;
        --claude-md)    CLAUDE_MD="yes" ;;
        --no-claude-md) CLAUDE_MD="no" ;;
        --docs)         shift; DOCS="${1:-docs}" ;;
        --endpoint)     shift; ENDPOINT="${1:-127.0.0.1:4780}" ;;
        -*)             echo "unknown flag: $1" >&2; exit 2 ;;
        *)              TARGET="$1" ;;
    esac
    shift
done

if [ -z "$TARGET" ]; then
    echo "usage: tools/loom-init.sh <directory> [--docs <dir>] [--endpoint <host:port>]" >&2
    echo "                          [--yes] [--claude-md | --no-claude-md]" >&2
    exit 2
fi

if [ ! -d "$TARGET" ]; then
    echo "No such directory: $TARGET" >&2
    exit 1
fi

TARGET=$(cd "$TARGET" && pwd)
NAME=$(basename "$TARGET")

# A prompt nobody can answer is a stall nobody sees, so the terminal test comes
# before every question rather than inside each one.
interactive() { [ -t 0 ] && [ -t 1 ]; }

ask() {
    # $1 prompt, $2 default when there is no terminal
    local answer
    if ! interactive; then
        printf '%s\n' "$2"
        return
    fi
    read -r -p "$1 " answer
    printf '%s\n' "${answer:-$2}"
}

echo "About to prepare: $TARGET"
echo "  documents      : $DOCS/"
echo "  service        : $ENDPOINT"
echo "  registered as  : $NAME"
echo
echo "This writes files into that repository and commits nothing."
echo

if [ "$ASSUME_YES" -ne 1 ]; then
    if ! interactive; then
        echo "Not a terminal and --yes was not given; declining rather than assuming." >&2
        exit 1
    fi
    reply=$(ask "Use Loom for development in this repository? [y/N]" "n")
    case "$reply" in
        y|Y|yes|Yes) ;;
        *) echo "Nothing was done."; exit 0 ;;
    esac
fi

# The second consent, asked separately. A yes to the first and a no to this is a
# supported outcome (R16): everything else is written and the tree is prepared
# but undiscovered, which is recoverable.
if [ "$CLAUDE_MD" = "ask" ]; then
    if [ -f "$TARGET/CLAUDE.md" ]; then
        echo
        echo "$TARGET/CLAUDE.md already exists ($(wc -l < "$TARGET/CLAUDE.md") lines)."
        echo "Loom would append a short pointer to it, between markers, so that an"
        echo "agent finds the workflow without being told. Nothing else in the file"
        echo "changes, and removal cuts exactly that region back out."
        reply=$(ask "Append the pointer to CLAUDE.md? [y/N]" "n")
        case "$reply" in
            y|Y|yes|Yes) CLAUDE_MD="yes" ;;
            *)           CLAUDE_MD="no" ;;
        esac
    else
        # No file to edit, so there is no consent to take: writing one is not
        # editing one, and R3 does not bear on a file that does not exist.
        CLAUDE_MD="yes"
    fi
fi

CONSENT=""
[ "$CLAUDE_MD" = "yes" ] && CONSENT="claude-md"

echo
echo "== preparing =="
./tools/loom.sh "init \"$TARGET\" $DOCS $CONSENT $ENDPOINT" || exit 1

echo
echo "== indexing and describing =="
# One session: both commands need the index the watch builds, and a second
# invocation would index the tree twice for no reason.
#
# `drift' before `architecture', which is REQ-0021 R7 read literally -- the
# prose is reviewed *before* the document is written. The first version had
# these the other way round, which made the ordering meaningless: the review
# printed after the document it was supposed to inform. It matters now because
# the generated document carries the prose attribution rather than only the
# structure.
./tools/loom.sh "watch \"$TARGET\"" "drift @$NAME" "architecture @$NAME" || exit 1

echo
echo "== what to do next =="
echo "  1. Read $DOCS/arch/ARCH-0001.yaml. Its invariants section is empty on"
echo "     purpose -- what must remain true is the half no index can derive."
echo "  2. Read the drift report above. A name there did not resolve; that means"
echo "     the prose and the index disagree, not that the prose is wrong."
echo "  3. Read the source comments yourself. Loom does not index them and"
echo "     deliberately does not -- a comment is what a source file is made of."
echo "  4. Review with 'git status' and 'git diff' in $TARGET, then commit if"
echo "     you want to keep it. Loom committed nothing."
echo
# The @token names a repository and must lead -- see DES-0021 D1. Written out
# here because the first draft of this line had it last and was wrong.
echo "To take it back out: tools/loom.sh 'remove @$NAME tooling'"
