# Synoptik

Synoptik was built because in writing code using Claude in Javascript, Python, and Lisp,
I found Claude needed documentation of architectures, tests, and decisions. If 
Claude code didn't have that it would go about inspecting code to make decisions.

While there are several code indexing systems that build knowledge graphs over 
the code, Synoptik creates a knowledge graph over both the code and the documentation 
and anweers: where something is defined, what a change reaches, which decisions govern
an area. It is written in Common Lisp and indexes itself. It was built by iteration of
the use of Synoptik while building out a large Javascript and LISP project.  Synoptik currently
works with  Common Lisp, JavaScript and Python source and YAML and Markdown documents, and it answers
people and LLM agents over a console, a REST API and an MCP endpoint.  A user interface
against the REST API has not yet been built.

[INSTALL.md](INSTALL.md) takes a machine with SBCL to a passing suite.
[CONTRIBUTING.md](CONTRIBUTING.md) says how to change it, and contributors
follow the [code of conduct](CODE_OF_CONDUCT.md). Synoptik is MIT-licensed
([LICENSE](LICENSE)), and [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)
lists the licence of each library it loads.

Synoptik was called Synoptik until October 2026. The code keeps the old name: the
ASDF systems and packages are `synoptik-*`, the MCP
tools are `synoptik_*`, and the index directory is `.synoptik/`.

## Why

An agent editing code has two ways to learn what a change touches. It can read
files until it believes it has seen enough, or it can grep. Grep matches
spelling. `grep -rn slurp-file src/` returned 27 lines, and four of them were a
docstring, an export, a comment and the definition. When two packages define or
re-export the same name, grep cannot say which one a call reaches. Either way
the agent rebuilds the structure of the tree from scratch at the start of every
session, and the documents that record why the code is the way it is sit in
other files that it never opens.

Synoptik indexes the tree once and answers from the knowledge graph using both lexical matching
and semantic matching. Three cases from [VALUE.md](VALUE.md), give some illustration of 
the usefulness of Synoptik:

- `describe slurp-file` returned 16 source callers and 2 tests, by location,
  across three systems. Deciding whether the function was safe to delete from
  the grep meant reading all 27 lines.
- `impact polygonsToPartition` listed 22 reached entities, and one was a test
  asserting that the other consumer of a shared import core imports with zero
  defects. That test settled the design before any code was written: the new
  stage defaults to off, so the path the test guards is untouched.
- A segmentation fix moved a validation count from about 200 problems to 253.
  The `context` bundle carried `REV-0001`, which had measured the same failure
  a month earlier and isolated its cause. The count was a known, open and
  unrelated finding, and nobody spent a session re-deriving it.

## Asking Synoptik a question

    tools/synoptik.sh 'context <task words>'   what to read before editing
    tools/synoptik.sh 'find <name>'            where something is defined
    tools/synoptik.sh 'describe <name>'        neighbours, grouped by edge type
    tools/synoptik.sh 'impact repository 3'    what a change reaches, and the decisions that govern it
    tools/synoptik.sh 'structure'              systems, protocols, entry points, hubs
    tools/synoptik.sh 'check'                  rule violations and unresolved document references
    tools/synoptik.sh 'status | find foo'      several commands, run in order
    tools/synoptik.sh 'help'                   the full table of commands

An example from [VALUE.md](VALUE.md). A game server crashed with a corrupted
heap under concurrent database load. The obvious suspect was the one pair of
functions that marks a shared connection as staying open outside its lock,
`dhandler-acquire-connection` and `dhandler-release-connection`.

    tools/synoptik.sh 'describe dhandler-acquire-connection'

returned its two method implementations and a plan that cites it, and no
`calls` edge. Nothing in the running server invoked it. The investigation moved
to the real cause, an unlocked schema-selection sequence run from handler
construction, before anyone instrumented or tested the dead path. A grep for the
name finds the definitions and the plan and cannot say that nothing calls it.

Each call to tools/synoptik.sh starts a console process, indexes the tree, runs the
commands and stops. A running service keeps the index loaded instead, and
answers the same questions to an MCP client without the reindex.

## The twelve systems

Each is one ASDF system under src/. A system depends only on the systems above
it in this table. synoptik-process and synoptik-serve depend on the same systems and
neither depends on the other. synoptik-rest and synoptik-mcp depend on synoptik-serve, and
not on synoptik-process or on each other.

