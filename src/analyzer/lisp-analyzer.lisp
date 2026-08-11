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
;;;; Naming the things a form mentions
;;;; ------------------------------------------------------------------
;;;;
;;;; The reader itself lives in lisp-reader.lisp. READ-FORMS-WITH-SPANS,
;;;; ELEMENT-SPANS, SKIP-WHITESPACE-AND-COMMENTS and
;;;; INTERN-FOREIGN-SYMBOL-LOCALLY stood here until ARCH-0013 R7 replaced
;;;; them with READ-SOURCE -- 169 lines whose whole burden was recovering, by
;;;; re-reading text and counting characters, what a conforming reader
;;;; reports directly.

(defun token-name (x)
  "A plain, package-independent lowercase name for a symbol or a lambda-list
element X (which may be a destructuring pair like (KEY DEFAULT))."
  (cond ((symbolp x) (string-downcase (symbol-name x)))
        ((consp x) (token-name (car x)))
        (t (princ-to-string x))))

(defun collect-call-names (body &key reading)
  "Two values: every operator-position symbol name appearing anywhere in BODY,
a sequence of forms, skipping quoted data so a literal list is never mistaken
for a call site; and the package prefixes those sites wrote, as a list of
\(NAME . PACKAGE) conses in the same order.

The second value is REQ-0019 R2 arriving where it can be used, and it is
evidence rather than an answer. `utils:parse-config' and a local PARSE-CONFIG
produce the same first value -- TOKEN-NAME reads SYMBOL-NAME and nothing else,
which is the whole reason RESOLVE-CALLS cannot currently tell two same-named
definitions apart -- and until now the prefix was destroyed at read time by
INTERN-FOREIGN-SYMBOL-LOCALLY, so there was nothing to record. What resolution
does with it is REQ-0015's question and this pass deliberately does not answer
it: recording the fact must not move an edge count, or a reader change and a
resolution change become one unattributable movement (PLAN-0013 step 6).

Only sites that wrote a prefix appear, so the list is short where :CALL-NAMES
is long -- 241 qualified operator occurrences against 4867 call names on this
tree. A bare name records nothing rather than recording NIL, because \"no
prefix was written\" is what absence already means.

READING is a keyword because a caller that has none is not made to lie about
one; with no READING the second value is NIL and the first is exactly what it
always was.

A sequence of forms, not one form: handed (value) -- the body of a method
whose whole body is a variable -- treating it as a form claims a call to
value.

Only the head of a form is an operator. Walking a form's tail as though it
were itself a form -- (cdr '(f x)) is (x), whose head is x -- reports every
argument as a call, so (repo-graph r) claimed a call to r. Harmless while the
names went nowhere; not harmless once dispatched calls fan out to every
candidate method, because a parameter that happens to share a name with a
generic would manufacture edges to all of it.

One operator is excepted, and one only: FUNCTION. #'f reads as (FUNCTION F),
which is the single form whose argument position holds a name rather than a
value, so the rule above dropped it and left the callee with no incoming edge
at all (BUG-0011). What that exception recovers is exactly one thing -- a
quotation appearing anywhere inside a body that reaches this function, so
(apply #'make-selector args) and (sort xs #'less-p) now each contribute a name.
The head-only discipline is otherwise unchanged and must stay unchanged, for
the reason the paragraph above gives: this is one special case, not a policy.
Two shapes of argument are names, a bare symbol and (setf f); everything else,
a lambda above all, contributes no name and is still walked for the calls
inside it.

Which forms are quotation is QUOTATIONP's question, and both its clauses are
ARCH-0013 R12. It asks the reader first -- 'x and #'f are the one class of
form kind a reader is entitled to know, because they really are syntax where
DEFUN is not -- and falls back to the name comparison only for a list a
program wrote out itself, and then only when no site qualified the head. Two
imprecisions this docstring used to disclose are gone with it: a literal
(some-pkg:function g) no longer contributes \"g\", and a (some-pkg:quote x) no
longer suppresses the walk of its own contents. Both were accepted under
PLAN-0011 R-7 on the grounds that \"the analyzer holds no package knowledge to
do better\"; REQ-0019 R2 is that it now does.

What it does not recover, because the designator never arrives here at all: a
callback stored in a slot. ANALYZE-FILE hands NOTE-DEFINITION no :body for
DEFVAR, DEFPARAMETER, DEFCLASS or DEFINE-CONDITION, and a DEFUN's body is
(cdddr form), which excludes the lambda list -- so a quotation in an initform
or in a lambda-list default is invisible to every clause below, and no wording
of this one can change that. BUG-0017."
  (let ((names '())
        (qualified '()))
    (labels ((note (symbol name)
               ;; The prefix goes on the list only when the site wrote one.
               ;; FORM-PACKAGE is already NIL for a bare name and for a symbol
               ;; from some other read, so this needs no guard of its own.
               (let ((package (and reading (form-package reading symbol))))
                 (when package (push (cons name package) qualified))))
             (unqualified-cl-p (symbol)
               ;; True when SYMBOL could be the CL operator its name suggests:
               ;; the site wrote no prefix, or wrote one naming COMMON-LISP.
               ;; A prefix naming anything else is positive evidence that it is
               ;; not -- which is the discrimination REQ-0019 R2 bought and
               ;; ARCH-0013 R12 spends here.
               (let ((package (and reading (form-package reading symbol))))
                 (or (null package)
                     (member package '("cl" "common-lisp") :test #'string=))))
             (quotationp (form kind)
               ;; ARCH-0013 R12. Two ways a form is quotation, and the order
               ;; matters: the reader's own answer first, because it is the one
               ;; class of form kind a reader is entitled to know -- 'x really
               ;; did come from a reader macro and no program wrote that list
               ;; out. Only when the reader has nothing to say does the name
               ;; comparison run, and then only for a head no site qualified.
               ;;
               ;; What this retires is two imprecisions COLLECT-CALL-NAMES has
               ;; disclosed in its own docstring since PLAN-0011: a literal
               ;; (some-pkg:function g) matched the quotation test and
               ;; contributed "g", a visible false positive; and
               ;; (some-pkg:quote x) was taken for quoted data so everything
               ;; inside it went unwalked, a silent miss. Both were accepted
               ;; because "the analyzer holds no package knowledge to do
               ;; better." It does now.
               (let ((marked (and reading (form-reader-macro reading form)))
                     (head (car form)))
                 (if marked
                     (eq marked kind)
                     (and (symbolp head)
                          (string= (token-name head)
                                   (ecase kind (:quote "quote") (:function "function")))
                          (unqualified-cl-p head)))))
             (walk (form)
               (when (consp form)
                 (let ((head (car form)))
                   (unless (quotationp form :quote)
                     ;; BUG-0020. A keyword can never name a function in Common
                     ;; Lisp, so a list whose head is one is a declaration, a
                     ;; plist entry or a CASE clause -- never a call. The test
                     ;; is on the symbol rather than on the name because
                     ;; TOKEN-NAME renders :FILE and FILE identically, which is
                     ;; why nothing downstream could tell
                     ;; (:unresolved-references list) from a call and why the
                     ;; five names DEFENTITY's property declarations orphan
                     ;; happen to match real functions in loom-analyzer and
                     ;; loom-graph.
                     (when (and (symbolp head) (not (keywordp head)))
                       (let ((name (token-name head)))
                         (push name names)
                         (note head name)))
                     ;; The one exception to head-only, and only for FUNCTION.
                     ;; (consp (cdr form)) with (null (cddr form)) is an arity
                     ;; test and nothing else: one argument and no more, which
                     ;; is what a quotation has and what an ftype specifier's
                     ;; (function (arg) result) does not. The arity test stays
                     ;; even where the reader marked the form, because #'x can
                     ;; only ever have one argument and a form that does not is
                     ;; therefore not one -- belt and braces over a table.
                     ;;
                     ;; What no longer holds is the docstring's old admission
                     ;; that a one-argument (some-pkg:function g) matches and
                     ;; records "g" because "the analyzer holds no package
                     ;; knowledge to do better." QUOTATIONP asks the reader
                     ;; first and the written prefix second, so it does.
                     (when (and (quotationp form :function)
                                (consp (cdr form))
                                (null (cddr form)))
                       (let ((designator (second form)))
                         (cond ((and designator (symbolp designator)
                                     (not (keywordp designator)))
                                (let ((name (token-name designator)))
                                  (push name names)
                                  ;; #'utils:parse-config is as qualified as
                                  ;; (utils:parse-config x) and wants the same
                                  ;; evidence recorded. The (setf f) branch
                                  ;; below does not: DEFINITION-NAME renders a
                                  ;; two-element list into one string, so
                                  ;; there is no single symbol whose prefix the
                                  ;; name belongs to.
                                  (note designator name)))
                               ;; Exactly (setf <non-keyword-symbol>) and
                               ;; nothing else. DEFINITION-NAME maps TOKEN-NAME
                               ;; over every element, so handed any other cons
                               ;; it renders a name nobody wrote --
                               ;; #'(lambda (item) (helper item)) becomes
                               ;; "(lambda item helper)", which no filter
                               ;; removes, which resolves to nothing, and which
                               ;; would then sit in :CALL-NAMES and
                               ;; :UNRESOLVED-CALLS forever. CON-0001: a
                               ;; recorded gap beats a fabricated fact, so
                               ;; anything not of this exact shape records no
                               ;; name and is still walked by the tail loop
                               ;; below. (consp (cdr designator)) earns its
                               ;; place twice: besides refusing a longer list,
                               ;; it is the only thing keeping a dotted
                               ;; #'(setf . g) away from DEFINITION-NAME, whose
                               ;; MAPCAR signals on a dotted list rather than
                               ;; rendering one. The stake there is an error
                               ;; out of ANALYZE-FILE, not merely a bad name.
                               ((and (consp designator)
                                     (symbolp (car designator))
                                     (string= (token-name (car designator)) "setf")
                                     (consp (cdr designator))
                                     (null (cddr designator))
                                     (second designator)
                                     (symbolp (second designator))
                                     (not (keywordp (second designator))))
                                (push (definition-name designator) names)))))
                     (when (consp head) (walk head))   ; ((lambda ...) x)
                     ;; The arguments are forms in their own right. LOOP over
                     ;; the tail rather than recursing on it, and stop at a
                     ;; dotted end rather than treating the atom as a form.
                     (loop for tail = (cdr form) then (cdr tail)
                           while (consp tail)
                           do (walk (car tail))))))))
      (dolist (form body) (walk form)))
    (values names (nreverse qualified))))

;;;; ------------------------------------------------------------------
;;;; Entity construction
;;;; ------------------------------------------------------------------

(defun definition-p (form head)
  (and (consp form) (symbolp (car form)) (string= (token-name (car form)) head)))

(defun normalize-system-name (raw)
  "RAW, a package designator as TOKEN-NAME rendered it, as a :system keyword.

Uppercased unconditionally, so (in-package :loom-graph), (in-package
\"loom-graph\") and (in-package :|Loom-Graph|) all name one system. The fold
matches AS-KEYWORD's in yaml-analyzer.lisp deliberately: those two produce the
two sides of every :no-edge rule's comparison, and a rule whose sides fold
differently reports no violations rather than wrong ones -- silence that reads
as success (ARCH-0009, risk 7).

No \"loom-\" stripping and no nickname resolution. Stripping a fixed prefix
would make this analyzer secretly aware of one tree's naming habit, which is
the guess ARCH-0009 is taking out of loom-graph rather than relocating; and a
nickname is declared by a DEFPACKAGE that RULE-0002 forbids an analyzer from
reading beyond its own file, so folding one here would be CON-0001's
fabricated fact. The literal canonical designator is recorded, gap and all."
  (and raw (plusp (length raw)) (intern (string-upcase raw) :keyword)))

(defun in-package-argument-name (form)
  "The package FORM, an (IN-PACKAGE ...) form, names -- as a plain string.

TOKEN-NAME already renders a keyword, a bare symbol or a string literal as one
token, which is all an IN-PACKAGE argument can be, so this needs no new parsing
capability. A `/`-structured name reads as one token too: `/` is an ordinary
constituent to the reader, so :game/game arrives as \"game/game\"."
  (and (consp form) (rest form) (token-name (second form))))

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
;;;; Initform call sites (BUG-0017, ARCH-0014 R3)
;;;;
;;;; The one place this analyzer mints a :CALL-SITE. COLLECT-CALL-NAMES' own
;;;; docstring records why it could not see these: ANALYZE-FILE hands
;;;; NOTE-DEFINITION no :body for a DEFVAR, DEFPARAMETER, DEFCLASS or
;;;; DEFINE-CONDITION, so (defparameter *json-key-name* #'default-json-key-name)
;;;; contributed no name and DEFAULT-JSON-KEY-NAME had no incoming edge at all.
;;;;
;;;; Reading the initform is only half of it, and the half BUG-0017's FIX could
;;;; already see. What blocked the fix is that the recorded caller would be a
;;;; :VARIABLE, and :CALLS runs from (:function :method :test) -- so there was
;;;; no edge to assert. ARCH-0014's answer is the node: the caller is a
;;;; :CALL-SITE the variable or class contains, which is a legal :CALLS source,
;;;; so the ontology question that stalled the fix does not arise.
;;;;
;;;; The other half of BUG-0017 -- a designator in a lambda-list default -- is
;;;; deliberately still open. It needs the lambda list parsed rather than
;;;; walked, or every parameter name becomes a call.
;;;; ------------------------------------------------------------------

(defun slot-initforms (slot)
  "The :INITFORM value of one DEFCLASS or DEFINE-CONDITION slot specifier, as a
list of zero or one form.

Read as a plist off the slot spec's cdr, exactly as SLOT-ACCESSOR-NAMES reads
:ACCESSOR beside it. A slot spec that is a bare symbol declares no options at
all, so it contributes nothing rather than being taken apart."
  (when (consp slot)
    (loop for (key value) on (rest slot) by #'cddr
          when (and key (symbolp key) (string= (token-name key) "initform"))
            collect value)))

(defun initform-call-sites (form head reading)
  "Every call name the initforms of FORM, whose head name is HEAD, contribute.

Names rather than entities, because this knows nothing of the file, the line or
the system in effect -- INITFORM-CALL-SITE-ENTITIES below is what turns one
into the other, and it is separate so the walk can be read against
COLLECT-CALL-NAMES without the entity construction in the way.

Filtered by STANDARD-OPERATOR-P and READER-ARTIFACT-P exactly as pass 2
filters, which is not a nicety: an unfiltered walk mints a call site for the
MAKE-HASH-TABLE in most DEFPARAMETERs in a Lisp tree, and that is the uniform
model ARCH-0014 priced at 4867 entities and refused, arriving by accident."
  (let ((initforms
          (cond ((member head '("defvar" "defparameter") :test #'string=)
                 ;; (defvar *x*) declares the variable and supplies no value.
                 (when (cddr form) (list (third form))))
                ((member head '("defclass" "define-condition") :test #'string=)
                 (loop for slot in (fourth form) append (slot-initforms slot))))))
    (when initforms
      (remove-if (lambda (name)
                   (or (standard-operator-p name) (reader-artifact-p name)))
                 (remove-duplicates (collect-call-names initforms :reading reading)
                                    :test #'string=)))))

(defun initform-call-site-entities (form start end path system reading kind)
  "The :CALL-SITE entities FORM's initforms contribute, owned by the definition
FORM makes and of KIND :VARIABLE or :CLASS.

START and END are the enclosing form's, not the initform's: ARCH-0013 deleted
ELEMENT-SPANS, so pass 1 has one range per top-level form and no sub-form
positions at all, and a DEFPARAMETER's call sites carry the DEFPARAMETER's line
(PLAN-0014 decision 5).

MAKE-CALL-SITE-ENTITY rather than MAKE-INSTANCE, and this is the seam ARCH-0014
names as a risk: the graph mints the other two kinds of call site, so the
natural key has to agree across a system boundary, and two spellings of it
would grow a duplicate per pass that nothing retracts."
  (loop for name in (initform-call-sites form (token-name (car form)) reading)
        collect (make-call-site-entity :file path :start-line start :end-line end
                                       :call-name name :referrer-kind kind
                                       :language :lisp :system system)))

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

;;; The dispatch table pass 1 runs on, and the head set derived from it.
;;;
;;; Until ARCH-0013 R13 this was a ten-clause COND beside a hand-maintained
;;; list, and *DEFINITION-HEADS*' own docstring made the reader responsible for
;;; keeping the two in step -- "adding a clause to that COND means adding its
;;; head here" -- with the failure named as a DEFUN being offered to the macro
;;; registry. Keying the clauses and deriving the list from the keys makes that
;;; obligation structurally impossible rather than merely documented.
;;;
;;; Two smaller things go with it. The COND computed (TOKEN-NAME (CAR FORM))
;;; up to ten times per top-level form, on every file, on every reindex, and
;;; discarded nine of the strings; and its first clause carried a comment
;;; defending its position, which is an ordering hazard a keyed lookup cannot
;;; have.

(defun definition-handler (name function)
  "One entry of *DEFINITION-DISPATCH*: NAME is the head as TOKEN-NAME renders
it, FUNCTION the handler." (cons name function))

(defun make-definition-dispatch (entries)
  "A head-name table from ENTRIES, refusing a duplicate key.

Refusing rather than replacing, which is the opposite of the four existing
registries in this tree and deliberately so. Those exist to be extended by
third parties (REQ-0004), where last-writer-wins is the useful semantics; this
one exists to be exhaustive over a fixed set the analyzer owns. The two
semantics differ exactly where it matters: a COND tries its clauses in order,
so a form matching two heads takes the first, and a replace-by-name table
would take the last. Getting that backwards would turn a duplicated head from
a load-time error into a definition kind silently dropped from every file in
every workspace."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry entries table)
      (destructuring-bind (name . function) entry
        (when (gethash name table)
          (error "Duplicate definition head ~s in *DEFINITION-DISPATCH*." name))
        (setf (gethash name table) function)))))

(defparameter *declaration-heads*
  '("in-package" "defpackage" "declaim" "proclaim" "eval-when"
    "defconstant" "deftype" "defsetf" "define-symbol-macro")
  "Heads that define nothing this ontology models and are not calls either.

Excluded from :DEFINER-CALL-SITES to keep the property about what it is for.
Getting this list wrong in the inclusive direction costs nothing -- an
operator matching no registry entry is left alone -- so it errs toward
recording, and only the forms that plainly declare rather than call are here.")

(defun definition-head-p (name)
  "True when NAME has a handler in *DEFINITION-DISPATCH*.

What *DEFINITION-HEADS* used to answer from a parallel list. The list is gone
and this reads the table's own keys, so the two cannot disagree and the
obligation its docstring put on the reader -- add a clause, remember to add
its head -- is discharged by construction rather than restated."
  (and (gethash name *definition-dispatch*) t))

(defun call-site-head-p (name)
  "True when NAME is a head ANALYZE-FILE already accounts for."
  (or (definition-head-p name)
      (member name *declaration-heads* :test #'string=)))

(defun argument-token (x)
  "One argument of a call site, rendered as a string.

Downcased for the reason TOKEN-NAME downcases: nothing downstream reads a
symbol's home package or its case, and a registry lookup has to match a name
as a human wrote it in source."
  (cond ((symbolp x) (token-name x))
        ((stringp x) x)
        (t (string-downcase (princ-to-string x)))))

(defun definer-call-site (form start end &optional system)
  "One :DEFINER-CALL-SITES entry for the top-level call FORM.

:SYSTEM is the package in effect at this site, and it is here rather than
inferred from the file because a file may change package part-way. No file in
either measured tree does -- 0 of 85 here and 0 of 134 on game-server,
2026-08-10 -- so reading the file's own package would work today and be a
fabricated fact tomorrow (CON-0001). Every other kind of call name reaches
resolution on an entity that carries its own :SYSTEM, so ENTITY-PACKAGE answers
for those; a definer call site is a plist on the :FILE entity and is the one
place with nowhere else to look.

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
          :system system
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

(defun make-function-entity (form start end path system)
  (make-instance 'function-entity
                 :name (token-name (second form))
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :arguments (mapcar #'token-name (third form))
                                    :language :lisp
                                    :system system))))

(defun make-variable-entity (form start end path system)
  (make-instance 'variable-entity
                 :name (token-name (second form))
                 :origin-file path
                 :properties (properties-table
                              (list :file path
                                    :start-line start
                                    :end-line end
                                    :kind :special
                                    :language :lisp
                                    :system system))))

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

(defun make-class-entity (name kind slots superclasses start end path system)
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
                                    :language :lisp
                                    :system system))))

(defun make-interface-entity (name start end path system &key members generated-by)
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
                                    :language :lisp
                                    :system system))))

(defun make-method-entity (name qualifier specializers generic arguments start end
                           path system)
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
                                    :language :lisp
                                    :system system))))

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

(defun make-macro-entity (form start end path system)
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
                                     :language :lisp
                                     :system system)
                               (macro-generator-properties form)))))

(defun method-body-from-tail (tail)
  "The body of a method whose TAIL is everything after its name: the optional
qualifier, the lambda list, then the body.

The lambda list has to go, or every specialised parameter would read as a call
site -- ((stream stream) (object entity)) is full of symbols in car position."
  (when (and (first tail) (symbolp (first tail))) (pop tail))
  (rest tail))

(defun method-body (form)
  "The body of a DEFMETHOD -- the (DEFMETHOD name . tail) spelling of a tail."
  (method-body-from-tail (cddr form)))

(defun make-generated-function-entity (name start end path system generated-by)
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
                                    :language :lisp
                                    :system system))))

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

(defun class-definition-entities (form kind start end path system)
  "The :CLASS for a DEFCLASS or DEFINE-CONDITION, and an :INTERFACE for each
accessor its slots declare."
  (let* ((name (definition-name (second form)))
         (superclasses (mapcar #'token-name (third form)))
         (slot-specs (remove-if-not (lambda (x) (or (symbolp x) (consp x)))
                                    (fourth form)))
         (class (make-class-entity name kind
                                   (mapcar #'token-name slot-specs)
                                   superclasses start end path system)))
    (cons class
          (loop for slot in slot-specs
                append (loop for accessor in (slot-accessor-names slot)
                             collect (make-interface-entity accessor start end path
                                                            system
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

(defun struct-definition-entities (form start end path system)
  "The :CLASS for a DEFSTRUCT, and a :FUNCTION for every name it generates."
  (multiple-value-bind (name slots generated superclasses)
      (defstruct-generated-names form)
    (cons (make-class-entity name :struct slots superclasses start end path system)
          (loop for generated-name in generated
                collect (make-generated-function-entity generated-name start end path
                                                        system name)))))

;;; --- defgeneric / defmethod ---------------------------------------

(defun method-entity-from-tail (name tail start end path system)
  "The :METHOD for a method named NAME whose TAIL is everything after the
name, keyed by name, qualifier and specializers.

The single copy of the method-tail grammar (ARCH-0010 R3). A DEFMETHOD form is
(DEFMETHOD name . tail) and an inline DEFGENERIC clause is (:METHOD . tail):
the tails are the same grammar, and the only thing the clause lacks is the
name, which the enclosing DEFGENERIC supplies. Extracting this rather than
fabricating a DEFMETHOD form per clause keeps one parser honest instead of
consing a synthesized head that nothing ever reads.

The qualifier is whatever sits between the name and the lambda list, which is
how a method is told from an :AROUND on the same specializers. NIL is a list,
so an empty lambda list is not mistaken for one -- and it is a symbol, so
dropping the NIL guard would read () as a qualifier and shift the whole tail
by one."
  (let* ((qualifier (when (and (first tail) (symbolp (first tail))) (first tail)))
         (lambda-list (if qualifier (second tail) (first tail)))
         (parameters (lambda-list-parameters lambda-list)))
    (make-method-entity name
                        (when qualifier
                          (intern (string-upcase (token-name qualifier)) :keyword))
                        (mapcar #'specializer-name parameters)
                        name                    ; the generic it implements
                        (mapcar #'token-name lambda-list)
                        start end path system)))

(defun method-definition-entity (form start end path system)
  "The :METHOD for a DEFMETHOD -- the (DEFMETHOD name . tail) spelling of a
tail."
  (method-entity-from-tail (definition-name (second form)) (cddr form)
                           start end path system))

(defun generic-definition-entities (form start end path system &key reading)
  "The :INTERFACE for a DEFGENERIC and a :METHOD for each of its inline
(:method ...) clauses, as an ordered list of (ENTITY . BODY) pairs.

Plural, like CLASS-DEFINITION-ENTITIES and STRUCT-DEFINITION-ENTITIES, because
a DEFGENERIC can define more than the protocol: game-server writes 247 inline
clauses across 158 forms, every one of which used to be discarded here, so
every body they contain contributed no call names and no edges in either
direction (ARCH-0010). The interface itself is untouched by all of this -- same
name, same :members, same whole-form range -- which is why a DEFGENERIC with no
clause still produces exactly what it always did.

READING is a keyword rather than positional so a caller that has none is not
required to lie about it, and so the fallback below is reachable from a test.
PATH and SYSTEM stay positional in that order, per ARCH-0009's convention.

Per-clause ranges come from FORM-RANGE, which asks the clause cons itself
rather than reconstructing a parallel sequence to zip against this one
(ARCH-0013 R7). That retires ELEMENT-SPANS' alignment condition entirely: there
is no element count to compare, so there is no mismatch to fall back from, and
the two shapes ELEMENT-SPANS returned NIL for -- a block comment before the
closing paren, a DEFGENERIC behind a reader macro -- now each clause its own
range like any other. ARCH-0010 R4's fallback stays as the declared answer
where FORM-RANGE misses, which after this it can do only for reader-level
structure sharing: the whole DEFGENERIC's range is a wider truth that genuinely
contains the clause, where a misattributed one would be a fabricated fact
(CON-0001)."
  (let ((name (definition-name (second form))))
    (cons (cons (make-interface-entity
                 name start end path system
                 :members (mapcar #'token-name
                                  (lambda-list-parameters (third form))))
                nil)
          ;; (:documentation ...), (:method-combination ...), (declare ...) and
          ;; (:argument-precedence-order ...) are skipped, as they always were.
          (loop for element in (cdddr form)
                when (and (consp element) (symbolp (car element))
                          (string= "method" (token-name (car element))))
                  collect (multiple-value-bind (clause-start clause-end foundp)
                              (and reading (form-range reading element))
                            ;; A DEFMETHOD is (DEFMETHOD name . tail) and a
                            ;; clause is (:METHOD . tail): the same grammar,
                            ;; minus the name the enclosing form supplies.
                            (let ((tail (rest element)))
                              (cons (method-entity-from-tail
                                     name tail
                                     (if foundp clause-start start)
                                     (if foundp clause-end end)
                                     path system)
                                    (method-body-from-tail tail))))))))

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
                                    ;; The path default and nothing stronger:
                                    ;; the reader failed before any form, so no
                                    ;; IN-PACKAGE was ever seen (ARCH-0009 R4).
                                    :system (default-system-for-path path)
                                    :line-count (line-count contents)
                                    :analysis-failed-p t
                                    :analysis-error (princ-to-string condition)))))

(defun supersede-shadowed-definitions (definitions)
  "Two values: the definitions in DEFINITIONS this file actually defines, in
source order, and an alist of (survivor . superseded-entities-in-source-order)
for those that replaced something.

Common Lisp's reconciliation rule, applied at the one layer where the two
definitions are still distinct objects (ARCH-0012 R1): among definitions
sharing one ENTITY-NATURAL-KEY, the last in source order is the one in effect
once the file loads, and every earlier one is dead code. It belongs here and
not in the writer because it is the *language's* semantics -- CL replaces,
while a TypeScript analyzer meeting interface merging would have to merge --
and the writer must stay language-neutral.

The keys are type-led, so a DEFUN and a DEFCLASS of one name do not collide
while a DEFUN and a DEFMACRO do: both mint :FUNCTION, and both really do
define the same name.

A definition whose key is NIL always survives and is never grouped. NIL means
\"this type declares no upsert identity\", not \"a key these two share\", and
a table keyed on it would fold unrelated definitions into one."
  (let ((survivor-of (make-hash-table :test #'equal))
        (survivors '())
        (shadowed '()))
    ;; Last write wins, which for a source-ordered list is last-in-source-order
    ;; wins -- the same answer ABSORB-ENTITY reaches downstream, reached here
    ;; while the loser is still an object that can simply be dropped.
    (dolist (e definitions)
      (let ((key (entity-natural-key e)))
        (when key (setf (gethash key survivor-of) e))))
    (dolist (e definitions)
      (let* ((key (entity-natural-key e))
             (survivor (and key (gethash key survivor-of))))
        (if (or (null survivor) (eq e survivor))
            (push e survivors)
            (let ((cell (assoc survivor shadowed :test #'eq)))
              (if cell
                  (push e (cdr cell))
                  (push (list survivor e) shadowed))))))
    (values (nreverse survivors)
            (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
                    (nreverse shadowed)))))

(defun shadowing-worth-recording-p (survivor superseded)
  "True when SURVIVOR replacing SUPERSEDED is a shadowing worth reporting.

Supersession (ARCH-0012 R1) applies to every definition kind without
exception; this decides only whether the survivor records it. The one case it
excludes is two DEFCLASS or DEFINE-CONDITION forms in one file each declaring
:ACCESSOR NAME. That is not a shadowing at all -- in Common Lisp it is one
generic function acquiring two methods, and both bodies are live -- so
reporting it would be a false finding. :GENERATED-BY is exactly the marker for
\"this name was synthesized from a slot declaration rather than written\", so
the carve-out is: stay quiet only when BOTH names were generated. If either
was written by hand, one of them really is dead code.

Measured before it was written, which is the only reason it is here:
recording every collision verbatim gives three findings on Loom and seventeen
on game-server, of which thirteen are accessor pairs -- burying the six that
matter. A rule whose output has to be read past is BUG-0009's failure again.

This lives in the Lisp analyzer and not in the rule or the writer because
\"an accessor name declared twice is one generic function\" is a fact about
Common Lisp, and language reconciliation is what ARCH-0012 puts here."
  (not (and (getp survivor :generated-by)
            (getp superseded :generated-by))))

(defun definition-line-range (e)
  "E's extent as the \"start-end\" string :SHADOWED-DEFINITIONS records.
A string rather than the entity, because the shadowed definition deliberately
has no entity: the graph holds what the file defines, and a reader who wants
the dead text opens the file at these lines."
  (format nil "~a-~a" (getp e :start-line) (getp e :end-line)))

;;;; ------------------------------------------------------------------
;;;; Pass 1's dispatch (ARCH-0013 R13)
;;;;
;;;; One handler per definition head. Each takes the form, its range, the path,
;;;; the system in effect, the READING, and NOTE, the function that records an
;;;; entity; each returns the system in effect afterwards, which is NIL for
;;;; every handler but IN-PACKAGE's.
;;;;
;;;; Returning the system rather than mutating a closed-over variable is what
;;;; lets IN-PACKAGE stop being a special case. It was the COND's first clause
;;;; with a comment defending that position -- "so no later clause can shadow
;;;; it" -- and it is the only form in the language that changes the state of
;;;; the walk rather than adding to its output. Making that visible in the
;;;; protocol every handler shares costs one ignored return value per handler
;;;; and removes an ordering a keyed lookup could not have honoured anyway.
;;;; ------------------------------------------------------------------

(defmacro define-definition-handler (name &body body)
  "A pass-1 handler taking FORM START END PATH SYSTEM READING NOTE and
returning the system in effect afterwards.

The lambda list is fixed and every parameter is declared IGNORABLE, because
seven parameters most handlers do not use is the price of one uniform
protocol -- and the alternative, a signature per definition kind, is the thing
the table exists to abolish."
  `(defun ,name (form start end path system reading note)
     (declare (ignorable form start end path system reading note))
     ,@body))

