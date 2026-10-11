# Loom - a Software Knowledge Engine

## Summary

Any team that works with Claude Code, or with any other coding agent, eventually learns that the lack of long-term memory is a significant issue. Without an appropriate memory system, the tools read the same files over-and-over to re-derive the same relationships, and every session starts from the same level of ignorance.

The code alone is not enough to be the memory. The documentation a best-in-class organization generates — requirements, architecture, designs, plans, reviews, bugs — must also be available, linked to each other and to the code, in a form an agent can query rather than read end to end.

Even with good quality linked documentation, the tools will need to crawl the code using grep and search the documentation using whatever tools are available. To minimize token use, accelerate development and get consistent results — what is needed is a tool which the coding agent can use to quickly find relevant pieces of code, determine the impact of changes, and determine dependency graphs, and a skill process for using it.

Loom is that tool. It provides a knowledge graph over code, documents and tests that can be searched and inspected, reached through a console, a REST API and an MCP server over one service. It answers by lexical search and by semantic search and fuses the two with current best-practice rank fusion.

Because LLMs run on text prediction, more well written text is better. That is a bottleneck for human developers and is easily solved by a workflow driven by documents the LLM drafts and the appropriate staff review — product managers, designers, and architects. Loom contains a basic workflow engine but is deliberately not a task management system. The workflow in Loom suffices for small teams; at scale Loom should be integrated with JIRA or GitHub Issues, and with an agent management system, so that multiple agents can be launched against different worktrees and Loom indexes, and be controlled and checked at defined workflow states.

Loom was bootstrapped on a multi-repository system written in Common Lisp and JavaScript, and it carries analyzers for both, plus analyzers for the YAML and Markdown that documentation lives in. It also reads Python source, package manifests and Firebase configuration. Adding a language means writing a new analyzer type, and the language must have a parser Loom can reach.

Loom is designed to run on each developer’s machine and index the git trees they want indexed. It picks up changes as editing occurs, so an agent’s answer describes the working tree rather than the last commit. A server-based Loom can also be installed that indexes a defined branch of each of the organization’s repositories using standard CI tooling. A local Loom can be told about a remote Loom, so that a developer with one repository checked out can still ask questions that span the code they are changing and the primary branch of the codebases they depend on.

Loom is not designed for large organizations. Teams of 1 to a hundred should find benefit, as long as every developer can reach a central Loom server and the organization has strong CI producing automatic testing of all changes. We have run teams spanning that range and see great potential benefit from using Loom.

Loom is fundamentally designed to support an AI-first development organization. A core assumption is that a project team, which often needs changes across the whole codebase, can use LLM tools and CI infrastructure to make changes in any code base the organization controls, subject to review by the owners of the affected areas. Loom’s ability to federate multiple code bases and answer questions across that federation is designed to enable this new AI first development model.

This document describes the architecture, and the concepts Loom is built on. Parts of it are running today on four real trees; parts of it are the designs that are planned to be built. Sections are marked Where this stands where the distinction matters.

We hope Loom helps your development team, and we look forward to improving this open-source tool from your feedback.

## Why Loom Exists: the Cost of an Agent Re-Reading the Code

AI coding tools, when planning a change, use grep and sed to explore the code. They first find every area that might be affected and send those to the LLM to determine which of them matter. This is slow and token expensive. In complex architecture the LLM ends up exploring the same complex files almost every time.

For example, in our JavaScript code base we have a model instantiated by callbacks from the server and stored as the server stores it, a proxy that lays on top of that model, a domain object that is a set of classes written in pure JavaScript that serialize to and from the underlying models, and classes that make this efficient to code. The Loom project started when we got tired of watching Claude read all these files again and again to understand the underlying architecture.

An agent uses Loom to find the lines where something is defined, to ask what is impacted if a particular function changes, and to learn why the code works the way it does by reading the architecture and design documents attached to it. An agent that cannot ask where is this, who calls it, what does changing it reach, and what has already been decided about it has no option but to read the tree again.

A grep over a package prefix finds the wrong files and the wrong function lines. A grep counts a docstring example as a call, counts a recursive self-call as an external caller, and reports a dead function as busy. A grep for import in a JavaScript tree returns too much information. Each of these examples was found as we developed Loom alongside our game code base.

The second half of the problem is that the reasoning behind code does not live in code. Why a subsystem is shaped the way it is, which alternative was rejected and on what evidence, which measurement a threshold came from, which test is a pin that must not break — all of that is either written down somewhere an agent can reach or it is re-derived, badly, every time. A knowledge engine that indexes only code solves half the problem and leaves the critical, expensive learning half.

Therefore, Loom indexes both into one graph, and answers one question with both halves: the definitions the task named, the decisions governing them, the rules that constrain them, the tests that pin them, and the documents that bear on them. Loom is designed to optimize recall of the functions, files, and snippets that matter. Precision, i.e. that only the correct items are returned, has been downgraded to support higher recall.

The [VALUE.md](VALUE.md) file provides examples from our actual code bases where Claude judged Loom to have saved time, tokens, and rework.

## Who Loom is For

Loom is for a team that has decided to develop with LLM assistants and maybe agents. That team must make AI coding work on a codebase large enough that no single person holds in their head.

Loom fits a group with these properties:

- Between one and roughly a hundred developers. Far above that, the assumptions about a shared service and the complexity of organizational management may require other tools and procedures.
- Several repositories that depend on each other, where a change in one may require a change in another. For example, extending the payments UI may require new capabilities in the payments service.
- Strong CI, so that a change anywhere in the tree is automatically tested, and the CI can continuously update an image of the main branches on all code trees for a central Loom to read.
- A willingness to write things down. Loom’s document apparatus distinguishes it from a call-graph browser, and it is only as good as the documents the team keeps. The Claude agent rules and the concepts that ship with Loom make the agent write things down in a structured way, so documentation comes along as part of the process.

It also fits the developer working alone, with the workflow scaled down: the same chain of documents, the same index, no forge and no approval policy. A single developer or small team does not need a document management or task management system.

It is not for an organization that wants a task tracker, a code review tool, or a replacement for its forge. Loom holds knowledge about the tree and answers questions about it. Everything else you may want to run your team should be integrated with Loom as appropriate for the organization’s development model.

Loom is written in Common Lisp. Installing takes five steps: install SBCL and Quicklisp, clone Loom, put its commands on the PATH, tell the service which repositories to watch, and prepare each of those repositories for the workflow. Appendix A has the full sequence, and INSTALL.md has the packages and the commands that were run to check them.

## Design Assumptions

### Development Assumptions: Git, CI, and the Document Store

