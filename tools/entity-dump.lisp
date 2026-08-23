;;;; Dump one repository's definitions as JSON, for building retrieval cases.
;;;;
;;;;   sbcl --script tools/entity-dump.lisp /path/to/repo > cases/repo.json
;;;;
;;;; One object per definition entity: name, type, file, the first line of its
;;;; documentation where it has any, and the whole of it. tools/make-cases.py
;;;; turns these into known-item retrieval cases, whose ground truth is the
;;;; entity the query was built from.
;;;;
;;;; Two documentation fields and not one, because two instruments want
;;;; different halves. `doc' is the first line and is what make-cases.py builds
;;;; the prose family from -- the 450 cases in tools/cases/known-item.json came
;;;; from it, so what it holds cannot change without changing a frozen case
;;;; file the next time anyone rebuilds it. `documentation' is everything the
;;;; analyzer recorded, and tools/mismatch-check.lisp needs all of it: a query
;;;; disjoint from a docstring's first line can share a word with its third,
;;;; and DES-0039 D2 is the case where that happened.
;;;;
;;;; Exists because the service has no operation that enumerates entities --
;;;; `find' takes a term -- and the acceptance harness needed an order of
;;;; magnitude more cases than the 24 hand-written ones.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((here (merge-pathnames
             "../" (make-pathname :name nil :type nil :defaults *load-truename*))))
  (dolist (system '("ontology/" "graph/" "analyzer/" "knowledge/" "workspace/"))
    (pushnew (merge-pathnames (concatenate 'string "src/" system) here)
             asdf:*central-registry* :test #'equal)))

(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload")
           '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem" "cl-json")
           :silent t)
  (asdf:load-system :loom-workspace))

(defpackage #:loom-entity-dump
  (:use #:cl #:loom-ontology #:loom-graph #:loom-workspace))
(in-package #:loom-entity-dump)

(defparameter *definition-types*
  '(:function :method :class :interface :variable)
  "Definitions only. A :FILE's name is a path and a :TEST is not what a task asks
for; both would make a case whose answer nobody wants.")

(defun first-sentence (text)
  "TEXT's first line, trimmed. A docstring's first line is its summary by
convention in both languages here, and a later paragraph is usually about
mechanism rather than about what the thing is."
  (when (stringp text)
    (let* ((newline (position #\Newline text))
           (line (string-trim '(#\Space #\Tab #\Return)
                              (if newline (subseq text 0 newline) text))))
      (when (plusp (length line)) line))))

(defun dump (root)
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (view (repository-graph repository))
         (rows '()))
    (dolist (type *definition-types*)
      (dolist (entity (entities-of-type view type))
        (let ((name (and (slot-boundp entity 'name) (princ-to-string (name entity)))))
          (when (and name (plusp (length name)))
            (push (list (cons :name name)
                        (cons :type (string-downcase (symbol-name type)))
                        (cons :file (or (getp entity :file) ""))
                        (cons :doc (or (first-sentence (getp entity :documentation)) ""))
                        (cons :documentation (or (getp entity :documentation) "")))
                  rows)))))
    (json:encode-json (nreverse rows) *standard-output*)
    (terpri)))

(dump (or (second sb-ext:*posix-argv*)
          (error "Usage: sbcl --script tools/entity-dump.lisp <repository-root>")))
