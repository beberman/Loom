#!/usr/bin/env python3
"""Find document-id collisions between a branch and the branch it merges into.

    tools/doc-ids.py check [--base REF]      exit 0 clean, 1 on any failure
    tools/doc-ids.py renumber OLD [OLD ...] [--to NEW] [--base REF] [--apply]

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

Each C1 failure prints the renumber command that resolves it.

`renumber` is that command (DES-0056 R2, REQ-0079 R7(c)). Without --apply it is a
dry run: it prints every change and writes nothing, as `complete` does. OLD is an
id this branch added; NEW defaults to the next id tools/next-doc-id.sh answers for
OLD's category (several OLDs of one category take consecutive numbers), or is given
with --to for exactly one OLD. Four changes, all to the working tree:

    W1  `git mv` of the file whose id: is OLD to NEW.yaml, in the same directory
        (an open document stays open and a completed/ one stays in completed/)
    W2  that file's id: line, which W3 or W4 rewrites like any other occurrence
    W3  every whole-token OLD in each file HEAD added
    W4  every whole-token OLD on each line HEAD added to a file it modified

A whole token is not preceded by a letter, digit or hyphen and not followed by a
digit. A line present at the merge base is never rewritten, in any file. A commit
message is never edited: the commits in MB..HEAD that name OLD are listed so the
author can reword or squash them. status:, date: and a file's place relative to
completed/ are not touched, and nothing outside the repository is.

It refuses, with one sentence on stderr, exit 1 and nothing written, when OLD is
not a well-formed id of a known category; exists at the merge base (published
before the branch began, which REQ-0025 forbids reclaiming); is not carried by
exactly one path that HEAD added; when NEW is carried by the working tree or by any
ref; when a file it would edit has uncommitted changes, staged or not; or when
BASE is missing or shares no history. Files are read as bytes from the committed
blobs and written back as bytes, so line endings and a missing final newline
survive. A binary or non-UTF-8 file that would have changed is skipped and
reported. A symlink or submodule is not a file it reads.

It commits nothing and stages nothing, except what `git mv` stages for W1. After
--apply the author reviews with `git diff HEAD`, then runs `git add -A` and commits.
"""

import argparse
import os
import re
import subprocess
import sys

DEFAULT_BASE = "origin/main"
CHECK_ORDER = ("C1", "C2", "C3", "C4", "C5")
ID_FIELDS = ("refines", "supersedes")
REGULAR_MODES = ("100644", "100755")
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


def branch_commits(root, base_ref):
    """(HEAD, BASE, their merge base) as commit ids, or a Refusal saying which is
    missing. `check` and `renumber` give the same sentences."""
    head_commit = resolve_commit(root, "HEAD")
    if not head_commit:
        raise Refusal("%s is not a git repository with a commit on HEAD" % root)
    base_commit = resolve_commit(root, base_ref)
    if not base_commit:
        raise Refusal("the base ref %s does not exist here; fetch it or name another with --base"
                      % base_ref)
    return head_commit, base_commit, merge_base(root, head_commit, base_commit)


def read_blobs(root, shas, raw=False):
    """{sha: text} for every sha, through one `git cat-file --batch`. One process
    rather than a `git show` per file: this tree has 293 documents on each side.
    RAW answers the bytes, which a rewrite needs to leave every other byte alone."""
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
        body = data[start:start + int(header[2])]
        blobs[sha] = body if raw else body.decode("utf-8", "replace")
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
    `++` is not taken for a file header, and `\\ No newline` markers are skipped.
    Lines end at "\\n" only, as git's do: str.splitlines also breaks at a form feed,
    which Lisp sources carry, and the hunk's line numbers would drift after it."""
    path, hunk = None, None
    for line in diff.split("\n"):
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
# renumber
# ---------------------------------------------------------------------------

def require_known_id(old, prefixes):
    found = re.fullmatch(r"([A-Z]+)-\d{4}", old)
    if not found or found.group(1) not in prefixes:
        raise Refusal("%s is not a well-formed id of a known category (PREFIX-nnnn, one of %s)"
                      % (old, " ".join(prefixes)))


