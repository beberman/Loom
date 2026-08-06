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

## The console

Drive it through `tools/loom.sh` **using the Bash tool**, which takes a whole
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
help [command]            the authoritative table; trust it over this list
watch "~/lisp/Loom"       register, index, and watch. Resumes a paused repo.
pause                     stop watching, keep the index
unwatch                   stop watching, drop the index
reindex                   discard and rebuild from disk. Always safe.
status                    counts, watcher state, unresolved references
find <name> [<type>]      where something is defined
describe <name>           neighbours grouped by edge type
impact <name> [<depth>]   what a change reaches, plus governing decisions
context <task words>      a budgeted bundle: what to know before editing
rules                     constraints; [prose only] means unenforced
check                     rule violations and unresolved doc references
log [n]                   recent events and errors
stop                      pause everything and leave
```

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
per call. REQ-0008 and ARCH-0006 are the design; CLAUDE.md's own "Running it
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
```

`update` is the one verb worth reaching for. It pays a restart's cost only when
something actually changed — a no-op in ~30ms on the common case, a ~4.5s
restart when the tree has moved, and a start when nothing is up. There is no
in-place reload any more: ARCH-0008 removed it, because reloading nine systems
under live request threads produced a reproducible 500 (BUG-0008), and a restart
was already measured at the same cost. ARCH-0007 is the rest of the design; the
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

Nine systems, per-system pass/fail summary — the original six (ontology,
analyzer, graph, workspace, knowledge, process) plus loom-serve, loom-rest and
loom-mcp, added by PLAN-0005. Note this is `/usr/bin/sbcl`, not the SBCL
behind SLIME; where the two could disagree, say which one you ran.

The script writes and runs this driver, which is also the preamble any one-off
script needs:

```lisp
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((here #p"/home/beberman/lisp/Loom/"))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "process/" "serve/" "rest/" "mcp/"))
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
quicklisp automatically, and `loom-test:full-test` loads all nine systems by
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
- **Compile output goes to stdout**, so grep it away rather than reading it.
- **A running loom-serve goes stale mid-session and nothing tells you.** The
  SessionStart hook makes it current once, at the start; every edit after that
  is invisible to the resident image until `tools/loom-serve.sh update` runs
  again. ARCH-0007 names this as accepted rather than solved.
- **The pidfile check under `tools/loom-serve.sh` is Linux-specific.** It reads
  `/proc/<pid>/cmdline` to tell loom-serve from whatever the OS may have
  recycled that pid to, which matches WSL Ubuntu and nothing else.
- **Bringing the service up to date loses any repository added at runtime.** A
  restart re-watches only this tree's root and whatever was on the command line,
  so a repository an agent added through `watch` is gone. That was already true
  of `restart` and `stop`; after ARCH-0008 it is true of `update` and `reload`
  as well, because every path that changes running code is a fresh process.

# Writing documents

Documents live in `docs/` as **YAML** — the analyzer claims `.yaml` and `.yml`
under `docs/` and nothing else, so a markdown file there is invisible to Loom.
The directory names the type:

    docs/requirements/  REQ-nnnn      docs/plans/     PLAN-nnnn
    docs/arch/          ARCH-nnnn     docs/reviews/   REV-nnnn
    docs/design/        DEC-nnnn      docs/bugs/      BUG-nnnn
    docs/concepts/      CON-nnnn      docs/rules/     RULE-nnnn

CON-0004 holds the full conventions and the reasoning. The fields that resolve:

- `refines: [REQ-0002]` — the document this one answers. Becomes a `:refines`
  edge, so `impact REQ-0002` reports what came of it.
- `affects: [function-name]` — code a decision governs.
- `applies-to: [function-name]` — code a rule constrains.

A name in any of those that resolves to nothing is reported by `check` rather
than dropped. That is the staleness detector, so fill them in accurately.

Two mistakes have each already cost a document its place in the index:

- **An unindented block scalar.** Content under `summary: |` must be indented.
- **A duplicated `id:`.** Two documents with one id are ambiguous to every
  reference naming it.

After writing, run `status` and confirm the document count rose and
`unresolved` did not.