Loom indexes both code and the documents that inform the agent of the why and how of the code – requirements, designs, architecture etc. The simplest configuration of Loom, and the installed default, is that the documents are stored in a docs directory below the top level of the git tree. However, these files are accessed through a file interface that may be substituted for a github issues interface, a JIRA interface, or other document store interface.  

On the code side, Loom always reads the current checked out tree. Loom runs a watcher so any changes to a code file will automatically be updated in the index.

The knowledge graph is derived and is never a second copy of the truth. It is an index over a store of documents, it can be discarded at any moment, and recovery is reindexing. Everything Loom needs from a document store is expressed as an adapter protocol, and the git repository on disk is one implementation of that protocol — the default, the reference implementation, and the only one running today.  Interfaces beyond this file git interface is a place to extend Loom.

In order for Loom to work it must be that anything not derivable from the store must be written back to it to preserve the knowledge. This is why documentation is a first-class analyzed source rather than a side feature, and why an agent recording a decision writes a document.

When a document store is configured, and this is not git, documents are materialized as files in the working tree, in an area that will be git ignored, because an LLM tool acts on a checkout. When the store is git those files are the store; when it is anything else they are a working copy of it, and the distinction matters only when the two disagree.

Appendix G gives the adapter protocol itself, and the one capability that divides backends from each other.

### Organizational Assumptions: Review, Ownership, and Code Domains

#### Doc on Main, Branch to Code

Loom assumes that a configurable branch name is the primary branch. The default is `main`. Concepts, rules and architecture notes are written to main because they span multiple requirements. A new requirement is written to main, and then the design and plan are developed before branching. When development starts, the assumption is that the LLM will branch to a branch named after the requirement, such as `req-0079-open-source`, or after the bug, such as `bug-0044`. After the code is completed and a pull request is done, the branch merges back to main. This process is not specified in Loom, nor is it required for Loom to work.  This practice is a working convention. It is not written into the agent rules that ship with Loom.

The split in git branches between main and a branch is for a reason the workflow already depends on. A document held on a branch cannot be referred to: its id is allocated in no tree anyone else can see, a `refines:` naming it resolves to nothing, and a check reports that reference as unresolved on every machine but the author’s. So a document lands as soon as it exists, and the only thing that travels on a branch is code, which has nothing to say to anyone until it works.

This is also what keeps the choice of document store open. Because no document type is edited on a branch and merged, no store has to carry branch-scoped revisions in order to run this workflow — and that is the capability which otherwise divides one backend from another. Appendix G sets out the distinction.

There are two consequences from this decision. First, a developer’s service indexes the branch they have checked out and answers about work in progress. A central service indexes the primary branch from CI and answers about what has landed. Neither substitutes for the other, and a team deployment needs both.

Second, a document written before its code names code that does not exist yet. A design on main declares `affects:` against definitions that live only on a feature branch until it merges, so an index built from main reports those names as unresolved for exactly as long as the work is in flight. That is work in progress rather than documentation rot, and today the two look identical. Telling them apart needs the set of open branches, which is what naming a branch for its requirement resolves.

Where this stands. The branch naming is a working convention, and nothing in Loom reads it. Loom does not report which requirement a working tree is implementing, does not refuse to close a requirement from the wrong branch, does not weigh that requirement’s chain when building context, and does not distinguish a pending reference from a rotted one. All four become cheap once the convention is machine-readable, and all four are unbuilt.

Loom writes a status; it never approves one. A status is an ordinary field on a document, and Loom writes it through the store like any other field. What Loom does not do is decide that a transition is allowed.

The reason is that the index is derived and can be discarded at any moment, so anything held only in the index is cache. An approval recorded by Loom would be exactly that: it would not survive a rebuild, and it would sit somewhere other than the document it approves. So the right to move a status belongs to the store, and Loom’s part is to ask before writing and to report the refusal when the answer is no.

Each store answers in its own way. On the git store the answer is a review. The status line is a one-line diff; the commit carrying it is reviewed by whoever owns the decision; branch protection is what makes that reviewer mandatory. git blame on the line names who moved it and when, and the commit message says why. On a repository with no branch protection the convention degrades to discipline, which is a property of the deployment rather than of Loom. On a store with its own workflow engine — a tracker, or a service built for this — the permission model and the transition rules belong to that backend, Loom asks before it writes, and a refusal comes back in the backend’s own words.

Review and ownership run through a maintainer map: a file that names which team approves documents affecting a given part of the code.

That map keys on the system a document affects rather than on the directory the document sits in, and system here means something specific: the build and namespace unit a definition belongs to. In Common Lisp that is the ASDF system, or the package the file declares; in another language it is the module or package equivalent. Loom derives it from the file’s path or its package declaration and records it on every entity it indexes, and a map or a rule may name a family of systems by prefix rather than listing each one — one entry covering the fourteen game/\* packages of a private tree, for instance (docs/PRIVATE-TREES.md).

Ownership has to key on the system because the document directories are flat by type. Every design sits in design/, whatever it is about, so a rule keyed on paths matches every design or none. What a design is actually about is the code it names in affects:; Loom resolves those names to entities, and each entity carries its system. “Who approves this design” is then a query over the index rather than a convention nobody can check.

A system is not a domain. A domain is declared by the repository, names a root within the tree, and exists to restrict searches. A system is derived from the code itself and is what ownership and layering rules key on.

Code bases may have multiple domains. In Lisp a domain is defined by package names. In JavaScript and TypeScript implementations, one set of source may be used by the front-end, by the node server, or by lambda functions in the cloud. Loom supports this through domains, which restrict searches. A repository declares its domains in the manifest under .loom/, each domain naming a root within the tree; every indexed entity then carries the domain it belongs to, and a query can name one by writing the repository and the domain together — front-end/server. Naming a domain the repository does not declare is refused, and the refusal lists what it does declare.

Where this stands. A maintainer map — a file naming the team that approves documents affecting a given system or family of systems — is designed and not yet built, along with the generation of a path-keyed owners file from it so the forge enforces the map rather than merely reporting it. The map holds teams and not people: a forge already knows who is in a team. What a forge cannot answer is which team owns a package family, and that is the one column the file exists to hold.

### How Loom Divides Work with Git, the Shell, the Forge and Task Managers

The index holds the present git branch. Every Loom answer is about the tree as it stands. When a name changed, what a migration deleted and where it went, and why something is the way it is are git’s questions — git log -S and the commit message.

The shell is right for four things: reading build files, because a source file is indexed whether or not any build file loads it, so a file missing from its build definition looks healthy while nothing can call it; confirming that two files with one name are byte-identical; anything in deliberately unindexed directories; and anything not yet written, because code that does not exist has no entity.

