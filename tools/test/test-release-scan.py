#!/usr/bin/env python3
"""Check that tools/test/release-scan.py reports each class it names, and only those.

PLAN-0061 step 9, REQ-0079 R2. Each case builds a throwaway git repository holding a
copy of the script (untracked, so the scan never reads itself), plants fake values,
runs the script from outside the repository and compares what it printed with what was
planted. Nothing here touches this repository.

Every planted value is built by string concatenation at run time, so neither this file
nor release-scan.py matches the scanner it tests, and every value is an obviously fake
body of repeated letters and digits. No planted value looks like a live credential.

The cases, in the order they run:

  tip         one planted value per class, one file each, and the exact set of
              (class, file, count) the scan must print. Around them: the exclusions
              (placeholder URL passwords, a one-letter URL password, a `task-` line, a
              bare AWS key name in prose, example/invalid/noreply addresses, a vendored
              package.json), near misses, a binary blob, a value that straddles a
              read-chunk boundary, and an untracked file, a staged file and an
              uncommitted edit that must not be read. Also --also.
  past        a value planted and removed: history finds it and the tip does not, and
              history exits 0 for a path, an address and a hostname
  credential  history exits 1 on a credential in a past commit and names that commit
              alone
  message     a credential only in a commit message; a trailer with a noreply address;
              an author address, which is not read
  side        a credential on a branch no ref but its own reaches
  merges      a credential written in a merge's conflict resolution, found at the merge
              commit; and a clean merge, where the feature's commit is the only one named
  binary      a NUL-containing blob is counted and does not stop the scan
  private     the private names are counted and never fail either mode
  contact     --contact: the published address is allowed in SECURITY.md and
              CODE_OF_CONDUCT.md at the root, in tip and history mode, and reported in
              every other file, in a commit message, and in either file without the
              option; another address in either file is reported; two options
  refusals    a bad --also, an empty --also, a bad --contact, no commit, no repository

Run it directly:

    tools/test/test-release-scan.py [path/to/a/copy/of/release-scan.py]

The optional argument names the script under test, so that CON-0003's mutations run on
a copy with one rule removed and nothing here edits tools/test/release-scan.py.

Exit status is 0 when every case holds. It tests a script, not Synoptik, so
tools/synoptik-test.sh does not run it.
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile

failures = []
under_test = []
secrets = []

CLASSES = ("paths", "host", "e-mail", "project-id", "credential", "private")
CHUNK = 1 << 20
FIXTURE_USER = "scanfixture"


def note_failure(ok, message):
    if not ok:
        failures.append(message)


def script_path():
    return under_test[0] if under_test else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                         "release-scan.py")


def fake(length, seed="ZQ7X"):
    """A body of repeated letters and digits that fits every character class the
    credential patterns use, and that nothing real looks like."""
    return (seed * length)[:length]


# ---------------------------------------------------------------------------
# git, and a fixture repository
# ---------------------------------------------------------------------------

def git_env(**extra):
    """A fixture has no configuration of its own, and the scan sees the account
    FIXTURE_USER in addition to the real one."""
    env = dict(os.environ,
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
               USER=FIXTURE_USER, LOGNAME=FIXTURE_USER)
    env.update(extra)
    return env


def git_in(repo, *args, env=None, check=True):
    done = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=env or git_env())
    if check and done.returncode != 0:
        raise RuntimeError("git %s failed in %s: %s" % (" ".join(args), repo, done.stderr))
    return done.stdout


def make_repo(tmp, name):
    """A repository on main holding an untracked copy of the script, where the script
    looks for its repository: the root of the checkout it sits in."""
    repo = os.path.join(tmp, name)
    os.makedirs(os.path.join(repo, "tools", "test"))
    git_in(repo, "init", "-q", "-b", "main")
    shutil.copy(script_path(), scan_script(repo))
    with open(os.path.join(repo, ".git", "info", "exclude"), "a", encoding="utf-8") as handle:
        handle.write("tools/test/release-scan.py\n")
    return repo


def scan_script(repo):
    return os.path.join(repo, "tools", "test", "release-scan.py")


def put_file(repo, relative, content):
    path = os.path.join(repo, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(path, mode, **({} if mode == "wb" else {"encoding": "utf-8"})) as handle:
        handle.write(content)


def plant(repo, relative, lines, values=()):
    """Write LINES to RELATIVE and remember what must never be printed: each line and
    each value."""
    put_file(repo, relative, "\n".join(lines) + "\n")
    secrets.extend(line.strip() for line in lines)
    secrets.extend(values)


def commit_all(repo, message="commit", author=None):
    git_in(repo, "add", "-A")
    env = git_env(GIT_AUTHOR_EMAIL=author) if author else None
    git_in(repo, "commit", "-q", "--allow-empty", "-m", message, env=env)
    return git_in(repo, "rev-parse", "HEAD").strip()


# ---------------------------------------------------------------------------
# Running the scan, and reading what it printed
# ---------------------------------------------------------------------------

def host_name():
    name = socket.gethostname().strip()
    return "" if name.lower() in ("", "localhost") else name


def leaks(output):
    """The planted values and lines that appear in OUTPUT. The hostname is looked for as
    a whole word: it is the one value that could be a piece of ordinary output."""
    found = [value for value in secrets if value and value in output]
    host = host_name()
    if host and re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(host), output, re.I):
        found.append("(the hostname)")
    if FIXTURE_USER in output:
        found.append("(the account name)")
    return found


def run_scan(repo, *args, label="scan"):
    """(exit code, stdout, stderr). The script is run from outside the repository, so
    that it must find its repository from its own location, and nothing it printed may
    hold a planted value."""
    done = subprocess.run([sys.executable, scan_script(repo), *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", env=git_env(), cwd=os.path.dirname(repo))
    shown = (done.stdout + done.stderr).strip()
    note_failure(not leaks(done.stdout + done.stderr), "%s: output holds %s.\n%s"
                 % (label, leaks(done.stdout + done.stderr), shown))
    note_failure("Traceback" not in done.stderr, "%s: a traceback.\n%s" % (label, done.stderr))
    return done.returncode, done.stdout, done.stderr


# Patterns, not compiled ones: a module-level call is a :CALL-SITE entity, and
# *PYTHON-CALL-SITE-CEILING* counts them.
HIT_LINE = r"^(paths|host|e-mail|project-id|credential|private) +(\d+)  (\S.*)$"
TABLE_ROW = r"^(paths|host|e-mail|project-id|credential|private) +(\d+)  (\d+)$"


def parse(stdout):
    """({class: {subject: count}}, {class: (lines, subjects)}, summary line). A subject
    is a path in tip mode and `commit where` in history mode."""
    hits, table, summary = {}, {}, ""
    for line in stdout.splitlines():
        if line.startswith("release-scan: tip,") or line.startswith("release-scan: history:"):
            summary = line
        elif not summary:
            found = re.match(HIT_LINE, line)
            if found:
                hits.setdefault(found.group(1), {})[found.group(3)] = int(found.group(2))
            else:
                note_failure(False, "a line that is neither a hit nor the summary: %r" % line)
        else:
            row = re.match(TABLE_ROW, line)
            if row:
                table[row.group(1)] = (int(row.group(2)), int(row.group(3)))
    return hits, table, summary


def compare(label, result, expected, exit_code, verdict=None):
    """The exit code, every class's exact set of (subject, count), and the class table
    agreeing with the lines above it."""
    code, out, err = result
    hits, table, summary = parse(out)
    shown = (out + err).strip()
    note_failure(code == exit_code, "%s: exit %d, expected %d.\n%s" % (label, code, exit_code, shown))
    for name in CLASSES:
        got, want = hits.get(name, {}), expected.get(name, {})
        note_failure(got == want, "%s: class %s: unexpected %s, missing %s." % (
            label, name, sorted(item for item in got.items() if item not in want.items()),
            sorted(item for item in want.items() if item not in got.items())))
        lines = sum(hits.get(name, {}).values())
        subjects = len({s.split()[0] if " " in s and len(s.split()[0]) == 40 else s for s in hits.get(name, {})})
        note_failure(table.get(name) == (lines, subjects),
                     "%s: table row for %s is %s, lines say %s." % (label, name, table.get(name), (lines, subjects)))
    note_failure(bool(summary), "%s: no summary line.\n%s" % (label, shown))
    if verdict is not None:
        last = out.strip().splitlines()[-1] if out.strip() else ""
        note_failure(last.startswith(verdict), "%s: last line %r does not start %r." % (label, last, verdict))
    return summary


# ---------------------------------------------------------------------------
# The tip case
# ---------------------------------------------------------------------------

def credential_plants():
    """name -> (line, value) for each credential pattern. The value is what a leak
    would show."""
    key = "AKIA" + fake(16)
    github = "gh" + "p_" + fake(36)
    pat = "github" + "_pat_" + fake(30)
    secret = "sk" + "-" + fake(24)
    slack = "xox" + "b-" + fake(12)
    google = "AIza" + fake(35)
    quoted = fake(10)
    bearer = fake(24)
    url_password = fake(12)
    jwt = "ey" + "J" + fake(8) + "." + "ey" + "J" + fake(8) + "." + fake(8)
    aws = fake(20)
    return {
        "aws-access-key-id": ("key = " + key, key),
        "github-token": ("token " + github, github),
        "github-fine-grained-token": ("token " + pat, pat),
        "api-secret-key": ("key " + secret, secret),
        "slack-token": ("hook " + slack, slack),
        "private-key-header": ("-----BEGIN " + "RSA PRIVATE KEY" + "-----", "RSA PRIVATE KEY"),
        "google-api-key": ("key " + google, google),
        "quoted-secret": ("pass" + "word" + " = '" + quoted + "'", quoted),
        "bearer-token": ("Authorization: Bear" + "er " + bearer, bearer),
        "url-password": ("postgres" + "://" + "someuser" + ":" + url_password + "@" + "dbhost/db", url_password),
        "jwt": ("jwt " + jwt, jwt),
        "aws-secret-key-assigned": ("aws_secret" + "_access_key" + " = " + aws, aws),
    }


def plant_tip(repo):
    """Everything the tip case commits. Returns the expected {class: {file: count}}."""
    expected = {name: {} for name in CLASSES}
    user = FIXTURE_USER
    plant(repo, "paths.txt", [
        "cd /ho" + "me/" + user + "/work",
        "open /Us" + "ers/" + user + "/notes",
        "see c:/" + "Users/someone/file",
        "see C:" + "\\Users\\someone\\file",
        "load ~/" + "lisp/thing",
        "load ~/" + "github/thing"])
    expected["paths"]["paths.txt"] = 6
    host = host_name()
    if host:
        plant(repo, "host.txt", ["ssh " + host + " now"], [host])
        expected["host"]["host.txt"] = 1
    plant(repo, "email.txt", ["write to " + "owner" + "@" + "corp.test"], ["owner" + "@" + "corp.test"])
    expected["e-mail"]["email.txt"] = 1
    plant(repo, "projectid.txt", ["project: fixture-proj-" + "7731"], ["fixture-proj-" + "7731"])
    for name, (line, value) in credential_plants().items():
        plant(repo, "creds/%s.txt" % name, [line], [value])
        expected["credential"]["creds/%s.txt" % name] = 1
    # a value that starts 10 bytes before the first chunk boundary and ends after it
    straddle = "AKIA" + fake(16, "Q7XZ")
    put_file(repo, "big/chunk.txt", "x" * (CHUNK - 10) + straddle + "\ntail\n")
    secrets.append(straddle)
    expected["credential"]["big/chunk.txt"] = 1
    plant(repo, "private.txt", [
        "see " + "game" + "-server",
        "ask @" + "front" + "-end",
        "read src/" + "front" + "-end" + "/x.js",
        "the " + "lfi" + "a" + " tree",
        "the front end of the app",
        "front-end work, as an English phrase"])
    expected["private"]["private.txt"] = 4
    # One file each, so that a rule removed from the script names the exemption it lost.
    exempt = {
        "short-url-password": ["ht" + "tp://u:p@host/x"],
        "sentinel-url-password": ["postgres" + "://user:" + "SENTINEL" + "@host/db"],
        "token-url-password": ["postgres" + "://user:" + "token" + "@host/db"],
        "task-word": ["run task-" + "implementation-of-the-long-name"],
        "bare-aws-name": ["the aws_secret" + "_access_key."],
        "example-addresses": ["mail someone@" + "example.com", "mail a@mail." + "example.org"],
        "invalid-address": ["mail x@" + "y.invalid"],
        "noreply-addresses": ["mail noreply@" + "github.com", "mail 12345+bot@users." + "noreply" + ".github.com"],
        "near-miss-paths": ["cd /ho" + "me/" + user + "x/work", "see c:/" + "Users/<name>/file",
                            "see the lisp/ directory"]}
    for name, lines in exempt.items():
        plant(repo, "exempt/%s.txt" % name, lines)
    plant(repo, "tools/js/vendor/x/package.json", ['"author": "Someone <person@' + 'corp.test>"'])
    plant(repo, "tools/js/vendor/x/readme.txt", ["by Someone <person@" + "corp.test>"])
    expected["e-mail"]["tools/js/vendor/x/readme.txt"] = 1
    plant(repo, "docs/package.json", ['"author": "Someone <person@' + 'corp.test>"'])
    expected["e-mail"]["docs/package.json"] = 1
    put_file(repo, "blob.bin", b"\0\1\2 " + credential_plants()["aws-access-key-id"][0].encode() + b"\n")
    plant(repo, "clean.txt", ["nothing to see"])
    return expected


def case_tip(tmp):
    repo = make_repo(tmp, "tip")
    expected = plant_tip(repo)
    commit_all(repo, "plant")
    tracked = len(git_in(repo, "ls-files").split("\n")) - 1
    leak = credential_plants()["github-token"]
    plant(repo, "untracked.txt", [leak[0]], [leak[1]])
    plant(repo, "staged.txt", [leak[0]], [leak[1]])
    git_in(repo, "add", "staged.txt")
    with open(os.path.join(repo, "clean.txt"), "a", encoding="utf-8") as handle:
        handle.write(leak[0] + "\n")
    result = run_scan(repo, label="tip")
    summary = compare("tip", result, expected, 1, "release-scan: FAIL, found in paths, host, e-mail, credential"
                      if host_name() else "release-scan: FAIL, found in paths, e-mail, credential")
    note_failure("%d files read" % tracked in summary and "1 binary skipped" in summary,
                 "tip: summary %r does not say %d files read and 1 binary skipped." % (summary, tracked))
    for line in result[1].splitlines():
        note_failure(not re.search(r"\b(?:ZQ7X|Q7XZ)", line), "tip: a value in %r" % line)
    # --also names the project id and nothing else changes
    expected["project-id"]["projectid.txt"] = 1
    also = "fixture-proj-" + "[0-9]+"
    result = run_scan(repo, "--also", also, label="tip --also")
    compare("tip --also", result, expected, 1)
    # two --also, the second matching a file that holds nothing else
    result = run_scan(repo, "--also", also, "--also", "nothing to" + " see", label="tip two --also")
    expected["project-id"]["clean.txt"] = 1
    compare("tip two --also", result, expected, 1)


# ---------------------------------------------------------------------------
# History cases
# ---------------------------------------------------------------------------

def with_where(sha, where="diff"):
    return "%s %s" % (sha, where)


def contact_address(local="reports"):
    """A fake published address, built so that this file does not hold one. example.net
    is not one of the exempt domains."""
    address = local + "@" + "maintainer.example.net"
    secrets.append(address)
    return address


def case_past(tmp):
    """Planted and then removed: only history sees it, and a path, an address and a
    hostname are not a failure there."""
    repo = make_repo(tmp, "past")
    plant(repo, "keep.txt", ["nothing to see"])
    host = host_name()
    old = ["cd /ho" + "me/" + FIXTURE_USER + "/work", "write to " + "owner" + "@" + "corp.test"]
    if host:
        old.append("ssh " + host + " now")
    plant(repo, "old.txt", old, [host] if host else [])
    first = commit_all(repo, "add")
    git_in(repo, "rm", "-q", "old.txt")
    commit_all(repo, "remove")
    compare("past, tip", run_scan(repo, label="past tip"), {}, 0, "release-scan: tip is clean")
    expected = {"paths": {with_where(first): 1}, "e-mail": {with_where(first): 1}}
    if host:
        expected["host"] = {with_where(first): 1}
    summary = compare("past, history", run_scan(repo, "--history", label="past history"), expected, 0,
                      "release-scan: history holds no credential")
    note_failure("2 commits" in summary, "past: summary %r does not say 2 commits." % summary)


def case_credential(tmp):
    """A credential planted in one commit and removed in the next fails history, and
    names the one commit."""
    repo = make_repo(tmp, "credential")
    plant(repo, "keep.txt", ["nothing to see"])
    commit_all(repo, "first")
    line, value = credential_plants()["aws-access-key-id"]
    plant(repo, "secret.txt", [line], [value])
    second = commit_all(repo, "second")
    git_in(repo, "rm", "-q", "secret.txt")
    commit_all(repo, "third")
    compare("credential, tip", run_scan(repo, label="credential tip"), {}, 0)
    compare("credential, history", run_scan(repo, "--history", label="credential history"),
            {"credential": {with_where(second): 1}}, 1, "release-scan: history has a credential in 1 commit(s)")


def case_message(tmp):
    """A credential only in a message. A noreply trailer is exempt and the author's
    address is not read."""
    repo = make_repo(tmp, "message")
    plant(repo, "keep.txt", ["nothing to see"])
    commit_all(repo, "first", author="author@" + "corp.test")
    line, value = credential_plants()["github-token"]
    secrets.extend([value, line])
    second = commit_all(repo, "add a note\n\nthe token was " + value + " once\nand lived in /ho" + "me/" + FIXTURE_USER + "/x")
    commit_all(repo, "thanks\n\nCo-Authored-By: Someone <noreply@" + "example.invalid>\nSigned-off-by: A <a@" + "users.noreply.github.com>")
    compare("message, history", run_scan(repo, "--history", label="message history"),
            {"credential": {with_where(second, "message"): 1}, "paths": {with_where(second, "message"): 1}}, 1)
    compare("message, tip", run_scan(repo, label="message tip"), {}, 0)


def case_side(tmp):
    """A commit on a branch that is not checked out is reachable from a ref and so is
    in the history; the tip does not hold it."""
    repo = make_repo(tmp, "side")
    plant(repo, "shared.txt", ["line = base"])
    commit_all(repo, "base")
    git_in(repo, "checkout", "-q", "-b", "side")
    line, value = credential_plants()["slack-token"]
    plant(repo, "side.txt", [line], [value])
    side = commit_all(repo, "side")
    git_in(repo, "checkout", "-q", "main")
    compare("side, tip", run_scan(repo, label="side tip"), {}, 0)
    compare("side, history", run_scan(repo, "--history", label="side history"),
            {"credential": {with_where(side): 1}}, 1)


def case_merges(tmp):
    """The lines a merge adds that no parent has are read at the merge commit. A line a
    merge only carries from a parent is read at the commit that added it."""
    repo = make_repo(tmp, "evil")
    plant(repo, "shared.txt", ["line = base"])
    commit_all(repo, "base")
    git_in(repo, "checkout", "-q", "-b", "left")
    plant(repo, "shared.txt", ["line = left"])
    commit_all(repo, "left")
    git_in(repo, "checkout", "-q", "main")
    plant(repo, "shared.txt", ["line = right"])
    commit_all(repo, "right")
    merged = git_in(repo, "merge", "left", env=git_env(), check=False)
    note_failure("CONFLICT" in merged, "merges: the fixture merge did not conflict: %s" % merged)
    line, value = credential_plants()["jwt"]
    plant(repo, "shared.txt", ["line = " + line], [value])
    merge = commit_all(repo, "merge left")
    compare("merges, evil merge", run_scan(repo, "--history", label="evil merge history"),
            {"credential": {with_where(merge): 1}}, 1)
    clean = make_repo(tmp, "clean-merge")
    plant(clean, "shared.txt", ["line = base"])
    commit_all(clean, "base")
    git_in(clean, "checkout", "-q", "-b", "feature")
    line, value = credential_plants()["google-api-key"]
    plant(clean, "feature.txt", [line], [value])
    feature = commit_all(clean, "feature")
    git_in(clean, "checkout", "-q", "main")
    plant(clean, "other.txt", ["unrelated"])
    commit_all(clean, "other")
    git_in(clean, "merge", "-q", "--no-ff", "-m", "merge feature", "feature")
    compare("merges, clean merge", run_scan(clean, "--history", label="clean merge history"),
            {"credential": {with_where(feature): 1}}, 1)


def case_binary(tmp):
    repo = make_repo(tmp, "binary")
    line, value = credential_plants()["aws-access-key-id"]
    secrets.extend([line, value])
    put_file(repo, "data.bin", b"\0\1\2 " + line.encode() + b"\n")
    plant(repo, "keep.txt", ["nothing to see"])
    commit_all(repo, "binary")
    summary = compare("binary, tip", run_scan(repo, label="binary tip"), {}, 0)
    note_failure("1 binary skipped" in summary, "binary: tip summary %r" % summary)
    summary = compare("binary, history", run_scan(repo, "--history", label="binary history"), {}, 0)
    note_failure("1 binary file diffs skipped" in summary, "binary: history summary %r" % summary)


def case_private(tmp):
    """The private names are counted and printed and fail neither mode."""
    repo = make_repo(tmp, "private")
    plant(repo, "private.txt", ["see " + "game" + "-server", "ask @" + "front" + "-end", "the " + "lfi" + "a" + " tree"])
    first = commit_all(repo, "private")
    expected = {"private": {"private.txt": 3}}
    compare("private, tip", run_scan(repo, label="private tip"), expected, 0, "release-scan: tip is clean")
    compare("private, history", run_scan(repo, "--history", label="private history"),
            {"private": {with_where(first): 3}}, 0, "release-scan: history holds no credential")


def case_contact(tmp):
    """The address a project publishes is allowed in the two files that publish it and
    nowhere else, in tip and in history."""
    contact, other = contact_address(), contact_address("someone")
    say = ["write to " + contact]
    repo = make_repo(tmp, "contact")
    for name in ("CODE_OF_CONDUCT.md", "README.md", "docs/notes.md", "docs/SECURITY.md"):
        plant(repo, name, say)
    plant(repo, "SECURITY.md", say + ["or " + contact.upper()])
    commit_all(repo, "contact")
    elsewhere = {"README.md": 1, "docs/notes.md": 1, "docs/SECURITY.md": 1}
    everywhere = dict(elsewhere, **{"SECURITY.md": 2, "CODE_OF_CONDUCT.md": 1})
    compare("contact, tip", run_scan(repo, "--contact", contact, label="contact tip"),
            {"e-mail": elsewhere}, 1, "release-scan: FAIL, found in e-mail")
    compare("contact, upper case", run_scan(repo, "--contact", contact.upper(), label="contact upper"),
            {"e-mail": elsewhere}, 1)
    compare("contact, no option", run_scan(repo, label="contact none"), {"e-mail": everywhere}, 1)
    compare("contact, another address", run_scan(repo, "--contact", other, label="contact other"),
            {"e-mail": everywhere}, 1)
    twice = make_repo(tmp, "contact-twice")
    plant(twice, "SECURITY.md", say)
    plant(twice, "CODE_OF_CONDUCT.md", ["write to " + other])
    commit_all(twice, "two addresses")
    compare("contact, twice", run_scan(twice, "--contact", contact, "--contact", other, label="contact twice"),
            {}, 0, "release-scan: tip is clean")
    compare("contact, once", run_scan(twice, "--contact", contact, label="contact once"),
            {"e-mail": {"CODE_OF_CONDUCT.md": 1}}, 1)
    mixed = make_repo(tmp, "contact-mixed")
    plant(mixed, "SECURITY.md", ["write to " + contact + " or " + other, "or " + contact])
    commit_all(mixed, "a second address on a line with the first")
    compare("contact, a different address in SECURITY.md",
            run_scan(mixed, "--contact", contact, label="contact mixed"), {"e-mail": {"SECURITY.md": 1}}, 1)
    history = make_repo(tmp, "contact-history")
    for name in ("SECURITY.md", "CODE_OF_CONDUCT.md"):
        plant(history, name, say)
    first = commit_all(history, "publish")
    for name in ("README.md", "docs/SECURITY.md"):
        plant(history, name, say)
    second = commit_all(history, "mention it\n\nwrite to " + contact + " about it")
    verdict = "release-scan: history holds no credential"
    compare("contact, history", run_scan(history, "--history", "--contact", contact, label="contact history"),
            {"e-mail": {with_where(second): 2, with_where(second, "message"): 1}}, 0, verdict)
    compare("contact, history, no option", run_scan(history, "--history", label="contact history none"),
            {"e-mail": {with_where(first): 2, with_where(second): 2, with_where(second, "message"): 1}}, 0, verdict)


def refused(label, result, needle):
    code, out, err = result
    note_failure(code == 2, "%s: exit %d, expected 2.\n%s" % (label, code, err))
    note_failure(out == "", "%s: stdout %r, expected none." % (label, out))
    note_failure(len(err.strip().splitlines()) == 1 and needle in err, "%s: stderr %r is not one sentence naming %r." % (label, err, needle))


def case_refusals(tmp):
    repo = make_repo(tmp, "refusals")
    plant(repo, "keep.txt", ["nothing to see"])
    commit_all(repo, "first")
    bad = "(unclos" + "ed"
    result = run_scan(repo, "--also", bad, label="bad regex")
    refused("bad regex", result, "--also argument 1 is not a regular expression")
    note_failure(bad not in result[2], "bad regex: the refusal repeats the expression.")
    refused("empty --also", run_scan(repo, "--also", "", label="empty also"), "--also argument 1 is empty")
    refused("second bad", run_scan(repo, "--also", "fine", "--also", "[a", label="second bad"), "--also argument 2")
    address = "reports" + "-at-" + "maintainer.example.net"
    result = run_scan(repo, "--contact", address, label="bad contact")
    refused("bad contact", result, "--contact argument 1 is not an e-mail address")
    note_failure(address not in result[2], "bad contact: the refusal repeats the argument.")
    refused("empty --contact", run_scan(repo, "--contact", "", label="empty contact"), "--contact argument 1")
    refused("second bad contact", run_scan(repo, "--contact", contact_address(), "--contact", address, label="second contact"),
            "--contact argument 2")
    empty = make_repo(tmp, "no-commit")
    refused("no commit", run_scan(empty, label="no commit"), "no commit")
    refused("no commit, history", run_scan(empty, "--history", label="no commit history"), "no commit")
    outside = os.path.join(tmp, "outside", "tools", "test")
    os.makedirs(outside)
    shutil.copy(script_path(), os.path.join(outside, "release-scan.py"))
    done = subprocess.run([sys.executable, os.path.join(outside, "release-scan.py")], capture_output=True, text=True,
                          env=git_env(GIT_CEILING_DIRECTORIES=tmp), cwd=tmp)
    refused("no repository", (done.returncode, done.stdout, done.stderr), "git rev-parse failed")


CASES = (case_tip, case_past, case_credential, case_message, case_side, case_merges, case_binary,
         case_private, case_contact, case_refusals)


def main():
    if len(sys.argv) > 1:
        under_test.append(os.path.abspath(sys.argv[1]))
    with tempfile.TemporaryDirectory(prefix="release-scan-") as tmp:
        for case in CASES:
            try:
                case(os.path.join(tmp, case.__name__))
            except Exception as error:
                note_failure(False, "%s raised %s: %s" % (case.__name__, type(error).__name__, error))
    if failures:
        for failure in failures:
            print("FAIL: %s" % failure)
        print("\n%d checks failed." % len(failures))
        sys.exit(1)
    print("release-scan.py: each class is reported on its own file, the exclusions hold, history finds "
          "what the tip no longer has and fails only on a credential, the contact address is allowed in "
          "the two files that publish it and nowhere else, and no planted value is printed.")


if __name__ == "__main__":
    main()
