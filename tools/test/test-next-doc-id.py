#!/usr/bin/env python3
"""Check that tools/next-doc-id.sh names a real directory for every category.

BUG-0039: the table read `DEC:design'. DEC documents live in docs/decisions,
so the DEC row globbed a directory holding no DEC-nnnn, matched nothing, and
answered DEC-0001 while four decisions already existed -- the duplicate the
script's header says it exists to prevent. DES had no row at all and exited 1.

The two assertions below are the ones a stale row cannot pass: every category
the script offers resolves to a directory that exists, and every answer is one
past the highest id actually on disk for that prefix. Neither reads the table,
so a row pointing somewhere plausible but wrong fails the same way a missing
one does.

DES-0056 R4 and PLAN-0061 step 5 add the floor. Both allocators answer one past
the highest id over the working tree and over every ref under refs/heads and
refs/remotes, matched by prefix anywhere under docs/. So the first assertion
computes that floor itself, from git, and the fixtures below build repositories
where the working tree alone gives a different answer. Each fixture is asked of
tools/next-doc-id.sh and of synoptik-docstore's NEXT-DOCUMENT-ID (through
tools/test/next-id.lisp), because BUG-0039 is what two allocators that
disagree cost. The Lisp half is skipped, and says so, where sbcl is not on PATH.

Run it directly:

    tools/test/test-next-doc-id.py

Exit status is 0 when every case holds. This is not part of the FiveAM suite --
it tests a shell script, not Synoptik -- so tools/synoptik-test.sh does not run it.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
SCRIPT = os.path.join(TOOLS, "next-doc-id.sh")
DOCS = os.path.join(ROOT, "docs")

failures = []


def report(ok, message):
    if not ok:
        failures.append(message)


def run(*args):
    p = subprocess.run([SCRIPT, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def offered_categories():
    """The prefixes the usage line names, which is what a caller is told to use."""
    code, out, err = run("nonsense")
    report(code != 0, "an unknown category must exit non-zero")
    match = re.search(r"One of: (.+)", err)
    if not match:
        report(False, "the usage line does not list the categories")
        return []
    return match.group(1).split()


def git_env():
    """A fixture repository has no configuration of its own: the invoking user's
    gpg signing or hooks must not decide whether a commit succeeds, and a sandbox
    has no identity at all (PLAN-0061 risk 6)."""
    return dict(os.environ,
                GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def doc_id(name, prefix):
    """N when the file name is exactly PREFIX-nnnn.yaml, else None."""
    m = re.fullmatch(re.escape(prefix) + r"-(\d{4})\.yaml", name)
    return int(m.group(1)) if m else None


def run_git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True, env=git_env())
    if check and p.returncode != 0:
        raise RuntimeError("git %s failed in %s: %s" % (args, repo, p.stderr.decode()))
    return p.stdout


def highest_on_disk(prefix):
    """The highest nnnn among docs/**/PREFIX-nnnn.yaml, or 0, and its directory."""
    best, where = 0, None
    for directory, _dirs, files in os.walk(DOCS):
        for name in files:
            n = doc_id(name, prefix)
            if n is not None and n > best:
                best, where = n, directory
    return best, where


def highest_on_refs(prefix):
    """The same over every ref under refs/heads and refs/remotes, read with
    `git ls-tree -r -z <ref> -- docs` from the root: a different route from the
    allocators', which run from inside docs/ and name each ref by its commit."""
    best, where = 0, None
    refs = run_git(ROOT, "for-each-ref", "--format=%(refname)",
               "refs/heads", "refs/remotes").decode().split()
    for ref in refs:
        for path in run_git(ROOT, "ls-tree", "-r", "-z", "--name-only", ref, "--", "docs",
                        check=False).split(b"\0"):
            n = doc_id(os.path.basename(path.decode("utf-8", "replace")), prefix)
            if n is not None and n > best:
                best, where = n, ref
    return best, where


def floor(prefix):
    """DES-0056 R4's floor: the highest id on disk or on any ref, and where."""
    disk, disk_where = highest_on_disk(prefix)
    refs, ref_where = highest_on_refs(prefix)
    if refs > disk:
        return refs, ref_where
    return disk, os.path.relpath(disk_where, ROOT) if disk_where else None


