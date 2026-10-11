#!/usr/bin/env python3
"""Find document-id collisions between a branch and the branch it merges into.

    tools/doc-ids.py check [--base REF]      exit 0 clean, 1 on any failure

DES-0056 R1. tools/next-doc-id.sh hands two branches cut from one commit the same
next id, and nothing else in the tree notices: for DEC, DES, ARCH, RULE and CON
the natural key is :doc-id, so two files become one entity before any query can
see it. Only a reader of files can. This reads them through git, needs only
python3's standard library and git, and writes nothing.

A document is a PREFIX-nnnn.yaml file under docs/, four digits as the allocators
match them. The prefixes come from the `types=` line of tools/next-doc-id.sh
(DES-0056 R3: no third copy of the table). Only committed files are read, through
`git ls-tree` and `git cat-file`, so an untracked or uncommitted file never
fails a check. HEAD is the branch, BASE defaults to origin/main, and MB is their
merge base.

    C1  an id added on HEAD (absent at MB) that BASE also carries, under any path
    C2  one id carried by two paths in HEAD's tree, or in the tree BASE and HEAD
        would produce together (a document copied rather than moved)
    C3  a file whose name is not its id:
    C4  a refines: or supersedes: entry, in a document HEAD added or modified,
        that names no document or more than one
    C5  a line HEAD added, in any tracked file, that names an id BASE added after
        MB and HEAD does not carry

Each C1 failure prints the renumber command that resolves it. `renumber` is a
later subcommand: COMMANDS is where it registers.
"""

import argparse
import os
import re
import subprocess
import sys

DEFAULT_BASE = "origin/main"
CHECK_ORDER = ("C1", "C2", "C3", "C4", "C5")
ID_FIELDS = ("refines", "supersedes")
KEY_LINE = r"(?P<key>[A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(?P<rest>.*))?"
HUNK_HEADER = r"@@ -\d+(?:,(?P<old>\d+))? \+(?P<new>\d+)(?:,(?P<count>\d+))? @@(?: .*)?"


class Refusal(Exception):
    """A sentence for the user. The script exits 1 on it rather than on a traceback."""


# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------

def run_git(root, *args, stdin=None):
    try:
        return subprocess.run(["git", "-C", root, *args], input=stdin, capture_output=True)
    except OSError as error:
        raise Refusal("git could not be run: %s" % error)


def git_text(root, *args):
    """Standard output of a git command that must succeed. Bytes git cannot decode
    survive as surrogates, so a path with unusual bytes can be handed back to git."""
    done = run_git(root, *args)
    if done.returncode != 0:
        message = done.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Refusal("git %s failed: %s" % (args[0], message[0] if message else "no message"))
    return done.stdout.decode("utf-8", "surrogateescape")


def resolve_commit(root, ref):
    """The commit REF names, or None."""
    done = run_git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
    return done.stdout.decode().strip() if done.returncode == 0 else None


def merge_base(root, head, base):
    done = run_git(root, "merge-base", head, base)
    if done.returncode != 0:
        raise Refusal("HEAD and %s share no history that this clone holds; fetch the full "
                      "history (actions/checkout needs fetch-depth: 0)" % base)
    return done.stdout.decode().strip()


def read_blobs(root, shas):
    """{sha: text} for every sha, through one `git cat-file --batch`. One process
    rather than a `git show` per file: this tree has 293 documents on each side."""
    shas = sorted(set(shas))
    if not shas:
        return {}
    done = run_git(root, "cat-file", "--batch", stdin="".join(sha + "\n" for sha in shas).encode())
    data, position, blobs = done.stdout, 0, {}
    for sha in shas:
        end = data.find(b"\n", position)
        header = data[position:end].split() if end >= 0 else []
        if len(header) != 3:
            raise Refusal("git holds no readable object %s; this clone may be partial" % sha)
        start = end + 1
        blobs[sha] = data[start:start + int(header[2])].decode("utf-8", "replace")
        position = start + int(header[2]) + 1
    return blobs