def sole_added_carrier(old, mb, head):
    """The one path HEAD added that carries OLD, or a Refusal. An id some document
    at MB carries, or a file at MB is named for, was published before the branch
    began, and renumbering it is the reclamation REQ-0025 forbids."""
    if old in carriers(mb) or any(os.path.basename(path) == old + ".yaml" for path in mb):
        raise Refusal("%s exists at the merge base, so it was published before this branch "
                      "began and is never reclaimed (REQ-0025)" % old)
    paths = carriers(head).get(old, [])
    if not paths:
        raise Refusal("HEAD did not add %s, so there is nothing to renumber" % old)
    if len(paths) > 1:
        raise Refusal("%s is carried by %d paths (%s); remove all but one first"
                      % (old, len(paths), ", ".join(paths)))
    if paths[0] in mb:
        raise Refusal("HEAD did not add %s: %s existed at the merge base" % (old, paths[0]))
    return paths[0]


def ref_tips(root, extra):
    """{commit id: [names]} for every local and remote-tracking ref, and EXTRA's
    (label, commit id) pairs: the commits the allocator reads, by id so that two
    refs at one commit are read once."""
    tips = {}
    listing = git_text(root, "for-each-ref", "--format=%(objectname) %(refname)",
                       "refs/heads", "refs/remotes")
    for line in listing.splitlines():
        commit, _space, name = line.partition(" ")
        tips.setdefault(commit, []).append(name)
    for label, commit in extra:
        tips.setdefault(commit, []).append(label)
    return tips


def places_naming(root, name, tips):
    """Where a docs/ file called NAME exists: the working tree, and each commit in
    TIPS. The allocator's notion of "carries": a file name, anywhere under docs/."""
    places = []
    if any(name in files for _dir, _dirs, files in os.walk(os.path.join(root, "docs"))):
        places.append("the working tree")
    for commit, labels in sorted(tips.items()):
        listing = git_text(root, "ls-tree", "-r", "-z", "--name-only", commit, "--", "docs")
        if any(os.path.basename(path) == name for path in listing.split("\0")):
            places.append(labels[0])
    return places


def allocator_answer(root, prefix):
    """The number tools/next-doc-id.sh, beside this script, answers for PREFIX."""
    script = os.path.join(root, "tools", "next-doc-id.sh")
    done = subprocess.run(["bash", script, prefix], capture_output=True, text=True)
    found = re.fullmatch(re.escape(prefix) + r"-(\d{4})\n?", done.stdout)
    if done.returncode != 0 or not found:
        raise Refusal("tools/next-doc-id.sh did not answer a %s id (%s); name one with --to"
                      % (prefix, (done.stderr.strip() or done.stdout.strip() or "no output")))
    return int(found.group(1))


def allocated_ids(root, olds):
    """{OLD: NEW}. The allocator is asked once per category. A dry run writes
    nothing for it to count, so each further OLD of that category takes the number
    above the last."""
    numbers, mapping = {}, {}
    for old in olds:
        prefix = old.rsplit("-", 1)[0]
        numbers[prefix] = numbers[prefix] + 1 if prefix in numbers else allocator_answer(root, prefix)
        mapping[old] = "%s-%04d" % (prefix, numbers[prefix])
    return mapping


def explicit_id(root, old, new, tips):
    """NEW from --to, or a Refusal: it must be a four-digit id of OLD's category
    that no ref and nothing in the working tree carries."""
    prefix = old.rsplit("-", 1)[0]
    if not re.fullmatch(re.escape(prefix) + r"-\d{4}", new):
        raise Refusal("--to %s is not a four-digit %s id" % (new, prefix))
    places = ["OLD itself"] if new == old else places_naming(root, new + ".yaml", tips)
    if places:
        raise Refusal("%s is already carried by %s; name another id or omit --to"
                      % (new, ", ".join(places)))
    return {old: new}


def branch_changes(root, mb_commit, head_commit):
    """One dict per path HEAD changed since MB: status, the new mode, the new blob
    id, and the path (the new one, for a rename)."""
    raw = git_text(root, "diff", "--raw", "-z", "-M", "--no-abbrev", "--no-color",
                   "--no-ext-diff", mb_commit, head_commit)
    fields, changes, index = raw.split("\0"), [], 0
    while index < len(fields) and fields[index].startswith(":"):
        meta = fields[index].split()
        paths = 2 if meta[4][0] in "RC" else 1
        changes.append({"status": meta[4], "mode": meta[1], "sha": meta[3],
                        "path": fields[index + paths]})
        index += 1 + paths
    return changes


def branch_hunks(root, mb_commit, head_commit):
    """{path: {line number: text}} for every line HEAD added, by added_lines."""
    diff = git_text(root, "-c", "core.quotePath=false", "diff", "-U0", "--no-color",
                    "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/",
                    mb_commit, head_commit)
    found = {}
    for path, number, text in added_lines(diff):
        found.setdefault(path, {})[number] = text
    return found


