;;;; firebase.json and .firebaserc, read for the two facts a graph pass needs.
;;;;
;;;; DES-0054 D4. A narrow analyzer, not a JSON analyzer: it claims exactly two
;;;; file names and writes properties on their own :FILE entities, so RETRACT-FILE
;;;; takes them away with the file. Synoptik's own tree tracks 10 .json files and none
;;;; carries a meaning Synoptik could state, so a general claim would turn
;;;; configuration into entities with nothing attached.
;;;;
;;;; From firebase.json, :CODEBASES: which directory deploys, under what name and
;;;; runtime, minus what the CLI's ignore list drops. From .firebaserc,
;;;; :PROJECT-ALIASES. Nothing else in either file is read -- hosting, firestore,
;;;; emulators and targets are out of scope (DES-0054 D4), and above all no
;;;; value: a project id is a name, and the files that hold a secret's value all
;;;; begin with a dot this analyzer is never handed (D7).

(in-package :synoptik-analyzer)

(defclass firebase-analyzer (analyzer)
  ()
  (:default-initargs :language nil :file-types '())
  (:documentation "Reads firebase.json's codebases and .firebaserc's project
aliases (DES-0054 D4). Claims by file name, so it declares no extension."))

(defparameter *firebase-file-names* '("firebase.json" ".firebaserc")
  "The two names this analyzer claims, in any directory it is not refused. A
tree with two firebase.json files, a monorepo's, has two projects, and each
:FILE carries its own.")

(defmethod analyzer-handles-p ((analyzer firebase-analyzer) path)
  "Exactly the two names, outside a vendored path. A vendored copy would add a
codebase that deploys nothing (DES-0054 RISKS), and the JavaScript analyzer's
VENDORED-PATH-P is the one list of what that means."
  (and (member (file-namestring (pathname path)) *firebase-file-names* :test #'string=)
       (not (vendored-path-p path))
       t))

(defun firebase-codebase (table)
  "One `functions' entry of firebase.json as a codebase plist.

An absent source is \"functions\" and an absent codebase is \"default\", as the
Firebase CLI applies them, and :DEFAULTED lists which of the two it was so a
reader can tell a written value from a supplied one. An absent runtime stays
absent: front-end's runtime lives in functions/package.json's `engines', which
this analyzer is not handed, and guessing one would be a fabricated fact
(CON-0001)."
  (let ((source (as-string (yaml-value table :source)))
        (codebase (as-string (yaml-value table :codebase)))
        (runtime (as-string (yaml-value table :runtime))))
    (append (list :source (or source "functions")
                  :codebase (or codebase "default"))
            (when runtime (list :runtime runtime))
            (list :ignore (as-list-of-strings (yaml-value table :ignore))
                  :defaulted (append (unless source (list :source))
                                     (unless codebase (list :codebase)))))))

(defun firebase-codebases (parsed)
  "PARSED firebase.json's `functions' as a list of codebase plists. An array is
the current form and a single object is the legacy one-codebase form. Anything
else, an entry that is not an object included, declares no codebase."
  (loop for entry in (as-sequence (yaml-value parsed :functions))
        when (hash-table-p entry)
          collect (firebase-codebase entry)))

(defun firebase-source-directory (source)
  "SOURCE, a codebase's `source', as a directory prefix with a trailing slash, or
\"\" for the project root. A leading `./' and a trailing slash are dropped."
  (format nil "~{~a/~}"
          (remove-if (lambda (segment) (member segment '("" ".") :test #'string=))
                     (loop for start = 0 then (1+ end)
                           for end = (position #\/ source :start start)
                           collect (subseq source start end)
                           while end))))

(defun firebase-codebase-language (codebase root)
  "The language of CODEBASE, a codebase plist, as :PYTHON, :NODEJS or NIL.

By `runtime' when it is written: python312 is Python and nodejs20 is Node. When
it is absent, as front-end's is, by what the source directory under ROOT holds:
main.py or package.json. Neither is NIL, which says nothing about a language Synoptik
could not name rather than guessing one (CON-0001). DES-0054 R10."
  (let ((runtime (getf codebase :runtime))
        (source (firebase-source-directory (getf codebase :source))))
    (flet ((holds (name)
             (probe-file (merge-pathnames (concatenate 'string source name) (pathname root))))
           (runtime-is (prefix)
             (and runtime (>= (length runtime) (length prefix))
                  (string-equal prefix runtime :end2 (length prefix)))))
      (cond ((runtime-is "python") :python)
            ((runtime-is "nodejs") :nodejs)
            (runtime nil)
            ((holds "main.py") :python)
            ((holds "package.json") :nodejs)))))

(defun firebase-codebase-languages (root)
  "ROOT's own firebase.json codebases, each with its :LANGUAGE, as plists with
:SOURCE, :CODEBASE, :RUNTIME and :LANGUAGE. NIL when there is no firebase.json or
it does not parse. Read from disk, for `init', which is asked before anything is
indexed. DES-0054 R10."
  (let ((parsed (read-json-file (merge-pathnames "firebase.json" (pathname root)))))
    (when parsed
      (loop for codebase in (firebase-codebases parsed)
            collect (list* :language (firebase-codebase-language codebase root)
                           codebase)))))

(defun firebase-project-aliases (parsed)
  "PARSED .firebaserc's `projects' as (alias . project-id) pairs, in file order.
`targets' is not read."
  (let ((projects (yaml-value parsed :projects)) (pairs '()))
    (when (hash-table-p projects)
      (maphash (lambda (alias id)
                 (let ((alias (as-string alias)) (id (as-string id)))
                   (when (and alias id) (push (cons alias id) pairs))))
               projects))
    (nreverse pairs)))

(defun make-firebase-file-entity (path contents)
  "The :FILE for PATH. A file that does not parse as strict JSON is still a
:FILE, carrying :ANALYSIS-ERROR and :ANALYSIS-FAILED-P so `status' lists it under
`unparsed' -- a known unknown rather than an absence a reader cannot tell from
an empty file. firebase-tools reads a comment where cl-yaml does not, so a
JSONC firebase.json lands here and says why."
  (let ((parsed (parse-json-text contents)))
    (make-instance
     'file-entity :name path :origin-file path
     :properties
     (properties-table
      (append (list :path path :line-count (line-count contents))
              (cond ((null parsed)
                     (list :analysis-failed-p t
                           :analysis-error
                           (format nil "~a is not strict JSON" (file-namestring (pathname path)))))
                    ((string= ".firebaserc" (file-namestring (pathname path)))
                     (list :project-aliases (firebase-project-aliases parsed)))
                    (t (list :codebases (firebase-codebases parsed)))))))))

(defmethod analyze-file ((analyzer firebase-analyzer) path contents workspace-id)
  "A :FILE carrying :CODEBASES or :PROJECT-ALIASES. Opens nothing: CONTENTS is
what it reads, so an unsaved buffer analyzes as well as a file on disk."
  (list (retract-file path workspace-id)
        (assert-entity (make-firebase-file-entity path contents) workspace-id)))

(register-analyzer (make-instance 'firebase-analyzer))
