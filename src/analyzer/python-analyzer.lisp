;;;; The Python analyzer -- DES-0053, REQ-0078 R1 to R6.
;;;;
;;;; Like the JavaScript analyzer this parses in a long-lived child process, and
;;;; the process lifecycle is extractor-child.lisp's (R14). The child is python3
;;;; running its own `ast' (D1): it reads text and imports, executes and compiles
;;;; nothing, so it works on code whose dependencies are not installed. A tree
;;;; analyzed on a machine with no python3 still indexes every .py file, with
;;;; the reason recorded on each.
;;;;
;;;; This half of the file is the child and nothing else. The decisions about
;;;; what the child's reply means -- entities, call sites, tests, reconciliation
;;;; -- come with the analyzer itself.

(in-package :loom-analyzer)

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
  ;; loom-analyzer.asd lives in src/analyzer/, so the tree root is two up.
  (asdf:system-relative-pathname :loom-analyzer "../../tools/py/extract.py")
  "The child script. Resolved against Loom's own source and not against the
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
