---
name: loom
description: How to query Loom about this repository and how to write a document into {{DOCUMENT-DIRECTORY}}/. Use whenever you need to know where something is defined, what a change reaches, which decisions govern an area, or before writing or finishing any requirement, design, plan, review or bug document.
---

# Loom, for this repository

Loom indexes this repository's source and its documents into one graph and
answers questions about both. It runs as a service at `{{ENDPOINT}}` and this
repository is registered with it as **`{{REPOSITORY-NAME}}`**.

Every query names its repository, because the service holds several and an
answer about the wrong one is worse than no answer.

## Asking

Over REST, which needs nothing installed:

```bash
curl -s '{{ENDPOINT_URL}}/v1/context?repository={{REPOSITORY-NAME}}&task=soft+delete+read+path'
curl -s '{{ENDPOINT_URL}}/v1/find?repository={{REPOSITORY-NAME}}&term=dhandler-delete'
curl -s '{{ENDPOINT_URL}}/v1/impact?repository={{REPOSITORY-NAME}}&term=dhandler-delete&depth=3'
curl -s '{{ENDPOINT_URL}}/v1/structure?repository={{REPOSITORY-NAME}}'
curl -s '{{ENDPOINT_URL}}/v1/check?repository={{REPOSITORY-NAME}}'
```

Or as MCP tools, if `.mcp.json` registered the endpoint: `loom_context`,
`loom_find`, `loom_impact`, `loom_describe`, `loom_check`, `loom_structure`,
`loom_set_status`, `loom_complete`. Each takes `repository`.

### Picking the one to call

The first tool is one of these, not the shell. If the question is *where is
this*, *who calls this*, *does this exist*, *what does this reach*, or *what has
been decided about this*, then `grep`, `find`, `rg` and `ls -R` are all the
wrong answer — they see text, and this sees definitions, callers and decisions.

| Question | Call |
|---|---|
| where is X defined | `find` |
| who calls X, how many, from where | `describe` |
| does X exist at all | `find`, once per repository |
| what breaks if X changes | `impact` |
| the shape of a system | `structure` |
| what governs this area | `impact`, then `context` |
| X's source and docstring | `describe` with `source=true` |

**`context` is for an edit, not for a question.** Given a task in words it
returns a budgeted bundle of what bears on it, banded so you can tell the code
you asked about from the reasoning about it: what the task named, decisions
governing it, documents bearing on it, prose that names it, and one hop away.
That is what you want before changing something, and it is large — large enough
to overflow a caller's output limit. To find out whether something exists, or
where it lives, `find` is one line of answer instead of sixty.

**Counting callers of a generic function: describe the methods, not the name.**
`describe` on a generic's name returns the interface, and its inbound `calls`
count is near zero because the calls attach to the methods. `find` the name,
keep every `method:` and `function:` entity, then `describe` each id —
`describe` takes a full entity id, not only a name. Skipping this step reads a
codebase's most-called function as unused, and the wrong answer looks like a
right one.

`impact` attaches the decisions and rules bearing on an entity. Read them
before writing something that contradicts one.

### Tell it what you actually used

Every `context` answer carries a `record` id. When you have finished the work
that call was for, send back what you used, quoting that id:

```bash
curl -s -X POST '{{ENDPOINT_URL}}/v1/context-used' \
  -H 'content-type: application/json' \
  -d '{"record":"ctx-...","used":"[{\"name\":\"slurp-file\",\"how\":\"...\"}]"}'
```

or `loom_context_used` with `record` and `used`. This is not bookkeeping. The
bundle is ranked by a heuristic, and the only way anyone learns whether the
ranking works is that the agent using it says so.

**Report the misses, and report them by name.** `used` is deliberately not
restricted to what the bundle returned: name the thing you actually needed even
when the bundle never mentioned it, and say in `how` where you found it instead
— "found by grepping the exact identifier", "found from something else the
bundle returned", "not in the bundle; it lives under `templates/`, which is not
indexed". A feedback channel that can only confirm hits measures nothing, because
the misses are the population that would raise recall.

Worth reporting honestly and specifically:

- **nothing was useful** — say so, and say what found the answer.
- **the bundle was right but unreadable** — an answer that overflowed the output
  limit and got skimmed from a file is a different failure from a bad ranking.
- **the correct answer was that nothing exists** — a bundle cannot say "no such
  thing is here", and a caller who confirmed absence with `find` should record
  that, because seeds implying otherwise is its own defect.
- **the call was a probe** — say it was, so whoever reads the log excludes it
  rather than counting it as a miss.

A free-text `how` rather than a score, on purpose: "found three files from
something the bundle returned" and "found by grepping the identifier" are
different failures implying different repairs, and neither is a number.

## What Loom cannot see

It reports what it derived and says where it is blind, and both matter.

- `structure` reports the edges between systems in **both directions** and
  calls neither a violation. Which one was intended is not in the index.
- An entry-point list carries the count of call sites that could not be
  attributed. A definition called only from inside a macro body looks
  uncalled.
- `check` reports names that resolved to **nothing**. It cannot see a name that
  resolved to the wrong thing.

A small answer is not proof of a small change.

Four gaps where the shell is the right tool, and it is these rather than a
general licence to fall back:

- **Build-file component lists.** A source file is indexed whether or not any
  system loads it, so a file missing from its `.asd` looks healthy while nothing
  can call it — its definitions read as having no callers, which is true for the
  wrong reason. Read the build file.
- **Byte-identical duplicates.** One name defined at two paths is the signal
  `find` gives you; `diff` is what confirms the two files are the same file.
- **`templates/` and dot-directories.** Deliberately unindexed. Text living
  there is invisible to every query, including this file.
- **Anything not yet written.** Code that does not exist has no entity, so a
  document naming it is rot rather than a plan.

## Writing a document

`{{DOCUMENT-DIRECTORY}}/concepts/{{CONCEPT-ID}}.yaml` has the conventions and
is the authority. In short: YAML under `{{DOCUMENT-DIRECTORY}}/<kind>/`, the
directory names the type, `refines:` chains a document to the one it answers,
and `affects:` names the code it bears on. Both resolve against the index and
`check` reports what rots.

Leave `affects:`/`describes:` out entirely when the code it would name does not
exist yet. An empty field is accurate; a field naming code you are about to
write is rot from the moment it is saved.

After writing, ask `check-document` for the path — it reports the id it parsed
and whether each `refines:` resolved, which is how a malformed block scalar is
caught before it becomes a nameless document — then `check`, and confirm
`unresolved` did not rise.

## Finishing work

Do not edit a `status:` by hand and do not move files into `completed/`.

```bash
curl -s -X POST '{{ENDPOINT_URL}}/v1/complete' \
  -H 'content-type: application/json' \
  -d '{"repository":"{{REPOSITORY-NAME}}","plan":"PLAN-0001"}'
```

With no `verdicts` it writes nothing and returns the chain and what it needs.
Then supply them — `"verdicts":"DES-0001=implemented REQ-0001=implemented"` —
and it sets the plan final, walks upward while the verdicts stay terminal,
refuses any document another unfinished document still refines, and files each
one where its new status belongs.

The verdict is yours and is never derived. `implemented` means every
requirement that document states is now true of the tree; `partial` means some
landed and the document gains an OUTSTANDING section naming what did not.

`set-status <document> <status>` is the same write path for one document.
