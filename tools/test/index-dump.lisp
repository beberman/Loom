;;;; Dump one repository's whole index as sorted lines, for comparing two builds.
;;;;
;;;;   sbcl --script tools/test/index-dump.lisp /path/to/repo > repo.dump
;;;;
;;;; DES-0051 D8's acceptance instrument. Run it from the code before a change
;;;; and from the code after it, against the same checkout, and `diff' the two
;;;; files. An empty diff is the acceptance.
;;;;
;;;; The two rebuild-equivalence tests in src/workspace/test/workspace.lisp
;;;; cannot do this. Each compares two indexes built by one version of the
;;;; code, and each compares ids only. Five of the six document entity types
;;;; are keyed on :DOC-ID, so a document read from the wrong address keeps its
;;;; id and both tests pass.
;;;;
;;;; Four kinds of line, sorted after a header:
;;;;
;;;;   E <id> <type> <name> <origin-file> @<slot>=<value> ... <key>=<value> ...
;;;;   R <id> <type> <from> <to> @<slot>=<value> ... <key>=<value> ...
;;;;   S <key> <value>
;;;;
;;;; One E line per entity and one R line per relationship, with properties
;;;; sorted by key. The @ fields are the provenance slots every fact carries:
;;;; source, confidence, derived-from, stale-p. One S line per key of
;;;; REPOSITORY-STATUS. Every value prints under WITH-STANDARD-IO-SYNTAX with
;;;; *PRINT-READABLY* T, so a value that would print as an address signals
;;;; instead. A newline inside a printed value becomes the two characters \n,
;;;; and a return becomes \r, so each fact stays on one line. PRIN1 already
;;;; doubles a backslash in a string, so the escaping cannot collide with text.
;;;;
;;;; It indexes the tree directly, with no monitor and no service, so
;;;; RULE-0008's service check does not apply and no vector store is built.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(synoptik-harness:load-systems "tools/test/index-dump.lisp"
                           :systems '("utils/" "ontology/" "graph/" "analyzer/" "knowledge/"
                                      "docstore/" "workspace/" "embed/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :synoptik-workspace)

(defpackage #:synoptik-index-dump
  (:use #:cl #:synoptik-ontology #:synoptik-graph #:synoptik-workspace))
(in-package #:synoptik-index-dump)

(defparameter *placeholder-properties*
  '(:taken-at :decided-at)
  "Properties printed as <time> rather than their value.

Both default to GET-UNIVERSAL-TIME: :TAKEN-AT on :SNAPSHOT and :DECIDED-AT on
:DECISION, in src/ontology/code-ontology.lisp. Two builds a second apart give
them different values and nothing else.")

(defparameter *omitted-status-keys*
  '(:indexed-at :enrichment-at :vector-store :vectors)
  "REPOSITORY-STATUS keys left out of the S lines.

:INDEXED-AT and :ENRICHMENT-AT hold a universal time. :VECTOR-STORE and
:VECTORS describe the vector sidecar, which this script never builds and a
running service may have built beside the tree.")

(defun plain-strings (value)
  "VALUE with every string in it a simple character string.

Readable printing writes a base-string as #A((5) BASE-CHAR . \"hello\"). Whether
a string is a base-string depends on how it was built, not on what it says, so
two equal strings could print differently and fail the diff."
  (typecase value
    (string (coerce value '(simple-array character (*))))
    (cons (cons (plain-strings (car value)) (plain-strings (cdr value))))
    (t value)))

(defun printed (value)
  "VALUE printed readably, on one line."
  (let ((text (with-standard-io-syntax
                (let ((*print-readably* t))
                  (prin1-to-string (plain-strings value))))))
    (with-output-to-string (out)
      (loop for char across text
            do (case char
                 (#\Newline (write-string "\\n" out))
                 (#\Return (write-string "\\r" out))
                 (t (write-char char out)))))))

(defun property-fields (object)
  "OBJECT's properties as sorted key=value strings."
  (let ((pairs '()))
    (maphash (lambda (key value)
               (push (format nil "~a=~a" (printed key)
                             (if (member key *placeholder-properties*)
                                 "<time>"
                                 (printed value)))
                     pairs))
             (properties object))
    (sort pairs #'string<)))

(defun provenance-fields (object)
  "OBJECT's provenance slots as @slot=value strings, in a fixed order."
  (list (format nil "@source=~a" (printed (source object)))
        (format nil "@confidence=~a" (printed (confidence object)))
        (format nil "@derived-from=~a" (printed (derived-from object)))
        (format nil "@stale-p=~a" (printed (stale-p object)))))

(defun line (&rest fields)
  (format nil "~{~a~^ ~}" fields))

(defun entity-line (entity)
  (apply #'line "E"
         (printed (id entity))
         (printed (entity-type entity))
         (printed (if (slot-boundp entity 'synoptik-ontology::name) (name entity) '<unbound>))
         (printed (origin-file entity))
         (append (provenance-fields entity) (property-fields entity))))

(defun relationship-line (relationship)
  (apply #'line "R"
         (printed (id relationship))
         (printed (rel-type relationship))
         (printed (from-id relationship))
         (printed (to-id relationship))
         (append (provenance-fields relationship) (property-fields relationship))))

(defun status-lines (repository)
  (loop for (key value) on (repository-status repository) by #'cddr
        unless (member key *omitted-status-keys*)
          collect (line "S" (printed key) (printed value))))

(defun dump (root)
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (graph (repository-graph repository))
         (lines (append (mapcar #'entity-line (all-entities graph))
                        (mapcar #'relationship-line (all-relationships graph))
                        (status-lines repository))))
    (format t "# index-dump: properties printed as <time>: ~{~(~s~)~^ ~}; status keys omitted: ~{~(~s~)~^ ~}~%"
            *placeholder-properties* *omitted-status-keys*)
    (dolist (text (sort lines #'string<))
      (write-line text))
    (finish-output)))

(dump (or (second sb-ext:*posix-argv*)
          (error "Usage: sbcl --script tools/test/index-dump.lisp <repository-root>")))
