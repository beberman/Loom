;;;
;;; Tests for src/analyzer/python-analyzer.lisp -- DES-0053 D3, D4, D9, D10,
;;; D11 and R11.
;;;
;;; Sources are strings and the paths are made up, for the reason
;;; python-extract.lisp gives: a fixture file in this tree would be claimed.
;;; Each test runs ANALYZE-FILE and applies the operations to a graph, so what
;;; is asserted is what the index would hold. A machine without python3 skips
;;; (CALL-WITH-PYTHON); PLAN-0056 risk 10 says this suite takes none here.
;;;

(in-package :loom-analyzer-test)

(def-suite python-analyzer
  :in all-tests
  :description "The Python analyzer: entities, call sites, reconciliation, environment reads.")

(in-suite python-analyzer)

;;; ------------------------------------------------------------------
;;; Harness
;;; ------------------------------------------------------------------

(defun pa-graph (path source)
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'loom-analyzer::python-analyzer)
                                       path source "ws-test"))
    g))

(defun pa-entities (g &optional type)
  (let ((all (all-entities g)))
    (if type (remove-if-not (lambda (e) (eq type (entity-type e))) all) all)))

(defun pa-named (g name &optional type)
  (find-if (lambda (e) (and (equal name (name e))
                            (or (null type) (eq type (entity-type e)))))
           (pa-entities g)))

(defun pa-file (g) (first (pa-entities g :file)))

(defun pa-sites (g &optional kind)
  (let ((sites (pa-entities g :call-site)))
    (if kind (remove-if-not (lambda (s) (eq kind (getp s :referrer-kind))) sites) sites)))

(defun pa-props-text (entity)
  (with-output-to-string (out)
    (maphash (lambda (key value) (format out "~s ~s " key value)) (properties entity))))

