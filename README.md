# Loom

Loom pulls together the threads of software development and weaves them into a
living tapestry of engineering knowledge.

It indexes source and documentation into a graph and answers questions about
them: where something is defined, what a change reaches, which decisions govern
an area. `docs/` holds the reasoning; `CLAUDE.md` is the pointer an agent reads.

## Running it

    sbcl --script loom.lisp                       the console
    sbcl --script loom-serve.lisp [repo ...]      console and listener on 4780
    sbcl --script loom-serve.lisp --headless ...  listener alone
    tools/loom-test.sh                            the full suite

## What has to be installed

Checked on this machine on 2026-08-23. Version numbers are what it reports
rather than a floor anybody has tested against.

**SBCL** — 2.2.9 here. `/usr/bin/sbcl`, which is what every script under
`tools/` invokes and is not necessarily the SBCL behind SLIME. Where the two
could disagree, say which one you ran.

**Quicklisp**, at `~/quicklisp`, supplying ten libraries: `bordeaux-threads`,
`cl-json`, `cl-yaml`, `drakma`, `eclector`, `fiveam`, `hunchentoot`,
`random-uuid`, `stem`, `uiop`. `(ql:quickload :loom-process)` pulls them.

**The `utils` library**, which Quicklisp does not supply and which is the one
prerequisite you cannot guess. It is a sibling repository reached through
`~/quicklisp/local-projects/`:

    git clone <utils> ~/lisp/utils
    ln -s ~/lisp/utils ~/quicklisp/local-projects/utils

`loom-serve` depends on it for `IMPROPER-LIST-P`, and PLAN-0036 deleted Loom's
own `SLURP-FILE` and `SPLIT-LINES` in favour of it. Without the symlink the
systems will not load and the error names a system rather than a file.

### Optional: semantic seeding

Loom answers from lexical matching alone and reports nothing about the absence.
There is no error, no warning and no configuration to turn off — a repository
with no vector store never opens a socket. This section is what you install if
you want more than that.

    curl -fsSL https://ollama.com/install.sh | sh     a root install
    ollama pull nomic-embed-text                      ~274 MB

Then build a store per repository. Nothing is automatic: a repository without
one behaves exactly as it did before any of this existed (REQ-0048 R6).

What it buys, measured on 2026-08-23 over game-server and front-end:

    known-item cases   410 of 450  ->  443 of 450
    vocabulary-mismatch  9 of 120  ->   39 of 120
    judged acceptance   42 of 45   ->   43 of 45

The mismatch family is the one to look at. Those are queries that share no
searchable word with their answer -- "the bit that merges edits" for
`compose-view` -- and lexical matching cannot reach them however it is tuned.

Costs, on the machine above: about 31 ms added to a query, and a one-time
build of 3.7 to 27 definitions a second depending on how long the docstrings
are. The build is incremental afterwards, and what counts as changed is the
name and the docstring, so editing a function body re-embeds nothing.

A different embedding model is a different store: `EMBEDDER-ID` is written into
the sidecar and a mismatch is discarded rather than read. Vectors from two
models are not comparable and nothing in the arithmetic would say so.

## Where the knowledge lives

Not here. `docs/` holds it, indexed and cross-referenced: requirements,
designs, decisions, plans, bugs, concepts and rules. `CON-0004` describes the
workflow and how the documents link.
