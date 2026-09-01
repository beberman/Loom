# Where Loom has earned its place

Every entry below is a question asked during real work on a real tree, the
answer Loom gave, and what the answer replaced. Nothing here is a capability
list: a feature that has never decided anything does not appear, and an entry
stays only as long as someone can still check it.

This is deliberately one-sided. It is the material for release notes and for
documentation, so it records what worked. What has not worked, and what is still
missing, is in `docs/TODO.md`, which carries the open dogfooding issues and is
the other half of the same record.

The trees are Loom itself, `game-server`, `front-end` and `utils`.

---

## Finding every caller, when the name is not the identity

**`describe slurp-file` returned 16 source callers and 2 tests, by location,
across three systems.** `grep -rn slurp-file src/` returns 27 lines, of which
four are a docstring, an export, a comment about where files get read, and the
definition itself. Deciding *is this safe to delete, and how much moves with it*
from the grep means reading all 27. The index answered it once.
— migrating Loom onto the utils library, 2026-08-21

**A grep on a package prefix finds call sites in the wrong repository forever.**
`#:gs-utils` USEs `#:utils` and re-exports its symbols, so `gs-utils:dict-value`
and `utils-dict:dict-value` are one symbol object and the definition is in the
other tree. A callable is identified by the symbol it names, not the string it
spells, and only the index resolves that.
— completing game-server's PLAN-0002, 2026-08-21

**Three ways a grep lied about one repository, all in one sitting, all caught by
`describe` reporting zero inbound calls.** A docstring example counted as a call
— `index.lisp` had `(array-map #'1+ #2A((0 1 2) ...))` inside a docstring. A
recursive self-call counted as an external caller, so `apply-to-list` and
`find-sequences` each read as used. And `gs-utils:find-objects` had no callers
at all while `game:find-objects` had six, so a grep for the bare name reported a
dead function as busy.
— game-server, recorded in its own CLAUDE.md

## Overturning a document that had gone stale

**One `find` call overturned two documents.** `get-package-file` resolves in
**neither** `game-server` nor `utils` — against a plan listing it under "KEPT IN
gs-utils" and a CLAUDE.md citing it in a worked example. A name absent from both
repositories is dead; a name absent from one and present in the other is a
migration telling you where it went.
— completing game-server's PLAN-0002, 2026-08-21

**`find` said where two of seven definitions actually were.** Locating the
entities in DES-0031's `affects:` returned `file:line-range` for each, one line
apiece. Two were not where the design implied — `record-read-query` is in
`src/serve/registry.lisp`, not in `context-log.lisp` beside the writer it calls
— and `find` said so without a file being opened.
— implementing REQ-0038, 2026-08-21

**`find` returned a call site the design had not seen.** Asking for
`estimate-tokens`, `render-context` and `context-token-budget` in one call also
returned the two `call-site` entities beside them, including
`render-context@src/process/console.lisp:897` — the console's own use of the
renderer, a surface the design had to change and which no reading of
`context.lisp` would have shown.
— designing REQ-0040, 2026-08-23

## Ordering a migration by what it actually reaches

**Eight candidates described in one pass gave the plan its stage boundaries.**
Caller counts are what separate a five-minute swap (`improper-list-p`, one
caller) from a stage of its own (`slurp-file`, eighteen). PLAN-0036's stages are
those counts.
— migrating Loom onto the utils library, 2026-08-21

**`structure` showed Loom had no utility system to delete.** The duplicates were
scattered through loom-analyzer, loom-serve and loom-workspace, which is why the
plan edits three `.asd` files rather than one, and why there was nothing to
remove wholesale.
— migrating Loom onto the utils library, 2026-08-21

## Reading a signature without opening the file

**`describe` answered "what does this take".** Reading `build-context` meant
knowing its keyword arguments, and one line gave them: `(build-context view task
&key budget seed-limit types source-fn source-definitions)`. That was the first
time `describe` answered that question in this tree's history, and it was used
within a day of existing.
— designing REQ-0040, 2026-08-23

**`context` seeds carried the method bodies, so three accessors were read
without opening the file.** Planning front-end's PLAN-0006 Task 1 needed to know
how `LayerEditorState` resolves the active map and gates on a layer. The bundle
returned `selectMap`, `activeMap` and `hasLayer` as seeds with their source
inline — the fallback-to-primary chain in `activeMap`, the `_selectedMapName`
persistence in `selectMap` — enough to design the new `activePartition` getter
against them without reading `useLayerEditorState.js` first. (The same bundle
missed the render files the task named — TODO.md — but the accessor seeds were
right.)
— implementing front-end's PLAN-0006 Task 1, 2026-08-29

## Catching a document that has rotted, before believing it

**`check` handed over the unresolved list as a single fact**, which is what made
PLAN-0002's `affects:` decision explicit rather than accidental: 8 of
game-server's 16 unresolved references were that plan's own, failing to resolve
*because the plan succeeded* and moved those names out of the repository.
— completing game-server's PLAN-0002, 2026-08-21

**`check-document` after every document edit.** Both documents parsed, both
`refines:` resolved, every `affects:` name still resolved. A block scalar
spliced into YAML by a script is exactly the malformed-document case it exists
for. Repeated on DES-0042 the following session: five `affects:` names and two
`refines:`, all resolved.
— implementing REQ-0038 and designing REQ-0040, 2026-08-21 and 2026-08-23

## The index tracks the working tree, not the last commit

**After the deletions, `find slurp-file` returned nothing** while the tree was
still uncommitted and no restart had happened. An answer is about the bytes on
disk, which is why comparing a reported commit with `git rev-parse HEAD` is the
wrong check and `drift` is the right one.
— migrating Loom onto the utils library, 2026-08-21

## When the index was right and the reader was not

