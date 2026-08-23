# The vocabulary-mismatch case family

REQ-0047, DES-0039, PLAN-0042. 120 cases in `mismatch.json`, in the four-tuple
`tools/recall.py` reads: `[repository, query, expected-name, family]`.

Every query describes what an entity does in words its author did not use. That
is checked rather than intended: `tools/mismatch-check.lisp` loads
`loom-knowledge`, runs the query through `TASK-TOKENS`, and rejects the case if
any token reaches the entity the way `SEED-MATCHES` would — as a
case-insensitive substring of any name the expected entity carries in that
repository, or as a whole word of any of their docstrings.

## The bar, 2026-08-22

    mismatch    strict 9/120   7.5%    lenient 9/120   7.5%

    front-end     3/86    3.5%
    game-server   6/34   17.6%

Measured against the seeder as it stood with BUG-0041 and BUG-0042 closed, and
recorded before anything was built to move it. On the same day the three
generated families in `known-item.json` scored 410 of 450, 91.1%.

No seed ever carries the answer — a query disjoint from the name and the prose
cannot be matched by the seeder. All nine hits arrived through the neighbour
band, reached from a seed that shared a word with the query. So this family
measures the expansion, and a change that narrows the neighbour band will show
up here as a fall.

The per-repository gap is the one REQ-0047's second open question predicted.
front-end carries a docstring on 999 of 3457 definitions and game-server on 408
of 1811; a repository whose prose is thinner gives the checker less to forbid
and the expansion less to travel on.

## How it was generated

- **By** Claude Opus 5 (`claude-opus-5`), in a Claude Code session, on 2026-08-22.
- **From** `tools/entity-dump.lisp` over `game-server` and `front-end`,
  filtered to definitions with a name of two or more parts, a docstring of 45
  characters or more, and a path with no test segment in it.
- **Instruction**: describe what this definition does, in words that appear
  neither in its name nor anywhere in its documentation, such that a person who
  knew the repository could name it from the description alone.
- **Loop**: write, run `mismatch-check.lisp`, rewrite what it rejected.

The first batch was written without seeing the entity's own vocabulary and 48
of 60 were rejected. Printing the forbidden word list beside each entity before
writing took the next three batches to 99 kept of 103. That number is worth
keeping: it is how much of the work of writing a mismatch query is knowing
which words are already taken.

This family cannot be re-derived from a seed the way the other three can. The
record above is what replaces that, along with the checker: anyone who
distrusts the family can re-run it.

## What twenty hand-read cases say

REQ-0047 R7. Twenty sampled with `random.Random(20260822).shuffle`, read
against the tree, one question: could a person who knew this repository name
the entity from this query alone?

**17 of 20.** The three failures, kept in the family rather than removed —
dropping them would make it easier by exactly the amount the reader was unsure:

- `pin an arriving spot onto the fine lattice so sameness is precise` for
  `fromLL`. It describes snapping to the integer grid, which is what `fromLL`
  documents — but `toGrid` and `onGrid` are both in this family and both fit
  the words better than the name does.
- `fuse adjoining areas by taking out the divider` for `mergeFaces`, which is
  near-interchangeable with this family's own
  `drop the divider between neighbouring areas so they become one` for
  `TerrainPartition.removeArc`. The two entities document each other; the two
  queries do not separate them.
- `what a square becomes when nothing says otherwise` for `DEFAULT_TILE_TYPE`.
  A fair description and not a fair question.

Two of the three are the same defect: a disjointness check has no opinion about
whether two cases in the family are about the same thing. Nothing here
currently detects that pair.
