;;;; The generic inspector protocol.
;;;; Implements DES-0011 R1, beside analyzer.lisp and shaped like it on
;;;; purpose: a class that says which language it speaks, a cheap probe, a
;;;; registry with replace-by-class semantics. A reader who knows one should
;;;; not have to learn the other.
;;;;
;;;; What it is not is a second ANALYZE-FILE, and the three mismatches are each
;;;; sufficient on their own (DES-0011). The unit is a loadable system rather
;;;; than a path plus contents. The input is a tree that must build, not text
;;;; that need not. And the output is facts rather than ontology operations --
;;;; because operations go through an upsert whose absorb-replace semantics
;;;; cannot protect the text pass's properties, so the derivation has to be
;;;; graph-aware, and an analyzer structurally cannot be.
;;;;
;;;; The invariants this file inherits from analyzer.lisp unchanged: it touches
;;;; no graph, and loom-analyzer.asd is what enforces that rather than
;;;; discipline. The one it adds: it never loads target code into this image.
;;;; The process boundary is what makes that structural (REQ-0018 R3), and it
;;;; is a per-language inspector's business to draw -- nothing here knows what
;;;; a subprocess is.

(in-package :loom-analyzer)

;;;; ==================================================================
;;;; The protocol
;;;; ==================================================================

(defclass inspector ()
  ((language :initarg :language :reader inspector-language
             :documentation "The keyword this inspector stamps onto the
:LANGUAGE field of the inspection it produces. One of
LOOM-ONTOLOGY:*SOURCE-LANGUAGES*."))
  (:documentation "Base class for every language inspector.

Configuration and no state, exactly as ANALYZER is: bounds, flags and the
language, so one registered instance serves every repository. Per-language
configuration -- what a unit is, how to drive the toolchain, what its output
looks like -- belongs on the subclass, and nothing outside it may learn any of
it."))

(defgeneric inspector-available-p (inspector root)
  (:documentation "Two values: whether this inspector can run against ROOT, and
a reason string when it cannot.

Never signals. REQ-0018 R2 is explicit that an absent toolchain is a recorded
absence rather than a failure, and the reason string is what ENRICH-REPOSITORY
reports -- so it has to name what was missing (\"no sbcl at /usr/bin/sbcl\",
\"no .asd files under root\") rather than merely say no. A caller cannot
distinguish \"nothing to do\" from \"something broke\" without it, which is the
whole of the distinction R2 asks for."))

(defgeneric inspect-repository (inspector root &key)
  (:documentation "Run the toolchain against ROOT and return an inspection.

An inspection is plain data -- DES-0011's CHILD PROTOCOL plist -- and not
ontology operations. Facts, because the merge that turns them into operations
has to read the graph first, and an inspector cannot reach one."))

;;;; ==================================================================
;;;; Registry
;;;; ==================================================================

(defvar *inspectors* '()
  "Registered inspector instances, most recently registered first.
Separate from *ANALYZERS* and sharing nothing with it: a language may have an
analyzer and no inspector, which is the ordinary case and REQ-0018 R2's
recorded absence.")

(defun register-inspector (inspector)
  "Register INSPECTOR, replacing any previously registered one of its class.
Re-registering rather than accumulating, for the reason REGISTER-ANALYZER
gives: in a live image a recompiled file runs its registration form again."
  (setf *inspectors*
        (cons inspector (remove (class-of inspector) *inspectors* :key #'class-of)))
  inspector)

(defun find-inspectors (language)
  "Every registered inspector for LANGUAGE, most recently registered first.

Plural where FIND-ANALYZER is singular, and the asymmetry is deliberate: an
analyzer is chosen because it claims a file, so a second claimant would be an
ambiguity, while two inspectors for one language would be two toolchains with
different things to say and both are worth asking."
  (remove language *inspectors* :key #'inspector-language :test-not #'eq))

;;;; ==================================================================
;;;; Reading an inspection
;;;; ==================================================================
;;;;
;;;; The in-memory shape IS the wire shape: the plist the child writes is the
;;;; plist the parent hands on, read with GETF at both ends. These wrappers
;;;; exist for this system's own readability, and LOOM-GRAPH deliberately does
;;;; not use them -- it depends on loom-ontology alone, so ENRICH-OPS reads the
;;;; same plist with its own GETFs and names nothing from this package.

(defun inspection-units (inspection)
  "Per-unit status plists: (:unit name :status :loaded), or :FAILED with a
:PHASE and an :ERROR string. The primary output, not the facts -- a pass whose
every unit failed produces no facts and no error, and only these tell it apart
from a tree the image agrees with completely (REQ-0018 R4)."
  (getf inspection :units))

(defun inspection-definitions (inspection)
  (getf inspection :definitions))

(defun inspection-calls (inspection)
  (getf inspection :calls))
