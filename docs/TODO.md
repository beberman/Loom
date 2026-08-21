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

Also, and smaller: `tools/loom-serve.sh update` failed at the start of the
session with *"nothing answering on http://127.0.0.1:4780/v1 after ~20s"*, and
the service answered normally twenty minutes later without intervention. So the
first thing the CLAUDE.md section tells an agent to do is the thing that failed,
and the fallback it trains is the grep habit the rest of that section exists to
prevent. Whatever the cold-start cost is on this machine, ~20s does not cover
it; a longer wait, or a failure message that says "still starting, retry" rather
than reading as "Loom is unavailable", would change what the agent does next.
