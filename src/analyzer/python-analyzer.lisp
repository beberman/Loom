;;;; The Python analyzer -- DES-0053, REQ-0078 R1 to R6.
;;;;
;;;; Like the JavaScript analyzer this parses in a long-lived child process, and
;;;; the process lifecycle is extractor-child.lisp's (R14). The child is python3
;;;; running its own `ast' (D1): it reads text and imports, executes and compiles
;;;; nothing, so it works on code whose dependencies are not installed. A tree
;;;; analyzed on a machine with no python3 still indexes every .py file, with
;;;; the reason recorded on each.
;;;;
;;;; The first half of this file is the child. The second is the decisions about
;;;; what its reply means: entities (D3), call sites (D4), reconciliation (D9),
;;;; environment-read placement (D10), exclusion by name (D11) and :SYSTEM (D12).
;;;; Like the Lisp and JavaScript analyzers this one writes properties and
;;;; asserts no cross-file relationship: every specifier and callee is recorded
;;;; for SYNOPTIK-GRAPH to resolve on each pass (DEC-0003).

(in-package :synoptik-analyzer)

;;;; ==================================================================
;;;; Configuration
;;;; ==================================================================

(defparameter *python-program* "python3"
  "The interpreter. A name rather than a path, for the reason *NODE-PROGRAM* is:
PATH is the only thing that knows where a version manager put it. The version
is a parsing limit -- python3 3.12 cannot read syntax added in 3.13 -- and
*PYTHON-PROGRAM* can name a newer interpreter. The child's error text carries
the version so a reader can tell an old interpreter from a broken file.")

(defparameter *py-extractor*
  ;; synoptik-analyzer.asd lives in src/analyzer/, so the tree root is two up.
  (asdf:system-relative-pathname :synoptik-analyzer "../../tools/py/extract.py")
  "The child script. Resolved against Synoptik's own source and not against the
repository being indexed, as *JS-EXTRACTOR* is.")

(defparameter *py-parse-timeout-seconds* 30
  "How long to wait for one file's reply before giving up on the child. See
*JS-PARSE-TIMEOUT-SECONDS*: it bounds the whole exchange, and fires only when
something is wrong.")

;;;; ==================================================================
;;;; The child process
;;;; ==================================================================

(defvar *py-extractor-child*
  (make-extractor-child
   :name "python"
   ;; -I keeps PYTHONPATH, the user site directory and the current directory off
   ;; sys.path, so a tree holding its own ast.py or json.py cannot replace a
   ;; module the extractor imports. -B writes no .pyc into anybody's tree (D1).
   :argv-function (lambda () (list *python-program* "-I" "-B" (namestring *py-extractor*)))
   :timeout-function (lambda () *py-parse-timeout-seconds*))
  "The Python extractor, whose lifecycle is extractor-child.lisp's.")

(defun parse-python (path contents)
  "Two values: the child's decoded reply for PATH, and a reason string when
there is none. A file with a syntax error is the child's business to report in
its reply (D7); EXCHANGE-WITH-CHILD retries only a child that died."
  (exchange-with-child *py-extractor-child* path contents))

;;;; ==================================================================
;;;; Reading the reply
;;;; ==================================================================

(defun py-dotted (specifier path)
  "SPECIFIER and PATH as one spelling: `service.ensure', `.posting.post'. A
