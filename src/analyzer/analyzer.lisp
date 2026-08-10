;;;; The generic analyzer protocol.
;;;; Implements Phase 1 Software Architecture SS8.1.
;;;;
;;;; "An analyzer receives a workspace-relative file path and its contents and
;;;; returns a list of ontology operations. Analyzers are stateless and know
;;;; nothing about storage, which keeps the language-independence principle
;;;; enforceable: the protocol is the only coupling."
;;;;
;;;; That sentence is the whole design of this file, and it is why
;;;; LOOM-ANALYZER depends on LOOM-ONTOLOGY and nothing else (SS3). An
;;;; analyzer cannot reach the graph, so it cannot acquire an opinion about
;;;; storage, transaction boundaries, or what is already in the graph -- and
;;;; SS12.3 turns that into a build-failing query once self-analysis runs:
;;;; "No entity in loom-analyzer has any edge into loom-adapter or loom-graph."
;;;;
;;;; Adding a language is therefore: subclass ANALYZER, declare the file
;;;; extensions it claims, write one ANALYZE-FILE method that returns ops, and
;;;; register an instance. Nothing upstream changes -- which is the promise
;;;; SS8.2 makes about the Tree-sitter analyzers arriving behind this same
;;;; protocol.

(in-package :loom-analyzer)

;;;; ==================================================================
;;;; The protocol (SS8.1)
;;;; ==================================================================

