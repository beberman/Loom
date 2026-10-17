#!/usr/bin/env python3
"""Check that tools/doc-ids.py check reports each document-id collision and only those.

DES-0056 R1 and PLAN-0061 step 6. Each case builds a bare upstream repository and
the clones a maintainer and a contributor would work in, under a temporary
directory, then runs the script that sits in the clone's own tools/ (finding 21:
tools/next-doc-id.sh finds its root from its own location, so a fixture carries
its own copies, as a fork does). Nothing here touches this repository's refs.

The first case is a branch that collides with nothing, so a fixture that is wrong
everywhere shows up as one failure in the clean cases and one in every other, not
as a pass. Then one case per check, each asserting exit 1 and the exact set of
checks that fire:

  C1  a branch adds REQ-0002, and main gains REQ-0002 after the branch point
  C2  a branch copies DES-0001.yaml into completed/ without removing it
  C3  a file REQ-0003.yaml whose id: is REQ-0002, with no other carrier
  C4  a refines: that names nothing, in the three list shapes a document uses
  C5  main adds REQ-0004 after the branch point; the branch adds a line naming it

and the cases around them: the kept-both resolution of an add/add conflict, a
file only the working tree holds, a base that does not exist, and the table of
categories being read from next-doc-id.sh rather than written into the script.

`renumber` (DES-0056 R2, PLAN-0061 step 7) is covered after them. The acceptance
case is REQ-0079's: two clones of one bare upstream each allocate REQ-0002 with
their own tools/next-doc-id.sh, one pushes, the other's `check` fails on C1, and
`renumber --apply` makes `check` pass and the merge clean. Around it: a one-clone
case (R8), each refusal as its own case asserting that nothing was written, a
document in completed/, byte exactness (CRLF, no final newline, non-UTF-8, binary,
a form feed, a rename), two OLDs of one category, and a second run.

Run it directly:

    tools/test/test-doc-ids.py [path/to/a/copy/of/doc-ids.py]

The optional argument names the script under test. That is how CON-0003's
mutations are run: a copy of the script with one check disabled must fail
exactly its own case, and nothing here edits tools/doc-ids.py to find out.

Exit status is 0 when every case holds. Like test-next-doc-id.py it tests a
script, not Synoptik, so tools/synoptik-test.sh does not run it.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

failures = []
under_test = []


def tools_dir():
    """tools/ of this checkout. A function, not a constant: a module-level call is
    a :CALL-SITE entity, and *PYTHON-CALL-SITE-CEILING* counts them."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def report(ok, message):
    if not ok:
        failures.append(message)


def script_path():
    return under_test[0] if under_test else os.path.join(tools_dir(), "doc-ids.py")


# ---------------------------------------------------------------------------
# git, and a fixture world
# ---------------------------------------------------------------------------

def git_env():
    """A fixture has no configuration of its own: the invoking user's gpg signing,
    hooks or default branch must not decide whether a commit succeeds, and a
    sandbox has no identity at all (PLAN-0061 risk 6)."""
    return dict(os.environ,
                GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")


def git_in(repo, *args, check=True):
    done = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=git_env())
    if check and done.returncode != 0:
        raise RuntimeError("git %s failed in %s: %s" % (" ".join(args), repo, done.stderr))
    return done.stdout