# ---------------------------------------------------------------------------
# The document table, and what a document says
# ---------------------------------------------------------------------------

def document_prefixes(root):
    """The category prefixes of tools/next-doc-id.sh's types= line, which sits
    beside this script. DES-0056 R3."""
    path = os.path.join(root, "tools", "next-doc-id.sh")
    try:
        with open(path, encoding="utf-8") as handle:
            found = re.search(r'^types="([^"]+)"', handle.read(), re.M)
    except OSError as error:
        raise Refusal("cannot read the category table in %s: %s" % (path, error.strerror))
    pairs = [entry.split(":") for entry in found.group(1).split()] if found else []
    if not pairs or any(len(pair) != 2 for pair in pairs):
        raise Refusal("%s has no types= line of PREFIX:directory entries" % path)
    return [prefix for prefix, _directory in pairs]


def document_tree(root, commit, prefixes):
    """{path: blob sha} for every PREFIX-nnnn.yaml under docs/ at COMMIT. A
    symlink is not a document: its blob is the link's target."""
    name = r"(?:%s)-\d{4}\.yaml" % "|".join(re.escape(prefix) for prefix in prefixes)
    tree = {}
    for entry in git_text(root, "ls-tree", "-r", "-z", commit, "--", "docs").split("\0"):
        meta, _tab, path = entry.partition("\t")
        fields = meta.split()
        if len(fields) == 3 and fields[1] == "blob" and fields[0] != "120000" \
                and re.fullmatch(name, os.path.basename(path)):
            tree[path] = fields[2]
    return tree


def strip_comment(text):
    """TEXT without a trailing ` # comment`, leaving a # inside quotes alone."""
    quote = None
    for index, char in enumerate(text):
        if quote:
            quote = None if char == quote else quote
        elif char in "\"'":
            quote = char
        elif char == "#" and (index == 0 or text[index - 1].isspace()):
            return text[:index].rstrip()
    return text.rstrip()


def scalar(text):
    """A YAML scalar's value for the plain and quoted forms an id takes."""
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def flow_items(lines, index, rest):
    """(entries, next line) of a `[a, b]` list that may run over several lines."""
    text, last = rest, index
    while "]" not in text and last + 1 < len(lines):
        last += 1
        text += " " + strip_comment(lines[last])
    inner = text[1:text.index("]")] if "]" in text else text[1:]
    return [scalar(item) for item in inner.split(",") if item.strip()], last + 1


def block_items(lines, index):
    """(entries, next line) of a `- a` list on the lines after a bare `key:`. The
    dashes may sit at the key's own column, which YAML allows."""
    items, last = [], index + 1
    while last < len(lines):
        line = lines[last]
        entry = re.match(r"\s*-(?:\s+(.*))?$", line)
        if line.strip() and not line.lstrip().startswith("#") and not entry:
            break
        if entry:
            items.append(scalar(strip_comment(entry.group(1) or "")))
        last += 1
    return items, last


def list_items(lines, index, rest):
    """The entries of the list whose key is on lines[index] with REST after it
    (None for no text), and the first line it did not consume: a one-line or
    multi-line flow list, a block list, or a single plain scalar."""
    rest = strip_comment(rest or "")
    if rest.startswith("["):
        return flow_items(lines, index, rest)
    if rest:
        return ([] if scalar(rest) in ("null", "~") else [scalar(rest)]), index + 1
    return block_items(lines, index)


def read_document(text):
    """{"id", "refines", "supersedes"} by a line scan for top-level keys. The scan
    src/docstore/status-line.lisp makes for `status:`: a parse would need PyYAML,
    and a block scalar's indented lines cannot be mistaken for a key at column 0."""
    lines = text.splitlines()
    document = {"id": None, "refines": [], "supersedes": []}
    index = 0
    while index < len(lines):
        found = re.fullmatch(KEY_LINE, lines[index])
        key = found.group("key") if found else None
        if key == "id":
            value = scalar(strip_comment(found.group("rest") or ""))
            document["id"] = document["id"] or value or None
            index += 1
        elif key in ID_FIELDS:
            items, index = list_items(lines, index, found.group("rest"))
            document[key].extend(item for item in items if item)
        else:
            index += 1
    return document