(defun pa-site-names (g kind)
  (sort (mapcar (lambda (s) (getp s :call-name)) (pa-sites g kind)) #'string<))

;;; ------------------------------------------------------------------
;;; Dispatch (R1, R11)
;;; ------------------------------------------------------------------

(test the-analyzer-claims-py-and-not-pyi
  (let ((analyzer (make-instance 'loom-analyzer::python-analyzer)))
    (is-true (analyzer-handles-p analyzer "functions/main.py"))
    (is-false (analyzer-handles-p analyzer "functions/main.pyi")
              "a stub beside its module would give find two entities for one definition")))

(test a-path-under-an-environment-directory-is-not-claimed
  (let ((analyzer (make-instance 'loom-analyzer::python-analyzer)))
    (dolist (path '("functions/venv/lib/x.py"
                    "lib/python3.12/site-packages/x.py"
                    "usr/dist-packages/x.py"
                    "pkg/__pycache__/x.py"))
      (is-false (analyzer-handles-p analyzer path) "~a is somebody else's code" path))
    (is-true (analyzer-handles-p analyzer "functions/venvs.py")
             "the rule is a directory segment, not a substring")
    (is-true (analyzer-handles-p analyzer "tools/venv.py"))))

;;; ------------------------------------------------------------------
;;; D3: what gets an entity
;;; ------------------------------------------------------------------

(test each-definition-kind-becomes-its-entity-type
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "functions/m.py" "\"\"\"The module.\"\"\"
import os
LIMIT = 3
def run(a, b=1):
    \"\"\"Runs.\"\"\"
    return a
class Box(Base):
    size = 1
    def open(self): pass
")))
       (is (eq :function (entity-type (pa-named g "run"))))
       (is (eq :class (entity-type (pa-named g "Box"))))
       (is (eq :method (entity-type (pa-named g "Box.open"))))
       (is (eq :variable (entity-type (pa-named g "LIMIT"))))
       (let ((file (pa-file g)))
         (is (eq :python (getp file :language)))
         (is (equal "The module." (getp file :documentation)))
         (is (equal '("os") (getp file :import-sources)))
         (is (equal '((:local "os" :specifier "os" :name nil))
                    (getp file :import-bindings))))
       (is (equal '("a" "b=1") (getp (pa-named g "run") :arguments)))
       (is (equal "Runs." (getp (pa-named g "run") :documentation)))
       (is (equal '("Base") (getp (pa-named g "Box") :superclass-names)))
       (is (equal '("size") (getp (pa-named g "Box") :slots)))
       (is (eq :functions (getp (pa-named g "run") :system))
           "the path convention, as for JavaScript (D12)")))))

(test a-star-import-is-kept-as-a-binding-with-no-local
  ;; BUG-0071. Without it the index cannot tell a module that star-imports from
  ;; one that does not, and the walk reports a name the star would have bound.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "app/pkg/__init__.py" "from .impl import *
import os
def f():
    from .inner import *
" )))
       (is (equal '((:local nil :specifier ".impl" :name "*")
                    (:local "os" :specifier "os" :name nil))
                  (getp (pa-file g) :import-bindings))
           "module level only: the star inside f is a function-scope import")))))

(test the-file-contains-each-definition
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "def a(): pass
class C:
    def m(self): pass
"))
            (file (pa-file g)))
       (is (equal '("C" "C.m" "a")
                  (sort (mapcar (lambda (r) (name (get-entity g (to-id r))))
                                (relationships-from g (id file) :rel-type :contains))
                        #'string<)))))))

(test a-nested-def-mints-nothing-and-its-calls-land-on-the-enclosing-function
  ;; ledger/refs.py's `advance', defined inside lease_block.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "functions/ledger/refs.py" "def lease_block():
    def advance():
        step()
    advance()
def step(): pass
")))
       (is (null (pa-named g "advance")))
       (is (equal '("step") (getp (pa-named g "lease_block") :call-names)))))))

(test start-line-is-the-first-decorator-and-a-comment-above-it-is-the-documentation
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "import functools
# Retries the call.
@functools.cache
@other
def f():
    \"\"\"Docstring.\"\"\"
"))
            (f (pa-named g "f")))
       (is (= 3 (getp f :start-line)))
       (is (equal "Retries the call.
Docstring." (getp f :documentation)))))))

(test decorators-are-recorded-with-their-resolved-path-and-literal-arguments
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "functions/main.py" "from firebase_functions import scheduler_fn as sf
@sf.on_schedule(schedule='every 1 hours', timeout_sec=540, retry=False, memory=None, secrets=[KEY], region=pick())
def sync(): pass
"))
            (decorator (first (getp (pa-named g "sync") :decorators))))
       (is (equal "firebase_functions" (getf decorator :specifier)))
       (is (equal '("scheduler_fn" "on_schedule") (getf decorator :path)))
       (is (equal '(("schedule" . "every 1 hours") ("timeout_sec" . 540)
                    ("retry" . :false) ("memory" . :none) ("secrets" "KEY")
                    ("region" . :expression))
                  (getf decorator :arguments)))
       (is (equal '((:specifier "firebase_functions" :path ("scheduler_fn" "on_schedule")
                     :line 2))
                  (getp (pa-named g "sync") :imported-calls))
           "a decorator is a call made by what it decorates")))))

;;; ------------------------------------------------------------------
;;; D2 into properties: names and imported calls
;;; ------------------------------------------------------------------

(test import-bound-calls-are-imported-calls-and-the-rest-are-call-names
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "functions/main.py" "import sheets
from sheets import read_tab as _read
def helper(): pass
def run(obj):
    helper()
    sheets.clear()
    _read()
    obj.go()
    print('x')
    _read()
"))
            (run (pa-named g "run")))
       (is (equal '("helper" "obj.go") (getp run :call-names)))
       (is (equal '((:specifier "sheets" :path ("clear") :line 6)
                    (:specifier "sheets" :path ("read_tab") :line 7))
                  (getp run :imported-calls))
           "the alias is undone and a repeated call is one entry")))))

;;; ------------------------------------------------------------------
;;; D4: calls with no definition to start from
;;; ------------------------------------------------------------------

(test the-six-guard-shapes-yield-module-sites
  (call-with-python
   (lambda ()
     (dolist (shape '("if __name__ == '__main__':
    main()
"
                      "main()
"
                      "if __name__ == '__main__':
    sys.exit(main())
"
                      "if __name__ == '__main__':
    asyncio.run(main())
"
                      "try:
    main()
except KeyboardInterrupt:
    pass
"
                      "with open('x') as f:
    main()
"))
       (let ((g (pa-graph "tools/t.py" (format nil "import sys, asyncio~%def main(): pass~%~a" shape))))
         (is (member "main" (mapcar (lambda (s) (getp s :call-name)) (pa-sites g :module))
                     :test #'string=)
             "no :module site for main in:~%~a" shape))))))

(test a-module-site-is-contained-by-the-file-and-carries-an-import-binding
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "tools/test/acceptance.py" "import service
if __name__ == '__main__':
    service.ensure()
"))
            (site (first (pa-sites g :module))))
       (is (equal "service.ensure" (getp site :call-name)))
       (is (equal '((:specifier "service" :path ("ensure") :line 3))
                  (getp site :imported-calls)))
       (is (= 2 (getp site :start-line)) "the statement's line")
       (is (equal (list (id (pa-file g)))
                  (mapcar #'from-id (relationships-to g (id site) :rel-type :contains))))))))

(test two-calls-of-one-name-in-one-guard-yield-one-site
  ;; CON-0005: a site's key is (:file :start-line :call-name) and the start line
  ;; is the statement's. Counted in the operations, because the graph upserts by
  ;; natural key and would hide a second assert: it is the writer that cannot
  ;; reconcile two, and the analyzer's job to send one.
  (call-with-python
   (lambda ()
     (let* ((ops (analyze-file (make-instance 'loom-analyzer::python-analyzer)
                               "tools/t.py" "def main(): pass
if __name__ == '__main__':
    main()
    main()
" "ws-test"))
            (sites (remove-if-not
                    (lambda (op)
                      (and (typep op 'assert-entity-op)
                           (eq :call-site (entity-type (op-entity op)))))
                    ops)))
       (is (= 1 (length sites)))))))

(defun pa-site-ids (source)
  "The id of every :CALL-SITE assert the analyzer emits for SOURCE, in the
operations and not the graph, which would upsert a second assert away."
  (mapcar (lambda (op) (id (op-entity op)))
          (remove-if-not (lambda (op)
                           (and (typep op 'assert-entity-op)
                                (eq :call-site (entity-type (op-entity op)))))
                         (analyze-file (make-instance 'loom-analyzer::python-analyzer)
                                       "app/m.py" source "ws-test"))))

(test calls-of-one-name-on-one-line-joined-by-semicolons-yield-one-site
  ;; REV-0003 item 6. `;' makes separate statements on one line, and a site's
  ;; key is its line and name, so PY-CALL-SITES' dedupe within a statement cannot
  ;; see the second. Each shape below emitted the same id twice before.
  (call-with-python
   (lambda ()
     (dolist (source '("x = f(); y = f()
" "f(); f()
" "x = f(); f()
"))
       (let ((ids (pa-site-ids source)))
         (is (= 1 (length ids)) "one site for ~s: ~a" source ids))))))

(test a-variable-and-a-class-own-their-calls-as-sites
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "src/m.py" "import logging
log = logging.getLogger('x')
class Handler(make_base()):
    pass
")))
       (is (equal '("logging.getLogger") (pa-site-names g :variable)))
       (is (equal '("make_base") (pa-site-names g :class)))
       (is (equal (list (id (pa-named g "log")))
                  (mapcar #'from-id
                          (relationships-to g (id (first (pa-sites g :variable)))
                                            :rel-type :contains))))))))

;;; ------------------------------------------------------------------
;;; D9: reconciliation (CON-0005)
;;; ------------------------------------------------------------------

(test two-defs-of-one-name-yield-one-entity-and-shadow-the-first
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "def f():
    first()
def f():
    second()
"))
            (f (pa-named g "f")))
       (is (= 1 (length (pa-entities g :function))))
       (is (equal '("second") (getp f :call-names)))
       (is (equal '("1-2") (getp f :shadowed-definitions)))))))

(test a-later-binding-of-another-kind-replaces-the-def
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "src/m.py" "def f(): pass
f = 3
")))
       (is (null (pa-entities g :function)))
       (is (eq :variable (entity-type (pa-named g "f"))))
       (is (equal '("1-1") (getp (pa-named g "f") :shadowed-definitions)))))))

(test a-variable-bound-twice-is-one-entity-and-nothing-is-shadowed
  ;; Reported by RULE-0006 on tools/test/test-next-doc-id.py, where `m' is the
  ;; match variable of two module-level loops. Neither assignment is dead code.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "src/m.py" "for a in x:
    m = first(a)
for b in y:
    m = second(b)
")))
       (is (= 1 (length (pa-entities g :variable))))
       (is (= 4 (getp (pa-named g "m") :start-line)) "the last binding wins")
       (is (null (getp (pa-named g "m") :shadowed-definitions)))))))

(test a-property-chain-is-one-method-with-both-bodies-calls
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "class C:
    @property
    def x(self):
        read()
    @x.setter
    def x(self, v):
        write()
"))
            (x (pa-named g "C.x")))
       (is (= 1 (length (pa-entities g :method))))
       (is (equal '("read" "write") (sort (copy-list (getp x :call-names)) #'string<)))
       (is (= 2 (getp x :start-line)))
       (is (= 7 (getp x :end-line)) "the entity spans the chain")
       (is (null (getp x :shadowed-definitions)) "none of it is shadowed")))))

(test an-overload-set-is-the-implementation-with-no-shadow
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "from typing import overload
@overload
def f(a: int) -> int: ...
@overload
def f(a: str) -> str: ...
def f(a):
    work()
"))
            (f (pa-named g "f")))
       (is (= 1 (length (pa-entities g :function))))
       (is (equal '("work") (getp f :call-names)))
       (is (= 6 (getp f :start-line)))
       (is (null (getp f :shadowed-definitions)))))))

;;; ------------------------------------------------------------------
;;; D10: environment reads
;;; ------------------------------------------------------------------

(test config-shaped-reads-land-on-eight-variables
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "functions/config.py" "import os
A = os.environ.get('A', '')
B = os.getenv('B')
C = os.environ['C']
D = os.environ.setdefault('D', 'x')
E = os.environ.get('E')
F = os.environ.get('F', 'f')
G = os.getenv('G', 'g')
H = os.environ.get('H')
")))
       (dolist (name '("A" "B" "C" "D" "E" "F" "G" "H"))
         (is (equal (list name) (getp (pa-named g name :variable) :environment-reads))
             "~a reads itself" name))
       (is (null (getp (pa-file g) :environment-reads)))))))

(test reads-land-on-the-innermost-entity-and-the-rest-on-the-file
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "src/m.py" "import os
def f():
    return os.environ.get('IN_F', 'secret-default')
os.environ.get('AT_TOP')
os.environ.get(name)
")))
       (is (equal '("IN_F") (getp (pa-named g "f") :environment-reads)))
       (is (equal '("AT_TOP") (getp (pa-file g) :environment-reads)))
       (is (eql 1 (getp (pa-file g) :unnamed-environment-reads)))
       (is (not (search "secret-default"
                        (format nil "~a ~a" (pa-props-text (pa-named g "f"))
                                (pa-props-text (pa-file g)))))
           "a default value is never recorded")))))

;;; ------------------------------------------------------------------
;;; D7: damage
;;; ------------------------------------------------------------------

(test a-broken-second-statement-keeps-the-first-ones-entities
  (call-with-python
   (lambda ()
     (let* ((g (pa-graph "src/m.py" "def good(): pass
def bad(:
    pass
"))
            (file (pa-file g)))
       (is-true (pa-named g "good"))
       (is-false (getp file :analysis-failed-p) "a piece parsed")
       (is (equal '((:reason "python syntax error" :start-line 2 :end-line 3))
                  (getp file :suppressed-regions)))
       (is (search "python 3" (getp file :analysis-error))
           "the text names the interpreter: ~a" (getp file :analysis-error))))))

(test a-file-nothing-of-which-parses-is-marked-failed
  (call-with-python
   (lambda ()
     (let ((file (pa-file (pa-graph "src/m.py" "def bad(:
"))))
       (is-true (getp file :analysis-failed-p))))))

;;; ------------------------------------------------------------------
;;; No interpreter (R1)
;;; ------------------------------------------------------------------

(test a-missing-interpreter-is-recorded-not-fatal
  (loom-analyzer::stop-extractor-child loom-analyzer::*py-extractor-child*)
  (unwind-protect
       (let* ((loom-analyzer::*python-program* "loom-no-such-python-should-exist")
              (g (pa-graph "src/m.py" "def f(): pass
"))
              (file (pa-file g)))
         (is-true file "the file is indexed with no toolchain")
         (is-true (getp file :analysis-failed-p))
         (is-true (search "loom-no-such-python-should-exist" (or (getp file :analysis-error) ""))
                  "the reason names what was missing")
         (is (null (pa-named g "f"))))
    (loom-analyzer::stop-extractor-child loom-analyzer::*py-extractor-child*)
    (setf (loom-analyzer::child-unavailable-reason loom-analyzer::*py-extractor-child*) nil)))

;;; ------------------------------------------------------------------
;;; D8: test cases
;;; ------------------------------------------------------------------

(defun pa-test-names (g)
  (sort (mapcar #'name (pa-entities g :test)) #'string<))

(test a-test-function-in-a-pytest-file-is-a-test-and-not-also-a-function
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "functions/tests/test_refs.py" "from ledger import refs
def test_lease():
    refs.lease()
def helper(): pass
")))
       (is (equal '("test_lease") (pa-test-names g)))
       (let ((case (pa-named g "test_lease")))
         (is (eq :pytest (getp case :framework)))
         (is (eq :python (getp case :language)))
         (is (equal '((:specifier "ledger" :path ("refs" "lease") :line 3))
                    (getp case :imported-calls))))
       (is (equal '("helper") (mapcar #'name (pa-entities g :function)))
           "the case is not also a :function")
       (is-true (getp (pa-file g) :test-file-p))))))

(test a-testcase-subclass-gives-unittest-cases-in-a-file-no-pattern-matches
  ;; tests/checks.py matches neither pytest pattern, so only the base class says
  ;; it is a test file. `as T' is undone by the child's binding.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "tests/checks.py" "from unittest import TestCase as T
class Ledger(T):
    def setUp(self):
        prepare()
    def tearDown(self):
        clean()
    def test_post(self):
        post()
def test_loose(): pass
")))
       (is (equal '("Ledger::test_post") (pa-test-names g)))
       (let ((case (pa-named g "Ledger::test_post")))
         (is (eq :unittest (getp case :framework)))
         (is (equal "Ledger" (getp case :suite)))
         (is (equal '("prepare" "clean" "post")
                    (getp case :call-names))
             "setUp and tearDown are part of what the case runs"))
       (is-true (pa-named g "Ledger.setUp" :method) "the hooks stay methods")
       (is-true (pa-named g "test_loose" :function)
                "pytest would not collect a function from checks.py")
       (is-true (getp (pa-file g) :test-file-p))))))

(test a-test-class-with-an-init-gives-no-cases-and-one-without-gives-pytest-cases
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "tests/test_x.py" "class TestA:
    def __init__(self): pass
    def test_one(self): pass
class TestB:
    def setup_method(self):
        arrange()
    def test_two(self):
        act()
")))
       (is (equal '("TestB::test_two") (pa-test-names g)))
       (is (equal '("arrange" "act") (getp (pa-named g "TestB::test_two") :call-names)))
       (is (eq :pytest (getp (pa-named g "TestB::test_two") :framework)))
       (is-true (pa-named g "TestA.test_one" :method)
                "a class pytest would not collect keeps its methods")))))

(test a-script-named-with-a-hyphen-is-no-test-file
  ;; tools/test/test-acceptance.py. Run directly, collected by nothing.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "tools/test/test-acceptance.py" "def test_it(): pass
")))
       (is (null (pa-entities g :test)))
       (is-false (getp (pa-file g) :test-file-p))
       (is-true (pa-named g "test_it" :function))))))

(test a-pytest-file-with-no-case-is-still-a-test-file
  ;; The report that a convention was missed: status' test-files-without-cases.
  (call-with-python
   (lambda ()
     (let ((g (pa-graph "tests/test_none.py" "def helper(): pass
")))
       (is (null (pa-entities g :test)))
       (is-true (getp (pa-file g) :test-file-p))))))
