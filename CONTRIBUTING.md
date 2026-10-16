# Contributing to Synoptik

Contributions are pull requests from forks. [INSTALL.md](INSTALL.md) takes a
machine to a passing suite, and [README.md](README.md) says what the system
contains. CLAUDE.md is the pointer an agent reads and holds the same rules.

## The terms

By opening a pull request you license your contribution under the project's MIT
licence ([LICENSE](LICENSE)). There is no contributor agreement to sign and no
sign-off line to add to a commit. DEC-0009 records the decision. This is the
project's statement of its terms and not legal advice.

## Before you open a pull request

Run the suite, `check`, and the peer test from the root of your clone:

    tools/loom-test.sh
    tools/loom.sh 'check'
    sbcl --script tools/test/load-test.lisp loom-serve

Green is:

- tools/loom-test.sh prints `12 of 12 systems passed.`
- `check` prints `No violations.` and lists no unresolved document reference
  that your change added. The list it prints on main is the baseline.
- `load-test.lisp` prints a line ending in `T`. That means loom-process is not
  in the image when loom-serve is loaded. `check` cannot see that property.

Before you edit, `tools/loom.sh 'context <task words>'` says what to read, and
`tools/loom.sh 'impact <name> 3'` says what a change reaches.

A new Synoptik system needs a new rule beside RULE-0010. loom-docstore may reach no
Synoptik system but loom-utils. A rule document carries one check and the rule
language has no list and no exception, so each Synoptik system loom-docstore may not
reach has its own rule: RULE-0010 and RULE-0013 to RULE-0021 name the ten that
exist. A system added later is not covered until a rule names it, and `check`
does not report an edge to it.

## Writing a document

The reasoning behind the code is in `docs/` as YAML, and CON-0004 describes the
workflow and the fields. Give a new document the next free id:

    tools/next-doc-id.sh REQ

With no argument it prints the next id of every category. When a plan is
finished, `complete` restates the status of every document the plan refines and
files them. The dry run is the default and writes nothing:

    tools/loom.sh 'complete PLAN-0019'

## Commit messages and prose

The same four rules apply to a document, a docstring and a commit message.
CLAUDE.md has the full text.

- A title names the contents.
- The subject is the subject matter and not the document.
- A number needs no adjective.
- A metaphor is replaced by the measurement it stands for.

Prefer two short declarative sentences to one long one.

## The path of a pull request that adds a document

Fetch upstream and allocate the id with tools/next-doc-id.sh. If another
document took the number first, CI fails on check C1 and prints the renumber
line:

    C1 REQ-0002: added on HEAD (...) and carried by origin/main (...)
         renumber with: tools/doc-ids.py renumber REQ-0002

The contributor or the maintainer runs that command on the pull request branch
with `--apply`, commits, and pushes. Without `--apply` the command is a dry run
and writes nothing.

    tools/doc-ids.py renumber REQ-0002 --apply
    git add -A
    git commit
    git push

A fork pull request is squash-merged, so the old id in the branch's commit
messages never enters main's history. The squash message is written after the
renumber. `python3 tools/doc-ids.py check` runs the same check before you push.

GitHub does not recompute a check when main moves. Two pull requests that each
pass can collide once the first merges, so main should require branches to be up
to date before merging (DES-0056). GitHub offers no merge queue to a repository
owned by a user.

## Before a release

README.md holds a block of figures that is read from the tree. Regenerating it
is part of a release and not of every pull request. Commit the result, because
the scan reads committed files and not the working tree.

    tools/test/readme-figures.py
    tools/test/readme-figures.py --check
    tools/test/release-scan.py --contact "$(grep -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]+' SECURITY.md)"
    tools/test/release-scan.py --history --contact "$(grep -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]+' SECURITY.md)"

`--check` exits 0 when the figures are current. The scan exits 0 when no class
but `private` has a hit. The history run exits 1 only for a credential, and
prints the other classes by commit. `--contact` takes the address SECURITY.md
publishes, and the scan then does not report it in SECURITY.md and
CODE_OF_CONDUCT.md at the root. It reports it anywhere else. A value that must
not ship and that the scan does not know, such as a project id, is passed with
`--also REGEX`.

## Reporting a vulnerability

Do not open a public issue. [SECURITY.md](SECURITY.md) says where to send a
report and what to include.

## Code of conduct

Everyone taking part follows [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). It is the
Contributor Covenant, version 2.1, and it says where to report a violation.
