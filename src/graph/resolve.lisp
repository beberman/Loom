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
  "Operations linking each recorded unresolved call to the definition it names.

For every callable carrying :UNRESOLVED-CALLS, each name is looked up in the
workspace:

  exactly one definition  -- assert a :CALLS edge to it, and drop the name
                             from :UNRESOLVED-CALLS
  several definitions     -- leave it unresolved rather than guess. Picking
                             one would be a fabricated edge, and asserting all
                             of them would make every caller of a common name
                             look coupled to code it never touches. Precise
                             disambiguation is what SS8.3 defers to LSP.
  none                    -- leave it unresolved. It is a genuine external
                             dependency, and a standing record of one.

Idempotent: an edge that already exists upserts onto itself by natural key,
and a name that resolved on the last pass is no longer in the property to
resolve again. Safe to run after every analysis pass."
  (let ((index (callable-index view))
        (ops '()))
    (dolist (type *callable-types*)
      (dolist (caller (entities-of-type view type))
        (let ((linked '())
              (left '()))
          (dolist (name (getp caller :unresolved-calls))
            (let ((candidates (gethash (string-downcase name) index)))
              (if (and candidates
                       (null (rest candidates))
                       (not (eq (first candidates) caller)))
                  (push (first candidates) linked)
                  (push name left))))
          (when linked
            (dolist (callee (nreverse linked))
              (push (assert-edge :calls caller callee :workspace-id workspace-id) ops))
            ;; What is left stays on the entity: an accurate, shrinking record
            ;; of what this code depends on that the workspace does not define.
            (push (update-properties (id caller)
                                     (list :unresolved-calls (nreverse left))
                                     workspace-id)
                  ops)))))
    (nreverse ops)))
