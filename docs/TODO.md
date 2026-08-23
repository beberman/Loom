Requirements should have an importance field


WHAT WAS REMOVED FROM THIS FILE, 2026-08-21

Reviewed every item against the document that was supposed to carry it, and
deleted the ones a requirement already says. The deletions, and where each one
lives now, so nobody re-derives it:

| Removed | Now carried by |
|---|---|
| REQ-0012's remaining half — `describe` resolving a name through SEARCH-ENTITIES' first hit, so an :INTERFACE/:METHOD tie falls to index order | REQ-0012 OUTSTANDING item 1, in the same words, and it names the open question as loom-knowledge's |
| REQ-0013's measurement — 3,037 unresolved calls at 48.2%, `:unresolved-calls` written at resolve.lisp:570 and read by nothing, a global counter being the useless fix | REQ-0013 body, including the counter argument |
| REQ-0015's R6 failure and its cause | REQ-0020, which was written to carry exactly that trace |
| REQ-0016's measurement — `context data-handler` returning 22 substring matches and none of the 21 `dhandler-*` generics | REQ-0016 summary, verbatim, with R-level acceptance |
| REQ-0017's risk argument — a generated requirement asserting structure its source never committed to | REQ-0017 body |
| `impact`'s `(truncated)` printed as a boolean | REQ-0005, which proposes `14 impacted, 31 more at depth 4` in its place |
| The 2026-08-09 rejections — Cleavir, a shared cross-language CST, reviving a CL parser for TS or Python | REQ-0019's WHAT THIS IS NOT and DES-0013's alternatives |
| A batched, out-of-process analyzer | REQ-0024's open question 1, which measures it against 455 files and answers that acorn does not batch |
| `describe` on a generic reading as unused because the inbound count sits on the methods | REQ-0012 OUTSTANDING item 1 — the same defect from the other side |
| The index's value being the prose a human wrote rather than the graph | REQ-0035, implemented: the prose a definition carries is indexed now |

What stayed was checked the same way and is in no document: the duplicate rows
in `impact` output, and the items under 2026-08-18 and 2026-08-21 below.

---

## From the ~/lisp/game-server evaluation, 2026-08-06

One finding from that session is in no document. The rest is in REQ-0012,
REQ-0013, REQ-0016, REQ-0017, REQ-0018 and REQ-0020.

- **`impact` repeats entities in its output.** `impact data-handler 5` returned
  253 rows covering 208 distinct entities — 18% of the answer is the same
  entity again, eating a budget that then cannot reach model-handler and
  operator-handler. REQ-0005 is about how truncation is *reported*; this is
  about the rows being spent twice before truncation is reached, and neither it
  nor any other document says it. The same run labelled rows `d6` at depth 5,
  which was recorded then and has not been re-checked since.

---

## Reader and call-site work, 2026-08-09

REQ-0019, DES-0013 and DES-0014 are in. One item from that work is still
unwritten and still true of the tree:

- **Drop `:unresolved-calls` as a stored property, and take a generated
  entity's `:system` from the call site rather than the file.** Still stored as
  of 2026-08-21: four declarations in `src/ontology/code-ontology.lisp` and the
  write at `src/graph/resolve.lisp:1295`. DES-0014 explains what the property
  buys RESOLVE-CALLS but does not defer removing it, so this is the only record.

---

## From the ~/lisp/utils extraction, 2026-08-18

Registered the five unregistered repositories under ~/lisp and used the index
to decide what a shared utility library should contain, measuring game-server's
utils package against what Loom and datascience/pursuit had each built for
themselves. It produced REQ-0001 and ARCH-0002 in the utils tree.

Three items came out of it.

1. **A check for source files absent from every ASDF component list.** The
   sharpest blind spot found. Loom indexes a file whether or not any system
   loads it, so `game-server/utils/token.lisp` and
   `datascience/pursuit/utils/range-tree.lisp` — 12K of the latter — both index
   normally, both export names, and neither is in its `.asd`. Loom reported
   their functions as having zero callers, which was true for the wrong reason:
   there is nothing to call, because nothing loads them. Between them they
   account for four of the dead exports the measurement found, and the only way
   to see it was to read the `.asd` by hand. This is mechanically detectable —
   the analyzer already reads `.asd` files as Lisp, so the component lists are
   in reach — and it belongs next to the existing unresolved-reference report.
   The neighbouring case is the same class and also worth catching: a name
   exported by a package and defined nowhere. `matrix-utils` exports
   INNER-PRODUCT, FLETCHER-REEVES, POLACK-RIBIERE and CONJUGATE-DIR, none of
   which exists anywhere under ~/lisp, and its own test suite calls all four.
   `find` returning nothing was the signal, but nothing reports it unasked.

