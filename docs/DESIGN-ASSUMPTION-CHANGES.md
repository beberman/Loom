# What has to change in docs/ to implement the document-store framing

Revised 2026-09-15. Replaces the first version of this file, which covered
decisions and requirements from memory and never swept `docs/rules`,
`docs/arch` or `docs/design`. This version is a document-by-document pass over
every active concept, rule, architecture note, design and decision, plus the
requirements already identified.

This is a triage note, not a workflow document. Nothing here has been applied.
Dispositions are proposals.

---

## 1. The change being propagated

`docs/Loom - A Code Knowledge Engine.docx` now asserts:

> The knowledge graph is derived from a store of documents and is never a second
> copy of the truth. It can be discarded at any moment; recovery is reindexing.
> Anything Loom knows that is not derivable from the store must be written back
> to it, or it is not knowledge — it is cache.

Two supporting rules:

> Exactly one store is authoritative for a given document type in a given
> repository. Anything else is a projection, written in one direction.

> Source code is always read from the checked-out tree. Only the document tier
> is reached through a store adapter.

Plus the adapter protocol (enumerate, read/write, allocate-id, changed-since,
compare-and-swap, may-transition, history, locate) and the branch-aware / flat
split with its five requirements.

---

## 2. New documents to write

| Kind | Subject |
|---|---|
| DEC | The index is derived from a document store. Supersedes DEC-0001 |
| DES | The document store adapter protocol: eight operations, capability declaration, one-authoritative-store, and the rule that the protocol is not reduced to the weakest backend |
| CON | Branch-aware stores and flat stores, and the five requirements for branch-scoped revisions |
| ARCH | Where the adapter sits in the tier graph, and which existing systems may reach it |
| RULE | The layering constraint for the new system (see §4) |
| REQ | Materializing a working copy for agents when the store is not the filesystem |
| REQ | Reporting currency honestly per store — `drift` vs mirror lag |
| REQ | The git adapter as reference implementation, existing behaviour restated as its conformance statement |

---

## 3. Concepts

### CON-0002 — "File stamp" · **re-scope**

The write date plus content hash is precisely the git adapter's implementation
of `changed-since`. Its argument — that `file-write-date` counts in whole
seconds, so an edit landing in the same second as the read is invisible — is a
property of filesystems and belongs with the file adapter, not with Loom.

A remote store answers `changed-since` with an ETag, an `updated-since` query or
an event; those have their own failure mode (a store whose clock or cursor lies)
and it is not this one.

**Disposition:** retitle as the file adapter's change detection, or keep and add
a scope line. Either way the generic question — *what does a store return when
asked what moved* — needs to be named somewhere, most naturally in the new store
DES.

### CON-0004 — "Workflow of record" · **amend**

Splits cleanly in two:

- **Store-independent:** the nine types, the chain, `refines:`, the
  `affects:` / `describes:` / `applies-to:` ladder, the status vocabularies,
  the bug record's WHY IT HID section, and the rule that a document names the
  one it answers.
- **Git-specific:** the section "WHY YAML AND WHY A REGISTERED DIRECTORY", the
  claim that the directory names the type, the block-scalar and duplicate-id
  failure modes, and `ls docs/bugs` being readable without loading Loom.

**Disposition:** amend, with the git-specific half moved under a heading that
says so. The directory-to-type registry becomes the git adapter's implementation
of type mapping; another store maps a type to an issue type, a project or a
label.

### CON-0008 — "The merge is the approval" · **amend, and one claim retracted**

This is the git adapter's implementation of `may-transition`, not the answer for
every store.

Two specific edits:

1. "No interface Loom offers may write a status" is now wrong. Loom **writes**
   statuses through the adapter; what it may never do is **approve** one. The
   description document now draws that line explicitly and the concept should
   match it.
2. The COROLLARY FOR EVERY INTERFACE section should read: no interface may put
   the approval outside the store that holds the document. Its examples still
   hold for the git store.

The rest — land at draft, transition in its own commit, work proceeds against a
draft — stands as written for a branch-aware store, and the description document
now points out that this convention is *why* a flat store loses less than it
first appears.

### CON-0001, CON-0003, CON-0005, CON-0006, CON-0007 · **unaffected**

Checked. CON-0001's asymmetry (a recorded gap beats a fabricated fact) is the
principle the adapter capability declaration is built on, and could cite it.

---

## 4. Rules

### RULE-0002 — "Analyzers are storage-agnostic" · **unaffected, now load-bearing twice**

Its statement already reads "must not reach the graph, the adapter, or any
store". Until now "store" named nothing in particular. It now names a real
component, and the rule is the thing that keeps a document analyzer from
learning which backend it is reading.

Worth adding to the statement: with a remote store, the workspace fetches and
hands the analyzer bytes, exactly as it does for a file. The analyzer signature
does not change and must not.

### RULE-0003 — "Knowledge Services never write" · **deny list needs extending**

