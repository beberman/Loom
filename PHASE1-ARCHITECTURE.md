# Phase 1 Software Architecture (revision 3)

Exported on 2026-10-10 from docs/Phase1 Software Architecture.docx at commit a675771, where the same file was docs/design/Phase1 Software Architecture.docx. The text is unedited. The table of contents, page breaks and bold and italic formatting are not carried over. The .docx file is removed in the same commit as this export.

Loom

Engineering Knowledge Graph

Design specification for the Common Lisp implementation

Revision 3 — July 2026

## 1. Introduction

This document is the software architecture for Phase 1 of Loom, the Engineering Knowledge Graph. It refines the design established in the Phase 1 architecture document into concrete systems, classes, protocols, and wire formats, and is intended to be sufficient to begin implementation: every component named here maps to an ASDF system, and every cross-component interface is specified as either a CLOS generic-function protocol or a JSON schema.

The governing decisions are: the implementation is entirely Common Lisp; the repository on disk is the system of record and the graph is a derived index; Phase 1 holds that index in memory behind a Graph Adapter protocol so that Neo4j, VivaceGraph, or AllegroGraph can be added later without touching ontology or service code; the ontology, not the storage engine, defines the system; the watcher and the server are one process, started by the developer and pointed at a repository; and the primary consumer is Claude Code over MCP, dogfooded against the game engine codebase.

The system is code-named Loom. The prefix loom- is used for every ASDF system, package, and MCP tool name in this document; Engineering Knowledge Graph remains the descriptive term for what the system is.

Three themes run through everything below. First, files are truth: source, comments, and the YAML documents under docs/ hold the knowledge, and the graph is an index over them that can be discarded and rebuilt at any time. Second, change flows through ontology operations: analyzers never mutate the graph, they emit operations, and the Graph Manager validates and applies them — which is what allows incremental update and full rebuild to produce the same result. Third, self-hosting: Loom’s test suite analyzes Loom, and the architectural rules stated in this document are enforced as queries against the graph Loom builds of its own source.

### 1.1 Changes in revision 3

This revision reconciles the specification against the implementation of loom-ontology, loom-graph, loom-analyzer, and loom-knowledge. Five corrections, each originating in a conflict found while building: the impact direction of :decides (§5.3), the addition of loom-knowledge to the system table (§4), the entity id grammar (§5.1 and §12), the retraction and staleness rules (§5.4), and a repository layout that describes the tree that exists rather than proposing a new one (§16). Where the implementation and the previous revision disagreed, the implementation was usually right; those cases are noted at the point of change.

## 2. System Overview

Figure 1 image: phase1-architecture-figure-1.png

Figure 1 — One process, two inbound paths, one system of record. The left column serves knowledge; the right column constructs it; both meet at the Graph Manager, the only writer.

Loom is a single OS process that the developer starts from a shell and points at a Git repository. That process holds the graph, watches the working tree, runs the analyzers, serves REST and MCP over HTTP on localhost, and presents a command loop on its own standard input. For a single developer there is no operational reason to separate the watcher from the server, and merging them removes an inter-process boundary that would otherwise sit between the component that detects change and the component that owns the graph.

Two paths meet at the Graph Manager. The construction path watches the repository, analyzes changed files — source code, and the YAML documents under docs/ — and emits ontology operations. The consumption path answers queries from Claude Code over MCP, from other clients over REST, and from the developer at the command loop, all through the same read-only Knowledge Services. Beneath the Graph Manager, the Graph Adapter isolates storage; in Phase 1 the only backend is the in-memory index.

### 2.1 The consequence of files-as-truth

Making the repository the system of record has a specific consequence worth stating plainly: the graph carries no independent durability requirement. If the process dies, restarting and reindexing produces the same graph, because nothing of value existed only in memory. This retroactively justifies the in-memory decision — Phase 1 does not need persistence, it needs fast rebuild — and it collapses several problems the design previously carried. The operation log needs no compaction for correctness. Snapshots need no long retention, because Git already holds the history of the truth. Recovery is reindexing, and reindexing is always correct.

The corollary is a constraint the rest of this document honors: anything Loom knows that is not derivable from files must be written back to files, or it is not knowledge — it is cache, and it will be lost without anyone noticing. This is why documentation is a first-class analyzed source rather than a side feature, and why an agent recording a decision writes a file rather than asserting a node. It also buys something the graph alone could not: decisions and rules are diffable, reviewable in a pull request, greppable, and useful to a person who never runs Loom.

## 3. Process Model and Command Surface

### 3.1 One process, three faces

The process presents three interfaces onto the same live image. Standard input and output belong to the command loop, the developer’s console. An HTTP listener on localhost serves the REST API and the MCP endpoint. And the Lisp REPL sits one command away behind the console, for when the other two are not enough.

This allocation of stdio is what settles the MCP transport question. A command loop that owns standard input cannot also carry an MCP stdio session, and a stdio MCP server would in any case normally be spawned by the client rather than started by the developer and pointed at a repository. MCP therefore runs over HTTP (Section 13), which additionally allows several clients — Claude Code, a second editor session, a future dashboard — to share one index.

### 3.2 The command loop

The console reads a line, splits it into a command and quoted arguments, and dispatches through a command table. It is deliberately not the Lisp reader: the syntax is documentable, forgiving of Windows paths, and usable by someone who does not write Lisp.

| Command | Effect |
| --- | --- |
| `watch "<directory>"` | Register a Git repository, index it, and begin watching. Repeatable; several repositories may be watched at once. |
| `unwatch "<directory>"` | Stop watching and drop the repository’s index. |
| `status` | Repositories watched, indexing progress, entity and relationship counts, watcher health, unresolved document references, unenforced rules, and the last error per thread. |
| `reindex ["<directory>"]` | Discard and rebuild an index from disk. Always safe, because files are truth; the escape hatch for any suspected divergence. |
| `query "<knowledge query>"` | Run a query and print results, through the same Knowledge Services path the MCP tools use. |
| `impact "<entity>"` | Print the impact set for an entity (Section 11). |
| `check` | Run the rule checks from docs/rules and print violations (Section 10.4). |
| `log [n]` | Recent transactions, analysis failures, and thread errors. |
| `>repl` | Drop into the Lisp REPL in this image. EOF or (loom:console) returns to the command loop. |
| `stop` | Stop watchers, close the listener, and exit. |

