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

Run it directly:

    tools/test/test-doc-ids.py [path/to/a/copy/of/doc-ids.py]

The optional argument names the script under test. That is how CON-0003's
mutations are run: a copy of the script with one check disabled must fail
exactly its own case, and nothing here edits tools/doc-ids.py to find out.

Exit status is 0 when every case holds. Like test-next-doc-id.py it tests a
script, not Loom, so tools/loom-test.sh does not run it.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

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


CASES = (case_clean_branch, case_clean_head_is_base, case_clean_moves, case_clean_forms,
         case_untracked_is_not_read,
         case_c1, case_c1_same_document, case_c2, case_c2_across_the_merge, case_c3,
         case_c3_kept_both, case_c4, case_c4_ambiguous, case_c5,
         case_refusals, case_categories_come_from_the_allocator, case_types_line, case_reading)


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
    print("doc-ids.py: each of C1 to C5 fires on its own case, the clean cases stay clean, and the "
          "categories come from next-doc-id.sh.")


if __name__ == "__main__":
    main()
