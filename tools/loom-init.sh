#!/bin/bash
# Prepare a repository for the Loom workflow.
#
#   tools/loom-init.sh /path/to/repo
#   tools/loom-init.sh /path/to/repo --docs knowledge --yes
#   tools/loom-init.sh /path/to/repo --no-claude-md
#   tools/loom-init.sh /path/to/repo --update
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
#   --update         refresh a repository already prepared, replacing what Loom
#                    wrote and leaving what an author added below the
#                    <!-- loom:yours --> marker (REQ-0052)
#   --replace-unproven  on --update, rewrite a file whose digest the manifest
#                    never recorded. Asked for at a terminal when omitted

set -u
# Derived as loom.sh derives it, through any symlink, so a `loom-init' on PATH
# reaches the checkout it links to. REQ-0079 R1; the path was written in here.
LOOM_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd) || exit 1
cd "$LOOM_ROOT" || exit 1

TARGET=""
DOCS="docs"
ENDPOINT="127.0.0.1:4780"
ASSUME_YES=0
CLAUDE_MD="ask"
UPDATE=0
REPLACE_UNPROVEN="ask"

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)          ASSUME_YES=1 ;;
        --claude-md)    CLAUDE_MD="yes" ;;
        --no-claude-md) CLAUDE_MD="no" ;;
        --update)       UPDATE=1 ;;
        --replace-unproven) REPLACE_UNPROVEN="yes" ;;
        --no-replace-unproven) REPLACE_UNPROVEN="no" ;;
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
    echo "                          [--update] [--replace-unproven]" >&2
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

# REQ-0052 R1. A refresh is a different run from a preparation: it makes no
# directory, writes no document and asks neither of the two consents a first
# contact asks, because the tree already answered both. It does ask the third
# -- whether to rewrite a file whose digest the manifest never recorded -- and
# that question is asked here for R16's reason, that this is where a terminal
# is.
if [ "$UPDATE" -eq 1 ]; then
    if [ ! -f "$TARGET/.loom/manifest.yaml" ]; then
        echo "$TARGET carries no Loom manifest, so there is nothing to refresh." >&2
        echo "Run without --update to prepare it." >&2
        exit 1
    fi

    echo "About to refresh: $TARGET"
    echo
    echo "This replaces what Loom wrote and leaves what you added below the"
    echo "<!-- loom:yours --> marker. It commits nothing."
    echo

    # REQ-0052 R2. The dry run first, always: this run's writes are over text
    # that already exists, so the caller sees the list before anything moves.
    echo "== what a refresh would change =="
    ./tools/loom.sh "init \"$TARGET\" --update" || exit 1

    # R16's third consent, asked only when the report above could have named an
    # unproven file. A tree prepared since digests existed never reaches it.
    if [ "$REPLACE_UNPROVEN" = "ask" ]; then
        # A manifest with a `rendered:' section records a digest per file, so
        # nothing in this tree can be unproven and the question is not worth
        # asking. Only a tree prepared before REQ-0052 reaches the prompt.
        if grep -q "^rendered:" "$TARGET/.loom/manifest.yaml" 2>/dev/null; then
            REPLACE_UNPROVEN="no"
        elif interactive; then
            echo
            echo "If a file above says it has no recorded digest, it was written"
            echo "before Loom kept one and cannot be shown to be unmodified."
            echo "Replacing it discards any edit made to it since; leaving it keeps"
            echo "that edit and the file stays stale."
            reply=$(ask "Also replace files with no recorded digest? [y/N]" "n")
            case "$reply" in
                y|Y|yes|Yes) REPLACE_UNPROVEN="yes" ;;
                *)           REPLACE_UNPROVEN="no" ;;
            esac
        else
            REPLACE_UNPROVEN="no"
        fi
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        if ! interactive; then
            echo
            echo "Not a terminal and --yes was not given; the dry run above is all" >&2
            echo "that ran. Nothing was written." >&2
            exit 0
        fi
        reply=$(ask "Apply this refresh? [y/N]" "n")
        case "$reply" in
            y|Y|yes|Yes) ;;
            *) echo "Nothing was written."; exit 0 ;;
        esac
    fi

    EXTRA=""
    [ "$REPLACE_UNPROVEN" = "yes" ] && EXTRA=" --replace-unproven"
    echo
    echo "== refreshing =="
    ./tools/loom.sh "init \"$TARGET\" --update --apply$EXTRA" || exit 1

    echo
    echo "Review with 'git diff' in $TARGET. Loom committed nothing."
    exit 0
fi

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