The REPL escape is the reason to be in Lisp at all: inspecting live graph state, redefining an analyzer function, and re-running it against an already-loaded repository without a restart. It is treated as a client like any other — interactive code submits transactions to the writer mailbox rather than mutating storage directly — so the single-writer invariant of Section 6.1 survives interactive poking. A REPL session that bypasses the mailbox is a bug, and Section 14.3 has an invariant that says so.

### 3.3 Thread supervision and error containment

The failure mode to design against is specific: an analyzer signals a condition, the watcher thread drops into the debugger, and the process stays alive and answers queries while silently no longer indexing anything. Nothing in the developer’s experience distinguishes that from a quiet afternoon.

Every long-lived thread — watcher, analyzer worker, writer, HTTP handler — runs its body inside a handler-bind that logs the condition together with its context (repository, file, operation) and unwinds to the thread’s supervisor loop rather than entering the debugger. The image sets \*debugger-hook\* to that same logging path, so no non-interactive thread can block on a debugger prompt even if a condition escapes a handler. Sessions started with >repl bind \*debugger-hook\* to nil for their own dynamic extent, so the developer keeps the real debugger where it is useful.

Failures are counted, surfaced in status, and attributed. A file that fails to analyze is marked in the graph as analysis-failed with the condition text attached, rather than simply being absent — a file that could not be parsed is a known unknown, and an agent asking about it deserves to be told that rather than told nothing. If the writer thread dies it is restarted and every affected repository is marked for reindex, which is cheap and always correct.

### 3.4 Startup, cold start, and the index cache

On watch, the process walks the tree, analyzes every file it has an analyzer for, and applies the resulting transactions; progress is reported at the console. Because files are truth, this is always available and always correct, and its only cost is time.

To avoid paying that cost at every launch, the process may keep an on-disk index cache, keyed by commit id plus a hash of the dirty files, written under .loom/ and gitignored. The cache is strictly an optimization and is governed by one rule: it is never authoritative and never repaired. On any version mismatch, checksum failure, or disagreement with the tree, it is deleted and the index is rebuilt. Phase 1 may ship without it — indexing the game engine takes seconds — and add it when a repository large enough to care about startup time appears.

## 4. System Decomposition

The code is organized as ten ASDF systems with a strict dependency direction: nothing below the line depends on anything above it. The ontology system has no dependencies at all — it is pure CLOS definitions and can be loaded into any image, including analysis scripts and tests, without dragging in a server.

| System | Responsibility | Depends on |
| --- | --- | --- |
| `loom-ontology` | Entity, relationship, workspace, and snapshot classes; provenance mixin; the define-entity-type macro; ontology operation objects and their serialization. | — |
| `loom-adapter` | The Graph Adapter generic-function protocol and the in-memory backend. | loom-ontology |
| `loom-graph` | Graph Manager: single-writer loop, validation, transactions, overlay resolution, snapshot lifecycle, query execution. | loom-ontology, loom-adapter |
| `loom-analyzer` | Analyzer protocol; Tree-sitter driver; per-language source analyzers emitting ontology operations. | loom-ontology |
| `loom-docs` | YAML documentation analyzer: decisions, rules, architecture notes, concepts; link resolution; the rule compiler. | loom-ontology |
| `loom-workspace` | Workspace registry, filesystem and Git event monitoring, debouncing and batching, analyzer dispatch. | loom-graph, loom-analyzer, loom-docs |
| `loom-knowledge` | Knowledge Services: search-entities, describe-entity, impact-report, build-context, and the rule runner. Read-only — it queries and never submits transactions. | loom-graph |
| `loom-rest` | Hunchentoot handlers, JSON encoding and decoding, error model. | loom-knowledge, loom-workspace |
| `loom-mcp` | MCP server over HTTP exposing knowledge tools to Claude Code. | loom-rest |
| `loom-process` | Entry point: command loop, thread supervision, lifecycle, index cache, image build. | all of the above |

An eleventh system, loom-tests, depends on all of the above and is described in Section 14.

loom-knowledge was referred to as “Knowledge Services” throughout the previous revision without appearing in this table — an omission, since §14.3 states a read-only invariant over it and a no-edge check cannot name its subject unless that subject is a system. It sits between loom-graph and the three faces, and the invariant is exactly what its position buys: nothing in loom-knowledge may reach the transaction mailbox.

One division of labour follows from that placement. The rule compiler belongs to loom-docs and runs at index time, turning a rule’s check clause into a query specification stored as a property of the Rule entity. The rule runner belongs to loom-knowledge and runs at query time, executing that specification through loom-graph. Splitting them this way keeps loom-knowledge independent of loom-docs, and keeps loom-docs a pure analyzer — which is what the storage-agnostic invariant of §14.3 requires of it.

## 5. Ontology Layer (loom-ontology)

### 5.1 Core classes

The base classes are deliberately lean, in line with the project’s general principle of minimal base types with extension through the dynamic property system rather than deep base-class hierarchies. Everything an entity or relationship might carry beyond identity lives in a properties table or in the provenance mixin.

```
(defclass identified ()
  ((id   :initarg :id   :reader id
         :documentation "Stable id, derived from the natural key, not random.")
   (name :initarg :name :accessor name)))

(defclass provenanced ()
  ((source        :initarg :source :accessor source
                  :type (member :structural :inferred :human-validated))
   (confidence    :initarg :confidence :accessor confidence
                  :initform 1.0 :type (real 0 1))
   (derived-from  :initarg :derived-from :accessor derived-from
                  :initform '()
                  :documentation "Entity ids whose modification invalidates this fact.")
   (origin-file   :initarg :origin-file :accessor origin-file
                  :documentation "The file this fact was read from. Every fact has one.")
   (stale-p       :initform nil :accessor stale-p)))

(defclass entity (identified provenanced)
  ((entity-type :initarg :entity-type :reader entity-type)   ; keyword, e.g. :function
   (properties  :initform (make-hash-table :test #'equal)
                :reader properties)))

(defclass relationship (identified provenanced)
  ((rel-type :initarg :rel-type :reader rel-type)            ; keyword, e.g. :calls
   (from-id  :initarg :from-id :reader from-id)
   (to-id    :initarg :to-id  :reader to-id)
   (properties :initform (make-hash-table :test #'equal)
               :reader properties)))
```

