# Loom

A Common Lisp engineering knowledge engine. It indexes source and documentation
into a graph and answers questions about them for LLM agents: where something is
defined, what a change reaches, what decisions govern an area.

## Ask Loom before reading the tree

Loom indexes itself, so the fastest way to understand this codebase is to use
it. **If `loom_*` tools are in your tool list, use those** — `.mcp.json`
registers the running service and they answer against a warm index in
milliseconds, where each `tools/loom.sh` call reindexes the tree first. They
need a Claude Code restart to appear, and `tools/loom-serve.sh update` after any
change to Loom's own source. The script below is the fallback and always works:

```
tools/loom.sh 'context <task words>'  # start here: what to read before editing
tools/loom.sh 'find <name>'           # where something is defined -- in every
tools/loom.sh 'find <name> --code'    # ...or only code, or --documentation for
                                      #   only documents. `repository' names 232
                                      #   entities here and most callers want one
                                      #   family. REQ-0062.
                                      #   watched tree, unless you name one.
                                      #   A zero-hit answer that named one says
                                      #   what the others hold: `0 here; 1 in
                                      #   <tree>'. REQ-0051.
tools/loom.sh 'describe <name>'       # neighbours, grouped by edge type
tools/loom.sh 'impact <name> 3'       # what a change reaches, plus decisions
                                      #   3 is a narrowing; the default is 5
tools/loom.sh 'structure'             # systems, protocols, entry points, hubs,
                                      #   derived from the index. Reports edges
                                      #   between systems both ways and calls
                                      #   neither wrong. REQ-0021 R5.
tools/loom.sh 'similar <name>'         # definitions that resemble one, by
                                      #   meaning rather than by name -- the
                                      #   question `find' cannot ask, since a
                                      #   duplicate is where the names differ.
                                      #   `survey <repo> <repo> [<cut>]' does it
                                      #   for two whole trees. Both need a
                                      #   vector store and say so when there is
                                      #   none. REQ-0042; on REST and MCP since
                                      #   BUG-0052.
tools/loom.sh 'rules'                 # constraints, and which are machine-checked
tools/loom.sh 'check'                 # violations and unresolved doc references
tools/loom.sh 'enrich'                # ask the toolchain what the text pass
                                      #   cannot see. Optional, on demand only,
                                      #   and self-aging: an index nobody has
                                      #   re-enriched gives today's text answer
                                      #   rather than yesterday's image answer.
                                      #   DES-0011.
tools/loom.sh 'impact @Loom repository 3'   # name the repository, when the
                                      #   service holds several. A leading
                                      #   @token works on every command and
                                      #   lasts one command. REQ-0023. Every
                                      #   command but `find' and `status'
                                      #   refuses without one rather than
                                      #   guessing; those two answer across all
                                      #   of them, which is what they are for.
