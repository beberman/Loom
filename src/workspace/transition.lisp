;;;; Document state transitions -- the write path of REQ-0022, shaped by
;;;; DES-0019.
;;;;
;;;; Loom had never written a document before this file. Everything above it
;;;; reads: an analyzer turns a file into operations, the graph stores them, and
;;;; loom-knowledge answers questions about what is stored. The one thing the
;;;; workflow asked a human to do by hand -- move a document out of draft when
;;;; the plan that implemented it lands -- was a rule (RULE-0005) that could
;;;; never be checked, because `check' inspects a state and the rule describes a
;;;; transition. There is no snapshot in which "a plan reached final and did not
;;;; restate what it implemented" is visible: by the time anything looks, the
;;;; only evidence is a document whose status is now false, which is
;;;; indistinguishable from one nobody has finished yet.
;;;;
;;;; So the transition is performed instead of remembered, and this is where it
;;;; is performed. Four properties carry the whole design:
;;;;
;;;;   The edit is one line, found by a rule that cannot be wrong. A block
;;;;   scalar's content must be indented past the key that introduces it and
;;;;   every top-level key sits at column zero, so the first line beginning
;;;;   `status:' with no leading whitespace *is* the top-level key. A `status:'
;;;;   written in prose -- and the documents in this tree are full of them -- is
;;;;   indented and invisible to the scan. Everything else in the file is copied
;;;;   through byte for byte: no YAML round-trip, because reserialising from the
;;;;   graph would destroy key order, block scalars, comments and every field
;;;;   the ontology does not model.
;;;;
;;;;   The verdict comes from the caller. Whether a plan *fully* implemented
;;;;   what it refines is a judgement about intent, not a fact in the graph, and
;;;;   a command that guessed `implemented' would be writing a false claim into
;;;;   a file and then indexing it -- CON-0001's fabricated fact with a commit
;;;;   behind it.
;;;;
;;;;   The propagation query is the part a person will not run. A document may
;;;;   leave draft only if no *other* unfinished plan also refines it. That is
;;;;   one graph query and it is exactly what someone closing a long change does
;;;;   not think to do.
;;;;
;;;;   It plans before it applies. A filesystem is not transactional, so
;;;;   everything is resolved, read, located, validated and probed before one
;;;;   byte is written -- APPLY-TRANSACTION's discipline, applied to files.
;;;;
;;;; It lives in loom-workspace because it writes files and then reindexes,
;;;; which is this system's existing job: loom-knowledge is read-only by
;;;; RULE-0003 and an analyzer may not touch the tree at all.

(in-package :loom-workspace)

;;;; ==================================================================
;;;; CON-0004's vocabulary, per category (DES-0019 D3)
;;;; ==================================================================

(defparameter *workflow-status-vocabulary*
  '(("requirements" (:draft :accepted :implemented :partial)             (:implemented))
    ("design"       (:draft :accepted :implemented :partial :superseded) (:implemented :superseded))
    ("plans"        (:draft :final)                                      (:final))
    ("bugs"         (:open :closed)                                      (:closed))
    ("reviews"      (:open :closed)                                      (:closed))
    ("arch"         (:draft :accepted :superseded)                       ())
    ("decisions"    (:proposed :accepted :superseded :rejected)          ())
    ("rules"        (:active :retired)                                   ()))
  "Document category -> (allowed statuses, terminal statuses).

Per category and not per entity type, which is the whole reason this table
exists rather than the ontology being read alone. Four of CON-0004's nine
categories -- requirements, plans, reviews, bugs -- all land on the :DOCUMENT
entity type, whose declared :ONE-OF is the union of their four vocabularies.
Validating against that union alone would let a plan be set to `closed' and a
bug to `final', which is not a status the workflow has.

The terminal column means finished, and a document is finished when there is no
work left in it: implemented for a REQ or a DES, final for a PLAN, closed for a
BUG or REV, and `superseded' for a DES. A partial document stays flat, because
it has an OUTSTANDING section, which is work.

`superseded' was not terminal until 2026-08-23, and the reason it was not is
worth keeping: RULE-0007's text named one word, and departing from it in code
would have put this table and the document a human reads into disagreement.
That was a reason to change both together rather than a reason to leave a
finished design filed as though it were open. DES-0034 and DES-0036 are what
forced it -- both were built, measured, and withdrawn, and both sat flat in
docs/design/ offering themselves to `context' as work in progress. The rule
text now says superseded too.

The last three categories have no terminal status at all and therefore no
completed/ subdirectory. An accepted decision, an active rule and a current
architecture document are in force rather than finished, and filing them under a
name meaning \"done with these\" would bury exactly the documents `impact'
exists to surface.