| System | Role |
| --- | --- |
| synoptik-utils | Leaf utilities that two systems which may not depend on each other both need: the refusal condition, the event log, scalar readers, whole-file reads, path segments, plist filtering. Depends on no Synoptik system, and RULE-0009 checks it. |
| synoptik-embed | The embedder protocol and its Ollama client, for semantic seeding. A leaf that depends on no Synoptik system. |
| synoptik-ontology | Entity and relationship declarations. Depends on no Synoptik system. |
| synoptik-graph | The only writer. Transactions, queries, resolution, rules. |
| synoptik-analyzer | Path and contents in, operations out. Never touches the graph. |
| synoptik-docstore | Documents behind a protocol: refs, addresses, versions, text. Depends only on synoptik-utils (RULE-0010, RULE-0013 to RULE-0021). synoptik-workspace is its only client. |
| synoptik-knowledge | Read-only services: find, describe, impact, context, structure. |
| synoptik-workspace | The indexing pipeline, the file monitor, and the write path: document transitions, init, generated architecture. |
| synoptik-process | The console. |
| synoptik-serve | The operation registry, the permission tiers, REPL sessions, the listener. |
| synoptik-rest | HTTP and JSON over that registry. |
| synoptik-mcp | MCP's JSON-RPC over the same listener. |

The layering is enforced by RULE-0001 to RULE-0003 and RULE-0009 to RULE-0021,
which `check` runs. They cannot see that synoptik-serve, synoptik-rest and synoptik-mcp
stay peers of synoptik-process. This does:

    sbcl --script tools/test/load-test.lisp synoptik-serve

It loads one system into a fresh image and prints a line ending in T when
synoptik-process is not in the image. CLAUDE.md has the reasoning for each layer.

## Console, REST and MCP

All three answer from the same operation registry in synoptik-serve.

- **Console.** `sbcl --script synoptik.lisp` opens a `synoptik>` prompt.
  tools/synoptik.sh drives the same console from a script.
- **REST.** The listener binds 127.0.0.1 port 4780. Every operation is a route
  at /v1/ followed by its name. An operation in the read tier answers GET and
  POST. An operation in the write or repl tier answers POST only.
- **MCP.** The same listener answers at /mcp. The file .mcp.json registers it
  with Claude Code as the `synoptik_*` tools. Claude Code resolves its MCP servers
  once, when a session opens, so the service has to be running before the
  session starts.

The tables below list the operations, the tiers and the tools. These operations
are REST only: watch, pause, unwatch, reindex, embed, server-status, init,
remove and architecture. The last three prepare, describe or dismantle a
repository, and tools/synoptik-init.sh drives them, where a terminal can ask for
consent first.

## What it contains

<!-- figures:begin -->
Figures taken at commit a5466cc, committed 2026-10-11.

Read from the tree by tools/test/readme-figures.py: the status, structure and
help commands of tools/synoptik.sh, and tools/test/surface.lisp. Edit those, not
this block.

```text
systems (12)
  synoptik-analyzer synoptik-docstore synoptik-embed synoptik-graph synoptik-knowledge synoptik-mcp
  synoptik-ontology synoptik-process synoptik-rest synoptik-serve synoptik-utils synoptik-workspace

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
  synoptik_check synoptik_check_document synoptik_complete synoptik_context synoptik_context_used
  synoptik_describe synoptik_drift synoptik_find synoptik_impact synoptik_repl_close
  synoptik_repl_eval synoptik_repl_open synoptik_rules synoptik_set_status synoptik_similar
  synoptik_sites synoptik_status synoptik_structure synoptik_survey
```
<!-- figures:end -->

The document analyzer reads YAML under docs/ only, not a YAML file elsewhere in
a tree. A dash under file types means the analyzer claims files by name:
package.json and requirements files for the manifest analyzer, firebase.json
and .firebaserc for the firebase analyzer. A dash under language means the
analyzer reads documents or configuration, not source. An mcp tool is named
synoptik_ followed by its operation, with underscores for hyphens. The three
`synoptik_repl_*` tools are defined and are not offered to a caller: no caller is
granted the repl tier ([SECURITY.md](SECURITY.md)), so a running service lists
16 tools.

tools/test/readme-figures.py writes the block from the index and from the loaded
systems. Its first line names the commit and the date the figures were taken at.
The test count is the index's count of test definitions, and the index has known
gaps (see "What does not work"). The other lists are read from the loaded
systems. With the option `--check` the script writes nothing, and exits 1 naming
the first line that differs from what regenerating would write. Regenerating is
part of a release and not of every pull request ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Running it

    tools/synoptik-serve.sh update                    the normal way to bring it up
    sbcl --script synoptik.lisp                       the console
    sbcl --script synoptik-serve.lisp [repo ...]      console and listener on 4780
    sbcl --script synoptik-serve.lisp --headless ...  listener alone
    tools/synoptik-test.sh                            the full suite

tools/synoptik-serve.sh is the launcher: `status`, `start`, `stop`, `restart` and
`update`, which starts a service that is down, restarts one whose code is stale,
and does nothing otherwise. `status` also lists the watched trees. It takes the
repository list from the file described below; the two `sbcl` lines take theirs
on the command line. `start` asks the service to build each repository's vector
store and does not wait for it.

