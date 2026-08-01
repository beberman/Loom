# Loom

A Common Lisp engineering knowledge engine. It indexes source and documentation
into a graph and answers questions about them for LLM agents: where something is
defined, what a change reaches, what decisions govern an area.

## Ask Loom before reading the tree

Loom indexes itself, so the fastest way to understand this codebase is to use
it:

```
tools/loom.sh 'context <task words>'  # start here: what to read before editing
tools/loom.sh 'find <name>'           # where something is defined
tools/loom.sh 'describe <name>'       # neighbours, grouped by edge type
tools/loom.sh 'impact <name> 3'       # what a change reaches, plus decisions
                                      #   3 is a narrowing; the default is 5
tools/loom.sh 'rules'                 # constraints, and which are machine-checked
tools/loom.sh 'check'                 # violations and unresolved doc references
tools/loom.sh 'status' 'find foo'     # several commands, run in order
tools/loom.sh 'help'                  # the authoritative table; trust it first
```

**Drive Loom through `tools/`, not through a shell pipeline.** `tools/loom.sh`
takes console commands as separate arguments, watches the tree before the first
and stops after the last, and filters compile chatter. `tools/loom-test.sh` runs
the full suite. Both `cd` to the tree themselves, so they work from any
directory. Call them with the **Bash** tool:

```
tools/loom.sh 'impact repository 3'
tools/loom-test.sh
```

One console command per argument; quote any that contains a space. Nothing else
belongs on the line — no pipe, no redirect, no `tail`. The equivalent
hand-rolled `bash -lc "printf ... | sbcl --script loom.lisp | tail"` prompts
every time, because the pipe, the redirect and the `tail` each need permission
of their own, and a prompt inside a subagent is a stall nobody sees.

`impact` attaches the decisions and rules bearing on an entity. Read them before
contradicting them.

Loom has known blind spots — calls inside macro bodies are unattributed, so
anything driven by a `test` form under-reports. ARCH-0001 records the rest. A
small impact set is not proof of a small change.

## Environment

Everything runs natively under WSL Ubuntu: the shell is Linux bash, `sbcl` is
`/usr/bin/sbcl`, and paths are plain Unix paths under
`/home/beberman/lisp/Loom`. There is no `wsl.exe` hop and no PowerShell — an
instruction anywhere that names either is stale, and the fix is to correct it
rather than to work around it. Files ending in `~` are Emacs backups — ignore
them.

Full suite, in a live image:

```lisp
(load "src/full-test.lisp")
(loom-test:full-test)      ; six systems, per-system summary
```

or `tools/loom-test.sh` from outside one — note that is `/usr/bin/sbcl`, not the
SBCL behind SLIME. Where the two could disagree, say which one you ran.

## Layering

    loom-ontology   entity and relationship declarations. Depends on nothing.
    loom-graph      the only writer. Transactions, queries, resolution, rules.
    loom-analyzer   path + contents -> operations. Never touches the graph.
    loom-knowledge  read-only services: find, describe, impact, context.
    loom-workspace  indexing pipeline and file monitor.
    loom-process    the console.

RULE-0001 to RULE-0003 enforce parts of this and are machine-checked. They do
not fail a FiveAM assertion, so run `check` as well as the suite.

## Where the knowledge lives

Not here. This file is a pointer; the reasoning is in `docs/`, indexed and
cross-referenced. CON-0004 describes the workflow and how documents link.

    docs/requirements/  what is wanted           REQ-nnnn
    docs/arch/          the shape of an answer   ARCH-nnnn
    docs/design/        decisions and rationale  DEC-nnnn
    docs/plans/         ordered steps            PLAN-nnnn
    docs/reviews/       review findings          REV-nnnn
    docs/bugs/          defects worth keeping    BUG-nnnn
    docs/concepts/      recurring ideas          CON-nnnn
    docs/rules/         constraints              RULE-nnnn

Documents are YAML. The analyzer claims `.yaml` and `.yml` under `docs/` and
nothing else, and the directory names the type — a markdown file in `docs/plans`
is invisible. `refines:` names the document a document answers, `affects:` names
the code a decision governs, and both resolve against the index; a name that
resolves to nothing is reported by `check` rather than dropped.

## Principles worth knowing before changing anything

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
