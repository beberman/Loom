;;;; The code taxonomy: every concrete entity and relationship type.
;;;; Implements the taxonomy named in Phase 1 Overview SSOntology and the
;;;; impact metadata specified in Software Architecture SS9.
;;;;
;;;; Everything here is declaration.  Adding a type is one DEFENTITY form; the
;;;; registry it populates is what the Graph Manager validates against, what
;;;; GET /ontology/schema serves, and what the MCP tool descriptions embed.

(in-package :loom-ontology)

;;;; ==================================================================
;;;; Shared vocabularies
;;;; ==================================================================

(defvar *source-languages* '(:lisp :typescript :python)
  "Languages the analyzers emit entities for, and the :LANGUAGE vocabulary
every code entity is validated against.  Phase 1 ships a reader-based Lisp
analyzer and a Tree-sitter TypeScript one; adding a language is a matter of
pushing its keyword here and writing the analyzer.")

;;;; ==================================================================
;;;; Workspace and history
;;;; ==================================================================

(defentity :workspace
  :documentation "An open working tree carrying its own overlay of
uncommitted edits.  Repository graphs hold committed state; a workspace holds
the delta, and a graph view composes base plus overlay with overlay winning."
  :natural-key (:root-path)
  :properties ((:root-path       string  :required t
                :documentation "Absolute path of the working tree.")
               (:repository-id   string)
               (:branch          string)
               (:base-version    integer :default 0
                :documentation "Version of the committed base graph.")
               (:overlay-version integer :default 0
                :documentation "Bumped by every applied transaction.")))

(defentity :snapshot
  :documentation "A named immutable position: base version plus overlay
version plus operation-log offset.  Cheap by construction -- three integers
and a timestamp, never a copy of the graph -- which is what lets a snapshot be
taken after every applied transaction."
  :properties ((:workspace-id      string  :required t)
               (:base-version      integer :required t)
               (:overlay-version   integer :required t)
               (:op-log-offset     integer :required t)
               (:taken-at          integer :default (get-universal-time))
               (:commit-boundary-p boolean :default nil
                :documentation "Survives retention thinning; intermediate
snapshots are dropped to one per commit when a workspace closes.")))

(defentity :repository
  :documentation "A Git repository.  Git metadata is attached to ontology
objects rather than defining them."
  :natural-key (:root-path)
  :properties ((:root-path      string :required t)
               (:remote-url     string)
               (:default-branch string :default "main")))

(defentity :branch
  :documentation "A Git branch.  Switching branches resets the overlay rather
than diffing it, accepting a re-analysis pass."
  :natural-key (:repository-id :name)
  :properties ((:repository-id string :required t)
               (:head-commit   string)))

(defentity :commit
  :documentation "A Git commit.  Distinct from a snapshot: commits are Git
history, snapshots are workspace history, and the system tracks both."
  :natural-key (:repository-id :sha)
  :properties ((:repository-id string  :required t)
               (:sha           string  :required t)
               (:author        string)
               (:message       string)
               (:committed-at  integer)))

;;;; ==================================================================
;;;; Code structure
;;;;
;;;; Every definition entity carries a file and a line range, because that is
;;;; what makes a graph answer actionable: an agent opens exactly the region a
;;;; fact came from instead of re-reading the file.
;;;; ==================================================================

(defentity :file
  :documentation "One source file on disk, and the unit the analyzer works
on: a pass over a file asserts this entity plus CONTAINS edges to every
definition found inside it."
  :natural-key (:path)
  :properties ((:path         string  :required t
                :documentation "Workspace-relative, forward-slashed.")
               (:language     keyword :one-of *source-languages*)
               (:line-count   integer)
               (:content-hash string
                :documentation "Digest of the analyzed contents.  An unchanged
hash is what lets re-analysis of an untouched file apply as a no-op.")
               (:analysis-failed-p boolean :default nil
                :documentation "SS9.3: set when the file could not be parsed.
The file is asserted anyway, because a known unknown is worth more to an agent
than an absence it cannot distinguish from an empty file.")
               (:analysis-error string
                :documentation "The condition text, when :ANALYSIS-FAILED-P.")
               (:definer-call-sites list
                :documentation "Every top-level form in this file whose
operator is neither a definition nor a declaration -- ARCH-0002 R2. One plist
per form: :OPERATOR, :START-LINE, :END-LINE, :ARGUMENTS as rendered strings,
:SYMBOL-ARGUMENTS naming which of those positions held a bare symbol, and
:CALL-NAMES pre-walked from the whole argument list.

Analyzer-written and never rewritten, the same discipline :CALL-NAMES has and
for the same DEC-0003 reason: RESOLVE-GENERATED-DEFINITIONS derives the
entities a definer macro brings into existence from this list on every pass,
so an entity destroyed by a retract comes back. The call names are pre-walked
here rather than left as a sexp because resolution reads properties and never
source, and it cannot know in advance which argument a macro's body starts
at.")))

(defentity :package
  :documentation "A namespace: a Lisp package, an npm package, a Python
package."
  :natural-key (:qualified-name)
  :properties ((:qualified-name string :required t)
               (:exports        list   :documentation "Exported symbol names.")
               (:language       keyword :one-of *source-languages*)))

(defentity :module
  :documentation "The logical unit definitions are grouped under -- a Lisp
package's file, an ES module.  Distinct from :file, which is the artifact on
disk: a module may span files, and a file need not declare one."
  :natural-key (:qualified-name)
  :properties ((:qualified-name string :required t)
               (:file           string)
               (:language       keyword :one-of *source-languages*)))

(defentity :class
  :documentation "A class definition."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer :required t)
               (:abstract-p boolean :default nil)
               (:slots      list    :documentation "Declared slot or field names.")
               (:superclass-names list
                :documentation "Names of the classes this one is declared to
extend.  Written by the analyzer and never rewritten, because a superclass may
live in another file: the :INHERITS edges are derived from this on every
resolution pass, per DEC-0003.")
               (:kind       keyword :one-of (:class :condition :struct)
                :documentation "Which defining form produced this.  A
defstruct is a class whose accessors are plain functions; a define-condition
is a class that is signalled rather than instantiated.  Worth telling apart
without reopening the file.")
               (:exported-p boolean :default nil)
               (:language   keyword :one-of *source-languages*)))

(defentity :interface
  :documentation "A contract without implementation: a TypeScript interface,
or a Lisp generic-function protocol treated as one."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer :required t)
               (:members    list)
               (:generated-by string
                :documentation "The class whose slot declared this, when the
name was generated rather than written.  A defclass :ACCESSOR/:READER/:WRITER
defines a generic function that appears nowhere else in the source; it is
indexed so calls to it resolve, and marked so an agent can tell a derived
name from one someone wrote.")
               (:exported-p boolean :default nil)
               (:language   keyword :one-of *source-languages*)))

(defentity :function
  :documentation "A named callable unit in source code."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer :required t)
               (:signature  string  :documentation "Rendered for display.")
               (:arguments  list    :documentation "Parsed parameter list.")
               (:exported-p boolean :default nil)
               (:generic-p  boolean :default nil
                :documentation "A CLOS generic function rather than a plain defun.")
               (:macro-p    boolean :default nil
                :documentation "A macro rather than a function.  Indexed so it
can be found and documented; what a :CALLS edge into one means is not settled.")
               (:generated-by string
                :documentation "The structure whose definition generated this
name, when it was generated rather than written -- a DEFSTRUCT accessor,
constructor, predicate or copier.  Unlike a DEFCLASS accessor, which is a
generic function and so an :INTERFACE, these really are plain functions.")
               (:language   keyword :one-of *source-languages*)
               (:call-names list
                :documentation "Every callee name the analyzer could not
resolve inside this one file.  Written by the analyzer and never rewritten
afterwards, which is what makes it the stable input cross-file resolution
re-derives from: retracting a file destroys the :CALLS edges that pointed into
it, and the only way the next resolution pass can rebuild them is if the
callers still record who they call.")
               (:unresolved-calls list
                :documentation "Callee names that did not resolve inside the
workspace.  Recorded as a property, never as a dangling edge.  Derived from
:CALL-NAMES on every resolution pass rather than accumulated, so it describes
the workspace as it stands rather than as it was when a name last resolved.")
               ;; What a DEFMACRO's template says a call to it defines
               ;; (ARCH-0002 R1).  Written once from the source text and never
               ;; rewritten, like :SUPERCLASS-NAMES: the decision about a call
               ;; site needs the whole workspace, which an analyzer does not
               ;; have, so the analyzer records the shape and
               ;; RESOLVE-GENERATED-DEFINITIONS acts on it.
               (:generator-entity-type keyword
                :documentation "The entity type a call to this macro defines,
when its template is a DEFUN, DEFCLASS or DEFMETHOD whose name position is a
bare substitution of one of the macro's own parameters.  Absent on a wrapper
macro, which claims to define nothing.")
               (:generator-name-index integer
                :documentation "Which element of a call to this macro supplies
the defined name, counting the operator as 0.  The only way to name the entity
without expanding the macro, which REQ-0003 rules out.")
               (:generator-body-index integer
                :documentation "Which element of a call to this macro begins
the body, counting the operator as 0.")
               (:definer-status keyword
                :documentation ":UNHANDLED when the template contains a
DEFUN, DEFCLASS or DEFMETHOD but the name position is not a bare substitution
-- a name built with INTERN or FORMAT cannot be read without running the code
that computes it.  Recorded and counted rather than guessed at, per CON-0001,
and reported by status the way an unresolved document reference is.")))

(defentity :method
  :documentation "A method on a class, or a CLOS method on a generic function."
  :natural-key (:file :name :qualifier :specializers)
  :properties ((:file             string  :required t)
               (:start-line       integer :required t)
               (:end-line         integer :required t)
               (:signature        string)
               (:arguments        list)
               (:qualifier        keyword
                :documentation "CLOS method qualifier -- :before, :after, :around.")
               (:specializers     list)
               (:generic-function string
                :documentation "Name of the generic function this method extends.")
               (:language         keyword :one-of *source-languages*)
               (:call-names       list)
               (:unresolved-calls list)))

(defentity :variable
  :documentation "A named binding: a constant, a special variable, a
module-level declaration."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer)
               (:kind       keyword :one-of (:constant :special :parameter :lexical))
               (:exported-p boolean :default nil)
               (:language   keyword :one-of *source-languages*)))

;;;; ==================================================================
;;;; Knowledge -- the part that cannot be recovered by re-reading source
;;;;
;;;; :CONCEPT and :ARCHITECTURE-DECISION deliberately declare no natural key,
;;;; as :SNAPSHOT does not.  A natural key exists so an analyzer re-deriving a
;;;; fact from source lands on the entity it made last time; knowledge that is
;;;; asserted once by a human or a planner is never re-derived, so its id is
;;;; its only identity and every assert of one is an insert.
;;;; ==================================================================

(defentity :test
  :documentation "A test.  TESTS edges to the units it exercises are derived
statically, never by running anything -- but from which static signal is a
question the type deliberately does not answer, because the better one differs
by language.

Lisp's RESOLVE-TESTS derives them from what the test's body actually :CALLS.
An earlier draft of this line said \"matched by import graph plus naming
convention\", and both halves turned out to be wrong for Lisp: fiveam names
tests in prose, so
RESOLVE-LINKS-A-CALL-TO-A-DEFINITION-IN-ANOTHER-FILE names no function
literally and a naming heuristic would resolve almost nothing, while a looser
one would fabricate; and the Lisp analyzer emits no :IMPORTS edges for an
import graph to be built from.  A JS/TS test typically imports its subject
rather than calling it locally, so an import-driven derivation is the right
one for that analyzer family and the wrong one here.  One edge type, fed by
whichever signal the language actually offers."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer :required t)
               (:suite      string)
               (:framework  keyword :one-of (:fiveam :vitest :jest :pytest))
               (:language   keyword :one-of *source-languages*)
               ;; A test is almost never written as its own form -- it is a
               ;; call to a framework macro -- so unlike every other definition
               ;; entity this one is usually minted by a resolution pass rather
               ;; than by an analyzer.  These three are what that costs and
               ;; what it buys (ARCH-0002 R5, R8).
               (:generated-by string
                :documentation "The macro whose call site brought this test
into existence.  Set by RESOLVE-GENERATED-DEFINITIONS, and the marker its
retract half keys on: an entity naming a registered macro that the current
computation no longer produces is one the pass has to take back.")
               (:call-names list
                :documentation "Every callee name found in the call site's
argument list.  Carried over verbatim from the file's :DEFINER-CALL-SITES
entry, so the same derive-never-consume discipline holds one level up: the
analyzer owns the record and resolution re-reads it every pass.")
               (:unresolved-calls list
                :documentation "Callee names that did not resolve inside the
workspace.  Expected to be populous for a test: a framework's assertion
operators -- fiveam's IS, SIGNALS, FINISHES -- are external by definition and
correctly stay here.")))

(defentity :document
  :documentation "Prose about the system: an architecture note, a README.
Read from a YAML file under docs/ whose subdirectory names no registered type
(SS10.1) -- such a file is indexed as a generic Document and reported, rather
than silently skipped, because \"a documentation directory that Loom is
quietly skipping is exactly the kind of thing that erodes trust in the
graph.\""
  :natural-key (:path)
  :properties ((:path   string :required t)
               (:doc-id string
                :documentation "The id: field.  How other documents name this
one, and what `describe REQ-0002' looks up.  Every workflow category -- arch,
requirements, plans, reviews, bugs -- is a :DOCUMENT, so this is what makes
the chain reachable by id rather than only by title.")
               (:title  string)
               (:summary string
                :documentation "The author's own one-paragraph statement of the
document, stored on its own as well as folded into :BODY.  Kept separately so a
reader can be given the paragraph the author wrote rather than the whole
concatenation -- :BODY answers \"what does it say\", this answers \"what is it
about\".")
               (:status keyword
                :one-of (:draft :proposed :accepted :final :superseded
                         :rejected :open :closed :implemented :partial)
                :documentation "Where the document is in its own life.  A plan
is draft until the work starts and final when it lands; a bug is open until it
is closed.  :IMPLEMENTED and :PARTIAL complete CON-0004's per-type vocabulary --
what RULE-0005 requires a plan reaching final to move the documents it refines
to -- and without them AS-KEYWORD dropped the status of every document that had
actually landed.")
               (:category string
                :documentation "The docs/ subdirectory the file was found in.")
               (:format keyword :one-of (:markdown :docx :org :text :yaml))
               (:body   string
                :documentation "The prose blocks, joined.  What an agent reads
when it wants the reasoning rather than the metadata.")
               (:refines list
                :documentation "The refines: field -- doc-ids of the documents
this one answers.  A design refines the requirement that asked for it, a plan
refines the design it sequences.  Resolved into :REFINES edges, which is what
makes the workflow a walkable chain rather than a naming convention.")
               (:mentions list
                :documentation "Entity names found in the prose.  Raw text
until the workspace resolves them (SS10.3); resolution turns each into an
:inferred edge and drops it from here.")
               (:unresolved-references list
                :documentation "Declared references that named nothing in the
index.  SS10.3: not dropped silently -- this is the documentation staleness
detector, and a decision naming a function that no longer exists is
detectably rotten.")
               (:analysis-error string
                :documentation "Set when the YAML would not parse.  The
document is indexed anyway, for the SS9.3 reason: a known unknown beats an
absence an agent cannot distinguish from an empty directory.")))

(defentity :rule-violation
  :documentation "One current breach of a rule's check clause (SS10.4):
\"Violations are asserted into the graph as entities, so an agent can ask what
the current tree violates and get an answer with the same query machinery as
everything else.\"

Derived from the tree rather than read from a file, so unlike every other
knowledge entity it is genuinely re-derivable and carries the rule document as
its origin -- reindexing rebuilds it, and a fixed violation simply stops being
asserted."
  :natural-key (:rule-id :subject)
  :properties ((:rule-id  string  :required t)
               (:subject  string  :required t
                :documentation "Id of the entity or relationship in breach.")
               (:severity keyword :one-of (:error :warning :advisory) :default :error)
               (:detail   string)))

(defentity :concept
  :documentation "A domain-aware architectural abstraction indexed as a
first-class entity rather than left as text -- a drawing lifecycle, a
separation between UI and interaction layers.  These are what let a planner
query architecture directly instead of rediscovering it from source.  Read
from docs/concepts (SS10.1)."
  :natural-key (:doc-id)
  :properties ((:doc-id   string :required t)
               (:title    string)
               (:summary  string)
               (:body     string)
               (:evidence list
                :documentation "Entity ids the concept was drawn from.  A
concept is usually :inferred, so this is what its DERIVED-FROM tracks.")
               (:refines list
                :documentation "The refines: field -- doc-ids of the documents
this one answers.  A design refines the requirement that asked for it, a plan
refines the design it sequences.  Resolved into :REFINES edges, which is what
makes the workflow a walkable chain rather than a naming convention.")
               (:mentions list)
               (:unresolved-references list)))

(defentity :decision
  :documentation "A recorded decision: what was chosen, why, and what it
touches.  Read from a YAML file under docs/design (SS10.1), which is what
makes it survive a restart -- SS2.1: \"anything Loom knows that is not
derivable from files must be written back to files, or it is not knowledge --
it is cache, and it will be lost without anyone noticing.\"  Written by an
agent through loom_record_decision, which writes the file and lets the
watcher index it like any other."
  :natural-key (:doc-id)
  :properties ((:doc-id        string :required t
                :documentation "The id: field of the YAML document, e.g. DEC-0042.")
               (:title         string)
               (:summary       string
                :documentation "The author's own one-paragraph statement of the
document, stored on its own as well as folded into :BODY.  Kept separately so a
reader can be given the paragraph the author wrote rather than the whole
concatenation -- :BODY answers \"what does it say\", this answers \"what is it
about\".")
               (:status        keyword
                :one-of (:proposed :accepted :superseded :rejected)
                :default :proposed)
               (:decision      string)
               (:rationale     string)
               (:consequences  string)
               (:tags          list)
               (:date          string
                :documentation "The date: field, verbatim.  Kept as written
rather than parsed: it is provenance for a human, not something to compute on.")
               (:body          string)
               (:affects       list
                :documentation "The affects: field -- names this decision
governs.  Raw text until the workspace resolves it into :DECIDES edges
(SS10.3); resolution removes what it linked and leaves the rest here.")
               (:supersedes    list
                :documentation "The supersedes: field -- doc-ids of decisions
this one replaces.")
               (:refines list
                :documentation "The refines: field -- doc-ids of the documents
this one answers.  A design refines the requirement that asked for it, a plan
refines the design it sequences.  Resolved into :REFINES edges, which is what
makes the workflow a walkable chain rather than a naming convention.")
               (:mentions      list)
               (:unresolved-references list)
               (:lessons       list
                :documentation "Learnings worth carrying forward -- the
\"avoid nested providers\" line of a decision record.")
               (:decided-at    integer :default (get-universal-time))
               (:superseded-by string
                :documentation "Doc-id of the decision that replaced this one.")))

(defentity :rule
  :documentation "A normative, checkable constraint, read from docs/rules
(SS10.2).  The point of the type is SS10.4: a rule's CHECK clause compiles to
the same query form as the architectural invariants of SS14.3, so \"the rule
is written where a human reads it and enforced from the same text\" -- one
statement serving the build, the reviewer, and loom_rules.

A rule whose constraint cannot be expressed as a check stays valid as prose
with severity :advisory.  It is not enforced, and the count of unenforced
rules is reported, so prose-only drift stays visible rather than comfortable."
  :natural-key (:doc-id)
  :properties ((:doc-id    string :required t)
               (:title     string)
               (:summary   string
                :documentation "The author's own one-paragraph statement of the
document, stored on its own as well as folded into :BODY.  Kept separately so a
reader can be given the paragraph the author wrote rather than the whole
concatenation -- :BODY answers \"what does it say\", this answers \"what is it
about\".")
               (:status    keyword :one-of (:active :retired) :default :active)
               (:severity  keyword :one-of (:error :warning :advisory)
                :default :error)
               (:statement string)
               (:body      string)
               (:applies-to list
                :documentation "Names this rule constrains.  Resolved into
:APPLIES-TO edges by the workspace, same as a decision's affects:.")
               (:refines list
                :documentation "The refines: field -- doc-ids of the documents
this one answers.  A design refines the requirement that asked for it, a plan
refines the design it sequences.  Resolved into :REFINES edges, which is what
makes the workflow a walkable chain rather than a naming convention.")
               (:mentions   list)
               (:unresolved-references list)
               (:check     list
                :documentation "The compiled check clause, or NIL when the
rule is advisory prose.  A plist: :kind plus the keys that kind needs.")))

;;;; ==================================================================
;;;; Relationships
;;;;
;;;; TRANSITIVE-IMPACT and IMPACT-DIRECTION are read directly by the impact
;;;; engine, so this block is the executable form of the SS9 table.  Impact
;;;; flows against the direction of dependency, which is why most types are
;;;; :reverse -- from the thing that changed to the things that relied on it.
;;;; ==================================================================

(defrelationship :calls
  :from (:function :method :test) :to (:function :method :interface)
  :transitive-impact t :impact-direction :reverse
  :documentation "The core propagation edge: a callee change reaches its callers.

:INTERFACE is a permitted target but not the usual one, and the distinction
matters. ARCH-0001 rejected routing dispatched calls through the generic --
they fan out to the candidate methods instead -- so an edge lands here only
when a protocol has no implementation in the workspace to fan out to: a
DEFCLASS slot accessor, which is a generic function generated from a slot and
never specialised again, or a DEFGENERIC whose methods live outside the
indexed tree. Permitting the endpoint is what keeps those callable; it does
not make the generic a hub.")

(defrelationship :depends-on
  :from (:module :package :file) :to (:module :package :file)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation.")

(defrelationship :imports
  :from (:file :module) :to (:file :module :package)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation.")

(defrelationship :uses
  :from (:function :method :class :module :interface :test)
  :to   (:variable :class :interface :function)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation, and the edge from a generated
definition back to whatever generated it.

The second use is ARCH-0002's, and it is why :INTERFACE and :TEST originate
here and :FUNCTION terminates here. A DEFCLASS slot accessor is an :INTERFACE
and has to reach its class; a macro-generated test is a :TEST and has to reach
the macro, which is a :FUNCTION carrying :MACRO-P. Widening rather than adding
a :GENERATES type, for the reason ARCH-0001 gave for not adding :SPECIALIZES:
no consumer needs to tell the two apart to get the right answer, because both
want impact to flow from the generator to the generated, which this type's
:REVERSE direction already gives. What distinguishes a derived name from a
written one is :GENERATED-BY on the entity, and repeating it in the edge type
would answer a question nobody asks of the edge.")

;;; TODO: closures (JS/TS arrow functions, hooks) currently fall back to plain
;;; :function + :uses edges to captured variables, with no way to distinguish
;;; "closes over" from "merely references via a call." Revisit before the
;;; TypeScript analyzer lands -- may want a dedicated captured-variables
;;; property or edge so the impact engine can reason about stale-closure /
;;; missing-dependency bugs specifically, rather than generic :uses.

(defrelationship :inherits
  :from (:class) :to (:class)
  :transitive-impact t :impact-direction :reverse
  :documentation "Contract changes propagate down to subclasses.")

(defrelationship :implements
  :from (:class :function :method) :to (:interface)
  :transitive-impact t :impact-direction :reverse
  :documentation "Contract changes propagate down to implementors.")

(defrelationship :contains
  :from (:repository :workspace :package :module :file :class)
  :to (:file :module :class :interface :function :method :variable :test)
  :transitive-impact nil :impact-direction :reverse
  :documentation "One step only: a changed function marks its file, not the world.")

(defrelationship :belongs-to
  :from (:file :module :class :interface :function :method :variable :test)
  :to (:repository :workspace :package :module :file :class)
  :transitive-impact nil :impact-direction :forward
  :documentation "The inverse of CONTAINS.  Impact still runs member to
container, which is along this edge rather than against it.")

(defrelationship :tests
  :from (:test) :to (:function :method :class :module :file :interface)
  :transitive-impact nil :impact-direction :reverse :collect-as :tests
  :documentation "One step, applied at the end of traversal and gathered into
a distinct tests field rather than mixed into the impact set.")

(defrelationship :documents
  :from (:document :decision :rule :concept)
  :to (:function :method :class :interface :module :package :file :concept :test)
  :transitive-impact nil :impact-direction :reverse :collect-as :documents
  :documentation "One step, applied at the end, gathered into a distinct
documents field.

:TEST joined the list the moment ARCH-0002 gave the type its first facts, and
it is the same oversight the :DECIDES comment above records, found the same
way. A fiveam test name is prose -- reindexing-produces-an-identical-index --
so a document discussing that test mentions it by name, RESOLVE-DOCUMENT-LINKS
resolves the mention, and one illegal endpoint rejected the whole transaction
rather than one edge. Nothing noticed while the :TEST type held no facts,
because no mention could resolve to one.")

;;; SS11's table pairs DECIDES with DOCUMENTS: "One step, at the end --
;;; Impacted unit -> documents -- Decisions, rules, and notes that reference
;;; it."  Impact therefore runs from the changed unit back to the decision, and
;;; the edge runs decision -> unit, so impact travels against it: :REVERSE.
;;;
;;; SS5.3's illustrative declaration writes :impact-direction :forward, which
;;; would send impact from a decision out to the code it governs -- the
;;; opposite traversal, and one that would put nothing in the decisions field
;;; of an impact report.  SS11 is the normative impact specification and the
;;; table is what the engine implements, so :REVERSE is used here.  Worth
;;; reconciling in the document.
;;; :INTERFACE is a legal target for both of the documentation links below,
;;; and its absence was an oversight rather than a judgement: :DOCUMENTS has
;;; always permitted it, and a decision that governs a protocol is the most
;;; ordinary thing a decision can do. Nothing noticed until the Lisp analyzer
;;; learned DEFGENERIC, at which point DEC-0002's affects: [id-derived-p] and
;;; RULE-0002's applies-to: [analyze-file, analyzer-handles-p] all began
;;; resolving to interfaces and rejecting the whole resolution transaction.

(defrelationship :decides
  :from (:decision)
  :to (:module :class :interface :function :method :file :package)
  :transitive-impact nil :impact-direction :reverse :collect-as :decisions
  :documentation "What a recorded decision governs.  Declared by the
affects: field of a decision document (SS10.3), resolved against the entity
index, and collected separately from the impact set so the decisions bearing
on a change reach the agent without inflating the impact count.")

(defrelationship :applies-to
  :from (:rule)
  :to (:module :class :interface :function :method :file :package)
  :transitive-impact nil :impact-direction :reverse :collect-as :rules
  :documentation "What a rule constrains.  Gathered into its own field so
loom_rules can answer \"what must I not break here\" without an agent having
to filter decisions for the normative ones.")

(defrelationship :refines
  :from (:document :decision :rule :concept)
  :to   (:document :decision :rule :concept)
  :transitive-impact t :impact-direction :reverse
  :documentation "One document answering another: a design refines the
requirement that asked for it, a plan refines the design it sequences, a bug
report refines the plan whose work produced it.

Declared by a refines: field and resolved against doc-ids, so the chain a piece
of work travelled is walkable in both directions -- from a requirement forward
to everything that came of it, and from a plan back to the requirement that
justifies it. Transitive rather than gathered into its own field, because the
chain is the point: a changed requirement has to reach the plan two hops away,
not just the design one hop away.")

(defrelationship :supersedes
  :from (:decision) :to (:decision)
  :transitive-impact nil :impact-direction :reverse
  :documentation "The supersedes: field of a decision document.  Kept as an
edge rather than only a property so the chain is walkable in both directions:
an agent handed a decision needs to know whether something later replaced it.")