The forge is a projection and never the record. Where Loom integrates with GitHub or an equivalent, deleting every issue the adapter opened must lose nothing, and configuring no adapter must leave every state computable from the store.

A task manager holds the schedule. Loom records how much something matters and when to work it as fields on documents, and holds no board, assignment or sprint.

## How Loom Works

### What the Graph Holds: Entities, Relationships, Provenance and Document Links

The ontology centers on entities and relationships, both first-class objects, declared in a registry.  Loom internally creates and stores an entity relationship graph.

Code entities include repository, module, package, class, interface, function, method, variable and test case. Documents are entities too — requirements, designs, decisions, architecture notes, plans, reviews, bugs, concepts and rules.

Loom has seventeen relationship types. The ones this document leans on are CALLS, IMPLEMENTS, INHERITS, IMPORTS, USES, DEPENDS_ON, TESTS, DOCUMENTS, CONTAINS and BELONGS_TO, plus the document edges DECIDES, APPLIES-TO, REFINES and MENTIONS.

Two properties of that registry matter more than the list.

Identity is derived, never generated. An entity’s id is computed from its natural key rather than assigned, and the natural key is the entity’s type together with the properties that identify an entity of that type. For a function, that is the file it is defined in and its name. For a method, the qualifiers and specializers as well, since those are what distinguish one method of a generic function from another. For a document, its path. The resulting ids are legible:

```
function:src/serve/registry.lisp:record-read-query
class:data-api/game-handler.lisp:game-handler
method:src/analyzer/yaml-analyzer.lisp:type-specific-properties::(eql document),t,t
document:docs/requirements/REQ-0001.yaml
```

The type has to lead, because two types can key on the same property — a file and a document are both identified by a path, a module and a package both by a qualified name — and without the type they would collide.

Deriving the id rather than generating one is what makes an index rebuilt from scratch identical to one updated incrementally, rather than merely equivalent. That in turn is what lets the rebuild-equivalence test compare the two directly, which is the highest-value test in the suite. It also means an entity’s id moves while its identifying properties are still being filled in, so the identity is fixed at one known boundary: the moment the entity enters the index.

Impact traversal is declared rather than coded. Each relationship type carries metadata saying whether it is traversed transitively, applied once at the end, or collected into its own named field. The tests, documents, decisions and mentions attached to an impact report are there because four relationship types declare it, not because the traversal knows what a document is. Adding a relationship type teaches the impact engine about it with no edit to the traversal.

Every fact also carries its provenance, because facts extracted structurally from source and facts inferred by a model have very different reliability. Each entity and relationship records where it came from — structural, introspected, inferred or human-validated — how strongly it is supported, which entities’ modification invalidates it, and when it was last confirmed. When a source entity changes, the dependent inferred facts are marked stale rather than deleted, and stale facts stay out of an agent’s context until re-verified. Without this the graph accumulates plausible-but-wrong knowledge and agents learn to distrust it.

Document-to-code edges follow the same principle. A document names code in one of three fields, and the field decides how strong a claim the edge makes: a decision or a design writes affects: and governs that code; a requirement, plan, bug or review writes the same field and merely bears on it; an architecture document writes describes: and only describes it; a rule writes applies-to: and binds it. A name written in backticks in prose is weaker still and records only that a file mentions the thing. Recording an inference as a declaration is the failure this ladder exists to prevent.

### How the Index is Built: Analyzers Propose, One Writer Disposes

Loom is twelve systems in four tiers over one write path.

The bottom tier is three leaves that depend on no other Loom system: the ontology, which holds declarations and nothing else; loom-utils, the few functions that two systems unable to see each other both need; and loom-embed, the embedder protocol and its Ollama client. Above them sit three siblings that cannot see each other — the graph, which owns storage, transactions, queries and resolution; the analyzers, which turn text into operations; and the document store, which holds documents behind a protocol and depends only on loom-utils. Above those, the knowledge layer is read-only, shaping graph answers into what an agent can use, and the workspace owns the indexing pipeline, the file monitor and the write path. The top tier is four peers rather than a stack: the console, the operation registry and listener, and the REST and MCP protocols over that one registry. A third protocol would be a fifth peer and should need no edit below the registry.

Four invariants hold across it.

One writer. Every mutation goes through one transaction function. A transaction plans completely before it applies anything, so it lands whole or is rejected whole with a structured problem naming the failing operation.

Analyzers cannot reach storage. An analyzer receives a path and the contents of a file and returns a list of operations. It may not read the filesystem, the graph, or anything the caller did not hand it. This is what makes language independence enforceable: adding a language is writing one method, not touching the graph.

Derive, never consume. A resolution pass reads a property an analyzer wrote and never rewrites it. This sounds like bookkeeping and is not: a pass that consumed its own input could not be re-run, so an edge destroyed when a file was reanalyzed could never come back.

A gap is recorded, never guessed. A name matching exactly one definition becomes an edge; a name matching several is left unresolved and reported. A damaged form costs a form and is recorded with its line range rather than repaired into an entity. A fabricated fact is worse than a recorded miss, because a miss is visible and a fabrication is not — and the record of what did not resolve is what makes documentation rot detectable.

The pipeline itself: a file changes; the monitor notices, reads it, and asks the registry which analyzer claims the path; the analyzer returns operations that always open by retracting that file’s previous contribution, so an incremental update is a full replacement of one file’s facts and a deleted definition leaves the index. Then resolution passes run over the whole index, because they are the first thing that needs more than one file at a time: turning recorded call names into edges, and turning a document’s declared fields into edges and its prose into weaker ones. Change detection records a modification time and a hash of the bytes analyzed, because comparing times alone misses any edit landing in the same second as the read — which is what happens whenever a developer saves twice quickly.

Where this stands. The graph is in memory, behind an adapter interface expressed as generic functions. Persistent backends — a graph store, a vector store, a full-text engine, an object store for snapshots and artifacts — are the target state, and under the derived-index rule each of them is a performance decision rather than a durability one. Moving to one is additive: implement the adapter methods, replay into it, switch.

### How a Question is Answered: Seed, Fuse, Expand, Budget

A context query runs in four stages.  The model optimizes recall because in the end found code blocks will be sent to an LLM to judge relevance so it is more important to contain the answer than to return few false positives.  A returned entity that did not matter costs about fifteen tokens and one line of attention from a system whose entire competence is deciding what in a large context is relevant. A missing entity costs a grep, and an LLM review of the grepped code, and costs it silently: the agent cannot distinguish a subsystem Loom did not return from one that does not exist.

