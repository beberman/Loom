## From the ~/lisp/game-server evaluation, 2026-08-06

Pointed Loom at a second real Lisp codebase (127 lisp files, 2151
entities, indexed in 3.4s) and asked it the two questions it exists to
answer: what does changing cascade-delete reach, and what would
restructuring the data-api handler protocol touch. It answered the
second well and the first wrongly. Six requirements came out of it; five
are still open, listed in priority order. The recurring theme is worth
naming on its own: three of the six are mechanisms that are correct
against Loom's own tree and wrong against the next one, for reasons
invisible from inside the first. One reference codebase cannot exercise
a language.

1. REQ-0012 (**partial**) — walk inline (:method ...) bodies inside
   DEFGENERIC. PLAN-0009 landed DES-0010 and closed R1–R4 and R6; the
   inline clauses are analyzed and BUG-0011's fix put the missing call
   names on the :METHOD entity. What is left is R5's second half: the
   fact holds but the query does not. `describe dhandler-delete` still
   misses the outgoing calls, because the calls sit on the :METHOD and
   `describe` resolves a name through SEARCH-ENTITIES' first hit, whose
   sort ranks match quality only — so an exact-name tie between the
   :INTERFACE and the same-named :METHOD falls to index order. Whether
   `describe` should prefer, merge or disambiguate same-named entities
   is a loom-knowledge question DES-0010 deliberately left alone.
   BUG-0012 is disclosed alongside it: an inline clause and a standalone
   DEFMETHOD colliding on one natural key in one file leave a union of
   both definitions' outgoing edges on the survivor.

2. REQ-0013 — say when an answer was built from dropped edges, at the
   point of the answer. 3037 unresolved calls in game-server (48.2%),
   1859 in Loom (47.9%), and every user-visible surface reports zero.
   :unresolved-calls is written at resolve.lisp:570 and read by
   nothing. CON-0001 says "stays unresolved and gets reported" — only
   the first half is built. A global counter is the weak version; the
   useful one is per-query.

3. REQ-0015 (**partial**) — an ambiguous call should become several
   discountable edges, not no edge. DES-0014 answered this and PLAN-0014
   landed it on 2026-08-10, in a shape the requirement did not name: the
   N edges run from an :ambiguous :CALL-SITE the caller *contains*
   rather than from the caller itself, which is what lets the fan-out
   happen without the caller looking coupled to code it never touches.
   Measured here: 18 ambiguous sites, :candidate-count 2 each, two
   :CALLS edges at confidence 0.5. R1–R4 are met. R6, the acceptance
   criterion, was run and **did not pass** — `impact cascade-delete 3`
   on game-server still reports one impacted entity, that entity's own
   file. The cause is a misreading in the requirement rather than a
   defect in what was built: `id`'s 7 definitions and `cascade-delete`'s
   2 are one generic function each, not rival definitions among which a
   resolver must guess. REQ-0020 is the finding and carries the trace.

4. REQ-0016 — context must rank by structure, not substring.
   `context data-handler` on game-server returned 22 entities: CORS
   handlers, event callbacks, test fixtures, and not the DATA-HANDLER
   class or any of its 21 dhandler-* generics. Meanwhile `impact
   data-handler 5` walks the whole hierarchy correctly, so the graph
   has what the ranking is ignoring. Loom's own unusually unique
   entity names are what make this look fine here.

5. REQ-0017 — generating REQ/ARCH from markdown. Wanted, and the
   riskiest thing on this list. A generated requirement asserts
   structure its source never committed to, and the graph lends it
   authority it didn't earn. Only acceptable with provenance on every
   document and a status the rest of the system refuses to treat as
   settled. Its prerequisite, REQ-0014, is now in.

Not made into requirements, but found in the same session:

- REQ-0005 (open since 2026-07-29) got fresh confirmation: `impact
  data-handler 5` returns rows labelled d6, and prints `(truncated)`
  as a boolean over 253 rows covering 208 distinct entities. The
  duplicate rows are their own small problem — 18% of that output is
  the same entity repeated, eating a budget that then can't reach
  model-handler and operator-handler.

---

## Reader and call-site work, 2026-08-09 — now in indexed documents

The long analysis that used to sit here has moved into docs/, which was the
point of REQ-0014's argument: it is queryable there and was invisible here.
Since REQ-0028 this file is claimed too, wherever it sits.

REQ-0019, DES-0013 and DES-0014 are all in. Rejected on the record, in
REQ-0019's WHAT THIS IS NOT and DES-0013's alternatives: Cleavir
(macroexpands, so it needs target code loaded in-image), a shared
cross-language CST as the intermediate representation (the uniform layer is
the ontology operation, one level up), and hand-rolling or reviving a CL
parser for TypeScript or Python (nothing exists for TS; parse-js is ES3;
CLPython is Python 2, unmaintained since 2013).

Still unwritten, both named in DES-0014's deferred list:

- A batched, out-of-process analyzer in the analyzer protocol. analyze-file is
  per-file and stateless, so a Python or Node process per file across 174
  files destroys the seconds-scale budget watch meets. This is on the critical
  path for any second language and gates nothing on the Lisp side.
- Dropping :unresolved-calls as a stored property, and taking generated
  entities' :system from the call site rather than the file. Still a stored
  property in code-ontology.lisp as of 2026-08-14.