Two slots deserve comment. Ids are derived deterministically from the natural key rather than generated randomly, so that a full rebuild produces the same ids as an incremental update — the property Section 14.4 tests. And origin-file is mandatory: under files-as-truth every fact traces to the file it came from, which is what makes reindexing a file a well-defined operation and what makes an orphaned fact detectable.

#### Id grammar

An id is three colon-separated parts:

```
<entity-type> ":" <scope> ":" <natural-key>

function::loom-graph/src/graph/overlay.lisp#resolve-overlay
module::loom-graph/src/graph/overlay.lisp
decision::docs/design/DEC-0042.yaml
```

The type prefix is required, not decorative. Several types share a natural key: :file and :document both key on path, and :module and :package both key on qualified name, so without the type those pairs collide outright. The scope segment is reserved for a repository identifier and is empty until loom-workspace introduces a repository entity to scope by; ids written today therefore carry an empty middle segment, and populating it later is a reindex.

That an id format can change with only a reindex depends on one rule, stated here because it is easy to violate by accident: documents reference entities by name, never by id. The affects, applies-to, supersedes, and implements fields of §10.2 are resolved against the index at read time, so an id change costs nothing beyond rebuilding. An id that leaks into a YAML document under docs/ becomes a dangling string the moment the format moves, and nothing will notice. This belongs in docs/rules as a checkable constraint rather than as advice in prose.

### 5.2 Entity taxonomy and define-entity-type

Specialized entities (Repository, Branch, Package, Module, Class, Interface, Function, Method, Variable, Test, Document, Decision, Rule, Concept) are declared with a macro rather than hand-written defclass forms. This mirrors the define-piece-type approach used in the game engine: a declarative, self-documenting schema that generates the class, typed property accessors with bounds checking, and a registry entry the REST layer uses to describe types to clients.

```
(define-entity-type :function
  :documentation "A named callable unit in source code."
  :properties
  ((:file       string  :required t)
   (:start-line integer :required t)
   (:end-line   integer :required t)
   (:signature  string)
   (:exported-p boolean :default nil)
   (:language   keyword :one-of (:lisp :typescript :python))))
```

The registry is the single source of the schema. The Graph Manager validates incoming operations against it, the REST API serves it at GET /ontology/schema, and the MCP server includes it in tool descriptions so agents know what property keys exist without guessing.

### 5.3 Relationship taxonomy

Relationship types are likewise registered declaratively, with the two pieces of metadata the impact engine needs: whether the type is traversed transitively during impact analysis, and in which direction impact flows across it. Section 11 uses this table.

```
(define-relationship-type :calls
  :from (:function :method) :to (:function :method)
  :transitive-impact t :impact-direction :reverse)

(define-relationship-type :decides
  :from (:decision) :to (:module :class :function :method)
  :transitive-impact nil :impact-direction :reverse)
```

The previous revision declared :decides with :impact-direction :forward, which contradicted the impact table of §11 and would have left the decisions field of every impact report empty. §11 is normative and :reverse is correct: impact runs from the changed unit back to the decision that governs it.

The wider lesson is that the slot invited the error. Every relationship type in §11 traverses against edge direction, so :impact-direction has never taken a value other than :reverse, and a slot whose only correct value must be restated at each declaration is a slot that will eventually be restated wrongly. It now defaults to :reverse, and any other value requires a documented justification at the declaration.

There is a legitimate forward traversal, and conflating it with impact is what produced the bug. “I am changing this decision — what code does it govern?” is a real and useful query, but it is not the impact query of §11: it begins at a different kind of node. Direction is a property of where a traversal starts, not of the edge type it crosses. That query is therefore named separately — forward expansion over :decides and :applies-to, specified in §11 — rather than expressed by inverting a per-type direction flag.

### 5.4 Ontology operations

Operations are the only way the index changes. Each is a small immutable object; the operations produced from analyzing one file form a transaction. Operations serialize to JSON for the REST API and to a readable form for the operation log.

```
(defclass ontology-op () ((workspace-id :initarg :workspace-id :reader workspace-id)))

(defclass assert-entity-op       (ontology-op) ((entity :initarg :entity :reader op-entity)))
(defclass assert-relationship-op (ontology-op) ((rel    :initarg :rel    :reader op-rel)))
(defclass retract-file-op        (ontology-op) ((path   :initarg :path   :reader path))
  (:documentation "Retract every fact whose origin-file is PATH."))
(defclass retract-op             (ontology-op) ((target-id :initarg :target-id :reader target-id)))
(defclass mark-stale-op          (ontology-op) ((target-id :initarg :target-id :reader target-id)
                                                (reason    :initarg :reason  :reader reason)))
```

Assert operations are upserts keyed by the natural key, so re-analyzing an unchanged file is idempotent. The file-scoped retract is the workhorse of incremental update: reanalyzing a changed file is retract-file followed by the fresh asserts, which is simple, obviously correct, and cheap at the granularity of one file.

#### Retraction and staleness are different things

The previous revision said that retraction cascades a mark-stale to every relationship touching a removed entity as well as to every inferred fact whose derived-from names it. The first half of that was wrong, and the implementation is correct in departing from it. Referential integrity is an invariant of the index, not a condition to be flagged: add-relationship refuses to create an edge whose endpoint does not exist, and remove-entity drops the edges that touch it. There is consequently no such thing as a dangling edge to mark stale.

Staleness means something narrower and is reserved for it: an inferred fact whose derived-from names a changed entity is flagged, excluded from agent context until re-verified, and never deleted. Structural facts are not marked stale, because nothing re-verifies them — they are re-derived. Flagging a dangling structural edge would file it in a category from which it could never be recovered, which is how a graph forgets rather than doubts.

Dropping edges on retraction does leave one gap, and closing it is a requirement rather than an option. If file B calls a function defined in file A, the CALLS edge has B as its origin-file; when A changes and that function disappears, remove-entity drops the edge although B still asserts the call and B has not changed. The index would then under-report until B happened to be edited. Retraction therefore enqueues the origin-file of every dropped edge for reanalysis. B is re-read, the call no longer resolves, and it is recorded as an unresolved-call property on the call site per §9.3 — which is where a reference to something that does not exist belongs, since it is a fact about B’s text rather than an edge in the graph. The index once again says exactly what the files say.