2. **`init` cannot refresh a marked region it wrote.** The guidance rewrite
   itself is done — `templates/claude-md-pointer.md` and `templates/loom-skill.md`
   both carry the question-shape table and what the index cannot see, and
   templates are read from disk so it lands on the next `init` without a
   rebuild. What it does not reach is any repository already prepared. `init`
   skips a CLAUDE.md that already carries a marked region and refuses to
   overwrite an existing skill, so the eight registered here keep the old text
   until each is edited by hand. Deliberate, because both files may hold an
   author's edits — but the marked region exists precisely to make replacing
   Loom's own bytes safe, and nothing uses it for that. Worth designing.

3. **`context` overflows the caller's output limit on a question.** Twice in
   one session, at 58KB and 76KB, on tasks phrased as questions rather than as
   edits. It is built for "I am about to change this, what bears on it" and is
   the wrong shape for "does an equivalent of this exist" — for which `find` is
   one line against sixty. The skill now steers the yes/no question to `find`,
   which is guidance rather than a fix: a size-aware `context` that trims to a
   budget the caller names would be the fix, and nothing asks for one.

---

## From completing game-server's PLAN-0002, 2026-08-21

The migration whose plan came out of the extraction session above is finished:
the integration suite was the plan's single final gate, it was failing, and the
session was three bugs, a plan transition and a push. Worth recording because
it is the first time Loom was used on the *aftermath* of a migration it helped
design, and the aftermath asks a different question than the design did.

**The honest verdict first: none of the three bugs was found with the index,
and mostly that is correct.** They were found with `grep`, `git log -S`, and
one commit message. The questions a broken test asks are "why does this decode
return NIL" — semantics, you have to read the function — and "when did this
default change, and did the author mean it". The second is the one worth
dwelling on. `de355d0`'s message says *"Debugging found that the
game-description/image url was wrong"*, and that sentence is the entire
evidence that a stale fixture was stale rather than the server being wrong. The
index holds the tree's present. A migration's debris is a question about its
past, and `git log -S` is the tool. Loom should not try to be; it should be
said out loud that it is not, because an agent told "ask Loom before reading
the tree" will otherwise ask it the wrong question first.

What the index did earn, all of it at the end and none of it in the debugging:
`find` proved `get-package-file` resolves in **neither** repository, against a
plan that lists it under "KEPT IN gs-utils" and a CLAUDE.md that cited it in a
worked example — one call overturning two documents. `check` handed over the
unresolved list as a single fact, which is what made the `affects:` decision
below explicit rather than accidental. `structure`'s commit stamp confirmed the
answers were about the tree I had just changed.

Three items.

1. **`find` should answer across registered repositories, or say that it
   didn't.** This is the sharpest one and it generalizes past game-server.
   PLAN-0002's whole content was that half of `gs-utils` moved to a second
   repository, and the question the tree now generates constantly is *which of
   the two owns this name*. Both are registered — `game-server` and `utils` —
   so the answer is two `find` calls. I made four grep calls instead, because
   nothing in the prepared guidance says a second repository is there: every
   example in the generated CLAUDE.md block and in the skill names one
   repository, and `repository` reads as a required scope rather than as a
   choice among several. A `find` with no repository that searches all of them,
   or a zero-hit answer that adds "0 here; 1 in `utils`", turns the miss into
   the answer. The zero-hit case is the valuable half: a name absent from one
   repository and present in another is a migration telling you where it went,
   and a name absent from both is dead — which is exactly how
   `get-package-file` was caught.

   Note also that the prefix lies, which is why the shell cannot substitute
   here. `#:gs-utils` USEs `#:utils` and re-exports its symbols, so
   `gs-utils:dict-value` and `utils-dict:dict-value` are one symbol object and
   the definition is in the other tree. Grep on the prefix finds call sites in
   the wrong repository forever.

2. **`complete` cannot finalize a plan that refines nothing.** A hard blocker,
   hit head-on. `complete-plan` is dry-run when `(null parsed)`, and `parsed`
   comes from `verdicts`; a plan with no `refines:` edges reaches no document
   but itself, so there is no verdict to give, and any verdict offered is
   refused with *"PLAN-0002 is not in this cascade"*. The command therefore
   returns `would-set` forever and writes nothing. `set-status PLAN-0002 final`
   is the way through and worked first time, but both the skill and the
   generated CLAUDE.md say "run the transition command" and mean `complete`,
   and `set-status` is mentioned once at the bottom as the escape hatch for a
   *blocked* document. Either `complete` should write when the cascade is the
   plan alone — there is nothing to decide, which is precisely why the
   all-or-nothing safety argument does not apply — or its dry-run report should
   name `set-status` when the frontier comes back empty.

