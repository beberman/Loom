;;;; What a repository knows about its own frameworks, that Loom cannot.
;;;;
;;;; DES-0025 D4. Loom ships knowing fiveam, because Loom's own tree uses
;;;; fiveam -- that is a fact about Loom, not a policy about frameworks. Every
;;;; other tree declares its own in .loom/frameworks.yaml:
;;;;
;;;;   definer-macros:
;;;;     - macro: defroute
;;;;       package: easy-routes
;;;;       defines: function
;;;;       name-index: 1
;;;;       body-index: 3
;;;;       route-index: 2
;;;;   route-callers:
;;;;     - callee: [get, post, sendGet, sendPost]
;;;;       argument-index: 0
;;;;
;;;; Without this, game-server's 27 (easy-routes:defroute NAME ("/public/..."))
;;;; forms produce nothing at all: PUBLIC-API-CREATE-GAME is not an entity, and
;;;; DEFROUTE is not even reported by UNHANDLED-DEFINER-MACROS, because that
;;;; report covers macros the tree itself defines and DEFROUTE comes from a
;;;; library. A definer nobody declared is invisible rather than counted, which
;;;; is the one shape of gap this project rules out (CON-0001) -- so declaring
;;;; it has to be possible from outside Loom's source.
;;;;
;;;; A SEPARATE FILE FROM .loom/manifest.yaml, and structurally so rather than
;;;; for tidiness. READ-MANIFEST is a line scanner: loom-workspace does not
;;;; depend on a YAML parser and DES-0018 kept it that way deliberately. A
;;;; nested declaration cannot be line-scanned honestly, and pretending
;;;; otherwise would put a half-parser in the layer that has no parser on
;;;; purpose. This file lives in loom-analyzer, which has cl-yaml already, and
;;;; loom-workspace hands the result to the passes exactly the way it already
;;;; hands in *MACRO-GENERATORS*.

(in-package :loom-analyzer)

