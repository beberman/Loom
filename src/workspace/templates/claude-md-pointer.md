<!-- loom:begin -->

## Engineering knowledge: ask Loom before reading the tree

This repository is indexed by **Loom**, a knowledge engine that answers
questions about this code and the documents describing it: where something is
defined, what a change reaches, which decisions govern an area.

The service is at `{{ENDPOINT}}` (REST under `/v1/`, MCP at `/mcp`), and this
repository is registered with it as `{{REPOSITORY-NAME}}`. Most queries name
the repository they mean. `loom_find` is the exception: called without a
`repository` it searches **every** watched tree, and this service may hold
several.

**Invoke the `loom` skill before starting work** — it is the authoritative copy
of how to query the index and how to write a document. Two things worth knowing
without it:

- Documents live under `{{DOCUMENT-DIRECTORY}}/`, as YAML, one directory per
  kind. `{{CONCEPT-ID}}` in `{{DOCUMENT-DIRECTORY}}/concepts/` has the
  conventions.
- When work lands, do not edit a status by hand. Run the transition command,
  which moves every document the plan implements and files it correctly.

### The service has to be running *before* the session starts

**Start Loom, wait for it, and then open the session.** A session whose first
tool call starts the service does not get the `loom_*` tools at all: the host
resolves MCP connections once at startup and does not retry, so the handshake
has already failed and the tools stay unavailable for that session's whole
length however healthy the endpoint becomes seconds later. Nothing is wrong
with `.mcp.json` or the endpoint when this happens — `POST /mcp` answers 200
throughout. Everything still works over REST, which is what the fallback below
is for, at the cost of hand-written URL encoding and JSON parsing all session.

**Install it once and the race cannot happen.** A service that outlives
sessions is already up when the next one opens, which beats remembering to
start it in time:

From your Loom checkout, once:

```bash
tools/loom-serve.sh install                   # writes the systemd user unit
systemctl --user enable --now loom.service    # turn it on
loginctl enable-linger $USER                  # optional: survive logout
```

`install` writes the unit and stops there; enabling changes what your machine
does with no session open, which is yours to decide. Once it is enabled,
`tools/loom-serve.sh start|stop|restart|update` all hand the verb to systemd
rather than spawning a second service beside the supervised one, so there is
still one thing to type.

**Starting takes tens of seconds, and the port refuses connections for the
first part of it.** Measured on one machine, warm cache, nine watched trees:
12s before the port answered at all, 18s to `ready`. A cold start is much
longer; `tools/loom-serve.sh` waits up to ~150s, sized against a cold fasl
cache. That first window, when nothing is listening, is what loses the
handshake.

**Once it answers, check `state` — "answering" and "ready" are different.**
`repository-state` defines three:

    indexing    nothing can be answered yet
    embedding   the graph is built and answerable: queries return lexically
                correct answers, without the semantic candidates they would
                have had a minute later
    ready       both

`find`, `describe`, `impact` and `check` are trustworthy at `embedding`; it is
`context`'s semantic seeding that is still warming. Ask rather than guess:

```bash
curl -s '{{ENDPOINT}}/v1/status?repository={{REPOSITORY-NAME}}'
```

Registrations survive a restart, so registering this tree is something a
service that has never seen it needs, not something to repeat on every bounce.

### Reach for the index, not for the shell

Saying "ask Loom first" once is not enough — the shell gets reached for anyway,
out of habit, on exactly the questions the index answers better. So, concretely:

If the question is *where is this*, *who calls this*, *does this exist*, *what
does this reach*, or *what has been decided about this* — the first tool is
`loom_*`. Not `grep`, not `find`, not `rg`, not `ls -R`.

| Question | Use | Not |
|---|---|---|
| where is X defined | `loom_find` | `grep -rn "defun X"` |
| which tree owns this name | `loom_find` with no `repository` | one call per tree |
| who calls X, how many, from where | `loom_describe` | `grep -rn "X"` |
| does X exist at all | `loom_find` | `grep -rl` over a tree |
| what breaks if X changes | `loom_impact` | reading callers by hand |
| the shape of a system | `loom_structure` | `ls -R` and guessing |
| what governs this area | `loom_impact`, `loom_context` | reading docs by hand |
| X's source and docstring | `loom_describe` with `source=true` | `sed -n` on the file |

