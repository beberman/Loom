;;;
;;; Tests for tools/py/extract.py through PARSE-PYTHON -- DES-0053 D1, D2, D7,
;;; D10 and R2.
;;;
;;; The sources are strings in this file and never files in the tree: a fixture
;;; named test_x.py under src/ would be claimed by the Python analyzer and add
;;; cases and a `main' to Loom's own index (PLAN-0056 risk 8).
;;;
;;; What these assert is the child's reply. What the analyzer makes of it is
;;; python-analyzer.lisp's, and is tested there.
;;;

(in-package :loom-analyzer-test)

(def-suite python-extract
  :in all-tests
  :description "tools/py/extract.py: scoping, binding, damage and environment reads (DES-0053).")

(in-suite python-extract)

;;; ------------------------------------------------------------------
;;; Harness
;;; ------------------------------------------------------------------

(defun py-reply (source &optional (path "src/m.py"))
  "The child's decoded reply for SOURCE."
  (multiple-value-bind (reply reason) (loom-analyzer::parse-python path source)
    (unless reply (error "no reply: ~a" reason))
    reply))

(defun py-get (alist key) (cdr (assoc key alist)))

(defun py-def (reply name)
  (find name (py-get reply :definitions) :key (lambda (d) (py-get d :name)) :test #'equal))

(defun py-calls (entity)
  "ENTITY's calls as short lists, so an assertion reads like the table in
DES-0053 D2: (:import \"sheets\" (\"upsert\")), (:local \"helper\"), ..."
  (mapcar (lambda (call)
            (let ((kind (py-get call :kind)))
              (if (equal kind "import")
                  (list :import (py-get call :specifier) (py-get call :path))
                  (list (intern (string-upcase kind) :keyword) (py-get call :name)))))
          (py-get entity :calls)))

(defun py-calls-of (reply name)
  (py-calls (py-def reply name)))

;;; ------------------------------------------------------------------
;;; D2: each binding
;;; ------------------------------------------------------------------

(test a-call-to-a-module-level-def-is-local
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def helper(): pass
def run():
    helper()
")))
       (is (equal '((:local "helper")) (py-calls-of reply "run")))))))

(test a-call-through-an-import-is-written-as-specifier-and-path
  ;; D2's five worked pairs. The alias is undone: `_read' is read_tab.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "from sheets import upsert