3. **A completed migration plan's `affects:` can never resolve, and `check`
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

Also, and smaller, now measured: **`tools/loom-serve.sh update`'s start timeout
is too short, and it is off by about ten seconds.** It failed twice in one day
with *"nothing answering on http://127.0.0.1:4780/v1 after ~20s"*. The second
time the service was polled immediately afterwards and answered within a further
ten -- so the real cold start with 9 repositories is roughly 25-30s against a
20s wait, and the script reports a healthy service as a dead one. The first
thing the CLAUDE.md section tells an agent to do is therefore the thing that
fails, and the fallback it trains is the grep habit the rest of that section
exists to prevent. A longer wait, a wait that scales with the number of watched
repositories, or a message that says "still starting, retry" rather than reading
as "Loom is unavailable".

---

## From migrating Loom onto the utils library, 2026-08-21

The task: find what ~/lisp/utils already does, delete Loom's own version, depend
on the library. It produced PLAN-0036 and landed that plan's S1. It was also the
first task deliberately run as a measurement of Loom, so what the index did and
did not do is recorded here at the same grain as the work.

WHERE THE INDEX WAS DECISIVE

- **`describe slurp-file` returned 16 source callers and 2 tests, by location,
  across three systems.** `grep -rn slurp-file src/` returns 27 lines, of which
  four are a docstring, an export, a comment about where files get read, and the
  definition. Deciding "is this safe to delete and how much moves" from the grep
  means reading all 27; the index answered it once. This is the case
  "before deleting anything, ask Loom" was written for, and it held.
- **Eight candidates described in one pass gave the ordering of the plan.**
  Caller counts are what separates a five-minute swap (improper-list-p, one
  caller) from a stage (slurp-file, eighteen). The plan's stage boundaries are
  those counts.
- **`structure` showed Loom has no utility system.** The duplicates are scattered
  through loom-analyzer, loom-serve and loom-workspace, which is why the plan
  edits three .asd files rather than one, and why there was nothing to delete
  wholesale.
- **The watcher stayed current through the edits.** After the deletions,
  `find slurp-file` returned nothing while the tree was still uncommitted and no
  restart had happened. Worth knowing that the index tracks the working tree.

WHERE IT COULD NOT HELP, AND THIS IS THE FINDING

1. **The task's central question -- does this codebase already have its own X --
   is a similarity question, and `find` matches names.** All ten duplicates are
   named differently: slurp-file/read-file, split-lines/string-lines,
   alist-object-p/alistp, fnv-1a/content-fingerprint, text-lines/string-lines.
   Asking `find` for each of the library's 44 exported names against Loom
   returned two hits, one of them a test helper. Every real duplicate was found
   by grepping Loom's own definition names for utility-shaped words
   (`string|split|join|trim|slurp|file|json|alist|hash|...`) and reading the
   bodies. That is the method the index was supposed to replace.

   What would have answered it: a query that takes a definition and returns
   definitions like it -- by signature, by body shape, or by docstring. The
   cheapest useful version is the last one, because a function extracted from
   another codebase carries its ancestor's prose. UTILS:CONTENT-FINGERPRINT and
   Loom's FNV-1A share whole sentences ("Deterministic across images, which
   SXHASH is not"), as do ALIST-OBJECT-P and ALISTP. A near-duplicate docstring
   detector would have found four of the ten pairs in one call. REQ-0035 already
   indexes the prose; nothing asks it this question.

2. **Two functions being the same function is not something the index can say,
   and half of the pairs that looked identical were not.** FNV-1A hashes the low
   octet of each character and CONTENT-FINGERPRINT hashes all of them, so they
   agree on ASCII and diverge on the em dashes this repository's own diffs are
   full of -- and that value gets written into context records. TEXT-LINES
   returns a list where STRING-LINES returns a vector. PLIST-SHAPED-P and PLISTP
   disagree about the empty list, at exactly the decision the caller uses them
   for. Each was caught by reading both bodies. `describe source=true` makes
   that reading one call instead of two file opens, which is real but small: the
   judgement is entirely manual and the index offers nothing toward it.