tools/loom.sh 'status | find foo'     # several commands, run in order
tools/loom.sh 'help'                  # the authoritative table; trust it first
```

**The index holds this tree's present. Its past is git's.** Every command above
asks about the code as it stands. When something changed, what a migration took
with it, and why it is the way it is are questions the index cannot answer and
will answer anyway, about the present. `git log -S <name>` finds the commits
where the count of a string changed, which is how a rename, a move or a
deletion is found.

A commit message is evidence no index holds. One bug turned on a single
sentence in a commit message, which was the whole of what was known about a
stale fixture, and nothing derives that from the code because it is not in the
code. REQ-0058.

**Drive Loom through `tools/`, not through a shell pipeline.** `tools/loom.sh`
takes console commands as separate arguments, watches the tree before the first
and stops after the last, and filters compile chatter. `tools/loom-test.sh` runs
the full suite. Both `cd` to the tree themselves, so they work from any
directory. Call them with the **Bash** tool:

```
tools/loom.sh 'impact repository 3'
tools/loom-test.sh
```

**`tools/` operates Loom; `tools/test/` measures it.** Eight things run Loom --
`loom.sh`, `loom-serve.sh`, `loom-install.sh`, `loom-init.sh`, `loom-test.sh`,
`next-doc-id.sh`, `doc-ids.py` and `allow-loom.py`, the permission hook --
beside `js/` and `py/`, which are not tools at all: the analyzer loads
`js/extract.js` and `py/extract.py` at runtime.

`tools/loom-install.sh` links `loom` and `loom-serve` onto `PATH` and calls
`loom-serve.sh install` for the unit. Links, never copies: Loom is a source tree
SBCL loads at runtime and indexes itself, so a copy would be a second Loom that
is never the one under test. REQ-0072. Everything that verifies
or measures is under `tools/test/`: the three `test-*.py` suites,
`load-test.lisp` for the peer property, `seed-trace.lisp` for why a seed band
holds what it holds, `profile-context.lisp` for where a `context` query spends its CPU, `index-dump.lisp` for comparing a whole index built by
two versions of the code (DES-0051 D8), the four census scripts, the case
builders with `cases/` beside them, the `acceptance.py` and `recall.py`
harnesses, and the two shared libraries they load -- `harness.lisp` and
`service.py`. Nothing in `tools/test/` is run by `tools/loom-test.sh`, which is
the FiveAM suite and nothing else.

Several commands go in one quoted argument separated by `|`, or one per
argument; the two forms mix. The `|` is inside the quotes, so the shell never
sees it — it is a separator the script splits on, not a pipeline. Nothing
unquoted belongs on the line: no pipe, no redirect, no `tail`. The equivalent
hand-rolled `bash -lc "printf ... | sbcl --script loom.lisp | tail"` prompts
every time, because the pipe, the redirect and the `tail` each need permission
of their own, and a prompt inside a subagent is a stall nobody sees.

`impact` attaches the decisions and rules bearing on an entity. Read them before
contradicting them.

`describe` and `impact` report the tests that reach an entity, and an empty
`tests` band is an answer rather than a shrug: no case in the index calls it.
Both languages now feed it — fiveam tests here, and in a JavaScript tree the
vitest and jest cases, one entity per `it`/`test` named the way the runner
prints it (`stitchOsmImage > crops to the bbox AFTER compositing`). A case is
linked to a unit because its body, or a hook the runner runs for it, calls that
unit, so a test file that imports a module no case exercises draws no edge to
it. A definition in a test file is not a tested unit, which is why `status`'
`tested-units` fell on every Lisp tree when REQ-0053 landed. `status` also
reports `test-files` and `test-files-without-cases` — the second is a file the
runner would run that the analyzer recognised nothing in.

Loom has known blind spots — calls inside macro bodies are unattributed, so
anything driven by a `test` form under-reports. A call inside a body-swallowing
macro is the exception since DES-0014: a `define-operation` or `define-command`
body reaches its callee through a `:call-site` entity, an ambiguous name becomes
one reportable site with an edge to each candidate rather than a silent drop, and
`describe` on the callee lists both among its callers with their kind. DES-0001
records the rest. A small impact set is not proof of a small change.

A callable is identified by the symbol it names, not the string it spells
(DES-0015). Two same-named definitions in different packages are two callables,
and a call reaches whichever one its own package makes accessible — through an
`:import-from`, through a `:use` of a package that exports it, or by interning
its own. So `find` showing two entries for one name is usually two things, not a
duplicate. When the package cannot be worked out — the file's package `:use`s
something no declaration in the tree describes — Loom refuses to place the name
and falls back to matching on the spelling, which is the older and blunter
answer rather than a wrong one.
`loom-analyzer:*external-package-names*` is how you narrow that: naming a
library there lets its exports be read from the image and its inherited names
placed.

A malformed form costs a form rather than a file. The Lisp analyzer reads
through Eclector behind a Loom-owned client (DES-0013), so a file with damage
in it still yields its other definitions and the damage is recorded on the
`:file` entity with a line range. A repaired form is deliberately not indexed:
recovering an unterminated list can swallow the next definition into the
damaged one's body, and an entity minted from that would carry a plausible
range over text defining something else — CON-0001's fabricated fact in the one
shape no count would reveal. `status`' `unread` line sums what was passed over
(`#+`/`#-` branches not taken, a refused `#.`) and what was repaired; both read
zero on a healthy tree, and a number there is the index saying which
definitions it knows it is missing.

## Environment

Everything runs natively under WSL Ubuntu: the shell is Linux bash, `sbcl` is
`/usr/bin/sbcl`, and paths are plain Unix paths under
`/path/to/Loom`. There is no `wsl.exe` hop and no PowerShell — an
instruction anywhere that names either is stale, and the fix is to correct it
rather than to work around it. Files ending in `~` are Emacs backups — ignore
them.

Full suite, in a live image:

```lisp
(load "src/full-test.lisp")
(loom-test:full-test)      ; twelve systems, per-system summary
```

or `tools/loom-test.sh` from outside one — note that is `/usr/bin/sbcl`, not the
SBCL behind SLIME. Where the two could disagree, say which one you ran.