Seed. Two independent generators propose candidates. The lexical generator splits the task into tokens — on non-alphanumerics and at case boundaries, keeping compounds whole as well as split — stems with a stemmer, and matches against both names and the documentation each entity carries. The dense generator embeds the task and scans a vector sidecar built per repository from each definition’s name-as-words plus its docstring.

Fuse. Reciprocal rank fusion merges the two ranked lists into at most eight seeds. The measured effect on 450 generated known-item cases was 410 to 443; on 120 queries whose words are provably disjoint from their target’s, 9 to 39.

Expand. A best-first walk expands from the seeds over edges that cost different amounts, bounded by accumulated cost rather than by hops, so one number serves two shapes of query: a hierarchy runs deep inside the horizon where a call fan reaches one step.

Budget. A budget decides how much of what was found is printed. Two tiers sit inside one total the caller may name: full source for a few definitions, and a long cheap list of one-line entries for everything else recalled. Both tiers are charged against the same number, because a tier outside the budget is a budget measuring the wrong thing.

An answer says what it is. Every bundle reports which of the task’s own words the index answered, which it answered only weakly, and which it answered with nothing — so a caller can tell a bundle whose subject is present from one whose seeds all rode a common word. A semantic seed structurally cannot mark a word answered, because cosine returns nearest neighbours for every query ever asked, and a mechanism allowed to answer a word would make “nothing here does that” impossible to say. Every answer also reports drift: how many of the files it claims have changed since the index read them.

The optional dependency is genuinely optional. No embedder, no sidecar, or a sidecar built by a different model are three states with one meaning — the lexical generator answers alone and nothing is reported as an error. Vectors from two embedders are never compared: the resulting number is in the ordinary range, nothing marks it wrong, and the store would return plausible neighbours forever.

#### Tuning Retrieval for a Deployment

Retrieval is the part of Loom most likely to need tuning, because what a good answer looks like depends on the tree and on the agent reading it. Loom ships a retrieval log for exactly that, and it is off unless an operator turns it on.

Setting LOOM_CONTEXT_LOG in the service’s environment enables it and names the directory; any other non-empty value selects the default, a dot-directory inside Loom’s own tree, which keeps the log out of the index it judges. No request field can turn it on. 

With the log on, each context call writes a record holding the task as asked, the tokens derived from it, the seeds in rank order with their scores, the items returned with their bands, and the latency. Every answer then carries feedback: on and a record id. When the agent finishes the work that call was for, it posts back the record id and what it actually used — and, more valuably, what it needed that the bundle never returned and where it found that instead. A channel that can only confirm hits measures nothing, because the misses are the population that would raise recall. When the log is off, the answer says feedback: off and carries no record id, so an agent never spends a call reporting into a channel that is closed.

Those records are the corpus a judged acceptance measurement scores against, and they are what an argument about a setting has to be made from. The settings worth arguing about are the seed limit, currently eight; the share of the budget the source tier may take, currently half; the cost horizon the expansion walk stops at; and the weight the dense list carries in the fusion.

### Why the Workflow Needs a Document Model

Loom exists because the knowledge around code does not survive in the code. A design argued in a chat window and then implemented is knowledge that was never written back to the store, and it will be lost without anyone noticing.

So each stage of work leaves a document, each document names the one it answers, and Loom indexes all of them.  You will find a substantial number of these documents in the Loom git tree itself.  The Loom init process will create a default structure for you on a new git database which may or may not already be in development.

The types of files are:

| Directory | Holds | Ids |
| --- | --- | --- |
| requirements/ | what is wanted, and why the current behaviour is not it | REQ-nnnn |
| design/ | the shape of the answer: entities, ownership, boundaries, alternatives rejected | DES-nnnn |
| decisions/ | a decision taken, its rationale and its consequences | DEC-nnnn |
| arch/ | the structure and mechanism of the software as it stands | ARCH-nnnn |
| plans/ | the ordered steps, the files each touches, the risks | PLAN-nnnn |
| reviews/ | what a review found, and whether it is safe | REV-nnnn |
| bugs/ | a defect worth remembering after it is fixed | BUG-nnnn |
| concepts/ | a recurring idea worth naming once | CON-nnnn |
| rules/ | a constraint, enforced as a check where it can be expressed as one | RULE-nnnn |

That table describes the git store, where the directory names the type and documents are YAML. On another store the same nine types map to whatever that store uses to separate them: an issue type, a project, a label. The types and the links between them are the model; the directories are one store’s spelling of it.

Every document may declare what it refines, which makes the chain walkable in both directions — from a requirement forward to everything that came of it, and from a plan back to the requirement that justifies it. The fields that reach into code are the ones described earlier: affects: on most types, describes: on an architecture document, applies-to: on a rule. All of them resolve against the index, and a name in any of them that resolves to nothing is reported rather than dropped. That report is the documentation staleness detector.

Beyond those shared fields, each type carries what its own genre needs — a decision its rationale and consequences, an architecture note its invariants, a bug the reason the defect went unnoticed. Appendix F lists the fields type by type.

### How a Document’s Status Moves, and Who Moves It

Every document carries a status, and the vocabulary is per type:

```
RULE    active | retired
CON     accepted | superseded
DEC     accepted | superseded
ARCH    draft -> accepted -> superseded

REQ     draft -> accepted -> implemented | partial
DES     draft -> accepted -> implemented | partial | superseded
PLAN    draft -> final
BUG     open -> closed
REV     open -> closed
```

Rules, concepts, decisions and architecture notes are high-level documents that control the overall flow of information and predicates that have to be maintained on the system. These are stable across multiple requirements. Architectures can be superseded as the design progresses and need to be updated when a system fundamentally changes.

The requirements, design, plan, bugs, and reviews are the core of the workflow documents. A requirement is created, a design is generated from the requirements, a plan is created to implement the design, code is written to meet the design, tests that test the system against the fit within the rules and concepts are created and run, bugs are created during implementation and testing, and optional code reviews may create additional bugs. Separately, a bug results in a plan, which leads to code, testing, and closing of bugs.

When working with Loom in a coding agent, the developer or architect works at the requirements level.  The process is to write some conceptual requirements in the coding agent and ask it to create a Loom requirement document.  Review that document, add or remove issues, update the summary, let the agent refine your results. Then let the agents move through the flow - design, plan, code, review.  If desired inspect the design to make sure nothing was missed. If an architect is responsible for a particular code base integrate an event to have them check the designs. Then have the agent move to plan and code. Review is optional but does lead to better code.  Set your Linter to the rule you care about.

