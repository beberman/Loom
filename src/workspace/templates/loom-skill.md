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

**Start with `context`.** Given a task in words it returns a budgeted bundle of
what bears on it, banded so you can tell the code you asked about from the
reasoning about it: what the task named, decisions governing it, documents
bearing on it, prose that names it, and one hop away.

`impact` attaches the decisions and rules bearing on an entity. Read them
before writing something that contradicts one.

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

## Writing a document

`{{DOCUMENT-DIRECTORY}}/concepts/{{CONCEPT-ID}}.yaml` has the conventions and
is the authority. In short: YAML under `{{DOCUMENT-DIRECTORY}}/<kind>/`, the
directory names the type, `refines:` chains a document to the one it answers,
and `affects:` names the code it bears on. Both resolve against the index and
`check` reports what rots.

After writing, ask `check` and confirm `unresolved` did not rise.

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
