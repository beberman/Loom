---
name: synoptik
description: How to query Synoptik about this repository and how to write a document into {{DOCUMENT-DIRECTORY}}/. Use whenever you need to know where something is defined, what a change reaches, which decisions govern an area, or before writing or finishing any requirement, design, plan, review or bug document.
---

# Synoptik, for this repository

Synoptik indexes this repository's source and its documents into one graph and
answers questions about both. It runs as a service at `{{ENDPOINT}}` and this
repository is registered with it as **`{{REPOSITORY-NAME}}`**.

Most queries name their repository, because the service holds several and an
answer about the wrong one is worse than no answer. `find` is the exception:
without a `repository` it searches every watched tree, because *which of them
owns this name* is a question no single tree can answer.

## Asking

Over REST, which needs nothing installed:

```bash
curl -s '{{ENDPOINT_URL}}/v1/context?repository={{REPOSITORY-NAME}}&task=soft+delete+read+path'
curl -s '{{ENDPOINT_URL}}/v1/find?repository={{REPOSITORY-NAME}}&term=dhandler-delete'
curl -s '{{ENDPOINT_URL}}/v1/find?term=dhandler-delete'   # every watched tree
curl -s '{{ENDPOINT_URL}}/v1/impact?repository={{REPOSITORY-NAME}}&term=dhandler-delete&depth=3'
curl -s '{{ENDPOINT_URL}}/v1/structure?repository={{REPOSITORY-NAME}}'
curl -s '{{ENDPOINT_URL}}/v1/check?repository={{REPOSITORY-NAME}}'
curl -s '{{ENDPOINT_URL}}/v1/similar?repository={{REPOSITORY-NAME}}&term=ringIsCCW'
```

Or as MCP tools, if `.mcp.json` registered the endpoint: `synoptik_context`,
`synoptik_find`, `synoptik_impact`, `synoptik_describe`, `synoptik_check`, `synoptik_structure`,
`synoptik_similar`, `synoptik_survey`, `synoptik_set_status`, `synoptik_complete`. Each takes
`repository`, except `synoptik_find`, where it is optional.

`synoptik_find` also takes `kind`, which is `code` or `documentation`. A common
noun names both: on Synoptik's own tree `repository` names 232 entities, most of
them code, and a caller wanting the documents had no way to ask. The filter
matches NAMES -- for documents *about* a subject rather than named after it,
ask `synoptik_context`.

### Picking the one to call

The first tool is one of these, not the shell. If the question is *where is
this*, *who calls this*, *does this exist*, *what does this reach*, or *what has
been decided about this*, then `grep`, `find`, `rg` and `ls -R` are all the
wrong answer — they see text, and this sees definitions, callers and decisions.

| Question | Call |
|---|---|
| where is X defined | `find` |
| who calls X, how many, from where | `describe` |
| does X exist at all | `find` with no `repository` |
| which tree owns this name | `find` with no `repository` |
| what breaks if X changes | `impact` |
| the shape of a system | `structure` |
| what governs this area | `impact`, then `context` |
| X's source and docstring | `describe` with `source=true` |
| which tests cover X | `describe` or `impact`, `tests` band |
| where else this shape of code lives | `similar` |
| what two trees have in common | `survey` |

**The index holds the tree's present. Its past is git's.** Every row above asks
about the code as it stands. What changed, when, and why are different
questions, and asking them here gets a confident answer to the question you did
not ask.

| Question | Call |
|---|---|
| when did X change, and to what | `git log -S X` |
| what did a migration delete, and where did it go | `git log -S X` |
| why is it this way | the commit message |

`git log -S <name>` is the verb worth knowing: it finds the commits where the
number of occurrences of a string changed, which is how a rename, a move or a
deletion is found. `git log -p --follow <file>` is the same question about one
file.

**A commit message is evidence no index holds.** One bug turned on a single
sentence in a commit message, which was the whole of what anybody knew about a
stale fixture. Nothing derives that from the code, because it is not in the
code.


