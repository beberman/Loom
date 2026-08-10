## Closed, 2026-08-09 — kept briefly so the answers are not re-derived

- "describe apply-transaction still shows one caller" — fixed. It now shows
  68 incoming calls and 68 tests.

- "Calls made from inside (test ...) macro bodies aren't attributed" — fixed
  by ARCH-0002's definer call sites plus resolve-generated-definitions.
  451 tests covering 305 units.

- "unwatch does not expand ~" — fixed 2026-08-09, and the diagnosis here was
  slightly off: the name is just the last path component ("Loom"), not the
  full directory. The cause was find-repository comparing an unnormalised
  designator against a root that watch had already run through probe-file.

- "571 entities before the resolution passes, 581 after" — answered, not a
  defect. The premise is false: resolution *does* mint entities.
  resolve-generated-definitions creates them from definer call sites, and the
  :test entity's own ontology docstring says so ("unlike every other
  definition entity this one is usually minted by a resolution pass rather
  than by an analyzer"). The ten were generated definitions.

---

## From the ~/lisp/game-server evaluation, 2026-08-06

Pointed Loom at a second real Lisp codebase (127 lisp files, 2151
entities, indexed in 3.4s) and asked it the two questions it exists to
answer: what does changing cascade-delete reach, and what would
restructuring the data-api handler protocol touch. It answered the
second well and the first wrongly. Six requirements came out of it,
listed in priority order. The recurring theme is worth naming on its
own: three of the six are mechanisms that are correct against Loom's
own tree and wrong against the next one, for reasons invisible from
inside the first. One reference codebase cannot exercise a language.

1. REQ-0012 — walk inline (:method ...) bodies inside DEFGENERIC.
   game-server writes 247 of them against 158 defgenerics; Loom writes
   2 in 7, which is why this has never been felt here. The whole
   default layer of the handler protocol has no outgoing edges.
   generic-definition-entity reads (second form) and (third form) and
   discards the rest; method-definition-entity right below it already
   does the whole job and should be reused.

2. REQ-0013 — say when an answer was built from dropped edges, at the
   point of the answer. 3037 unresolved calls in game-server (48.2%),
   1859 in Loom (47.9%), and every user-visible surface reports zero.
   :unresolved-calls is written at resolve.lisp:570 and read by
   nothing. CON-0001 says "stays unresolved and gets reported" — only
   the first half is built. A global counter is the weak version; the
   useful one is per-query.

3. REQ-0014 — index markdown, assert :mentions (not :affects).
   game-server has 3906 lines across 12 md files and Loom reports
   documents: 0, so everything impact offers beyond a call graph is
   unavailable there. The backticked identifiers and relative links
   are already machine-readable. A backtick is evidence a file names
   something, not that it governs it — hence the weaker edge type.

4. REQ-0015 — an ambiguous call should become several discountable
   edges, not no edge. id: 7 definitions, 144 dropped sites.
   definition: 3 and 50. cascade-delete: 2 and ~12. resolve.lisp
   already threads :confidence and :derived-from and never reaches
   them for this case. The cost of the current rule is not neutral —
   it scales with how much a codebase uses CLOS.

5. REQ-0016 — context must rank by structure, not substring.
   `context data-handler` on game-server returned 22 entities: CORS
   handlers, event callbacks, test fixtures, and not the DATA-HANDLER
   class or any of its 21 dhandler-* generics. Meanwhile `impact
   data-handler 5` walks the whole hierarchy correctly, so the graph
   has what the ranking is ignoring. Loom's own unusually unique
   entity names are what make this look fine here.

6. REQ-0017 — generating REQ/ARCH from markdown. Wanted, and the
   riskiest thing on this list. A generated requirement asserts
   structure its source never committed to, and the graph lends it
   authority it didn't earn. Only acceptable with provenance on every
   document and a status the rest of the system refuses to treat as
   settled. Needs REQ-0014 first — you can't check a generated
   requirement against a source that isn't indexed.

Not made into requirements, but found in the same session:

- REQ-0005 (open since 2026-07-29) got fresh confirmation: `impact
  data-handler 5` returns rows labelled d6, and prints `(truncated)`
  as a boolean over 253 rows covering 208 distinct entities. The
  duplicate rows are their own small problem — 18% of that output is
  the same entity repeated, eating a budget that then can't reach
  model-handler and operator-handler.

- find / describe / impact / context take no repository argument, so
  with two repositories watched all four refuse: "Several repositories
  are watched; name one." There is no way to name one. `unwatch` takes
  a name and is the only workaround, so you cannot compare two
  codebases in one session. Related to the older unwatch note above.

- This file is markdown under docs/, so Loom cannot see any of it.
  That is REQ-0014's argument, sitting in the place that makes it.

---

## Reader and call-site work, 2026-08-09 — now in indexed documents

The long analysis that used to sit here has moved into docs/, which is the
point of REQ-0014's argument above: it is queryable there and invisible here.

- **REQ-0019** — the Lisp analyzer should read through a conforming,
  customizable, recovering reader. Measured: 169 lines across four functions,
  241 package-qualified operators with the prefix discarded, one bad form
  costing a whole file, the index depending on the analyzing implementation's
  \*features\*.
- **ARCH-0013** — Eclector behind a Loom-owned client, raw s-expression
  unchanged, annotations in EQ-keyed side tables. Also folds in the
  head-name dispatch table replacing pass 1's ten definition-p calls, and
  says why definition-p itself survives (no conforming reader knows what a
  defun is; the CST taxonomy is two classes).
- **ARCH-0014** — a :call-site entity exactly where a call cannot be an edge
  from a definition. The uniform reference-node model was priced and refused:
  4867 call-name occurrences against 1604 entities is 4x for 18 ambiguous
  occurrences, 42 orphaned names and one initform.

Rejected on the record, in REQ-0019's WHAT THIS IS NOT and ARCH-0013's
alternatives: Cleavir (macroexpands, so it needs target code loaded in-image),
a shared cross-language CST as the intermediate representation (the uniform
layer is the ontology operation, one level up), and hand-rolling or reviving a
CL parser for TypeScript or Python (nothing exists for TS; parse-js is ES3;
CLPython is Python 2, unmaintained since 2013).

Still unwritten, both named in ARCH-0014's deferred list:

- A batched, out-of-process analyzer in the analyzer protocol. analyze-file is
  per-file and stateless, so a Python or Node process per file across 174
  files destroys the seconds-scale budget watch meets. This is on the critical
  path for any second language and gates nothing on the Lisp side.
- Dropping :unresolved-calls as a stored property, and taking generated
  entities' :system from the call site rather than the file.