**The index holds this tree's present. Its past is git's.** Every row above asks
about the code as it stands. What changed, when, and why are different
questions, and asking them here gets a confident answer to the question you did
not ask.

| Question | Use | Not |
|---|---|---|
| when did X change, and to what | `git log -S X` | `loom_describe` |
| what a migration deleted, and where it went | `git log -S X` | `loom_find` alone |
| why it is this way | the commit message | any query |

`git log -S <name>` finds the commits where the number of occurrences of a
string changed, which is how a rename, a move or a deletion is found. And a
commit message is evidence no index holds: one sentence in a commit was the
whole of what anybody knew about a stale fixture on the tree this guidance was
written from, and nothing derives that from the code because it is not in the
code.


**A name absent here may live in another tree.** `loom_find` with no
`repository` searches every watched one and each row says which it came from.
Named with a `repository` and finding nothing, it answers with an `elsewhere`
list -- `0 here; 1 in utils` -- so the migration is in the first answer rather
than a second call. A name in no tree at all is dead, and that is the finding
worth having: it is how a function two documents still cited was caught. The
answer also names any tree it could **not** search, because "absent everywhere"
is a claim a partial search must not make.

**Use `find` and `describe` for a yes/no; save `context` for an edit.**
`context` answers "I am about to change this, what bears on it" and returns a
large bundle — large enough to overflow a caller's output limit. To learn
whether something exists, `find` is one line of answer instead of sixty.

**Counting callers of a generic function: describe the methods, not the name.**
`describe` on a generic's name returns the interface, whose inbound `calls`
count is near zero, because the calls attach to its methods. `find` the name,
keep every `method:` and `function:` entity, and `describe` each id —
`describe` accepts a full entity id, not only a name. Skipping this reads a
codebase's most-called function as unused.

### What the index cannot see

Not an invitation to fall back to the shell generally — these are the specific
gaps, and the shell is the right tool for each:

- **Build-file component lists.** A source file is indexed whether or not any
  system loads it, so a file missing from its `.asd` (or equivalent) looks
  healthy while nothing can call it. Read the build file.
- **Byte-identical duplicates.** One name defined at two paths is the signal
  `find` gives you; `diff` is what confirms the two files are the same file.
- **`templates/` and dot-directories.** Deliberately unindexed, so text that
  lives there is invisible to every query — including this file.
- **Anything not yet written.** A document's `affects:`/`describes:` must name
  code that exists, or `check` reports it as rot. Leave the field out until the
  code lands.

### Whether an answer is current, and which surfaces say

Four answers carry the commit the analyzer read, the branch, and a hash of the
uncommitted diff. The commit distinguishes weeks; the diff hash distinguishes
saves. Three of them carry the staleness itself, and that is the field to read
before trusting an answer about code you have just changed:

- `loom_status`, `loom_structure` and `loom_context` carry `drift` — how many
  claimed files have changed since the index read them. `0` means the answer
  describes the tree as it stands.
- `loom_describe` carries `file` and `file-stale`: the same question about the
  one file the entity is defined in.
- `loom_find`, `loom_impact`, `loom_check` and `loom_rules` carry
  `provenance`: the commit, branch and `diff` hash the index was built from,
  and `indexed-at`. No `drift` — computing it costs a stat per claimed file,
  which on the four commands you call most is a price paid on every answer to
  tell you something is usually true. Compare `diff` against what you saw
  before your edit; if it has not moved, the answer predates your save.

Comparing a reported commit against `git rev-parse HEAD` yourself answers a
different question. The commit moves on `git commit` and the analyzer reads the
working tree, so a commit agreeing with HEAD is consistent with an index built
from entirely different bytes.

After writing any document, run `check-document` on its path — it reports the
id it parsed and whether each `refines:` resolved — then `check`, and confirm
`unresolved` did not rise.

Everything below the next line is yours. Loom replaces the text above it
whenever `init --update` runs, and never reads or writes anything below it —
so that is where knowledge about *this* repository belongs: which of two
repositories owns a name, the commands that start the service here, a query
that answered badly and what answered it instead.

<!-- loom:yours -->
<!-- loom:end -->