**A name absent here may live in another tree.** `find` with no `repository`
searches every watched one, and each row says which it came from. Named with a
`repository` and finding nothing, it answers with an `elsewhere` list -- `0
here; 1 in <tree>` -- so a migration shows up in the first answer rather than a
second call. A name in no tree at all is dead, which is the finding worth
having. The answer also names any tree it could **not** search: "absent
everywhere" is a claim a partial search must not make.

**`context` is for an edit, not for a question.** Given a task in words it
returns a budgeted bundle of what bears on it, banded so you can tell the code
you asked about from the reasoning about it: what the task named, decisions
governing it, documents bearing on it, prose that names it, and one hop away.
That is what you want before changing something, and it is large — large enough
to overflow a caller's output limit. To find out whether something exists, or
where it lives, `find` is one line of answer instead of sixty.

**`similar` asks the question `find` cannot.** A duplicate is precisely the
case where the two names differ, so a name search is structurally unable to
find one. `similar` takes a definition and returns the definitions that
resemble it by meaning, each row carrying the cosine and what the two share --
name words, docstring words, arity. Add `against=<other repository>` to look in
a different tree; `survey` does the same for two whole trees at once and
reports one best match per definition above a `cut`.

The answer points and does not conclude. Half the pairs the query was built
from were read on both sides and were not duplicates, so a row is a reason to
read two definitions, never grounds for rewriting one into the other.

Both need a vector store. Without one they refuse by name -- "X has no vector
store. Run embed on it first." -- rather than answering with an empty list,
because an empty list would mean *nothing resembles this* and *nothing could
have* at once.

**Counting callers of a generic function: describe the methods, not the name.**
`describe` on a generic's name returns the interface, and its inbound `calls`
count is near zero because the calls attach to the methods. `find` the name,
keep every `method:` and `function:` entity, then `describe` each id —
`describe` takes a full entity id, not only a name. Skipping this step reads a
codebase's most-called function as unused, and the wrong answer looks like a
right one.

**An empty `tests` band is an answer.** `describe` and `impact` report the
tests that reach an entity: fiveam tests in a Lisp tree, vitest and jest cases
in a JavaScript one, each named the way the runner prints it -- `stitchOsmImage > crops to the bbox AFTER compositing`. A case is linked
to a unit because its body, or a hook the runner runs for it, calls that unit.
So no `tests` means no case in this index calls it, which is worth knowing
before you change it. It does not mean the code is unexercised -- a case may
reach it through a caller, which is what `impact` traces -- and a file the
runner would run that Synoptik recognised no case in is counted in `status` as
`test-files-without-cases` rather than passed over.

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

or `synoptik_context_used` with `record` and `used`. This is not bookkeeping. The
bundle is ranked by a heuristic, and the only way anyone learns whether the
ranking works is that the agent using it says so.

**Check `feedback` first.** Every context answer carries it. `"feedback": "on"`
means the answer also carries a `record` id and the channel below is open;
`"feedback": "off"` means this deployment keeps no context log, no `record` was
minted, and `context-used` will refuse — so do not spend a call on it. The
field is on the answer in both states precisely so that a missing `record` is
never something you have to guess about.

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

## Whether an answer is current

An index is built by a watcher polling after a save, so an answer describes the
tree as the last poll read it and not necessarily as it stands. Four surfaces
say which tree that was — the commit the analyzer read, the branch, and a hash
of the uncommitted diff. The commit distinguishes weeks; the diff hash
distinguishes saves.

    status, structure, context    drift: how many claimed files have changed
                                  since the index read them. 0 is current.
    describe                      file and file-stale: the same question about
                                  the one file this entity is defined in.
    find, impact, check, rules    provenance: the commit, branch, diff hash and
                                  indexed-at. No drift -- it costs a stat per
                                  claimed file, and these four are the ones you
                                  call in a loop. Compare diff against what you
                                  saw before your edit.

Do not compare a reported commit against `git rev-parse HEAD` instead. That
answers a different question: the commit moves on `git commit` and the analyzer
reads the working tree, so a commit agreeing with HEAD is consistent with an
index built from entirely different bytes.

## What Synoptik cannot see

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
