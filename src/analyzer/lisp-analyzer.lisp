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

(defun make-file-entity (path contents)
  (let ((e (make-instance 'file-entity :name path)))
    (setp e :path path)
    (setp e :language :lisp)
    (setp e :line-count (line-count contents))
    e))

(defun make-function-entity (form start end path)
  (let ((e (make-instance 'function-entity :name (token-name (second form)))))
    (setp e :file path)
    (setp e :start-line start)
    (setp e :end-line end)
    (setp e :arguments (mapcar #'token-name (third form)))
    (setp e :language :lisp)
    e))

(defun make-variable-entity (form start end path)
  (let ((e (make-instance 'variable-entity :name (token-name (second form)))))
    (setp e :file path)
    (setp e :start-line start)
    (setp e :end-line end)
    (setp e :kind :special)
    (setp e :language :lisp)
    e))

;;;; ------------------------------------------------------------------
;;;; The protocol method
;;;; ------------------------------------------------------------------

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
  (let* ((file (make-file-entity path contents))
         (ops '())                 ; built reversed, NREVERSEd on the way out
         (functions '()))          ; alist: name -> (entity . defun-form)
    (flet ((emit (op) (push op ops))
           (contained (entity)
             (assert-edge :contains file entity :workspace-id workspace-id)))
      (emit (assert-entity file workspace-id))
      (dolist (spec (read-forms-with-spans contents))
        (destructuring-bind (form start end) spec
          (cond
            ((definition-p form "defun")
             (let ((e (make-function-entity form start end path)))
               (emit (assert-entity e workspace-id))
               (emit (contained e))
               (push (cons (name e) (cons e form)) functions)))
            ((or (definition-p form "defvar") (definition-p form "defparameter"))
             (let ((e (make-variable-entity form start end path)))
               (emit (assert-entity e workspace-id))
               (emit (contained e)))))))
      ;; Calls, once every local definition is known: a name resolves only if
      ;; it was defined in this same file.
      (dolist (entry functions)
        (destructuring-bind (caller . form) (cdr entry)
          (dolist (callee-name (remove-duplicates (collect-call-names (cdddr form))
                                                  :test #'string=))
            (let ((callee (assoc callee-name functions :test #'string=)))
              (when callee
                (emit (assert-edge :calls caller (cadr callee)
                                   :workspace-id workspace-id))))))))
    (nreverse ops)))

;;;; The one registered instance. Stateless, so one serves every file and
;;;; every workspace.
(register-analyzer (make-instance 'lisp-analyzer))