def check_categories():
    for category in offered_categories():
        code, out, err = run(category)
        report(code == 0, "%s: exited %d (%s)" % (category, code, err))
        if code != 0:
            continue

        m = re.fullmatch(r"([A-Z]+)-(\d{4})", out)
        if not m:
            report(False, "%s: answered %r, not a PREFIX-nnnn id" % (category, out))
            continue
        prefix, answered = m.group(1), int(m.group(2))

        report(prefix == category,
               "%s: answered a %s id (%s)" % (category, prefix, out))

        highest, where = floor(category)
        report(answered == highest + 1,
               "%s: answered %s, but %s-%04d exists in %s"
               % (category, out, category, highest, where or "docs"))

        # The directory the answer came from has to be the one holding the
        # documents. A row pointing at the wrong directory answers nnnn+1 of an
        # empty set, which is what BUG-0039 did.
        report(highest > 0,
               "%s: no %s-nnnn.yaml anywhere under docs/ or on any ref, so the row "
               "names a category with no documents" % (category, category))

    # Every prefix with documents on disk must be a category the script offers.
    # The loop above can only check rows that exist, so on its own it is blind to
    # the other half of BUG-0039: DES had no row, so nothing offered it and nothing
    # tested it. This asks the tree what categories there are instead of asking the
    # script.
    offered = set(offered_categories())
    on_disk = {}
    for directory, _dirs, files in os.walk(DOCS):
        for name in files:
            m = re.fullmatch(r"([A-Z]+)-\d{4}\.yaml", name)
            if m:
                on_disk.setdefault(m.group(1), directory)

    for prefix, directory in sorted(on_disk.items()):
        report(prefix in offered,
               "%s-nnnn.yaml exists in %s but %s is not a category the script offers"
               % (prefix, os.path.relpath(directory, ROOT), prefix))


# ---------------------------------------------------------------------------
# DES-0056 R3: the table in the script is the table in transition.lisp.
# ---------------------------------------------------------------------------

def script_types():
    """The directory -> prefix pairs of the script's types= line."""
    with open(SCRIPT) as f:
        m = re.search(r'^types="([^"]+)"', f.read(), re.M)
    if not m:
        report(False, "next-doc-id.sh has no types= line")
        return {}
    pairs = [pair.split(":") for pair in m.group(1).split()]
    if any(len(p) != 2 for p in pairs):
        report(False, "a types= entry is not PREFIX:directory: %r" % m.group(1))
        return {}
    return {directory: prefix for prefix, directory in pairs}


def lisp_types():
    """*DOCUMENT-ID-PREFIXES* read from transition.lisp's text, not loaded."""
    with open(os.path.join(ROOT, "src", "workspace", "transition.lisp")) as f:
        text = f.read()
    start = text.index("(defparameter *document-id-prefixes*")
    form = text[start:text.index('"Document category', start)]
    return dict(re.findall(r'\("([a-z]+)" \. "([A-Z]+)"\)', form))


def check_types_agree():
    report(script_types() == lisp_types() != {},
           "the types= line of next-doc-id.sh is %r but *DOCUMENT-ID-PREFIXES* is %r"
           % (script_types(), lisp_types()))


# ---------------------------------------------------------------------------
# Fixture repositories: both allocators, one answer.
# ---------------------------------------------------------------------------

def have_sbcl():
    return shutil.which("sbcl") is not None


