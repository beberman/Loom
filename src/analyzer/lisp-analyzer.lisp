;;;; A reader-based Common Lisp analyzer: walks a single source file and emits
;;;; the ontology operations describing the :file, :function and :variable
;;;; entities (plus :contains/:calls edges) it finds. Implements the analyzer
;;;; Phase 1 Software Architecture SS8.2 calls for -- "The Lisp analyzer does
;;;; not need Tree-sitter at all -- the reader plus a walk of top-level forms
;;;; yields functions, classes, packages, and call sites more reliably than any
;;;; grammar" -- behind the generic protocol in analyzer.lisp.
;;;;
;;;; It emits operations and never touches a graph (SS8.1), so it has no way to
;;;; know what a previous pass found. Everything that needs that knowledge --
;;;; recognising an entity it already made, retiring one that is gone -- is the
;;;; Graph Manager's, via the natural keys of SS4.4.
;;;;
;;;; Scope of this pass: top-level DEFUN and DEFVAR/DEFPARAMETER forms only,
;;;; and :CALLS edges only between functions defined in the *same* file. A call
;;;; to anything else -- a function defined elsewhere in the workspace, or the
;;;; standard library -- is indistinguishable from here without a cross-file
;;;; symbol index, so it is silently not recorded rather than guessed at or
;;;; dumped into :unresolved-calls. Cross-file resolution is a follow-on step
;;;; once more than one file has been analyzed into the same graph.

(in-package :loom-analyzer)