def load_documents(tree, blobs):
    return {path: dict(read_document(blobs[sha]), sha=sha) for path, sha in tree.items()}


def carriers(documents):
    """{id: sorted paths} for every id some document in DOCUMENTS declares."""
    found = {}
    for path, document in documents.items():
        if document["id"]:
            found.setdefault(document["id"], []).append(path)
    return {id_: sorted(paths) for id_, paths in found.items()}


def merged_tree(mb, base, head):
    """The documents BASE and HEAD would produce together, as {path: sha}: BASE's,
    with what HEAD changed since MB laid over them. A path HEAD removed is removed.
    A path HEAD modified that BASE no longer has is left out: BASE moved it, and a
    merge would carry HEAD's edit to the new path, so keeping both would report a
    duplicate git would never write."""
    merged = dict(base)
    for path, sha in head.items():
        if mb.get(path) != sha and not (path in mb and path not in base):
            merged[path] = sha
    for path in mb:
        if path not in head:
            merged.pop(path, None)
    return merged


# ---------------------------------------------------------------------------
# The five checks. Each takes plain data and returns failure lines.
# ---------------------------------------------------------------------------

def check_c1(mb, base, head, base_ref, base_option):
    """An id HEAD added that BASE carries. The same document in both (same path,
    same blob) is a cherry-pick or a branch already merged, not a collision."""
    mb_ids, base_paths, head_paths = carriers(mb), carriers(base), carriers(head)
    failures = []
    for id_ in sorted(set(head_paths) - set(mb_ids)):
        same = all(head[path]["sha"] == base.get(path, {}).get("sha") for path in head_paths[id_])
        if id_ in base_paths and not same:
            failures.append(
                "C1 %s: added on HEAD (%s) and carried by %s (%s)\n"
                "     renumber with: tools/doc-ids.py renumber %s%s"
                % (id_, ", ".join(head_paths[id_]), base_ref, ", ".join(base_paths[id_]),
                   id_, base_option))
    return failures


def check_c2(head, merged):
    """One id on two paths, in HEAD's tree or in the merge of BASE and HEAD."""
    failures, seen = [], set()
    for label, documents in (("HEAD", head), ("the merge of BASE and HEAD", merged)):
        for id_, paths in sorted(carriers(documents).items()):
            if len(paths) > 1 and (id_, tuple(paths)) not in seen:
                seen.add((id_, tuple(paths)))
                failures.append("C2 %s: carried by %d paths in %s: %s"
                                % (id_, len(paths), label, ", ".join(paths)))
    return failures


def check_c3(head):
    """A file whose name is not its id:, or that has none."""
    failures = []
    for path, document in sorted(head.items()):
        stem = os.path.basename(path)[:-len(".yaml")]
        if document["id"] is None:
            failures.append("C3 %s: has no id: line" % path)
        elif document["id"] != stem:
            failures.append("C3 %s: is named %s but its id: is %s" % (path, stem, document["id"]))
    return failures


def check_c4(mb, head, merged):
    """A refines: or supersedes: entry, in a document HEAD added or modified, that
    names no document or several in the merge of BASE and HEAD."""
    known = carriers(merged)
    failures = []
    for path, document in sorted(head.items()):
        if path in mb and mb[path]["sha"] == document["sha"]:
            continue
        for field in ID_FIELDS:
            for entry in document[field]:
                holders = known.get(entry, [])
                if len(holders) != 1:
                    what = "names no document" if not holders else \
                        "names %d documents (%s)" % (len(holders), ", ".join(holders))
                    failures.append("C4 %s: %s %s %s" % (path, field, entry, what))
    return failures


def hunk_count(text):
    """A hunk header leaves out a count of 1."""
    return 1 if text is None else int(text)


