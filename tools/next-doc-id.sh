#!/bin/bash
# The next free document id for a docs/ category.
#
#   tools/next-doc-id.sh ARCH     -> ARCH-0002
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
# cannot match the glob below, so a file open in an editor never shifts the
# answer.

set -u

root=$(cd "$(dirname "$0")/.." && pwd) || exit 1

# category prefix : directory under docs/
types="REQ:requirements ARCH:arch DEC:design PLAN:plans REV:reviews BUG:bugs CON:concepts RULE:rules"

next_for() {
    local type=$1 dir=$2 highest=0 f base n

    for f in "$root/docs/$dir/$type"-[0-9][0-9][0-9][0-9].yaml; do
        [ -e "$f" ] || continue          # no match: the glob came through literally
        base=$(basename "$f" .yaml)
        n=$((10#${base#"$type"-}))       # 10# so 0004 is four, not an octal error
        [ "$n" -gt "$highest" ] && highest=$n
    done

    printf '%s-%04d\n' "$type" $((highest + 1))
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
printf 'One of: REQ ARCH DEC PLAN REV BUG CON RULE\n' >&2
exit 1
