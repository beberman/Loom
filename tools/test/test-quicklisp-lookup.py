#!/usr/bin/env python3
"""Check that quicklisp-setup.lisp loads Quicklisp from the first place that has one.

BUG-0074.  Every Synoptik entry point named ~/quicklisp/setup.lisp, so a machine
with several users needed a Quicklisp in each home directory.  The entry points
now load quicklisp-setup.lisp, which looks in $SYNOPTIK_QUICKLISP, then
~/quicklisp, then /usr/local/lib/quicklisp.

Each case runs sbcl on that file with a scratch home directory holding a stub
setup.lisp that prints which one it is:

    SYNOPTIK_QUICKLISP names a directory         that stub loads
    SYNOPTIK_QUICKLISP and ~/quicklisp both set  SYNOPTIK_QUICKLISP wins
    only ~/quicklisp                         that stub loads
    SYNOPTIK_QUICKLISP names a directory with no setup.lisp
                                             ~/quicklisp is used
    nothing anywhere                         exit 1, naming every place it looked

The last case is skipped when /usr/local/lib/quicklisp/setup.lisp exists, since
the test cannot hide it.  No network and no real Quicklisp are used.  Run it
directly:

    tools/test/test-quicklisp-lookup.py

Like the other test-*.py suites it is not run by tools/synoptik-test.sh, which is the
FiveAM suite and nothing else.
"""

import os
import shutil
import subprocess
import sys
import tempfile

failures = []


def synoptik_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def stub(directory, label):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "setup.lisp"), "w", encoding="utf-8") as handle:
        handle.write('(format t "STUB:%s~%%")\n' % label)


def run(home, named=None):
    environment = dict(os.environ, HOME=home)
    environment.pop("SYNOPTIK_QUICKLISP", None)
    if named is not None:
        environment["SYNOPTIK_QUICKLISP"] = named
    return subprocess.run(
        ["sbcl", "--noinform", "--non-interactive", "--eval", "(require :asdf)",
         "--load", os.path.join(synoptik_root(), "quicklisp-setup.lisp")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
        env=environment, timeout=120)


def check(name, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        print("     " + detail.replace("\n", "\n     "))
        failures.append(name)


def main():
    scratch = tempfile.mkdtemp(prefix="synoptik-quicklisp-lookup-")
    try:
        home = os.path.join(scratch, "home")
        named = os.path.join(scratch, "named")
        empty = os.path.join(scratch, "empty")
        os.makedirs(home)
        os.makedirs(empty)

        stub(named, "named")
        done = run(home, named)
        check("SYNOPTIK_QUICKLISP names a directory", "STUB:named" in done.stdout, done.stdout)

        stub(os.path.join(home, "quicklisp"), "home")
        done = run(home, named)
        check("SYNOPTIK_QUICKLISP wins over ~/quicklisp",
              "STUB:named" in done.stdout and "STUB:home" not in done.stdout, done.stdout)

        done = run(home)
        check("only ~/quicklisp", "STUB:home" in done.stdout, done.stdout)

        done = run(home, empty)
        check("a SYNOPTIK_QUICKLISP with no setup.lisp falls through to ~/quicklisp",
              "STUB:home" in done.stdout, done.stdout)

        shutil.rmtree(os.path.join(home, "quicklisp"))
        if os.path.exists("/usr/local/lib/quicklisp/setup.lisp"):
            print("skip nothing anywhere: /usr/local/lib/quicklisp/setup.lisp exists here")
        else:
            done = run(home)
            check("nothing anywhere exits 1 and names the places",
                  done.returncode == 1
                  and os.path.join(home, "quicklisp", "setup.lisp") in done.stdout
                  and "/usr/local/lib/quicklisp/setup.lisp" in done.stdout,
                  "exit %d\n%s" % (done.returncode, done.stdout))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    if failures:
        print("\n%d failed" % len(failures))
        return 1
    print("\nall passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
