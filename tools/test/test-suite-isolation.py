#!/usr/bin/env python3
"""Check that two copies of the suite can run at the same time.

SBCL starts every image with the same *RANDOM-STATE*, so `(random (expt 2 48))'
returns the same number in every process that asks it the same number of times.
A fixture directory named from it is therefore the same directory in two
concurrent runs: each deletes the other's fixtures, and the tests that count the
records in a directory count both runs' records.  A literal port does the same
to the listener tests.  BUG-0073 reproduced both with two loom-serve suites
started together: 7 failures, among them A-WRITE-OPERATION-IS-NOT-RECORDED
and four ADDRESS-IN-USE-ERRORs.

Two properties hold the suite apart, and this checks both in the sources:

  1. every RANDOM in a test file is given a state of its own, so the name it
     builds differs between images;
  2. *TEST-PORT* is not an integer literal.

Run it directly:

    tools/test/test-suite-isolation.py

Exit status is 0 when both hold.  Like the other test-*.py suites it is not run
by tools/loom-test.sh, which is the FiveAM suite and nothing else.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
failures = []


def balanced_form(text, start):
    """The form opening at TEXT[START], through its matching paren."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def arguments(form):
    """Top-level arguments of a form like `(random A B)'."""
    inner = form[1:-1].split(None, 1)[1] if len(form.split(None, 1)) > 1 else ""
    parts, depth, current = [], 0, ""
    for char in inner:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char.isspace() and depth == 0:
            if current:
                parts.append(current)
                current = ""
        else:
            current += char
    if current:
        parts.append(current)
    return parts


def check_random_has_a_state():
    for path in sorted(glob.glob(os.path.join(ROOT, "src", "*", "test", "*.lisp"))):
        text = open(path, encoding="utf-8").read()
        for match in re.finditer(r"\(random[\s]", text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            if ";" in text[line_start:match.start()]:
                continue  # inside a comment
            form = balanced_form(text, match.start())
            if len(arguments(form)) < 2:
                line = text.count("\n", 0, match.start()) + 1
                failures.append(
                    "%s:%d  %s  has no state of its own, so two images build one name"
                    % (os.path.relpath(path, ROOT), line, " ".join(form.split())))


def check_port_is_not_a_literal():
    path = os.path.join(ROOT, "src", "serve", "test", "server.lisp")
    text = open(path, encoding="utf-8").read()
    match = re.search(r"\(defparameter \*test-port\*\s+(\S+)", text)
    if not match:
        failures.append("src/serve/test/server.lisp defines no *TEST-PORT*")
    elif match.group(1).isdigit():
        failures.append(
            "src/serve/test/server.lisp:*TEST-PORT* is the literal %s, which a "
            "second suite or a stale image already holds" % match.group(1))


check_random_has_a_state()
check_port_is_not_a_literal()

if failures:
    for f in failures:
        print("FAIL: %s" % f)
    print("\n%d checks failed." % len(failures))
    sys.exit(1)

print("test-suite-isolation: every RANDOM in a test file has its own state, and *TEST-PORT* is chosen at load.")