import sheets
from sheets import read_tab as _read
from ledger import dates
import google.auth
def a(): upsert()
def b(): sheets.clear()
def c(): _read()
def d(): dates.parse()
def e(): google.auth.default()
")))
       (is (equal '((:import "sheets" ("upsert"))) (py-calls-of reply "a")))
       (is (equal '((:import "sheets" ("clear"))) (py-calls-of reply "b")))
       (is (equal '((:import "sheets" ("read_tab"))) (py-calls-of reply "c")))
       (is (equal '((:import "ledger" ("dates" "parse"))) (py-calls-of reply "d")))
       (is (equal '((:import "google" ("auth" "default"))) (py-calls-of reply "e")))))))

(test a-relative-import-keeps-its-dots-in-the-specifier
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "from .posting import post
from .. import util
def a(): post()
def b(): util.go()
")))
       (is (equal '((:import ".posting" ("post"))) (py-calls-of reply "a")))
       (is (equal '((:import ".." ("util" "go"))) (py-calls-of reply "b")))))))

(test self-and-cls-calls-in-a-method-are-the-classs-own
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "class C:
    def m(self):
        self.n()
    @classmethod
    def k(cls):
        cls.n()
    def n(self): pass
")))
       (is (equal '((:self "C.n")) (py-calls-of reply "C.m")))
       (is (member '(:self "C.n") (py-calls-of reply "C.k") :test #'equal))))))

(test a-call-on-a-local-or-an-expression-is-a-member-call
  ;; "obj.m" for a name receiver, a bare "m" for an expression receiver, as
  ;; extract.js reports them.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def f(obj):
    obj.run()
    make().go()
")))
       (is (member '(:member "obj.run") (py-calls-of reply "f") :test #'equal))
       (is (member '(:member "go") (py-calls-of reply "f") :test #'equal))))))

(test a-builtin-is-dropped-and-so-is-a-call-on-a-builtin
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def f(xs):
    print(len(xs))
    return ', '.join(str.lower(x) for x in xs)
")))
       (is (equal '((:member "join")) (py-calls-of reply "f"))
           "print and len are dropped; str.lower has a language global as receiver;
only the join on a literal survives, as an expression receiver")))))

(test a-parameter-used-as-a-callee-is-dropped
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def apply(callback):
    callback()
")))
       (is (null (py-calls-of reply "apply")))))))

(test a-function-local-import-binds-only-in-that-function
  ;; main.py's read_tab does exactly this.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def f():
    import sheets
    sheets.clear()
def g():
    sheets = 1
    sheets.clear()
")))
       (is (equal '((:import "sheets" ("clear"))) (py-calls-of reply "f")))
       (is (equal '((:member "sheets.clear")) (py-calls-of reply "g")))))))

(test a-class-body-does-not-enclose-its-methods-names
  ;; Python looks a name up in the class's own scope only while the class body
  ;; runs. The call in m reaches the module's helper, not the class attribute.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def helper(): pass
class C:
    helper = 2
    def m(self):
        helper()
")))
       (is (equal '((:local "helper")) (py-calls-of reply "C.m")))))))

(test a-comprehension-variable-is-not-a-module-name
  ;; The comprehension's own `parser' shadows the import inside it only.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import parser
def f(handlers):
    return [parser() for parser in handlers]
def g():
    parser.parse()
")))
       (is (null (py-calls-of reply "f")))
       (is (equal '((:import "parser" ("parse"))) (py-calls-of reply "g")))))))

(test global-makes-the-lookup-go-to-the-module
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import sheets
def f():
    global sheets
    sheets.clear()
def g():
    sheets = 1
    sheets.clear()
")))
       (is (equal '((:import "sheets" ("clear"))) (py-calls-of reply "f")))
       (is (equal '((:member "sheets.clear")) (py-calls-of reply "g")))))))

(test an-unbound-name-that-is-no-builtin-stays-a-bare-name
  ;; DES-0053 DEFERRED, `from x import *': a gap, not a guess.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def f(): mystery()
")))
       (is (equal '((:local "mystery")) (py-calls-of reply "f")))))))

(test a-nested-def-is-not-an-entity-and-its-calls-belong-to-the-enclosing-one
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def lease_block():
    def advance():
        step()
    advance()
def step(): pass
")))
       (is (null (py-def reply "advance")))
       (is (equal '((:local "step")) (py-calls-of reply "lease_block")))))))

(test a-decorator-is-a-call-made-by-what-it-decorates
  (call-with-python
   (lambda ()
     (let* ((reply (py-reply "from firebase_functions import scheduler_fn as sf
def retry(f): return f
@retry
@sf.on_schedule(schedule='every 1 hours', timeout_sec=540, secrets=[KEY], region=pick())
def sync(): pass
"))
            (sync (py-def reply "sync"))
            (decorators (py-get sync :decorators)))
       (is (member '(:local "retry") (py-calls sync) :test #'equal))
       (is (member '(:import "firebase_functions" ("scheduler_fn" "on_schedule"))
                   (py-calls sync) :test #'equal))
       (is (= 3 (py-get sync :start-line)) "the first decorator's line")
       (is (= 5 (py-get sync :def-line)))
       (let ((on-schedule (second decorators)))
         (is (equal "sf.on_schedule" (py-get on-schedule :name)))
         (is (equal "firebase_functions" (py-get on-schedule :specifier)))
         (is (equal '("scheduler_fn" "on_schedule") (py-get on-schedule :path)))
         (let ((args (py-get on-schedule :arguments)))
           (is (equal "every 1 hours"
                      (py-get (py-get (find "schedule" args :key (lambda (a) (py-get a :name))
                                                           :test #'equal)
                                      :value)
                              :value)))
           (is (equal '("KEY")
                      (py-get (py-get (find "secrets" args :key (lambda (a) (py-get a :name))
                                                          :test #'equal)
                                      :value)
                              :value)))
           (is (equal "expression"
                      (py-get (py-get (find "region" args :key (lambda (a) (py-get a :name))
                                                          :test #'equal)
                                      :value)
                              :kind)))))))))

(test arguments-are-recorded-as-written
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def f(a, b: int = 1, /, c=2, *args, d: float, **kw): pass
def g(a, *, k): pass
")))
       (is (equal '("a" "b: int = 1" "/" "c=2" "*args" "d: float" "**kw")
                  (py-get (py-def reply "f") :arguments)))
       (is (equal '("a" "*" "k") (py-get (py-def reply "g") :arguments)))))))

(test a-class-records-its-bases-with-the-alias-undone-and-its-slots
  (call-with-python
   (lambda ()
     (let* ((reply (py-reply "from unittest import TestCase as T
class Checks(T):
    '''Docs.'''
    a: int
    b = 1
"))
            (class (py-def reply "Checks"))
            (base (first (py-get class :bases))))
       (is (equal "unittest" (py-get base :specifier)))
       (is (equal "TestCase" (py-get base :name)) "T is TestCase")
       (is (equal '("a" "b") (py-get class :slots)))
       (is (equal "Docs." (py-get class :docstring)))))))

;;; ------------------------------------------------------------------
;;; D10: environment reads
;;; ------------------------------------------------------------------

(test an-environment-read-through-an-alias-records-the-key-and-not-the-default
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "from os import environ as E
def f():
    return E.get('K', 'v')
")))
       (is (equal '("K") (py-get (py-def reply "f") :env-reads))
           "K and not v: the default is never recorded")))))

(test a-parameter-default-that-reads-the-environment-is-not-kept-in-the-arguments
  ;; REV-0003 item 7. D10 promises the default of a read is never recorded, and
  ;; :ARGUMENTS holds a parameter as written. The parameter and its `=' stay,
  ;; because the arity reads the `=' to know it is optional; only the text goes.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import os
def f(token=os.environ.get('TOKEN', 'hunter2'), n=3, *, k: str = os.getenv('K', 'secret')): pass
")))
       (is (equal '("token=" "n=3" "*" "k: str = ")
                  (py-get (py-def reply "f") :arguments)))
       (is (equal '("TOKEN" "K") (py-get (py-def reply "f") :env-reads))
           "the read itself is still recorded")))))

(test every-spelling-of-an-environment-read-is-recognised
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import os
def f():
    return (os.environ.get('A') + os.getenv('B') + os.environ['C']
            + os.environ.setdefault('D', 'x'))
")))
       (is (equal '("A" "B" "C" "D") (py-get (py-def reply "f") :env-reads)))))))

(test a-module-level-read-lands-on-its-variable-and-a-bare-one-on-the-file
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import os
SPREADSHEET_ID = os.environ.get('SPREADSHEET_ID', '')
os.environ.get('LOOSE')
")))
       (is (equal '("SPREADSHEET_ID")
                  (py-get (first (py-get reply :variables)) :env-reads)))
       (is (equal '("LOOSE") (py-get reply :env-reads)))))))

(test a-read-with-no-literal-key-is-counted-and-not-named
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import os
def f(name):
    return os.environ.get(name)
")))
       (is (null (py-get (py-def reply "f") :env-reads)))
       (is (= 1 (py-get (py-def reply "f") :unnamed-env-reads)))))))

(test an-environ-write-is-not-a-read
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "import os
def f():
    os.environ['A'] = 'x'
")))
       (is (null (py-get (py-def reply "f") :env-reads)))))))

;;; ------------------------------------------------------------------
;;; D7: a syntax error costs its statement
;;; ------------------------------------------------------------------

(test a-syntax-error-in-the-second-statement-keeps-the-first
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def a():
    return 1

def b(:
    pass
")))
       (is (py-def reply "a") "the first statement's definitions survive")
       (is (null (py-def reply "b")))
       (let ((damage (first (py-get reply :damage))))
         (is (= 4 (py-get damage :start-line)))
         (is (= 5 (py-get damage :end-line)) "the second statement's exact range"))
       (is (= 1 (py-get reply :pieces-parsed)))))))

(test the-error-text-names-the-interpreter
  ;; python3 3.12 cannot parse 3.13 syntax, and the version is how a reader
  ;; tells the interpreter's age from the file's.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "def b(:
")))
       (is (search "python 3." (py-get reply :error)))
       (is (zerop (py-get reply :pieces-parsed)))
       (is (search (subseq (py-get reply :python-version) 0 4)
                   (py-get reply :error)))))))

(test a-valid-if-else-beside-damage-is-not-reported-as-damage
  ;; A column-0 `else:' continues the `if'. Split there, the `if' parses alone
  ;; and the `else' does not, and a valid statement would be reported damaged.
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "if X:
    a = 1
else:
    a = 2
@deco
def f(: pass
")))
       (is (= 1 (length (py-get reply :damage))))
       (is (= 5 (py-get (first (py-get reply :damage)) :start-line))
           "the damage starts at the decorator: it and its def are one statement")
       (is (find "a" (py-get reply :variables) :key (lambda (v) (py-get v :name))
                                               :test #'equal))))))

(test a-multi-line-string-and-a-bracket-do-not-split-a-statement
  (call-with-python
   (lambda ()
     (let ((reply (py-reply "X = [1,
2]
Y = '''
def not_a_statement():
'''
def broken(: pass
")))
       (is (= 1 (length (py-get reply :damage))))
       (is (= 6 (py-get (first (py-get reply :damage)) :start-line)))
       (is (= 2 (length (py-get reply :variables))))))))

;;; ------------------------------------------------------------------
;;; R2: nothing it reads is run
;;; ------------------------------------------------------------------

(test the-child-never-runs-what-it-reads
  ;; The source's top level would write a marker file if executed. Change
  ;; extract.py to exec the source and this fails; that is CON-0003's check for
  ;; this test.
  (call-with-python
   (lambda ()
     (let ((marker (marker-path)))
       (unwind-protect
            (progn
              (py-reply (format nil "open('~a', 'w').write('ran')
import os
os.system('touch ~a')
def f(): pass
" marker marker))
              (is-false (probe-file marker)
                        "the marker exists only if the source was executed"))
         (ignore-errors (delete-file marker)))))))

(test the-reply-for-one-file-does-not-disturb-the-next
  (call-with-python
   (lambda ()
     (py-reply "def a(: pass")
     (let ((reply (py-reply "def ok(): pass
" "src/second.py")))
       (is (equal "src/second.py" (py-get reply :path)))
       (is (py-def reply "ok"))
       (is (null (py-get reply :damage)))))))
