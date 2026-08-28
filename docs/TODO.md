# Open dogfooding issues

What using Loom on real trees has turned up and nothing has yet fixed. One
entry per issue, each carrying the tree and the date it was found on, so a
reader can check whether it is still true.

**An entry leaves this file when a document carries it.** A requirement, design
or bug reaching a terminal status makes the entry redundant, and an entry that
duplicates a completed document is worse than no entry: it reads as open work.
Removals go in the table at the bottom, naming what carries each one now, so
nobody re-derives it from scratch.

Where Loom has proven useful is the other half of this record and lives in
`docs/VALUE.md`. Neither file is complete without the other.

The trees are Loom itself, `game-server`, `front-end` and `utils`.

---

## Queries and their answers

- **`impact` prints a bare name, so a generic's methods read as one entity
  repeated.** BUG-0050, and it is not the entry that stood here. That entry
  said `impact` repeats entities -- 253 rows covering 208 distinct entities,
  18% of the answer the same entity again. Re-measured 2026-08-24 on the same
  tree and command: 822 rows, 822 distinct ids, zero repeats. IMPACT-SET is
  deduplicated by a `seen` hash keyed on entity id. The 18% was counted by
  name, and counting by name counts two definitions as one, which DES-0015
  says is the wrong count.

  What the reader saw was still real. 45 names occupy more than one row, 95
  rows in all, worst case `dhandler-copy` at eight -- eight genuine methods in
  four files, printed as eight rows saying `d2 method dhandler-copy` with
  nothing on them saying which. The REST answer carries `id` and `location`;
  the console prints neither, so the one field that separates them is the one
  field not shown. `find` and `describe` both print a location.

  The same entry's second half -- rows labelled `d6` on a depth-5 walk -- also
  reproduces, 7 of 822, and is by design: the one-step band is a single hop
  from everything already impacted, so a base at the cap yields a neighbour one
  past it. All seven are `:file` entities reached by a final `contains>` hop.
  The number is the true path length. What is missing is any statement that the
  band lies outside the depth the caller asked for.
  -- the ~/lisp/game-server evaluation, 2026-08-06; re-measured 2026-08-24

- **`find` answers a term that matches no definition with silence, when it
  could say the term is prose.** `find term=osm-import` against `front-end`
  returned `{"entities":[],"total":0}`. The string is a route -- `router.post
  ('/osm-import', ...)` -- and it appears in the mock, in the router's header
  comment, and in PLAN-0003, so the question "where is the osm-import endpoint"
  has an answer and the index holds the material for it. Route strings are not
  definitions and should not become entities; that is not the ask. The ask is
  that a zero-hit answer distinguish *no such name anywhere* from *no definition,
  N textual occurrences, here they are*, because those imply opposite next
  moves and only the first is worth the caller's confidence. `context` finds
  these through its `mentions` band, so the material is already indexed -- it
  is `find` that has no path to it.
  -- chasing front-end's BUG-0014, 2026-08-27
  -- REQ-0054 asks for it, 2026-08-27

## The graph and what it stores

- **Drop `:unresolved-calls` as a stored property, and take a generated
  entity's `:system` from the call site rather than the file.** Still stored as
  of 2026-08-21: four declarations in `src/ontology/code-ontology.lisp` and the
  write at `src/graph/resolve.lisp:1295`. DES-0014 explains what the property
  buys RESOLVE-CALLS but does not defer removing it, so this is the only record.
  -- reader and call-site work, 2026-08-09
  -- REQ-0055 asks for it, and states why it must not land before BUG-0055, 2026-08-27

## Documents and the workflow around them

