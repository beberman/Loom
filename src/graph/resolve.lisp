;;;; Cross-file call resolution.
;;;; Implements the workspace half of Phase 1 Software Architecture SS8.3:
;;;; "CALLS relationships where the callee resolves within the workspace
;;;; (unresolved calls are recorded as a property, not a dangling edge)."
;;;;
;;;; This cannot live in an analyzer. SS8.1 makes analyzers stateless and
;;;; file-scoped, so one sees the call to APPLY-TRANSACTION but has no way to
;;;; know that transaction.lisp defines it -- it records the name and moves
;;;; on. Resolution is the first thing that needs the whole workspace in one
;;;; place, which is here.
;;;;
;;;; It is also the difference between a graph that can answer questions and
;;;; one that cannot. Without it, :CALLS edges stop at file boundaries, so
;;;; "what calls this?" and "what breaks if I change this?" -- the two
;;;; questions the impact engine exists to answer -- return almost nothing.
;;;;
;;;; Reads a view and returns operations; it does not apply them. The caller
;;;; submits them like any other transaction, which keeps the Graph Manager
;;;; the only writer (SS5.1).

(in-package :loom-graph)

(defparameter *callable-types* '(:function :method)
  "Entity types a :CALLS edge may terminate at, per the :CALLS declaration in
code-ontology.lisp.")

(defun callable-index (view)
  "Name -> list of callable entities defined under it, downcased.
A list rather than a single entity because nothing stops two files defining
the same name, and pretending otherwise is how a resolver invents edges."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (type *callable-types*)
      (dolist (entity (entities-of-type view type))
        (when (slot-boundp entity 'name)
          (push entity (gethash (string-downcase (name entity)) index)))))
    index))