The rule is a `no-call-to` check with an explicit list of writer names, and it
says of itself that it is "only as current as its last edit". The adapter
introduces new write functions. Whichever of them can submit a change to a store
has to be added to `to-names` when it exists, or the read side quietly gains a
write path.

**Disposition:** no change now; add a note to the rule that the adapter's write
operations are pending inclusion.

### RULE-0004 — "A handler that guards a long-running thread names serious-condition" · **extend applies-to**

Directly relevant and easy to miss. The rule exists because cl-yaml defines
conditions as direct subtypes of `condition`, so a handler naming `error` has a
hole in it. An HTTP client library for a remote store is exactly the same
hazard, and the adapter's polling loop is exactly the kind of thread the rule
protects.

**Disposition:** add the adapter poll loop to `applies-to:` when it exists. The
rule's own lesson — "the set of conditions a handler catches is decided by the
libraries you depend on" — is the argument.

### RULE-0001 and RULE-0009 — the two leaf layers · **new layering question**

Both are `no-edge ... to-system outside` checks asserting that `loom-ontology`
and `loom-utils` reach nothing else in the tree. Neither is violated by the
change, but the change adds a system and the tier graph has to say where it
goes. The constraints that follow from what is already written:

- the adapter must not be reachable from `loom-ontology` or `loom-utils`;
- `loom-analyzer` must not reach it (RULE-0002);
- `loom-knowledge` must not reach its write side (RULE-0003);
- `loom-workspace` is the natural owner, since it already owns the indexing
  pipeline and the monitor.

**Disposition:** write the new layering rule with the adapter placed under
`loom-workspace`, and check it with the same `no-edge` kind.

### RULE-0007 — "A workflow document lives in completed/" · **already retired, one note**

Retired, but it encoded the only statement of the completed-area convention. The
description document now speaks of "the store's completed area". If that
convention is to survive at all, it needs a home that is not a retired rule.

### RULE-0005, RULE-0006, RULE-0008 · **unaffected**

RULE-0005 is retired. RULE-0006 (shadowed definitions) and RULE-0008 (an
instrument brings the service current before printing a number) are about code
and measurement and do not touch the document tier.

---

## 5. Architecture

### ARCH-0101 — "Nine systems over one write path" · **pending, not wrong**

An architecture document describes what is there. The adapter is not there, so
I5 is currently accurate and should **not** be restated yet. What will change
when it lands:

- **I5 FILES ARE TRUTH** becomes the derived-index invariant, with source code
  keeping the absolute form.
- **THE FOUR TIERS** gains a system, per §4.
- **THE WRITE PATH, END TO END** currently opens "a file changes; the monitor
  notices". For documents that becomes "the adapter reports a change"; the rest
  of the path — retract, plan, apply, resolve — is unchanged, which is worth
  saying explicitly because it is the payoff of the analyzer protocol.
- **I2** is preserved rather than weakened, and the document should say how: the
  workspace fetches, the analyzer still receives bytes.
- **WHAT THE DOCUMENT TIERS MEAN** (the edge-strength ladder) is
  store-independent and unchanged.

**Disposition:** flag as pending; restate in the same change that lands the
adapter.

### ARCH-0102 — Retrieval · **one paragraph only**

Seeding, fusion, expansion, budget, the vector sidecar and the instruments are
all untouched: they read the index, not the store. The single exception is the
currency claim. `drift` is defined as claimed files that changed since the index
read them, checked with a stat. Against a remote store it means mirror
staleness, which is a different claim under the same word.

**Disposition:** one added paragraph when the adapter lands, and the REQ in §2
that decides what is reported.

---

## 6. Designs

### DES-0048 — "A document id comes from a block leased on an orphan branch" · **re-scope**

This is the git adapter's implementation of `allocate-id`, needed because a
filesystem has no allocator. A tracker answers `allocate-id` natively and the
whole mechanism is skipped. The ordering rule it rests on — a block is claimed
and its push confirmed before any id is minted — stands exactly as argued.

**Disposition:** amend to name the adapter it belongs to. Do not retire.

### DES-0022 — "Init installs a skill rather than agents" · **amend**

`init` currently creates document directories unconditionally and writes the
workflow concept into the tree. With a store choice it has to ask which store,
and on a flat store create a gitignored working-copy area rather than an
authoritative document tree. Its two consent questions become three.

The structural report and the skill installation are unaffected.

### DES-0007 — "A tools/ lifecycle script and a self-watch timestamp" · **small extension**

`status` reports whether the service is up and its code current. With a remote
store there is a third thing a developer needs to know: whether the store is
reachable and how stale the working copy is. Same argument the design already
makes about honest currency.

### DES-0009 — "System identity from IN-PACKAGE" and DES-0024 — "from-family" · **cited, unchanged**

The description document now defines *system* in terms of these two and
distinguishes it from a domain. Neither needs to change; both are now
load-bearing for the maintainer map and should be cited by it.

### DES-0025 — "What crosses is a claim" · **re-derive**

Federation is built on claims normalized across trees. A shared document store
changes what has to cross at all: two repositories on one store need no claim
matching for documents. Worth re-deriving before more is built on it.

