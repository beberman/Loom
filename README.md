# Loom

Loom pulls together the threads of software development and weaves them into a
living tapestry of engineering knowledge.

It indexes source and documentation into a graph and answers questions about
them: where something is defined, what a change reaches, which decisions govern
an area. `docs/` holds the reasoning; `CLAUDE.md` is the pointer an agent reads.

## Running it

    tools/loom-serve.sh update                    the normal way to bring it up
    sbcl --script loom.lisp                       the console
    sbcl --script loom-serve.lisp [repo ...]      console and listener on 4780
    sbcl --script loom-serve.lisp --headless ...  listener alone
    tools/loom-test.sh                            the full suite

`tools/loom-serve.sh` is the launcher: `status`, `start`, `stop`, `restart` and
`update`, which starts a service that is down, restarts one whose code is stale,
and does nothing otherwise. `status` also lists the watched trees. It takes the
repository list from the file described below; the two `sbcl` lines take theirs
on the command line. `start` asks the service to build each repository's vector
store and does not wait for it.

## Which trees it watches

`loom-serve.lisp` takes repository roots as arguments, and watches its own tree
first whether or not you name it (DES-0007 R1) — without it the staleness check
`tools/loom-serve.sh status` makes has no repository to read an `indexed-at`
from. So this watches two trees:

    sbcl --script loom-serve.lisp --headless ~/lisp/game-server

That list lives only as long as the process. `tools/loom-serve.sh` keeps it in a
file instead: **`tools/extra-repos`**, one absolute path per line, `#` to end of
line a comment, blank lines ignored. `start` appends each surviving line to the
command it builds, after Loom's own root.

    # Extra trees watched alongside Loom, for dogfooding.
    /home/beberman/lisp/game-server
    /home/beberman/github/front-end

The file is gitignored: which trees a machine holds is a property of that
machine. `LOOM_EXTRA_REPOS=/some/other/file tools/loom-serve.sh start` reads a
different file, and a missing or empty one leaves the command what it was
before this existed.

Editing the file changes nothing until the process is replaced:

    tools/loom-serve.sh restart

`update` is not enough on its own. It restarts a service whose image is older
than the source and does nothing otherwise, and `tools/extra-repos` is not
source — so an `update` with no source change behind it prints "running and
current; nothing to do" and goes on watching what it watched before.

`status` says which trees are watched, under the line about the process:

    $ tools/loom-serve.sh status
    running, code current
      ready      Loom                   /home/beberman/lisp/Loom/
      ready      game-server            /home/beberman/lisp/game-server/
      indexing   front-end              /home/beberman/github/front-end/

State, name and root, one line per tree; `indexing` rather than `ready` is a
restart still working through it. The list is read back from the service rather
than from the file, because the two disagree exactly when it matters: a path in
the file that could not be watched is skipped with a message to the log and
never becomes a repository, and a tree added over `/v1/watch` is watched and is
in no file. `start` prints the other half of the comparison — `watching <root>
plus N from <file>` — so a file that was not found reads as `plus 0` rather
than as silence.

A query answering over fewer trees than expected is that list being short, not
the query being wrong.

Watching a tree in a service that is already running is a different operation
and persists nothing:

    curl -X POST 'http://127.0.0.1:4780/v1/watch?path=/home/beberman/lisp/game-server'

It registers and indexes the tree in the live image and writes to no file;
`/v1/pause` keeps the index and stops polling, `/v1/unwatch` drops it. The next
restart watches Loom plus `tools/extra-repos` regardless of what any of the
three did. Use it to try a tree out; add the line to the file to keep it.

`tools/extra-repos` is read by `tools/loom-serve.sh` and by nothing else.
`tools/loom.sh` starts a console process of its own that watches this tree
alone, so `find` there searches Loom and no more; name another tree in the same
invocation to reach it.

    tools/loom.sh 'watch "~/lisp/game-server" | find compose-view'

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