Two implementation consequences worth stating. Analysis order matters on a cold start: a strict no-dangling-edges rule means relationships cannot be asserted before their endpoints exist, so a full index runs in two phases — all entities from all files, then all relationships. Incremental single-file updates need no such treatment, since the other files’ entities are already present. And staleness cascade is a scan over facts whose derived-from names a target, so it must be batched: a retract-file removing fifty definitions should perform one scan against a set of fifty ids, not fifty scans. Called per-entity it is quadratic in the hot path, which is every file save; called per-transaction it is linear and unremarkable. A reverse index on derived-from removes the scan altogether and is the obvious optimization when the linear pass stops being free.

One point of emphasis, changed from the previous revision. The operation log is not the system of record — files are. The log exists to make incremental update expressible and to give the developer a readable trace of what the analyzers concluded and when. It is bounded, rotated, and may be discarded at any time; nothing recovers from it, because recovery is reindexing.

## 6. Graph Manager (loom-graph)

### 6.1 Concurrency model: single writer

The Graph Manager runs one writer thread, consuming transactions from a mailbox. Analyzers, the workspace monitor, REST handlers, MCP tools, and interactive REPL code all submit transactions to that mailbox and none of them touch storage. Readers never block: query execution runs against an immutable view, so HTTP request threads and the console read freely while the writer applies changes. This eliminates lock discipline as a class of bugs at the cost of write throughput, which is the right trade here — the write load is one developer’s file saves.

### 6.2 Transactions and validation

A transaction is validated in full before any of it is applied: every operation is checked against the entity-type registry (property types, required keys, bounds), relationship endpoints are checked for existence and type compatibility, and retracts are checked for dangling references. A transaction either applies atomically or is rejected with a structured error naming the failing operation. After a successful apply, the transaction is appended to the log and the workspace’s index version is bumped, which is what clients wait on when they need read-your-writes (Section 10.5).

### 6.3 Query protocol

Queries are read-only generic functions over a graph view. The Phase 1 set is intentionally small — these cover what the REST endpoints, MCP tools, and rule checks need, and each has an obvious translation to Cypher later.

```
(defgeneric get-entity      (view id))
(defgeneric find-entities   (view &key entity-type name-like property-filters))
(defgeneric neighbors       (view id &key rel-types direction))
(defgeneric impact-set      (view id &key max-depth include-tests include-docs))
(defgeneric edges-between-systems (view from-system to-system &key rel-types)
  (:documentation "Backs the architectural rule checks of Sections 10.4 and 14.3."))
```

## 7. Graph Adapter Protocol (loom-adapter)

The adapter is the storage boundary. It is a CLOS protocol with exactly one Phase 1 implementation, the in-memory adapter, and its shape is dictated by the migration strategy: an adapter must be able to apply operations and to bulk-load an index, and nothing in the protocol exposes backend query syntax.

```
(defgeneric adapter-apply-transaction (adapter transaction))
(defgeneric adapter-get-entity   (adapter id))
(defgeneric adapter-find         (adapter &key entity-type name-like property-filters))
(defgeneric adapter-neighbors    (adapter id &key rel-types direction))
(defgeneric adapter-facts-from-file (adapter path)
  (:documentation "Every fact with this origin-file; backs retract-file."))
(defgeneric adapter-load-index   (adapter index))
(defgeneric adapter-write-index  (adapter))
```

The in-memory adapter is two hash tables (id to entity, id to relationship) plus adjacency indexes in both directions, an index by entity type, and an index by origin file. That last one is what makes file-scoped retraction O(facts in the file) rather than a scan, and it exists because of the files-as-truth model.

Moving to Neo4j later means implementing these seven functions against Bolt, then either bulk-loading a written index or simply reindexing from disk — and under files-as-truth, reindexing is the simpler and more trustworthy of the two. Impact traversal deliberately lives above the adapter, expressed in terms of neighbors; a graph backend could push it down later through an optional adapter-impact-set method, with the generic traversal as the fallback.

## 8. Workspaces, Overlays, and Snapshots (loom-workspace)

### 8.1 Overlay model

The committed state of a repository forms the base index, built by analyzing the tree at a commit. Each watched working tree owns an overlay: the facts that differ from the base because of uncommitted edits. A view composes base plus overlay with the overlay winning, and all queries run against a view. On commit, the overlay is folded into a new base and emptied; on branch switch, the overlay is discarded and the base rebuilt, which is a re-analysis pass rather than a diffing problem.

### 8.2 Snapshots

A snapshot is a named position in the index: base version, overlay version, and log offset. Because facts are immutable once applied, taking one is cheap — three integers and a timestamp, not a copy. Snapshots exist so that a multi-step query or an agent’s reasoning can run against a stable view while files continue to change underneath.

Their role is smaller than the previous revision implied. Git holds the history of the truth; a Loom snapshot is only a position in a derived index, so there is nothing to preserve for the long term and no retention policy to speak of. Snapshots live for the session, are dropped when a repository is reindexed, and need no compaction. If a caller asks about a snapshot that no longer exists, the answer is a stale-snapshot error and a suggestion to re-query, not an attempt at reconstruction.

### 8.3 File and Git monitoring

The monitor watches the working tree using OS file notifications where a portable library behaves, and falls back to a two-second mtime poll otherwise — the poll is the guaranteed path and is adequate for one developer’s save rate. Events are debounced per file for 500 ms and batched, so a save-all in the editor becomes one analysis pass and one transaction. Git events (commit, branch switch) are detected by watching .git/HEAD and the refs, and trigger base rebuild or overlay reset as described above. Files are dispatched to analyzers by extension and path: source extensions to the code analyzers, anything under docs/ to the documentation analyzer.

## 9. Code Analyzer (loom-analyzer)

### 9.1 Analyzer protocol

An analyzer receives a repository-relative path and the file contents and returns a list of ontology operations. Analyzers are stateless and know nothing about storage, which keeps language independence enforceable: the protocol is the only coupling.

```
(defgeneric analyze-file (analyzer path contents workspace-id)
  (:documentation "Return a list of ontology-ops for this file."))
(defgeneric analyzer-handles-p (analyzer path))
```