## Layering

    loom-utils      leaf utilities two systems that may not depend on each
                    other both need: the refusal condition, the event log and
                    its debugger hook, the scalar readers, whole-file reads,
                    path segments, plist filtering, the two waits. Depends on
                    nothing, and RULE-0009 checks it. loom-ontology does not
                    use it -- RULE-0001 would report the edge -- so what the
                    ontology shares lives in the ontology. REV-0002.
    loom-embed      the embedder protocol and its Ollama client, for semantic
                    seeding. A second leaf beside loom-utils. Depends on no
                    Loom system. loom-knowledge and loom-workspace use it.
    loom-ontology   entity and relationship declarations. Depends on nothing.
    loom-graph      the only writer. Transactions, queries, resolution, rules.
    loom-analyzer   path + contents -> operations. Never touches the graph.
    loom-docstore   documents behind a protocol: refs, addresses, versions,
                    text. Depends only on loom-utils (RULE-0010, RULE-0013 to
                    RULE-0021). loom-workspace is its only client;
                    loom-analyzer and loom-knowledge may not reach it
                    (RULE-0011, RULE-0012). Holds the file stamps. DES-0051.
    loom-knowledge  read-only services: find, describe, impact, context,
                    structure.
    loom-workspace  indexing pipeline, file monitor, and the write path:
                    document transitions, init, generated architecture. Depends
                    on loom-knowledge since DES-0022 S3 -- it renders that
                    system's structural report into a document.
    loom-process    the console.
    loom-serve      the operation registry, tiers, REPL sessions, the listener.
    loom-rest       HTTP/JSON over that registry.
    loom-mcp        MCP's JSON-RPC over the same listener.

The last four are peers, not a stack: loom-serve, loom-rest and loom-mcp depend
on the same five systems loom-process does and on nothing above loom-knowledge,
and nothing below any of them depends on any of them. DES-0006 R5 makes that
structural rather than a habit — console.lisp, loom.lisp, loom-process.asd and
src/process/package.lisp were unedited by all of it. REV-0002 edited all four,
and the direction is the whole difference: `log-event` and the debugger hook
moved *down* into loom-utils, which both peers reach, rather than one peer
reaching across to the other. `sbcl --script tools/test/load-test.lisp loom-serve`
is what says which of the two happened, and it still prints T.

A function belongs in loom-utils only when two systems that cannot depend on
each other both need it. When one caller's system already depends on the other's,
the shared home is that lower system -- twelve of REV-0002's twenty-two
duplications are that case and none of them moved here.

RULE-0001 to RULE-0003 enforce parts of this and are machine-checked. They do
not fail a FiveAM assertion, so run `check` as well as the suite — and note
that they cannot see the peer property above at all regardless: they key on
LOOM-GRAPH:ENTITY-SYSTEM, which reads the `:system` property the analyzer
wrote, and that property holds the file's own package name (DES-0009). It is
not a path guess: it was one until BUG-0006, when every file in the tree read
as system "src" and every layering rule matched nothing, and the segment after
`src/` for a while after that. `sbcl --script tools/test/load-test.lisp loom-serve`
is still the instrument for the peer property specifically; no rule names
loom-serve, loom-rest, loom-mcp or loom-process, so `check` has nothing to say
about them either way.

`check` reports **no violations** on this tree, and has since BUG-0009 closed
on 2026-08-15 — so a violation you see is a real one, not the standing noise
this file used to warn about. Getting there took both of BUG-0009's causes:
DES-0009's package-derived `:system` stopped classifying a test file into the
system it tests, and RULE-0003 moved to a fifth check kind, `:no-call-to`,
which names the loom-graph functions that *mutate* rather than banning every
call into loom-graph. Reading the graph is what loom-knowledge depends on it
for; only a write was ever forbidden. That deny list is only as current as its
`to-names:` — a mutator added to loom-graph is unreported until its name is
added to `docs/rules/RULE-0003.yaml`. One rule stays unenforceable as a check
and prints as such: RULE-0004.

A rule names one package by default. `from-family:`/`to-family:` name a family
instead — every system whose name is the family or begins with it followed by
`/` or `.`, so one rule covers every `app/*` package of a tree and
`to-system: outside` then means outside the *family* (DES-0024). No rule here
uses it: Loom's packages are dash-flat, and `-` is deliberately not a family
delimiter because it would rejoin every `loom-x` to its `loom-x-test` sibling
and re-open BUG-0009.

