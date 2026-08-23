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

Run it directly:

    tools/test-next-doc-id.py

Exit status is 0 when every case holds. This is not part of the FiveAM suite --
it tests a shell script, not Loom -- so tools/loom-test.sh does not run it.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "tools", "next-doc-id.sh")
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


def highest_on_disk(prefix):
    """The highest nnnn among docs/*/PREFIX-nnnn.yaml, or 0, and its directory."""
    best, where = 0, None
    for directory, _dirs, files in os.walk(DOCS):
        for name in files:
            m = re.fullmatch(re.escape(prefix) + r"-(\d{4})\.yaml", name)
            if m:
                n = int(m.group(1))
                if n > best:
                    best, where = n, directory
    return best, where


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

    highest, where = highest_on_disk(category)
    report(answered == highest + 1,
           "%s: answered %s, but %s-%04d exists in %s"
           % (category, out, category, highest,
              os.path.relpath(where, ROOT) if where else "docs"))

    # The directory the answer came from has to be the one holding the
    # documents. A row pointing at the wrong directory answers nnnn+1 of an
    # empty set, which is what BUG-0039 did.
    report(highest > 0,
           "%s: no %s-nnnn.yaml anywhere under docs/, so the row names a "
           "category with no documents" % (category, category))

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

if failures:
    for f in failures:
        print("FAIL: %s" % f)
    print("\n%d of %d checks failed." % (len(failures), len(failures)))
    sys.exit(1)

print("next-doc-id.sh: every offered category resolves and answers highest + 1.")