Concepts are absent on purpose and their absence is not what refuses them:
:CONCEPT declares no :STATUS property at all, so DOCUMENT-STATUS-VOCABULARY
refuses one before it ever consults this table.")

(defun category-vocabulary (category)
  "Two values: the statuses CATEGORY allows and the ones that are terminal.
The second value is NIL for a category with no completed/ subdirectory, which
is also what an unregistered category returns."
  (let ((entry (assoc category *workflow-status-vocabulary* :test #'string-equal)))
    (values (second entry) (third entry))))

(defun terminal-category-status-p (category status)
  "True when STATUS finishes a document filed under CATEGORY.

The terminal column above, in the form a document store takes: a store has an
address and reads a category out of it, and has no entity to consult. The
entity form beside it is TERMINAL-STATUS-P, which the walk uses."
  (multiple-value-bind (allowed terminal) (category-vocabulary category)
    (declare (ignore allowed))
    (and (member status terminal) t)))

(setf *terminal-status-p* #'terminal-category-status-p)

(defun document-status-vocabulary (entity)
  "Two values for ENTITY: the statuses it may take, and the terminal ones.

NIL for the first when the entity's type declares no :STATUS property, which is
DES-0019 D3's refusal: four concepts in this tree carry no status line and
:CONCEPT has nowhere to put one, so inserting a line would write a fact the
index cannot hold.

The category narrows the ontology rather than replacing it. Where a category is
registered above, the answer is the intersection -- so a plan gets two statuses
out of :DOCUMENT's ten, and a status the ontology would refuse cannot be smuggled
in by a table entry. Where it is not, the ontology's declaration stands alone,
which is the honest answer for a document filed somewhere the workflow does not
name."
  (let ((declared (let ((spec (find-property (entity-type entity) :status)))
                    (and spec (property-one-of spec)))))
    (if (null declared)
        (values nil nil)
        (multiple-value-bind (allowed terminal)
            (category-vocabulary (getp entity :category))
          (if allowed
              (values (remove-if-not (lambda (s) (member s declared)) allowed)
                      terminal)
              (values declared nil))))))

(defun terminal-status-p (entity status)
  "True when STATUS means ENTITY's document is finished and belongs in completed/."
  (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
    (declare (ignore allowed))
    (and (member status terminal) t)))

;;;; ==================================================================
;;;; Finding the document (DES-0019 D4)
;;;; ==================================================================

(defun document-entity-p (entity)
  (member (entity-type entity) *document-types*))

(defun documents-named (graph designator)
  "Every document entity DESIGNATOR could mean, matched on doc-id then on name.

Two passes rather than one index, because a doc-id match is what a caller
almost always means and a name match is the fallback for a document that has no
id. Returning the whole set rather than the best of it is CON-0001: two files
carrying one id is a real state this tree can reach -- an id-keyed type absorbs
them into one entity, a path-keyed type keeps two -- and picking one of them
before editing a file would be the worst possible moment to guess."
  (flet ((collect (test)
           (loop for type in *document-types*
                 append (remove-if-not test (entities-of-type graph type)))))
    (or (collect (lambda (e) (let ((id (getp e :doc-id)))
                               (and id (string-equal id designator)))))
        (collect (lambda (e) (and (slot-boundp e 'name)
                                  (string-equal (name e) designator)))))))

(defun document-category-of (entity)
  "The docs/ subdirectory ENTITY was read from, or NIL.
:CATEGORY for the types that declare it, and the path for the ones that do not
-- :DECISION, :RULE and :CONCEPT carry no such property, and a transition that
could not name a decision's category could not validate its status."
  (or (getp entity :category)
      (let ((file (origin-file entity)))
        (and file (document-category file)))))

(defun document-store-entry (repository entity)
  "Two values: the store ref for ENTITY's document and the address it is at.
NIL when the index does not hold one.

ORIGIN-FILE rather than a :PATH property, because only :DOCUMENT declares one:
the id-keyed types are deliberately findable after their file moves, and the
origin is the one place every document type records where it came from. That
origin is the store address, and DOCUMENTS maps it to the ref the store knows
it by -- which on the file store is the same string and on another store is
not (DES-0051 D1). This replaced DOCUMENT-FILE, which merged the origin with
the repository root and handed back a path to open."
  (let ((address (origin-file entity)))
    (when address
      (let ((entry (indexed-document repository address)))
        (when entry (values (car entry) address))))))

;;;; ==================================================================
;;;; Plan, then apply (D6)
;;;; ==================================================================

(defstruct (document-edit (:conc-name edit-))
  "One document's whole transition, computed before anything is written.

Since DES-0051 the workspace neither edits the text nor works out where the
file goes. It carries the ref the store knows the document by, the version it
read, and the two statuses; DOCSTORE-TRANSITION does the rest and says in its
returned record where the document ended up."
  (doc-id "")
  (category nil)
  (ref nil)             ; the store's ref for the document, read at plan time
  (address nil)         ; the address it was at then
  (version nil)         ; the version read, which the write is conditional on
  (from nil)            ; the status the document currently declares
  (to nil)              ; the status it will declare
  (blocked-by '()))     ; doc-ids of unfinished plans still refining this one

(defun edit-changes-p (edit)
  "True when EDIT sets a status the document does not already declare.

What it is not is a prediction of whether the store will write. A document
already declaring its target status may still be filed in the wrong directory,
and the store moves it -- so every planned edit is sent, and APPLY-TRANSITION
reports what actually changed from the records that come back. This answers
only the question a report row asks: is the caller setting something?"
  (not (eq (edit-from edit) (edit-to edit))))

(defun plan-document-edit (repository entity status)
  "Two values: the DOCUMENT-EDIT setting ENTITY's status to STATUS, and a list
of problems. One or the other is always NIL.

Everything that can refuse happens here and nothing here writes. The order is
cheapest-first only incidentally; what matters is that every problem is
collected rather than the first one signalled, because an agent that has to run
a command five times to discover five problems will stop reading the fifth."
  (let* ((doc-id (or (getp entity :doc-id) (and (slot-boundp entity 'name) (name entity))))
         (category (document-category-of entity))
         (problems '()))
    (flet ((refuse (format &rest arguments)
             (push (format nil "~a: ~?" doc-id format arguments) problems)))
      (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
        (declare (ignore terminal))
        (when (null allowed)
          ;; Returned rather than collected with the rest, because every check
          ;; below it is downstream of a status field existing: a concept has no
          ;; top-level status line either, and reporting that second fact would
          ;; describe the same absence twice and bury the one a reader can act
          ;; on.
          (refuse "~(~a~) documents have no status field, so there is nothing to set."
                  (entity-type entity))
          (return-from plan-document-edit (values nil (nreverse problems))))
        (unless (member status allowed)
          (refuse "~(~a~) is not a status a ~a document takes. Try: ~{~(~a~)~^, ~}"
                  status (or category (string-downcase (entity-type entity)))
                  allowed))
        (multiple-value-bind (ref address) (document-store-entry repository entity)
          (cond
            ((null ref) (refuse "the index does not record which file it came from."))
            (t
             (multiple-value-bind (contents version)
                 (handler-case (docstore-read (repository-document-store repository) ref)
                   (error (condition)
                     (refuse "~a cannot be read: ~a" address condition)
                     (values nil nil)))
               (when contents
                 (let ((current (nth-value 2 (top-level-status-line contents))))
                   (when (and allowed current (not (member current allowed)))
                     ;; BUG-0019's shape: `status: fixed', dropped to NIL by
                     ;; AS-KEYWORD, so the index held no status while the file
                     ;; held a word. A document in an unknown state is exactly
                     ;; where a human should look, so it is reported rather
                     ;; than silently overwritten.
                     (refuse "the file declares ~(~a~), which is not a status this ~
document takes; fix it by hand first." current))
                   ;; A document with no top-level status line reaches the store
                   ;; with CURRENT NIL and is refused there, in the one place
                   ;; that can also refuse a taken destination or a file it
                   ;; cannot write. Everything above is CON-0004's vocabulary,
                   ;; which is the workspace's and no store's (DES-0051 D2).
                   (unless problems
                     (return-from plan-document-edit
                       (values (make-document-edit
                                :doc-id doc-id
                                :category category
                                :ref ref
                                :address address
                                ;; The version read here and not the one
                                ;; indexed. A developer who saves an edit the
                                ;; monitor has not seen yet gets the status
                                ;; line written into the text they saved;
                                ;; comparing against the indexed version would
                                ;; refuse that, which is the case DEC-0001
                                ;; settles in the file's favour.
                                :version version
                                :from current
                                :to status)
                               nil))))))))))
      (values nil (nreverse problems)))))

(defun change-report (repository edit record)
  "The report plist for EDIT, given the RECORD the store returned.

:FILE is the address merged with the repository root, which is the string this
report has always carried and what the console prints for a person to open.
DOCSTORE-LOCATE is the protocol's answer to that question and arrives in step
9; on the file store the two agree."
  (let ((address (docstore-record-address record)))
    (list :doc-id (edit-doc-id edit)
          :from (edit-from edit)
          :to (edit-to edit)
          :file (namestring (merge-pathnames address (repository-root repository)))
          :moved (not (string= address (edit-address edit))))))

(defun store-changed-p (edit record)
  "True when the store actually changed the document EDIT named.

The address moved, or the version did. Neither is the workspace guessing: both
come off the record the store returned. A transition to the status a document
already declares, with the file already where that status puts it, writes
nothing and reads as no change here -- which is R7's empty :CHANGED and the
reason `set-status' twice shows one diff rather than two."
  (or (not (string= (docstore-record-address record) (edit-address edit)))
      (not (equalp (docstore-record-version record) (edit-version edit)))))

(defun apply-transition (repository edits &key reindex)
  "Apply every EDIT through the document store. Two values: the change reports
and the problems.

One DOCSTORE-APPLY-BATCH for the whole command, which is DES-0051 D4: the store
plans every entry and refuses all of them together, so nothing is written while
any entry is refused. That is the property APPLY-DOCUMENT-EDIT's plan-then-apply
split had within `complete\' and every caller now has.

A file store is :PLANNED, so a failure once writing has begun leaves the tree
part-way and returns the records that landed. Those are reported as changes
beside the problem that stopped it, and re-running the same command finishes the
rest -- a document already at its target status plans to a no-op.

REINDEX-REPOSITORY rather than a poll, and RULE-0007 records why: a :DOCUMENT\'s
natural key is (:PATH), so a move changes its id and therefore every edge
endpoint, and INDEX-REPOSITORY does not retract what is no longer on disk. The
cheaper call would leave the old path in the index beside the new one and every
reference to it ambiguous."
  (multiple-value-bind (records problems)
      (docstore-apply-batch
       (repository-document-store repository)
       (mapcar (lambda (edit)
                 (list :transition (edit-ref edit) (edit-to edit)
                       :expected-version (edit-version edit)))
               edits))
    (let ((changed (loop for edit in edits
                         for record in records
                         when (store-changed-p edit record)
                           collect (change-report repository edit record))))
      (when (and reindex (some (lambda (report) (getf report :moved)) changed))
        (reindex-repository repository :quiet t))
      (values changed problems))))

;;;; ==================================================================
;;;; set-status: the primitive
;;;; ==================================================================

(defun resolve-document (repository designator)
  "Two values: the one document DESIGNATOR names, and a list of problems."
  (let ((found (documents-named (repository-graph repository) designator)))
    (cond ((null found)
           (values nil (list (format nil "No document in ~a is named ~a."
                                     (repository-name repository) designator))))
          ((rest found)
           (values nil (list (format nil "~d documents are named ~a: ~{~a~^, ~}. ~
Two files carrying one id is a defect worth fixing before anything is written."
                                     (length found) designator
                                     (mapcar (lambda (e) (or (origin-file e) (id e)))
                                             found)))))
          (t (values (first found) nil)))))

(defun as-status (value)
  "VALUE as a status keyword, whatever a console token or a JSON string gave us."
  (typecase value
    (null nil)
    (keyword value)
    (string (let ((text (string-trim '(#\Space #\Tab) value)))
              (when (plusp (length text)) (intern (string-upcase text) :keyword))))
    (t (intern (string-upcase (princ-to-string value)) :keyword))))

(defun set-document-status (repository designator status &key (reindex t))
  "Set one document's status, move its file if the new status is terminal, and
reindex. Returns a report plist; :PROBLEMS non-empty means nothing was written.

The primitive DES-0019 D1 asks for, wanted in its own right -- accepting a
requirement, closing a bug, retiring a rule -- and the single write path
COMPLETE-PLAN is built from, so there is one of these to get right rather than
two.

Deliberately without the propagation query COMPLETE-PLAN runs. This is the way
to say \"I know what I am doing\" about one document, and files are truth: a
developer with an editor can always do the same thing, so a primitive that
refused would only be telling them to use the editor."
  (let ((repository (if (repository-p repository)
                        repository
                        (or (find-repository repository)
                            (return-from set-document-status
                              (list :problems (list (format nil "No repository named ~a."
                                                            repository))))))))
    (with-repository-lock (repository)
      (let ((status (as-status status)))
        (multiple-value-bind (entity problems) (resolve-document repository designator)
          (when problems
            (return-from set-document-status
              (list :repository (repository-name repository)
                    :document designator :problems problems :changed '())))
          (multiple-value-bind (edit edit-problems) (plan-document-edit repository entity status)
            (if edit-problems
                (list :repository (repository-name repository)
                      :document (or (getp entity :doc-id) designator)
                      :problems edit-problems :changed '())
                (multiple-value-bind (changed apply-problems)
                    (apply-transition repository (list edit) :reindex reindex)
                  (list :repository (repository-name repository)
                        :document (edit-doc-id edit)
                        :problems apply-problems
                        :changed changed
                        :status (edit-to edit)
                        ;; From the change when there was one, and from where
                        ;; the document already was when there was not. The
                        ;; store is the only thing that knows either.
                        :file (if changed
                                  (getf (first changed) :file)
                                  (namestring (merge-pathnames
                                               (edit-address edit)
                                               (repository-root repository)))))))))))))

;;;; ==================================================================
;;;; The propagation query (D4)
;;;; ==================================================================

(defparameter *plan-category* "plans"
  "The document category whose completion drives the cascade.

A plan is identified by its :CATEGORY -- a fact the indexer recorded from the
directory -- rather than by a PLAN- prefix on its id. The prefix is a naming
convention this tree happens to use; the category is what a foreign tree
prepared by REQ-0021 will also have.")

(defun plan-document-p (entity)
  (string-equal *plan-category* (or (document-category-of entity) "")))

(defun refines-targets (graph document)
  "The documents DOCUMENT refines -- its outgoing :REFINES edges.
CON-0004's chain read upward: a design refines the requirement that asked for
it, a plan refines the design it sequences."
  (loop for neighbor in (neighbors graph (id document) :rel-types '(:refines)
                                                       :direction :out)
        for entity = (neighbor-entity neighbor)
        when (document-entity-p entity)
          collect entity))

(defun finishable-p (entity)
  "True when ENTITY's category has a terminal status at all.

False for a decision, a rule, an architecture document and a concept, and that
is what stops them blocking anything. Those are *in force* rather than
outstanding: an active rule refining a concept is not unfinished work holding
the concept open, and treating it as one would make every such parent
permanently blocked by documents that are behaving correctly."
  (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
    (and allowed terminal t)))

(defun document-blockers (graph document settled)
  "Doc-ids of the unfinished documents still refining DOCUMENT, SETTLED aside.

This is the query REQ-0022 was written for and the strongest argument for
building the command rather than restating the rule. A document may leave draft
only if no *other* unfinished work still refines it. Loom knows that -- the
edges are in the graph and the statuses are properties -- and a human closing a
plan at the end of a long change does not, and will not check.

Every refining document counts, not only plans, which is RULE-0005 read whole:
\"If any sibling is still open -- another architecture, an unfixed bug, an
unanswered review -- the parent stays where it is. Marking a requirement
implemented while a bug refining it is still open is the same false claim in the
other direction.\"

SETTLED is what this cascade is in the act of finishing, the plan included. Its
members are not blockers because their unfinished state is precisely what is
being ended; without it the plan would block every document it refines and the
command could never do anything."
  (loop for neighbor in (neighbors graph (id document) :rel-types '(:refines)
                                                       :direction :in)
        for other = (neighbor-entity neighbor)
        when (and (document-entity-p other)
                  (not (member other settled))
                  (finishable-p other)
                  (not (terminal-status-p other (getp other :status))))
          collect (or (getp other :doc-id) (name other))))

;;;; ==================================================================
;;;; complete: the cascade
;;;; ==================================================================

(defun parse-verdicts (spec)
  "Two values: SPEC as an alist of (document . status), and a list of problems.

SPEC is `DES-0019=implemented REQ-0022=implemented' -- one string, whether it
arrived as console tokens, a REST query parameter or an MCP argument, because
all three can carry a string and only one of them can carry an object. A list of
tokens is accepted too, which is what the console has after splitting its line."
  (let ((tokens (etypecase spec
                  (null '())
                  (string (let ((words '()) (current (make-string-output-stream)))
                            (flet ((finish ()
                                     (let ((word (get-output-stream-string current)))
                                       (when (plusp (length word)) (push word words)))))
                              (loop for character across spec
                                    do (if (whitespace-char-p character)
                                           (finish)
                                           (write-char character current))
                                    finally (finish)))
                            (nreverse words)))
                  (cons spec)))
        (verdicts '())
        (problems '()))
    (dolist (token tokens)
      (let ((equals (position #\= token)))
        (cond ((or (null equals) (zerop equals) (= equals (1- (length token))))
               (push (format nil "~s is not a verdict. Write it as DOC-ID=status." token)
                     problems))
              (t (push (cons (subseq token 0 equals)
                             (as-status (subseq token (1+ equals))))
                       verdicts)))))
    (values (nreverse verdicts) (nreverse problems))))

(defun complete-plan (repository designator &key verdicts (reindex t) force-write)
  "Set a plan final and restate every document it implements. Returns a report.

REQ-0022 R1, and the one command that replaces RULE-0005. With no VERDICTS it
writes nothing and reports what it would do: which documents the plan refines,
what each currently says, which are still blocked by another unfinished plan,
and what the caller has to decide. Dry run by default rather than behind a flag,
which is the right default for a command whose failure mode is editing files --
and it means an agent that runs `complete PLAN-0019' and walks away has done
nothing, which is deliberate and will occasionally be surprising.

With verdicts it is all or nothing: every refined document that is not blocked
needs one. A cascade that applied the two verdicts it was given and left the
third document in draft would produce exactly the half-updated state RULE-0005
was written to prevent, one command later.

A blocked document is reported and left alone, and a verdict naming one is
refused rather than obeyed. SET-DOCUMENT-STATUS is the way past that, and the
refusal exists so the caller sees the blocking plan before deciding to.

FORCE-WRITE is not for callers. It is how this function re-enters itself once
when the dry run it just performed had nothing to preview -- BUG-0057, and the
reasoning is at the re-entry below."
  (let ((repository (if (repository-p repository)
                        repository
                        (or (find-repository repository)
                            (return-from complete-plan
                              (list :problems (list (format nil "No repository named ~a."
                                                            repository))))))))
    (with-repository-lock (repository)
      (let ((graph (repository-graph repository)))
        (multiple-value-bind (parsed parse-problems) (parse-verdicts verdicts)
          (multiple-value-bind (plan problems) (resolve-document repository designator)
            (let ((problems (append parse-problems problems)))
              (when (and plan (not (plan-document-p plan)))
                (push (format nil "~a is a ~a document, not a plan; `complete' cascades ~
from a plan. Use set-status for one document."
                              (or (getp plan :doc-id) designator)
                              (or (document-category-of plan) "categoryless"))
                      problems))
              (when problems
                (return-from complete-plan
                  (list :repository (repository-name repository) :plan designator
                        :problems problems :documents '() :changed '())))
              (let ((dry-run (and (null parsed) (not force-write)))
                    (edits '())
                    (rows '())
                    ;; What this cascade is in the act of finishing. The plan
                    ;; leads it, because its own draft status is the first thing
                    ;; that would otherwise block every document it refines.
                    (settled (list plan))
                    (visited (list plan))
                    ;; BUG-0026. The verdict lookup is driven by the walk, so a
                    ;; verdict for a document the walk never reaches is never
                    ;; the subject of an ASSOC and cannot be reported by any
                    ;; code path that reads it. Every consulted doc-id is
                    ;; recorded here instead, and what is left over is refused
                    ;; below rather than discarded in silence.
                    (consulted '())
                    (frontier '()))
                (flet ((record (row) (push row rows))
                       (edit-for (document status)
                         (multiple-value-bind (edit edit-problems)
                             (plan-document-edit repository document status)
                           (if edit-problems
                               (progn (setf problems (append problems edit-problems)) nil)
                               (progn (push edit edits) edit)))))
                  ;; --- the plan itself ----------------------------------
                  ;; First, so that a plan whose own file refuses the edit is
                  ;; refused before a single refined document is touched.
                  (let ((edit (edit-for plan :final)))
                    (when edit
                      (record (list :doc-id (edit-doc-id edit)
                                    :category (edit-category edit)
                                    :status (edit-from edit)
                                    :verdict (edit-to edit)
                                    :blocked-by '()
                                    :action (cond (dry-run :would-set)
                                                  ((edit-changes-p edit) :set)
                                                  (t :unchanged))))
                      (setf frontier (refines-targets graph plan))))
                  ;; --- the walk upward ----------------------------------
                  ;; RULE-0005: "The walk continues upward only on
                  ;; implemented. If a plan implements an architecture and that
                  ;; architecture was the last outstanding child of a
                  ;; requirement, the requirement is implemented too." One hop
                  ;; would leave that requirement in draft, which is the same
                  ;; false claim the command exists to stop, arrived at one
                  ;; level further up.
                  ;;
                  ;; Level by level rather than depth-first, because a parent's
                  ;; blockers include its other children and every one of them
                  ;; has to be decided before the parent is judged.
                  (loop while frontier
                        do (let ((finished '())
                                 ;; BUG-0065 F1 and F1b. Documents the walk
                                 ;; passes through rather than decides: already
                                 ;; terminal, or of a category with no terminal
                                 ;; status. Separate from FINISHED because they
                                 ;; contribute REFINES-TARGETS and nothing else
                                 ;; -- no verdict, no edit, and no membership in
                                 ;; SETTLED, which is what this cascade is in
                                 ;; the act of finishing and they are not.
                                 (passed '())
                                 (next '()))
                             (dolist (document frontier)
                               (unless (member document visited)
                                 (push document visited)
                                 (let* ((doc-id (or (getp document :doc-id) (name document)))
                                        (category (document-category-of document))
                                        (vocabulary (document-status-vocabulary document))
                                        (blocked (document-blockers graph document settled))
                                        (verdict (cdr (assoc doc-id parsed
                                                             :test #'string-equal))))
                                   (push doc-id consulted)
                                   (cond
                                     ;; A type with no status field at all --
                                     ;; a concept, which REQ documents in this
                                     ;; tree routinely refine. Reported rather
                                     ;; than passed over silently, because
                                     ;; "nothing happened to CON-0004" is a fact
                                     ;; the caller wants. Walked through since
                                     ;; BUG-0065 F1b: it decides nothing, so it
                                     ;; ends nothing.
                                     ((null vocabulary)
                                      (record (list :doc-id doc-id :category category
                                                    :status nil :verdict nil
                                                    :blocked-by '() :action :no-status))
                                      (push document passed))
                                     ;; BUG-0065 F1b. A decision, a rule and an
                                     ;; architecture note have a status
                                     ;; vocabulary and no terminal member of it,
                                     ;; so none of the clauses below fits: not
                                     ;; terminal, not blocking -- FINISHABLE-P
                                     ;; already excludes them from
                                     ;; DOCUMENT-BLOCKERS -- and therefore
                                     ;; falling to :AWAITING-VERDICT, where the
                                     ;; all-or-nothing rule would refuse the
                                     ;; whole cascade until the caller supplied
                                     ;; a verdict for a decision. And no verdict
                                     ;; would help: TERMINAL-STATUS-P is false
                                     ;; for every member of the vocabulary, so
                                     ;; the walk would stop there having
                                     ;; extracted a judgement that changed
                                     ;; nothing.
                                     ;;
                                     ;; They are in force rather than
                                     ;; outstanding, which is the same sentence
                                     ;; FINISHABLE-P's docstring uses to keep
                                     ;; them from blocking. Reported as such and
                                     ;; walked through.
                                     ((not (finishable-p document))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by '()
                                                    :action :in-force))
                                      (push document passed))
                                     ;; Already finished before this cascade
                                     ;; started. It needs no verdict and blocks
                                     ;; nothing, and BUG-0065 D1 is that the
                                     ;; walk used to stop here: "nothing about
                                     ;; it changed, so nothing above it changed
                                     ;; because of it."
                                     ;;
                                     ;; True of a document this cascade
                                     ;; finished, false of one finished in an
                                     ;; earlier session. front-end is the case:
                                     ;; DES-0006 closed weeks before PLAN-0004
                                     ;; ran, so REQ-0004 above it was reachable
                                     ;; from no plan at all and had to be set
                                     ;; blind with `set-status'. The condition
                                     ;; that would have finished it had already
                                     ;; happened and the walk could no longer
                                     ;; observe it.
                                     ;;
                                     ;; So it contributes no verdict and no edit
                                     ;; and does contribute its own
                                     ;; REFINES-TARGETS, which is what
                                     ;; DOCUMENT-BLOCKERS has always assumed
                                     ;; about it: terminal means settled, and
                                     ;; settled is a reason a parent may now be
                                     ;; finishable rather than a reason to stop
                                     ;; asking.
                                     ((terminal-status-p document (getp document :status))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by '()
                                                    :action :already-finished))
                                      (push document passed))
                                     (blocked
                                      (when verdict
                                        (push (format nil "~a is still refined by ~
~{~a~^, ~}, which ~:[is~;are~] not finished. Close ~:*~:[it~;them~] first, or use ~
set-status to override." doc-id blocked (rest blocked))
                                              problems))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by blocked
                                                    :action :blocked)))
                                     ((null verdict)
                                      (unless dry-run
                                        (push (format nil "~a needs a verdict. Add ~
~a=<status> -- one of ~{~(~a~)~^, ~}." doc-id doc-id vocabulary)
                                              problems))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by '()
                                                    :action :awaiting-verdict)))
                                     (t
                                      (let ((edit (edit-for document verdict)))
                                        (when edit
                                          (record (list :doc-id doc-id
                                                        :category (edit-category edit)
                                                        :status (edit-from edit)
                                                        :verdict verdict :blocked-by '()
                                                        :action (cond (dry-run :would-set)
                                                                      ((edit-changes-p edit) :set)
                                                                      (t :unchanged))))
                                          ;; Terminal only. A `partial' verdict
                                          ;; means work remains, so the parent
                                          ;; is not finished either and the
                                          ;; walk stops rather than climbing
                                          ;; past an OUTSTANDING section.
                                          (when (terminal-status-p document verdict)
                                            (push document finished)))))))))
                             ;; Every document at this level is decided before
                             ;; the next level is computed, so a parent sees all
                             ;; of its children's outcomes and none of its
                             ;; grandchildren's.
                             (setf settled (append finished settled))
                             (dolist (document (append finished passed))
                               (setf next (append next (refines-targets graph document))))
                             ;; A dry run walks the whole chain on the
                             ;; assumption that every document it reports would
                             ;; be finished, which is what makes it a preview of
                             ;; the verdicts the caller has to supply.
                             (when dry-run
                               (dolist (document frontier)
                                 (unless (or (member document settled)
                                             (not (finishable-p document))
                                             (terminal-status-p document
                                                                (getp document :status))
                                             (document-blockers graph document settled))
                                   (push document settled)
                                   (setf next (append next
                                                      (refines-targets graph document))))))
                             (setf frontier (remove-duplicates next :from-end t)))))
                ;; BUG-0026: a verdict nobody asked for. Refused rather than
                ;; warned, for the reason a missing verdict is refused -- the
                ;; command is all-or-nothing, and a caller who named a document
                ;; the cascade does not reach has either mistyped it or misread
                ;; the chain. The message says which of the walk's two stopping
                ;; conditions applies, because "not in this cascade" invites the
                ;; reply that it is right there in the refines: chain.
                (let ((unused (remove-if (lambda (pair)
                                           (member (car pair) consulted
                                                   :test #'string-equal))
                                         parsed)))
                  (when unused
                    (push (format nil "~{~a~^, ~} ~:[is~;are~] not in this cascade, so ~
~:*~:[its verdict was~;their verdicts were~] not applied. The walk stops at a document ~
whose verdict is not terminal, and goes no further than what the plan refines -- run ~
`complete' with no verdicts to see the chain it reaches."
                                  (mapcar #'car unused) (rest unused))
                          problems)))
                (let ((rows (nreverse rows))
                      ;; Every planned edit, not only the ones that look like
                      ;; writes. A document already declaring its target status
                      ;; can still be filed in the wrong directory, and only
                      ;; the store knows; a no-op transition writes nothing and
                      ;; STORE-CHANGED-P keeps it out of :CHANGED.
                      (edits (nreverse edits)))
                  ;; BUG-0057. A dry run is a preview of the verdicts the
                  ;; caller has to supply. When no document in the cascade can
                  ;; take one, there is nothing to preview and no second call
                  ;; that would write: `complete PLAN-0002' answered `would-set'
                  ;; on every run and a verdict offered for the plan itself was
                  ;; refused as not in the cascade, so the command could not
                  ;; finish the plan at all and `set-status' became the way
                  ;; through -- which both the skill and the generated CLAUDE.md
                  ;; describe as the escape hatch for a *blocked* document.
                  ;;
                  ;; Two shapes reach this and the second is the commoner: a
                  ;; plan with no `refines:' edges, and a plan whose refined
                  ;; documents are all already finished or carry no status
                  ;; field. Neither is deciding anything, so the all-or-nothing
                  ;; safety argument has nothing to protect -- and a
                  ;; one-document transition writing at once is what
                  ;; SET-DOCUMENT-STATUS already does for the same act.
                  ;;
                  ;; Re-entry rather than a second code path, so the decision of
                  ;; what a walk finds is made once. It cannot recur twice:
                  ;; FORCE-WRITE clears DRY-RUN, and this branch tests it.
                  (when (and dry-run (null problems)
                             (notany (lambda (row)
                                       (eq :awaiting-verdict (getf row :action)))
                                     rows))
                    (return-from complete-plan
                      (complete-plan repository designator
                                     :verdicts verdicts :reindex reindex
                                     :force-write t)))
                  (multiple-value-bind (changed apply-problems)
                      (if (or dry-run problems)
                          (values '() '())
                          (apply-transition repository edits :reindex reindex))
                    (list :repository (repository-name repository)
                          :plan (or (getp plan :doc-id) designator)
                          :dry-run dry-run
                          ;; The store's refusals arrive here rather than from
                          ;; the walk: planning the batch is where a taken
                          ;; destination or an unwritable file is found, and
                          ;; under :PLANNED nothing has been written when they
                          ;; are. A partial apply reports both -- what landed
                          ;; under :CHANGED and what stopped it here -- and the
                          ;; same command run again finishes the rest.
                          :problems (append problems apply-problems)
                          :documents rows
                          ;; R7: re-running on a completed plan changes nothing
                          ;; and says so. The empty :CHANGED list is the saying.
                          :changed changed)))))))))))
