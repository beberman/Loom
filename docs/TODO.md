describe apply-transaction still shows one caller. 

Calls made from inside (test ...) macro bodies aren't attributed because defmacro is not expanded

TODO: watch already expands ~ to find the file so ~/lisp works.
However unwatch does not because it pulls the full directory name in
as the name of the workspace

I have an unexplained number. Indexing Loom went from 571 entities
before the resolution passes to 581 after. Resolution creates edges,
not entities, so that shouldn't move at all. Every suite passes
including reindexing-produces-an-identical-index, so it isn't drift
between incremental and rebuilt indexes — but I haven't accounted for
it, and I'd rather say so than let it pass as noise. Worth me chasing
before this is called done.

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