(defun resolve-calls (view &key workspace-id)
  "Operations linking each recorded call name to the definition it names.

For every callable carrying :CALL-NAMES, each name is looked up in the
workspace:

  exactly one definition  -- assert a :CALLS edge to it
  several definitions     -- record it unresolved rather than guess. Picking
                             one would be a fabricated edge, and asserting all
                             of them would make every caller of a common name
                             look coupled to code it never touches. Precise
                             disambiguation is what SS8.3 defers to LSP.
  none                    -- record it unresolved. It is a genuine external
                             dependency, and a standing record of one.

:UNRESOLVED-CALLS is rewritten from scratch each pass rather than whittled
down, and :CALL-NAMES is never touched. That distinction is what makes the
pipeline's ordering work rather than merely look right. Reanalyzing a file
retracts it first (SS5.4), which destroys the :CALLS edges pointing *into* it
from files that did not change. Those files are not reanalyzed, so the only
record that they call anything is whatever is already on their entities -- and
while this function consumed that record, resolution could not rebuild what the
retract had just destroyed. Deriving instead of consuming means every pass sees
the same question and can answer it again.

Idempotent: an edge that already exists upserts onto itself by natural key, and
a name that resolved last pass resolves to the same edge this pass. Safe to run
after every analysis pass."
  (let ((index (callable-index view))
        (ops '()))
    (dolist (type *callable-types*)
      (dolist (caller (entities-of-type view type))
        (let ((names (getp caller :call-names))
              (linked '())
              (left '()))
          (dolist (name names)
            (let ((candidates (gethash (string-downcase name) index)))
              (if (and candidates
                       (null (rest candidates))
                       (not (eq (first candidates) caller)))
                  (push (first candidates) linked)
                  (push name left))))
          (dolist (callee (nreverse linked))
            (push (assert-edge :calls caller callee :workspace-id workspace-id) ops))
          ;; Unconditional where it used to be (WHEN LINKED ...): a caller
          ;; whose every name went external still has to have that written
          ;; down, and a caller whose callee has since been deleted has to
          ;; have :UNRESOLVED-CALLS grow back.
          (when names
            (push (update-properties (id caller)
                                     (list :unresolved-calls (nreverse left))
                                     workspace-id)
                  ops)))))
    (nreverse ops)))

;;;; ==================================================================
;;;; Document links (SS10.3)
;;;; ==================================================================
;;;;
;;;; The same problem in a different costume. A decision's affects: field
;;;; names entities the document analyzer cannot see, for the same reason the
;;;; Lisp analyzer cannot see across a file boundary: SS9.1 keeps analyzers
;;;; stateless. The names ride through as properties and are resolved here,
;;;; where the whole index is in one place.
;;;;
;;;; SS10.3 asks for two mechanisms with different provenance, and the
;;;; difference is the point:
;;;;
;;;;   Declared -- affects:, supersedes:, applies-to:. Someone wrote these
;;;;   down deliberately, so they resolve to :structural edges at confidence
;;;;   1.0, and a name that resolves to nothing is recorded rather than
;;;;   dropped. That record is the documentation staleness detector.
;;;;
;;;;   Mentioned -- names appearing in prose. Nobody promised these, so they
;;;;   resolve to :inferred edges at lower confidence with derived-from
;;;;   populated, which is what makes them go stale when the code moves.

(defparameter *document-types* '(:decision :rule :concept :document)
  "Entity types the documentation analyzer produces.")

(defparameter *declared-link-fields*
  '((:affects    . :decides)
    (:applies-to . :applies-to)
    (:supersedes . :supersedes))
  "Document property -> the relationship type it declares.")

(defparameter *mention-confidence* 0.5
  "Confidence for an edge inferred from prose.
Low enough that a caller filtering on confidence drops them, present enough
that \"what decisions touch this?\" answers without the author having
enumerated every consequence.")

(defun linkable-index (view)
  "Name -> entities that a document reference could name.
Keyed on both the entity name and, for documents, the doc-id -- a decision's
supersedes: names another decision by its id, not by a function name."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (entity (all-entities view))
      (when (slot-boundp entity 'name)
        (push entity (gethash (string-downcase (name entity)) index)))
      (let ((doc-id (getp entity :doc-id)))
        (when doc-id
          (pushnew entity (gethash (string-downcase doc-id) index)))))
    index))

(defun resolve-one (index name)
  "The single entity NAME identifies, or NIL when it names none or several.
Refusing an ambiguous name is the same judgement RESOLVE-CALLS makes: a
fabricated edge is worse than a recorded miss."
  (let ((candidates (gethash (string-downcase name) index)))
    (when (and candidates (null (rest candidates)))
      (first candidates))))

(defun resolve-document-links (view &key workspace-id)
  "Operations linking each document's declared and mentioned references.

Declared names that resolve become :structural edges of the type their field
declares; the rest are collected onto the document's :UNRESOLVED-REFERENCES,
which is what SS10.3 asks be \"flagged ... counted in status, and exposed
through the API\" instead of quietly discarded. Prose mentions that resolve
become :inferred :DOCUMENTS edges.

Idempotent, like RESOLVE-CALLS: edges upsert by natural key, and a name that
resolved on a previous pass is still in the property, so nothing drifts."
  (let ((index (linkable-index view))
        (ops '()))
    (dolist (type *document-types*)
      (dolist (document (entities-of-type view type))
        (let ((unresolved '()))
          ;; --- declared links ------------------------------------------
          (dolist (field-and-type *declared-link-fields*)
            (dolist (name (getp document (car field-and-type)))
              (let ((target (resolve-one index name)))
                (if (and target (not (eq target document)))
                    (push (assert-edge (cdr field-and-type) document target
                                       :workspace-id workspace-id)
                          ops)
                    (pushnew name unresolved :test #'string=)))))
          ;; --- mentioned links -----------------------------------------
          (dolist (name (getp document :mentions))
            (let ((target (resolve-one index name)))
              (when (and target
                         (not (eq target document))
                         (not (member (entity-type target) *document-types*)))
                (push (assert-edge :documents document target
                                   :workspace-id workspace-id
                                   :source :inferred
                                   :confidence *mention-confidence*
                                   :derived-from (list (id target)))
                      ops))))
          (push (update-properties (id document)
                                   (list :unresolved-references (nreverse unresolved))
                                   workspace-id)
                ops))))
    (nreverse ops)))

(defun unresolved-references (view)
  "Every document reference that named nothing, as (document-name . name).
What the status command reports, per SS3.2."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type view type)
                     append (loop for name in (getp document :unresolved-references)
                                  collect (cons (name document) name)))))