## Running it as a service

    sbcl --script loom-serve.lisp [/path/to/repo ...]              console + listener
    sbcl --script loom-serve.lisp --headless [/path/to/repo ...]   listener alone

Both bind 127.0.0.1:4780 and carry the REST routes under `/v1/` and the MCP
endpoint at `/mcp`. The first hands over the same `loom>` console `loom.lisp`
does; the second exists because `main` returns immediately when stdin is closed,
which under a supervisor would take the listener down with it. REQ-0008 and
DES-0006 are the reasoning.

**Install the unit and the `loom_*` tools stop depending on your timing.** The
host resolves MCP connections once when a session opens, so a service the
session's own first tool call starts has already missed the handshake and the
tools are gone for that session's whole length. A service that outlives
sessions is up before the next one opens:

    tools/loom-serve.sh install                   # writes the systemd user unit
    systemctl --user enable --now loom.service    # turn it on
    loginctl enable-linger $USER                  # optional: survive logout

`install` writes the unit and stops there — enabling changes what the machine
does with no session open. Once it is enabled, `start`, `stop`, `restart` and
`update` all hand the verb to systemd rather than spawning a second service
beside the supervised one, so `tools/loom-serve.sh` stays the thing to type
either way. REQ-0064.

A machine with several users runs one service, as a system unit under its own
account, because every user unit binds port 4780. `sudo tools/loom-serve.sh
install --system` writes it, and INSTALL.md, "A machine with several users",
gives the clone location, the shared Quicklisp and the git setting it needs.
That service answers every local user and runs their write operations, which
SECURITY.md says plainly. BUG-0074.

## Where the knowledge lives

Not here. This file is a pointer; the reasoning is in `docs/`, indexed and
cross-referenced. CON-0004 describes the workflow and how documents link.

    docs/requirements/  what is wanted           REQ-nnnn
    docs/design/        the shape of an answer   DES-nnnn
    docs/decisions/     decisions and rationale  DEC-nnnn
    docs/arch/          structure and mechanism  ARCH-nnnn
    docs/plans/         ordered steps            PLAN-nnnn
    docs/reviews/       review findings          REV-nnnn
    docs/bugs/          defects worth keeping    BUG-nnnn
    docs/concepts/      recurring ideas          CON-nnnn
    docs/rules/         constraints              RULE-nnnn

Loom's own documents are YAML, and writing one is still writing YAML. The
document analyzer claims `.yaml` and `.yml` under `docs/`, and the directory
names the type. `refines:` names the document a document answers, `affects:`
names the code a document bears on — every document type, not just decisions
(BUG-0023) — and both resolve against the index; a name that resolves to
nothing is reported by `check` rather than dropped. A decision's `affects:`
*governs* and becomes `:decides`; every other document's merely bears on its
target and becomes `:documents`.

Markdown is indexed too, by a separate analyzer, and it earns weaker edges on
purpose (REQ-0014, DES-0016). Since REQ-0028 a `.md`, `.markdown` or `.txt` file
is claimed **wherever the repository keeps it** — the directory-name allowlist
is gone, because it tested where a file lived rather than what it said and so
missed a 541-line `src/models/README.md`. Three exclusions remain: any
dot-directory (`.claude/`, `.windsurf/` — those instruct an assistant, not the
reader of the code), a `templates/` directory (text written to be copied
elsewhere describes the elsewhere), and `CLAUDE.md`/`AGENTS.md` by name. A
claimed file becomes a `:document` whose title is its first H1 — but never a REQ or a DEC, whatever its directory is
called, because that mapping is this tree's convention rather than a fact about
markdown. Its backticked identifiers and its relative link targets resolve into
`:mentions` edges: *this file names this thing*, and nothing more. A `:mentions`
is not an `affects:`, `impact` reports it under its own heading rather than
among the decisions governing an entity, and a token that resolves to nothing
is dropped in silence rather than counted as a rotten reference — prose is full
of ordinary words in backticks.

`:mentions` is where every prose mention now lands, including the ones the YAML
analyzer finds in a document's own body. They used to be `:documents` edges.
`impact`'s `documents:` line carries the declared kind instead — a requirement's,
plan's or bug's `affects:`, and an architecture document's `describes:` — which
it did not until BUG-0023 made `affects:` readable from every document type, so
a claim that the line is empty on this tree is out of date rather than honest.