- **A completed migration plan's `affects:` can never resolve, and `check`
  will report it as rot forever.** 8 of game-server's 16 unresolved references
  are PLAN-0002's own: `config-get`, `dict-value`, `alistp`, `string-split`,
  `json-encode`, `json-decode`, `get-package-file`, `make-dict`. They fail to
  resolve *because the plan succeeded* and moved them out of the repository. I
  left the field alone and said why in the commit, because trimming it to
  whatever still resolves would make the record less true — the plan's subject
  is exactly those names. But the state is unsatisfying in both directions: an
  accurate document is permanently reported as rotten, and 8 items of standing
  noise is how a check gets ignored. Worth designing. Candidates: exempt
  documents under `completed/` from unresolved-affects, resolve `affects:`
  across registered repositories, or let a document say a name has left the
  tree.

  The middle option is item 1's mechanism again, and measuring it is
  instructive: 5 of the 8 — `dict-value`, `alistp`, `string-split`,
  `json-encode`, `json-decode` — resolve in `utils` today and would go quiet
  immediately. The other 3 are each true in a different way. `config-get`
  resolves nowhere because the plan *renamed* it to `config-search`, which the
  plan's own text records. `get-package-file` is gone from both trees, which is
  the finding in item 1 and the one entry here that genuinely wants reporting.
  And the eighth is written as the path-qualified id
  `function:utils/dict.lisp:make-dict`, naming a file the plan deleted — a bare
  `make-dict` resolves in `utils`, that id cannot resolve anywhere ever again.
  So a cross-repository `affects:` would not silence the category; it would
  separate the noise from the two entries that are saying something, which is
  the better outcome.
  -- completing game-server's PLAN-0002, 2026-08-21
  -- REQ-0056 asks for it, 2026-08-27

- **A test that reads a live document pins a judgement.**
  `IMPORTANCE-IS-READ-AS-A-KEYWORD-FROM-THE-VOCABULARY` asserted REQ-0037 was
  `:CRITICAL`; repricing REQ-0037 to Minor broke it, and the failure was
  reported twice as a standing loom-analyzer defect before being read properly.
  Split into fixtures for the vocabulary and one live assertion that does not
  name a level (BUG-0044). Worth checking whether any other test reads
  `docs/` and asserts a value that is a judgement rather than a format.
  -- implementing REQ-0040, 2026-08-23
  -- REQ-0057 asks for the audit, 2026-08-27

## Preparing somebody else's tree

- **Loom is the wrong tool for a question about a tree's past, and nothing says
  so.** Completing game-server's PLAN-0002 was three bugs, and none of them was
  found with the index -- they were found with `grep`, `git log -S`, and one
  commit message. `de355d0`'s message says *"Debugging found that the
  game-description/image url was wrong"*, and that sentence is the entire
  evidence that a stale fixture was stale rather than the server being wrong.
  The index holds the tree's present. A migration's debris is a question about
  its past, and `git log -S` is the tool for it. Loom should not try to be --
  but an agent told "ask Loom before reading the tree" will ask it the wrong
  question first, and neither the prepared CLAUDE.md region nor the skill says
  where the boundary is.
  -- completing game-server's PLAN-0002, 2026-08-21
  -- REQ-0058 asks for it, 2026-08-27

## Measuring Loom

- **`tools/` is indexed by language rather than by role, so the measurement
  harness is invisible.** `find acceptance`, `find score_judgement` and
  `find ensure` all return nothing: Python is not analyzed, so
  `tools/test/acceptance.py`, `tools/test/recall.py` and `tools/test/service.py` have no
  entity, no callers and no documents attached to them. `tools/test/harness.lisp` is
  indexed -- `find load-systems` returns `tools/test/harness.lisp:57-79` -- so one
  directory splits down the middle. The absence itself is known and settled
  (REQ-0019 and DES-0013 record the rejected approaches); what is worth stating
  in one place is that the part of the tree Loom cannot answer questions about
  is the part that measures Loom.
  -- implementing REQ-0038, 2026-08-21; re-measured 2026-08-24
  -- REQ-0059 asks that the gap be reported; whether Python is analyzed is a
     separate question REQ-0059 does not ask, 2026-08-27

