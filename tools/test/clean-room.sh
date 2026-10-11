#!/bin/bash
# Run Loom in a sandbox where nothing under /home exists but a copy of this
# tree and a Quicklisp of its own. REQ-0079 R1 and PLAN-0061 step 3.
#
#   tools/test/clean-room.sh                        the working tree, Quicklisp copied
#   tools/test/clean-room.sh --ref d3f2824          a commit instead of the working tree
#   tools/test/clean-room.sh --quicklisp fresh      install Quicklisp from the network
#   tools/test/clean-room.sh -- sbcl --script loom.lisp   one command instead of three
#
# Why this exists. A tree that loads on its author's machine says nothing about
# whether it loads on another, because the author's machine holds things the
# tree never declares: ~/lisp/utils behind a symlink in
# ~/quicklisp/local-projects, a ~/.sbclrc, a node under nvm. `--tmpfs /home`
# removes all of them at once. PLAN-0061 risk 5 is the control: the same script
# on d3f2824, which still depended on utils, must fail naming it. A sandbox
# that passes that commit is reading something it claims to hide, and every
# other result from it is void.
#
# What it proves: nothing under /home is read, including ~/lisp/utils,
# ~/quicklisp, ~/.sbclrc and nvm's node. What it does not prove: the OS package
# set. / is the host's, so libyaml, git, python3 and /usr/bin/node are present
# whether or not INSTALL.md names them.
#
# Needs bubblewrap (bwrap) and unprivileged user namespaces. The sandbox shares
# the host's network namespace so --quicklisp fresh can reach
# beta.quicklisp.org; the tests bind their own ports, not 4780.
#
# The scratch directory is printed and left behind, so a failure can be read
# in place. rm -rf it when done.

set -euo pipefail

ref=""
quicklisp=copy
command=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)       ref=${2:?--ref needs a commit}; shift 2 ;;
        --quicklisp) quicklisp=${2:?--quicklisp needs copy or fresh}; shift 2 ;;
        --)          shift; command=("$@"); break ;;
        -h|--help)   sed -n '2,/^$/p' "$0"; exit 0 ;;
        *)           echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done

case "$quicklisp" in
    copy|fresh) ;;
    *) echo "--quicklisp takes copy or fresh, not $quicklisp" >&2; exit 2 ;;
esac

command -v bwrap >/dev/null || { echo "bwrap is not installed (apt install bubblewrap)" >&2; exit 1; }

# The checkout this script lives in, two directories up from tools/test/.
root=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)

scratch=$(mktemp -d "${TMPDIR:-/tmp}/loom-clean-room-XXXXXX")
tree=$scratch/home/src/Loom
mkdir -p "$tree"
echo "scratch: $scratch"

# The snapshot. Without --ref it is what git would track if everything new were
# added, copied from the working tree, so an uncommitted file is tested. A file
# deleted from the working tree but still in the index is skipped; tar would
# stop on it.
if [ -z "$ref" ]; then
    echo "snapshot: working tree of $root"
    git -C "$root" ls-files -z --cached --others --exclude-standard |
        (cd "$root" && while IFS= read -r -d '' file; do
            if [ -e "$file" ] || [ -L "$file" ]; then printf '%s\0' "$file"; fi
        done) |
        tar -C "$root" --null -T - -cf - | tar -C "$tree" -xf -
else
    git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null ||
        { echo "no such commit: $ref" >&2; exit 1; }
    echo "snapshot: $(git -C "$root" rev-parse --short "$ref") from git archive"
    git -C "$root" archive "$ref" | tar -C "$tree" -xf -
fi

# A repository, so the self-index sees one and asks git what to skip (DES-0018).
git -C "$tree" init -q
git -C "$tree" add -A
git -C "$tree" -c commit.gpgsign=false -c user.name=clean-room -c user.email=clean-room@example.invalid \
    commit -q -m "clean-room snapshot"

if [ "$quicklisp" = copy ]; then
    cp -a "$HOME/quicklisp" "$scratch/home/quicklisp"
    # Every entry here is a symlink to a sibling checkout on the author's
    # machine. Deleting them is the point of the copy.
    find "$scratch/home/quicklisp/local-projects" -mindepth 1 -delete
fi

# Runs inside the sandbox. $1 is the invoking user's real home, $2 the
# Quicklisp mode; the command follows. Single-quoted so nothing expands here.
inner='
real_home=$1; quicklisp=$2; shift 2
if [ "$quicklisp" = fresh ]; then
    echo "== installing Quicklisp from beta.quicklisp.org =="
    curl -fsSL -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp &&
        sbcl --non-interactive --load /tmp/quicklisp.lisp \
             --eval "(quicklisp-quickstart:install)" >/tmp/quicklisp-install.log 2>&1 || {
        echo "Quicklisp install failed; the last lines of its log:" >&2
        tail -5 /tmp/quicklisp-install.log >&2
        exit 1
    }
    echo "installed: $HOME/quicklisp"
fi
echo "== sandbox =="
[ ! -e "$real_home" ] || { echo "FAIL: $real_home exists in the sandbox" >&2; exit 1; }
echo "ok: $real_home does not exist"
[ ! -e "$HOME/.sbclrc" ] || { echo "FAIL: $HOME/.sbclrc exists" >&2; exit 1; }
echo "ok: $HOME/.sbclrc does not exist"
[ -d "$HOME/quicklisp" ] || { echo "FAIL: no $HOME/quicklisp" >&2; exit 1; }
[ -z "$(find "$HOME/quicklisp/local-projects" -mindepth 1 \( -type d -o -type l \) 2>/dev/null)" ] ||
    { echo "FAIL: $HOME/quicklisp/local-projects holds a project" >&2; exit 1; }
echo "ok: $HOME/quicklisp/local-projects holds no project"
echo "node:    $(command -v node || echo none) $(node --version 2>&1 || true)"
echo "python3: $(python3 --version 2>&1)"
echo "sbcl:    $(sbcl --version 2>&1)"
echo "cwd:     $PWD"
echo
if [ $# -gt 0 ]; then
    "$@"
    exit $?
fi
status=0
out=$(mktemp)
# loom-test.sh and loom.sh end in a filter, so their exit status is that of the
# filter, which says nothing about the run. Each is judged by what it printed.
echo "== tools/loom-test.sh =="
tools/loom-test.sh | tee "$out"
grep -Eq "^([0-9]+) of \1 systems passed\.$" "$out" ||
    { echo "FAIL: loom-test.sh did not report every system passing" >&2; status=1; }
echo "== load-test.lisp loom-serve =="
sbcl --script tools/test/load-test.lisp loom-serve || status=1
echo "== loom.sh status | check =="
tools/loom.sh "status | check" | tee "$out"
grep -q "$PWD/" "$out" && ! grep -q Unhandled "$out" ||
    { echo "FAIL: loom.sh did not index $PWD" >&2; status=1; }
exit $status
'

status=0
bwrap --ro-bind / / --tmpfs /home --bind "$scratch/home" /home/tester \
      --tmpfs /tmp --dev /dev --proc /proc --unshare-pid --die-with-parent \
      --setenv HOME /home/tester --setenv PATH /usr/local/bin:/usr/bin:/bin \
      --unsetenv LOOM_EXTRA_REPOS --chdir /home/tester/src/Loom \
      bash -c "$inner" clean-room "$HOME" "$quicklisp" "${command[@]}" || status=$?

echo
echo "clean-room exit status: $status"
echo "scratch left at: $scratch"
exit $status