(define-definition-handler handle-in-package
  "The only handler that changes the walk's state rather than its output.

Mints no entity and records no call site: a file's package declaration is not
a definition this ontology models, and ARCH-0009 makes the IN-PACKAGE chain
the sole source of :SYSTEM. \"in-package\" stays in *DECLARATION-HEADS* as
well, which is now belt and braces rather than the mechanism -- a head with a
handler never reaches the catch-all."
  (or (normalize-system-name (in-package-argument-name form)) system))

;;;; ------------------------------------------------------------------
;;;; Package declarations (ARCH-0015)
;;;;
;;;; The analyzer records what a declaration says and decides nothing with it.
;;;; Canonicalising a nickname, or working out which package a name is homed
;;;; in, needs every declaration in the tree at once -- test/fixture.lisp is
;;;; only (in-package :integration-test) with the DEFPACKAGE in another file --
;;;; and RULE-0002 keeps an analyzer inside its own file. So this is the
;;;; recording half of ARCH-0015's split, and loom-graph does the assembling,
;;;; exactly as ARCH-0014 R4 divided definer call sites.

(defun package-designator-name (x)
  "A package or symbol designator as a canonical uppercase string.

Uppercased for the reason NORMALIZE-SYSTEM-NAME gives: (:use :cl), (:use \"CL\")
and (:use cl) name one package, and folding here means the graph compares one
spelling. TOKEN-NAME reads SYMBOL-NAME and nothing else, so a package prefix on
the designator itself is already gone before this sees it."
  (let ((raw (token-name x)))
    (and raw (plusp (length raw)) (string-upcase raw))))

(defun package-clauses (form head)
  "Every clause of a DEFPACKAGE-shaped FORM whose head is HEAD.

Every, not the first: a package may carry several :IMPORT-FROM clauses, one
per source package, and reading only the first is how tools/package-census.lisp
reported 0 imported names on a tree that has 227."
  (remove-if-not (lambda (clause)
                   (and (consp clause)
                        (equal head (token-name (car clause)))))
                 (cddr form)))

(defparameter *unmodelled-package-clauses*
  '("use-reexport" "mix" "mix-reexport" "recycle" "reexport"
    "shadow" "shadowing-import-from")
  "Clauses that move symbols between packages and that this analyzer does not
model. Recorded on the entity rather than dropped: neither Loom nor game-server
uses any of them -- measured 2026-08-10, zero occurrences in 65 declarations --
and the first tree that does must produce a recorded gap rather than a
confident wrong answer (CON-0001).")

(defun package-imported-symbols (form)
  "Every (symbol-name . from-package-name) an :IMPORT-FROM clause declares.

The clause is (:import-from PACKAGE SYMBOL ...), so the source package is the
clause's second element and the symbols are the rest."
  (loop for clause in (package-clauses form "import-from")
        for from = (package-designator-name (second clause))
        when from
          append (loop for sym in (cddr clause)
                       for name = (package-designator-name sym)
                       when name collect (cons name from))))

(defun make-package-entity (form start end path system)
  "A :PACKAGE from a DEFPACKAGE or a uiop DEFINE-PACKAGE.

Both operators, because game-server declares 31 of its 41 packages with
DEFINE-PACKAGE and DEFPACKAGE alone would read that tree as importing nothing
at all. TOKEN-NAME is package-independent, so UIOP/PACKAGE:DEFINE-PACKAGE and a
bare DEFINE-PACKAGE arrive here identically."
  (let ((qualified (package-designator-name (second form))))
    (make-instance 'package-entity
                   :name qualified
                   :origin-file path
                   :properties (properties-table
                                (list :qualified-name qualified
                                      :nicknames
                                      (loop for c in (package-clauses form "nicknames")
                                            append (mapcar #'package-designator-name
                                                           (rest c)))
                                      :uses
                                      (loop for c in (package-clauses form "use")
                                            append (mapcar #'package-designator-name
                                                           (rest c)))
                                      :exports
                                      (loop for c in (package-clauses form "export")
                                            append (mapcar #'package-designator-name
                                                           (rest c)))
                                      :imported-symbols (package-imported-symbols form)
                                      :unhandled-package-clauses
                                      (loop for head in *unmodelled-package-clauses*
                                            when (package-clauses form head)
                                              collect (string-upcase head))
                                      :file path
                                      :start-line start
                                      :end-line end
                                      :language :lisp
                                      :system system)))))

(define-definition-handler handle-defpackage
  "DEFPACKAGE and uiop's DEFINE-PACKAGE.

Mints an entity and changes no walk state: unlike IN-PACKAGE, declaring a
package does not make it current. \"defpackage\" stays in *DECLARATION-HEADS*
as belt and braces, following HANDLE-IN-PACKAGE's precedent -- a head with a
handler never reaches the catch-all."
  (funcall note (make-package-entity form start end path system))
  system)

(define-definition-handler handle-defun
  (funcall note (make-function-entity form start end path system)
           :local t :body (cdddr form))
  system)

(define-definition-handler handle-defmacro
  (funcall note (make-macro-entity form start end path system)
           :local t :body (cdddr form))
  system)

(define-definition-handler handle-variable
  "DEFVAR and DEFPARAMETER, which shared a clause and now share a handler."
  (funcall note (make-variable-entity form start end path system)
           :call-sites (initform-call-site-entities form start end path system
                                                    reading :variable))
  system)

;;; The class is (FIRST ENTITIES) and the rest are the :INTERFACE per declared
;;; accessor, so the two are noted separately rather than in one DOLIST: an
;;; initform belongs to the class that declares the slot, and hanging it off an
;;; accessor would put the call under a generic function that never mentions it.

(define-definition-handler handle-defclass
  (let ((entities (class-definition-entities form :class start end path system)))
    (funcall note (first entities)
             :call-sites (initform-call-site-entities form start end path system
                                                      reading :class))
    (dolist (e (rest entities)) (funcall note e)))
  system)

(define-definition-handler handle-define-condition
  (let ((entities (class-definition-entities form :condition start end path system)))
    (funcall note (first entities)
             :call-sites (initform-call-site-entities form start end path system
                                                      reading :class))
    (dolist (e (rest entities)) (funcall note e)))
  system)

(define-definition-handler handle-defstruct
  (let ((entities (struct-definition-entities form start end path system)))
    (funcall note (first entities))
    ;; The generated names are ordinary functions defined by this file, so a
    ;; call to one inside it resolves here rather than waiting for the
    ;; workspace.
    (dolist (e (rest entities)) (funcall note e :local t)))
  system)

(define-definition-handler handle-defgeneric
  ;; NOTE already treats a NIL :body as "no body", so the interface pair needs
  ;; no special case. No :local for the inline methods either, for the reason
  ;; DEFMETHOD gives: a call names the generic, and which method runs is a
  ;; runtime question resolution fans out.
  (dolist (pair (generic-definition-entities form start end path system
                                             :reading reading))
    (funcall note (car pair) :body (cdr pair)))
  system)

(define-definition-handler handle-defmethod
  (funcall note (method-definition-entity form start end path system)
           :body (method-body form))
  system)

(defparameter *definition-dispatch*
  (make-definition-dispatch
   (list (definition-handler "in-package"       #'handle-in-package)
         (definition-handler "defpackage"       #'handle-defpackage)
         (definition-handler "define-package"   #'handle-defpackage)
         (definition-handler "defun"            #'handle-defun)
         (definition-handler "defmacro"         #'handle-defmacro)
         (definition-handler "defvar"           #'handle-variable)
         (definition-handler "defparameter"     #'handle-variable)
         (definition-handler "defclass"         #'handle-defclass)
         (definition-handler "define-condition" #'handle-define-condition)
         (definition-handler "defstruct"        #'handle-defstruct)
         (definition-handler "defgeneric"       #'handle-defgeneric)
         (definition-handler "defmethod"        #'handle-defmethod)))
  "Head name to pass-1 handler. The same set answers DEFINITION-HEAD-P, so
adding a definition kind is one entry here and nothing else.

Two handlers share a function -- DEFVAR and DEFPARAMETER, which shared a COND
clause before -- which is why duplicate *keys* are refused while duplicate
values are ordinary.")

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
        ;; The package in effect at the form being read (ARCH-0009 R4). Seeded
        ;; from the path because a definition read before the file's first
        ;; IN-PACKAGE has no stronger fact available -- that is the ordinary
        ;; default falling through, not a special case.
        (current-system (default-system-for-path path))
        (definitions '())       ; every entity, in source order
        (local-functions '())   ; alist: name -> entity, for exact local calls
        (callables '())         ; list of (entity . body), things with bodies
        (call-sites '())        ; :DEFINER-CALL-SITES entries, in source order
        (owned-call-sites '())  ; list of (owner . :CALL-SITE entity), ARCH-0014
        (shadowed '())          ; alist: survivor -> what it superseded
        (ops '())               ; built reversed, NREVERSEd on the way out
        (reading nil)
        (forms nil))

    ;; --- pass 0: read, and survive a file that will not read ---------
    ;; SS3.3: a condition escaping here would take the watcher thread down and
    ;; leave the process answering queries while silently indexing nothing.
    ;;
    ;; READ-SOURCE does not signal for a form it could repair, so what used to
    ;; be a HANDLER-CASE over the whole read is now a test of one slot
    ;; (ARCH-0013). The unparsable :FILE entity survives for the case it was
    ;; always the right answer to -- a file that could not be read at all --
    ;; and stops being the answer to a file with one bad form in it, which is
    ;; REQ-0019 R3. A repaired form is already absent from READING-FORMS, so
    ;; nothing below can mint an entity from text the reader guessed at.
    (setf reading (read-source contents))
    (when (reading-fatal reading)
      (return-from analyze-file
        (list (retract-file path workspace-id)
              (assert-entity (make-unparsable-file-entity
                              path contents (reading-fatal reading))
                             workspace-id))))
    (setf forms (reading-forms reading))

    ;; --- pass 1: what this file defines -----------------------------
    ;;
    ;; A DEFUN and a DEFSTRUCT accessor go into LOCAL-FUNCTIONS, because a call
    ;; to either names exactly one definition and can be linked here. A
    ;; DEFMETHOD does not: a call names the generic, and which method runs is a
    ;; runtime question, so those edges are left for resolution to fan out.
    (flet ((note-definition (entity &key local body call-sites)
             (push entity definitions)
             (when local (push (cons (name entity) entity) local-functions))
             (when body (push (cons entity body) callables))
             ;; :CALL-SITES is ARCH-0014's addition and the only one of the
             ;; three that names entities rather than raw material: the handler
             ;; has already built them, because it is the only place with the
             ;; form's range and the system in effect at once.
             (dolist (site call-sites) (push (cons entity site) owned-call-sites))))
      (dolist (spec forms)
        (destructuring-bind (form start end start-offset) spec
          ;; START-OFFSET is vestigial from here: ELEMENT-SPANS was its only
          ;; consumer and it is gone, but ARCH-0010 R1 named the widened tuple
          ;; as a requirement, so the element stays and the bind does not move.
          (declare (ignore start-offset))
          ;; The head name, computed once. The COND this replaced asked
          ;; DEFINITION-P up to ten times per form and DEFINITION-P is
          ;; (STRING= (TOKEN-NAME (CAR FORM)) HEAD), so the same downcased
          ;; string was allocated and discarded nine times over -- on every
          ;; file, on every reindex.
          (let* ((head (and (consp form) (symbolp (car form)) (car form)
                            (token-name (car form))))
                 (handler (and head (gethash head *definition-dispatch*))))
            (cond
              (handler
               ;; Every handler returns the system in effect afterwards, which
               ;; is how IN-PACKAGE stops being a first clause with a comment
               ;; defending its position. A keyed lookup cannot be shadowed, so
               ;; there is no ordering left to defend.
               (setf current-system
                     (funcall handler form start end path current-system reading
                              #'note-definition)))
              ;; Everything else is a call, and may be a call to a definer
              ;; macro. Recorded, never judged: the judgement needs the whole
              ;; workspace (ARCH-0002). HEAD being non-NIL is the same test the
              ;; catch-all always made -- a cons whose car is a non-NIL symbol.
              ((and head (not (call-site-head-p head)))
               (push (definer-call-site form start end current-system)
                     call-sites)))))))
    (setf definitions (nreverse definitions)
          owned-call-sites (nreverse owned-call-sites))

    ;; --- supersession: what the file defines once loaded (ARCH-0012 R1) ---
    ;; Here rather than after pass 2, because the point is that a shadowed
    ;; definition's body is never walked at all: no :CALL-NAMES, no local
    ;; :CALLS edge, no entity op, no :CONTAINS. Left to the graph it would be
    ;; too late -- pass 3 emits every entity before any call edge, so both
    ;; definitions' edges land after the absorb that was supposed to choose
    ;; between them, and they are indistinguishable by then (BUG-0012).
    ;;
    ;; CALLABLES and LOCAL-FUNCTIONS are filtered rather than rebuilt.
    ;; LOCAL-FUNCTIONS is an alist searched with ASSOC and pushed in source
    ;; order, so the survivor is already in front of anything it shadows;
    ;; removing the losers keeps a body that names one from resolving to an
    ;; object no op will ever assert.
    ;;
    ;; OWNED-CALL-SITES is filtered the same way and for a sharper version of
    ;; the same reason: a shadowed DEFPARAMETER's initform is dead code, and a
    ;; call site surviving its owner would be an entity in the graph carrying a
    ;; :CONTAINS edge from something no assert ever lands.
    (multiple-value-setq (definitions shadowed)
      (supersede-shadowed-definitions definitions))
    (setf callables
          (remove-if-not (lambda (entry) (member (car entry) definitions :test #'eq))
                         callables)
          local-functions
          (remove-if-not (lambda (entry) (member (cdr entry) definitions :test #'eq))
                         local-functions)
          owned-call-sites
          (remove-if-not (lambda (entry) (member (car entry) definitions :test #'eq))
                         owned-call-sites))

    ;; ARCH-0012 R2. The shadowed source is real text, so its existence is
    ;; recorded on the survivor rather than silently dropped (CON-0001) -- and
    ;; no guess is involved, since source order decides which definition the
    ;; loaded file contains. Absent and empty differ, which is why the WHEN is
    ;; there: RULE-0006 reports on presence alone, so writing an empty list
    ;; where the carve-out filtered everything out would be a false finding.
    (loop for (survivor . superseded) in shadowed
          for ranges = (mapcar #'definition-line-range
                               (remove-if-not
                                (lambda (e) (shadowing-worth-recording-p survivor e))
                                superseded))
          when ranges
            do (setp survivor :shadowed-definitions ranges))

    (setp file :definer-call-sites (nreverse call-sites))

    ;; What the reader passed over or repaired, recorded on the file rather
    ;; than dropped (ARCH-0013, PLAN-0013 step 5). The WHEN on each is the
    ;; same discipline :SHADOWED-DEFINITIONS uses: absent and empty differ, so
    ;; a file with nothing to report carries no property rather than an empty
    ;; list that reads as a report of nothing.
    ;;
    ;; The reason is rendered to a string here and the region's own shape is
    ;; flattened, because a property is data the graph stores and reloads --
    ;; an Eclector reason cons holding an uninterned symbol is a different
    ;; object on every read, so storing it would give two indexings of one
    ;; unchanged file two different answers.
    (let ((suppressed (reading-suppressed-regions reading)))
      (when suppressed
        (setp file :suppressed-regions
              (mapcar (lambda (skip)
                        (list :reason (skip-reason-name (getf skip :reason))
                              :start-line (getf skip :start-line)
                              :end-line (getf skip :end-line)))
                      suppressed))))
    (let ((recovered (reading-recovered reading)))
      (when recovered
        (setp file :recovered-regions
              (mapcar (lambda (entry)
                        (list :condition (string-downcase
                                          (symbol-name (getf entry :condition)))
                              :text (getf entry :text)
                              :start-line (getf entry :start-line)
                              :end-line (getf entry :end-line)
                              :cost (getf entry :cost)))
                      recovered))))
    ;; Whatever package was in effect at the end of the file -- coarser than
    ;; the per-entity value above, and deliberately so: one :FILE entity cannot
    ;; carry two. ARCH-0009 discloses what that costs on a real multi-IN-PACKAGE
    ;; file. SETP rather than a constructor argument because :system is in no
    ;; natural key, so writing it here does not move the id.
    (setp file :system current-system)

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
          (multiple-value-bind (call-names qualified)
              (collect-call-names body :reading reading)
            (let ((foreign '()))
              (dolist (callee-name (remove-duplicates call-names :test #'string=))
                (let ((callee (cdr (assoc callee-name local-functions :test #'string=))))
                  (cond ((and callee (not (eq callee caller)))
                         (push (cons caller callee) local-calls))
                        ((standard-operator-p callee-name))
                        ((reader-artifact-p callee-name))
                        ((string= callee-name (name caller)))   ; direct recursion
                        (t (push callee-name foreign)))))
              (setp caller :call-names (nreverse foreign))
              ;; ARCH-0013, PLAN-0013 step 6. Recorded beside :CALL-NAMES and
              ;; read by nothing: this step records the fact and changes no
              ;; resolution behaviour, so the :CALLS edge count must not move.
              ;;
              ;; Deduplicated on the whole pair rather than on the name. Two
              ;; sites writing `utils:parse-config' are one fact; a body
              ;; calling both `utils:parse-config' and `config:parse-config'
              ;; is two, and collapsing them by name would silently pick
              ;; whichever came first -- a fabricated fact in exactly the
              ;; shape CON-0001 names, since the surviving prefix would look
              ;; like the only one the file wrote.
              ;;
              ;; Absent rather than empty when nothing was qualified, the
              ;; discipline :SHADOWED-DEFINITIONS and :SUPPRESSED-REGIONS both
              ;; keep: most bodies write no prefix at all, and an empty list on
              ;; every one of them is noise that reads as a report.
              (let ((pairs (remove-duplicates qualified :test #'equal
                                                        :from-end t)))
                (when pairs
                  (setp caller :qualified-calls
                        (mapcar (lambda (pair)
                                  (list :name (car pair) :package (cdr pair)))
                                pairs))))))))

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
      ;; After every definition, so an owner's own assert is always already
      ;; planned when the edge naming it is. No :CONTAINS from the file: the
      ;; chain ARCH-0014 draws is file contains variable contains call-site, and
      ;; a second ownership edge would make the file a container of things it
      ;; does not directly define.
      (dolist (entry owned-call-sites)
        (destructuring-bind (owner . site) entry
          (push (assert-entity site workspace-id) ops)
          (push (assert-edge :contains owner site :workspace-id workspace-id) ops)))
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
