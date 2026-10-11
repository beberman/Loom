#!/usr/bin/env python3
"""Scan this repository for facts about the author's machine and for credentials.

    tools/test/release-scan.py [--history] [--also REGEX ...] [--contact ADDRESS ...]

REQ-0079 R2 and PLAN-0061 step 9. A published clone must not carry the author's home
directory, hostname, address, project id or any credential, and because the history is
published too (REQ-0079 `decided:`) the scan covers every commit as well as the tip.
Python 3 standard library and git only. It finds its repository from its own location,
not from the working directory, and it never writes.

Classes, one line of text counting at most once per class:

    paths       /home/NAME/ and /Users/NAME/ for the account running the scan (the
                names are read at run time from $USER, $LOGNAME and the owners of the
                process and of $HOME, and are never written here), a Windows
                drive path under Users, and the tilde paths of the author's two
                source trees
    host        socket.gethostname(), skipped when empty or "localhost"
    e-mail      any address except example.com and example.org (and their
                subdomains), *.invalid, anything with "noreply" in the local part or
                the domain, tools/js/vendor/**/package.json, and each --contact
                ADDRESS in SECURITY.md and CODE_OF_CONDUCT.md at the repository root
    project-id  each --also REGEX. The release checklist supplies the Firebase
                project id (PLAN-0061 finding 25) and this script does not name it
    credential  CREDENTIAL_PATTERNS below. The table is the review surface: the
                placeholder URL passwords SENTINEL and token, a URL password shorter
                than four characters, an AWS secret key that names no value, and the
                `\\b` that keeps an ordinary word ending in "sk" from reading as an
                API key, are in it
    private     the names of the three private trees. Counted and printed and never a
                failure, because REQ-0079 R3 keeps them

Tip mode reads the blobs of HEAD (`git ls-tree`, `git cat-file --batch`), not the
working tree. A scratch file, an untracked file or an uncommitted edit is not part of
what gets published and so never matters; the cost is that a change must be committed
before the scan can see it. It exits 1 on a hit in paths, host, e-mail, project-id or
credential.

History mode reads `git log --all --cc -p -U0`: the commit message of every commit
reachable from any ref, and every line each commit added. It exits 1 on a credential
hit only. The other classes are printed by commit and stay in history (D3: rewriting
history changes every hash the documents cite). Author and committer metadata is not
read.

Why that is complete. A blob reachable from any ref is the tree entry of some reachable
commit C. Each line of it is either in C's parent's version of the file, which is an
earlier reachable blob that this argument covers in turn, or it is a line C added and
the diff shows it. Rename detection shows no line for a pure rename, which added none.
A root commit shows every line. For a merge `--cc` shows the lines that are in no
parent, which is where a conflict resolution or an edit made in the merge puts a new
line, and the lines taken from one parent were added by that parent's own history. So
every line of every blob is read at the commit that added it, and a line is read once
per commit rather than once per blob that carries it, which is why the counts are per
commit. What it cannot see: a binary file (git's test is a NUL in the first 8000
bytes, and `.gitattributes` can change it), whose count is printed; and an object
reachable only from a tag that names a tree or a blob directly. The summary prints the
number of blobs reachable, from `git rev-list --all --objects`, so the figure can be
compared with an earlier run.

--contact names the address the project publishes for vulnerability reports and conduct
reports (DEC-0009). The two files that publish it say it by design, so the address is
not a hit there. It is a hit anywhere else, including a commit message and a file of the
same name in a subdirectory. Without the option it is a hit in those two files too. A
different address in either file is a hit. History mode takes the path from the diff.

Output is one line per hit: the class, a count of lines, and a file path (tip) or a
commit id with `diff` or `message` (history). It never prints a matched value or a
line of any file. A refusal is one sentence on stderr and exit 2, as is a bad
argument; an --also that is not a regular expression is a refusal that does not repeat
the expression.

Blobs are streamed in 1 MiB chunks, so a large file costs time and not memory; the
summary names the slowest one. Matching is on bytes, so no file can fail to decode.
"""

import argparse
import itertools
import os
import re
import subprocess
import sys
import tempfile
import time

CLASS_ORDER = ("paths", "host", "e-mail", "project-id", "credential", "private")
FAILS_AT_TIP = ("paths", "host", "e-mail", "project-id", "credential")
FAILS_IN_HISTORY = ("credential",)
BINARY_PROBE = 8000
CHUNK = 1 << 20

