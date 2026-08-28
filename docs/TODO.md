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

None open. Every entry that stood here is in the 2026-08-27 and 2026-08-28
tables below, which name the document carrying each. The section is kept so
that a reader looking for query issues learns there are none rather than that
the heading was dropped.

## The graph and what it stores

- **Drop `:unresolved-calls` as a stored property, and take a generated
  entity's `:system` from the call site rather than the file.** Still stored as
  of 2026-08-21: four declarations in `src/ontology/code-ontology.lisp` and the
  write at `src/graph/resolve.lisp:1295`. DES-0014 explains what the property
  buys RESOLVE-CALLS but does not defer removing it, so this is the only record.
  -- reader and call-site work, 2026-08-09
  -- REQ-0055 asked for it and is `partial`: both halves are withdrawn on
     evidence, 2026-08-28. Nothing reads `:unresolved-calls`, so it is not the
     resolution intermediate this entry calls it -- it is the only record that a
     definition calls a name no definition in the tree answers, which is what
     BUG-0055 reasoned from. And a generated entity already takes its system
     from the calling file, which since DES-0009 is the call site's package.
     `describe` now prints the names as an `external` band rather than holding
     them where nobody could see them.

## Documents and the workflow around them

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

None open. Both entries that stood here -- refreshing a marked region, and
saying where Loom's boundary is -- are in the tables below.

## Measuring Loom

- **A full run that fails once cannot say which test, because the failure was
  intermittent and the run that caught it is gone.** BUG-0058 fixed the
  instrument -- `tools/loom-test.sh` discarded FiveAM's whole failure block, so
  a run reporting `Fail: 1` named nothing. The failure itself has no name. On
  2026-08-28 loom-serve reported 251 of 252 in a full run; the serve suite
  alone passed 252 five times in one image, once on its own, and once more in a
  full verbose run -- seven clean runs against one failure. The next occurrence
  will name itself, which is what the fix bought; until then this entry is the
  only record that there is something to catch.
  -- working on Loom itself, 2026-08-28

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

### 2026-08-28

| Removed | Now carried by |
|---|---|
| "`context`'s four candidate lists -- seeds, decisions, documents, mentions -- are 26% of the answer, are uncharged by the budget, and on a bundle that fit duplicate what `items` already carries under a band" -- 9,038 of 34,206 bytes on front-end at `budget=6000` | REQ-0061, implemented, shape C2 with a count (DES-0046). Each list now carries only the candidates its band did not admit into `items`: empty on a bundle that fit, the refused ones by name on one that truncated. The bundle gains `bands`, five `(found, sent)` pairs, and `found` minus `sent` is the list's length. `render-cutoff` prints a line per clipped band. C3 -- drop the lists, keep the count -- was rejected because the seed band sends 3 of 8 on front-end at `budget=6000` and `recall.py` scores strict recall on the seeds the seeder produced, so a dropped-but-ranked seed would read as a miss with no ranking change; `service.seed_names` reads the union of a band's `items` and its list |

### 2026-08-27