3. **Cross-repository, again, and this time expensively.** The whole task is
   "compare repository A against repository B", both registered, and every query
   names one of them. There is no call that takes two and reports what they have
   in common. The 2026-08-21 entry above asks for `find` to answer across
   repositories; this is the same gap met from the other side, and the shape it
   wants here is a *diff* rather than a lookup.

4. **`commit` in a `structure` answer is not the state of what was indexed.**
   The field named the last commit while the index reflected a working tree with
   twenty-four modified files. It is not wrong, and CLAUDE.md's advice to compare
   it against `git rev-parse HEAD` reads as "the index is current" in exactly the
   state where the two agree and the content does not. REQ-0036 R4 already knows
   this -- it pairs the commit with a diff hash for precisely this reason -- and
   the same pairing belongs in `structure` and `status`.

---

## Using Loom to implement REQ-0038, 2026-08-21

A record of what the index answered while S3 and S4 were written, kept because
REQ-0038 is the requirement about measuring Loom and a session spent inside it
is evidence of the same kind. Three items below are in no document; the rest is
the usage log.

### Where the index answered and the shell would have been worse

- **Locating the six entities in DES-0031's `affects:`.** `find` on
  `record-query`, `answer-shape`, `record-read-query`, `invoke-operation`,
  `record-context-call`, `record-context-use` and `drain-context-log` returned
  `file:line-range` for each, one line apiece. Two of the seven were not where
  the design implied — `record-read-query` is in `src/serve/registry.lisp`, not
  in `context-log.lisp` beside the writer it calls, and `find` said so without
  a file being opened.
- **`record-context-call` had two call sites and `find` listed both** —
  `src/serve/operations.lisp:260` and `src/process/console.lisp:751`. The
  console one was not in view from the design and is the second skin D1 argues
  about.
- **`structure`'s commit field, before trusting anything.** `cf51f6f` against
  `git rev-parse HEAD`, equal, so every answer above was about the tree on
  disk. This is the discipline the corpus itself recommends, in the judgement
  reading *"loom_structure commit field — USED, and it should be advertised"*,
  and it cost one call.
- **`check-document` after each of the two documents was edited.** Both parsed,
  both `refines:` resolved, every `affects:` name still resolved. A block scalar
  spliced by a script is exactly the malformed-document case it exists for.

### Where the shell was required

- **`tools/acceptance.py` is invisible.** `find acceptance` and
  `find score_judgement` both return nothing: Python is not analyzed, so the
  entire subject of S3 and S4 — 400 lines of harness — has no entity, no
  callers and no documents attached to it. Every question about it was `sed`,
  `grep` and reading the file. This is a known absence rather than a defect
  (REQ-0019 and DES-0013 record the rejected approaches), but it is worth
  stating in one place that the tree's own measurement harness is the part of
  the tree Loom cannot answer questions about.
- **The corpus itself.** `.loom/context/` is a dot-directory and deliberately
  unindexed, so every fact that drove the design — 193 records, 10 carrying an
  `:operation` field, 15 judged, 18 of 41 used entries not being names — came
  from `python3` over the raw JSON. Correct that it is excluded; worth knowing
  that reasoning about the log is always shell work.
- **Document statuses.** `sed`/`grep` over `docs/*/`, because the `loom_*` MCP
  tools were not in this session's tool list and the REST skin has no "show me
  this document's status" call short of `check-document`, which reports
  references rather than status.

### Items no document carries

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


- **Loom-side acceptance cases cannot measure Loom-side commits, and prose is
  the vector.** On 2026-08-22 `log-1` ("trim whitespace from a string") went
  from a hit to a miss with no semantic change to the seeder: `js-trim` was
  displaced by `task-token-origins`, `seed-matches` and `best-name-rank`, three
  functions whose docstrings had just been written to explain BUG-0040 and so
  are dense in "string", "str", "stre" and "trim". `tools/acceptance.py`'s
  header already warns that "every commit to it changes the corpus a Loom-side
  clause measures", and that warning was written about code; the measured
  vector was documentation. `log-1`, `r39-3` and the three `ABSENCE_CASES` are
  all Loom-side and all inherit the problem. DES-0033 records the three
  attempts it took to establish, including one experiment that moved two
  variables at once by stashing the source file and thereby removing the new
  docstrings with it.


- ~~The harness contaminates the corpus it measures.~~ Written here on
  2026-08-21 and moved the same day: REQ-0038's DECIDED section carries it, along
  with the purge that answers it — keep records carrying a judgement, drop
  unjudged `find` records older than the current commit.