## Which trees it watches

synoptik-serve.lisp takes repository roots as arguments, and watches its own tree
first whether or not you name it (DES-0007 R1) — without it the staleness check
`tools/synoptik-serve.sh status` makes has no repository to read an `indexed-at`
from. So this watches two trees:

    sbcl --script synoptik-serve.lisp --headless /path/to/other-tree

That list lives only as long as the process. tools/synoptik-serve.sh keeps it in a
file instead: **tools/extra-repos**, one absolute path per line, `#` to end of
line a comment, blank lines ignored. `start` appends each surviving line to the
command it builds, after Synoptik's own root.

    # Extra trees watched alongside Synoptik
    /path/to/other-tree
    /path/to/another-tree

The file is gitignored: which trees a machine holds is a property of that
machine, so a fresh clone has none. `SYNOPTIK_EXTRA_REPOS=/some/other/file
tools/synoptik-serve.sh start` reads a different file, and a missing or empty one
leaves the command what it was before this existed.

Editing the file changes nothing until the process is replaced:

    tools/synoptik-serve.sh restart

`update` is not enough on its own. It restarts a service whose image is older
than the source and does nothing otherwise, and tools/extra-repos is not
source — so an `update` with no source change behind it prints "running and
current; nothing to do" and goes on watching what it watched before.

`status` says which trees are watched, under the line about the process:

    $ tools/synoptik-serve.sh status
    running, code current
      ready      Synoptik                   /path/to/Synoptik/
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
restart watches Synoptik plus tools/extra-repos regardless of what any of the
three did. Use it to try a tree out; add the line to the file to keep it.

tools/extra-repos is read by tools/synoptik-serve.sh and by nothing else.
tools/synoptik.sh starts a console process of its own that watches this tree
alone, so `find` there searches Synoptik and no more; name another tree in the same
invocation to reach it.

    tools/synoptik.sh 'watch "/path/to/other-tree" | find compose-view'

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

Synoptik answers from lexical matching alone but can be extended to support semantic
indexing. This section is what you install if you want more than that.

    curl -fsSL https://ollama.com/install.sh | sh     a root install
    ollama pull nomic-embed-text                      ~274 MB

Then build a store per repository. Nothing is automatic: a repository without
one behaves exactly as it did before any of this existed (REQ-0048 R6).

    curl -X POST 'http://127.0.0.1:4780/v1/embed?repository=Synoptik'

[INSTALL.md](INSTALL.md#optional-semantic-seeding-with-ollama) has the install
as it was run, the build time, and the effect on Synoptik's own tree: 347 of 450
generated cases found without the store and 432 with it, and 0 of 44
vocabulary-mismatch cases against 8. Those can be run again from this
repository.

What it buys, measured on 2026-08-23 over two private repositories:

    known-item cases   410 of 450  ->  443 of 450
    vocabulary-mismatch  9 of 120  ->   39 of 120
    judged acceptance   42 of 45   ->   43 of 45

The judged set has 45 expectations. One of them, a definition that moved into the
private utils library, cannot be returned by any ranking (BUG-0043).

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
  Synoptik matches on the spelling instead, which is blunter. Naming the library in
  `synoptik-analyzer:*external-package-names*` narrows it.
- **A damaged form costs that form.** The Lisp reader recovers and the other
  definitions in the file are indexed. The damaged form is not, and `status`
  counts it on its `unread` line (DES-0013).
- **The index holds the present.** When something changed, what a migration
  took with it, and why it is the way it is are questions for git.
- **`impact` says it truncated and not by how much.** It prints `(truncated)`
  and no count of what was cut.
- **Two rules are prose.** `check` cannot enforce RULE-0004 and RULE-0008 and
  prints them as unenforced.
- **The semantic figures from 2026-08-23 cannot be reproduced here**, and
  neither can the acceptance instrument under tools/test that scores them. They
  need trees that are not published ([docs/PRIVATE-TREES.md](docs/PRIVATE-TREES.md)).
  The figures in INSTALL.md are on Synoptik's own tree and can.

## Where the knowledge lives

`docs/` holds the reasoning, indexed and cross-referenced: requirements,
designs, decisions, plans, bugs, concepts and rules. CON-0004 describes the
workflow and how the documents link. CLAUDE.md is the pointer an agent reads.
Three documents at the top level are not in `docs/`:
[ABOUT.md](ABOUT.md) is the white paper and says why Synoptik exists,
[VALUE.md](VALUE.md) records the questions it has answered in real work, and
[PHASE1-ARCHITECTURE.md](PHASE1-ARCHITECTURE.md) is the original architecture
document.