### 9.2 Tree-sitter integration strategy

This is the highest-risk dependency, so the design commits to a two-stage strategy with the spike built in. Stage one drives Tree-sitter as a subprocess: a small helper parses a file and prints the syntax tree as JSON, and the Lisp side consumes JSON. This requires no FFI, behaves identically on Windows and Linux, and is the spike deliverable. Stage two, optional and purely a performance move, replaces the subprocess with CFFI bindings to libtree-sitter behind the same analyze-file protocol. Nothing upstream changes.

Phase 1 ships two source analyzers: Common Lisp and TypeScript/TSX. The Lisp analyzer needs no Tree-sitter at all — the reader plus a walk of top-level forms yields functions, classes, packages, and call sites more reliably than any grammar, and it makes Loom able to index its own source from day one, which the testing strategy depends on.

### 9.3 What structural analysis emits

Per file, the analyzer asserts a Module entity and CONTAINS relationships to each Function, Class, Method, and Variable found, with file and line-range properties; IMPORTS relationships between modules; CALLS relationships where the callee resolves within the workspace (unresolved calls are recorded as a property, not a dangling edge); and INHERITS or IMPLEMENTS from class declarations. Test files additionally assert Test entities with TESTS relationships to the units they exercise. Comments attached to a definition are carried as a property of that entity rather than as separate facts, so that a doc comment is part of what an agent sees when it asks about a function. If a file cannot be parsed, the analyzer emits a single assert marking the module analysis-failed with the condition text, which is what makes the failure visible in status and honest in query results.

## 10. Documentation Analyzer (loom-docs)

If files are truth, then engineering knowledge — decisions, rules, architecture notes, vocabulary — must live in files as well, or the principle is a fiction and every restart quietly loses whatever the agents had recorded. Loom therefore reads a documentation tree in the repository as a first-class source, indexed through the same pipeline as source code, by the same watcher, into the same graph.

### 10.1 Layout: the directory names the type

```
docs/
  design/      ; decisions: what was chosen and why
  rules/       ; normative, checkable constraints
  arch/        ; architecture and component overviews
  concepts/    ; domain vocabulary and definitions
```

A document’s subdirectory determines its entity type. This keeps the convention obvious to a human reading the tree and keeps the analyzer free of content sniffing: the mapping from directory to type is a registry entry, so adding a category means creating a directory and registering a type rather than changing code. A subdirectory with no registered type is indexed as a generic Document and reported in status, rather than being silently ignored — a documentation directory that Loom is quietly skipping is exactly the kind of thing that erodes trust in the graph.

### 10.2 Format: YAML

Documents are YAML rather than prose files with embedded metadata. The gain is that they parse into structured data with no heuristic extraction, validate against a schema per type, and can be written reliably by an agent — a decision record with a malformed header is a parsing problem; a decision record with a missing key is a validation error with a line number. Narrative is not sacrificed: prose lives in block scalars, which read perfectly well in an editor and in a pull request diff.

```
id: DEC-0042
type: decision
title: The Graph Manager is the only writer
status: accepted          # proposed | accepted | superseded
date: 2026-07-14
supersedes: []
affects: [loom-graph, loom-adapter]
tags: [concurrency, storage]
rationale: |
  Readers vastly outnumber writers and the write load is one
  developer's file saves, so serializing writes costs little and
  removes lock discipline as a class of bugs.
consequences: |
  Write throughput is capped by one thread. Interactive REPL code
  must submit transactions rather than mutate storage.
```

Rules carry an additional clause that makes them checkable:

```
id: RULE-0007
type: rule
title: The ontology layer depends on nothing
status: active
severity: error           # error | warning | advisory
statement: |
  No system in the ontology layer may reference a system above it
  in the dependency order.
check:
  kind: no-edge
  from-system: loom-ontology
  to: outside-system
  rel-types: [calls, imports, depends-on]
```

### 10.3 What the documentation analyzer emits

Each file yields one entity of the type named by its directory, with scalar fields as properties and prose blocks preserved as properties so an agent can read the rationale rather than just the metadata. Relationships arrive by two mechanisms, and the provenance mixin is what keeps them honest:

- Declared links. The affects, supersedes, applies-to, and implements fields are resolved against the entity index and produce :structural relationships at confidence 1.0. A name that does not resolve is not dropped silently — the document is flagged with an unresolved reference, counted in status, and exposed through the API. That flag is the documentation staleness detector: a decision that names a function which no longer exists is detectably rotten, and detecting it needs no scale and no inference.
- Mentioned links. Entity names appearing in prose blocks are matched against the index and produce :inferred relationships at lower confidence with derived-from populated. These are what make “what decisions touch this function?” work without the author having enumerated every consequence, and they are the facts that get marked stale when the referenced code changes.

### 10.4 Rules as executable checks

A rule’s check clause is compiled into the same query form as the architectural invariants in the test suite. This closes a loop the previous revision left open: the invariants of Section 14.3 need not be hand-written tests that happen to agree with the architecture — they can be the rules themselves, read from docs/rules and executed against the graph. The rule is written where a human reads it and enforced from the same text.

Phase 1 supports a small set of check kinds — no-edge (no relationship of these types between these system sets), requires-edge (every entity of a type must have a relationship of a type), and property-constraint — which is enough for the layering and single-writer rules Loom needs on itself. A rule that cannot be expressed as a check remains valid as prose with severity advisory; it is not enforced, and status reports the count of unenforced rules so that prose-only drift stays visible rather than comfortable. Checks run after each reindex, on demand via the check command, and through GET /rules/violations. Violations are asserted into the graph as entities, so an agent can ask what the current tree violates and get an answer with the same query machinery as everything else.

### 10.5 Writing documents back

The loom_record_decision tool writes a YAML file into docs/design and returns its path. The watcher then indexes it exactly as if a human had written it — one code path, no special case, and no way for an agent-recorded decision to exist in the graph but not on disk. Two consequences are accepted deliberately. Loom writes into the developer’s repository, with Git as the undo. And there is a window between the write and the index catching up, which the tool closes by waiting for the resulting transaction to be applied before it returns, so an agent that records a decision and immediately queries for it sees it.

## 11. Impact Analysis Specification