- **Context logging is off by default during work on Loom, and the corpus was
  purged to what scores.** On 2026-08-22 `.loom/context` held 2032 records and
  27MB, of which 15 carried a judgement. Two runs of the 450-case known-item
  harness contributed 900 by themselves; 1100 earlier records covered 39
  distinct tasks. Purged to the 15 judgements and the 15 records they judge,
  following REQ-0038's rule of keeping what scores; the whole directory is
  archived first at `.loom/context-archive-20260822.tar.gz`, which is
  gitignored along with the rest of `.loom/`. `tools/loom-serve.sh` no longer
  defaults `LOOM_CONTEXT_LOG` to `1` -- a session meant to produce judgements
  turns it on with `LOOM_CONTEXT_LOG=1 tools/loom-serve.sh restart`. This is a
  workaround for REQ-0044, which asks for a field marking a record as a probe;
  with one, probe traffic could be written and then excluded rather than not
  written at all.
  -- working on Loom itself, 2026-08-22
  -- REQ-0044 carries the probe field this works around, 2026-08-21

- **Loom-side acceptance cases cannot measure Loom-side commits, and prose is
  the vector.** On 2026-08-22 `log-1` ("trim whitespace from a string") went
  from a hit to a miss with no semantic change to the seeder: `js-trim` was
  displaced by `task-token-origins`, `seed-matches` and `best-name-rank`, three
  functions whose docstrings had just been written to explain BUG-0040 and so
  are dense in "string", "str", "stre" and "trim". `tools/test/acceptance.py`'s
  header already warns that "every commit to it changes the corpus a Loom-side
  clause measures", and that warning was written about code; the measured
  vector was documentation. `log-1`, `r39-3` and the three `ABSENCE_CASES` are
  all Loom-side and all inherit the problem. DES-0033 records the three
  attempts it took to establish, including one experiment that moved two
  variables at once by stashing the source file and thereby removing the new
  docstrings with it.
  -- working on Loom itself, 2026-08-22
  -- REQ-0060 asks for it, 2026-08-27

---

## What has been removed, and what carries it now

A removed entry is one a document now states. The tables are kept so nobody
re-derives an item that was answered, and each row names where to look instead.

### 2026-08-27

