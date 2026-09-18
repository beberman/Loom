---
name: loom
description: How to build, test, and query Loom — the SBCL invocation, the full test suite, the console commands, and the document conventions. Use whenever you need to run Loom, run its tests, ask its index a question, or write a document into docs/. Covers "run the tests", "how do I start Loom", "what does impact say about X", "where is Y defined", and any task touching docs/*.yaml.
---

# Running Loom

Loom is a Common Lisp knowledge engine. It runs natively under **WSL Ubuntu**:
the shell is Linux bash, `sbcl` is `/usr/bin/sbcl`, and the tree is
`/home/beberman/lisp/Loom`. This file is the authoritative copy of the
invocation — CLAUDE.md and the agent definitions point here rather than
restating it, because five copies of it went stale twice.

## Do not rediscover any of this

Every invocation below is known to work. If something fails, the cause is
almost certainly a real problem rather than a wrong incantation.

## Two ways in, and the fast one first

**MCP.** `.mcp.json` registers the running service, so `loom_*` tools may be in
your tool list already:

    loom_find  loom_describe  loom_impact  loom_context  loom_status
    loom_check  loom_rules  loom_structure  loom_drift
    loom_set_status  loom_complete  loom_repl_open/eval/close

Each takes a `repository` argument — the service holds several and refuses to
guess, because an answer about the wrong tree is worse than none. `loom_find`
is the exception since REQ-0051: `repository` is optional there, and without it
every watched tree is searched, because *which of them owns this name* is a
question no single tree can answer. They run
against a resident, file-watching index: an `impact` measured at 22ms where the
script takes minutes, since the script reindexes the whole tree before it can
answer.

Three caveats, all real:

- The registration needs a **Claude Code restart**. A session that began before
  `.mcp.json` existed will not have the tools; look at your own list.
- The service runs **the code it was started with**. After changing Loom's
  source, `tools/loom-serve.sh update` — it restarts only when something
  actually changed.
- `loom_init`, `loom_remove` and `loom_architecture` are deliberately **not**
  MCP tools. They prepare, describe or dismantle a repository and are driven by
  `tools/loom-init.sh`, where a terminal can ask the consent REQ-0021 R16
  requires. REST carries them for that script.

**The console.** Always works, needs no service, and is the answer whenever the
tools are absent. Drive it through `tools/loom.sh` **using the Bash tool**, which takes a whole
console session as one quoted argument, watches the tree before the first
command and stops after the last, and filters compile chatter:

```bash
tools/loom.sh 'status | impact repository 3'
```

Commands are separated by `|` and run in order. The `|` sits inside the quotes,
so the shell never sees it — it is a separator the script splits on, not a
pipeline. The older form, one command per argument
(`tools/loom.sh 'status' 'impact repository 3'`), still works and the two mix;
each argument is split on `|` in turn. The script `cd`s to the tree itself, so
it works from any directory and the absolute form
`/home/beberman/lisp/Loom/tools/loom.sh` is equivalent.

`.claude/settings.json` carries a PreToolUse hook, `tools/allow-loom.py`, that
decides this script's permission directly. It is needed because Claude Code's
Bash matcher splits a command on shell operators before matching it, and does
that even inside single quotes, so `Bash(tools/loom.sh:*)` alone prompts on
every `|`-separated session. The hook allows only a driver script followed by
single-quoted arguments; anything else falls through to the normal prompt.

**Do not hand-roll the pipeline.** `bash -lc "printf ... | sbcl --script
loom.lisp | tail"` needs permission for the pipe, the redirect and the `tail`
separately, and a nested `bash -lc "..."` is opaque to the permission matcher,
so it prompts on every variation. A prompt inside a subagent is a stall nobody
sees. `tools/loom.sh` is allowlisted precisely so none of that is needed.

For an interactive session a human drives:

```bash
cd ~/lisp/Loom && sbcl --script loom.lisp
```

The commands, at the `loom>` prompt or as `loom.sh` arguments:

```
@<name> <command> ...     name the repository a command acts on. A leading
                          @token is stripped by the dispatcher, so it works on
                          every command including the variadic ones:
                          `impact @game-server dhandler-delete 3`,
                          `context @front-end soft delete read path`. It lasts
                          one command -- there is no selected-repository mode
                          to forget. With one repository watched, nothing has
                          to be typed.
help [command]            the authoritative table; trust it over this list
watch "~/lisp/Loom"       register, index, and watch. Resumes a paused repo.
pause                     stop watching, keep the index
unwatch                   stop watching, drop the index
reindex                   discard and rebuild from disk. Always safe.
status                    counts, watcher state, unresolved references, and
                          the `unread` line: source the reader passed over or
                          had to repair. Both read zero on a healthy tree.
find <name> [<type>] [--code|--documentation]
                          where something is defined, in every watched tree.
                          The flag narrows to code or to documents: `repository'
                          names 232 entities on this tree and most callers want
                          one family. It matches NAMES -- for documents ABOUT a
                          subject, ask `context'.
                          unless a leading @token names one. Each row is
                          prefixed with the tree it came from. Naming a tree and
                          finding nothing there prints what the others hold --
                          `0 here; 1 in utils' -- and a name in no tree at all
                          is dead. Any tree it could not search is named, so
                          "absent everywhere" is never a partial search's
                          claim. REQ-0051.
describe <name>           neighbours grouped by edge type
impact <name> [<depth>]   what a change reaches, plus governing decisions
context <task words>      a budgeted bundle: what to know before editing
rules                     constraints; [prose only] means unenforced
check                     rule violations and unresolved doc references
structure                 systems, the edges between them, protocols, entry
                          points and hubs — all derived, and it names neither
                          direction of a cycle wrong
init "<dir>" [docs] [claude-md] [host:port]
                          prepare a repository Loom did not write: directories,
                          conventions, the skill, a manifest. `claude-md` is the
                          second consent — without it an existing CLAUDE.md is
                          left alone
architecture              write an ARCH document from the index into a prepared
                          tree. Invariants section empty on purpose
set-status <doc> <status> set one document's status and file it where that
                          status belongs — into completed/ when terminal, back
                          out when not. One line changed, one rename, nothing
                          else in the file touched.
complete <plan> [<doc>=<status> ...]
                          set a plan final and restate every document it
                          implements. With no verdicts it writes nothing and
                          shows what it would need.
enrich [repo]             load the tree in a bounded child and add what its own
                          toolchain knows: macro-generated definitions, calls
                          xref sees and the text walk does not
log [n]                   recent events and errors
stop                      pause everything and leave
```

**A malformed form costs a form, not a file.** The Lisp analyzer reads through
Eclector behind a Loom-owned client (DES-0013), which recovers: a file with a
stray paren or an unbalanced list in it still yields its other definitions, and
the damage is recorded on the `:file` entity as a `:recovered-regions` entry
with a line range. A repaired form is deliberately *not* indexed — recovering
an unterminated list can swallow the next definition whole into the damaged
one's body, and an entity minted from that would carry a plausible range over
text defining something else. So the definitions in a damaged region are a
recorded gap, never a guess (CON-0001). `:analysis-failed-p`, and the single
unparsable `:file` entity that goes with it, now means only what it always
should have: the file could not be read at all.

**A call with nowhere to go is an entity, not a drop.** An ambiguous name, a
call in a body-swallowing macro's body such as `define-operation`'s, and a
function designated in an initform each mint a `:call-site` (DES-0014) rather
than being discarded, so `describe` on the callee lists them among its callers
with their kind — `<- calls: violation-summary@src/serve/operations.lisp:186
(definer-call)`.

**A name is resolved as a symbol, not as a string** (DES-0015). Two definitions
spelled alike in different packages are two callables, and a call reaches the one
its own package makes accessible — imported, inherited through a `:use` of a
package that exports it, or interned locally. So two `find` hits for one name are
usually two things rather than a duplicate. Where the package cannot be
determined, because the file's package uses a library the tree does not declare,
Loom says so by falling back to matching on the spelling rather than guessing;
`loom-analyzer:*external-package-names*` is how a library's exports get read from
the image so its inherited names can be placed.

`:suppressed-regions` is the same idea for source the reader passed over rather
than repaired — a `#+`/`#-` branch the feature policy did not take, or a `#.`
it refused to evaluate. Comments are not in it; they are what a source file is
made of, not a gap in what Loom knows. `status`' `unread` line sums both.

**Start with `context`.** It is the command written for exactly this job and the
one most easily missed. Given a task in words it returns a token-budgeted bundle
of the entities that matter, edges already attached — the answer to "what should
I read before editing", in one call:

```bash
tools/loom.sh 'context macro definitions'
```

    # Context for: macro definitions
    # 12 entities, ~862/2000 tokens
    function make-macro-entity  [src/analyzer/lisp-analyzer.lisp:297-310]
        -> calls properties-table
        <- calls analyze-file
    ...

`find` then narrows, and `describe` and `impact` go deep on one name.

`enrich` is optional, runs on explicit demand only -- never from the monitor,
never from `watch` -- and ages itself out through RETRACT-FILE, so an index
nobody has re-enriched gives today's text answer rather than yesterday's image
answer. DES-0011 is the design.

`impact` takes an optional depth. **The default is 5, not 3** — every example
here and in CLAUDE.md passes an explicit `3`, which is a choice rather than a
restatement of the default. Two known defects in it, both specified as REQ-0005:
the `d<n>` label on a row can exceed the depth you asked for, because the
one-step relationship types are applied after traversal — `impact x 1` returns
`d2` rows — so the number after `d` is not the number you asked about; and
`(truncated)` is a boolean, so it cannot tell you whether two entities were cut
or two hundred.

Three things to know before trusting a `find`:

- it matches **substrings**, so `find test` returns anything containing "test";
- it caps at 20 hits and **does not say it truncated**, unlike `impact`, which
  prints `(truncated)`;
- the optional type argument narrows it, but there is no way to list every
  entity of a type. `find "" test` does not do it — the empty term is dropped
  and `test` becomes the term.

`describe` on a document prints type, doc-id, title, status, and a summary
bounded to 120 tokens (marked `truncated` if the document's own `summary:`
ran over), then the edges — bounded output regardless of document length, per
REQ-0007. The full body is not printed; read the file with Read if you want
the text describe deliberately leaves out.

## Running it as a service

    sbcl --script loom-serve.lisp [/path/to/repo ...]              console + listener
    sbcl --script loom-serve.lisp --headless [/path/to/repo ...]   listener alone

An addition, not a replacement — `tools/loom.sh` and the console above are
unchanged and still how an agent in this tree reaches Loom (`.claude/agents/
tools.md` says so explicitly). This runs Loom as a standing process reachable
over REST (`/v1/...`) and MCP (`/mcp`) on `127.0.0.1:4780`, for a caller that
needs one resident graph shared across many requests instead of a fresh index
per call. REQ-0008 and DES-0006 are the design; CLAUDE.md's own "Running it
as a service" section is the other copy of this table.

Do not run either invocation by hand. `tools/loom-serve.sh` owns the lifecycle,
and it is what the allowlist and the SessionStart hook both name:

```bash
tools/loom-serve.sh status     running? and is its loaded code current
tools/loom-serve.sh start      spawn it headless and detached
tools/loom-serve.sh stop       SIGTERM it and wait for it to go
tools/loom-serve.sh restart    stop, then start
tools/loom-serve.sh reload     stop, then start (an alias for restart)
tools/loom-serve.sh update     start / restart / nothing, whichever applies
tools/loom-serve.sh install    write the systemd user unit (does not enable it)
```

`install` is the one to run once rather than per session. A service started by
a session's first tool call has already missed the MCP handshake, so the
`loom_*` tools are unavailable for that whole session however healthy the
endpoint is — installing the unit and enabling it removes the race instead of
narrowing it. Once enabled, every verb above delegates to systemd rather than
spawning a second service beside the supervised one. REQ-0064.

`update` is the one verb worth reaching for. It pays a restart's cost only when
something actually changed — a no-op in ~30ms on the common case, a ~4.5s
restart when the tree has moved, and a start when nothing is up. There is no
in-place reload any more: DES-0008 removed it, because reloading nine systems
under live request threads produced a reproducible 500 (BUG-0008), and a restart
was already measured at the same cost. DES-0007 is the rest of the design; the
two files it tracks live under `/tmp`, named from the watched root
(`/tmp/loom-serve-home-beberman-lisp-Loom.{pid,log}`), so a second checkout
never collides with this one.

A `SessionStart` hook in `.claude/settings.json` runs `update` before the
session's first tool call, which is what makes the MCP surface reachable at
all: Claude Code's `initialize`/`tools/list` handshake runs once and early, and
a service that was down when it ran offers no `loom_*` tools for the rest of
the session. **What the hook does not cover, and the one manual fallback:** an
edit landing *after* the hook has run is invisible to the running image until
someone says so. If an MCP or REST call fails mid-session, or answers against
code you know you just changed, run `tools/loom-serve.sh update` and retry.
`tools/loom.sh` never has this problem — it keeps no state to go stale.

## The test suite

Also the Bash tool:

```bash
tools/loom-test.sh        # summary only
tools/loom-test.sh -v     # with compile output
```

Twelve systems, per-system pass/fail summary: the original six (ontology,
analyzer, graph, workspace, knowledge, process), loom-serve, loom-rest and
loom-mcp from PLAN-0005, the two leaves loom-utils and loom-embed, and
loom-docstore from PLAN-0055. Note this is `/usr/bin/sbcl`, not the SBCL
behind SLIME; where the two could disagree, say which one you ran.

The script writes and runs this driver, which is also the preamble any one-off
script needs:

```lisp
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((here #p"/home/beberman/lisp/Loom/"))
  (dolist (system '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/"
                    "docstore/" "workspace/" "process/" "serve/" "rest/" "mcp/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid") :silent t))
(load "/home/beberman/lisp/Loom/src/full-test.lisp")
(funcall (read-from-string "loom-test:full-test"))
```

`hunchentoot` and `cl-json`, which loom-serve/rest/mcp depend on, are not in
that explicit quickload list and do not need to be: once quicklisp/setup.lisp
is loaded, `asdf:load-system` resolves a system's own `:depends-on` through
quicklisp automatically, and `loom-test:full-test` loads all twelve systems by
name. The explicit list above is only for libraries no `.asd` in the tree
names as a dependency.


**Run `check` in the console as well.** RULE-0001 to RULE-0003 are enforced by
the rule engine, not by assertions, so a green suite says nothing about them.

## A one-off script

Any script needs the registry preamble above — the first eleven lines. Then
`(asdf:load-system :loom-process)` and whatever you want to run. Write it to
`/tmp` and run it the same way.

## Read files with the Read tool

Never `cat`, `head`, `grep` or loop over files in a shell to read them. Use
Read, Glob and Grep. A shell loop such as

```bash
for f in RULE-0001 RULE-0002; do cat docs/rules/$f.yaml; done   # prompts
```

trips a permission prompt on the compound command whatever the allowlist says,
and in a subagent that prompt is an invisible stall. Four Read calls in one
message are faster and never prompt.

## Things that will bite

- **The SBCL behind SLIME may not be `/usr/bin/sbcl`.** They have disagreed on
  implementation-defined behaviour before, and a green run under one is weak
  evidence about the other. Where it matters, say which you ran.
- **Files ending in `~` are Emacs backups.** Ignore them. Files beginning with
  `.#` are Emacs lock symlinks and are skipped by the indexer.
- **The indexer skips what git ignores** (DES-0018). It asks
  `git check-ignore` once per pass rather than interpreting `.gitignore`
  itself, so `node_modules`, `dist`, `coverage` and anything else the
  repository excludes contributes nothing — but a *tracked* file stays indexed
  even when it matches a pattern, because git consults the index and a
  committed file is part of the repository. A directory that is not a git
  repository is indexed whole, and `status` prints an `ignores :` line saying
  git could not be consulted. Measured on `~/github/front-end`: 27 documents
  instead of 421.
- **Compile output goes to stdout**, so grep it away rather than reading it.
- **A running loom-serve goes stale mid-session and nothing tells you.** The
  SessionStart hook makes it current once, at the start; every edit after that
  is invisible to the resident image until `tools/loom-serve.sh update` runs
  again. DES-0007 names this as accepted rather than solved.
- **The pidfile check under `tools/loom-serve.sh` is Linux-specific.** It reads
  `/proc/<pid>/cmdline` to tell loom-serve from whatever the OS may have
  recycled that pid to, which matches WSL Ubuntu and nothing else.
- **Bringing the service up to date loses any repository added at runtime.** A
  restart re-watches only this tree's root and whatever was on the command line,
  so a repository an agent added through `watch` is gone. That was already true
  of `restart` and `stop`; after DES-0008 it is true of `update` and `reload`
  as well, because every path that changes running code is a fresh process.

# Writing documents

Documents you write live in `docs/` as **YAML** — the document analyzer claims
`.yaml` and `.yml` under `docs/`, and the directory names the type. Write YAML;
a markdown file is indexed (see below) but it can never be a REQ, an ARCH or a
DEC, so a plan written as markdown is a plan Loom cannot chain.

    docs/requirements/  REQ-nnnn      docs/plans/     PLAN-nnnn
    docs/design/        DES-nnnn      docs/reviews/   REV-nnnn
    docs/decisions/     DEC-nnnn      docs/bugs/      BUG-nnnn
    docs/arch/          ARCH-nnnn     docs/rules/     RULE-nnnn
    docs/concepts/      CON-nnnn

CON-0004 holds the full conventions and the reasoning. The fields that resolve:

- `refines: [REQ-0002]` — the document this one answers. Becomes a `:refines`
  edge, so `impact REQ-0002` reports what came of it.
- `describes: [function-name]` — **ARCH only**: the code whose structure the
  document describes. Becomes a `:documents` edge. An architecture document has
  no `affects:` — it describes, it does not govern, and writing `affects:` in
  one is read by nothing on purpose.
- `invariants: |` — **ARCH only**: what must remain true, as prose. The field
  that most distinguishes the genre — a DES records what was chosen, an ARCH
  records what may not be broken.
- `affects: [function-name]` — code the document bears on. Read from **every**
  document type, not just decisions (BUG-0023 — it used to be decisions only,
  and 63 of 67 documents were declaring this into a void). What the claim means
  depends on who makes it: a decision *governs* what it affects and earns a
  `:decides` edge, so `impact` reports it under `decisions:`; a requirement,
  plan, bug or review merely *bears on* it and earns `:documents`.
- `applies-to: [function-name]` — code a rule constrains.

A name in any of those that resolves to nothing is reported by `check` rather
than dropped. That is the staleness detector, so fill them in accurately.

Two mistakes have each already cost a document its place in the index:

- **An unindented block scalar.** Content under `summary: |` must be indented.
- **A duplicated `id:`.** Two documents with one id are ambiguous to every
  reference naming it.

After writing, run `status` and confirm the document count rose and
`unresolved` did not.

## Finishing work: `complete`, not a status you remember to edit

A plan reaching `final` makes the `draft` status of every document it refines
false, and a false status is worse than none — the next agent believes it. That
transition used to be RULE-0005, a rule nobody could check because `check`
inspects a state and the rule describes an event. It is now a command:

```bash
tools/loom.sh 'complete PLAN-0019'
```

writes nothing and prints the chain with the verdicts it still needs:

```
  PLAN-0019      plans          draft       -> final
  DES-0019       design         draft       -> ?            needs a verdict
  REQ-0022       requirements   draft       -> ?            needs a verdict
  CON-0004       concepts       -           -               no status field -- the walk stops here
To apply: complete PLAN-0019 DES-0019=<status> REQ-0022=<status>
```

Then supply them. What the command does and does not do:

- **The verdict is yours.** `implemented` means every requirement the document
  states is now true; `partial` means some landed and the document gains an
  OUTSTANDING section naming what did not. Nothing derives that, and a command
  that guessed would write a false claim into a file and then index it.
- **It walks upward, but only through a terminal verdict.** A `partial` design
  stops the climb, because the requirement above it is not implemented either.
- **It refuses a document another unfinished plan still refines**, and names the
  plan in the way. That query is the reason the command exists — it is the one
  a human closing a long change will not run.
- **All or nothing.** Give a verdict for every document it asks about, or it
  writes none of them. It also refuses whole rather than one problem at a time.
- **The file moves too.** A terminal status files the document under
  `completed/`, and a status that stops being terminal moves it back out, so
  placement and `status:` cannot drift apart. That was RULE-0007.
- **It does not commit.** The tree is left dirty, which is what you want from a
  command that just edited your documents.

`set-status <doc> <status>` is the same write path for one document, with no
propagation query — the way to accept a requirement, close a bug, retire a rule,
or override a block you have looked at. Both are also `/v1/set-status` and
`/v1/complete` over REST, and `loom_set_status` and `loom_complete` over MCP,
which is how an agent working outside this tree reaches them.

## Markdown is indexed, and earns a weaker edge

REQ-0014, DES-0016, and REQ-0028 which widened it. A separate analyzer claims
`.md`, `.markdown` and `.txt` **anywhere the repository keeps them**, root
README included. Excluded: any dot-directory (`.claude/`, `.windsurf/` instruct
an assistant rather than describe the code), a `templates/` directory, and
`CLAUDE.md`/`AGENTS.md` by name. What a document is worth is measured by how
much of its vocabulary resolves — `drift` reports it — rather than assumed from
where it sits. Each file becomes a
`:document` named by its path, titled by its first H1 (the filename when there
is none), always a plain `:document`: a markdown file in `docs/design` is *not*
a DES, because the directory-names-the-type registry is this tree's convention
and not a fact about foreign repositories.

What it extracts is deliberately shallow — no summarizing, no inference:

- **Inline code spans.** `` `dhandler-delete` `` is a candidate; a span with a
  space in it is a phrase, not a name, and is not.
- **Link and image targets**, normalized against the document's own directory,
  so `[h](../media/media-handler.lisp)` in `docs/data-layer.md` becomes
  `media/media-handler.lisp` and resolves against the `:file` entity.
- **Fenced code blocks are skipped entirely.** A fence is a transcript or a
  specimen, not the document naming something.

Each candidate that resolves becomes a `:mentions` edge — *this file names this
thing*, which is not the `affects:` a YAML document earns by declaring it.
`impact` lists mentions under their own heading, never among the decisions
governing an entity, and `describe` gives them their own group. A candidate that
resolves to nothing, or that is ambiguous, is dropped in silence: prose is full
of ordinary words in backticks, and reporting each as an unresolved reference
would bury the staleness signal that `unresolved` exists to carry.

`:mentions` is also where the YAML analyzer's own prose mentions land now. They
were `:documents` edges until REQ-0014, so `impact`'s `documents:` line is empty
on this tree and a `mentions:` line carries what it used to.

There is nothing to register any more: the directory name was never the
question, so `*documentation-directories*` and its registration function are
gone. A repository keeping prose under `handbook/`, `adr/` or beside its source
is claimed without anybody configuring anything.
