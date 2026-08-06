# Reaching Loom

The single copy of "how an agent in this directory reaches Loom" — the Bash
invocation, the Read-tool discipline, the command table, and the layering.
Every file in `.claude/agents/` points here instead of restating it, because
five separately drifting copies is worse than one: PLAN-0005 found the same
few paragraphs repeated, slightly differently, in all five, and the fix is
this file, not a sixth copy done more carefully.

This is not a replacement for the **loom** skill, which every agent invokes
first and which is the authoritative build/test/console reference. This file
is shorter and role-agnostic: the part every agent definition needed and
restated, not the part any one of them needed in full.

## Query the console through the Bash tool

`tools/loom.sh` takes a whole console session as one quoted argument, `cd`s to
the tree itself, watches before the first command and stops after the last:

    tools/loom.sh 'context <task words>' 'check'

Several commands separated by `|` inside the quotes run in order — that `|`
is a separator the script splits on, not a shell pipeline, so the shell never
sees it. **Do not add a real pipe, a redirect, or `tail`.** Each needs its own
permission on top of the script's own, and a permission prompt inside a
subagent is a stall nobody sees; `tools/allow-loom.py` allowlists exactly the
quoted form so none of that is needed.

`help` prints the authoritative command table; trust it over the list below.

    context <task words>   start here: a budgeted bundle of what bears on a
                           task, with edges already attached
    find <name>             where something is defined
    describe <name>         neighbours, grouped by edge type
    impact <name> [depth]   what a change reaches, plus governing decisions
                            (the default depth is 5, not 3 — name the depth
                            explicitly if you mean something else)
    rules                   constraints; "[prose only]" means unenforced
    check                   rule violations and unresolved document references

`impact` attaches the decisions and rules bearing on an entity. Read those
before proposing or writing anything that contradicts one; to overturn a
decision, say so and write one that supersedes it, rather than quietly
disagreeing with it in code.

## Read files with the Read tool

Never `cat`, `head`, `grep`, or a shell loop over several files to read them —
the compound command trips a permission prompt regardless of what the
allowlist says, and inside a subagent that prompt is an invisible stall.
Several Read calls in one message are faster and silent.

## Loom under-reports where it is blind

ARCH-0001 records the analyzer's known gaps, the one worth carrying into every
task: calls made inside a macro body — which includes every `test` or
`def-suite` form — are unattributed. A small `impact` set is evidence of a
small change only once you've ruled out that it is instead evidence of a blind
spot.

## The layering, and what is and is not machine-checked

    loom-ontology   entity and relationship declarations. Depends on nothing.
    loom-graph      the only writer. Transactions, queries, resolution, rules.
    loom-analyzer   path + contents -> ontology operations. Never touches the graph.
    loom-knowledge  read-only services: find, describe, impact, context.
    loom-workspace  indexing pipeline and the file monitor.
    loom-process    the console.
    loom-serve      the operation registry, tiers, REPL sessions, the listener.
    loom-rest       HTTP/JSON over that registry.
    loom-mcp        MCP's JSON-RPC over the same listener.

The last three are peers of loom-process, not a layer stacked on it: none of
them is depended on by anything below loom-knowledge, and nothing below any of
them depends on any of them. CLAUDE.md's Layering section is the authoritative
copy of this table and the reasoning behind it; this repeats only the shape.

RULE-0001 to RULE-0003 exist to enforce parts of this and run through `check`,
not a FiveAM assertion, so a green suite alone has never said anything about
them. BUG-0006 (closed) found the function the three rules key on classified
every source file as `:src` and never as `:ontology`, `:analyzer` or
`:knowledge`, so all three passed vacuously regardless of what the code
actually did; that is fixed, and RULE-0001's own count is now real. RULE-0002
and RULE-0003 are not yet trustworthy the other direction: BUG-0009 (open)
found `check` now reports 72 false-positive violations of those two, from a
test file resolving to the same system as the code it tests and from
RULE-0003's check clause banning every call into loom-graph rather than only a
write. Read a RULE-0001 line from `check` as real; read a RULE-0002 or
RULE-0003 line as BUG-0009 until it closes. None of the three ever verifies
the peer property above — no rule names loom-serve, loom-rest, loom-mcp or
loom-process — so verify that one by reading the relevant `.asd`'s
`:depends-on`, or for a new system, with `tools/load-test.lisp`, which loads
it into a fresh image and checks who is and is not present — not with `check`.

## Loom is also a standing service

`loom-serve.lisp` runs Loom as a long-lived process reachable over REST
(`/v1/...`) and MCP (`/mcp`), alongside the console — REQ-0008 and ARCH-0006
are the design, and CLAUDE.md's "Running it as a service" section has the
invocation. `tools/loom.sh` still drives the console, still pays a cold reindex
per call, and is still the correct tool for the queries above; the service is
for a caller that needs one resident graph shared across many requests, and
this section is additive to `tools/loom.sh` rather than a replacement for it.

Its lifecycle belongs to one script, `tools/loom-serve.sh`, which ARCH-0007
adds beside `loom.sh` and which the allowlist and the SessionStart hook both
name. Never start or stop the service by hand:

    tools/loom-serve.sh status     running? and is its loaded code current
    tools/loom-serve.sh start      spawn it headless and detached
    tools/loom-serve.sh stop       SIGTERM it and wait for it to go
    tools/loom-serve.sh restart    stop, then start
    tools/loom-serve.sh reload     stop, then start (an alias for restart)
    tools/loom-serve.sh update     start / restart / nothing, whichever applies

`update` is the verb to reach for. It restarts the service only when the tree
has actually moved — a no-op in ~30ms otherwise, a ~4.5s restart when it has —
and a `SessionStart` hook in
`.claude/settings.json` runs it before the session's first tool call. That
timing is the point rather than a convenience: Claude Code's MCP handshake runs
once and early, and a service that was down when it ran offers no `loom_*`
tools for the rest of the session, which no per-call hook can recover.

**The one manual fallback, which the hook cannot cover.** An edit landing after
SessionStart has already run is invisible to the resident image until something
says so. An MCP or REST call that fails mid-session, or that answers against
code you know you just changed, means run `tools/loom-serve.sh update` and
retry — ARCH-0007 names this gap as accepted rather than solved.