| Removed | Now carried by |
|---|---|
| "A JavaScript tree has no test entities at all, so 'is this covered?' is a question Loom cannot be asked where it matters most" | REQ-0053, implemented. front-end reads `test-entities: 2325, tested-units: 947, test-files: 145`, and `describe stitchOsmImage` names the three cases of makeImage.test.js while `impact runSegmentationTrial` names segment.test.js's two and not those. The item's proposed second half -- joining `makeImage.test.js` to `make-image.mjs` on the filename -- is refused rather than deferred: DES-0045 D8 gives the reason, and the import plus the call answer it without a guess |
| "`similar` and `survey` are unreachable from a registered repository" -- `GET /v1/similar` answering `UNKNOWN-OPERATION`, and neither verb among the MCP tools | BUG-0052. Both are registered read-tier operations: `/v1/similar`, `/v1/survey`, `loom_similar` and `loom_survey` answer, and a repository with no vector store is refused with a sentence naming it and `embed` rather than an empty array, per DES-0041 D10. The three REQ-0042 rows in the tables below were true of the console and false of every other caller |
| "Whether it is missing, renamed, or gated is not something a caller can tell from `UNKNOWN-OPERATION`" | BUG-0052 F4. The refusal names the registered operations, so a typo and an absent verb read differently. A tier the caller may not reach was already distinguishable: FIND-OPERATION is unfiltered and CHECK-CAPABILITY answers 403 |
| "JavaScript call edges attributed by bare method name are wrong often enough to mislead" -- 3 of 4 on `ingestModel`, 9 of 12 on `extractSharedArcs`, every wrong row naming a real definition | BUG-0055, closed. The edges were always asserted `:inferred` at 1/N and every answer surface dropped it: a neighbour row now carries `edge-source` and `edge-confidence` beside the entity's own, an impact row carries `inferred` and `confidence-of-path`, and a path writes the guessed hop `calls?>name`. The console prints `BiMap.get (inferred 0.33)`. The volume is unchanged and the bug says so -- `impact` still walks these edges, and filtering on the number nothing carried until now is a capability rather than this defect |
| "`budget` counts the content and not the JSON around it, so a caller who sets a small budget still overflows" | BUG-0054, closed. ADMIT-ITEM charged the *console* rendering; the skin now passes its own pricing in through `*context-item-cost*`, and the same function prices and emits the item so the two cannot disagree. front-end at `budget=6000`: 81,793 bytes to 34,206, and 4.2 characters per token on the charged part against ESTIMATE-TOKENS' own 4. What remains is REQ-0061: four candidate lists, 26% of the answer, that nothing charges for |
| "`context` mints a record id only when a log directory is set ... so `context-used` is unreachable on an ordinary deployment" | BUG-0053, closed. Every context answer carries `feedback: "on"` or `"off"`, and RECORD-CONTEXT-USE no longer answers "No context record <id>" when the truth is that no log exists. The item's third proposal -- `init` turning the log on for the tree it prepares -- is withdrawn rather than deferred: DES-0030 D1 makes the directory an operator's and not a caller's, and it deliberately lives in Loom's tree so a prepared repository's corpus holds still. Whether `tools/loom-serve.sh` should default it on is REQ-0044's question |
| "`complete` cannot finalize a plan that refines nothing" -- `would-set` forever, with `set-status` as the way through | BUG-0057, closed, and the item named one of three shapes: a plan refining nothing, a plan whose refined documents are all already terminal, and one whose documents are all blocked. Each ends with no verdict a caller could offer, so each previewed forever. A dry run that finds nothing awaiting a verdict now re-enters once and writes, so the walk decides what it found in one place. Dry run is unchanged wherever a verdict can be withheld |
| "`export default { name }` sometimes mints a second entity for `name`" -- ambiguous in `affects:` for a cause absent from the author's source | BUG-0056, closed. The item's arrow-function lead was wrong: `export default { name }` always minted a nameless variable, and JS-DEFINITION-NAME names it after the module's base name -- so it collides exactly when a module is named after its principal export, which is why the byte-identical sibling differed. A re-export object now mints nothing; an anonymous function, a class, an object with inline values and an empty object all keep the entity they had |
| "`find` should answer across registered repositories, or say that it didn't" -- three instances, the sharpest entry in this file | REQ-0051, implemented. `find` with no `repository` searches every watched tree and each row names its own; named with one and finding nothing, it answers `0 here; 1 in utils`. The answer also names any tree it could not search, so "absent everywhere" is never claimed by a partial search |
| "`init` cannot refresh a marked region it wrote" -- eight prepared trees keeping stale guidance, and a hand-edited region that is a superset of the template | REQ-0052, implemented as `init --update`. The author's half of the region is declared rather than guessed at, so a refresh replaces Loom's bytes and leaves the hundred lines beside them that no template can regenerate |

### 2026-08-24

Run after RULE-0008, REQ-0050 R3 and the prepared-guidance change, and again
when this file was narrowed to open issues only. Each removal was checked
against the running service rather than against the document claiming to carry
it.

| Removed | Now carried by |
|---|---|
| "`tools/loom-serve.sh update` reports failure while the service is starting", printing `after ~20s` against a cold start that takes longer | Fixed. The loop is 300 half-second polls and the message reads `after ~150s` |
| "The context log is the instrument and it was measuring a ghost" -- acceptance.py scoring a service started before the day's work, and its proposed fix of a commit line compared against `git rev-parse HEAD` | REQ-0050 R4 prints what answered, and RULE-0008 removes the comparison: `tools/test/service.py` calls `tools/loom-serve.sh update` before the first case, so the build that answers is the one on disk. The `git rev-parse` half is not merely done but withdrawn -- the commit moves on `git commit` and the analyzer reads the working tree, so `drift` is the field that answers it |
| "`tools/test/call-site-census.lisp` was broken and nobody knew ... the general shape is worth a rule" | The rule was written twice. REQ-0050 R5 and `tools/test/harness.lisp` for the instruments that load a system; RULE-0008 and `tools/test/service.py` for the three that drive the service. Both refuse with a sentence rather than report a zero |
| "No console command reports `:source-tokens`, `:sourced` or the rendered byte count ... Loom cannot currently be asked the question REQ-0040 is about" | PLAN-0045 brought the source tier inside the budget and RENDER-CONTEXT-SUMMARY reports it: `# N entities, ~T/B tokens (truncated)`, then the percentage sent, then `index` and `source` lines naming items and bodies withheld with their token cost |
| "`find term=join` against Loom now returns 2 ... the absence cases should be re-checked before REQ-0037 is measured against them" | acceptance.py runs all three absence cases on every invocation, and RULE-0008 makes each run happen against a current service. All three passed on 2026-08-24. The decay the item illustrates is REQ-0038 R4's subject, and `freshness()` classifies a record by it |
| "Document statuses" -- the REST skin having no way to show one, short of `check-document` | `describe` carries it. `describe term=PLAN-0045` returns `document: {title, status, field, text}` with `status: "final"`, and the same holds for every kind |
| "`structure`'s commit field, before trusting anything" -- comparing a reported commit against `git rev-parse HEAD`, in two places | REQ-0050 R1 put `drift` on the answer, and the prepared guidance now names the comparison as the thing not to do |
| "Two functions being the same function is not something the index can say" | REQ-0042, implemented as `similar` and `survey`, which report *why* a pair is suspicious. The remaining half is a decision rather than a gap: REQ-0042 R4 forbids the answer from asserting equivalence |
| The session logs of what the index answered on 2026-08-06, 08-18, 08-21 and 08-23 | `docs/VALUE.md`, which is where evidence that Loom worked belongs. This file is issues |