`context` bands the same three ways `impact` does (REQ-0026, DES-0020) and says
which band each entry is in: what the task named, decisions governing it,
documents bearing on it, prose that names it, and one hop away. The bands are
assigned by the edge a document arrived on rather than by its type, because
`:document` is what REQ, PLAN, BUG and REV land on *and* what every markdown
file is — so the type cannot tell a declared `affects:` from a backtick, and the
edge can. Prose is ranked by how much of the bundle it actually names and capped
at `loom-knowledge:*context-mention-limit*`.

## Writing a document, a docstring or a commit message

Every sentence carries a fact the reader can check. Four tests, each from a real
failure in this tree:

- **A title names the contents.** "DES-0026 in seven steps: the walk, the tiers,
  the index, the ranking", not "Reach it first, then say why, then hold it
  cheaply, then stop guessing at rarity". A title that cannot be checked against
  the document is decoration.

- **The subject is the subject matter, never the document.** Cut "Worth stating,
  because...", "This is the part to get right", "...comes later on purpose".
  Each announces that a claim has status instead of making it. If the reason is
  known it belongs in that sentence; if it is not, the sentence should not exist.

- **A number needs no adjective.** "S4 through S6 are last because query latency
  is 0.01-0.06s", not "...because the index recovers no latency: every query
  already answers in 0.01-0.06s". Giving the characterisation and then the
  measurement says it twice.

- **Replace a metaphor with the measurement it stands for.** Not "the constraint
  moved from reach to budget" but "all ten are reachable; the neighbour band
  printed 2 of 157 before the budget ran out".

Prefer two short declarative sentences to one clause-laden one. These documents
are read later as the record of a decision, so a sentence nobody can check is
worse than no sentence.

## Principles worth knowing before changing anything

- **A generated invariant is a defect.** `init` prepares a foreign tree and
  `architecture` writes an ARCH document into it from the index — and that
  document's invariants section is empty and says so. Code being consistent
  with an invariant is not evidence anybody intended it, and a violation is not
  evidence they did not. What a generator may write is what was measured;
  what must remain true is the half only a human can supply. REQ-0021 R6.
- **Files are truth.** The graph is an index over them and can be discarded and
  rebuilt. Anything Loom knows that is not derivable from files must be written
  back to files, or it is not knowledge. DEC-0001.
- **A fabricated fact is worse than a recorded gap.** An ambiguous name stays
  unresolved and gets reported. CON-0001.
- **Derive, never consume.** A resolution pass that rewrites its own input
  cannot be re-run, so an edge destroyed by a retract never returns. DEC-0003.
- **Guard with the condition type the library actually signals.** `error` does
  not catch a condition defined as a direct subtype of `condition`. RULE-0004.
- **A test must fail without the change it covers.** CON-0003.
- **An instrument brings the service up itself.** `tools/test/acceptance.py`,
  `tools/test/recall.py` and `tools/test/seed-sheet.py` score answers read over REST, and
  each opens by calling `tools/test/service.py`'s `ensure`: it runs
  `tools/loom-serve.sh update`, waits for every tree it names to reach `ready`
  — a repository still `embedding` answers lexically, so its recall measures
  half the seeder — and exits with a sentence rather than print a figure against
  a service it could not reach. `tools/loom.sh` is not the driver for this: it
  reindexes every tree it names on every call and builds no vector store, which
  a harness making 450 calls would pay 450 times. RULE-0008.
- **An analyzer asserts each natural key at most once per file.** Two source
  definitions deriving one key are reconciled by the analyzer, in its own
  language's semantics — CL replaces, TypeScript merges — because the writer is
  language-neutral and by the time it sees the ops the evidence is gone.
  Nothing checks this. CON-0005.
- **Finishing a plan is a command, not a chore you remember.** A plan reaching
  `final` makes the `draft` status of every document it refines false, so
  `complete` sets both and moves the files:

      tools/loom.sh 'complete PLAN-0019'      # writes nothing; shows what it needs
      tools/loom.sh 'complete PLAN-0019 DES-0019=implemented REQ-0022=implemented'

  It walks upward while the verdicts stay terminal, refuses to touch a document
  another unfinished plan still refines, and files each moved document in
  `completed/`. It will not guess `implemented` versus `partial` — that is a
  judgement about intent, and a partial needs an OUTSTANDING section. Dry run is
  the default, so a `complete` with no verdicts has done nothing.
  `set-status <doc> <status>` is the same write path for one document.
  REQ-0022 and DES-0019; CON-0004 for the status vocabulary. RULE-0005 and
  RULE-0007 are retired to advisory — they describe the invariant, the command
  maintains it.
