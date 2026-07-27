;;;; A reader-based Lisp analyzer: walks a single source file and writes the
;;;; :function, :variable, and :file entities (plus :contains/:calls edges)
;;;; it finds directly into a Graph Manager. Implements the "reader-based
;;;; Lisp analyzer" named in Phase 1 Overview -- the Tree-sitter/LSP analyzer
;;;; for other languages is separate future work.
;;;;
;;;; Scope of this first pass: top-level DEFUN and DEFVAR/DEFPARAMETER forms
;;;; only, and :CALLS edges only between functions defined in the *same*
;;;; file. A call to anything else -- a function defined elsewhere in the
;;;; workspace, or the standard library -- is indistinguishable from here
;;;; without a cross-file symbol index, so it is silently not recorded
;;;; rather than guessed at or dumped into :unresolved-calls. Cross-file
;;;; resolution is a follow-on step once more than one file has been
;;;; analyzed into the same graph.

(in-package :loom-analyzer)

;;;; ------------------------------------------------------------------
;;;; Reading forms with source spans
;;;; ------------------------------------------------------------------

(defun slurp-file (path)
  "The full contents of the file at PATH as a string."
  (with-open-file (in path :direction :input)
    (let* ((buffer (make-string (file-length in)))
           (count (read-sequence buffer in)))
      (subseq buffer 0 count))))

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

(defun offset-line (string offset)
  "The 1-based line number of OFFSET in STRING."
  (1+ (count #\Newline string :end (min offset (length string)))))

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
;;;; Entity extraction
;;;; ------------------------------------------------------------------

(defun definition-p (form head)
  (and (consp form) (symbolp (car form)) (string= (token-name (car form)) head)))

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

(defun analyze-lisp-file (graph path)
  "Analyze the Lisp source file at PATH and write what it finds into GRAPH:
a :FILE entity; a :FUNCTION entity per top-level DEFUN and a :VARIABLE
entity per top-level DEFVAR/DEFPARAMETER, each with a :CONTAINS edge from
the file; and a :CALLS edge between two functions defined in this file
whenever one's body references the other. Returns the :FILE entity."
  (let* ((path-string (namestring path))
         (content (slurp-file path))
         (forms (read-forms-with-spans content))
         (file-entity (make-instance 'file-entity :name path-string)))
    (setp file-entity :path path-string)
    (setp file-entity :language :lisp)
    (add-entity graph file-entity)
    (let ((functions '()))  ; alist: name -> (entity . defun-form)
      (dolist (spec forms)
        (destructuring-bind (form start end) spec
          (cond
            ((definition-p form "defun")
             (let ((e (make-function-entity form start end path-string)))
               (add-entity graph e)
               (add-relationship graph (make-instance 'relationship :rel-type :contains
                                                        :from-id (id file-entity) :to-id (id e)))
               (push (cons (token-name (second form)) (cons e form)) functions)))
            ((or (definition-p form "defvar") (definition-p form "defparameter"))
             (let ((e (make-variable-entity form start end path-string)))
               (add-entity graph e)
               (add-relationship graph (make-instance 'relationship :rel-type :contains
                                                        :from-id (id file-entity) :to-id (id e))))))))
      (dolist (fn functions)
        (destructuring-bind (entity . form) (cdr fn)
          (dolist (callee-name (remove-duplicates (collect-call-names (cdddr form)) :test #'string=))
            (let ((callee (assoc callee-name functions :test #'string=)))
              (when callee
                (add-relationship graph (make-instance 'relationship :rel-type :calls
                                                         :from-id (id entity)
                                                         :to-id (id (cadr callee))))))))))
    file-entity))