def token_pattern(olds):
    """Whole-token OLD, as bytes: not preceded by a letter, digit or hyphen, and not
    followed by a digit. No capture group, so findall answers the matches."""
    return re.compile(rb"(?<![A-Za-z0-9-])(?:%s)(?!\d)"
                      % b"|".join(re.escape(old.encode()) for old in olds))


def rewrite_lines(data, pattern, mapping, only=None):
    """(new bytes, [(line number, [OLD ...])]). Lines end at b"\\n", so a CR stays
    where it was and a missing final newline stays missing. ONLY, {number: text},
    limits the rewrite to those lines and only where the line still reads as the
    diff said it did: a line that is not exactly one HEAD added is never touched."""
    lines, changes = data.split(b"\n"), []
    for number, line in enumerate(lines, 1):
        if only is not None and only.get(number) != line.decode("utf-8", "surrogateescape"):
            continue
        found = sorted({match.decode() for match in pattern.findall(line)})
        if found:
            lines[number - 1] = pattern.sub(lambda m: mapping[m.group().decode()].encode(), line)
            changes.append((number, found))
    return b"\n".join(lines), changes


def why_unreadable(data):
    """Why DATA is not text this command will rewrite, or None."""
    if b"\0" in data:
        return "a binary file"
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return "not UTF-8"
    return None


def plan_edits(candidates, blobs, hunks, mapping):
    """({path: (new bytes, changes)}, [(path, why)]) for the changed files. W3: a
    file HEAD added (status A) is rewritten on every line. W4: any other, on the
    lines HEAD added to it. A file that would have changed but is binary or not
    UTF-8 is skipped and reported, never rewritten."""
    pattern = token_pattern(mapping)
    edits, skipped = {}, []
    for change in candidates:
        only = None if change["status"] == "A" else hunks.get(change["path"], {})
        data, changes = rewrite_lines(blobs[change["sha"]], pattern, mapping, only)
        why = why_unreadable(blobs[change["sha"]]) if changes else None
        if why:
            skipped.append((change["path"], why))
        elif changes:
            edits[change["path"]] = (data, changes)
    return edits, skipped


def refuse_if_dirty(root, paths):
    """A Refusal naming the first of PATHS with a staged or unstaged change. Exactly
    these paths, literally, and without refreshing the index: a dry run writes
    nothing, not even under .git."""
    done = run_git(root, "--no-optional-locks", "--literal-pathspecs", "status",
                   "--porcelain", "-z", "--untracked-files=no", "--", *paths)
    if done.stdout:
        dirty = done.stdout.decode("utf-8", "surrogateescape")[3:].split("\0")[0]
        raise Refusal("%s has uncommitted changes and renumber would edit it; commit or stash "
                      "them first" % dirty)


def named_regex(olds):
    """The same whole-token test as an extended regular expression, for git."""
    return "(^|[^A-Za-z0-9-])(%s)([^0-9]|$)" % "|".join(re.escape(old) for old in olds)


def left_alone(root, head_commit, olds, edits):
    """["path:line"] for each committed line that names an OLD and that no edit
    rewrites: the lines that were already there."""
    done = run_git(root, "grep", "-I", "-n", "-z", "--no-color", "-E", "-e", named_regex(olds),
                   head_commit, "--")
    text = done.stdout.decode("utf-8", "surrogateescape")
    hits = re.finditer(r"%s:([^\0]+)\0(\d+)\0" % re.escape(head_commit), text)
    rewritten = {(path, number) for path, (_data, changes) in edits.items() for number, _ in changes}
    return ["%s:%s" % (hit.group(1), hit.group(2)) for hit in hits
            if (hit.group(1), int(hit.group(2))) not in rewritten]


def commits_naming(root, mb_commit, head_commit, olds):
    """["OLD abbreviated-id subject"] for each commit in MB..HEAD whose message names
    an OLD. Listed and never changed: rewriting history is the author's choice."""
    found = []
    for old in olds:
        log = git_text(root, "log", "-E", "--grep=" + named_regex([old]), "--format=%h %s",
                       "%s..%s" % (mb_commit, head_commit))
        found.extend("%s %s" % (old, line) for line in log.splitlines())
    return found


