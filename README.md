# Loom

Loom indexes source and documentation into a graph and answers questions about
them: where something is defined, what a change reaches, which decisions govern
an area. It is written in Common Lisp and indexes itself. It reads Common Lisp,
JavaScript and Python source and YAML and Markdown documents, and it answers
people and LLM agents over a console, a REST API and an MCP endpoint.

[INSTALL.md](INSTALL.md) takes a machine with SBCL to a passing suite.
[CONTRIBUTING.md](CONTRIBUTING.md) says how to change it. Loom is MIT-licensed
([LICENSE](LICENSE)), and [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)
lists the licence of each library it loads.

## Asking it a question

    tools/loom.sh 'context <task words>'   what to read before editing
    tools/loom.sh 'find <name>'            where something is defined
    tools/loom.sh 'describe <name>'        neighbours, grouped by edge type
    tools/loom.sh 'impact repository 3'    what a change reaches, and the decisions that govern it
    tools/loom.sh 'structure'              systems, protocols, entry points, hubs
    tools/loom.sh 'check'                  rule violations and unresolved document references
    tools/loom.sh 'status | find foo'      several commands, run in order
    tools/loom.sh 'help'                   the full table of commands

Each call to tools/loom.sh starts a console process, indexes the tree, runs the
commands and stops. A running service keeps the index loaded instead, and
answers the same questions to an MCP client without the reindex.

## The twelve systems

Each is one ASDF system under src/. A system depends only on the systems above
it in this table. loom-process and loom-serve depend on the same systems and
neither depends on the other. loom-rest and loom-mcp depend on loom-serve, and
not on loom-process or on each other.

| System | Role |
| --- | --- |
| loom-utils | Leaf utilities that two systems which may not depend on each other both need: the refusal condition, the event log, scalar readers, whole-file reads, path segments, plist filtering. Depends on no Loom system, and RULE-0009 checks it. |
| loom-embed | The embedder protocol and its Ollama client, for semantic seeding. A leaf that depends on no Loom system. |
| loom-ontology | Entity and relationship declarations. Depends on no Loom system. |
| loom-graph | The only writer. Transactions, queries, resolution, rules. |
| loom-analyzer | Path and contents in, operations out. Never touches the graph. |
| loom-docstore | Documents behind a protocol: refs, addresses, versions, text. Depends only on loom-utils (RULE-0010, RULE-0013 to RULE-0021). loom-workspace is its only client. |
| loom-knowledge | Read-only services: find, describe, impact, context, structure. |
| loom-workspace | The indexing pipeline, the file monitor, and the write path: document transitions, init, generated architecture. |
| loom-process | The console. |
| loom-serve | The operation registry, the permission tiers, REPL sessions, the listener. |
| loom-rest | HTTP and JSON over that registry. |
| loom-mcp | MCP's JSON-RPC over the same listener. |

The layering is enforced by RULE-0001 to RULE-0003 and RULE-0009 to RULE-0021,
which `check` runs. They cannot see that loom-serve, loom-rest and loom-mcp
stay peers of loom-process. This does:

    sbcl --script tools/test/load-test.lisp loom-serve

It loads one system into a fresh image and prints a line ending in T when
loom-process is not in the image. CLAUDE.md has the reasoning for each layer.

## Console, REST and MCP

All three answer from the same operation registry in loom-serve.

- **Console.** `sbcl --script loom.lisp` opens a `loom>` prompt.
  tools/loom.sh drives the same console from a script.
- **REST.** The listener binds 127.0.0.1 port 4780. Every operation is a route
  at /v1/ followed by its name. An operation in the read tier answers GET and
  POST. An operation in the write or repl tier answers POST only.
- **MCP.** The same listener answers at /mcp. The file .mcp.json registers it
  with Claude Code as the `loom_*` tools. Claude Code resolves its MCP servers
  once, when a session opens, so the service has to be running before the
  session starts.

The tables below list the operations, the tiers and the tools. These operations
are REST only: watch, pause, unwatch, reindex, embed, server-status, init,
remove and architecture. The last three prepare, describe or dismantle a
repository, and tools/loom-init.sh drives them, where a terminal can ask for
consent first.

## What it contains

<!-- figures:begin -->
Figures taken at commit f5e3d83, committed 2026-10-11, with uncommitted changes in the working tree.

Read from the tree by tools/test/readme-figures.py: the status, structure and
help commands of tools/loom.sh, and tools/test/surface.lisp. Edit those, not
this block.