The initial requirements are written on the primary branch as draft. A draft on main is not a commitment. It is an allocated id, a reference other documents can resolve, and a place for the argument to happen in the open. Holding a document back until it is agreed blocks every document that would answer it, for as long as the argument lasts.

A transition out of draft is its own commit, reviewed by whoever owns the decision. Using git commit this will trigger whatever workflow you have designed in your CI on a commit to main. It is one line, so the review is about the judgement rather than about the prose, which is what makes requiring a reviewer affordable.

Work may proceed against a draft, and the refusal comes at the end. A design may refine a draft requirement and a branch may implement a draft design. What is refused is the claim that the work is finished while the documents above it are still drafts. Blocking at the start would serialize every chain behind an approval.

The complete operation should be used to advance plans, not changes by hand and not changes by the LLM coding agent. It is the only thing that should ever move a status or move a finished document into the store’s completed area. Called with no verdicts it writes nothing and returns the chain, the blockers and what it still needs.

Supplied with verdicts, it sets the plan final, walks upward while the verdicts stay terminal, refuses any document another unfinished document still refines, and files each finished document under completed/ in the same operation — so the status and the directory cannot disagree.

A single document is moved the same way, through a set-status operation that writes through the adapter; on the git store what it writes still has to be committed, reviewed and merged like anything else, and on a store with its own approval model the write is refused unless that model allows it.

The implemented-versus-partial judgement is the author’s and is never derived by Loom. It can be suggested by the coding agent and should be approved by the code author.

### Extending the Document Model: New Categories, New Rules

Adding a document category means creating a directory and registering it, not changing code. Loom keeps a registry mapping a document-directory name to an entity type — decisions to decision, design to design, rules to rule, arch to architecture, concepts to concept, and the remaining four to the generic document type — and a registration call adds an entry to it. A directory with no registered type is not ignored: its files are indexed as generic documents and the count is reported by status.

Adding a rule means writing a rule document that declares what it binds in applies-to:, how strictly it is enforced in severity:, and — where the constraint can be expressed mechanically — a check: clause naming one of five kinds:

- :no-edge — no edge of these types may run from this system to that one. This is how a layering rule is written: “the ontology depends on nothing”, “analyzers never reach the graph”.
- :no-call-to — no edge of these types may reach any of these named callees. The narrower sibling of the above, for a rule that forbids reaching specific functions rather than a whole system. It is a deny list, so it is only as current as its list of names.
- :requires-edge — every entity of this type must have an edge of one of these types.
- :property-constraint — every entity of this type must carry this property, optionally equal to this value. This is how “every fact has an origin file” is written.
- :property-absent — no entity may carry this property; every carrier is reported with its location and the offending value.

Every active rule with a check runs against the graph on each indexing pass, and its violations are recorded as entities owned by the rule document: all of a rule’s violations are retracted and re-asserted together, so a rule that now passes stops carrying yesterday’s findings, and reindexing the rule document clears them. A rule whose constraint outgrows the five kinds is still a valid rule — it stays advisory prose, and status counts it among the unenforced so that prose-only drift stays visible rather than comfortable. Adding a sixth check kind is one method plus one registry entry.

The document directory is configurable, and the preparation script asks before writing into an existing one. A new document genre added later has to say which of the two judgement axes — how much it costs, and when to work it — its documents sit on.

### Using Loom as a Single Developer

One developer, one service, several repositories on one filesystem. The service watches each tree, reindexes on save, and answers over console, REST or MCP. The document chain runs without a forge: statuses move because the developer moves them, and the loop from a note about a gap to a shipped answer can close inside a day.

This is the configuration Loom was developed in and the one that works today, including cross-repository answers: asking one tree a question while working in another is cheap enough to do over a passing curiosity, which is how a field that was read everywhere and written nowhere came to be found.

### Using Loom as a Team: Document Ids, Approval and Federation

Three things change when there is more than one person. The first is built in part. The other two are designed and not built, and they are a good place to extend and contribute to Loom.

Document ids must not collide. An id allocated by reading the tree and adding one works for one developer on one branch and fails the moment there are two: both read the state they can see, both pick the same number, and the collision surfaces at merge or not at all. This is the allocate-id operation of the store protocol, and a store that has an allocator of its own — any tracker does — simply answers it.

Part of the git store’s answer is built. Both allocators, tools/next-doc-id.sh and the Lisp next-document-id, answer the highest id plus one over the working tree and over every local and remote-tracking branch, so two branches in one clone are never handed the same number. Two clones that cannot see each other, such as a fork and its upstream, still can be. tools/doc-ids.py check reads the committed files through git and fails when a branch added an id its base also carries, when one id sits on two paths, when a file’s name is not its id, when a refines: or supersedes: entry names no document or more than one, and when a line the branch added names an id the base added after the branch point. A GitHub Actions workflow runs it on pull requests and on pushes. For the first of those failures it prints a command, tools/doc-ids.py renumber, which moves the branch’s document to the next free id and rewrites the old id only on the lines the branch added. It leaves other authors’ text and the commit messages alone. DES-0056 has a fork pull request squash-merged, so that the old id never enters the history of main.

The rest is designed and not built. The design (DES-0048) prevents the collision where the check above repairs it: lease a contiguous block of numbers and mint ids from it locally, with the lease ledger held on an orphan branch of the repository being developed. Git’s non-fast-forward rejection is the concurrency primitive: two instances claiming the same range both commit locally, the second push is refused, and Loom re-derives a non-overlapping range and pushes again. That retry is safe to automate for exactly one reason — a block is claimed and its push confirmed before any id is minted from it, so no document exists when the conflict is resolved and nothing is renumbered. It needs push access to the upstream repository, which a contributor working from a fork does not have.

Approval must be enforceable without a second system of record. On the git store that is the convention described above: documents land at draft, a transition out of draft is its own reviewed one-line commit, and branch protection on the default branch is what turns the convention into enforcement. On a store that answers may-transition itself, its permission model is the enforcement and Loom stops asserting one. Either way the approval lives in the same place as the document, which is the property being defended — not the commit that happens to implement it here.

Repositories must be able to reach each other. Today a cross-repository answer requires every tree checked out on one filesystem and indexed by one service. That holds for one developer with six repositories and fails for a team: ten services means ten clones per developer, each kept current; walking a tree is not free; and a federated edge records whichever commit that developer’s clone of the far tree happens to sit at, so two people asking the same question get different answers.

Loom supports federated analysis for this reason. Document federation — a requirement in one repository refining a design in another, or naming a capability it needs from another team — needs only the far tree’s documents and its declared aliases, which is a few hundred YAML files and no source at all. The half that crosses team boundaries is the cheap half.