(defclass analyzer ()
  ((language   :initarg :language   :reader analyzer-language
               :documentation "The keyword this analyzer stamps onto the
:LANGUAGE property of everything it emits. One of LOOM-ONTOLOGY:*SOURCE-LANGUAGES*.")
   (file-types :initarg :file-types :reader analyzer-file-types
               :initform '()
               :documentation "Lowercase filename extensions this analyzer
claims, without the dot. Read by the default ANALYZER-HANDLES-P method."))
  (:documentation "Base class for every language analyzer.

Deliberately holds configuration and no state: an analyzer is a value that
says which language it speaks, not an object that accumulates results. Two
calls to ANALYZE-FILE on the same instance are independent, so one registered
instance serves every file and every workspace."))

(defgeneric analyze-file (analyzer path contents workspace-id)
  (:documentation "Return a list of ontology-ops for this file.

PATH is workspace-relative and forward-slashed; CONTENTS is its text.
Implementations must not touch the filesystem or the graph -- everything they
are allowed to know arrives in these arguments, and everything they have to
say leaves as operations.

One file's op stream must assert each ENTITY-NATURAL-KEY at most once. Two
asserts on one key in one transaction are a claim that the file defines the
same thing twice, and the writer has no way to reconcile them: ids are derived
from the key, so both definitions' edges carry the same endpoint, and by the
time the graph sees the ops the fact of which definition produced which edge
has already been destroyed. That is BUG-0012, and ARCH-0012 puts the duty
here.

Reconciling is the implementer's job because it is the *language's* semantics,
not the graph's. Common Lisp replaces: among same-key definitions in one file
the last in source order is the one that loads, and every earlier one is dead
code -- which is what SUPERSEDE-SHADOWED-DEFINITIONS does in the Lisp
analyzer, before it walks a body or emits an operation. A TypeScript analyzer
meeting interface declaration merging or function overloads must MERGE the
same shape instead. There is no answer the writer could pick that would be
right for both, which is why it does not try.

ABSORB-ENTITY's later-assert-wins is a disclosed backstop for an
implementation that breaks this, not a mechanism to lean on: it reconciles the
properties and leaves the edges unioned. A within-transaction absorb of a code
entity is evidence of an analyzer violating this contract. Nothing checks it
-- see CON-0005."))

(defgeneric analyzer-handles-p (analyzer path)
  (:documentation "True when ANALYZER claims PATH.")
  (:method ((analyzer analyzer) path)
    "Match PATH's extension against ANALYZER-FILE-TYPES. Enough for every
analyzer so far; specialize when a language needs to read the file to decide."
    (let ((type (pathname-type (pathname path))))
      (and (stringp type)
           (member type (analyzer-file-types analyzer) :test #'string-equal)
           t))))

;;;; ==================================================================
;;;; Registry -- how a file finds its analyzer
;;;; ==================================================================

(defvar *analyzers* '()
  "Registered analyzer instances, most recently registered first.
FIND-ANALYZER takes the first that claims a path, so a later registration
overrides an earlier one for the extensions they share.")

(defun register-analyzer (analyzer)
  "Register ANALYZER, replacing any previously registered one of its class.
Re-registering rather than accumulating matters in a live image, where a file
is recompiled and its registration form runs again."
  (setf *analyzers*
        (cons analyzer (remove (class-of analyzer) *analyzers* :key #'class-of)))
  analyzer)

(defun find-analyzer (path)
  "The registered analyzer claiming PATH, or NIL when no language handles it."
  (find-if (lambda (a) (analyzer-handles-p a path)) *analyzers*))

(defun analyzable-p (path)
  "True when some registered analyzer claims PATH."
  (and (find-analyzer path) t))

;;;; ==================================================================
;;;; Driving an analyzer over a file on disk
;;;; ==================================================================
;;;;
;;;; The protocol above takes contents, not a filename, so that analyzers stay
;;;; testable without a filesystem and usable against unsaved editor buffers.
;;;; Reading the file is a caller's job, and this is the caller most of them
;;;; want.

(defun slurp-file (path)
  "The full contents of the file at PATH as a string."
  (with-open-file (in path :direction :input)
    (let* ((buffer (make-string (file-length in)))
           (count (read-sequence buffer in)))
      (subseq buffer 0 count))))

(defun workspace-relative-path (path &optional workspace-root)
  "PATH as the ontology wants it stored: relative to WORKSPACE-ROOT and
forward-slashed, so a :FILE entity's :PATH means the same thing on Windows and
Linux and survives the workspace moving. With no root, the namestring is used
as given."
  (let ((string (if workspace-root
                    (enough-namestring (pathname path) (pathname workspace-root))
                    (namestring (pathname path)))))
    (substitute #\/ #\\ string)))

(defun analyze-path (path &key workspace-id workspace-root contents)
  "Analyze the file at PATH with whichever analyzer claims it, returning the
ontology-ops it produced. Returns NIL when no analyzer handles PATH, so a
sweep over a mixed tree can call this on everything.

CONTENTS overrides what is on disk -- the hook for analyzing an editor buffer
that has not been saved."
  (let ((analyzer (find-analyzer path)))
    (when analyzer
      (analyze-file analyzer
                    (workspace-relative-path path workspace-root)
                    (or contents (slurp-file path))
                    workspace-id))))

(defun analyze-tree (root &key workspace-id (workspace-root root))
  "Ops for every analyzable file under ROOT, as one list.

One transaction for a whole tree: the base-graph pass of SS7.1, and the entry
point self-analysis (SS12.2) runs Loom over its own source with."
  (loop for path in (directory (merge-pathnames "**/*.*" (pathname root)))
        when (and (pathname-name path) (analyzable-p path))
          append (analyze-path path :workspace-id workspace-id
                                    :workspace-root workspace-root)))

;;;; ==================================================================
;;;; Shared text utilities
;;;;
;;;; Language-neutral only. Anything that knows what a comment looks like
;;;; belongs in the analyzer for the language that says so.
;;;; ==================================================================

(defun offset-line (string offset)
  "The 1-based line number of OFFSET in STRING."
  (1+ (count #\Newline string :end (min offset (length string)))))

(defun line-count (string)
  "The number of lines in STRING.
A trailing newline terminates the last line rather than starting an empty one,
so this agrees with what an editor shows and with the line numbers
OFFSET-LINE hands out."
  (let ((length (length string)))
    (cond ((zerop length) 0)
          ((char= #\Newline (char string (1- length))) (count #\Newline string))
          (t (1+ (count #\Newline string))))))

;;;; ------------------------------------------------------------------
;;;; The system a path belongs to, for an analyzer with nothing stronger
;;;;
;;;; ARCH-0009 R2: this is BUG-0006's fix, relocated from LOOM-GRAPH's
;;;; ENTITY-SYSTEM rather than reimplemented. Deciding what a path means in a
;;;; given language is an analyzer's job and not the query layer's -- the query
;;;; layer is the one place in the stack that structurally cannot know -- but a
;;;; path convention is language-neutral, so it lives here beside OFFSET-LINE
;;;; rather than in one language's analyzer. An analyzer whose language has a
;;;; real grouping construct (Lisp's IN-PACKAGE) overrides this; one that has
;;;; none calls it and stops.
;;;;
;;;; The body is unchanged from what BUG-0006 already proved against this tree,
;;;; deliberately: a rewrite would have to reprove the same claim.
;;;; ------------------------------------------------------------------

(defparameter *src-prefix* "src/"
  "The one directory a tree's layering rules look inside. A path outside it
keeps DEFAULT-SYSTEM-FOR-PATH's older, shallower convention -- see its own
docstring.")

(defun default-system-for-path (path)
  "The system PATH belongs to, as a keyword, or NIL.

The segment after \"src/\" for a source file, so \"src/knowledge/services.lisp\"
is :KNOWLEDGE, and the leading one for anything else, so
\"docs/rules/RULE-0001.yaml\" stays :DOCS. NIL when no further slash exists --
a file directly under src/ names no system."
  (when (stringp path)
    (let* ((prefix-length (length *src-prefix*))
           (under-src (and (>= (length path) prefix-length)
                           (string= *src-prefix* path :end2 prefix-length)))
           (start (if under-src prefix-length 0))
           (slash (position #\/ path :start start)))
      (when slash
        (intern (string-upcase (subseq path start slash)) :keyword)))))