```text
systems (12)
  loom-analyzer loom-docstore loom-embed loom-graph loom-knowledge loom-mcp
  loom-ontology loom-process loom-rest loom-serve loom-utils loom-workspace

tests (counted by the index, not by running the suite)
  1667 tests covering 493 units

console commands (30)
  architecture check check-document complete context context-log describe
  drift embed enrich federation find help impact init log pause reindex remove
  repl rules set-status similar sites status stop structure survey unwatch
  watch

analyzers (7)
  class             language   file types
  document-analyzer -          yaml yml
  firebase-analyzer -          -
  js-analyzer       javascript cjs js jsx mjs
  lisp-analyzer     lisp       asd cl lisp lsp
  manifest-analyzer -          -
  markdown-analyzer -          markdown md txt
  python-analyzer   python     py

entity types (23)
  architecture branch call-site class commit concept decision design document
  file function interface method module package repository rule rule-violation
  setting snapshot test variable workspace

relationship types (17)
  applies-to belongs-to calls contains decides depends-on documents implements
  imports inherits mentions reads refines serves supersedes tests uses

operations (28)
  name           tier
  architecture   write
  check          read
  check-document read
  complete       write
  context        read
  context-used   write
  describe       read
  drift          read
  embed          write
  find           read
  impact         read
  init           write
  pause          write
  reindex        write
  remove         write
  repl-close     repl
  repl-eval      repl
  repl-open      repl
  rules          read
  server-status  read
  set-status     write
  similar        read
  sites          read
  status         read
  structure      read
  survey         read
  unwatch        write
  watch          write

mcp tools (19)
  loom_check loom_check_document loom_complete loom_context loom_context_used
  loom_describe loom_drift loom_find loom_impact loom_repl_close
  loom_repl_eval loom_repl_open loom_rules loom_set_status loom_similar
  loom_sites loom_status loom_structure loom_survey
```
<!-- figures:end -->

The document analyzer reads YAML under docs/ only, not a YAML file elsewhere in
a tree. A dash under file types means the analyzer claims files by name:
package.json and requirements files for the manifest analyzer, firebase.json
and .firebaserc for the firebase analyzer. A dash under language means the
analyzer reads documents or configuration, not source. An mcp tool is named
loom_ followed by its operation, with underscores for hyphens.

tools/test/readme-figures.py writes the block from the index and from the loaded
systems. Its first line names the commit and the date the figures were taken at.
The test count is the index's count of test definitions, and the index has known
gaps (see "What does not work"). The other lists are read from the loaded
systems. With the option `--check` the script writes nothing, and exits 1 naming
the first line that differs from what regenerating would write. Regenerating is
part of a release and not of every pull request ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Running it

    tools/loom-serve.sh update                    the normal way to bring it up
    sbcl --script loom.lisp                       the console
    sbcl --script loom-serve.lisp [repo ...]      console and listener on 4780
    sbcl --script loom-serve.lisp --headless ...  listener alone
    tools/loom-test.sh                            the full suite

tools/loom-serve.sh is the launcher: `status`, `start`, `stop`, `restart` and
`update`, which starts a service that is down, restarts one whose code is stale,
and does nothing otherwise. `status` also lists the watched trees. It takes the
repository list from the file described below; the two `sbcl` lines take theirs
on the command line. `start` asks the service to build each repository's vector
store and does not wait for it.

## Which trees it watches

loom-serve.lisp takes repository roots as arguments, and watches its own tree
first whether or not you name it (DES-0007 R1) — without it the staleness check
`tools/loom-serve.sh status` makes has no repository to read an `indexed-at`
from. So this watches two trees:

    sbcl --script loom-serve.lisp --headless /path/to/other-tree

That list lives only as long as the process. tools/loom-serve.sh keeps it in a
file instead: **tools/extra-repos**, one absolute path per line, `#` to end of
line a comment, blank lines ignored. `start` appends each surviving line to the
command it builds, after Loom's own root.

    # Extra trees watched alongside Loom, for dogfooding.
    /path/to/other-tree
    /path/to/another-tree

The file is gitignored: which trees a machine holds is a property of that
machine, so a fresh clone has none. `LOOM_EXTRA_REPOS=/some/other/file
tools/loom-serve.sh start` reads a different file, and a missing or empty one
leaves the command what it was before this existed.

Editing the file changes nothing until the process is replaced:

    tools/loom-serve.sh restart

`update` is not enough on its own. It restarts a service whose image is older
than the source and does nothing otherwise, and tools/extra-repos is not
source — so an `update` with no source change behind it prints "running and
current; nothing to do" and goes on watching what it watched before.

`status` says which trees are watched, under the line about the process:

    $ tools/loom-serve.sh status
    running, code current
      ready      Loom                   /path/to/Loom/
      indexing   other-tree             /path/to/other-tree/

State, name and root, one line per tree; `indexing` rather than `ready` is a
restart still working through it. The list is read back from the service rather
than from the file, because the two disagree exactly when it matters: a path in
the file that could not be watched is skipped with a message to the log and
never becomes a repository, and a tree added over /v1/watch is watched and is
in no file. `start` prints the other half of the comparison — `watching <root>
plus N from <file>` — so a file that was not found reads as `plus 0` rather
than as silence.

A query answering over fewer trees than expected is that list being short, not
the query being wrong.