def put_file(repo, relative, text):
    path = os.path.join(repo, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def commit_all(repo, message):
    git_in(repo, "add", "-A")
    git_in(repo, "commit", "-q", "-m", message)


def doc_text(id_, refines="[]", extra=""):
    return "id: %s\ntitle: %s\nstatus: draft\nrefines: %s\n%s" % (id_, id_, refines, extra)


def seed_files():
    """The documents every world starts from. BUG-0001 names a document that
    exists nowhere, as a tree may already: the check is about what a branch
    changes, not about what was there before it."""
    return {
        "docs/requirements/REQ-0001.yaml": doc_text("REQ-0001"),
        "docs/design/DES-0001.yaml": doc_text("DES-0001", "[REQ-0001]"),
        "docs/plans/PLAN-0001.yaml": doc_text("PLAN-0001", "[DES-0001]"),
        "docs/bugs/BUG-0001.yaml": doc_text("BUG-0001", "[REQ-0098]"),
        "README.md": "# fixture\nREQ-0004 is only an example id.\n",
    }


def install_tools(repo, categories=None):
    """The script under test and the real allocator, as a fork carries them. A
    CATEGORIES string replaces the allocator's types= line."""
    os.makedirs(os.path.join(repo, "tools"), exist_ok=True)
    shutil.copy(script_path(), os.path.join(repo, "tools", "doc-ids.py"))
    with open(os.path.join(tools_dir(), "next-doc-id.sh"), encoding="utf-8") as handle:
        text = handle.read()
    if categories:
        text = re.sub(r'^types="[^"]*"', 'types="%s"' % categories, text, flags=re.M)
    put_file(repo, "tools/next-doc-id.sh", text)


def build_world(tmp, name, categories=None):
    """(upstream, maintainer, contributor): a bare repository holding main with the
    seed documents, a clone that publishes to it, and a clone on branch `feature`."""
    base = os.path.join(tmp, name)
    upstream, maintainer, contributor = (os.path.join(base, d)
                                         for d in ("upstream.git", "maintainer", "contributor"))
    os.makedirs(base)
    git_in(base, "init", "-q", "--bare", "-b", "main", upstream)
    git_in(base, "clone", "-q", upstream, maintainer)
    for relative, text in seed_files().items():
        put_file(maintainer, relative, text)
    install_tools(maintainer, categories)
    commit_all(maintainer, "seed")
    git_in(maintainer, "push", "-q", "origin", "HEAD:main")
    git_in(base, "clone", "-q", upstream, contributor)
    git_in(contributor, "checkout", "-q", "-b", "feature")
    return upstream, maintainer, contributor


def publish(maintainer, files, message="main moves on"):
    """Commit FILES on the maintainer's main, push, and let nobody else know."""
    for relative, text in files.items():
        put_file(maintainer, relative, text)
    commit_all(maintainer, message)
    git_in(maintainer, "push", "-q", "origin", "HEAD:main")


def check_in(repo, *args):
    """(exit code, stdout, stderr) of the clone's own doc-ids.py check, run from
    outside the clone: the script finds its repository from its own location."""
    done = subprocess.run([sys.executable, os.path.join(repo, "tools", "doc-ids.py"), "check", *args],
                          capture_output=True, text=True, env=git_env(), cwd=os.path.dirname(repo))
    return done.returncode, done.stdout, done.stderr


def fired(stdout):
    """The checks that printed a failure line, as C1..C5 in order, once each."""
    return sorted(set(re.findall(r"^(C\d) ", stdout, re.M)))


def expect(label, result, code, checks, needles=()):
    got_code, out, err = result
    shown = (out + err).strip()
    report(got_code == code, "%s: exit %d, expected %d.\n%s" % (label, got_code, code, shown))
    report(fired(out) == list(checks), "%s: checks fired %s, expected %s.\n%s"
           % (label, fired(out), list(checks), shown))
    for needle in needles:
        report(needle in out, "%s: output lacks %r.\n%s" % (label, needle, shown))
    report("Traceback" not in err, "%s: a traceback.\n%s" % (label, err))


def snapshot(repo):
    """Everything a check could have written: git's view of the tree, HEAD, and
    every file's size and mtime outside .git."""
    files = []
    for directory, dirs, names in os.walk(repo):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in names:
            stat = os.stat(os.path.join(directory, name))
            files.append((os.path.join(directory, name), stat.st_size, stat.st_mtime_ns))
    return (git_in(repo, "status", "--porcelain"), git_in(repo, "rev-parse", "HEAD"),
            git_in(repo, "for-each-ref"), sorted(files))


# ---------------------------------------------------------------------------
# The clean cases, first
# ---------------------------------------------------------------------------

def case_clean_branch(tmp):
    """A branch that adds a document while main adds an unrelated one."""
    _up, maintainer, work = build_world(tmp, "clean")
    publish(maintainer, {"docs/decisions/DEC-0002.yaml": doc_text("DEC-0002")})
    put_file(work, "docs/requirements/REQ-0002.yaml", doc_text("REQ-0002", "[REQ-0001]"))
    put_file(work, "docs/design/DES-0002.yaml", doc_text("DES-0002", "[REQ-0002]"))
    commit_all(work, "feature")
    git_in(work, "fetch", "-q", "origin")
    before = snapshot(work)
    result = check_in(work)
    expect("clean: a branch and a main that moved apart", result, 0, [], ["doc-ids: ok"])
    report(snapshot(work) == before, "clean: the check changed the clone")


def case_clean_head_is_base(tmp):
    """HEAD equal to BASE, and HEAD behind BASE: nothing diverges."""
    _up, maintainer, work = build_world(tmp, "same")
    git_in(work, "checkout", "-q", "main")
    expect("clean: HEAD is BASE", check_in(work), 0, [], ["doc-ids: ok"])
    publish(maintainer, {"docs/requirements/REQ-0002.yaml": doc_text("REQ-0002")})
    git_in(work, "fetch", "-q", "origin")
    expect("clean: HEAD is an ancestor of BASE", check_in(work), 0, [])


def case_clean_moves(tmp):
    """A document moved into completed/ is one document, whichever side moved it."""
    _up, maintainer, work = build_world(tmp, "moves")
    os.makedirs(os.path.join(work, "docs/design/completed"))
    git_in(work, "mv", "docs/design/DES-0001.yaml", "docs/design/completed/DES-0001.yaml")
    commit_all(work, "complete DES-0001")
    expect("clean: the branch moves a document into completed/", check_in(work), 0, [])

    # Main completes PLAN-0001 while the branch edits it where it was.
    os.makedirs(os.path.join(maintainer, "docs/plans/completed"))
    git_in(maintainer, "mv", "docs/plans/PLAN-0001.yaml", "docs/plans/completed/PLAN-0001.yaml")
    commit_all(maintainer, "complete PLAN-0001")
    git_in(maintainer, "push", "-q", "origin", "HEAD:main")
    put_file(work, "docs/plans/PLAN-0001.yaml", doc_text("PLAN-0001", "[DES-0001]", "tags: [edited]\n"))
    commit_all(work, "edit PLAN-0001 in place")
    git_in(work, "fetch", "-q", "origin")
    expect("clean: main moves a document the branch edits", check_in(work), 0, [])


def case_clean_forms(tmp):
    """Every way a refines: or an id: is written, all resolving: a quoted id, a
    one-line list, a list over two and three lines, a block list indented and at
    the key's own column, a bare scalar, a comment, an empty list, supersedes."""
    _up, _maintainer, work = build_world(tmp, "forms")
    files = {
        "docs/requirements/REQ-0002.yaml": 'id: "REQ-0002"\nrefines: []\n',
        "docs/requirements/REQ-0003.yaml": "id: 'REQ-0003'   # quoted\nrefines: [\"REQ-0001\", 'REQ-0002']\n",
        "docs/design/DES-0002.yaml": "id: DES-0002\nrefines:\n  - REQ-0002\n  - REQ-0003  # both\nstatus: draft\n",
        "docs/design/DES-0003.yaml": "id: DES-0003\nrefines: [REQ-0001,\n   REQ-0002]\nsupersedes: [DES-0001]\n",
        "docs/design/DES-0004.yaml": "id: DES-0004\nrefines: [\n  REQ-0001,\n  REQ-0003,\n]\n",
        "docs/design/DES-0005.yaml": "id: DES-0005\nrefines:\n- DES-0002\n- DES-0003\ntitle: dashes at the key's column\n",
        "docs/plans/PLAN-0002.yaml": "id: PLAN-0002\nrefines: DES-0002   # one scalar\n",
        "docs/plans/PLAN-0003.yaml": "id: PLAN-0003\nrefines: ~\nsummary: |\n  id: PLAN-0099\n  refines: [REQ-0099]\n",
    }
    for relative, text in files.items():
        put_file(work, relative, text)
    commit_all(work, "every list shape")
    expect("clean: every shape of id: and refines:", check_in(work), 0, [], ["doc-ids: ok"])


def case_untracked_is_not_read(tmp):
    """A file git does not hold at HEAD cannot fail a check: untracked, staged
    only, or edited in the working tree."""
    _up, _maintainer, work = build_world(tmp, "untracked")
    put_file(work, "docs/requirements/REQ-0003.yaml", doc_text("REQ-0009", "[REQ-0099]"))
    put_file(work, "docs/plans/PLAN-0004.yaml", "title: no id\n")
    put_file(work, "docs/design/DES-0006.yaml", doc_text("DES-0001"))
    git_in(work, "add", "docs/design/DES-0006.yaml")
    put_file(work, "docs/requirements/REQ-0001.yaml", doc_text("REQ-0777", "[REQ-0099]"))
    expect("untracked, staged and edited files are not read", check_in(work), 0, [], ["doc-ids: ok"])


# ---------------------------------------------------------------------------
# One case per check
# ---------------------------------------------------------------------------

def case_c1(tmp):
    """The branch and main each take the next id."""
    _up, maintainer, work = build_world(tmp, "c1")
    put_file(work, "docs/requirements/REQ-0002.yaml", doc_text("REQ-0002", "[REQ-0001]"))
    commit_all(work, "feature allocates REQ-0002")
    publish(maintainer, {"docs/requirements/REQ-0002.yaml": doc_text("REQ-0002", "[REQ-0001]", "tags: [main]\n")})
    git_in(maintainer, "push", "-q", "origin", "HEAD:refs/heads/release")
    git_in(work, "fetch", "-q", "origin")
    before = snapshot(work)
    result = check_in(work)
    expect("C1: both take REQ-0002", result, 1, ["C1"],
           ["C1 REQ-0002:", "tools/doc-ids.py renumber REQ-0002\n"])
    report(len([l for l in result[1].splitlines() if l.startswith("C1 ")]) == 1,
           "C1: not one line for one collision.\n" + result[1])
    report(snapshot(work) == before, "C1: the check changed the clone")
    expect("C1: a base that is not the default is in the command",
           check_in(work, "--base", "origin/release"), 1, ["C1"],
           ["renumber REQ-0002 --base origin/release"])

    # A branch reset to main has nothing of its own left to collide.
    git_in(work, "reset", "-q", "--hard", "origin/main")
    expect("C1: a branch that is main", check_in(work), 0, [])


def case_c1_same_document(tmp):
    """The same document on both sides (a cherry-pick, a branch main squashed) is
    one document, not a collision."""
    _up, maintainer, work = build_world(tmp, "c1same")
    text = doc_text("REQ-0002", "[REQ-0001]")
    put_file(work, "docs/requirements/REQ-0002.yaml", text)
    commit_all(work, "feature allocates REQ-0002")
    publish(maintainer, {"docs/requirements/REQ-0002.yaml": text})
    git_in(work, "fetch", "-q", "origin")
    expect("C1: the same document in both", check_in(work), 0, [])


def case_c2(tmp):
    """A document copied into completed/ and not removed."""
    _up, _maintainer, work = build_world(tmp, "c2")
    shutil.copy(os.path.join(work, "docs/design/DES-0001.yaml"),
                os.path.join(work, "docs/design/DES-0001.copy"))
    os.makedirs(os.path.join(work, "docs/design/completed"))
    os.rename(os.path.join(work, "docs/design/DES-0001.copy"),
              os.path.join(work, "docs/design/completed/DES-0001.yaml"))
    commit_all(work, "copy, not move")
    expect("C2: DES-0001 on two paths", check_in(work), 1, ["C2"],
           ["C2 DES-0001:", "docs/design/DES-0001.yaml", "docs/design/completed/DES-0001.yaml"])


def case_c2_across_the_merge(tmp):
    """Each side holds one path, and the merge of them would hold two: main added
    DES-0002 at one path and the branch at another, under one id."""
    _up, maintainer, work = build_world(tmp, "c2merge")
    put_file(work, "docs/design/completed/DES-0002.yaml", doc_text("DES-0002"))
    commit_all(work, "feature")
    publish(maintainer, {"docs/design/DES-0002.yaml": doc_text("DES-0002")})
    git_in(work, "fetch", "-q", "origin")
    result = check_in(work)
    expect("C2: the merge would hold DES-0002 twice", result, 1, ["C1", "C2"], ["C2 DES-0002:"])
    report("the merge of BASE and HEAD" in result[1], "C2: the line does not say it is the merge\n" + result[1])


def case_c3(tmp):
    """A file whose name and id: disagree, and a file with no id: at all."""
    _up, _maintainer, work = build_world(tmp, "c3")
    put_file(work, "docs/requirements/REQ-0003.yaml", doc_text("REQ-0002"))
    commit_all(work, "kept both, and the id never changed")
    expect("C3: REQ-0003.yaml says REQ-0002", check_in(work), 1, ["C3"],
           ["C3 docs/requirements/REQ-0003.yaml:", "REQ-0002"])
    put_file(work, "docs/requirements/REQ-0004.yaml", "title: no id here\n")
    commit_all(work, "no id")
    result = check_in(work)
    expect("C3: a document with no id:", result, 1, ["C3"], ["REQ-0004.yaml: has no id: line"])


def case_c3_kept_both(tmp):
    """The add/add conflict GitHub blocks, resolved by keeping both files under
    different names. main's REQ-0002.yaml stays; the branch's goes to REQ-0003.yaml
    and its id: is never changed."""
    _up, maintainer, work = build_world(tmp, "keptboth")
    put_file(work, "docs/requirements/REQ-0002.yaml", doc_text("REQ-0002", "[REQ-0001]", "tags: [branch]\n"))
    commit_all(work, "feature allocates REQ-0002")
    publish(maintainer, {"docs/requirements/REQ-0002.yaml": doc_text("REQ-0002", "[REQ-0001]", "tags: [main]\n")})
    git_in(work, "fetch", "-q", "origin")
    merge = subprocess.run(["git", "-C", work, "merge", "-q", "--no-edit", "origin/main"],
                           capture_output=True, text=True, env=git_env())
    report(merge.returncode != 0, "kept-both: the fixture did not conflict add/add")
    ours = git_in(work, "show", "HEAD:docs/requirements/REQ-0002.yaml")
    put_file(work, "docs/requirements/REQ-0003.yaml", ours)
    put_file(work, "docs/requirements/REQ-0002.yaml", git_in(work, "show", "origin/main:docs/requirements/REQ-0002.yaml"))
    git_in(work, "add", "-A")
    git_in(work, "commit", "-q", "-m", "keep both")
    expect("C3: kept both, one renamed", check_in(work), 1, ["C2", "C3"],
           ["C2 REQ-0002:", "C3 docs/requirements/REQ-0003.yaml:"])


def case_c4(tmp):
    """An entry that names nothing: one-line, over two lines (the dangling entry
    first and last), as a block list, and in supersedes. A document nobody
    touched may keep its dangling reference (BUG-0001 in the seed)."""
    _up, _maintainer, work = build_world(tmp, "c4")
    files = {
        "docs/design/DES-0002.yaml": doc_text("DES-0002", "[REQ-0099]"),
        "docs/design/DES-0003.yaml": doc_text("DES-0003", "[REQ-0001,\n   REQ-0098]"),
        "docs/design/DES-0004.yaml": doc_text("DES-0004", "[REQ-0097,\n   REQ-0001]"),
        "docs/design/DES-0005.yaml": doc_text("DES-0005", "\n  - REQ-0001\n  - REQ-0096\n"),
        "docs/design/DES-0006.yaml": doc_text("DES-0006", "[REQ-0001]", "supersedes: [DES-0095]\n"),
    }
    for relative, text in files.items():
        put_file(work, relative, text)
    commit_all(work, "dangling references")
    result = check_in(work)
    expect("C4: entries that name nothing", result, 1, ["C4"])
    lines = [l for l in result[1].splitlines() if l.startswith("C4 ")]
    wanted = {"DES-0002": "REQ-0099", "DES-0003": "REQ-0098", "DES-0004": "REQ-0097",
              "DES-0005": "REQ-0096", "DES-0006": "DES-0095"}
    for doc, dangling in wanted.items():
        mine = [l for l in lines if "%s.yaml" % doc in l]
        report(len(mine) == 1 and dangling in mine[0] and "names no document" in mine[0],
               "C4: %s should have exactly one line naming %s: %s" % (doc, dangling, mine))
    report(len(lines) == len(wanted), "C4: %d lines for %d dangling entries.\n%s"
           % (len(lines), len(wanted), result[1]))
    report(not any("REQ-0001 names" in l for l in lines), "C4: a resolving entry was reported")
    report(not any("BUG-0001" in l for l in lines), "C4: an untouched document was reported")

    # Editing the document that was already dangling makes it the branch's.
    put_file(work, "docs/bugs/BUG-0001.yaml", doc_text("BUG-0001", "[REQ-0098]", "tags: [touched]\n"))
    commit_all(work, "touch BUG-0001")
    report(any("BUG-0001" in l for l in check_in(work)[1].splitlines()),
           "C4: a modified document's dangling entry was not reported")


def case_c4_ambiguous(tmp):
    """An entry that names two documents because one id sits on two paths."""
    _up, _maintainer, work = build_world(tmp, "c4amb")
    os.makedirs(os.path.join(work, "docs/design/completed"))
    shutil.copy(os.path.join(work, "docs/design/DES-0001.yaml"),
                os.path.join(work, "docs/design/completed/DES-0001.yaml"))
    put_file(work, "docs/plans/PLAN-0002.yaml", doc_text("PLAN-0002", "[DES-0001]"))
    commit_all(work, "refine an id on two paths")
    expect("C4: an entry naming two documents", check_in(work), 1, ["C2", "C4"],
           ["C4 docs/plans/PLAN-0002.yaml: refines DES-0001 names 2 documents"])


def case_c5(tmp):
    """The branch cannot have seen the document main added, and names it anyway."""
    _up, maintainer, work = build_world(tmp, "c5")
    put_file(work, "README.md", "# fixture\nREQ-0004 is only an example id.\n"
             "see REQ-0004 for the design\nREQ-00045 is another id\nX-REQ-0004 is another\n")
    put_file(work, "src/a.lisp", "++ see REQ-0004 (an added line that begins ++)\n")
    commit_all(work, "name REQ-0004")
    publish(maintainer, {"docs/requirements/REQ-0004.yaml": doc_text("REQ-0004")})
    git_in(work, "fetch", "-q", "origin")
    result = check_in(work)
    expect("C5: a line names an id main added", result, 1, ["C5"],
           ["C5 README.md:3: names REQ-0004", "C5 src/a.lisp:1: names REQ-0004"])
    report(len([l for l in result[1].splitlines() if l.startswith("C5 ")]) == 2,
           "C5: whole-token matching and unchanged lines must leave two lines.\n" + result[1])

    # Merged, the branch has seen the document.
    git_in(work, "merge", "-q", "--no-edit", "origin/main")
    expect("C5: after the branch carries it", check_in(work), 0, [])


# ---------------------------------------------------------------------------
# Refusals, and where the categories come from
# ---------------------------------------------------------------------------

def case_refusals(tmp):
    _up, _maintainer, work = build_world(tmp, "refuse")
    code, out, err = check_in(work, "--base", "origin/nowhere")
    report(code == 1 and "origin/nowhere" in err and len(err.strip().splitlines()) == 1
           and "Traceback" not in err and out == "",
           "a missing base: exit %d, stdout %r, stderr %r" % (code, out, err))

    git_in(work, "checkout", "-q", "--orphan", "unrelated")
    put_file(work, "docs/requirements/REQ-0001.yaml", doc_text("REQ-0001"))
    commit_all(work, "an unrelated history")
    code, out, err = check_in(work)
    report(code == 1 and "fetch-depth" in err and "Traceback" not in err,
           "no merge base: exit %d, stdout %r, stderr %r" % (code, out, err))

    bare = os.path.join(tmp, "nothing")
    install_tools(bare)
    code, out, err = check_in(bare)
    report(code == 1 and "Traceback" not in err and len(err.strip().splitlines()) == 1,
           "not a repository: exit %d, stderr %r" % (code, err))

    unborn = os.path.join(tmp, "unborn")
    install_tools(unborn)
    git_in(unborn, "init", "-q", "-b", "main")
    code, out, err = check_in(unborn)
    report(code == 1 and "Traceback" not in err and len(err.strip().splitlines()) == 1,
           "no commit: exit %d, stderr %r" % (code, err))


def case_categories_come_from_the_allocator(tmp):
    """A category added to next-doc-id.sh's types= line is a category here, with
    no edit to doc-ids.py (DES-0056 R3)."""
    _up, _maintainer, work = build_world(tmp, "zzz", categories="REQ:requirements ZZZ:zzz")
    put_file(work, "docs/zzz/ZZZ-0002.yaml", doc_text("ZZZ-0001"))
    commit_all(work, "a category the script was not written for")
    expect("a ZZZ document is checked", check_in(work), 1, ["C3"], ["ZZZ-0002.yaml"])

    plain = build_world(tmp, "nozzz")[2]
    put_file(plain, "docs/zzz/ZZZ-0002.yaml", doc_text("ZZZ-0001"))
    commit_all(plain, "the same file, no such category")
    expect("a ZZZ document is not a document without the row", check_in(plain), 0, [])


def load_script():
    sys.dont_write_bytecode = True    # a .pyc beside the script is a write into the tree
    spec = importlib.util.spec_from_file_location("doc_ids_under_test", script_path())
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def lisp_prefixes():
    """*DOCUMENT-ID-PREFIXES*' prefixes, read from transition.lisp's text."""
    with open(os.path.join(os.path.dirname(tools_dir()), "src", "workspace", "transition.lisp"), encoding="utf-8") as handle:
        text = handle.read()
    start = text.index("(defparameter *document-id-prefixes*")
    form = text[start:text.index('"Document category', start)]
    return sorted(prefix for _directory, prefix in re.findall(r'\("([a-z]+)" \. "([A-Z]+)"\)', form))


def case_types_line(tmp):
    """The prefixes the script reads are the allocator's types= line, and that is
    *DOCUMENT-ID-PREFIXES* in transition.lisp."""
    script = load_script()
    got = sorted(script.document_prefixes(os.path.dirname(tools_dir())))
    report(got == lisp_prefixes() and len(got) == 9,
           "document_prefixes read %s, but *DOCUMENT-ID-PREFIXES* is %s" % (got, lisp_prefixes()))
    lonely = os.path.join(tmp, "lonely")
    os.makedirs(os.path.join(lonely, "tools"))
    put_file(lonely, "tools/next-doc-id.sh", "#!/bin/bash\necho no table\n")
    try:
        script.document_prefixes(lonely)
        report(False, "a script with no types= line was accepted")
    except script.Refusal as refusal:
        report("types=" in str(refusal), "the refusal does not name types=: %s" % refusal)


def case_reading(tmp):
    """read_document on the shapes a refines: or an id: takes."""
    script = load_script()
    table = [
        ("id: REQ-0001\nrefines: [A-0001, B-0002]\n", "REQ-0001", ["A-0001", "B-0002"], []),
        ('id: "REQ-0001"\n', "REQ-0001", [], []),
        ("id: 'REQ-0001' # c\n", "REQ-0001", [], []),
        ("refines: []\n", None, [], []),
        ("refines: [A-0001,\n  B-0002]\nsupersedes: [C-0003]\n", None, ["A-0001", "B-0002"], ["C-0003"]),
        ("refines: [\n  A-0001,\n  B-0002,\n]\nid: X-0001\n", "X-0001", ["A-0001", "B-0002"], []),
        ("refines:\n  - A-0001\n  - B-0002 # c\n\n  # note\n  - 'C-0003'\nstatus: x\n", None,
         ["A-0001", "B-0002", "C-0003"], []),
        ("refines:\n- A-0001\n- B-0002\ntitle: t\n", None, ["A-0001", "B-0002"], []),
        ("refines: A-0001\n", None, ["A-0001"], []),
        ("refines: null\n", None, [], []),
        ("refines:\nstatus: draft\n", None, [], []),
        ("summary: |\n  id: NO-0001\n  refines: [NO-0002]\n", None, [], []),
        ("supersedes:\n  - D-0001\n", None, [], ["D-0001"]),
    ]
    for text, id_, refines, supersedes in table:
        got = script.read_document(text)
        report((got["id"], got["refines"], got["supersedes"]) == (id_, refines, supersedes),
               "read_document(%r) = %r, expected %r" % (text, got, (id_, refines, supersedes)))


# ---------------------------------------------------------------------------
# renumber
# ---------------------------------------------------------------------------

timings = {}


def renumber_in(repo, *args):
    """(exit code, stdout, stderr) of the clone's own doc-ids.py renumber, from
    outside the clone."""
    done = subprocess.run([sys.executable, os.path.join(repo, "tools", "doc-ids.py"), "renumber", *args],
                          capture_output=True, text=True, env=git_env(), cwd=os.path.dirname(repo))
    return done.returncode, done.stdout, done.stderr


def allocate_in(repo, category):
    """What the clone's own tools/next-doc-id.sh answers."""
    done = subprocess.run(["bash", os.path.join(repo, "tools", "next-doc-id.sh"), category],
                          capture_output=True, text=True, env=git_env(), cwd=os.path.dirname(repo))
    return done.stdout.strip()


def read_bytes(repo, relative):
    with open(os.path.join(repo, relative), "rb") as handle:
        return handle.read()


def put_bytes(repo, relative, data):
    path = os.path.join(repo, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)


def frozen(repo):
    """Everything a refused or dry-run renumber could have changed: git's view, HEAD,
    refs, size and mtime of every file, the bytes of every file, the commit messages
    and the index."""
    contents = {}
    for directory, dirs, names in os.walk(repo):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in names:
            contents[os.path.join(directory, name)] = read_bytes(directory, name)
    return (snapshot(repo), contents, git_in(repo, "log", "--format=%H %B"), git_in(repo, "diff", "--cached"))


def expect_refused(label, repo, args, needle):
    """Exit 1, one sentence on stderr naming NEEDLE, nothing on stdout, and nothing
    written."""
    before = frozen(repo)
    code, out, err = renumber_in(repo, *args)
    report(code == 1, "%s: exit %d, expected 1.\n%s%s" % (label, code, out, err))
    report(len(err.strip().splitlines()) == 1 and needle in err and "Traceback" not in err,
           "%s: stderr %r should be one sentence naming %r" % (label, err, needle))
    report(out == "", "%s: stdout %r" % (label, out))
    report(frozen(repo) == before, "%s: renumber wrote something" % label)


def world_with(tmp, name, files):
    """build_world, with FILES already on main when the branch begins."""
    upstream, maintainer, work = build_world(tmp, name)
    publish(maintainer, files, "pre-existing files")
    git_in(work, "fetch", "-q", "origin")
    git_in(work, "reset", "-q", "--hard", "origin/main")
    return upstream, maintainer, work


NOTES = "keep REQ-0002 here\nmid\nsecond: REQ-0002 stays\n"


def branch_adds(repo, new_id, code_file, notes_file, message):
    """What a branch that implements NEW_ID commits: its document, a code file naming
    it, and a line added to a pre-existing file whose own lines also name it. The
    added line repeats the text of the first pre-existing line. The document carries
    the code file's name, so two branches never commit the same document."""
    put_file(repo, "docs/requirements/%s.yaml" % new_id,
             doc_text(new_id, "[REQ-0001]", "summary: see %s for the plan\ntags: [%s]\n" % (new_id, code_file)))
    put_file(repo, code_file, ";; implements %s\n(defun f ())\n" % new_id)
    put_file(repo, notes_file, NOTES + "keep %s here\n" % new_id)
    commit_all(repo, message)


def case_renumber_acceptance(tmp):
    """REQ-0079's acceptance, literally: two clones that cannot see each other each
    take REQ-0002; one publishes; the other renumbers and merges."""
    _up, clone_a, clone_b = world_with(tmp, "accept", {"notes-a.md": NOTES, "notes-b.md": NOTES})
    answers = (allocate_in(clone_a, "REQ"), allocate_in(clone_b, "REQ"))
    report(answers == ("REQ-0002", "REQ-0002"), "acceptance: the clones were handed %s" % (answers,))
    branch_adds(clone_a, "REQ-0002", "src/a.lisp", "notes-a.md", "A allocates REQ-0002")
    git_in(clone_a, "push", "-q", "origin", "HEAD:main")
    branch_adds(clone_b, "REQ-0002", "src/x.lisp", "notes-b.md", "B allocates REQ-0002")
    git_in(clone_b, "fetch", "-q", "origin")

    result = check_in(clone_b)
    expect("acceptance: B's check", result, 1, ["C1"], ["renumber REQ-0002"])

    before = frozen(clone_b)
    started = time.perf_counter()
    code, out, err = renumber_in(clone_b, "REQ-0002")
    timings["dry run"] = time.perf_counter() - started
    report(code == 0 and err == "", "acceptance: dry run exit %d, stderr %r" % (code, err))
    report(frozen(clone_b) == before, "acceptance: the dry run wrote something")
    report(git_in(clone_b, "status", "--porcelain") == "", "acceptance: the dry run left a dirty tree")
    for needle in ("renumber REQ-0002 -> REQ-0003",
                   "move docs/requirements/REQ-0002.yaml -> docs/requirements/REQ-0003.yaml",
                   "edit src/x.lisp:1: REQ-0002 -> REQ-0003", "edit notes-b.md:4: REQ-0002 -> REQ-0003",
                   "edit docs/requirements/REQ-0002.yaml:1: REQ-0002 -> REQ-0003",
                   "left alone notes-b.md:1", "left alone notes-b.md:3",
                   "commit", "B allocates REQ-0002", "dry run, nothing written"):
        report(needle in out, "acceptance: the dry run does not say %r.\n%s" % (needle, out))
    report("edit notes-b.md:1:" not in out and "edit notes-b.md:3:" not in out,
           "acceptance: the dry run would rewrite a line the branch did not add.\n" + out)

    messages = git_in(clone_b, "log", "--format=%H %B")
    started = time.perf_counter()
    code, out, err = renumber_in(clone_b, "REQ-0002", "--apply")
    timings["apply"] = time.perf_counter() - started
    report(code == 0 and err == "", "acceptance: apply exit %d, stderr %r" % (code, err))
    report(os.path.exists(os.path.join(clone_b, "docs/requirements/REQ-0003.yaml")), "acceptance: no REQ-0003.yaml")
    report(not os.path.exists(os.path.join(clone_b, "docs/requirements/REQ-0002.yaml")), "acceptance: REQ-0002.yaml remains")
    document = read_bytes(clone_b, "docs/requirements/REQ-0003.yaml").decode()
    report(document.startswith("id: REQ-0003\n") and "REQ-0002" not in document and "see REQ-0003 for" in document,
           "acceptance: the moved document reads %r" % document)
    report(read_bytes(clone_b, "src/x.lisp") == b";; implements REQ-0003\n(defun f ())\n",
           "acceptance: the code file reads %r" % read_bytes(clone_b, "src/x.lisp"))
    report(read_bytes(clone_b, "notes-b.md").decode() == NOTES + "keep REQ-0003 here\n",
           "acceptance: notes-b.md reads %r" % read_bytes(clone_b, "notes-b.md"))
    report(git_in(clone_b, "log", "--format=%H %B") == messages, "acceptance: a commit message changed")
    staged = git_in(clone_b, "diff", "--cached", "--name-status").splitlines()
    report(len(staged) == 1 and staged[0].startswith("R") and "REQ-0003.yaml" in staged[0],
           "acceptance: renumber staged %s, expected only the rename" % staged)
    report("git add -A" in out and "commit" in out, "acceptance: apply does not say what to do next.\n" + out)

    commit_all(clone_b, "B renumbered")
    expect("acceptance: B's check after the renumber", check_in(clone_b), 0, [], ["doc-ids: ok"])
    merge = subprocess.run(["git", "-C", clone_b, "merge", "-q", "--no-edit", "origin/main"],
                           capture_output=True, text=True, env=git_env())
    report(merge.returncode == 0, "acceptance: the merge conflicts.\n%s%s" % (merge.stdout, merge.stderr))
    ids = [read_bytes(clone_b, "docs/requirements/REQ-000%d.yaml" % n).decode().splitlines()[0] for n in (2, 3)]
    report(ids == ["id: REQ-0002", "id: REQ-0003"], "acceptance: after the merge the documents are %s" % ids)
    report("src/x.lisp" in read_bytes(clone_b, "docs/requirements/REQ-0003.yaml").decode()
           and "src/a.lisp" in read_bytes(clone_b, "docs/requirements/REQ-0002.yaml").decode(),
           "acceptance: the two documents are not each branch's own")
    expect("acceptance: the check after the merge", check_in(clone_b), 0, [])


def case_renumber_one_clone(tmp):
    """R8: the allocator reads every local branch, so a second branch in one clone
    is handed the next id, not the same one."""
    _up, _maintainer, work = build_world(tmp, "oneclone")
    git_in(work, "checkout", "-q", "-b", "first")
    first = allocate_in(work, "REQ")
    put_file(work, "docs/requirements/%s.yaml" % first, doc_text(first))
    commit_all(work, "first branch takes %s" % first)
    git_in(work, "checkout", "-q", "-b", "second", "origin/main")
    second = allocate_in(work, "REQ")
    report((first, second) == ("REQ-0002", "REQ-0003"), "one clone: the branches were handed %s and %s" % (first, second))


def refusal_world(tmp, name):
    """A branch that added REQ-0002 and implemented it, over NOTES."""
    _up, maintainer, work = world_with(tmp, name, {"notes-b.md": NOTES})
    branch_adds(work, "REQ-0002", "src/x.lisp", "notes-b.md", "B allocates REQ-0002")
    return maintainer, work


def case_renumber_refusals(tmp):
    maintainer, work = refusal_world(tmp, "refuse1")
    code, out, err = renumber_in(work, "REQ-0002")
    report(code == 0 and "REQ-0003" in out, "refusals: the fixture does not renumber cleanly.\n%s%s" % (out, err))

    expect_refused("OLD exists at the merge base", work, ["REQ-0001"], "published before")
    # Moved into completed/ by the branch, REQ-0001 is on a path the merge base lacks,
    # and only the id gives it away.
    os.makedirs(os.path.join(work, "docs/requirements/completed"))
    git_in(work, "mv", "docs/requirements/REQ-0001.yaml", "docs/requirements/completed/REQ-0001.yaml")
    commit_all(work, "complete REQ-0001")
    expect_refused("OLD exists at the merge base, on another path", work, ["REQ-0001"], "published before")
    git_in(work, "reset", "-q", "--hard", "HEAD~1")
    expect_refused("HEAD added no such id", work, ["REQ-0007"], "HEAD did not add REQ-0007")
    for malformed in ("REQ-2", "FOO-0001", "req-0002", "REQ-00020", "REQ"):
        expect_refused("malformed OLD %s" % malformed, work, [malformed], "well-formed")
    expect_refused("--to with two OLDs", work, ["REQ-0002", "REQ-0001", "--to", "REQ-0009"], "exactly one OLD")
    expect_refused("--to NEW of another category", work, ["REQ-0002", "--to", "DES-0009"], "four-digit REQ id")
    expect_refused("--to NEW that is OLD", work, ["REQ-0002", "--to", "REQ-0002"], "already carried")
    expect_refused("a base that does not exist", work, ["REQ-0002", "--base", "origin/nowhere"], "origin/nowhere")

    # An id main added after the branch point is not HEAD's to renumber.
    publish(maintainer, {"docs/requirements/REQ-0003.yaml": doc_text("REQ-0003")})
    git_in(work, "fetch", "-q", "origin")
    expect_refused("an id only BASE carries", work, ["REQ-0003"], "HEAD did not add REQ-0003")

    # --to NEW carried by a local branch, by a remote-tracking ref, by the working tree.
    git_in(work, "branch", "other", "HEAD")
    git_in(work, "checkout", "-q", "other")
    put_file(work, "docs/requirements/REQ-0009.yaml", doc_text("REQ-0009"))
    commit_all(work, "REQ-0009 on a local branch")
    git_in(work, "checkout", "-q", "-")
    expect_refused("--to NEW carried by a local branch", work, ["REQ-0002", "--to", "REQ-0009"], "refs/heads/other")
    git_in(maintainer, "checkout", "-q", "-b", "release")
    put_file(maintainer, "docs/decisions/REQ-0010.yaml", doc_text("REQ-0010"))
    commit_all(maintainer, "REQ-0010 filed in the wrong place on a release branch")
    git_in(maintainer, "push", "-q", "origin", "release")
    git_in(work, "fetch", "-q", "origin")
    expect_refused("--to NEW carried by a remote-tracking ref", work, ["REQ-0002", "--to", "REQ-0010"],
                   "refs/remotes/origin/release")
    put_file(work, "docs/requirements/REQ-0011.yaml", doc_text("REQ-0011"))
    expect_refused("--to NEW carried by the working tree", work, ["REQ-0002", "--to", "REQ-0011"], "the working tree")
    os.remove(os.path.join(work, "docs/requirements/REQ-0011.yaml"))
    code, out, err = renumber_in(work, "REQ-0002", "--to", "REQ-0012")
    report(code == 0 and "renumber REQ-0002 -> REQ-0012" in out, "--to a free id: exit %d.\n%s%s" % (code, out, err))

    # A fork has no REQ-0001 to share: no merge base at all.
    git_in(work, "checkout", "-q", "--orphan", "unrelated")
    commit_all(work, "an unrelated history")
    expect_refused("no merge base", work, ["REQ-0002"], "fetch-depth")


def case_renumber_dirty(tmp):
    """Exactly the files it would edit: any of them, staged or not, refuses; a dirty
    file it would not edit does not."""
    _maintainer, work = refusal_world(tmp, "dirty")
    put_file(work, "other.md", "a file the branch changed that names no id\n")
    commit_all(work, "another file")
    put_file(work, "other.md", "edited, and still naming no id\n")
    put_file(work, "README.md", "# fixture, edited\n")
    code, out, err = renumber_in(work, "REQ-0002")
    report(code == 0, "dirty: a file renumber would not edit blocked it: %s%s" % (out, err))
    put_file(work, "untracked.txt", "REQ-0002 in a file git does not hold\n")
    code, out, err = renumber_in(work, "REQ-0002")
    report(code == 0 and "untracked.txt" not in out, "dirty: an untracked file was read: %s%s" % (out, err))
    git_in(work, "checkout", "--", "README.md", "other.md")
    os.remove(os.path.join(work, "untracked.txt"))

    for path in ("notes-b.md", "src/x.lisp", "docs/requirements/REQ-0002.yaml"):
        original = read_bytes(work, path)
        put_bytes(work, path, original + b"edited\n")
        expect_refused("dirty, unstaged: %s" % path, work, ["REQ-0002"], path)
        git_in(work, "add", path)
        expect_refused("dirty, staged: %s" % path, work, ["REQ-0002"], path)
        git_in(work, "reset", "-q", "--hard")


def case_renumber_two_carriers(tmp):
    """Two paths HEAD added carry OLD: copied into completed/ without removing."""
    _maintainer, work = refusal_world(tmp, "twopaths")
    put_file(work, "docs/requirements/completed/REQ-0002.yaml", doc_text("REQ-0002"))
    commit_all(work, "copy, not move")
    expect_refused("two HEAD-added paths carry OLD", work, ["REQ-0002"], "carried by 2 paths")


def case_renumber_completed(tmp):
    """A document stays where it is filed: completed/ stays completed/, and a branch
    that moved a document into completed/ leaves it moved."""
    _up, _maintainer, work = world_with(tmp, "completed", {"filler.md": "filler\n"})
    put_file(work, "docs/requirements/REQ-0002.yaml", doc_text("REQ-0002", "[REQ-0001]", "summary: REQ-0002\n"))
    commit_all(work, "add REQ-0002")
    os.makedirs(os.path.join(work, "docs/requirements/completed"))
    git_in(work, "mv", "docs/requirements/REQ-0002.yaml", "docs/requirements/completed/REQ-0002.yaml")
    put_file(work, "docs/requirements/completed/REQ-0002.yaml",
             doc_text("REQ-0002", "[REQ-0001]", "summary: REQ-0002\ndate: 2026-01-01\n").replace("draft", "implemented"))
    os.makedirs(os.path.join(work, "docs/design/completed"))
    git_in(work, "mv", "docs/design/DES-0001.yaml", "docs/design/completed/DES-0001.yaml")
    commit_all(work, "complete REQ-0002 and DES-0001")
    moved = read_bytes(work, "docs/design/completed/DES-0001.yaml")
    code, out, err = renumber_in(work, "REQ-0002", "--apply")
    report(code == 0, "completed: exit %d.\n%s%s" % (code, out, err))
    final = "docs/requirements/completed/REQ-0003.yaml"
    report(os.path.exists(os.path.join(work, final)), "completed: %s does not exist.\n%s" % (final, out))
    report(not os.path.exists(os.path.join(work, "docs/requirements/REQ-0003.yaml")), "completed: the document left completed/")
    text = read_bytes(work, final).decode()
    report(text.startswith("id: REQ-0003\n") and "status: implemented" in text and "date: 2026-01-01" in text,
           "completed: status or date changed: %r" % text)
    report(read_bytes(work, "docs/design/completed/DES-0001.yaml") == moved, "completed: DES-0001 was touched")
    report(os.path.exists(os.path.join(work, "docs/design/completed/DES-0001.yaml")) and
           not os.path.exists(os.path.join(work, "docs/design/DES-0001.yaml")), "completed: DES-0001 moved")
    commit_all(work, "renumbered")
    expect("completed: the check after", check_in(work), 0, [])


def case_renumber_bytes(tmp):
    """Only the token changes: CRLF and a missing final newline survive, a form feed
    does not shift the line numbers, a rename keeps its old lines, and a file that is
    binary or not UTF-8 is reported and left as it was."""
    files = {"win.md": b"keep REQ-0002\r\nline2\r\n", "tail.txt": b"first REQ-0002\nlast REQ-0002",
             "ff.lisp": b"(a) REQ-0002\n\x0c\n(b) REQ-0002\n", "latin.txt": b"caf\xe9\n",
             "moved.md": b"alpha\nbeta REQ-0002\ngamma\ndelta\nepsilon\n", "gone.md": b"deleted REQ-0002\n"}
    _up, maintainer, work = build_world(tmp, "bytes")
    for relative, data in files.items():
        put_bytes(maintainer, relative, data)
    commit_all(maintainer, "pre-existing files")
    git_in(maintainer, "push", "-q", "origin", "HEAD:main")
    git_in(work, "fetch", "-q", "origin")
    git_in(work, "reset", "-q", "--hard", "origin/main")

    put_file(work, "docs/requirements/REQ-0002.yaml", doc_text("REQ-0002", "[REQ-0001]"))
    put_bytes(work, "late.md", b"one REQ-0002\n")
    commit_all(work, "add the document and a file")
    put_bytes(work, "late.md", b"one REQ-0002\ntwo REQ-0002\n")
    put_bytes(work, "win.md", files["win.md"] + b"added REQ-0002\r\n")
    put_bytes(work, "tail.txt", b"added REQ-0002\n" + files["tail.txt"])
    put_bytes(work, "ff.lisp", files["ff.lisp"] + b"tail \x0c REQ-0002\n")
    put_bytes(work, "latin.txt", files["latin.txt"] + b"added REQ-0002\n")
    git_in(work, "mv", "moved.md", "renamed.md")
    put_bytes(work, "renamed.md", files["moved.md"] + b"zeta REQ-0002\n")
    git_in(work, "rm", "-q", "gone.md")
    put_bytes(work, "crlf.md", b"see REQ-0002\r\nnext REQ-0002 line\r\n")
    put_bytes(work, "nonl.txt", b"x REQ-0002")
    put_bytes(work, "blob.bin", b"\x00\xff REQ-0002\n")
    put_bytes(work, "tokens.txt", b"REQ-0002 (REQ-0002) REQ-0002.\nREQ-00025 X-REQ-0002 REQ-0002x REQ-0002-ish\n")
    commit_all(work, "everything")
    skipped_before = {name: read_bytes(work, name) for name in ("latin.txt", "blob.bin")}

    code, out, err = renumber_in(work, "REQ-0002", "--apply")
    report(code == 0 and err == "", "bytes: exit %d, stderr %r.\n%s" % (code, err, out))
    expected = {
        "win.md": files["win.md"] + b"added REQ-0003\r\n",
        "tail.txt": b"added REQ-0003\n" + files["tail.txt"],
        "ff.lisp": files["ff.lisp"] + b"tail \x0c REQ-0003\n",
        "renamed.md": files["moved.md"] + b"zeta REQ-0003\n",
        "crlf.md": b"see REQ-0003\r\nnext REQ-0003 line\r\n",
        "nonl.txt": b"x REQ-0003", "late.md": b"one REQ-0003\ntwo REQ-0003\n",
        "tokens.txt": b"REQ-0003 (REQ-0003) REQ-0003.\nREQ-00025 X-REQ-0002 REQ-0003x REQ-0003-ish\n",
        "latin.txt": skipped_before["latin.txt"], "blob.bin": skipped_before["blob.bin"],
    }
    for relative, data in expected.items():
        got = read_bytes(work, relative)
        report(got == data, "bytes: %s reads %r, expected %r" % (relative, got, data))
    report("skipped latin.txt: not UTF-8" in out and "skipped blob.bin: a binary file" in out,
           "bytes: the skipped files are not reported.\n" + out)
    report("left alone win.md:1" in out and "left alone tail.txt:2" in out,
           "bytes: the lines left alone are not reported.\n" + out)
    report("gone.md" not in out, "bytes: a file HEAD deleted is mentioned.\n" + out)


def case_renumber_two_olds(tmp):
    """Two OLDs of one category get two numbers, and an OLD of another category its
    own. Main already holds REQ-0002 and REQ-0003, so the allocator answers REQ-0004
    and the second OLD must take REQ-0005 without the allocator knowing the first."""
    _up, maintainer, work = build_world(tmp, "twoolds")
    publish(maintainer, {"docs/requirements/REQ-0002.yaml": doc_text("REQ-0002"),
                         "docs/requirements/REQ-0003.yaml": doc_text("REQ-0003")})
    git_in(work, "fetch", "-q", "origin")
    git_in(work, "reset", "-q", "--hard", "origin/main")
    put_file(work, "docs/requirements/REQ-0004.yaml", doc_text("REQ-0004", "[REQ-0001]", "summary: first, REQ-0004\n"))
    put_file(work, "docs/requirements/REQ-0005.yaml", doc_text("REQ-0005", "[REQ-0004]", "summary: second, REQ-0005\n"))
    put_file(work, "docs/design/DES-0002.yaml", doc_text("DES-0002", "[REQ-0004, REQ-0005]", "summary: DES-0002\n"))
    commit_all(work, "three documents")
    publish(maintainer, {"docs/requirements/REQ-0004.yaml": doc_text("REQ-0004"),
                         "docs/requirements/REQ-0005.yaml": doc_text("REQ-0005")}, "main takes both")
    git_in(work, "fetch", "-q", "origin")
    # Main now holds REQ-0004 and REQ-0005 too; REQ-0006 and REQ-0007 are free.
    before = frozen(work)
    code, out, err = renumber_in(work, "REQ-0004", "REQ-0005", "DES-0002")
    report(code == 0, "two OLDs: dry run exit %d.\n%s%s" % (code, out, err))
    for needle in ("renumber REQ-0004 -> REQ-0006", "renumber REQ-0005 -> REQ-0007", "renumber DES-0002 -> DES-0003"):
        report(needle in out, "two OLDs: the dry run lacks %r.\n%s" % (needle, out))
    report(frozen(work) == before, "two OLDs: the dry run wrote something")
    code, out, err = renumber_in(work, "REQ-0004", "REQ-0005", "DES-0002", "--apply")
    report(code == 0, "two OLDs: apply exit %d.\n%s%s" % (code, out, err))
    second = read_bytes(work, "docs/requirements/REQ-0007.yaml").decode()
    report(second.startswith("id: REQ-0007\n") and "refines: [REQ-0006]" in second and "second, REQ-0007" in second,
           "two OLDs: the second document reads %r" % second)
    third = read_bytes(work, "docs/design/DES-0003.yaml").decode()
    report("refines: [REQ-0006, REQ-0007]" in third and third.startswith("id: DES-0003\n"),
           "two OLDs: the design reads %r" % third)
    report("first, REQ-0006" in read_bytes(work, "docs/requirements/REQ-0006.yaml").decode(),
           "two OLDs: the first document was not rewritten")
    commit_all(work, "renumbered")
    expect("two OLDs: the check after", check_in(work), 0, [])


def case_renumber_rerun(tmp):
    """After --apply the old id is gone from HEAD once committed, and a second run is
    a refusal, not a second rewrite; before the commit the edited files are dirty."""
    _maintainer, work = refusal_world(tmp, "rerun")
    code, out, err = renumber_in(work, "REQ-0002", "--apply")
    report(code == 0, "rerun: first run exit %d.\n%s%s" % (code, out, err))
    expect_refused("rerun before the commit", work, ["REQ-0002"], "uncommitted")
    commit_all(work, "renumbered")
    expect_refused("rerun after the commit", work, ["REQ-0002"], "HEAD did not add REQ-0002")


def case_renumber_parts(tmp):
    """The pieces whose failure the cases above could miss: hunk reading across a
    form feed, and the token rule."""
    script = load_script()
    diff = "+++ b/f\n@@ -0,0 +1,2 @@\n+one\x0c+two\n+three\n"
    got = list(script.added_lines(diff))
    report(got == [("f", 1, "one\x0c+two"), ("f", 2, "three")], "added_lines across a form feed: %r" % got)
    pattern = script.token_pattern(["REQ-0002"])
    table = [("REQ-0002", 1), ("(REQ-0002)", 1), ("REQ-0002.", 1), ("REQ-0002x", 1), ("REQ-0002-ish", 1),
             ('"REQ-0002"', 1), ("REQ-00025", 0), ("REQ-00020", 0), ("X-REQ-0002", 0), ("XREQ-0002", 0),
             ("9REQ-0002", 0), ("REQ-0002 REQ-0002", 2), ("req-0002", 0), ("REQ-0003", 0)]
    for text, count in table:
        got = len(pattern.findall(text.encode()))
        report(got == count, "token_pattern found %d in %r, expected %d" % (got, text, count))
    data, changes = script.rewrite_lines(b"a REQ-0002\r\nREQ-0002\nb REQ-0002", pattern,
                                         {"REQ-0002": "REQ-0003"}, {2: "REQ-0002"})
    report(data == b"a REQ-0002\r\nREQ-0003\nb REQ-0002" and changes == [(2, ["REQ-0002"])],
           "rewrite_lines limited to line 2: %r %r" % (data, changes))
    data, _ = script.rewrite_lines(b"a REQ-0002\r\nREQ-0002\nb REQ-0002", pattern,
                                   {"REQ-0002": "REQ-0003"}, {2: "a different line"})
    report(data == b"a REQ-0002\r\nREQ-0002\nb REQ-0002", "rewrite_lines rewrote a line that is not the added one: %r" % data)


CASES = (case_clean_branch, case_clean_head_is_base, case_clean_moves, case_clean_forms,
         case_untracked_is_not_read,
         case_c1, case_c1_same_document, case_c2, case_c2_across_the_merge, case_c3,
         case_c3_kept_both, case_c4, case_c4_ambiguous, case_c5,
         case_refusals, case_categories_come_from_the_allocator, case_types_line, case_reading,
         case_renumber_acceptance, case_renumber_one_clone, case_renumber_refusals,
         case_renumber_dirty, case_renumber_two_carriers, case_renumber_completed,
         case_renumber_bytes, case_renumber_two_olds, case_renumber_rerun, case_renumber_parts)


def main():
    if len(sys.argv) > 1:
        under_test.append(os.path.abspath(sys.argv[1]))
    with tempfile.TemporaryDirectory(prefix="doc-ids-") as tmp:
        for case in CASES:
            try:
                case(os.path.join(tmp, case.__name__))
            except Exception as error:
                report(False, "%s raised %s: %s" % (case.__name__, type(error).__name__, error))
    if failures:
        for failure in failures:
            print("FAIL: %s" % failure)
        print("\n%d checks failed." % len(failures))
        sys.exit(1)
    print("doc-ids.py: each of C1 to C5 fires on its own case, the clean cases stay clean, the "
          "categories come from next-doc-id.sh, and renumber passes REQ-0079's acceptance and refuses "
          "each of its refusals.")
    print("renumber on the acceptance fixture: dry run %.2f s, apply %.2f s"
          % (timings.get("dry run", 0), timings.get("apply", 0)))


if __name__ == "__main__":
    main()