def apply_edits(root, edits, moves):
    """W3 and W4's bytes, then W1. The rename is the one thing staged."""
    for path, (data, _changes) in edits.items():
        with open(os.path.join(root, path), "wb") as handle:
            handle.write(data)
    for old_path, new_path in moves.items():
        moved = run_git(root, "mv", "--", old_path, new_path)
        if moved.returncode != 0:
            raise Refusal("git mv %s failed: %s" % (old_path, moved.stderr.decode("utf-8", "replace").strip()))


def print_plan(mapping, moves, edits, skipped, leftovers, commits):
    for old, new in mapping.items():
        print("renumber %s -> %s" % (old, new))
    for old_path, new_path in moves.items():
        print("move %s -> %s" % (old_path, new_path))
    for path, (_data, changes) in sorted(edits.items()):
        for number, found in changes:
            print("edit %s:%d: %s" % (path, number, ", ".join("%s -> %s" % (f, mapping[f]) for f in found)))
    for path, why in skipped:
        print("skipped %s: %s, and it names an id to renumber; edit it by hand" % (path, why))
    for place in leftovers:
        print("left alone %s: a line present at the merge base" % place)
    for commit in commits:
        print("commit %s: its message names the old id; reword or squash it" % commit)


def command_renumber(args):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    prefixes = document_prefixes(root)
    olds = list(dict.fromkeys(args.old))
    for old in olds:
        require_known_id(old, prefixes)
    if args.to and len(olds) != 1:
        raise Refusal("--to names one new id, so it takes exactly one OLD (%d given)" % len(olds))
    head_commit, base_commit, mb_commit = branch_commits(root, args.base)

    trees = {name: document_tree(root, commit, prefixes)
             for name, commit in (("mb", mb_commit), ("head", head_commit))}
    blobs = read_blobs(root, [sha for tree in trees.values() for sha in tree.values()])
    documents = {name: load_documents(tree, blobs) for name, tree in trees.items()}
    carrier = {old: sole_added_carrier(old, documents["mb"], documents["head"]) for old in olds}
    tips = ref_tips(root, [("HEAD", head_commit), (args.base, base_commit)])
    mapping = explicit_id(root, olds[0], args.to, tips) if args.to else allocated_ids(root, olds)

    candidates = [change for change in branch_changes(root, mb_commit, head_commit)
                  if change["status"][0] != "D" and change["mode"] in REGULAR_MODES]
    edits, skipped = plan_edits(candidates,
                                read_blobs(root, [change["sha"] for change in candidates], raw=True),
                                branch_hunks(root, mb_commit, head_commit), mapping)
    moves = {}
    for old, path in carrier.items():
        if path not in edits:
            raise Refusal("%s carries %s but could not be rewritten (%s)"
                          % (path, old, dict(skipped).get(path, "its id: line is not one HEAD added")))
        moves[path] = os.path.join(os.path.dirname(path), mapping[old] + ".yaml")
    refuse_if_dirty(root, sorted(edits))

    print_plan(mapping, moves, edits, skipped, left_alone(root, head_commit, olds, edits),
               commits_naming(root, mb_commit, head_commit, olds))
    if not args.apply:
        print("doc-ids: dry run, nothing written; add --apply to make these changes")
        return 0
    apply_edits(root, edits, moves)
    print("doc-ids: %d files edited, %d moved. Nothing is committed, and only the rename is staged "
          "(git mv). Review with `git diff HEAD`, then `git add -A` and commit." % (len(edits), len(moves)))
    return 0


# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------

def command_check(args):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    prefixes = document_prefixes(root)
    head_commit, base_commit, mb_commit = branch_commits(root, args.base)

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


COMMANDS = {"check": command_check, "renumber": command_renumber}


def build_parser():
    parser = argparse.ArgumentParser(prog="doc-ids.py", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="report id collisions between HEAD and BASE")
    check.add_argument("--base", default=DEFAULT_BASE,
                       help="the branch HEAD merges into (default %s)" % DEFAULT_BASE)
    renumber = commands.add_parser("renumber", help="give ids this branch added new numbers")
    renumber.add_argument("old", nargs="+", metavar="OLD", help="an id this branch added")
    renumber.add_argument("--to", metavar="NEW", help="the new id, for exactly one OLD")
    renumber.add_argument("--base", default=DEFAULT_BASE,
                          help="the branch HEAD merges into (default %s)" % DEFAULT_BASE)
    renumber.add_argument("--apply", action="store_true", help="write the changes (default: a dry run)")
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