**A ranking miss that was written up, and was not one.** The query `context
bundle token budget truncation` was recorded as returning three DEFSTRUCT
accessors and not the budget. The stored record has `*context-token-budget*` at
rank 1, followed by `estimate-tokens`, `seed-matches`, `context-log-summary` and
`build-context`. What produced the false claim was reading the console output
through `tail -6` — the last six lines of a 146-item bundle, which is exactly
where three same-prefixed struct accessors sit. The seeds were at the top, off
screen. A design document was nearly written from the opposite of what Loom
said.
— designing REQ-0040, 2026-08-23

## Searching for a term the language itself uses

**`find term=import` against `front-end` returned eight entities, all of them
about importing.** The tree is JavaScript, where `import` opens most of the
533 files; `grep -rn import src/` is thousands of ES module statements with the
answer somewhere inside. The eight were `importErrorMessage` and
`SEGMENT_IMPORT_ZOOM` in the editor mock, the two files under
`domain/partition/import/`, their tests, and a fixture generator — which is the
whole of the feature, named. The bug being chased was in the mock's Import
button, and the first call landed on it.

The general point is not that the answer was short. It is that a term whose
frequency in a language is unrelated to its meaning in a codebase is exactly
where a text search degrades and a definition index does not.
— chasing front-end's BUG-0014, 2026-08-27

## The reasoning arrived with the code

**A fix that moved a measurement from 200-odd problems to 253 was not a
regression, and `context` is the only reason that was known.** Repairing the OSM
tile stitcher changed which pixels the segmentation trial classifies, and the
partition it then produced failed validation with 253 dangling-arc problems and
110 crossing-arc failures. Nothing in the code says whether that number is new.

The `documents` band of the context bundle carried `REV-0001`, which records the
same failure measured a month earlier — 93 problems and 42 failures on a smaller
bbox — with its cause already isolated by experiment: per-component
simplification running before shared-arc extraction. The finding was known,
open, and unrelated to the change in hand. Without it the honest options were to
report a possible regression or to spend a session re-deriving somebody else's
completed diagnosis.

`impact` on the repaired function carried `PLAN-0003` and `DEC-0001` in the same
way, which is where the constraint that the raster input may only ever be OSM
tiles is written down. A caller who edits the image pipeline needs to know that
and would not think to ask.
— chasing front-end's BUG-0014, 2026-08-27

## The tests band, the day it arrived

**`impact polygonsToPartition` named the one test I was not allowed to break, before
I had written a line.** The change was to add an optional simplification stage to a
shared import core with two consumers. The band listed twenty-two impacted entities
and among them `OSM import pipeline — real Golden Gate fixture > is in fact clean for
this fixture (the real data imports cleanly)` — a pin asserting that the OTHER consumer
imports with zero defects. That is what settled the design decision: the new stage
defaults to off, so the path that pin guards is untouched. Reading it out of the answer
took one call; finding it by hand means knowing that a server-side trial test exercises
a domain-layer function through two intermediate modules.

Worth recording for a second reason. The same tree reported `test-entities: 0` earlier
the same day, and the gap was filed in `docs/TODO.md` as a thing Loom could not answer
where it mattered most — the bug being chased was in the one module with no test. The
capability landed as REQ-0053 within the session, and the very next task used it to make
a decision. The loop from dogfooding note to shipped answer to a design choice that
depended on it closed inside a day.
— implementing front-end's DES-0009, 2026-08-27

## The docstring was the fix

**`describe extractSharedArcs source=true` returned the algorithm and its contract in
one call, and the contract was the answer.** The symptom was 363 findings of the form
`arc N borders 1 ring(s), expected 2` from a raster-segmentation import. The
documentation the call returned says the function takes *grid-canonical* rings and pairs
chains by exact grid-point equality — from which the cause follows immediately, without
reading the body: anything that decimates the two sides of a shared border
independently, before this runs, makes them stop being equal, and exact equality then
pairs nothing. That is a fact about a contract, not about a call graph, and it is
sitting in a docstring three modules away from the code that reported the symptom.

The fix followed from the same sentence: decimate one stage LATER, where the border is
one object instead of two.
— chasing front-end's segmentation defect, 2026-08-27

## When two definitions of one name AGREEING was the answer

**`find ringIsCCW` against `front-end` returned two definitions, and the useful content was
that they were identical.** A raster import was emitting documents its own consumer rejected
with `element 59 hole 0 is not clockwise`, and the obvious hypothesis was that producer and
consumer disagreed about winding — the orientation is decided in
`import/polygonsToPartition.js` and checked in `interchange.js`. `find` named both in one
line. `describe` on each showed the same shoelace, the same `area >= 0`.

That killed the hypothesis and produced the real one. If the two agree, the fault is not a
disagreement but the convention itself: `>= 0` makes a ZERO-area ring counter-clockwise by
definition, so a degenerate hole can never be clockwise and reversing it changes nothing. The
upstream stage was collapsing small faces to zero area.

The standing guidance says two definitions sharing a name is a thing to know before editing
either. This is the inverse case and worth recording next to it: the answer that mattered was
that neither needed editing.

Honest about the rest of that session: the index found the pair and the decisions bearing on
the area, and running the pipeline with one parameter varied found everything else. Nine
collapsed loops at one tolerance, zero at another, is not a question an index can answer and
should not be asked to.
— chasing front-end's BUG-0015, 2026-08-27

## The standing measurement

`tools/test/acceptance.py` scores 42 of 44 hand-judged expectations present across
four trees, with all three absence cases correctly returning nothing and the
slowest query at 0.33s. `tools/test/recall.py` runs 450 generated known-item cases
over the same service. Both refuse to print a figure against a service they
could not bring current, which is RULE-0008.
— 2026-08-24
