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
                :documentation "The condition text, when :ANALYSIS-FAILED-P.")))

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
               (:language   keyword :one-of *source-languages*)
               (:unresolved-calls list
                :documentation "Callee names that did not resolve inside the
workspace.  Recorded as a property, never as a dangling edge.")))

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
  :documentation "A test.  TESTS edges to the units it exercises are matched
by import graph plus naming convention, not by execution."
  :natural-key (:file :name)
  :properties ((:file       string  :required t)
               (:start-line integer :required t)
               (:end-line   integer :required t)
               (:suite      string)
               (:framework  keyword :one-of (:fiveam :vitest :jest :pytest))
               (:language   keyword :one-of *source-languages*)))

(defentity :document
  :documentation "Prose about the system: an architecture note, a README.
Read from a YAML file under docs/ whose subdirectory names no registered type
(SS10.1) -- such a file is indexed as a generic Document and reported, rather
than silently skipped, because \"a documentation directory that Loom is
quietly skipping is exactly the kind of thing that erodes trust in the
graph.\""
  :natural-key (:path)
  :properties ((:path   string :required t)
               (:title  string)
               (:category string
                :documentation "The docs/ subdirectory the file was found in.")
               (:format keyword :one-of (:markdown :docx :org :text :yaml))
               (:body   string
                :documentation "The prose blocks, joined.  What an agent reads
when it wants the reasoning rather than the metadata.")
               (:mentions list
                :documentation "Entity names found in the prose.  Raw text
until the workspace resolves them (SS10.3); resolution turns each into an
:inferred edge and drops it from here.")
               (:unresolved-references list
                :documentation "Declared references that named nothing in the
index.  SS10.3: not dropped silently -- this is the documentation staleness
detector, and a decision naming a function that no longer exists is
detectably rotten.")))

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
               (:status    keyword :one-of (:active :retired) :default :active)
               (:severity  keyword :one-of (:error :warning :advisory)
                :default :error)
               (:statement string)
               (:body      string)
               (:applies-to list
                :documentation "Names this rule constrains.  Resolved into
:APPLIES-TO edges by the workspace, same as a decision's affects:.")
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
  :from (:function :method :test) :to (:function :method)
  :transitive-impact t :impact-direction :reverse
  :documentation "The core propagation edge: a callee change reaches its callers.")

(defrelationship :depends-on
  :from (:module :package :file) :to (:module :package :file)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation.")

(defrelationship :imports
  :from (:file :module) :to (:file :module :package)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation.")

(defrelationship :uses
  :from (:function :method :class :module) :to (:variable :class :interface)
  :transitive-impact t :impact-direction :reverse
  :documentation "Module-level propagation.")

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
  :from (:test) :to (:function :method :class :module :file)
  :transitive-impact nil :impact-direction :reverse :collect-as :tests
  :documentation "One step, applied at the end of traversal and gathered into
a distinct tests field rather than mixed into the impact set.")

(defrelationship :documents
  :from (:document :decision :rule :concept)
  :to (:function :method :class :interface :module :package :file :concept)
  :transitive-impact nil :impact-direction :reverse :collect-as :documents
  :documentation "One step, applied at the end, gathered into a distinct
documents field.")

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
(defrelationship :decides
  :from (:decision) :to (:module :class :function :method :file :package)
  :transitive-impact nil :impact-direction :reverse :collect-as :decisions
  :documentation "What a recorded decision governs.  Declared by the
affects: field of a decision document (SS10.3), resolved against the entity
index, and collected separately from the impact set so the decisions bearing
on a change reach the agent without inflating the impact count.")

(defrelationship :applies-to
  :from (:rule) :to (:module :class :function :method :file :package)
  :transitive-impact nil :impact-direction :reverse :collect-as :rules
  :documentation "What a rule constrains.  Gathered into its own field so
loom_rules can answer \"what must I not break here\" without an agent having
to filter decisions for the normative ones.")

(defrelationship :supersedes
  :from (:decision) :to (:decision)
  :transitive-impact nil :impact-direction :reverse
  :documentation "The supersedes: field of a decision document.  Kept as an
edge rather than only a property so the chain is walkable in both directions:
an agent handed a decision needs to know whether something later replaced it.")