- **`tools/loom-serve.sh update` reports failure while the service is starting.**
  It printed `nothing answering on http://127.0.0.1:4780/v1 after ~20s` and the
  service was answering normally moments later; the cold start is longer than
  the script's timeout. The failure text names a log file and reads as broken,
  which is what CLAUDE.md tells every session to run first.

- **`find term=join` against Loom now returns 2.** The judgement recorded on
  2026-08-18 says *"Confirmed with find term=join returning nothing"* and it was
  the corpus's cleanest correct-negative. The tree has changed under it. Nothing
  is wrong — the record is right about what it saw — but it is a worked example
  of REQ-0036 R4's decay, and the absence cases in `ABSENCE_CASES` should be
  re-checked before REQ-0037 is measured against them.

## Using Loom to design REQ-0040, 2026-08-23

Kept for the reason the REQ-0038 section above was: REQ-0040 is the requirement
about what a bundle costs its reader, and a session spent reading bundles is
evidence of the same kind. Context logging was switched on for the session with
`LOOM_CONTEXT_LOG=1`, against the default recorded in the previous section, and
the corpus went 30 records to 34.

### Where the index answered and the shell would have been worse

- **`find estimate-tokens`, `find render-context`, `find context-token-budget`
  in one call** returned `file:line-range` for each, and returned the two
  `call-site` entities beside them — `estimate-tokens@src/process/console.lisp:599`
  and `render-context@src/process/console.lisp:897`. The second is the console's
  own use of the renderer, which is a surface D4 has to change and which no
  reading of `context.lisp` would have shown.
- **`describe` gave the signature this session added.** Reading `build-context`
  meant knowing its keyword arguments, and BUG-0044's line answers that without
  opening the file: `(build-context view task &key budget seed-limit types
  source-fn source-definitions)`. That is the first time in this tree's history
  that `describe` answered "what does this take", and it was used within a day
  of existing.
- **`check-document` on DES-0042 before believing it.** Five `affects:` names
  and two `refines:` all resolved.

### Where the index was worse than the shell, and this is the item worth keeping

- **`context bundle token budget truncation` did not return the budget.** The
  seeds were `context-log-entry-p`, `context-log-task` and
  `copy-context-log-entry` — three DEFSTRUCT accessors generated by one
  `make-context-log-entry`, none of them about budgeting. `*context-token-budget*`,
  `admit-item`, `estimate-tokens` and the `truncated` flag are the subject of
  the query and the bundle named none of them.

  It is worth being exact about the shape, because it is not the vocabulary
  gap REQ-0047 measures. Every word of the task appears in the source: the
  parameter is literally named `*context-token-budget*` and the flag is
  literally named `truncated`. This is a ranking miss on words that are there,
  and the winner is a family of struct accessors sharing one prefix — the same
  shape BUG-0041 closed for names spending seed slots, arriving through a
  different door.

  Not filed as a bug because one query is an anecdote and the generated
  instruments do not cover it: `known-item` builds its queries from an entity's
  own name or docstring, so no case in it asks for a *concept* named by two
  common words. Recorded here as the query to build a case from.

- **The measurement that drove the whole design came from a script.** The table
  in DES-0042 — index tier, source tier, per-body cost, rendered total — is
  `build-context` and `render-context` called directly from SBCL. No console
  command reports `:source-tokens`, `:sourced` or the rendered byte count, and
  `render-context`'s own header prints `~2477/4000` while handing over 7777
  tokens. Loom cannot currently be asked the question REQ-0040 is about.

### Items no document carries

- **`tools/call-site-census.lisp` was broken and nobody knew.** Its registry
  and quickload list predate loom-embed, which loom-knowledge has depended on
  since PLAN-0043, so the instrument `*CALL-SITE-CEILING*`'s failure message
  tells you to re-run could not load at all. Fixed in passing during PLAN-0044.
  The general shape is worth a rule: a tool under `tools/` that loads a system
  has a dependency list that drifts, and nothing runs it until something fails.

- **A test that reads a live document pins a judgement.**
  `IMPORTANCE-IS-READ-AS-A-KEYWORD-FROM-THE-VOCABULARY` asserted REQ-0037 was
  `:CRITICAL`; repricing REQ-0037 to Minor broke it, and the failure was
  reported twice as a standing loom-analyzer defect before being read properly.
  Split into fixtures for the vocabulary and one live assertion that does not
  name a level (BUG-0044). Worth checking whether any other test reads
  `docs/` and asserts a value that is a judgement rather than a format.