Impact of an entity E is the set of entities that may need attention if E changes. The computation is a reverse traversal: impact flows against the direction of dependency edges.

| Relationship | Traversed | Direction of impact | Notes |
| --- | --- | --- | --- |
| `CALLS` | Transitively | Callee → callers | The core propagation edge. |
| `DEPENDS_ON / IMPORTS / USES` | Transitively | Dependee → dependents | Module-level propagation. |
| `INHERITS / IMPLEMENTS` | Transitively | Parent → subclasses | Contract changes propagate down. |
| `CONTAINS / BELONGS_TO` | One step | Member → container | A changed function marks its module, not the world. |
| `TESTS` | One step, at the end | Impacted unit → its tests | Collected into a distinct tests field. |
| `DECIDES / DOCUMENTS` | One step, at the end | Impacted unit → documents | Decisions, rules, and notes that reference it. |

Traversal is bounded by max-depth (default 5, maximum 20) and runs against a single snapshot named in the request, so results are reproducible. Each result carries the path by which impact arrived and a depth, so agents can rank near impact above distant impact. Stale inferred facts are excluded from traversal; entities reached only through a stale edge appear in a separate possibly-affected list rather than silently disappearing.

The documentation edges make impact analysis answer a question the code graph alone cannot: changing this function does not only break callers and tests, it may also invalidate the decision that explains why the function exists. Returning that decision alongside the callers is the difference between an impact report and a briefing.

### 11.1 Forward expansion

The complementary query starts at a document rather than at a unit of code: given this decision or rule, what does it govern? It is a forward traversal over :decides and :applies-to, one step, with no transitive expansion — a decision reaches the units it names, not everything those units touch. It is specified separately from impact rather than as an inversion of it, because traversal direction follows from the starting node’s role and not from the edge type; a per-type direction flag that had to serve both would be wrong for one of them. Both an agent about to revise a decision and a reviewer checking whether a decision is still honoured need this query, and it is exposed as GET /documents/{id}/governs and through loom_rules.

## 12. REST API (loom-rest)

Hunchentoot serves JSON over HTTP on a configurable port (default 4780), bound to localhost. Handlers are thin: decode, dispatch to Knowledge Services or the transaction mailbox, encode.

| Endpoint | Purpose |
| --- | --- |
| `POST /repositories` | Register and index a repository — the API equivalent of the watch command. |
| `GET /repositories/{id}` | Status: index version, progress, counts, watcher health, unresolved references. |
| `POST /repositories/{id}/reindex` | Discard and rebuild the index from disk. |
| `GET /ontology/schema` | The entity- and relationship-type registry, for clients and agents. |
| `GET /entities/{id}` | Entity with properties, provenance, origin file, and one-step neighbors. |
| `GET /entities?type=&name=` | Search by type, name pattern, and property filters. |
| `GET /impact/{id}?depth=&snapshot=` | Impact set per Section 11. |
| `GET /documents?type=&affects=` | Decisions, rules, and notes, filtered by what they reference. |
| `POST /documents` | Write a document to docs/ and index it; returns path and index version. |
| `GET /rules/violations` | Current violations of the checkable rules in docs/rules. |
| `GET /repositories/{id}/graph` | Serialized graph view (paged) for visualization and export. |

Entities on the wire are generated from the ontology, so the shape is stable across backends:

```
{
  "id": "function::loom-graph/src/graph/overlay.lisp#resolve-overlay",
  "entityType": "function",
  "name": "resolve-overlay",
  "properties": { "file": "src/graph/overlay.lisp",
                  "startLine": 41, "endLine": 78, "language": "lisp" },
  "provenance": { "source": "structural", "confidence": 1.0,
                  "originFile": "src/graph/overlay.lisp", "stale": false }
}
```

Errors use a single envelope: an HTTP status, a machine-readable code (validation-failed, unknown-entity, stale-snapshot, unresolved-reference), a human message, and, for rejected transactions, the index and rendering of the failing operation. Responses carry the index version they were computed at, and write endpoints return the version at which their write became visible, which is how a client achieves read-your-writes without polling blindly.

## 13. MCP Server (loom-mcp)

The MCP server is the dogfooding deliverable: it is how Claude Code consumes the graph during real development of the game engine. It runs over HTTP on the same listener as the REST API rather than over stdio, for the reasons given in Section 3.1 — the console owns standard input, and an HTTP endpoint lets several clients share one index and one warm process. Claude Code connects to it as a URL-based server; the current MCP transport options should be confirmed against Claude Code’s documentation at implementation time, and if a stdio client proves necessary, a thin shim that forwards stdio to the HTTP endpoint is a twenty-line fallback that changes nothing in this design. Tool descriptions embed the ontology schema so the model knows the vocabulary without discovery calls.

| Tool | Behavior |
| --- | --- |
| `loom_find` | Search entities by type, name, and properties. The entry point for “where is X defined.” |
| `loom_describe` | Full entity detail with neighbors, comments, and the decisions that reference it. |
| `loom_impact` | Impact set for a proposed change, with paths and depths, per Section 11. |
| `loom_record_decision` | Write a decision to docs/design as YAML, wait for it to be indexed, return its path. |
| `loom_rules` | Active rules relevant to a set of entities, and current violations — what a coding agent should read before proposing a change. |
| `loom_context` | Given a task description, return a budgeted context bundle: relevant entities, their relationships, and the decisions and rules that apply, sized to a token limit. |

loom_context is the tool that attacks the original problem statement — tokens spent rediscovering the same code. Its first implementation is deliberately simple (seed entities from the task text by name matching, expand one hop, attach non-stale decisions and active rules touching those entities, truncate to budget) and it should be instrumented from the first day, because the log of what agents asked for and what they were given is the only honest evidence that the graph is earning its keep.

## 14. Testing Strategy

The operation model makes the system unusually testable, and the primary integration fixture is Loom’s own source tree. Loom analyzes Loom: the corpus that the analyzer, Graph Manager, and impact engine are tested against is the code implementing them, together with the decisions and rules in its own docs/ tree.

### 14.1 Test levels and bootstrap order

Self-hosting has an obvious ordering problem — Loom cannot test Loom until Loom works — so the suite is stratified and the levels run in order.