# The expressions are in the source so that a reviewer can read them. \x22 and \x27 are
# the two quotation marks. Each is written so that its own text does not match it: a
# scanner whose source trips the scan would have to exclude itself.
PATH_PATTERNS = (
    ("windows-drive-home", r"(?i:[a-z]:[/\\]+Users[/\\]+[^/\\\s\x22\x27<>]+[/\\])"),
    ("tilde-trees", r"~/(?:lisp|github)/"),
)

CREDENTIAL_PATTERNS = (
    ("aws-access-key-id", r"AKIA[0-9A-Z]{16}"),
    ("github-token", r"gh[pousr]_[A-Za-z0-9]{36,}"),
    ("github-fine-grained-token", r"github_pat_[A-Za-z0-9_]{22,}"),
    ("api-secret-key", r"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}"),
    ("slack-token", r"xox[abprs]-[A-Za-z0-9-]{10,}"),
    ("private-key-header", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("google-api-key", r"AIza[0-9A-Za-z_-]{35}"),
    ("quoted-secret",
     r"(?i:password|passwd|secret|api_key|access_token|auth_token)[\x22\x27]?\s*[:=]\s*"
     r"[\x22\x27][^\x22\x27\s]{8,}[\x22\x27]"),
    ("bearer-token", r"[Bb]earer\s+[A-Za-z0-9._~+/=-]{20,}"),
    ("url-password",
     r"(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:(?!(?:SENTINEL|token)@)[^\s/@]{4,}@"),
    ("jwt", r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+"),
    ("aws-secret-key-assigned",
     r"(?i:aws_secret_access_ke[y])[\x22\x27]?\s*[=:]\s*[\x22\x27]?[A-Za-z0-9/+]{16,}"),
)

# Spelled with a one-letter class so that this file does not name what it counts.
PRIVATE_PATTERNS = (
    ("first-tree", r"game-serve[r]"),
    ("second-tree", r"(?:@|/)front-en[d]\b|\bfront-en[d]/"),
    ("third-tree", r"\blfi[a]\b"),
)

# A lookbehind on the local part keeps a long run of address characters from being
# retried from every position.
EMAIL_PATTERN = (r"(?<![A-Za-z0-9._%+-])(?P<local>[A-Za-z0-9._%+-]+)@"
                 r"(?P<domain>[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})(?![A-Za-z0-9-])")
EXEMPT_DOMAINS = ("example.com", "example.org")
VENDORED_PREFIX = b"tools/js/vendor/"
VENDORED_MANIFEST = b"/package.json"
PUBLISHING_PATHS = (b"SECURITY.md", b"CODE_OF_CONDUCT.md")


class Refusal(Exception):
    """A sentence for the user. The script exits 2 on it rather than on a traceback."""


# ---------------------------------------------------------------------------
# What to look for
# ---------------------------------------------------------------------------

def account_names():
    """The account names this machine knows the user by. Nothing is written into the
    script: a name that lived here would be an author-machine fact itself."""
    names = [os.environ.get("USER"), os.environ.get("LOGNAME")]
    try:
        import pwd
        names.append(pwd.getpwuid(os.getuid()).pw_name)
        names.append(pwd.getpwuid(os.stat(os.path.expanduser("~")).st_uid).pw_name)
    except (ImportError, KeyError, OSError):
        pass
    return sorted({name for name in names if name})


def host_name():
    import socket
    name = socket.gethostname().strip()
    return "" if name.lower() in ("", "localhost") else name


def alternation(patterns):
    return "|".join("(?:%s)" % pattern for pattern in patterns)


def compile_bytes(pattern):
    return re.compile(pattern.encode("utf-8", "surrogateescape"))


def also_patterns(arguments):
    """The --also expressions as one alternation, or a Refusal that names the
    argument's position and not its text (it may be the very value being hunted)."""
    for number, argument in enumerate(arguments, 1):
        if not argument:
            raise Refusal("--also argument %d is empty and would match every line" % number)
        try:
            compile_bytes(argument)
        except re.error as error:
            raise Refusal("--also argument %d is not a regular expression: %s" % (number, error.msg))
    return list(arguments)


def contact_addresses(arguments):
    """The --contact addresses as lower-case bytes, or a Refusal that names the
    argument's position and not its text."""
    shape = compile_bytes(EMAIL_PATTERN)
    found = set()
    for number, argument in enumerate(arguments, 1):
        encoded = argument.encode("utf-8", "surrogateescape")
        if not shape.fullmatch(encoded):
            raise Refusal("--contact argument %d is not an e-mail address" % number)
        found.add(encoded.lower())
    return frozenset(found)


def allowance_for(path, contacts):
    """The contact addresses that may stand in the file at PATH: all of them in a
    publishing file, none anywhere else."""
    return contacts if path in PUBLISHING_PATHS else frozenset()


def build_scanner(also):
    """class name -> compiled pattern over bytes. A class with nothing to look for is
    absent. The e-mail pattern needs the address and so is applied by foreign_address."""
    names = account_names()
    paths = [pattern for _, pattern in PATH_PATTERNS]
    if names:
        paths.append(r"(?:/home|/Users)/(?:%s)(?![A-Za-z0-9_-])" % "|".join(re.escape(n) for n in names))
    scanner = {
        "paths": compile_bytes(alternation(paths)),
        "e-mail": compile_bytes(EMAIL_PATTERN),
        "credential": compile_bytes(alternation(pattern for _, pattern in CREDENTIAL_PATTERNS)),
        "private": compile_bytes(alternation(pattern for _, pattern in PRIVATE_PATTERNS)),
    }
    host = host_name()
    if host:
        scanner["host"] = compile_bytes(r"(?i:(?<![A-Za-z0-9.-])%s(?![A-Za-z0-9-]))" % re.escape(host))
    extra = also_patterns(also)
    if extra:
        scanner["project-id"] = compile_bytes(alternation(extra))
    return scanner


def is_vendored_manifest(path):
    return path.startswith(VENDORED_PREFIX) and path.endswith(VENDORED_MANIFEST)


def exempt_address(local, domain):
    domain = domain.lower()
    if b"noreply" in local.lower() or b"noreply" in domain:
        return True
    text = domain.decode("ascii", "replace")
    return text.endswith(".invalid") or any(text == d or text.endswith("." + d) for d in EXEMPT_DOMAINS)


def foreign_address(pattern, line, allowed):
    """True when the line holds an address that no exemption covers and that is not one
    of the ALLOWED contact addresses."""
    return any(not exempt_address(m.group("local"), m.group("domain")) and m.group(0).lower() not in allowed
               for m in pattern.finditer(line))


def scan_line(scanner, line, vendored, allowed):
    """The classes that hit this line. VENDORED is a file whose addresses are other
    people's by construction. ALLOWED is the contact addresses this file may hold."""
    hit = [name for name, pattern in scanner.items() if name != "e-mail" and pattern.search(line)]
    email = scanner.get("e-mail")
    if email and not vendored and b"@" in line and foreign_address(email, line, allowed):
        hit.append("e-mail")
    return hit


def add_hits(counts, scanner, line, vendored, allowed=frozenset()):
    for name in scan_line(scanner, line, vendored, allowed):
        counts[name] = counts.get(name, 0) + 1


# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------

def run_git(root, *args, stdin=None):
    try:
        done = subprocess.run(["git", "-C", root, *args], input=stdin, capture_output=True)
    except OSError as error:
        raise Refusal("git could not be run: %s" % error)
    if done.returncode != 0:
        message = done.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Refusal("git %s failed: %s" % (args[0], message[0] if message else "no message"))
    return done.stdout


def repository_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return run_git(here, "rev-parse", "--show-toplevel").decode("utf-8", "surrogateescape").strip()


def head_commit(root):
    done = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                          capture_output=True)
    if done.returncode != 0:
        raise Refusal("the repository has no commit to scan")
    return done.stdout.decode().strip()


def show_path(path):
    return path.decode("utf-8", "backslashreplace")


# ---------------------------------------------------------------------------
# Tip mode: the blobs of HEAD
# ---------------------------------------------------------------------------

def tip_entries(root):
    """(path, blob id) of every tracked blob at HEAD, in path order. A submodule is a
    commit and not a blob, so it is not read."""
    entries = []
    for record in run_git(root, "ls-tree", "-r", "-z", "HEAD").split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        mode, kind, sha = meta.split(b" ")
        if kind == b"blob":
            entries.append((path, sha))
    return sorted(entries)


class BlobReader:
    """One `git cat-file --batch`, asked for one blob at a time so that neither side
    can fill a pipe the other is not reading."""

    def __init__(self, root):
        self.process = subprocess.Popen(["git", "-C", root, "cat-file", "--batch"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def chunks(self, sha):
        """The blob's bytes in pieces. It must be consumed to the end, or the next
        request reads the wrong bytes."""
        self.process.stdin.write(sha + b"\n")
        self.process.stdin.flush()
        header = self.process.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            raise Refusal("git could not read the object %s" % sha.decode("ascii", "replace"))
        left = int(header[2])
        while left:
            piece = self.process.stdout.read(min(left, CHUNK))
            if not piece:
                raise Refusal("git cat-file ended in the middle of an object")
            left -= len(piece)
            yield piece
        self.process.stdout.read(1)

    def close(self):
        self.process.stdin.close()
        self.process.wait()


def split_lines(chunks):
    tail = b""
    for chunk in chunks:
        parts = (tail + chunk).split(b"\n")
        tail = parts.pop()
        yield from parts
    if tail:
        yield tail


def scan_blob(scanner, chunks, vendored, allowed):
    """(counts, binary) for one blob. A blob with a NUL in its first 8000 bytes, which
    is git's own test, is drained and not read."""
    first = next(chunks, b"")
    if b"\0" in first[:BINARY_PROBE]:
        for _ in chunks:
            pass
        return {}, True
    counts = {}
    for line in split_lines(itertools.chain([first], chunks)):
        add_hits(counts, scanner, line, vendored, allowed)
    return counts, False


def tip_texts(root, entries):
    """(path, chunks) for each entry, read from the committed blobs."""
    reader = BlobReader(root)
    try:
        for path, sha in entries:
            yield path, reader.chunks(sha)
    finally:
        reader.close()


def tip_findings(root, scanner, contacts):
    findings, stats = [], {"files": 0, "binary": 0, "slowest": (0.0, b"")}
    for path, chunks in tip_texts(root, tip_entries(root)):
        started = time.monotonic()
        counts, binary = scan_blob(scanner, chunks, is_vendored_manifest(path), allowance_for(path, contacts))
        elapsed = time.monotonic() - started
        stats["files"] += 1
        stats["binary"] += binary
        stats["slowest"] = max(stats["slowest"], (elapsed, path))
        if counts:
            findings.append((show_path(path), "", counts))
    return findings, stats


# ---------------------------------------------------------------------------
# History mode: every message, and every line each commit added
# ---------------------------------------------------------------------------

LOG_COMMAND = ("-c", "core.quotepath=off", "-c", "log.showRoot=true", "log", "--all", "--cc", "-p", "-U0",
               "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
               "--submodule=short", "--format=%x01%H%x02%B%x03")


class CommitScan:
    """The counts for one commit, filled a line at a time from `git log -p` output.
    The format puts \\x01 before a commit and \\x03 after its message, characters a
    diff line cannot start with: every line of a hunk starts with one of + - space or a
    backslash."""

    def __init__(self, scanner, commit, contacts):
        self.scanner = scanner
        self.commit = commit
        self.contacts = contacts
        self.in_message = True
        self.message = []
        self.message_counts = {}
        self.diff_counts = {}
        self.binary = 0
        self.columns = 1
        self.in_hunk = False
        self.path = b""

    def feed(self, line):
        if self.in_message:
            self.feed_message(line)
        elif line.startswith(b"diff "):
            self.start_file(line)
        elif line.startswith(b"@@"):
            self.in_hunk = True
            self.columns = len(line) - len(line.lstrip(b"@")) - 1
        elif self.in_hunk:
            self.feed_added(line)
        else:
            self.feed_header(line)

    def feed_message(self, line):
        head, ended, _ = line.partition(b"\x03")
        self.message.append(head)
        if ended:
            self.in_message = False
            for message_line in b"\n".join(self.message).split(b"\n"):
                add_hits(self.message_counts, self.scanner, message_line, False)

    def start_file(self, line):
        self.in_hunk = False
        self.path = b""
        for combined in (b"diff --cc ", b"diff --combined "):
            if line.startswith(combined):
                self.path = line[len(combined):]

    def feed_header(self, line):
        if line.startswith(b"+++ b/"):
            self.path = line[6:].rstrip(b"\t")
        elif line.startswith(b"Binary files ") or line.startswith(b"GIT binary patch"):
            self.binary += 1

    def feed_added(self, line):
        """An added line has a + in every column: one for a plain diff, one per parent
        for a combined one. A line with a space in a column is in that parent."""
        if line[:self.columns] == b"+" * self.columns:
            add_hits(self.diff_counts, self.scanner, line[self.columns:], is_vendored_manifest(self.path),
                     allowance_for(self.path, self.contacts))


def commit_findings(commit):
    """The (commit, where, counts) rows for one finished CommitScan."""
    return [(commit.commit, where, counts)
            for where, counts in (("message", commit.message_counts), ("diff", commit.diff_counts)) if counts]


def reachable_blobs(root):
    """How many distinct blobs the refs reach, to compare one run with another."""
    listing = run_git(root, "rev-list", "--all", "--objects")
    ids = b"".join(entry.split(b" ", 1)[0] + b"\n" for entry in listing.splitlines())
    kinds = run_git(root, "cat-file", "--batch-check=%(objecttype)", stdin=ids)
    return kinds.split().count(b"blob")


def history_findings(root, scanner, contacts):
    findings, stats = [], {"commits": 0, "binary": 0, "blobs": reachable_blobs(root)}
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(["git", "-C", root, *LOG_COMMAND], stdout=subprocess.PIPE, stderr=errors)
        current = None
        for raw in itertools.chain(process.stdout, [b"\x01"]):
            line = raw[:-1] if raw.endswith(b"\n") else raw
            if line.startswith(b"\x01"):
                if current:
                    findings.extend(commit_findings(current))
                    stats["commits"] += 1
                    stats["binary"] += current.binary
                ident, _, rest = line[1:].partition(b"\x02")
                current = CommitScan(scanner, ident.decode("ascii", "replace"), contacts) if ident else None
                if current:
                    current.feed(rest)
            elif current:
                current.feed(line)
        if process.wait() != 0:
            errors.seek(0)
            message = errors.read().decode("utf-8", "replace").strip().splitlines()
            raise Refusal("git log failed: %s" % (message[0] if message else "no message"))
    return findings, stats


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def class_totals(findings):
    """class -> (lines, subjects) over all findings."""
    totals = {name: [0, set()] for name in CLASS_ORDER}
    for subject, where, counts in findings:
        for name, count in counts.items():
            totals[name][0] += count
            totals[name][1].add(subject)
    return {name: (lines, len(subjects)) for name, (lines, subjects) in totals.items()}


def print_findings(findings):
    for subject, where, counts in findings:
        for name in CLASS_ORDER:
            if name in counts:
                print("%-10s %6d  %s%s" % (name, counts[name], subject, " " + where if where else ""))


def print_table(totals, noun):
    print("%-10s %6s  %s" % ("class", "lines", noun))
    for name in CLASS_ORDER:
        print("%-10s %6d  %d" % ((name,) + totals[name]))


def failing(totals, classes):
    return [name for name in classes if totals[name][0]]


def summary_tip(root, stats, elapsed):
    seconds, path = stats["slowest"]
    return ("release-scan: tip, HEAD %s: %d files read, %d binary skipped, slowest %.2f s (%s), %.2f s in all"
            % (head_commit(root)[:12], stats["files"], stats["binary"], seconds, show_path(path), elapsed))


def summary_history(stats, elapsed):
    return ("release-scan: history: %d commits, %d blobs reachable, %d binary file diffs skipped, %.2f s"
            % (stats["commits"], stats["blobs"], stats["binary"], elapsed))


def build_parser():
    parser = argparse.ArgumentParser(prog="release-scan.py", description="Scan for author-machine facts and credentials.")
    parser.add_argument("--history", action="store_true",
                        help="scan every commit message and every line any commit added, not the tip")
    parser.add_argument("--also", action="append", default=[], metavar="REGEX",
                        help="a regular expression to report as project-id (repeatable)")
    parser.add_argument("--contact", action="append", default=[], metavar="ADDRESS",
                        help="the published contact address, not reported in SECURITY.md and "
                             "CODE_OF_CONDUCT.md at the root (repeatable)")
    return parser


def main():
    arguments = build_parser().parse_args()
    started = time.monotonic()
    try:
        root = repository_root()
        head_commit(root)
        scanner = build_scanner(arguments.also)
        contacts = contact_addresses(arguments.contact)
        scan = history_findings if arguments.history else tip_findings
        findings, stats = scan(root, scanner, contacts)
        elapsed = time.monotonic() - started
        summary = summary_history(stats, elapsed) if arguments.history else summary_tip(root, stats, elapsed)
    except Refusal as error:
        print("release-scan: %s" % error, file=sys.stderr)
        sys.exit(2)
    totals = class_totals(findings)
    print_findings(findings)
    print(summary)
    print_table(totals, "commits" if arguments.history else "files")
    failed = failing(totals, FAILS_IN_HISTORY if arguments.history else FAILS_AT_TIP)
    if arguments.history:
        print("release-scan: history has a credential in %d commit(s); rotate it before release" % totals["credential"][1]
              if failed else "release-scan: history holds no credential")
    else:
        print("release-scan: FAIL, found in %s" % ", ".join(failed) if failed else "release-scan: tip is clean")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