Where this stands. A cross-repository request — a capability one repository needs from another, stated where the answering team will see it, with a lifecycle of proposed, open, answered, declined, deferred or satisfied — is designed and not built. So is the forge adapter that delivers it: a job on a pull request that adds a request declaration opens or updates an issue in the named repository. It needs the requesting repository and a token and nothing else — no federation, no shared index — which makes the signal path the cheapest part of this workflow to build and the part without which none of the rest is reached. Silence and a refusal must not look alike.

### What Loom Cannot See

An engine that reports its blind spots is worth more than one that does not, so they are part of the design rather than an appendix to it.

- The index holds the present. It answers nothing about the past.
- Structure reports the edges between systems in both directions and calls neither a violation. Which one was intended is not in the index.
- A check reports names that resolved to nothing. It cannot see a name that resolved to the wrong thing.
- A definition called only from inside a Lisp macro body looks uncalled, which is why an entry-point list carries the count of call sites that could not be attributed.
- A Lisp generic function’s inbound call count is near zero, because the calls attach to its methods. Counting callers means describing the methods, not the name — and skipping that step reads a codebase’s most-called function as unused.
- A small answer is not proof of a small change.
- A call name matching several definitions currently produces no edge at all, which falls entirely on codebases using polymorphism heavily; the intended answer is several edges each carrying confidence. And roughly half of all recorded call names in a large tree do not resolve while every surface a user can see reports zero — a gap that has to be surfaced at the point of the answer, because a small impact set and a contained change are otherwise indistinguishable.

### How Retrieval Quality is Measured

Loom is a ranking system, and a ranking system without an instrument is a collection of opinions. Three instruments run against the service: a hand-judged acceptance corpus, currently 42 of 44 returnable expectations present across four trees (a 45th expectation exists that no ranking can return, BUG-0043) with all absence cases correctly returning nothing; 450 generated known-item cases; and 120 queries constructed so that their words are provably disjoint from their target’s, which is the only family that can measure whether meaning was found rather than spelling. Each refuses to print a figure against a service it could not bring current.

The result worth publishing is a negative one. Four ranking mechanisms were measured in one month — coverage by distinct word, provenance rank, a name analyzer, and inverse document frequency — and all four came in at baseline or below and were withdrawn. What moved outcomes was candidate generation and slot allocation, not ranking.  The addition of semantic indexing was a significant improvement in candidate generation.

## Conclusion

Loom’s bet is that the next generation of development tooling differentiates not by having a smarter coding model but by having a richer, continuously updated, honestly-labelled understanding of the codebase — and that such an understanding has to include the reasoning, not only the structure.

The concepts holding the design together are few and they recur everywhere in it. The index is derived from a store of documents and never the other way round, so recovery is a rebuild and anything worth knowing gets written back to that store; the git repository is the default store and the one that carries the most, not a requirement of the model. A gap is recorded and never guessed, because a fabricated fact is invisible in a way a missing one is not. Recall beats precision when the reader is a model that throws away what it does not need and cannot recover what it was never given. Every answer says what it is: which words it answered, what it withheld, how stale it might be, and where it is blind.

Parts of this are running. Parts are the direction the running parts are being built toward, and this document marks which is which, because a design guide that blurs them cannot be checked. What has not worked, and what is still missing, is kept alongside what has, in the same repository, under the same rules — because a tool that indexes the reasoning behind code should be able to show you its own.

## Appendix A: Installing Loom and Preparing a Repository

Loom runs as a service on a Unix machine.

1\. Install the prerequisites. SBCL, tested here at 2.2.9, at /usr/bin/sbcl, which is what every script under tools/ invokes. Quicklisp at ~/quicklisp, supplying the thirteen libraries that the .asd files of the twelve systems and their test systems name — babel, bordeaux-threads, cl-json, cl-yaml, drakma, eclector, fiveam, hunchentoot, random-uuid, st-json, stem, usocket and uiop — and the dependencies they pull. INSTALL.md lists the Ubuntu packages, the 50 releases the first load downloads, and the commands that were run to check them. No library is cloned by hand.

2\. Clone Loom. It is an open-source tree and it is meant to be run from the clone:

```
git clone <loom> /path/to/Loom
```

3\. Put the commands on PATH.

```
cd /path/to/Loom
tools/loom-install.sh
```

This links loom and loom-serve into a directory on your PATH and then offers to register a systemd user unit. It links rather than copies, and the reason is particular to this program: Loom is a source tree an SBCL script loads at runtime, the running image is expected to track that source, and the tree is itself one of the repositories Loom indexes. A copy in a system directory would be a second Loom that is never the one under test. The script never calls sudo; where a directory needs root it prints the one command to run.

Then bring the service up:

```
tools/loom-serve.sh update
```

update starts a service that is down, restarts one whose image is older than the source, and does nothing otherwise. start, stop, restart and status do what they say.

4\. Register the repositories to watch. Each registered repository is indexed once and then watched: a monitor thread polls for changes and reanalyzes only the files that moved. There are two ways to register one, and they differ in whether the registration survives a restart.

The durable list is a file, tools/extra-repos, one absolute path per line, # to end of line a comment, blank lines ignored. tools/loom-serve.sh appends each line to the command it builds, after Loom’s own root — Loom always watches its own tree first, whether or not you name it, because the staleness check needs a repository to read an index timestamp from.

```
# Extra trees watched alongside Loom.
/path/to/game-server
/path/to/front-end
```

That file is gitignored, because which trees a machine holds is a property of that machine. Editing it changes nothing until the process is replaced: tools/loom-serve.sh restart. An update is not enough, because extra-repos is not source, so an update with no source change behind it reports “running and current” and goes on watching what it watched before.

The live way is a request to a running service, which persists nothing:

```
curl -X POST 'http://127.0.0.1:4780/v1/watch?path=/path/to/game-server'
```

/v1/pause keeps the index and stops polling; /v1/unwatch drops the index entirely. Use the request to try a tree out, and add the line to the file to keep it. The console takes the same commands by name: watch, pause, unwatch.

tools/loom-serve.sh status reports which trees are actually watched, read back from the service rather than from the file — the two disagree exactly when it matters, because a path in the file that could not be watched is skipped with a message to the log, and a tree added over /v1/watch is in no file:

```
$ tools/loom-serve.sh status
running, code current
  ready      Loom                   /path/to/Loom/
  ready      game-server            /path/to/game-server/
  indexing   front-end              /path/to/front-end/
```

A query that answers over fewer trees than expected is usually that list being short, not the query being wrong.

