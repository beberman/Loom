#!/usr/bin/env python3
"""Check that tools/loom-test.sh and tools/loom.sh exit with the run's status.

Both scripts end in a filter (awk, grep -v), so a shell without `pipefail'
reports the filter's status.  BUG-0072: PLAN-0061 step 3 ran loom-test.sh at a
commit whose driver loaded a file that did not exist, sbcl failed, awk printed
nothing, and the script exited 0.  There was a second layer under the first: the
driver called FULL-TEST, which returns NIL when a system fails, and then ended,
so sbcl exited 0 for a failing suite as well.

Each case copies the script into a scratch tree whose Lisp side is a stub, and
runs it there, because both scripts find their tree from their own location:

    loom-test.sh   the suite passes                         exit 0
    loom-test.sh   FULL-TEST returns NIL                    exit 1
    loom-test.sh   src/full-test.lisp is missing            exit 1
    loom-test.sh   -v, FULL-TEST returns NIL                exit 1
    loom.sh        the console runs                         exit 0
    loom.sh        loom.lisp is missing                     exit 1

The loom-test.sh cases need Quicklisp in the home directory, as the real script
does, and take a few seconds each.  Run it directly:

    tools/test/test-script-exit-status.py

Like the other test-*.py suites it is not run by tools/loom-test.sh, which is the
FiveAM suite and nothing else.
"""

import os
import shutil
import subprocess
import sys
import tempfile

failures = []


def loom_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def scratch_tree(scripts, files):
    """A directory holding tools/SCRIPTS copied from this tree and FILES (path -> text)."""
    tree = tempfile.mkdtemp(prefix="loom-exit-status-")
    os.makedirs(os.path.join(tree, "tools"))
    for name in scripts:
        shutil.copy(os.path.join(loom_root(), "tools", name), os.path.join(tree, "tools", name))
    for path, text in files.items():
        full = os.path.join(tree, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)
    return tree


def run(tree, script, *arguments):
    done = subprocess.run([os.path.join(tree, "tools", script)] + list(arguments),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True, timeout=300)
    return done.returncode, done.stdout


def full_test_stub(result):
    return ("(defpackage :loom-test (:use :cl) (:export #:full-test))\n"
            "(in-package :loom-test)\n"
            "(defun full-test () (format t \"~&~%1 of 1 system passed.~%\") RESULT)\n"
            ).replace("RESULT", result)


def expect(label, tree, script, arguments, want):
    try:
        status, output = run(tree, script, *arguments)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    if status != want:
        failures.append("%s: exit %d, wanted %d; output began %r"
                        % (label, status, want, output.strip()[:120]))


def main():
    expect("loom-test.sh, a passing suite",
           scratch_tree(["loom-test.sh"], {"src/full-test.lisp": full_test_stub("t")}),
           "loom-test.sh", [], 0)
    expect("loom-test.sh, FULL-TEST returns NIL",
           scratch_tree(["loom-test.sh"], {"src/full-test.lisp": full_test_stub("nil")}),
           "loom-test.sh", [], 1)
    expect("loom-test.sh, src/full-test.lisp is missing",
           scratch_tree(["loom-test.sh"], {}),
           "loom-test.sh", [], 1)
    expect("loom-test.sh -v, FULL-TEST returns NIL",
           scratch_tree(["loom-test.sh"], {"src/full-test.lisp": full_test_stub("nil")}),
           "loom-test.sh", ["-v"], 1)
    expect("loom.sh, the console runs",
           scratch_tree(["loom.sh"], {"loom.lisp": "(format t \"Loom stub~%\")\n"}),
           "loom.sh", ["status"], 0)
    expect("loom.sh, loom.lisp is missing",
           scratch_tree(["loom.sh"], {}),
           "loom.sh", ["status"], 1)

    if failures:
        for f in failures:
            print("FAIL: %s" % f)
        print("\n%d checks failed." % len(failures))
        sys.exit(1)

    print("test-script-exit-status: loom-test.sh and loom.sh exit with the run's status, "
          "and a failing suite, a missing driver and a missing console each exit 1.")


if __name__ == "__main__":
    main()