def added_lines(diff):
    """(path, line number, text) for each line a `git diff -U0` adds. A hunk header
    says how many removed and added lines follow, so an added line that begins
    `++` is not taken for a file header, and `\\ No newline` markers are skipped."""
    path, hunk = None, None
    for line in diff.splitlines():
        if hunk and not line.startswith("\\"):
            if line.startswith("-") and hunk["old"] > 0:
                hunk["old"] -= 1
            elif line.startswith("+") and hunk["new"] > 0:
                yield path, hunk["line"], line[1:]
                hunk["new"] -= 1
                hunk["line"] += 1
            hunk = hunk if hunk["old"] or hunk["new"] else None
        elif not hunk and line.startswith("+++ "):
            path = line[len("+++ "):].split("\t")[0]
            path = None if path == "/dev/null" else re.sub(r"^b/", "", path)
        elif not hunk and re.fullmatch(HUNK_HEADER, line) and path:
            header = re.fullmatch(HUNK_HEADER, line)
            hunk = {"old": hunk_count(header.group("old")), "new": hunk_count(header.group("count")),
                    "line": int(header.group("new"))}


def check_c5(root, mb_commit, head_commit, base, mb, head):
    """A line HEAD added that names an id BASE added after MB and HEAD lacks."""
    foreign = sorted(set(carriers(base)) - set(carriers(mb)) - set(carriers(head)))
    if not foreign:
        return []
    token = r"(?<![A-Za-z0-9-])(?:%s)(?!\d)" % "|".join(re.escape(id_) for id_ in foreign)
    diff = git_text(root, "diff", "-U0", "--no-color", "--no-ext-diff", "-M",
                    mb_commit, head_commit)
    failures = []
    for path, number, text in added_lines(diff):
        for id_ in sorted(set(re.findall(token, text))):
            failures.append("C5 %s:%d: names %s, which BASE added after the merge base and "
                            "HEAD does not carry" % (path, number, id_))
    return failures


# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------

def command_check(args):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    prefixes = document_prefixes(root)
    head_commit = resolve_commit(root, "HEAD")
    if not head_commit:
        raise Refusal("%s is not a git repository with a commit on HEAD" % root)
    base_commit = resolve_commit(root, args.base)
    if not base_commit:
        raise Refusal("the base ref %s does not exist here; fetch it or name another with --base"
                      % args.base)
    mb_commit = merge_base(root, head_commit, base_commit)

    trees = {name: document_tree(root, commit, prefixes)
             for name, commit in (("mb", mb_commit), ("base", base_commit), ("head", head_commit))}
    merged = merged_tree(trees["mb"], trees["base"], trees["head"])
    blobs = read_blobs(root, [sha for tree in (*trees.values(), merged) for sha in tree.values()])
    documents = {name: load_documents(tree, blobs) for name, tree in trees.items()}
    documents["merged"] = load_documents(merged, blobs)

    option = "" if args.base == DEFAULT_BASE else " --base %s" % args.base
    failures = {
        "C1": check_c1(documents["mb"], documents["base"], documents["head"], args.base, option),
        "C2": check_c2(documents["head"], documents["merged"]),
        "C3": check_c3(documents["head"]),
        "C4": check_c4(documents["mb"], documents["head"], documents["merged"]),
        "C5": check_c5(root, mb_commit, head_commit, documents["base"],
                       documents["mb"], documents["head"]),
    }
    lines = [line for name in CHECK_ORDER for line in failures[name]]
    for line in lines:
        print(line)
    if lines:
        print("doc-ids: %d failure%s against %s" % (len(lines), "" if len(lines) == 1 else "s", args.base))
        return 1
    print("doc-ids: ok, %d documents against %s" % (len(documents["head"]), args.base))
    return 0


COMMANDS = {"check": command_check}


def build_parser():
    parser = argparse.ArgumentParser(prog="doc-ids.py", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="report id collisions between HEAD and BASE")
    check.add_argument("--base", default=DEFAULT_BASE,
                       help="the branch HEAD merges into (default %s)" % DEFAULT_BASE)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        code = COMMANDS[args.command](args)
    except Refusal as refusal:
        print("doc-ids: %s" % refusal, file=sys.stderr)
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