5\. Prepare each repository. tools/loom-init.sh \<directory> turns a tree Loom did not write into one the workflow can run on. It creates the document directories, writes the workflow conventions into the tree as a concept document, installs the agent-facing skill, optionally appends a pointer to an existing CLAUDE.md between markers, registers and indexes the tree, and generates a first architecture document describing the structure Loom can already see. It asks before writing into an existing document directory and before touching CLAUDE.md, it writes and never commits, and git status in the target shows exactly what was added. --update refreshes a prepared tree, replacing what Loom wrote and leaving what an author added below the loom:yours marker.

6\. Point the agents at it. The service exposes the same operations three ways — a console for a human, REST for anything that can make an HTTP request, and MCP for agent harnesses that speak it — so that tools such as loom_context, loom_find, loom_impact and loom_describe are available to the model with no file edited by hand. This can be a tricky area: agents have a strong tendency to fall back to grep even when instructed to use Loom, and you may have to edit your agent files to keep reinforcing it.

Optional: semantic seeding. Loom answers from lexical matching alone unless a repository has a vector store, and reports nothing about the absence. To get the semantic half, install a local embedder and build a store per repository:

```
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text            about 274 MB
```

Then run embed against each repository. Nothing is automatic, and a repository without a store behaves exactly as it did before any of this existed. Measured over two trees, the store took a generated known-item corpus from 410 of 450 to 443 of 450, and a corpus of queries sharing no word with their answer from 9 of 120 to 39 of 120. It costs about 31 ms per query and a one-time build.

Where this stands. There is no package and no installer beyond the scripts above: installation is a git clone, a Quicklisp environment, and tools/loom-install.sh. Per-repository configuration lives in a manifest under .loom/ in the repository itself, holding what a repository declares about itself that Loom cannot derive — framework definer macros, route callers, archived paths, and the code domains covered under organizational assumptions above. That file is being widened to carry the set of directories a repository wants indexed and, for an organizational deployment, where to authenticate.

## Appendix B: Why Loom is Written in Common Lisp

The ontology is modelled directly as live objects; generic functions give the storage adapter a clean protocol with per-backend methods; the ontology can be evolved at runtime without restarting the image; and macros keep the ontology-operation DSL concise. A knowledge graph is a living system and a live image is its natural host. A long-running image also means an index with a lifetime longer than a command, which is what makes rebuild-on-demand cheap enough to be the recovery story.

Using Lisp narrows the contributor pool and puts Loom on a toolchain most teams do not otherwise run. However, the tools are fast, stable, and have a rich set of capabilities. The mitigation is that nothing about the ontology, the workflow or the interfaces is Lisp-specific. The REST and MCP surfaces are the contract; what is behind them is an implementation.

The core third-party packages Loom takes from the Lisp community are:

- Hunchentoot — a fast, stable, multi-threaded web server. It carries both the REST endpoints and the MCP endpoint on one listener.
- Bordeaux-Threads — portable threads and locks, used by the file monitor and by the listener.
- Eclector — a portable Common Lisp reader. The Lisp analyzer uses it to read source as data without evaluating it, which is what lets an unfamiliar tree be indexed without being loaded.
- cl-yaml — YAML parsing, for documents and for the repository manifest.
- cl-json and st-json — JSON encoding and decoding for the REST and MCP surfaces.
- Drakma — an HTTP client, used to reach an embedder.
- FiveAM — the test framework the twelve test systems are written in.
- Stem — Porter stemming, used by the lexical half of the seeder.
- UIOP — portable filesystem and subprocess access.
- Random-UUID — identifiers for records that have no natural key to derive one from.

## Appendix C: Adding Support for Another Language

Adding a language is four steps: subclass the analyzer protocol, declare the extensions it claims, write one analysis method, and register an instance — with nothing upstream changing. Seven analyzers exist: Lisp, JavaScript, Python, YAML, Markdown, package manifests and Firebase configuration.

A parser-backed analyzer. For languages with a mature grammar, the intended route is a tree-sitter or LSP-backed analyzer, with TypeScript handled by a Node process that Loom manages rather than by re-implementing a parser in Lisp.

An enrichment pass. Reading source as text is the right baseline — it needs nothing installed, indexes an unfamiliar tree in seconds, and works on code that does not compile. It is also the root of a standing family of defects: macro blind spots, inline method definitions, ambiguous dispatch, package identity reconstructed from declarations. Each is a case of re-deriving, imperfectly, something the language’s own toolchain knows exactly. The answer is a second, optional pass that asks the toolchain: for Common Lisp, load the system into an isolated child process bounded by a timeout and a heap cap and read its introspection facilities; for other languages, the equivalent inspector where one exists. It runs only on explicit demand, never from the file monitor, and its facts carry origin files like every other fact, so the ordinary retraction machinery ages them out on edit. An index nobody re-enriched gives today’s text answer rather than yesterday’s image answer — it degrades toward the text index and never lies.

Third-party frameworks. A repository that leans on a framework Loom has never heard of should be able to teach Loom about its definer macros without editing Loom’s source. The registry of framework definers exists; loading extensions from the repository’s own manifest is the piece still to come.

## Appendix D: Integrating a Task Manager — JIRA, GitHub Issues and the Rest

Loom’s workflow is sufficient for a small team and is not a task management system. At scale a tracker enters in one of two roles, and the choice is made once per repository rather than discovered later.

Other data stores should project into git. The git store stays authoritative, and the tracker mirrors it in one direction: deleting every issue the adapter opened loses nothing, and every state still computes from the store. This is the default, and it is what an organization wants when the documents belong to the engineers and the tracker exists so that everyone else can see them.

As the store. The tracker answers the adapter protocol itself, allocating ids, enforcing transitions through its own permission model, and reporting change through its own events. Loom keeps a working copy on disk for agents to read and indexes that. What is given up is branch-scoped revision — a document cannot be edited on a feature branch and merged with the code — which the Doc on Main workflow does not ask for. An organization that wants its designs revised on the implementing branch should keep the git store.

Loom’s task-management adaptor class is the base class for both, and the file-based workflow described above is the current implementation of that adaptor. A forge adaptor is another implementation, and its shape is: (1) open or update an issue when a document declares something another team must answer; (2) generate the forge’s path-keyed owners file from Loom’s system-to-team map, so the forge enforces ownership rather than Loom merely reporting it; and (3) read approval events back as evidence rather than as authority. Documents can additionally be mirrored from a tracker into the document directories.

That mirroring generalizes to anything machine-generated, and it is the most dangerous item on this list. Converting a repository’s existing prose documentation into requirements and architecture documents is mechanically within reach, and a generated requirement asserts structure its source never committed to — once indexed, the graph lends it an authority it did not earn. The rule is that generated output must never be mistakable for a human’s: provenance on every document, a status the system will not treat as settled, and no silent regeneration.

