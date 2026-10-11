;;;; What Loom exposes, printed as plain tables.
;;;;
;;;;   sbcl --script tools/test/surface.lisp
;;;;
;;;; PLAN-0061 step 13, for tools/test/readme-figures.py. REQ-0079 R4 asks the
;;;; README to state the languages and formats analysed, the entity and
;;;; relationship types, and the REST and MCP surfaces, each read from the tree
;;;; and not typed. `status` and `structure` print counts and systems; none of
;;;; them prints these four lists, so this loads the systems and reads the
;;;; registries the running service reads:
;;;;
;;;;   analyzers       LOOM-ANALYZER:*ANALYZERS*, which each analyzer file fills
;;;;                   with a REGISTER-ANALYZER form as it loads
;;;;   entity types    LOOM-ONTOLOGY:ALL-ENTITY-TYPES
;;;;   relationships   LOOM-ONTOLOGY:ALL-RELATIONSHIP-TYPES
;;;;   operations      LOOM-SERVE:ALL-OPERATIONS, one DEFINE-OPERATION each, with
;;;;                   the tier that decides who may call it
;;;;   MCP tools       LOOM-MCP:*TOOLS*
;;;;
;;;; Every list is sorted, so two runs on one tree print the same bytes and a
;;;; diff of the output is a diff of the surface. A file type column lists the
;;;; extensions an analyzer's ANALYZER-FILE-TYPES names, and a dash where it names
;;;; none. The manifest and firebase analyzers claim files by name (package.json
;;;; and requirements*.txt; firebase.json and .firebaserc) through their own
;;;; ANALYZER-HANDLES-P methods, which that slot does not hold, so the column is
;;;; what the extension test accepts and not everything a file can be claimed
;;;; for.
;;;;
;;;; Written as functions with one top-level call: a top-level call to a function
;;;; defined here is a :CALL-SITE, and the Lisp sites are read against a pinned
;;;; ceiling (520, tools/test/call-site-census.lisp). The names are prefixed
;;;; `surface-' because a name another file calls without qualification turns
;;;; that call ambiguous (DES-0015) and mints a site in that file.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(loom-harness:load-systems "tools/test/surface.lisp"
                           :systems '("utils/" "embed/" "ontology/" "graph/" "analyzer/"
                                      "knowledge/" "docstore/" "workspace/" "serve/" "rest/" "mcp/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem"
                                        "cl-json" "drakma" "hunchentoot")
                           :load :loom-mcp)

(defpackage #:loom-surface
  (:use #:cl))
(in-package #:loom-surface)

(defun surface-word (keyword)
  "KEYWORD's name in lower case, without the colon; a dash for NIL, which the
document, manifest and firebase analyzers hold as their language."
  (if keyword (string-downcase (symbol-name keyword)) "-"))

(defun surface-print-list (title names)
  "TITLE, then NAMES one space apart, wrapped before column 78."
  (format t "~a (~d)~%" title (length names))
  (let ((column 0))
    (dolist (name names)
      (when (and (plusp column) (> (+ column 1 (length name)) 78))
        (terpri)
        (setf column 0))
      (format t "~:[ ~;  ~]~a" (zerop column) name)
      (incf column (+ (if (zerop column) 2 1) (length name))))
    (terpri)
    (terpri)))

(defun surface-print-table (title headings rows)
  "TITLE and a table of ROWS, each a list of strings, one column per heading.
Every column but the last is padded to its widest cell."
  (format t "~a (~d)~%" title (length rows))
  (let ((widths (loop for index from 0 below (length headings)
                      collect (reduce #'max (cons (length (nth index headings))
                                                  (mapcar (lambda (row) (length (nth index row)))
                                                          rows))))))
    (dolist (row (cons headings rows))
      (format t " ")
      (loop for (cell . more) on row
            for width in widths
            do (format t " ~a" (if more (format nil "~va" width cell) cell)))
      (terpri))
    (terpri)))

(defun surface-analyzer-rows ()
  "One row per registered analyzer: class, language, file types."
  (sort (mapcar (lambda (analyzer)
                  (list (string-downcase (symbol-name (class-name (class-of analyzer))))
                        (surface-word (loom-analyzer:analyzer-language analyzer))
                        (format nil "~:[-~;~:*~{~a~^ ~}~]"
                                (sort (copy-list (loom-analyzer:analyzer-file-types analyzer))
                                      #'string<))))
                loom-analyzer:*analyzers*)
        #'string< :key #'first))

(defun surface-operation-rows ()
  "One row per registered operation: name, tier."
  (sort (mapcar (lambda (operation)
                  (list (surface-word (loom-serve:operation-name operation))
                        (surface-word (loom-serve:operation-tier operation))))
                (loom-serve:all-operations))
        #'string< :key #'first))

(defun surface-print ()
  (surface-print-table "analyzers" '("class" "language" "file types") (surface-analyzer-rows))
  (surface-print-list "entity types"
                      (mapcar #'surface-word (loom-ontology:all-entity-types)))
  (surface-print-list "relationship types"
                      (mapcar #'surface-word (loom-ontology:all-relationship-types)))
  (surface-print-table "operations" '("name" "tier") (surface-operation-rows))
  (surface-print-list "mcp tools"
                      (sort (mapcar #'loom-mcp:tool-name (loom-mcp:all-tools)) #'string<)))

(surface-print)