| Removed | Now carried by |
|---|---|
| "A JavaScript tree has no test entities at all, so 'is this covered?' is a question Loom cannot be asked where it matters most" | REQ-0053, implemented. front-end reads `test-entities: 2325, tested-units: 947, test-files: 145`, and `describe stitchOsmImage` names the three cases of makeImage.test.js while `impact runSegmentationTrial` names segment.test.js's two and not those. The item's proposed second half -- joining `makeImage.test.js` to `make-image.mjs` on the filename -- is refused rather than deferred: DES-0045 D8 gives the reason, and the import plus the call answer it without a guess |
| "`similar` and `survey` are unreachable from a registered repository" -- `GET /v1/similar` answering `UNKNOWN-OPERATION`, and neither verb among the MCP tools | BUG-0052. Both are registered read-tier operations: `/v1/similar`, `/v1/survey`, `loom_similar` and `loom_survey` answer, and a repository with no vector store is refused with a sentence naming it and `embed` rather than an empty array, per DES-0041 D10. The three REQ-0042 rows in the tables below were true of the console and false of every other caller |
| "Whether it is missing, renamed, or gated is not something a caller can tell from `UNKNOWN-OPERATION`" | BUG-0052 F4. The refusal names the registered operations, so a typo and an absent verb read differently. A tier the caller may not reach was already distinguishable: FIND-OPERATION is unfiltered and CHECK-CAPABILITY answers 403 |
| "JavaScript call edges attributed by bare method name are wrong often enough to mislead" -- 3 of 4 on `ingestModel`, 9 of 12 on `extractSharedArcs`, every wrong row naming a real definition | BUG-0055, closed. The edges were always asserted `:inferred` at 1/N and every answer surface dropped it: a neighbour row now carries `edge-source` and `edge-confidence` beside the entity's own, an impact row carries `inferred` and `confidence-of-path`, and a path writes the guessed hop `calls?>name`. The console prints `BiMap.get (inferred 0.33)`. The volume is unchanged and the bug says so -- `impact` still walks these edges, and filtering on the number nothing carried until now is a capability rather than this defect |
| "`budget` counts the content and not the JSON around it, so a caller who sets a small budget still overflows" | BUG-0054, closed. ADMIT-ITEM charged the *console* rendering; the skin now passes its own pricing in through `*context-item-cost*`, and the same function prices and emits the item so the two cannot disagree. front-end at `budget=6000`: 81,793 bytes to 34,206, and 4.2 characters per token on the charged part against ESTIMATE-TOKENS' own 4. The four candidate lists it named as still uncharged -- 26% of the answer -- are REQ-0061, in the 2026-08-28 table below |
| "`context` mints a record id only when a log directory is set ... so `context-used` is unreachable on an ordinary deployment" | BUG-0053, closed. Every context answer carries `feedback: "on"` or `"off"`, and RECORD-CONTEXT-USE no longer answers "No context record <id>" when the truth is that no log exists. The item's third proposal -- `init` turning the log on for the tree it prepares -- is withdrawn rather than deferred: DES-0030 D1 makes the directory an operator's and not a caller's, and it deliberately lives in Loom's tree so a prepared repository's corpus holds still. Whether `tools/loom-serve.sh` should default it on is REQ-0044's question |
| "`complete` cannot finalize a plan that refines nothing" -- `would-set` forever, with `set-status` as the way through | BUG-0057, closed, and the item named one of three shapes: a plan refining nothing, a plan whose refined documents are all already terminal, and one whose documents are all blocked. Each ends with no verdict a caller could offer, so each previewed forever. A dry run that finds nothing awaiting a verdict now re-enters once and writes, so the walk decides what it found in one place. Dry run is unchanged wherever a verdict can be withheld |
| "`export default { name }` sometimes mints a second entity for `name`" -- ambiguous in `affects:` for a cause absent from the author's source | BUG-0056, closed. The item's arrow-function lead was wrong: `export default { name }` always minted a nameless variable, and JS-DEFINITION-NAME names it after the module's base name -- so it collides exactly when a module is named after its principal export, which is why the byte-identical sibling differed. A re-export object now mints nothing; an anonymous function, a class, an object with inline values and an empty object all keep the entity they had |
| "`impact` prints a bare name, so a generic's methods read as one entity repeated" -- eight rows of `d2 method dhandler-copy` | BUG-0050, closed. An impact row prints its location in PRINT-SUMMARY-LINE's bracket form, so `find`, `describe` and `impact` agree; the bracket is dropped where it would repeat a file's own path. The entry's second half -- rows labelled `d6` on a depth-5 walk -- was never a defect, and IMPACT-REPORT now carries the depth it was asked for so the console can say once that the one-step band lies one hop past it. All 7 of those rows also print `d6?`, BUG-0055's marker: the band is low-confidence reaches, not a miscount |
| "Loom is the wrong tool for a question about a tree's past, and nothing says so" | REQ-0058, implemented. Both prepared surfaces name the boundary immediately after their question-shape table, with `git log -S <name>` as the verb and what it does said plainly, and both cite the instance rather than the principle: game-server's `de355d0` -- "Debugging found that the game-description/image url was wrong" -- was the whole of what anybody knew about a stale fixture. Loom's own CLAUDE.md carries the same. A tree prepared before today gets it on `init --update`, which is REQ-0052's mechanism rather than a gap |
| "`tools/` is indexed by language rather than by role, so the measurement harness is invisible" | REQ-0059, implemented. `status` reports `unclaimed` -- the tracked files no analyzer claims -- with the extensions named, and a zero-hit `find` carries `unanalyzed` beside REQ-0051's `elsewhere`. Loom reads `48 tracked files no analyzer claims -- 10 .json, 10 .md, 9 .py, 5 (none), 5 .sh, 3 .js, 6 other`, and `find acceptance` now says 0 here, 1 in front-end, and 9 Python files this index cannot have read. Whether Python should be analyzed is still not asked; REQ-0018 is where a language's toolchain gets consulted |
| "`find` answers a term that matches no definition with silence, when it could say the term is prose" | REQ-0054, implemented. A zero-hit `find` carries an `occurrences` band -- the lines the term is written on, with file, line and text, capped at twelve with the total beside it. `find osm-import` against front-end answers 0 definitions and 8 occurrences naming the router and the mock; `find no-such-token-anywhere` answers 0 and 0, which is what makes the first trustworthy. Files rather than `:mentions` edges, because two of the three occurrences are a string literal and a comment no analyzer asserts anything about. The document's own acceptance was wrong about PLAN-0003, and says so |
| "A completed migration plan's `affects:` can never resolve, and `check` will report it as rot forever" -- 8 of game-server's 16 | REQ-0056, implemented, and C1 did not have to be built: FEDERATED-AFFECTS-OPS has resolved `affects:` across repositories since REQ-0027 R4 and `check` was not reading the edges. Three states now -- answered by another watched tree, a qualified id naming a deleted file, and a name no tree holds. game-server went 16 to 5 unresolved and PLAN-0002 8 to 2, both of which are findings. BUG-0001 fell 6 to 3 by the same mechanism |
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