## Appendix E: Integrating an Agent Framework

Loom is built to be the memory an agent system reads and writes, and the integration has three layers.

The tool surface. MCP tools and REST endpoints, callable by any harness. The guidance an agent needs to use them well is installed into the repository as a skill rather than as agent definitions — because agent names collide totally across projects, and because a skill is advertised to the model by the harness with no file edited. Loom’s own agents are about Loom; the transferable half lives in the skill.

The role contract. Each agent role needs an explicit read/write contract against the graph. The planner reads impact and decision history and writes plans. The architect reads structure and writes detailed change plans. The coder writes code, and the file monitor writes the resulting graph updates. The tester reads change sets and writes test entities, results, and a bug document when a failure turns out to predate the change. The reviewer reads rules and decisions, writes documentation updates, and writes a bug document when reading finds a defect no test exercised. That matrix — what each role reads versus writes — is the interface between agents and the knowledge engine, and it should be specified before the agents are built.

The scheduler. Above that sits work Loom does not do and should integrate with: launching agents against separate worktrees and separate indexes, and gating them at defined workflow states. Loom’s part is to answer what an agent needs to start and to record what it decided; which agent runs when is somebody else’s job, and the interface between the two is the workflow state that already exists in the documents.

## Appendix F: The Fields of Each Document Type

Every document, whatever its type, carries the same core. The spelling below is the git store’s, where a document is a YAML file; another store holds the same fields under its own names.

```
id:        REQ-0031                the type's prefix and a number
title:     one line                what this document is about
status:    draft                   a vocabulary that depends on the type
date:      2026-08-21
tags:      [retrieval, context]    free-form, for a human
summary: | one paragraph           what this says, for a reader in a hurry
body:    | the argument            the document proper
refines:   [REQ-0016]              the document this one answers
```

Two fields record judgements, and they are two fields because they answer different questions. importance: on a requirement and severity: on a bug share one vocabulary — critical, major, minor — and both ask how much it costs: a requirement asks whether the product would be wrong without this or only poorer, a bug asks how severe the impact is when it happens. priority:, p1 through p5, asks when to work it, and is derived rather than judged fresh: the impact above, weighted by how likely the thing is to happen, then sequenced against work already planned, because a bug a planned requirement will resolve on its way past should be sequenced behind it rather than fixed twice. A bug can be severe and last, and neither value is recoverable from the other. A value outside the vocabulary is dropped silently at analysis time and reported by the tree-wide check, so severity: high sets nothing.

On top of that core, each type adds what its genre needs:

- REQ — what is wanted, why the current behaviour is not it, and the observable that would settle whether it landed. affects: names the code it bears on. Carries importance:.
- DES — the shape of an answer to a requirement: the entities involved, who owns what, the boundaries, and the alternatives rejected with the reason. affects: here is a governing claim.
- DEC — a decision, in three parts: rationale: for why, consequences: for what it commits the system to, and lessons: for what it teaches. affects: is governing.
- ARCH — the structure and mechanism of the software as it stands, with an invariants: section naming what must remain true. It writes describes: rather than affects:, because it describes the code and does not govern it.
- PLAN — the ordered steps, the files each touches and the risks. Its closing step is what moves the statuses of everything it refines.
- REV — what a review found, whether it is safe, and what must change.
- BUG — a defect worth remembering after it is fixed, which means one whose class of mistake will recur. Its body has four sections: SYMPTOM, what was observed against what was expected, quoting the failing assertion; CAUSE, the actual mechanism rather than the first plausible story; WHY IT HID, what let this survive review or testing or both; and FIX. WHY IT HID is the section that earns the document — the fix lands in the code where anyone can see it, and the reason nobody noticed for a year lands nowhere at all unless it is written down. Carries severity:.
- CON — a recurring idea worth naming once, so that later documents cite it instead of re-deriving it.
- RULE — a constraint, with applies-to: naming what it binds, a severity: of error, warning or advisory saying how strictly it is enforced, and, where the constraint can be expressed mechanically, a check: clause that Loom executes against the graph on every indexing pass.

Two mistakes each cost a document its place in the index and are worth naming: an unindented block scalar, where content under summary: | starts at column zero and makes the rest of the file unparseable, leaving the document nameless; and a duplicated id, which is ambiguous to every reference that names it and for some types silently becomes one entity.

## Appendix G: Configuring a Document Store

### What a Document Store Must Provide

The document adapter protocol is small:

| API End point | Requirements |
| --- | --- |
| enumerate | every document, so a rebuild is always possible |
| read/write | one whole document |
| allocate-id | the next id of a given type |
| changed-since | what moved since a token --- a write time and a content hash, an ETag, an updated-since query, a commit |
| compare-and-swap | a write that fails when the document moved underneath it |
| may-transition | whether this actor may move this status, and the refusal when they may not |
| history | who changed a field, when, and why |
| locate | an address a human can open |

An adapter declares which of these it implements, and Loom degrades in named ways rather than silently. The default git model supports all of these capabilities.

### Branch-Aware Stores and Flat Stores

The capability that divides backends is not storage technology. It is whether the store carries branch-scoped revisions with merge semantics, which is what lets a document be edited alongside the code that implements it and land with it. Supporting that takes five things:

- a revision records the branch it was written on and the revision it derived from, so the history is a graph rather than a labelled log;
- promotion to the main line at merge is one atomic operation covering every document the branch touched, so there is no window in which half a branch’s edits are live;
- the join to code is a commit identifier rather than a timestamp — a rebase, a squash or a cherry-pick moves the clock without moving the content;
- two branches editing one document conflict against their merge base rather than resolving by last writer;
- an abandoned branch has a defined outcome, so revisions that never landed do not sit in the index looking real.

Git satisfies all five, which is why the file adapter is the default. A ticket tracker satisfies none of them: an issue has one state and a change log, and there is no revision scoped to a branch. A purpose-built Loom document service could satisfy all five, and would be a content-addressed revision store with merge-base semantics and an atomic promote.

A flat store is therefore not a compromise under the workflow this document describes. Doc on Main, Branch to Code already puts every document on the primary branch and lets only code travel on a branch, so nothing in the workflow asks a store to carry a document edit on a branch and merge it. What a flat store does change is the approval mechanism: the merge cannot be the approval when the document never left the main line, so the store’s own permission model enforces the transition instead, and Loom asks rather than asserts.

The five requirements above still matter for a store meant to support a workflow other than this one — an organization that decides a design should be revised on the branch that implements it. They are what such a store would have to provide.
