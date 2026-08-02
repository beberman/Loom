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

(defun intern-foreign-symbol-locally (condition)
  "Absorb a package prefix naming a package this image has never loaded.

The analyzer reads source belonging to workspaces it has not compiled, so
`utils:parse-config' is the normal case, not the exception: the reader signals
a PACKAGE-ERROR the moment a prefix names a package that is merely absent, and
one such form used to cost the whole file -- ANALYZE-FILE would catch it and
emit a single analysis-failed :FILE entity, so every definition in the file
became invisible to `find'.

The CONTINUE restart the reader offers here interns the symbol in *PACKAGE*
instead, which under READ-FORMS-WITH-SPANS is the throwaway package that is
deleted on the way out. That is exactly what the analyzer wants: nothing
downstream reads a symbol's home package -- TOKEN-NAME takes SYMBOL-NAME and
nothing else -- so the package prefix carries no information worth failing
over.

Only PACKAGE-ERROR is handled, and only when the restart exists. A file with a
genuinely broken form -- an unbalanced paren, a `#.' under *READ-EVAL* NIL --
still fails, and should: SS9.3's analysis-failed :FILE entity is the honest
answer there, where here it was a false report of a file Loom could read."
  (let ((restart (find-restart 'continue condition)))
    (when restart (invoke-restart restart))))

(defun read-forms-with-spans (content)
  "Every top-level form in CONTENT, read with *READ-EVAL* disabled and in a
throwaway package so foreign package prefixes and keywords intern safely
without touching any real package. Returns a list of (FORM START-LINE
END-LINE).

One stream over the whole string, seeked with FILE-POSITION, rather than a
fresh bounded stream per form. A stream made with MAKE-STRING-INPUT-STREAM over
a sub-range leaves FILE-POSITION ambiguous -- implementations disagree on
whether it counts from the start of the string or from the start of the range,
and SBCL builds disagree with each other. Reading a form and adding the offset
back therefore double-counts on half of them: the first form lands correctly
because both conventions agree at zero, the second lands past its own end, and
the walk quietly stops two forms in with no condition signalled. Here the range
is always the whole string, so there is nothing for the two conventions to
disagree about."
  (let ((stream (make-string-input-stream content))
        (len (length content))
        (results '())
        (*package* (make-package (gensym "LOOM-ANALYZER-SCRATCH-") :use nil))
        (*read-eval* nil))
    (unwind-protect
         (handler-bind ((package-error #'intern-foreign-symbol-locally))
           (loop
             (let ((start (skip-whitespace-and-comments content (file-position stream))))
               (when (>= start len) (return))
               (file-position stream start)
               ;; READ-PRESERVING-WHITESPACE, not READ: plain READ consumes one
               ;; trailing whitespace char it never needed, which would throw
               ;; off the end position by one whenever a form is followed by a
               ;; newline.
               (let ((form (read-preserving-whitespace stream nil :eof)))
                 (when (eq form :eof) (return))
                 (let ((end (file-position stream)))
                   (push (list form (offset-line content start) (offset-line content end))
                         results)
                   ;; A read that did not advance would spin forever. It should
                   ;; not happen; costing one comparison to be sure it cannot
                   ;; is cheaper than a watcher thread that never returns.
                   (when (<= end start) (return)))))))
      (delete-package *package*))
    (nreverse results)))

(defun token-name (x)
  "A plain, package-independent lowercase name for a symbol or a lambda-list
element X (which may be a destructuring pair like (KEY DEFAULT))."
  (cond ((symbolp x) (string-downcase (symbol-name x)))
        ((consp x) (token-name (car x)))
        (t (princ-to-string x))))

(defun collect-call-names (body)
  "Every operator-position symbol name appearing anywhere in BODY, a sequence
of forms, skipping quoted data so a literal list is never mistaken for a call
site.

A sequence of forms, not one form: handed (value) -- the body of a method
whose whole body is a variable -- treating it as a form claims a call to
value.

Only the head of a form is an operator. Walking a form's tail as though it
were itself a form -- (cdr '(f x)) is (x), whose head is x -- reports every
argument as a call, so (repo-graph r) claimed a call to r. Harmless while the
names went nowhere; not harmless once dispatched calls fan out to every
candidate method, because a parameter that happens to share a name with a
generic would manufacture edges to all of it."
  (let ((names '()))
    (labels ((walk (form)
               (when (consp form)
                 (let ((head (car form)))
                   (unless (and (symbolp head) (string= (token-name head) "quote"))
                     (when (symbolp head) (push (token-name head) names))
                     (when (consp head) (walk head))   ; ((lambda ...) x)
                     ;; The arguments are forms in their own right. LOOP over
                     ;; the tail rather than recursing on it, and stop at a
                     ;; dotted end rather than treating the atom as a form.
                     (loop for tail = (cdr form) then (cdr tail)
                           while (consp tail)
                           do (walk (car tail))))))))
      (dolist (form body) (walk form)))
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

(defparameter *reader-artifacts* '("quasiquote" "unquote" "unquote-splicing")
  "Names that are an implementation's reader, not the program's vocabulary.

SBCL expands a backquote into (SB-INT:QUASIQUOTE ...), which is a real symbol
in a real package and so survives STANDARD-OPERATOR-P, leaving every macro
that writes a template claiming to call something named quasiquote. Filtered
by name rather than by package so a different implementation's spelling of the
same idea does not need a different rule.")

(defun reader-artifact-p (name)
  (member name *reader-artifacts* :test #'string=))

;;;; ------------------------------------------------------------------
;;;; Definer call sites (ARCH-0002 R2)
;;;;
;;;; A top-level form that is neither a definition nor a declaration is a call
;;;; to something, and it may be a call to a macro that defines a name --
;;;; (test resolve-links-a-call ...) is the case that matters, and it defines
;;;; a name appearing nowhere as a DEFUN. Whether it does is not a question
;;;; this analyzer can answer: the macro is routinely in another file, or, for
;;;; fiveam, outside the tree entirely, and RULE-0002 keeps an analyzer
;;;; file-scoped and stateless. So the analyzer records the call and
;;;; LOOM-GRAPH:RESOLVE-GENERATED-DEFINITIONS decides what it defined -- the
;;;; shape :CALL-NAMES and RESOLVE-CALLS already have, for the same reason.
;;;; ------------------------------------------------------------------

(defparameter *definition-heads*
  '("defun" "defvar" "defparameter" "defclass" "define-condition" "defstruct"
    "defgeneric" "defmethod" "defmacro")
  "The heads ANALYZE-FILE's pass-1 COND turns into entities.

Kept beside the COND rather than inside it because the same list answers a
second question -- which top-level forms are *not* call sites -- and having
the two disagree would mean a DEFUN being offered to the macro registry.
Adding a clause to that COND means adding its head here.")

(defparameter *declaration-heads*
  '("in-package" "defpackage" "declaim" "proclaim" "eval-when"
    "defconstant" "deftype" "defsetf" "define-symbol-macro")
  "Heads that define nothing this ontology models and are not calls either.

Excluded from :DEFINER-CALL-SITES to keep the property about what it is for.
Getting this list wrong in the inclusive direction costs nothing -- an
operator matching no registry entry is left alone -- so it errs toward
recording, and only the forms that plainly declare rather than call are here.")

(defun call-site-head-p (name)
  "True when NAME is a head ANALYZE-FILE already accounts for."
  (or (member name *definition-heads* :test #'string=)
      (member name *declaration-heads* :test #'string=)))

(defun argument-token (x)
  "One argument of a call site, rendered as a string.

Downcased for the reason TOKEN-NAME downcases: nothing downstream reads a
symbol's home package or its case, and a registry lookup has to match a name
as a human wrote it in source."
  (cond ((symbolp x) (token-name x))
        ((stringp x) x)
        (t (string-downcase (princ-to-string x)))))

(defun definer-call-site (form start end)
  "One :DEFINER-CALL-SITES entry for the top-level call FORM.

:SYMBOL-ARGUMENTS is the part that is easy to leave out and expensive to miss.
The registry says which argument names the entity; nothing says the call site
put a symbol there, and minting from (test (make-name i) ...) would produce a
garbage-named entity that resolves nothing and never goes away. Rendering
every argument to a string alone would not let resolution tell that case from
a real one -- a string literal renders to something that looks like a name --
so which positions held a bare symbol is recorded as its own fact.

Indices count the operator as 0, so they line up with a registry entry's
:NAME-INDEX without either side having to remember an offset."
  (let ((arguments (rest form)))
    (list :operator (token-name (car form))
          :start-line start
          :end-line end
          :arguments (mapcar #'argument-token arguments)
          ;; NIL and a keyword are symbols and neither one ever names a
          ;; definition -- (def-suite code-ontology :in all-tests) has a
          ;; keyword in position 2 -- so neither counts as a name the site
          ;; supplied.
          :symbol-arguments (loop for argument in arguments
                                  for index from 1
                                  when (and argument (symbolp argument)
                                            (not (keywordp argument)))
                                    collect index)
          ;; The whole argument list, not a guessed body: ARCH-0002 has the
          ;; walk happen here precisely so resolution never has to know which
          ;; argument the body starts at. A non-body argument -- a bare name, a
          ;; docstring -- contains no calls to lose.
          :call-names (remove-if (lambda (name)
                                   (or (standard-operator-p name)
                                       (reader-artifact-p name)))
                                 (remove-duplicates (collect-call-names arguments)
                                                    :test #'string=)))))


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

;;;; ------------------------------------------------------------------
;;;; CLOS and structure definitions (ARCH-0001)
;;;;
;;;; Everything here reads one form and returns entities. Nothing resolves a
;;;; name: a superclass, a specializer and a generic can each be defined in
;;;; another file, so each is recorded as a property the analyzer writes once
;;;; and never rewrites, and LOOM-GRAPH derives the edges from it on every
;;;; pass. That is DEC-0003 applied to three more kinds of name, and it is
;;;; what lets an edge destroyed by a retract come back.
;;;; ------------------------------------------------------------------

(defun lambda-list-parameters (lambda-list)
  "The required parameters of LAMBDA-LIST, stopping at the first & marker."
  (loop for param in lambda-list
        for token = (token-name param)
        until (and (plusp (length token)) (char= #\& (char token 0)))
        collect param))

(defun specializer-name (parameter)
  "What PARAMETER dispatches on: a class name, a rendered EQL specializer, or
\"t\" for a parameter that does not specialise."
  (if (consp parameter)
      (let ((specializer (second parameter)))
        (cond ((null specializer) "t")
              ((consp specializer)          ; (eql :foo), (eql 3)
               (format nil "(~{~a~^ ~})" (mapcar #'token-name specializer)))
              (t (token-name specializer))))
      "t"))

(defun definition-name (designator)
  "A definition's name as a string, rendering (setf foo) as \"(setf foo)\" so
a setf method keeps an identity distinct from its reader."
  (if (consp designator)
      (format nil "(~{~a~^ ~})" (mapcar #'token-name designator))
      (token-name designator)))

(defun make-class-entity (name kind slots superclasses start end path)
  (make-instance 'class-entity
                 :name name
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :kind kind
                                    :slots slots
                                    :superclass-names superclasses
                                    :language :lisp))))

(defun make-interface-entity (name start end path &key members generated-by)
  "A generic function: a declared protocol with no implementation of its own."
  (make-instance 'interface-entity
                 :name name
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :members members
                                    :generated-by generated-by
                                    :language :lisp))))

(defun make-method-entity (name qualifier specializers generic arguments start end path)
  (make-instance 'method-entity
                 :name name
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :qualifier qualifier
                                    :specializers specializers
                                    :generic-function generic
                                    :arguments arguments
                                    :language :lisp))))

;;; --- what a macro's template says it defines (ARCH-0002 R1) --------
;;;
;;; REQ-0003 fixes where template reading stops, and the line is not a
;;; heuristic that could be sharpened later: the template contains a DEFUN,
;;; DEFCLASS or DEFMETHOD, and the name position is a bare substitution of one
;;; of the macro's own parameters. Everything past that -- a name assembled
;;; with INTERN or FORMAT, a gensym, a template expanding into another macro --
;;; is not hard to read but impossible to read without running the code that
;;; computes it, and this analyzer executes nothing (RULE-0002 and *READ-EVAL*
;;; NIL both). A macro on the far side of the line is reported, not
;;; approximated.

(defparameter *template-definer-heads*
  '(("defun"    . :function)
    ("defclass" . :class)
    ("defmethod" . :method))
  "Template head -> the entity type a call to the macro would define.
DEFVAR and DEFPARAMETER are absent only because nothing has needed them; this
is a table, so adding a form is adding a row rather than a code path.")

(defparameter *unquote-heads* '("unquote" "unquote-splicing" "comma")
  "Heads an implementation may read `,X' or `,@X' into, when it uses a list.")

(defparameter *comma-accessors*
  (let ((package (find-package "SB-INT")))
    (when package
      (let ((predicate (find-symbol "COMMA-P" package))
            (accessor  (find-symbol "COMMA-EXPR" package)))
        (when (and predicate accessor (fboundp predicate) (fboundp accessor))
          (cons (symbol-function predicate) (symbol-function accessor))))))
  "How to read this implementation's object form of a source comma, as
(PREDICATE . ACCESSOR), or NIL when commas read as ordinary lists.

The reader's representation of `,X' is not specified, and implementations
differ in kind rather than merely in spelling: several produce the list
(UNQUOTE X), while SBCL produces a structure whose slot holds X. Looked up by
name at load time rather than named in source, so this file still compiles
where no such structure exists. That is the standing lesson of FILE-POSITION
in READ-FORMS-WITH-SPANS -- an unspecified detail is not something to build
on without a path for the case where it differs -- and the same judgement
*READER-ARTIFACTS* makes one level up.")

(defun comma-symbol (x)
  "The downcased name of the symbol S in a source `,S', or NIL when X is not
one.

A splice, `,@S', is accepted alongside a plain unquote. Telling them apart
would cost a second implementation-specific reader for nothing: a DEFUN's name
position takes one form, so a splice there is not valid Lisp that this rule
would otherwise have to reject."
  (let ((expression
          (cond ((and (consp x) (symbolp (car x)) (car x)
                      (member (token-name (car x)) *unquote-heads* :test #'string=))
                 (second x))
                ((and *comma-accessors* (funcall (car *comma-accessors*) x))
                 (funcall (cdr *comma-accessors*) x)))))
    (when (and expression (symbolp expression) (not (keywordp expression)))
      (token-name expression))))

(defun template-definer-form (body)
  "The first DEFUN, DEFCLASS or DEFMETHOD form anywhere in BODY, and the entity
type it would produce. Two values, both NIL when there is none.

Walked rather than matched at the top, because a template is routinely
wrapped: DEFENTITY's DEFCLASS sits inside a LET inside the backquote, and
matching only the outermost form would report it as defining nothing. Quoted
data is skipped for the reason COLLECT-CALL-NAMES skips it -- a literal list
is data, not a form."
  (let ((found nil) (found-type nil))
    (labels ((walk (x)
               (when (and (consp x) (null found))
                 (let* ((head (car x))
                        (name (and head (symbolp head) (token-name head)))
                        (entry (and name (assoc name *template-definer-heads*
                                                :test #'string=))))
                   (cond ((and name (string= name "quote")))
                         (entry (setf found x found-type (cdr entry)))
                         (t (when (consp head) (walk head))
                            (loop for tail = (cdr x) then (cdr tail)
                                  while (consp tail)
                                  do (walk (car tail)))))))))
      (mapc #'walk body))
    (values found found-type)))

(defun macro-parameter-names (lambda-list)
  "The macro's own parameter names, in call order, skipping the & markers.

Position here is position in the call, which is what makes
:GENERATOR-NAME-INDEX derivable without expanding anything: a marker consumes
no argument, so the nth parameter of this list is the (n+1)th element of the
call form."
  (loop for element in lambda-list
        for token = (token-name element)
        unless (and (plusp (length token)) (char= #\& (char token 0)))
          collect token))

(defun macro-body-index (lambda-list)
  "The call-form index at which a call to this macro's body begins, or NIL.

Taken from the &BODY or &REST parameter rather than from wherever the template
splices, because that is the part the lambda list guarantees: everything from
that argument on is body. A macro with neither declares no body, and nothing
downstream needs one -- ARCH-0002 has the analyzer pre-walk the whole argument
list precisely so resolution never has to know where the body starts."
  (let ((index 1))
    (dolist (element lambda-list)
      (let ((token (token-name element)))
        (cond ((or (string= token "&body") (string= token "&rest"))
               (return-from macro-body-index index))
              ((and (plusp (length token)) (char= #\& (char token 0))))
              (t (incf index)))))
    nil))

(defun macro-generator-properties (form)
  "What a DEFMACRO's template says a call to it defines, as properties.

Three outcomes, per ARCH-0002 R1, and the third is the one that is easy to get
wrong. A match records the three generator properties. A near-miss -- one of
the three forms present, but the name position something other than a bare
parameter substitution -- records :DEFINER-STATUS :UNHANDLED, so a definer
Loom cannot characterise is counted rather than silently dropped. A template
containing none of the three records nothing at all: a wrapper macro claims to
define nothing, and flagging it would put every WITH-LOCK in the tree into a
count that exists to be read and acted on."
  (multiple-value-bind (definer entity-type) (template-definer-form (cdddr form))
    (when definer
      (let* ((parameters (macro-parameter-names (third form)))
             (substituted (comma-symbol (second definer)))
             (position (and substituted
                            (position substituted parameters :test #'string=))))
        (if position
            (list :generator-entity-type entity-type
                  :generator-name-index (1+ position)
                  :generator-body-index (macro-body-index (third form)))
            (list :definer-status :unhandled))))))

(defun make-macro-entity (form start end path)
  "A macro, indexed as a :FUNCTION carrying :MACRO-P.
Findable and documentable; what a :CALLS edge into one means is left open by
ARCH-0001, and calls made inside its expansion remain unattributed.

The generator properties are appended rather than merged conditionally: a
macro whose template defines nothing contributes an empty list, which is the
right answer and not an omission."
  (make-instance 'function-entity
                 :name (definition-name (second form))
                 :origin-file path
                 :properties (properties-table
                              (append
                               (list :file path
                                     :start-line start
                                     :end-line end
                                     :macro-p t
                                     :arguments (mapcar #'token-name (third form))
                                     :language :lisp)
                               (macro-generator-properties form)))))

(defun method-body (form)
  "The body of a DEFMETHOD: everything after the qualifier and lambda list.
The lambda list has to go, or every specialised parameter would read as a call
site -- ((stream stream) (object entity)) is full of symbols in car position."
  (let ((tail (cddr form)))
    (when (and (first tail) (symbolp (first tail))) (pop tail))
    (rest tail)))

(defun make-generated-function-entity (name start end path generated-by)
  "An accessor, constructor, predicate or copier a DEFSTRUCT defines.

A plain function, unlike a DEFCLASS accessor, which is a generic function and
so an :INTERFACE. Located at the form that generates it, because that is the
region an agent has to open to change it, and marked so a derived name can be
told from a written one."
  (make-instance 'function-entity
                 :name name
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :generated-by generated-by
                                    :language :lisp))))

;;; --- defclass / define-condition ----------------------------------

(defun slot-accessor-names (slot)
  "Every generic function a DEFCLASS slot specifier declares.

:ACCESSOR, :READER and :WRITER each name a function that appears nowhere else
in the source, which is why a reference to one resolves to nothing today --
DEC-0002's mention of id-derived-p is exactly this."
  (when (consp slot)
    (loop for (key value) on (rest slot) by #'cddr
          when (and value (symbolp key)
                    (member (token-name key) '("accessor" "reader" "writer")
                            :test #'string=))
            collect (token-name value))))

(defun class-definition-entities (form kind start end path)
  "The :CLASS for a DEFCLASS or DEFINE-CONDITION, and an :INTERFACE for each
accessor its slots declare."
  (let* ((name (definition-name (second form)))
         (superclasses (mapcar #'token-name (third form)))
         (slot-specs (remove-if-not (lambda (x) (or (symbolp x) (consp x)))
                                    (fourth form)))
         (class (make-class-entity name kind
                                   (mapcar #'token-name slot-specs)
                                   superclasses start end path)))
    (cons class
          (loop for slot in slot-specs
                append (loop for accessor in (slot-accessor-names slot)
                             collect (make-interface-entity accessor start end path
                                                            :generated-by name))))))

;;; --- defstruct ----------------------------------------------------

(defun defstruct-options (form)
  "Values: the structure name, and its options as a list of lists.
DEFSTRUCT names itself either bare or as (name option...), and an option is
either a bare keyword or a list."
  (let ((designator (second form)))
    (if (consp designator)
        (values (token-name (first designator))
                (mapcar (lambda (o) (if (consp o) o (list o))) (rest designator)))
        (values (token-name designator) '()))))

(defun defstruct-option-value (options key default)
  "The value DEFSTRUCT option KEY carries, or DEFAULT when it is absent.
A bare option -- (:conc-name) with nothing after it -- means NIL, which for
:CONC-NAME is the documented way to ask for unprefixed accessors."
  (let ((option (find key options :key (lambda (o) (token-name (first o)))
                                  :test #'string=)))
    (cond ((null option) default)
          ((null (rest option)) nil)
          (t (second option)))))

(defun defstruct-slot-specs (form)
  "The slot specifiers of FORM, skipping the documentation string DEFSTRUCT
allows between the name and the first slot."
  (let ((tail (cddr form)))
    (when (stringp (first tail)) (pop tail))
    tail))

(defun defstruct-generated-names (form)
  "Every name a DEFSTRUCT form brings into existence, with the slot list.

Honouring the options rather than assuming the defaults is not pedantry:
eleven of Loom's sixteen structures rename something, and a guessed name
resolves to nothing exactly where the real one is called most."
  (multiple-value-bind (name options) (defstruct-options form)
    (let* ((slots (mapcar #'token-name (defstruct-slot-specs form)))
           (conc (let ((declared (defstruct-option-value options "conc-name" :absent)))
                   (cond ((eq declared :absent) (concatenate 'string name "-"))
                         ((null declared) "")
                         (t (token-name declared)))))
           (names '()))
      ;; :CONSTRUCTOR may appear more than once, and (:constructor nil)
      ;; suppresses the default rather than naming one.
      (let ((constructors (remove-if-not
                           (lambda (o) (string= "constructor" (token-name (first o))))
                           options)))
        (if constructors
            (dolist (option constructors)
              (let ((constructor (second option)))
                (when constructor (push (token-name constructor) names))))
            (push (concatenate 'string "make-" name) names)))
      (let ((predicate (defstruct-option-value options "predicate" :absent)))
        (cond ((eq predicate :absent) (push (concatenate 'string name "-p") names))
              (predicate (push (token-name predicate) names))))
      (let ((copier (defstruct-option-value options "copier" :absent)))
        (cond ((eq copier :absent) (push (concatenate 'string "copy-" name) names))
              (copier (push (token-name copier) names))))
      (dolist (slot slots)
        (push (concatenate 'string conc slot) names))
      (values name slots (nreverse names)
              (let ((include (defstruct-option-value options "include" nil)))
                (and include (list (token-name include))))))))

(defun struct-definition-entities (form start end path)
  "The :CLASS for a DEFSTRUCT, and a :FUNCTION for every name it generates."
  (multiple-value-bind (name slots generated superclasses)
      (defstruct-generated-names form)
    (cons (make-class-entity name :struct slots superclasses start end path)
          (loop for generated-name in generated
                collect (make-generated-function-entity generated-name start end path
                                                        name)))))

;;; --- defgeneric / defmethod ---------------------------------------

(defun generic-definition-entity (form start end path)
  (make-interface-entity (definition-name (second form)) start end path
                         :members (mapcar #'token-name
                                          (lambda-list-parameters (third form)))))

(defun method-definition-entity (form start end path)
  "The :METHOD for a DEFMETHOD, keyed by name, qualifier and specializers.

The qualifier is whatever sits between the name and the lambda list, which is
how a method is told from an :AROUND on the same specializers. NIL is a list,
so an empty lambda list is not mistaken for one."
  (let* ((name (definition-name (second form)))
         (tail (cddr form))
         (qualifier (when (and (first tail) (symbolp (first tail))) (first tail)))
         (lambda-list (if qualifier (second tail) (first tail)))
         (parameters (lambda-list-parameters lambda-list)))
    (make-method-entity name
                        (when qualifier
                          (intern (string-upcase (token-name qualifier)) :keyword))
                        (mapcar #'specializer-name parameters)
                        name                    ; the generic it implements
                        (mapcar #'token-name lambda-list)
                        start end path)))

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
        (definitions '())       ; every entity, in source order
        (local-functions '())   ; alist: name -> entity, for exact local calls
        (callables '())         ; list of (entity . body), things with bodies
        (call-sites '())        ; :DEFINER-CALL-SITES entries, in source order
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
    ;;
    ;; A DEFUN and a DEFSTRUCT accessor go into LOCAL-FUNCTIONS, because a call
    ;; to either names exactly one definition and can be linked here. A
    ;; DEFMETHOD does not: a call names the generic, and which method runs is a
    ;; runtime question, so those edges are left for resolution to fan out.
    (flet ((note-definition (entity &key local body)
             (push entity definitions)
             (when local (push (cons (name entity) entity) local-functions))
             (when body (push (cons entity body) callables))))
      (dolist (spec forms)
        (destructuring-bind (form start end) spec
          (cond
            ((definition-p form "defun")
             (note-definition (make-function-entity form start end path)
                              :local t :body (cdddr form)))
            ((definition-p form "defmacro")
             (note-definition (make-macro-entity form start end path)
                              :local t :body (cdddr form)))
            ((or (definition-p form "defvar") (definition-p form "defparameter"))
             (note-definition (make-variable-entity form start end path)))
            ((definition-p form "defclass")
             (dolist (e (class-definition-entities form :class start end path))
               (note-definition e)))
            ((definition-p form "define-condition")
             (dolist (e (class-definition-entities form :condition start end path))
               (note-definition e)))
            ((definition-p form "defstruct")
             (let ((entities (struct-definition-entities form start end path)))
               (note-definition (first entities))
               ;; The generated names are ordinary functions defined by this
               ;; file, so a call to one inside it resolves here rather than
               ;; waiting for the workspace.
               (dolist (e (rest entities)) (note-definition e :local t))))
            ((definition-p form "defgeneric")
             (note-definition (generic-definition-entity form start end path)))
            ((definition-p form "defmethod")
             (note-definition (method-definition-entity form start end path)
                              :body (method-body form)))
            ;; Everything else is a call, and may be a call to a definer
            ;; macro. Recorded, never judged: the judgement needs the whole
            ;; workspace (ARCH-0002).
            ((and (consp form) (symbolp (car form)) (car form)
                  (not (call-site-head-p (token-name (car form)))))
             (push (definer-call-site form start end) call-sites))))))
    (setf definitions (nreverse definitions))
    (setp file :definer-call-sites (nreverse call-sites))

    ;; --- pass 2: who each function calls ----------------------------
    ;; A name resolves here only if this same file defines it. Anything else
    ;; that is not standard Common Lisp is recorded on the entity as a call
    ;; name, per SS8.3: "unresolved calls are recorded as a property, not a
    ;; dangling edge." LOOM-GRAPH:RESOLVE-CALLS is what turns those into real
    ;; edges once the whole workspace is in one graph -- the analyzer cannot,
    ;; because it sees one file and holds no state.
    ;;
    ;; :CALL-NAMES, not :UNRESOLVED-CALLS. What this pass knows is which names
    ;; this file does not define; whether they resolve anywhere is a question
    ;; only the workspace can answer, and RESOLVE-CALLS derives
    ;; :UNRESOLVED-CALLS from this list every pass. Writing the answer here
    ;; would destroy the question: resolution used to consume the property, so
    ;; a caller whose callee had resolved no longer recorded calling it, and
    ;; an edge destroyed by retracting the callee's file could never be
    ;; rebuilt.
    (let ((local-calls '()))      ; list of (caller-entity . callee-entity)
      (dolist (entry callables)
        (destructuring-bind (caller . body) entry
          (let ((foreign '()))
            (dolist (callee-name (remove-duplicates (collect-call-names body)
                                                    :test #'string=))
              (let ((callee (cdr (assoc callee-name local-functions :test #'string=))))
                (cond ((and callee (not (eq callee caller)))
                       (push (cons caller callee) local-calls))
                      ((standard-operator-p callee-name))
                      ((reader-artifact-p callee-name))
                      ((string= callee-name (name caller)))   ; direct recursion
                      (t (push callee-name foreign)))))
            (setp caller :call-names (nreverse foreign)))))

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

;;;; ------------------------------------------------------------------
;;;; The macro registry (ARCH-0002 R3)
;;;;
;;;; The fourth registry in this codebase, and it follows the three that came
;;;; before -- *analyzers*/REGISTER-ANALYZER and
;;;; *document-type-directories*/REGISTER-DOCUMENT-TYPE -- because REQ-0003
;;;; asked for exactly that: a special variable holding a table plus a
;;;; function that adds to it, so extending behaviour is pushing an entry
;;;; rather than editing a function.
;;;;
;;;; It exists because a macro's own source is not always available. In-tree
;;;; macros feed the same decision from their templates (see
;;;; MACRO-GENERATOR-PROPERTIES above), but fiveam's TEST and DEF-SUITE are
;;;; defined outside the indexed tree entirely, and no amount of reading
;;;; inside the workspace will ever see them. They are also the two most
;;;; common macro calls in every src/*/test/*.lisp, and the reason the :TEST
;;;; entity type has never held a fact.
;;;;
;;;; The table is here and the pass that reads it is in LOOM-GRAPH, which
;;;; cannot see this package. LOOM-WORKSPACE, the first system that uses both,
;;;; is what hands the table across.
;;;; ------------------------------------------------------------------

(defparameter *macro-generators* (make-hash-table :test #'equal)
  "Downcased macro name -> list of generator entries.

A list rather than one entry because two packages may name a macro
identically, and a resolution pass that matched a call site against several
entries has to leave it alone rather than pick one -- CON-0001 in the same
form RESOLVE-CALLS applies it. Each entry is a plist carrying :NAME,
:PACKAGE, :ENTITY-TYPE, :NAME-INDEX, :BODY-INDEX and :FRAMEWORK; the indices
count the operator as 0.")

(defun register-macro-generator (name &key package entity-type name-index
                                           body-index framework)
  "Declare what a call to macro NAME defines.

Replaces an entry for the same name and package rather than accumulating a
second one, which is what makes re-evaluating this file in a live image a
no-op -- the same judgement REGISTER-ANALYZER and REGISTER-DOCUMENT-TYPE
make, and for the same reason."
  (let* ((key (string-downcase (string name)))
         (package-name (and package (string-downcase (string package))))
         (entry (list :name key :package package-name
                      :entity-type entity-type
                      :name-index name-index :body-index body-index
                      :framework framework)))
    (setf (gethash key *macro-generators*)
          (cons entry (remove package-name (gethash key *macro-generators*)
                              :key (lambda (e) (getf e :package))
                              :test #'equal)))
    entry))

(defun macro-generators-for (name)
  "Every registered entry for a macro called NAME."
  (gethash (string-downcase name) *macro-generators*))

;;; fiveam, shipped populated. DEF-SUITE deliberately declares :ENTITY-TYPE
;;; NIL: a suite is not a test and the ontology declares no :SUITE type, so a
;;; DEF-SUITE call mints nothing. Its entry exists only so the call is
;;; recognised as accounted for rather than reported as a definer nobody
;;; characterised. Populating a :TEST's :SUITE property from DEF-SUITE and
;;; IN-SUITE context is real work and ARCH-0002 defers it explicitly.
(register-macro-generator "test" :package "fiveam" :entity-type :test
                                 :name-index 1 :body-index 2 :framework :fiveam)
(register-macro-generator "def-suite" :package "fiveam" :entity-type nil
                                      :name-index 1 :body-index 2 :framework :fiveam)

;;;; The one registered instance. Stateless, so one serves every file and
;;;; every workspace.
(register-analyzer (make-instance 'lisp-analyzer))