Watching a tree in a service that is already running is a different operation
and persists nothing:

    curl -X POST 'http://127.0.0.1:4780/v1/watch?path=/path/to/other-tree'

It registers and indexes the tree in the live image and writes to no file;
/v1/pause keeps the index and stops polling, /v1/unwatch drops it. The next
restart watches Loom plus tools/extra-repos regardless of what any of the
three did. Use it to try a tree out; add the line to the file to keep it.

tools/extra-repos is read by tools/loom-serve.sh and by nothing else.
tools/loom.sh starts a console process of its own that watches this tree
alone, so `find` there searches Loom and no more; name another tree in the same
invocation to reach it.

    tools/loom.sh 'watch "/path/to/other-tree" | find compose-view'

## What has to be installed

[INSTALL.md](INSTALL.md) has the packages, the library list and the commands
that were run to check them. The short version:

**SBCL** — 2.2.9 here. The scripts under tools/ call `sbcl` from PATH, which is
`/usr/bin/sbcl` here and is not necessarily the SBCL behind SLIME. Where the two
could disagree, say which one you ran.

**Quicklisp** supplies the Lisp libraries.

**node** runs the JavaScript analyzer and **python3** runs the Python
analyzer. Each is a program the analyzer starts, not a Lisp library.

### Optional: semantic seeding

Loom answers from lexical matching alone but can be extended to support semantic
indexing. This section is what you install if you want more than that.

    curl -fsSL https://ollama.com/install.sh | sh     a root install
    ollama pull nomic-embed-text                      ~274 MB

Then build a store per repository. Nothing is automatic: a repository without
one behaves exactly as it did before any of this existed (REQ-0048 R6).

What it buys, measured on 2026-08-23 over two private repositories:

    known-item cases   410 of 450  ->  443 of 450
    vocabulary-mismatch  9 of 120  ->   39 of 120
    judged acceptance   42 of 45   ->   43 of 45

These figures cannot be reproduced from this repository: the trees are not
published. [docs/PRIVATE-TREES.md](docs/PRIVATE-TREES.md) names them and lists
what was copied from them and which instruments need them.

The mismatch family is the one to look at. Those are queries that share no
searchable word with their answer -- "the bit that merges edits" for
`compose-view` -- and lexical matching cannot reach them however it is tuned.

Costs, on the same two trees: about 31 ms added to a query, and a one-time
build of 3.7 to 27 definitions a second depending on how long the docstrings
are. The build is incremental afterwards, and what counts as changed is the
name and the docstring, so editing a function body re-embeds nothing.

A different embedding model is a different store: `EMBEDDER-ID` is written into
the sidecar and a mismatch is discarded rather than read. Vectors from two
models are not comparable and nothing in the arithmetic would say so.

## Security

The service has no authentication. It binds 127.0.0.1 and grants every caller
that reaches it the read and write tiers, and never the repl tier. It answers
403 to a request whose Host header is not a loopback name for its own port,
which stops a web page that reaches 127.0.0.1 through DNS rebinding (DEC-0008).
It does not stop another process on the same machine, and binding to another
address is unsupported. Run it only on a machine whose local users and
processes you trust with your repositories. [SECURITY.md](SECURITY.md) says what
the service trusts, what the Host check stops and what it does not.

## What does not work

- **Calls inside a macro body are unattributed.** Anything driven by a `test`
  form under-reports, so a small `impact` set is not proof of a small change.
  A `define-operation` or `define-command` body is the exception (DES-0014):
  its calls are recorded as call sites. DES-0001 records the rest.
- **A name is placed by its package, and sometimes cannot be.** Two definitions
  spelled alike in different packages are two callables (DES-0015). When a
  file's package uses a library that no declaration in the tree describes,
  Loom matches on the spelling instead, which is blunter. Naming the library in
  `loom-analyzer:*external-package-names*` narrows it.
- **A damaged form costs that form.** The Lisp reader recovers and the other
  definitions in the file are indexed. The damaged form is not, and `status`
  counts it on its `unread` line (DES-0013).
- **The index holds the present.** When something changed, what a migration
  took with it, and why it is the way it is are questions for git.
- **`impact` says it truncated and not by how much.** It prints `(truncated)`
  and no count of what was cut.
- **Two rules are prose.** `check` cannot enforce RULE-0004 and RULE-0008 and
  prints them as unenforced.
- **The semantic figures above cannot be reproduced here**, and neither can
  the recall and acceptance instruments under tools/test that score them. They
  need trees that are not published ([docs/PRIVATE-TREES.md](docs/PRIVATE-TREES.md)).

## Where the knowledge lives

`docs/` holds the reasoning, indexed and cross-referenced: requirements,
designs, decisions, plans, bugs, concepts and rules. CON-0004 describes the
workflow and how the documents link. CLAUDE.md is the pointer an agent reads.
[docs/KNOWLEDGE-ENGINE.md](docs/KNOWLEDGE-ENGINE.md) makes the case for Loom at
length.