### DES-0021 — repository designators (`@name`) · **check**

A designator resolves against what a local service happens to watch. With a
store that is not a local path, a repository may be addressable without being
checked out. Whether `@name` still means the same thing needs an answer.

### DES-0001, DES-0011, DES-0012, DES-0026, DES-0032 · **unaffected**

Checked. CLOS analysis, the inspector pass, shadowed definitions, the two-tier
context design and term coverage are all about code or retrieval.

---

## 7. Decisions

### DEC-0001 — "The repository on disk is the system of record" · **supersede**

Its title is the claim being narrowed. Rationale and consequences hold verbatim
if "files" reads as "the store"; "on disk" does not.

**Supersede rather than edit.** CON-0004, CON-0006, DEC-0006 and ARCH-0101 I5
all cite it, and those citations should keep pointing at what was decided at the
time. The replacement must carry the corollary sentence, which is the part other
documents quote.

### DEC-0002 — "Entity ids are derived from the natural key" · **consequence worth catching**

The mechanism is unaffected. What changes is the natural key *of a document*. A
document is currently identified by its path, which is why its id reads
`document:docs/requirements/REQ-0001.yaml`. An issue in a tracker has no path.
Its natural key becomes something like the store plus the store's own
identifier, and the ids in every report change shape with it.

This is the most concrete breakage in the list: it touches `describe`, `find`,
`impact`, every `refines:` that names a qualified id, and the acceptance corpus.

**Disposition:** needs deciding before the first non-file adapter, not after.

### DEC-0004 — "Watching is a state a repository is in" · **extend**

A repository is `watched` or `paused`, both named states. A store connection has
states too — connected, stale, unreachable — and the decision's own argument
says an unnamed state will be read as a fault.

### DEC-0007 — "Impact and priority are two axes" · **mapping needed**

`importance`, `severity` and `priority` are fields with closed vocabularies. A
flat store has its own priority field with its own vocabulary, and the mapping
between them is a decision, not a detail. A value outside the vocabulary is
currently dropped silently and reported by `check`; that behaviour has to hold
across the mapping.

### DEC-0003, DEC-0005, DEC-0006 · **unaffected**

---

## 8. Requirements

### REQ-0009 — "Documents under docs/ must move to a database, overriding DEC-0001" · **close**

Answered, but not as asked. It wanted a database and an override; it gets an
adapter, with DEC-0001's durability half intact and only its filesystem half
relaxed. All three of its named gaps close: no owner → the maintainer map or the
store's ownership; no structured reason → `history`; no enforced transitions →
`may-transition`.

**Disposition:** close as superseded by the new DES. Leaving it open asks for
something the design deliberately does not do.

### REQ-0025 — id allocation · **re-scope with DES-0048**

### REQ-0071 — the repository manifest · **add keys**

Add the store declaration to the keys it is being widened to carry: which
adapter, its endpoint, its credential reference, and the capabilities it claims.

### REQ-0021 — `init` · **amend with DES-0022**

### REQ-0073, REQ-0074, REQ-0077 — federation and cross-repository requests · **re-derive**

REQ-0077's three deployment shapes were reasoned from "every tree must be on one
filesystem". A central document store makes the document half of federation
nearly free, and that is the half REQ-0077 identifies as the one that crosses
team boundaries. REQ-0074's capability request becomes much cheaper when both
repositories share a store. These are the requirements most likely to shrink.

### REQ-0075, REQ-0076 — maintainer map and forge adapter · **check overlap**

The maintainer map is store-independent and unaffected. REQ-0076 R1 — a
pull-request job opening an issue in another repository — overlaps with the
tracker-as-store case, where the request already is an issue. Check whether R1
survives as its own requirement.

### REQ-0017 — generated documents carry provenance · **unaffected, more important**

Documents imported from a tracker are machine-generated by the same argument and
must not be mistakable for a human's.

---

## 9. Open questions

**Multi-document atomicity is missing from the protocol.** `complete`
transitions a plan and every document it refines in one operation. On git that
is a commit; on a tracker it is several API calls that can half-fail. Either the
protocol gains a batch operation, or `complete` is specified as resumable with a
defined partial state.

**What is a document's natural key on a store with no paths?** See DEC-0002.
This one blocks the first non-file adapter.

**Where do `refines:` and `affects:` live on a flat store?** Custom fields, a
YAML block in the description, or a native link type. This decides whether the
chain survives the move, and is the question most likely to make
tracker-as-store unworkable.

**Does the working copy accept writes when the store is unreachable?** A file
store never faces this. The answer decides whether an agent can work offline.

**One store per repository, or one per document type?** Rules and architecture
notes in git while requirements live in JIRA is either useful flexibility or the
second system of record wearing a disguise.

**What happens to a document type a store cannot represent?** Refuse the
configuration, fall back to git for that type, or degrade it to a generic issue.

**Is the abandoned-branch rule enforced or only defined?** Git gives it free by
deleting the branch. A purpose-built store must decide whether unlanded
revisions are collected, hidden, or indexed with a marker.