- Level 0 — pure unit tests, no self-analysis. Ontology macro expansion and property validators; Graph Manager driven by hand-constructed operation lists (no filesystem, no server); YAML document parsing and rule compilation; the adapter conformance suite, run against every adapter so a future Neo4j backend is verified by the same tests as the in-memory one.
- Level 1 — self-analysis. The Lisp and documentation analyzers run over loom/ itself; census, invariant, rebuild-equivalence, and rule-check tests assert against the resulting graph.
- Level 2 — end-to-end. The process is started, pointed at a temporary repository, driven through the command loop and the HTTP API, and stopped. This is where TypeScript coverage and the game engine tree live.

CI enforces the ordering: a level 0 failure aborts before level 1 runs, because self-hosting assertions made against a broken graph core produce misleading results rather than useful ones.

### 14.2 Self-analysis as the primary fixture

Using loom/ as the corpus rather than synthetic fixtures buys several things. The code is real Common Lisp with genuine structure — packages, generic functions, methods, mixins, macro-generated classes — rather than the tidy shapes a hand-written fixture tends to have. It is versioned alongside the tests, so the corpus can never drift out of sync with the system. It grows for free: every new system adds test material the day it is written. And because the team knows this codebase precisely, a wrong answer is recognizable on sight.

The baseline is a census. After indexing the tree at a given commit, the graph must contain a Module entity for every source file on disk, entities for every top-level definition the reader finds, a Decision or Rule entity for every file under docs/, and a set of named sentinel entities known to exist — for example the generic function adapter-apply-transaction in loom-adapter, with its CONTAINS edge to its module and its recorded line range.

### 14.3 Architectural invariants as executable queries

This is the real payoff of self-hosting, and under the documentation model it becomes something better than a test suite: the rules live in docs/rules as YAML, they are indexed like everything else, and the test suite runs them. A violation fails the build, and the same rule that failed the build is the one a human reads and an agent is handed by loom_rules.

| Invariant | Stated in | Check |
| --- | --- | --- |
| Ontology depends on nothing | §4 | No CALLS/IMPORTS/DEPENDS_ON edge leaves loom-ontology. |
| Strict dependency direction | §4 | No edge runs from a lower system to a higher one in the declared order. |
| Graph Manager is the only writer | §6.1 | No call to adapter-apply-transaction originates outside loom-graph. |
| Analyzers are storage-agnostic | §9.1 | No entity in loom-analyzer or loom-docs has any edge into loom-adapter or loom-graph. |
| Knowledge Services are read-only | §2 | No call from a Knowledge Services entity to any transaction-submitting function. |
| Every fact has an origin file | §5.1 | No entity or relationship in the index has a null origin-file. |

Written out, an invariant test is short, because the graph has already done the work:

```
(deftest ontology-has-no-outbound-dependencies ()
  (let* ((view      (analyze-self))
         (offenders (edges-between-systems view :loom-ontology :outside
                                           :rel-types '(:calls :imports :depends-on))))
    (is (null offenders)
        "loom-ontology must not depend on other systems; found: ~a" offenders)))
```

### 14.4 Rebuild and incremental equivalence

The highest-value test in the suite, and the one that files-as-truth makes into a first-class correctness property rather than a nicety. Index the tree in full to produce graph A. Touch a file and let the incremental path run to produce graph B. Independently reindex the modified tree in full to produce graph C. Assert that B and C are identical — not merely equivalent, since ids are derived from natural keys rather than generated. Divergence here is the classic knowledge-rot failure, an index quietly disagreeing with the files it claims to describe, and it is the failure that would destroy agent trust fastest.

Two related properties are asserted in the same harness. Determinism: reanalyzing an unchanged file produces a transaction that applies as a no-op, which is what verifies the natural keys of Section 5.4. Staleness: editing an entity named in an inferred fact’s derived-from list marks that fact stale and drops it from query results without deleting it. A third test covers the documentation path specifically — deleting a function that a decision names must produce an unresolved reference on that decision, not a silent hole.

### 14.5 Guarding against vacuous passes

Most of the invariants in Section 14.3 are negative assertions — no edge of this kind exists. If the analyzer silently emits nothing, every one of them passes. A self-hosting suite is therefore only as trustworthy as its positive assertions, and each prohibition is paired with one: minimum entity and relationship counts per system, presence of the named sentinel entities, a check that the count of analyzed modules equals the number of source files on disk, and a check that every YAML file under docs/ produced an entity. Without these, the suite turns green precisely as it goes blind.

### 14.6 What self-hosting does not cover

Loom’s source is Common Lisp, so self-analysis exercises the reader-based analyzer and never touches the Tree-sitter path. TypeScript coverage stays with the golden-file analyzer tests — a source file in, an expected operation list out, checked in as documentation of what the analyzer extracts — and with level 2 runs against the game engine. Self-analysis is also uniform and small: one repository, one language, thousands of lines rather than millions. Scale behavior, multi-language repositories, watcher behavior under real editor churn, and the overlay under branch switching are validated at level 2 and eventually against a large external repository.

## 15. Risks and Spike Plan

The analyzer, graph, ontology, and knowledge services are implemented; the spikes that remain are the ones this revision introduces or leaves outstanding. Spike A: the process shell — command loop, thread supervision with \*debugger-hook\* bound, watch and reindex against a real repository, and a deliberate mid-analysis error to confirm that the watcher survives it, that status reports it, and that the offending file is marked rather than missing. Spike B: MCP over HTTP from Claude Code against the running process, with one trivial tool, which retires the transport question raised in Section 13 and proves the consumption path on Windows. Spike C: the documentation pipeline end to end — a decision and a rule in docs/, indexed, linked to real entities, with the rule’s check running and failing on a deliberately introduced layering violation. Spike C is the one that most changes the character of the system, because it is where the graph starts holding knowledge that no analyzer could derive.

Remaining tracked risks: file-notification portability (mitigated by the polling fallback); a large repository making cold start unpleasant (mitigated by the index cache of Section 3.4, deferred until it matters); YAML schema churn as the document types settle (mitigated by validating on read and reporting rather than refusing, so a schema change never leaves the developer with an unstartable process); and inferred documentation links producing enough noise to be ignored (mitigated by confidence thresholds on what loom_context includes, and by measuring what agents actually use).

## 16. Repository Layout

