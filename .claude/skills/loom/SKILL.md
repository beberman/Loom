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

Drive it through `tools/loom.sh` **using the Bash tool**, which takes console
commands as separate arguments, watches the tree before the first and stops
after the last, and filters compile chatter:

```bash
tools/loom.sh 'status' 'impact repository 3'
```

One console command per argument; quote any containing a space. The script
`cd`s to the tree itself, so it works from any directory and the absolute form
`/home/beberman/lisp/Loom/tools/loom.sh` is equivalent.

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

`describe` on a document prints the **entire body**, which for a long
requirement is hundreds of lines with the edge list at the very bottom. Read the
file with Read if you want the text; use `describe` on a document only when you
want its edges, and expect to scroll.

## The test suite

Also the Bash tool:

```bash
tools/loom-test.sh        # summary only
tools/loom-test.sh -v     # with compile output
```

Six systems, per-system pass/fail summary. Note this is `/usr/bin/sbcl`, not the
SBCL behind SLIME; where the two could disagree, say which one you ran.

The script writes and runs this driver, which is also the preamble any one-off
script needs:

```lisp
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((here #p"/home/beberman/lisp/Loom/"))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/"
                    "workspace/" "process/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid") :silent t))
(load "/home/beberman/lisp/Loom/src/full-test.lisp")
(funcall (read-from-string "loom-test:full-test"))
```


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