specifier ending in a dot takes no second one, so `..' and (util go) read
`..util.go'. Only a label and a natural key (D4): resolution reads the two parts."
  (format nil "~a~@[~a~]~{~a~^.~}" specifier
          (and path (not (char= #\. (char specifier (1- (length specifier))))) ".")
          path))

(defun py-call-names (calls)
  "The bare names of CALLS that are not bound to an import: local, self and
member bindings (D2, R4). Each distinct name once."
  (remove-duplicates
   (loop for call in calls
         unless (equal "import" (jget call :kind))
           collect (jget call :name))
   :test #'string= :from-end t))

(defun py-imported-calls (calls)
  "One plist per distinct import-bound call: :SPECIFIER, :PATH and the :LINE of
the first (D2). A change to what RESOLVE-CALLS walks is a change to this shape."
  (let ((seen '()) (out '()))
    (dolist (call calls (nreverse out))
      (when (equal "import" (jget call :kind))
        (let ((key (list (jget call :specifier) (jlist call :path))))
          (unless (member key seen :test #'equal)
            (push key seen)
            (push (list :specifier (jget call :specifier)
                        :path (jlist call :path)
                        :line (jget call :line))
                  out)))))))

(defun py-call-key (call)
  "The key resolution reads CALL by: its bare name, or an import-bound call's
specifier and path as PY-DOTTED renders them. IMPORTED-CALL-KEY in synoptik-graph
writes the same spelling into an edge's :VIA, and a shape is joined to its edge
through that spelling (DES-0055 D11)."
  (if (equal "import" (jget call :kind))
      (py-dotted (jget call :specifier) (jlist call :path))
      (jget call :name)))

(defun py-call-shapes (calls)
  "D11's :CALL-SHAPES value for CALLS, the child's call records: one occurrence
per call, keyed as PY-CALL-KEY keys it, with the signature the child computed
and the call's own line. NIL for none.

A record with no signature is left out and not given a guessed one: the child
writes one on every call, so a missing one is a reply from something else
(CON-0001)."
  (group-call-shapes
   (loop for call in calls
         when (jget call :signature)
           collect (list (py-call-key call) (jget call :signature) (jget call :line)))))

(defun py-shape-occurrences (shapes)
  "SHAPES, a :CALL-SHAPES value, as the (KEY SIGNATURE LINE) list that
GROUP-CALL-SHAPES reads, a repeated line repeated."
  (loop for (key . entries) in shapes
        append (loop for (signature . lines) in entries
                     append (loop for line in lines collect (list key signature line)))))

(defun py-merge-site-shapes (kept dropped)
  "Move DROPPED's :CALL-SHAPES onto KEPT. Two sites of one natural key are one
site (CON-0005), and the call whose site is dropped was still made."
  (setp kept :call-shapes
        (group-call-shapes (append (py-shape-occurrences (getp kept :call-shapes))
                                   (py-shape-occurrences (getp dropped :call-shapes))))))

(defun py-decorator-value (value)
  "A decorator argument as DES-0054 D1 records it. DECODE-ARGUMENT-VALUE is the
decoder, shared with the JavaScript analyzer. No longer called here since
DECODE-REGISTRATION reads a decorator's arguments; kept because DES-0054 and
PLAN-0057 name it in `affects:' and `check' reports a name that resolves to
nothing."
  (decode-argument-value value))

(defun py-value-call (variable)
  "VARIABLE's :VALUE-CALL (DES-0054 D2) as a plist. DECODE-VALUE-CALL is the
decoder, shared with the JavaScript analyzer."
  (decode-value-call (jget variable :value-call)))

(defun py-decorators (definition)
  "One plist per decorator, in source order (D3), read by DECODE-REGISTRATION."
  (mapcar #'decode-registration (jlist definition :decorators)))

;;;; ==================================================================
;;;; Reconciling same-key definitions (CON-0005, D9)
;;;; ==================================================================

(defun py-accessor-names (name)
  "`x.setter', `x.getter' and `x.deleter' for a def whose own name is x, written
as `C.x' when it is a method."
  (let ((own (subseq name (1+ (or (position #\. name :from-end t) -1)))))
    (mapcar (lambda (suffix) (concatenate 'string own suffix))
            '(".setter" ".getter" ".deleter"))))

(defun py-item (kind definition)
  "DEFINITION, a definition or variable of the child's reply, as a plist the
reconciliation and the entity builders share.

A property accessor's own decorator, `@x.setter', is a member call on the
property just defined. It names no definition anywhere and would only be
recorded as an unresolved call, so it is dropped here; D9's merge reads it from
:DECORATORS instead."
  (list :kind kind
        :name (jget definition :name)
        :start (jget definition :start-line)
        :end (jget definition :end-line)
        :arguments (jlist definition :arguments)
        :decorators (py-decorators definition)
        :documentation (jget definition :docstring)
        :bases (jlist definition :bases)
        :slots (jlist definition :slots)
        :calls (let ((accessors (and (member kind '(:function :method))
                                     (py-accessor-names (jget definition :name)))))
                 (remove-if (lambda (call)
                              (and (equal "member" (jget call :kind))
                                   (member (jget call :name) accessors :test #'equal)))
                            (jlist definition :calls)))
        :env (jlist definition :env-reads)
        :value-call (py-value-call definition)
        :unnamed (or (jget definition :unnamed-env-reads) 0)))

(defun py-module-items (reply)
  "Every definition and module-level variable of REPLY, in source order."
  (stable-sort
   (append (mapcar (lambda (d) (py-item (cdr (assoc (jget d :kind)
                                                    '(("function" . :function)
                                                      ("method" . :method)
                                                      ("class" . :class))
                                                    :test #'equal))
                                        d))
                   (jlist reply :definitions))
           (mapcar (lambda (v) (py-item :variable v)) (jlist reply :variables)))
   #'< :key (lambda (item) (getf item :start))))

(defun py-decorated-p (item &rest names)
  "True when ITEM carries a decorator written as one of NAMES, or as a dotted
name ending in one: `overload' and `typing.overload' are both an overload."
  (some (lambda (decorator)
          (let ((written (getf decorator :name)))
            (some (lambda (name)
                    (or (string= written name)
                        (let ((tail (concatenate 'string "." name)))
                          (and (> (length written) (length tail))
                               (string= tail written
                                        :start2 (- (length written) (length tail)))))))
                  names)))
        (getf item :decorators)))

(defun py-accessor-p (item)
  "True when ITEM is `@x.setter', `@x.getter' or `@x.deleter' on a def named x."
  (let* ((name (getf item :name))
         (own (subseq name (1+ (or (position #\. name :from-end t) -1)))))
    (some (lambda (suffix)
            (some (lambda (decorator)
                    (string= (getf decorator :name)
                             (concatenate 'string own suffix)))
                  (getf item :decorators)))
          '(".setter" ".getter" ".deleter"))))

(defun py-range (item) (format nil "~a-~a" (getf item :start) (getf item :end)))

(defun py-supersede (previous item)
  "What one name means once ITEM follows PREVIOUS in a module or class body.

Python replaces a rebound name, so the later one wins and the earlier range goes
into :SHADOWED. Three shapes are not that and stay out of :SHADOWED (D9). A
property's accessor chain is one definition: its entity spans the chain and holds
the union of its bodies' calls. An overload set's stubs have no body to
contribute and are neither kept nor reported as shadowed. A variable rebound by a
variable is last-wins with no shadow record, for the reason given below. The
figures behind replacement, the accessor merge and the overload merge are 827
methods defined twice in one class body, 276 accessor decorators and 789
@overload decorators in lfia's own virtual environment."
  (cond ((and (py-accessor-p item) (member (getf previous :kind) '(:function :method)))
         (list* :end (getf item :end)
                :calls (append (getf previous :calls) (getf item :calls))
                :decorators (append (getf previous :decorators) (getf item :decorators))
                :env (union (getf previous :env) (getf item :env) :test #'string=)
                :unnamed (+ (getf previous :unnamed) (getf item :unnamed))
                previous))
        ((py-decorated-p previous "overload")
         (list* :shadowed (getf previous :shadowed) item))
        ;; A variable bound again is a rebinding. Nothing is dead: the earlier
        ;; assignment ran and the later one replaced its value. RULE-0006 is about
        ;; a definition that reads like one and never runs, so reporting
        ;; `m = re.fullmatch(...)' written in two module-level loops would be the
        ;; false finding its Lisp accessor carve-out exists to avoid.
        ((and (eq :variable (getf previous :kind)) (eq :variable (getf item :kind)))
         (list* :shadowed (getf previous :shadowed) item))
        (t (list* :shadowed (append (getf previous :shadowed)
                                    (list (py-range previous)))
                  item))))

(defun py-reconcile (items)
  "ITEMS with each name asserted once, in Python's semantics. One module-level
name yields one entity whatever kinds its bindings were, and `Class.name' keys a
method the same way."
  (let ((by-name (make-hash-table :test #'equal))
        (order '()))
    (dolist (item items)
      (let* ((name (getf item :name))
             (previous (gethash name by-name)))
        (unless previous (push name order))
        (setf (gethash name by-name)
              (if previous (py-supersede previous item) item))))
    (mapcar (lambda (name) (gethash name by-name)) (nreverse order))))

;;;; ==================================================================
;;;; Test cases (D8)
;;;; ==================================================================
;;;;
;;;; Recognised by the runners' own defaults, which are facts about two runners
;;;; and not about one repository (DES-0045's reasoning for vitest and jest).
;;;; tools/test/test-*.py match neither pattern: they are scripts run directly,
;;;; so no runner would collect them and no test entity is minted for them.

(defun py-test-file-name-p (path)
  "True when PATH is a file pytest collects by default: `test_*.py' or `*_test.py'."
  (let ((name (pathname-name (pathname path))))
    (and (stringp name)
         (or (and (> (length name) 5) (string= "test_" name :end2 5))
             (and (> (length name) 5) (string= "_test" name :start2 (- (length name) 5)))))))

(defun py-unittest-class-p (item)
  "True when ITEM is a class with a base that binds to unittest.TestCase. The
binding is the child's (D2), so `from unittest import TestCase as T' counts."
  (and (eq :class (getf item :kind))
       (some (lambda (base)
               (and (equal "unittest" (jget base :specifier))
                    (equal '("TestCase") (jlist base :path))))
             (getf item :bases))))

(defun py-test-file-p (path items)
  "True when the runner would run PATH: by its name, or because it defines a
TestCase subclass wherever it sits."
  (or (py-test-file-name-p path) (some #'py-unittest-class-p items)))

(defun py-prefix-p (prefix string)
  (and (>= (length string) (length prefix)) (string= prefix string :end2 (length prefix))))

(defun py-hook-calls (items &rest names)
  "The calls of the items called NAMES, which the runner runs around a case."
  (loop for item in items
        when (member (getf item :name) names :test #'string=)
          append (getf item :calls)))

(defun py-case (item path items unittest-classes)
  "ITEM as a test case, or NIL when it is not one (D8).

A module-level `test*' function counts only in a file pytest collects. A `test*'
method counts in a TestCase subclass wherever it sits, and in a `Test*' class
with no __init__ in a collected file. Its calls include the hooks the runner
runs around it, as DES-0045 D4 does for beforeEach."
  (let* ((name (getf item :name))
         (dot (position #\. name))
         (class (and dot (subseq name 0 dot)))
         (method (if dot (subseq name (1+ dot)) name))
         (collected (py-test-file-name-p path)))
    (flet ((case-of (framework suite hooks)
             (list* :kind :test
                    :name (if suite (format nil "~a::~a" suite method) name)
                    :suite suite :framework framework
                    :calls (append (apply #'py-hook-calls items hooks) (getf item :calls))
                    item)))
      (cond ((not (py-prefix-p "test" method)) nil)
            ((and (eq :function (getf item :kind)) collected)
             (case-of :pytest nil '("setup_function" "teardown_function")))
            ((not (eq :method (getf item :kind))) nil)
            ((member class unittest-classes :test #'string=)
             (case-of :unittest class
                      (list (format nil "~a.setUp" class) (format nil "~a.tearDown" class))))
            ((and collected (py-prefix-p "Test" class)
                  (notany (lambda (i) (string= (getf i :name) (format nil "~a.__init__" class)))
                          items))
             (case-of :pytest class
                      (list (format nil "~a.setup_method" class)
                            (format nil "~a.teardown_method" class))))))))

(defun py-mark-tests (items path)
  "ITEMS with each test case turned into a :TEST, which is not also a :FUNCTION
or a :METHOD. The hooks stay what they are."
  (let ((unittest-classes (loop for item in items
                                when (py-unittest-class-p item) collect (getf item :name))))
    (mapcar (lambda (item) (or (py-case item path items unittest-classes) item)) items)))

;;;; ==================================================================
;;;; Entities
;;;; ==================================================================

(defun py-system-for-path (path)
  "The :SYSTEM for a Python file, which is the path convention (D12). Package-ness
depends on another file's __init__.py, and an analyzer sees one file: deriving
:SYSTEM from it would leave every sibling stale when one is added or deleted."
  (default-system-for-path path))

(defun py-import-modules (imports)
  "One plist per distinct (source, module) over IMPORTS, every scope, absolute
sources only: (:SOURCE s :MODULE m :STDLIB bool). `from S import a' is both S
and S.a, because `a' may be a submodule or a name and the entry cannot tell
which. :STDLIB is absent when the child sent no mark. A relative import is left
out, since it is never external. PLAN-0059 FINDINGS 3, DES-0055 R4."
  (let ((found '()))
    (dolist (import imports (nreverse found))
      (let ((source (jget import :source)))
        (when (and source (plusp (length source)) (char/= #\. (char source 0)))
          (let ((from-p (and (jget import :name) (not (equal "*" (jget import :name))))))
            (dolist (module (if from-p
                                (list source (format nil "~a.~a" source (jget import :name)))
                                (list source)))
              (pushnew (append (list :source source :module module)
                               (when (assoc :stdlib import)
                                 (list :stdlib (and (jget import :stdlib) t))))
                       found :test #'equal))))))))

(defun make-py-file-entity (path contents reply reason test-file-p)
  "The :FILE entity, asserted whether or not anything parsed (D7).

Damage goes to :SUPPRESSED-REGIONS with its exact range, one region per damaged
statement, because a statement that did not parse would have defined things and
did not: DES-0013's second case, and a repaired region is never indexed.
:ANALYSIS-ERROR carries the child's text, which names the interpreter's version,
so an old interpreter reads differently from a broken file. :ANALYSIS-FAILED-P is
set only when nothing parsed or python3 could not run."
  (let* ((damage (jlist reply :damage))
         (items (py-module-items reply))
         (imports (jlist reply :imports))
         (env (remove-duplicates
               (jlist reply :env-reads) :test #'string=))
         (unnamed (+ (or (jget reply :unnamed-env-reads) 0)
                     (reduce #'+ items :key (lambda (item) (getf item :unnamed)))))
         (sources (remove-duplicates
                   (remove nil (mapcar (lambda (i) (jget i :source)) imports))
                   :test #'string= :from-end t))
         (import-modules (py-import-modules imports))
         (bindings (loop for import in imports
                         ;; A star import binds no :LOCAL but is kept, with :NAME
                         ;; "*", because the walk needs to know a module may hold
                         ;; names its own text never wrote (BUG-0071).
                         when (and (equal "module" (jget import :scope))
                                   (or (jget import :local)
                                       (equal "*" (jget import :name))))
                           collect (list :local (jget import :local)
                                         :specifier (jget import :specifier)
                                         :name (jget import :name)))))
    (make-instance 'file-entity
                   :name path
                   :origin-file path
                   :properties
                   (properties-table
                    (append
                     (list :path path
                           :language :python
                           :system (py-system-for-path path)
                           :line-count (or (jget reply :line-count) (line-count contents)))
                     (when (jget reply :docstring)
                       (list :documentation (jget reply :docstring)))
                     (when sources (list :import-sources sources))
                     (when import-modules (list :import-modules import-modules))
                     ;; DES-0045 D7: written on the file, so a file the runner
                     ;; would run and no case was found in is a reportable
                     ;; miss rather than just a source file.
                     (when test-file-p (list :test-file-p t))
                     (when bindings (list :import-bindings bindings))
                     (when env (list :environment-reads env))
                     (when (plusp unnamed) (list :unnamed-environment-reads unnamed))
                     (when (or reason damage)
                       (list :analysis-error (or reason (jget reply :error))))
                     (when (or reason (and damage (eql 0 (jget reply :pieces-parsed))))
                       (list :analysis-failed-p t))
                     (when damage
                       (list :suppressed-regions
                             (loop for region in damage
                                   collect (list :reason "python syntax error"
                                                 :start-line (jget region :start-line)
                                                 :end-line (jget region :end-line))))))))))

(defun py-entity-properties (item path system &rest extra)
  "The properties every Python definition carries. EXTRA is appended whole, for
the reason JS-DEFINITION's FLET gives: dropping its NIL values would pair each
surviving key with the next key along."
  (properties-table
   (append (list :file path :start-line (getf item :start) :end-line (getf item :end)
                 :language :python :system system)
           (when (getf item :documentation)
             (list :documentation (getf item :documentation)))
           (when (getf item :shadowed)
             (list :shadowed-definitions (getf item :shadowed)))
           extra)))

(defun py-callable-properties (item path system)
  "Properties of a :FUNCTION or :METHOD: the call names a :CALLS edge may start
from, and the import-bound calls RESOLVE-CALLS walks (D2, R4)."
  (let ((names (py-call-names (getf item :calls)))
        (imported (py-imported-calls (getf item :calls)))
        (shapes (py-call-shapes (getf item :calls))))
    ;; Each only when non-empty: most definitions have no decorator and read no
    ;; environment, and an empty list on every one of them is noise.
    (apply #'py-entity-properties item path system
           :arguments (getf item :arguments)
           (append (when (getf item :decorators) (list :decorators (getf item :decorators)))
                   (when names (list :call-names names))
                   (when imported (list :imported-calls imported))
                   (when shapes (list :call-shapes shapes))
                   (when (getf item :env) (list :environment-reads (getf item :env)))))))

(defun py-test-properties (item path system)
  "Properties of a :TEST. A test is a legal :CALLS source and takes :CALL-NAMES
and :IMPORTED-CALLS on the terms a function does, so RESOLVE-TESTS derives its
:TESTS edges from the :CALLS edges those produce."
  (let ((names (py-call-names (getf item :calls)))
        (imported (py-imported-calls (getf item :calls)))
        (shapes (py-call-shapes (getf item :calls))))
    (apply #'py-entity-properties item path system
           :suite (getf item :suite) :framework (getf item :framework)
           (append (when names (list :call-names names))
                   (when imported (list :imported-calls imported))
                   (when shapes (list :call-shapes shapes))
                   (when (getf item :env) (list :environment-reads (getf item :env)))))))

(defun make-py-entity (item path system)
  "The entity for one reconciled ITEM."
  (let ((name (getf item :name)))
    (ecase (getf item :kind)
      (:function (make-instance 'function-entity :name name :origin-file path
                                :properties (py-callable-properties item path system)))
      (:method (make-instance 'method-entity :name name :origin-file path
                              :properties (py-callable-properties item path system)))
      (:class (make-instance 'class-entity :name name :origin-file path
                             :properties (py-entity-properties
                                          item path system
                                          :superclass-names
                                          (loop for base in (getf item :bases)
                                                collect (or (jget base :name) (jget base :text)))
                                          :slots (getf item :slots)
                                          :decorators (getf item :decorators))))
      (:test (make-instance 'test-entity :name name :origin-file path
                            :properties (py-test-properties item path system)))
      (:variable (make-instance 'variable-entity :name name :origin-file path
                                :properties (apply #'py-entity-properties
                                                   item path system
                                                   :environment-reads (getf item :env)
                                                   (when (getf item :value-call)
                                                     (list :value-call
                                                           (getf item :value-call)))))))))

;;;; ==================================================================
;;;; Call sites (D4)
;;;; ==================================================================

(defun py-call-site (call path start end kind system)
  "The :CALL-SITE for one CALL, a call made where no definition can own it."
  (let ((imported (equal "import" (jget call :kind))))
    (make-call-site-entity
     :file path :start-line start :end-line end
     :call-name (py-call-key call)
     :referrer-kind kind :language :python :system system
     :imported-calls (when imported (py-imported-calls (list call)))
     :call-shapes (py-call-shapes (list call)))))

(defun py-call-sites (calls path start end kind system)
  "A site per distinct call, deduped on the site's natural key (:file
:start-line :call-name). Two `main()' calls in one guard share a line, and the
writer cannot reconcile two entities of one key (CON-0005). The dropped site's
line is kept: it moves onto the site that stays."
  (let ((kept (make-hash-table :test #'equal)) (sites '()))
    (dolist (call calls (nreverse sites))
      (let* ((site (py-call-site call path start end kind system))
             (first-site (gethash (id site) kept)))
        (if first-site
            (py-merge-site-shapes first-site site)
            (progn (setf (gethash (id site) kept) site)
                   (push site sites)))))))

(defun py-owned-sites (items statements path system)
  "(owner . site) pairs. A variable's and a class's calls belong to that entity,
which no :CALLS edge may start from; a statement's belong to the file (D4).

One pair per site id across all of them. PY-CALL-SITES dedupes inside one item or
statement, but `x = f(); y = f()' is two statements on one line and so two
sites of one natural key (:file :start-line :call-name), which the writer cannot
reconcile (CON-0005). The first owner is kept, and the dropped site's lines move
onto its site."
  (let ((seen (make-hash-table :test #'equal)))
    (remove-if
     (lambda (pair)
       (let ((first-site (gethash (id (cdr pair)) seen)))
         (if first-site
             (progn (py-merge-site-shapes first-site (cdr pair)) t)
             (progn (setf (gethash (id (cdr pair)) seen) (cdr pair)) nil))))
     (append
      (loop for item in items
            for kind = (case (getf item :kind) (:variable :variable) (:class :class))
            when kind
              append (loop for site in (py-call-sites (getf item :calls) path
                                                      (getf item :start) (getf item :end)
                                                      kind system)
                           collect (cons (getf item :name) site)))
      (loop for statement in statements
            append (loop for site in (py-call-sites (jlist statement :calls) path
                                                    (jget statement :start-line)
                                                    (jget statement :end-line)
                                                    :module system)
                         collect (cons nil site)))))))

;;;; ==================================================================
;;;; The analyzer class
;;;; ==================================================================

(defclass python-analyzer (analyzer)
  ()
  (:default-initargs :language :python :file-types '("py"))
  (:documentation "Parses Python through python3's own ast in a child process.

Not `.pyi': a stub beside its module would give `find' two entities for one
definition (DES-0053 R1)."))

;;;; ==================================================================
;;;; Comments
;;;; ==================================================================

(defun py-trim (line)
  (string-trim '(#\Space #\Tab #\Return) line))

(defun py-comment-line-p (line)
  "True when LINE is a `#' comment and not code with a remark after it."
  (let ((s (py-trim line)))
    (and (plusp (length s)) (char= #\# (char s 0)))))

(defmethod comment-line-text ((analyzer python-analyzer) line)
  "LINE without its leading `#' marks."
  (declare (ignore analyzer))
  (py-trim (string-left-trim "#" (py-trim line))))

(defmethod comment-extent ((analyzer python-analyzer) lines start-line)
  "The run of `#' lines above START-LINE, and how it is attached.

Python has one comment form, so this is the Lisp rule with `#' for `;': a block
above the definition. START-LINE is the first decorator's line, which is why the
block is found above the decorators and not between them and the def. :SECTION
is decided by position, as the JavaScript method decides it: no code above the
block means it is about the file."
  (declare (ignore analyzer))
  (let ((i (- start-line 2))
        (gap nil))
    (loop while (and (>= i 0) (blank-line-p (aref lines i)))
          do (setf gap t) (decf i))
    (if (or (minusp i) (not (py-comment-line-p (aref lines i))))
        (values nil nil)
        (let ((j i))
          (loop while (and (>= j 0) (py-comment-line-p (aref lines j))) do (decf j))
          (let ((code-above (loop for k downfrom j to 0
                                  unless (blank-line-p (aref lines k)) return t)))
            (values (+ j 2)
                    (cond ((not code-above) :section)
                          (gap :separated)
                          (t :adjacent))))))))

;;;; ==================================================================
;;;; Claiming files and analyzing them
;;;; ==================================================================

(defparameter *python-excluded-directories*
  '("venv" "site-packages" "dist-packages" "__pycache__")
  "Directory names whose contents are an installed environment or its bytecode.
VENDORED-PATH-P's precedent. The workspace's pyvenv.cfg rule catches a venv with
any other name; this catches one whose marker file is not indexed (D11).")

(defun python-excluded-path-p (path)
  "True when PATH lies under a directory named in *PYTHON-EXCLUDED-DIRECTORIES*."
  (member-if (lambda (segment)
               (and (stringp segment)
                    (member segment *python-excluded-directories* :test #'string=)))
             (rest (pathname-directory (pathname path)))))

(defmethod analyzer-handles-p ((analyzer python-analyzer) path)
  (and (call-next-method) (not (python-excluded-path-p path))))

(defmethod analyze-file ((analyzer python-analyzer) path contents workspace-id)
  "Ontology operations for one Python file.

Always a :FILE entity, whatever happened: a file analyzed on a machine with no
python3, and a file the child could not parse at all, are both indexed with the
reason recorded on them (D1, D7)."
  (multiple-value-bind (reply reason) (parse-python path contents)
    (let* ((system (py-system-for-path path))
           (reconciled (py-reconcile (py-module-items reply)))
           (items (py-mark-tests reconciled path))
           (entities (mapcar (lambda (item) (make-py-entity item path system)) items))
           (owned (py-owned-sites items (jlist reply :statements) path system))
           (file (make-py-file-entity path contents reply reason
                                      (py-test-file-p path reconciled))))
      (attach-comment-documentation analyzer entities (string-lines contents))
      (append
       (list (retract-file path workspace-id)
             (assert-entity file workspace-id))
       (loop for entity in entities
             collect (assert-entity entity workspace-id)
             collect (assert-edge :contains file entity :workspace-id workspace-id))
       ;; After every definition, so an owner's assert is already planned when
       ;; the edge naming it is (lisp-analyzer.lisp's pass 3).
       (loop for (owner . site) in owned
             collect (assert-entity site workspace-id)
             collect (assert-edge :contains
                                  (or (and owner (find owner entities :key #'name
                                                                      :test #'string=))
                                      file)
                                  site :workspace-id workspace-id))))))

(register-analyzer (make-instance 'python-analyzer))