### 2026-08-23

| Removed | Now carried by |
|---|---|
| "Requirements should have an importance field" | Implemented. `importance:` is on every REQ, in the ontology's `:one-of` vocabulary, with IMPORTANCE-IS-READ-AS-A-KEYWORD-FROM-THE-VOCABULARY over it |
| A check for source files absent from every ASDF component list, and for a name a package exports and nothing defines | REQ-0043 R1 and R2, which cite the same instances -- game-server/utils/token.lisp, datascience's range-tree.lisp, matrix-utils' four undefined exports |
| "a size-aware `context` that trims to a budget the caller names would be the fix, and nothing asks for one" | REQ-0040 asks for it and PLAN-0045 built it: `--budget`, one budget covering both tiers, and a cutoff signal saying what a larger one would buy |
| "a query that takes a definition and returns definitions like it" | REQ-0042, implemented as `similar` |
| "There is no call that takes two [repositories] and reports what they have in common" | REQ-0042 R3, implemented as `survey` |
| "`commit` in a `structure` answer is not the state of what was indexed" | REQ-0050, which generalises it |
| `tools/loom-serve.sh`'s 20-second start timeout | Fixed; it is ~150s now, sized against a cold fasl cache |

### 2026-08-21

| Removed | Now carried by |
|---|---|
| REQ-0012's remaining half -- `describe` resolving a name through SEARCH-ENTITIES' first hit, so an :INTERFACE/:METHOD tie falls to index order | REQ-0012 OUTSTANDING item 1 |
| REQ-0013's measurement -- 3,037 unresolved calls at 48.2%, `:unresolved-calls` written at resolve.lisp:570 and read by nothing | REQ-0013 body, including the counter argument |
| REQ-0015's R6 failure and its cause | REQ-0020, written to carry exactly that trace |
| REQ-0016's measurement -- `context data-handler` returning 22 substring matches and none of the 21 `dhandler-*` generics | REQ-0016 summary, verbatim, with R-level acceptance |
| REQ-0017's risk argument -- a generated requirement asserting structure its source never committed to | REQ-0017 body |
| `impact`'s `(truncated)` printed as a boolean | REQ-0005, which proposes `14 impacted, 31 more at depth 4` in its place |
| The 2026-08-09 rejections -- Cleavir, a shared cross-language CST, reviving a CL parser for TS or Python | REQ-0019's WHAT THIS IS NOT and DES-0013's alternatives |
| A batched, out-of-process analyzer | REQ-0024's open question 1, which measures it against 455 files and answers that acorn does not batch |
| `describe` on a generic reading as unused because the inbound count sits on the methods | REQ-0012 OUTSTANDING item 1 -- the same defect from the other side |
| The index's value being the prose a human wrote rather than the graph | REQ-0035, implemented: the prose a definition carries is indexed now |
| "The harness contaminates the corpus it measures" | REQ-0038's DECIDED section, along with the purge that answers it |
