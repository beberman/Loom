#!/bin/bash
# The next free document id for a docs/ category.
#
#   tools/next-doc-id.sh ARCH     -> DES-0002
#   tools/next-doc-id.sh req      -> REQ-0005      (type is case-insensitive)
#   tools/next-doc-id.sh          -> every category, one per line
#
# Exists because the alternative is globbing docs/ by hand and reading the
# highest number off the listing, which is how a duplicate gets allocated: two
# documents with one id are ambiguous to every reference that names them, and
# CON-0004 records that this has already cost a document its place in the index.
#
# A gap is never reused. The answer is highest + 1, not lowest free, because
# reusing a retired number makes an old reference silently point at new content.
#
# Emacs backups (docs/x/REQ-0001.yaml~) and lock symlinks (docs/x/.#REQ-0001.yaml)
# cannot match the anchored pattern below, so a file open in an editor never
# shifts the answer.
#
# completed/ is searched as well as the category directory (now every directory
# under docs/, see doc_names), and that is not a refinement -- it is the whole
# correctness of this script. REQ-0022's `complete' MOVES a finished document
# into docs/<category>/completed/, so the highest id in a mature category is
# normally in there and not beside its open siblings.
# Looking only at the open ones answered BUG-0026 on 2026-08-14, when BUG-0026
# and BUG-0027 were both already taken and sitting in completed/. A duplicate
# was written and had to be renumbered -- which is exactly the failure the
# header above says this script exists to prevent, produced by the script
# itself.

set -u

root=$(cd "$(dirname "$0")/.." && pwd) || exit 1

# category prefix : directory under docs/
#
# Allocation no longer reads the directory column: DES-0056 R4 matches an id
# anywhere under docs/, so a DEC in docs/design/ on an old branch counts. The
# column stays because tools/doc-ids.py and test-next-doc-id.py read this line
# and say where a category's documents are filed.
#
# DEC names docs/decisions and DES names docs/design, and BUG-0039 is what one
# row conflating them cost: `DEC' globbed docs/design, matched no DEC-nnnn, and
# answered DEC-0001 while four decisions already existed, and `DES' -- the
# category CON-0004's chain passes through between a requirement and a plan --
# had no row at all and exited 1.
types="REQ:requirements ARCH:arch DEC:decisions DES:design PLAN:plans REV:reviews BUG:bugs CON:concepts RULE:rules"

# Every file name under docs/ that could carry an id: the working tree, then the
# tree of every local branch and remote-tracking branch, one basename per line.
#
# DES-0056 R4. Highest + 1 over the working tree alone hands two branches cut
# from one commit the same id, and the allocator is the only place that can stop
# it before the document is written. Reading every branch's tree is what makes
# a second branch in the same clone answer the next id instead of the same one.
# A burned id is never reissued (REQ-0025), so an id that exists only on a stale
# branch still counts: ARCH-0001 to 0004 and the DEC files that sat under
# docs/design/ before BUG-0039 are on such branches today.
#
# Names are matched anywhere under docs/, not under the category's own
# directory, for the same reason: a DEC-nnnn on an old ref sits in docs/design/.
#
# git is asked for nothing it cannot answer. A directory that is not a git
# repository, a repository with no commits, a ref that does not resolve, or no
# git on PATH all leave the working tree's names alone. -z because git quotes a
# path with unusual bytes otherwise, and a quoted directory would hide the id
# below it. ls-tree is given each ref's commit id rather than its name: a
# branch called like a tag is not ambiguous, a name with unusual bytes is not
# decoded and encoded again on the way back, and two refs at one commit are
# read once.
doc_names() {
    local commit
    find "$root/docs" -type f -name '*-[0-9][0-9][0-9][0-9].yaml' 2>/dev/null
    git -C "$root/docs" for-each-ref --format='%(objectname)' refs/heads refs/remotes 2>/dev/null |
    sort -u |
    while IFS= read -r commit; do
        git -C "$root/docs" ls-tree -r -z --name-only "$commit" 2>/dev/null | tr '\0' '\n'
    done
}

next_for() {
    local type=$1 highest

    # Once per run: `git ls-tree' costs a process per ref, and all nine
    # categories read the same names.
    [ -n "${names+x}" ] || names=$(doc_names | sed 's|.*/||' | sort -u)

    # A backup (REQ-0001.yaml~) or a lock (.#REQ-0001.yaml) cannot match the
    # anchored pattern, so a file open in an editor never shifts the answer.
    highest=$(printf '%s\n' "$names" |
              grep -E "^$type-[0-9]{4}\.yaml\$" |
              sed -E 's/^[A-Z]+-0*([0-9]+)\.yaml$/\1/' |
              sort -n | tail -n 1)

    printf '%s-%04d\n' "$type" $((10#${highest:-0} + 1))   # 10# so 0004 is four, not octal
}

if [ $# -eq 0 ]; then
    for pair in $types; do
        next_for "${pair%%:*}" "${pair##*:}"
    done
    exit 0
fi

want=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')

for pair in $types; do
    if [ "${pair%%:*}" = "$want" ]; then
        next_for "${pair%%:*}" "${pair##*:}"
        exit 0
    fi
done

printf 'Unknown document type: %s\n' "$1" >&2
printf 'One of: REQ ARCH DEC DES PLAN REV BUG CON RULE\n' >&2
exit 1