(defclass lisp-analyzer (analyzer)
  ()
  (:default-initargs
   :language :lisp
   ;; .asd included deliberately: system definitions are Lisp, and indexing
   ;; them is what lets the SS12.3 dependency-direction invariants be asked
   ;; about the declared graph as well as the code.
   :file-types '("lisp" "lsp" "cl" "asd"))
  (:documentation "A reader-based analyzer for Common Lisp source files."))

;;;; ------------------------------------------------------------------
;;;; Reading forms with source spans
;;;; ------------------------------------------------------------------

(defun skip-whitespace-and-comments (string pos)
  "The offset of the first character in STRING at or after POS that is
neither whitespace nor part of a line comment."
  (loop
    (cond ((>= pos (length string)) (return pos))
          ((member (char string pos) '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed))
           (incf pos))
          ((char= (char string pos) #\;)
           (setf pos (or (position #\Newline string :start pos) (length string))))
          (t (return pos)))))

(defun read-forms-with-spans (content)
  "Every top-level form in CONTENT, read with *READ-EVAL* disabled and in a
throwaway package so foreign package prefixes and keywords intern safely
without touching any real package. Returns a list of (FORM START-LINE
END-LINE)."
  (let ((pos 0)
        (len (length content))
        (results '())
        (*package* (make-package (gensym "LOOM-ANALYZER-SCRATCH-") :use nil))
        (*read-eval* nil))
    (unwind-protect
         (loop
           (setf pos (skip-whitespace-and-comments content pos))
           (when (>= pos len) (return))
           ;; READ-PRESERVING-WHITESPACE, not READ: plain READ consumes one
           ;; trailing whitespace char it never needed, which would throw
           ;; off END-POS by one whenever a form is followed by a newline.
           (let* ((stream (make-string-input-stream content pos len))
                  (form (read-preserving-whitespace stream nil :eof)))
             (when (eq form :eof) (return))
             (let ((end-pos (+ pos (file-position stream))))
               (push (list form (offset-line content pos) (offset-line content end-pos))
                     results)
               (setf pos end-pos))))
      (delete-package *package*))
    (nreverse results)))

(defun token-name (x)
  "A plain, package-independent lowercase name for a symbol or a lambda-list
element X (which may be a destructuring pair like (KEY DEFAULT))."
  (cond ((symbolp x) (string-downcase (symbol-name x)))
        ((consp x) (token-name (car x)))
        (t (princ-to-string x))))

(defun collect-call-names (tree)
  "Every operator-position symbol name appearing anywhere in TREE, skipping
quoted data so a literal list is never mistaken for a call site."
  (let ((names '()))
    (labels ((walk (x)
               (when (consp x)
                 (unless (and (symbolp (car x)) (string= (token-name (car x)) "quote"))
                   (when (symbolp (car x))
                     (push (token-name (car x)) names))
                   (walk (car x))
                   (walk (cdr x))))))
      (walk tree))
    names))

;;;; ------------------------------------------------------------------
;;;; Entity construction
;;;; ------------------------------------------------------------------

(defun definition-p (form head)
  (and (consp form) (symbolp (car form)) (string= (token-name (car form)) head)))

(defun standard-operator-p (name)
  "True when NAME names a symbol in the COMMON-LISP package.

The filter that keeps :UNRESOLVED-CALLS meaningful. Every operator position in
a body is a call candidate, and most of them are LET, WHEN, FORMAT and the
rest of the standard library -- recording those as unresolved would bury the
handful of names that actually point at another file in the workspace. This
belongs in the Lisp analyzer specifically: knowing what the ambient vocabulary
of a language is, is exactly the kind of thing a language analyzer knows."
  (and (find-symbol (string-upcase name) '#:common-lisp) t))


;;; Natural-key properties are passed at construction, not set afterwards with
;;; SETP: SS5.1 derives the id from the natural key, and that derivation runs
;;; inside INITIALIZE-INSTANCE. A :file or :name arriving later would leave the
;;; entity carrying an id computed from values it did not yet have.

(defun make-file-entity (path contents)
  (make-instance 'file-entity
                 :name path
                 :origin-file path
                 :properties (properties-table
                              (list :path path
                                    :language :lisp
                                    :line-count (line-count contents)))))

(defun make-function-entity (form start end path)
  (make-instance 'function-entity
                 :name (token-name (second form))
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :arguments (mapcar #'token-name (third form))
                                    :language :lisp))))

(defun make-variable-entity (form start end path)
  (make-instance 'variable-entity
                 :name (token-name (second form))
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :kind :special
                                    :language :lisp))))

(defun make-unparsable-file-entity (path contents condition)
  "The entity a file gets when its contents cannot be read.

SS9.3: \"If a file cannot be parsed, the analyzer emits a single assert
marking the module analysis-failed with the condition text.\" SS3.3 gives the
reason -- a file that could not be parsed is a known unknown, and an agent
asking about it deserves to be told so rather than told nothing. Silence would
be indistinguishable from a file that genuinely defines nothing."
  (make-instance 'file-entity
                 :name path
                 :origin-file path
                 :properties (properties-table
                              (list :path path
                                    :language :lisp
                                    :line-count (line-count contents)
                                    :analysis-failed-p t
                                    :analysis-error (princ-to-string condition)))))

(defmethod analyze-file ((analyzer lisp-analyzer) path contents workspace-id)
  "Ontology operations for the Lisp source in CONTENTS at PATH: a :FILE
entity; a :FUNCTION entity per top-level DEFUN and a :VARIABLE entity per
top-level DEFVAR/DEFPARAMETER, each with a :CONTAINS edge from the file; and a
:CALLS edge between two functions defined in this file whenever one's body
references the other.

Asserts precede the edges that name them, because the Graph Manager resolves
an edge's endpoints against the asserts it has already planned in the same
transaction."
  (declare (ignore analyzer))
  (let ((file (make-file-entity path contents))
        (definitions '())       ; entities, in source order
        (functions '())         ; alist: name -> (entity . defun-form)
        (ops '())               ; built reversed, NREVERSEd on the way out
        (forms nil))

    ;; --- pass 0: read, and survive a file that will not read ---------
    ;; SS3.3: a condition escaping here would take the watcher thread down and
    ;; leave the process answering queries while silently indexing nothing.
    (handler-case (setf forms (read-forms-with-spans contents))
      (error (condition)
        (return-from analyze-file
          (list (retract-file path workspace-id)
                (assert-entity (make-unparsable-file-entity path contents condition)
                               workspace-id)))))

    ;; --- pass 1: what this file defines -----------------------------
    (dolist (spec forms)
      (destructuring-bind (form start end) spec
        (cond
          ((definition-p form "defun")
           (let ((e (make-function-entity form start end path)))
             (push e definitions)
             (push (cons (name e) (cons e form)) functions)))
          ((or (definition-p form "defvar") (definition-p form "defparameter"))
           (push (make-variable-entity form start end path) definitions)))))
    (setf definitions (nreverse definitions))

    ;; --- pass 2: who each function calls ----------------------------
    ;; A name resolves here only if this same file defines it. Anything else
    ;; that is not standard Common Lisp is recorded on the entity as an
    ;; unresolved call, per SS8.3: "unresolved calls are recorded as a
    ;; property, not a dangling edge." LOOM-GRAPH:RESOLVE-CALLS is what turns
    ;; those into real edges once the whole workspace is in one graph -- the
    ;; analyzer cannot, because it sees one file and holds no state.
    (let ((local-calls '()))      ; list of (caller-entity . callee-entity)
      (dolist (entry functions)
        (destructuring-bind (caller . form) (cdr entry)
          (let ((unresolved '()))
            (dolist (callee-name (remove-duplicates (collect-call-names (cdddr form))
                                                    :test #'string=))
              (let ((callee (assoc callee-name functions :test #'string=)))
                (cond (callee (push (cons caller (cadr callee)) local-calls))
                      ((standard-operator-p callee-name))
                      ((string= callee-name (name caller)))   ; direct recursion
                      (t (push callee-name unresolved)))))
            (setp caller :unresolved-calls (nreverse unresolved)))))

      ;; --- pass 3: emit ------------------------------------------------
      ;; RETRACT-FILE leads, per SS5.4: "reanalyzing a changed file is
      ;; retract-file followed by the fresh asserts." It is what makes a
      ;; definition deleted from the file leave the index -- the asserts below
      ;; can only say what is still there. On a file the index has not seen it
      ;; is a no-op, so a first analysis and a reanalysis are the same shape.
      ;;
      ;; Asserts then precede the edges that name them, because the Graph
      ;; Manager resolves an edge's endpoints against the asserts it has
      ;; already planned in the same transaction.
      (push (retract-file path workspace-id) ops)
      (push (assert-entity file workspace-id) ops)
      (dolist (e definitions)
        (push (assert-entity e workspace-id) ops)
        (push (assert-edge :contains file e :workspace-id workspace-id) ops))
      (dolist (call (reverse local-calls))
        (push (assert-edge :calls (car call) (cdr call) :workspace-id workspace-id)
              ops)))
    (nreverse ops)))

;;;; The one registered instance. Stateless, so one serves every file and
;;;; every workspace.
(register-analyzer (make-instance 'lisp-analyzer))