def write(repo, relative, text="id: x\n"):
    path = os.path.join(repo, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def commit(repo, relative, message=None):
    write(repo, relative)
    run_git(repo, "add", "-A", "docs")
    run_git(repo, "commit", "-q", "-m", message or relative)


def make_repo(parent, name, git_repo=True):
    """A fixture tree with the script in its own tools/, as a fork carries it:
    the script finds its root from its location."""
    repo = os.path.join(parent, name)
    os.makedirs(os.path.join(repo, "tools"))
    shutil.copy(SCRIPT, os.path.join(repo, "tools", "next-doc-id.sh"))
    if git_repo:
        run_git(repo, "init", "-q", "-b", "main")
    return repo


def script_answer(repo, category):
    p = subprocess.run([os.path.join(repo, "tools", "next-doc-id.sh"), category],
                       capture_output=True, text=True, env=git_env())
    return p.stdout.strip() if p.returncode == 0 else "exit %d: %s" % (p.returncode, p.stderr.strip())


def lisp_answer(repo, directory, prefix):
    p = subprocess.run(["sbcl", "--script", os.path.join(TOOLS, "test", "next-id.lisp"),
                        os.path.join(repo, "docs", directory) + "/", prefix],
                       capture_output=True, text=True, env=git_env())
    return p.stdout.strip() if p.returncode == 0 else "exit %d: %s" % (p.returncode, p.stderr.strip()[-300:])


def both(label, repo, category, directory, expected):
    got = script_answer(repo, category)
    report(got == expected, "%s: next-doc-id.sh answered %s, expected %s" % (label, got, expected))
    if have_sbcl():
        got = lisp_answer(repo, directory, category)
        report(got == expected, "%s: NEXT-DOCUMENT-ID answered %s, expected %s" % (label, got, expected))


def check_fixtures():
    if not have_sbcl():
        print("skipped: sbcl is not on PATH, so NEXT-DOCUMENT-ID is not compared.")
    with tempfile.TemporaryDirectory(prefix="next-doc-id-") as tmp:
        # main holds REQ-0001, branch b adds REQ-0005, main is checked out: the
        # working tree alone says REQ-0002, which b's author would also be handed.
        repo = make_repo(tmp, "branched")
        commit(repo, "docs/requirements/REQ-0001.yaml")
        commit(repo, "docs/decisions/DEC-0003.yaml")
        run_git(repo, "checkout", "-q", "-b", "b")
        commit(repo, "docs/requirements/REQ-0005.yaml")
        run_git(repo, "checkout", "-q", "main")
        report(not os.path.exists(os.path.join(repo, "docs/requirements/REQ-0005.yaml")),
               "fixture: REQ-0005 must be off the working tree")
        both("branch b adds REQ-0005, main out", repo, "REQ", "requirements", "REQ-0006")

        # No remote above. A detached HEAD still reads the branches.
        run_git(repo, "checkout", "-q", "--detach", "HEAD")
        both("detached HEAD", repo, "REQ", "requirements", "REQ-0006")
        run_git(repo, "checkout", "-q", "main")

        # A DEC filed under docs/design/ on a branch, as before BUG-0039: matched
        # by prefix anywhere under docs/, not by the category directory.
        run_git(repo, "checkout", "-q", "-b", "old")
        commit(repo, "docs/design/DEC-0050.yaml")
        run_git(repo, "checkout", "-q", "main")
        both("DEC-0050 under docs/design on a branch", repo, "DEC", "decisions", "DEC-0051")

        # A shallow clone has the tips of every branch as remote-tracking refs and
        # nothing of their history.
        clone = os.path.join(tmp, "shallow")
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--no-single-branch",
                        "file://" + repo, clone], check=True, env=git_env(), capture_output=True)
        os.makedirs(os.path.join(clone, "tools"))
        shutil.copy(SCRIPT, os.path.join(clone, "tools", "next-doc-id.sh"))
        run_git(clone, "branch", "-D", "b", check=False)
        both("shallow clone, ids on refs/remotes/origin only", clone, "REQ", "requirements", "REQ-0006")

        # A directory git does not hold uses the working tree alone.
        plain = make_repo(tmp, "plain", git_repo=False)
        write(plain, "docs/requirements/REQ-0001.yaml")
        both("a directory that is not a repository", plain, "REQ", "requirements", "REQ-0002")

        # A repository with no commit has refs for nothing to enumerate.
        bare_init = make_repo(tmp, "unborn")
        write(bare_init, "docs/requirements/REQ-0001.yaml")
        both("a repository with no commit", bare_init, "REQ", "requirements", "REQ-0002")

        # A backup and a lock never match, on disk or on a ref.
        editor = make_repo(tmp, "editor")
        commit(editor, "docs/requirements/REQ-0001.yaml")
        run_git(editor, "checkout", "-q", "-b", "b")
        commit(editor, "docs/requirements/REQ-0007.yaml~")
        commit(editor, "docs/requirements/REQ-0008.yaml.orig")
        run_git(editor, "checkout", "-q", "main")
        write(editor, "docs/requirements/REQ-0009.yaml~")
        os.symlink("user@host.1234:1700000000",
                   os.path.join(editor, "docs/requirements/.#REQ-0010.yaml"))
        both("a backup and a lock on disk and on a ref", editor, "REQ", "requirements", "REQ-0002")

        # Unusual bytes in a ref name and in a directory name. git quotes the
        # directory in plain output, and the allocator must see the id below it.
        odd = make_repo(tmp, "odd")
        commit(odd, "docs/requirements/REQ-0001.yaml")
        run_git(odd, "checkout", "-q", "-b", "fé/ü#1@x")
        commit(odd, "docs/café déjà/REQ-0007.yaml")
        run_git(odd, "checkout", "-q", "main")
        both("a ref and a directory with non-ASCII names", odd, "REQ", "requirements", "REQ-0008")


def main():
    check_categories()
    check_types_agree()
    check_fixtures()

    if failures:
        for f in failures:
            print("FAIL: %s" % f)
        print("\n%d of %d checks failed." % (len(failures), len(failures)))
        sys.exit(1)

    print("next-doc-id.sh: every offered category resolves and answers the highest id on disk or on any ref, plus 1.")


if __name__ == "__main__":
    main()