The previous revision sketched a greenfield tree in which each directory was named for its ASDF system. That was a proposal, not a specification, and it should not be acted on: directory names and system names are independent, only the system names appear in code, and renaming directories is expensive here in a way it was not before. Ids derive from paths and every fact carries an origin-file, so moving a directory rewrites every id in the index, invalidates the cache wholesale, and breaks any golden-file test keyed on a path. Under files-as-truth, paths are part of identity. The existing tree stands.

```
src/
  ontology/         ; loom-ontology      implemented
  graph/            ; loom-graph         implemented
  analyzer/         ; loom-analyzer      implemented
  knowledge/        ; loom-knowledge     implemented
  adapter/          ; loom-adapter
  docs-analyzer/    ; loom-docs
  workspace/        ; loom-workspace
  rest/             ; loom-rest
  mcp/              ; loom-mcp
  process/          ; loom-process
tests/              ; loom-tests
tools/              ; tree-sitter subprocess helper
docs/
  design/           ; decisions (YAML)
  rules/            ; checkable constraints (YAML)
  arch/             ; architecture overviews
  concepts/         ; domain vocabulary
CLAUDE.md
```

The four implemented systems keep the directories they have. The mapping is a convention rather than a rule — directory src/knowledge holds system loom-knowledge — and it is written down here precisely because it is not derivable. The one name chosen with care is src/docs-analyzer, which avoids colliding with the docs/ content tree at the root; a directory named docs/ inside src/ that contains an analyzer for the documents in docs/ is a confusion worth spending eleven characters to avoid. If the tree as built differs from the above, the tree is right and this section should be corrected to match it.

Loom’s own docs/ tree is not decoration. It is the level 1 test fixture, the source of the architectural rules the build enforces, and the first real evidence that a decision recorded by an agent in July is still findable, still linked to live code, and still true in October. CLAUDE.md remains at the root as the validated-knowledge file for agent sessions — the manual precursor of exactly what this system automates, and worth keeping until the automated path has earned the trust.

## Revision 1 section numbers

Other files in this repository cite sections of this document as SS followed by a number. Some of those citations were written against revision 1 of the document (commit c5d3649), which numbered its sections differently from revision 3, the text above. Revision 2 (commit d69542a) numbers every cited section as revision 3 does, so it has no column. The table lists each numbered heading of revision 1 with the number of the revision 3 heading of the same title.

| Revision 1 number | Revision 1 title | Revision 3 number |
| --- | --- | --- |
| 1 | Introduction | 1 |
| 2 | System Overview | 2 |
| 3 | System Decomposition | 4 |
| 4 | Ontology Layer (loom-ontology) | 5 |
| 4.1 | Core classes | 5.1 |
| 4.2 | Entity taxonomy and define-entity-type | 5.2 |
| 4.3 | Relationship taxonomy | 5.3 |
| 4.4 | Ontology operations | 5.4 |
| 5 | Graph Manager (loom-graph) | 6 |
| 5.1 | Concurrency model: single writer | 6.1 |
| 5.2 | Transactions and validation | 6.2 |
| 5.3 | Query protocol | 6.3 |
| 6 | Graph Adapter Protocol (loom-adapter) | 7 |
| 7 | Workspace and Snapshot Management (loom-workspace) | 8 (title changed) |
| 7.1 | Overlay model | 8.1 |
| 7.2 | Snapshots | 8.2 |
| 7.3 | File and Git monitoring | 8.3 |
| 8 | Code Analyzer (loom-analyzer) | 9 |
| 8.1 | Analyzer protocol | 9.1 |
| 8.2 | Tree-sitter integration strategy | 9.2 |
| 8.3 | What structural analysis emits | 9.3 |
| 9 | Impact Analysis Specification | 11 |
| 10 | REST API (loom-rest) | 12 |
| 11 | MCP Server (loom-mcp) | 13 |
| 12 | Testing Strategy | 14 |
| 12.1 | Test levels and bootstrap order | 14.1 |
| 12.2 | Self-analysis as the primary fixture | 14.2 |
| 12.3 | Architectural invariants as executable queries | 14.3 |
| 12.4 | Incremental equivalence | 14.4 (title changed) |
| 12.5 | Guarding against vacuous passes | 14.5 |
| 12.6 | What self-hosting does not cover | 14.6 |
| 13 | Risks and Spike Plan | 15 |
| 14 | Repository Layout | 16 |

Two rows have no revision 3 heading of the same title and were matched by hand. Revision 1 section 7 contains the sections 7.1 to 7.3, which are 8.1 to 8.3 in revision 3. Revision 1 section 12.4 describes the same three-graph comparison (graphs A, B and C) as revision 3 section 14.4.

These 14 cited ids name different sections in revision 1 and revision 3, so a citation of one of them has to be read against the revision it was written for:

- SS3: revision 1 "System Decomposition"; revision 3 "Process Model and Command Surface".
- SS4: revision 1 "Ontology Layer (loom-ontology)"; revision 3 "System Decomposition".
- SS5.1: revision 1 "Concurrency model: single writer"; revision 3 "Core classes".
- SS5.2: revision 1 "Transactions and validation"; revision 3 "Entity taxonomy and define-entity-type".
- SS5.3: revision 1 "Query protocol"; revision 3 "Relationship taxonomy".
- SS7: revision 1 "Workspace and Snapshot Management (loom-workspace)"; revision 3 "Graph Adapter Protocol (loom-adapter)".
- SS8.1: revision 1 "Analyzer protocol"; revision 3 "Overlay model".
- SS8.2: revision 1 "Tree-sitter integration strategy"; revision 3 "Snapshots".
- SS8.3: revision 1 "What structural analysis emits"; revision 3 "File and Git monitoring".
- SS9: revision 1 "Impact Analysis Specification"; revision 3 "Code Analyzer (loom-analyzer)".
- SS10: revision 1 "REST API (loom-rest)"; revision 3 "Documentation Analyzer (loom-docs)".
- SS11: revision 1 "MCP Server (loom-mcp)"; revision 3 "Impact Analysis Specification".
- SS12: revision 1 "Testing Strategy"; revision 3 "REST API (loom-rest)".
- SS13: revision 1 "Risks and Spike Plan"; revision 3 "MCP Server (loom-mcp)".

The numbers 5, 6, 8, 14 also name different sections in the two revisions. No file cites them.