(defparameter *frameworks-file* ".loom/frameworks.yaml"
  "Where a repository declares what its own frameworks mean, relative to its
root. Dot-prefixed, so REPOSITORY-FILES skips it for the same reason it skips
the manifest: this is Loom's own configuration, not the repository's content,
and indexing it as engineering knowledge would be a category error.")

(defun frameworks-path (root)
  (merge-pathnames *frameworks-file* (pathname root)))

(defun as-index (value)
  "A non-negative integer from a YAML scalar, or NIL.

NIL for anything else, including a negative or a non-number. An index is a
position in a form and a wrong one mints an entity named after the wrong
subform -- CON-0001's fabricated fact -- so a malformed one declines to
declare rather than defaulting to something plausible."
  (let ((n (typecase value
             (integer value)
             (string (parse-integer value :junk-allowed t))
             (t nil))))
    (and n (>= n 0) n)))

(defun parse-definer-macro (table)
  "One definer-macros: entry as a generator registry plist, or NIL.

The shape REGISTER-MACRO-GENERATOR produces, plus :ROUTE-INDEX, so nothing
downstream can tell a declared entry from a shipped one -- REQ-0003's one
table and one pass over it, which EFFECTIVE-GENERATOR-REGISTRY already relies
on for in-tree macros.

:MACRO and :DEFINES are required. An entry without a name has nothing to match
a call site against, and one without an entity type would mint an entity of no
type; both are dropped, and FRAMEWORKS-PROBLEMS reports them rather than
letting the file look like it worked."
  (let ((macro (as-string (yaml-value table :macro)))
        (defines (as-keyword (yaml-value table :defines))))
    (when (and macro defines)
      (list :name (string-downcase macro)
            :package (let ((p (as-string (yaml-value table :package))))
                       (and p (string-downcase p)))
            :entity-type defines
            :name-index (or (as-index (yaml-value table :|name-index|)) 1)
            :body-index (as-index (yaml-value table :|body-index|))
            ;; DES-0025 D1. The position of a literal to record as :ROUTE on
            ;; the minted entity -- the claim one side of an HTTP join
            ;; publishes. Absent for a definer that defines no endpoint, which
            ;; is most of them.
            :route-index (as-index (yaml-value table :|route-index|))
            :framework (as-keyword (yaml-value table :framework))
            :declared t))))

(defun parse-route-caller (table)
  "One route-callers: entry, or NIL.

The client half of DES-0025 D1: which callees carry a route as a literal
argument, and at which position. `callee:' takes a scalar or a sequence,
because a tree that routes through four wrapper names should write them once."
  (let ((callees (as-list-of-strings (yaml-value table :callee)))
        (index (or (as-index (yaml-value table :|argument-index|)) 0)))
    (when callees
      (list :callees (mapcar #'string-downcase callees)
            :argument-index index))))

(defun as-sequence (value)
  "A YAML sequence as a list, whatever cl-yaml made of it."
  (typecase value
    (null '())
    (cons value)
    (vector (coerce value 'list))
    (t (list value))))

(defun parse-frameworks (contents)
  "A .loom/frameworks.yaml as (:definer-macros ... :route-callers ...).

Returns NIL for a file that does not parse. A repository whose declaration is
malformed gets no declarations rather than some of them: a partially applied
framework file would index half a tree's handlers and leave the reader to work
out which half."
  ;; RULE-0004, and this file broke it on the first attempt. cl-yaml defines
  ;; its conditions as direct subtypes of CONDITION rather than of ERROR, so a
  ;; handler naming ERROR alone lets a malformed document sail straight
  ;; through -- taking the watcher thread with it, which is the whole reason
  ;; the rule exists. PARSE-DOCUMENT names both for the same reason.
  (let ((parsed (handler-case (yaml:parse contents)
                  ((or error yaml.error:yaml-error) () nil))))
    (when (hash-table-p parsed)
      (list :definer-macros
            (remove nil (mapcar #'parse-definer-macro
                                (as-sequence (yaml-value parsed :|definer-macros|))))
            :route-callers
            (remove nil (mapcar #'parse-route-caller
                                (as-sequence (yaml-value parsed :|route-callers|))))))))

(defun read-frameworks (root)
  "ROOT's framework declarations, or NIL when it has none.

Absent is the normal case and is not an error: every repository Loom has ever
indexed until now has had none, and a tree with no unusual definers needs no
file."
  (let ((path (frameworks-path root)))
    (when (probe-file path)
      (let ((contents (handler-case
                          (with-open-file (in path :external-format :utf-8)
                            (let ((text (make-string (file-length in))))
                              (subseq text 0 (read-sequence text in))))
                        (error () nil))))
        (when contents (parse-frameworks contents))))))

(defun frameworks-registry (frameworks &optional (base *macro-generators*))
  "BASE plus FRAMEWORKS' definer macros, as a fresh table.

Fresh, and that is the whole point of taking BASE as an argument rather than
pushing into it: two repositories watched by one service must not teach each
other their frameworks. game-server declaring DEFROUTE cannot make Loom's own
tree start looking for one, and a REGISTER-MACRO-GENERATOR call would have
exactly that effect -- it mutates a global, which is right for a fact about a
language and wrong for a fact about one repository."
  (let ((index (make-hash-table :test #'equal)))
    (when base
      (maphash (lambda (name entries) (setf (gethash name index) (copy-list entries)))
               base))
    (dolist (entry (getf frameworks :definer-macros))
      (push entry (gethash (getf entry :name) index)))
    index))

(defun frameworks-problems (root)
  "Why ROOT's frameworks file declared less than it looks like it does.

A list of human-readable strings, empty when the file is absent or wholly
usable. This exists because the failure mode of a declaration file is silence:
a mistyped `defines:' yields a tree that indexes exactly as it did before, and
nothing about that looks like an error. `status' reports these."
  (let ((path (frameworks-path root)))
    (when (probe-file path)
      (let ((frameworks (read-frameworks root)))
        (cond ((null frameworks)
               (list (format nil "~a does not parse as YAML" *frameworks-file*)))
              ((and (null (getf frameworks :definer-macros))
                    (null (getf frameworks :route-callers)))
               (list (format nil "~a declares nothing usable: a definer-macros entry needs both macro: and defines:"
                             *frameworks-file*)))
              (t '()))))))
