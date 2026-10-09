;;;; requirements*.txt and package.json, read for the dependencies they declare.
;;;;
;;;; DES-0055 D2 and D3. A narrow analyzer in firebase-analyzer's shape: it claims
;;;; file names, not an extension, and asserts the manifest's own :FILE plus one
;;;; :MODULE per dependency name, so RETRACT-FILE on the manifest removes all of
;;;; it. A :MODULE here is a dependency the manifest declares. It is never a file
;;;; in the tree, and it carries no :SYSTEM, :DOMAIN or :LANGUAGE.
;;;;
;;;; Only names and version specs are stored. A requirements line or a package.json
;;;; value can embed a credential (`https://user:token@host/simple'), so a spec
;;;; that is a URL, a git reference, a path or an alias is reduced to its kind
;;;; (:URL, :GIT, :PATH, :ALIAS) and an option line such as --extra-index-url is
;;;; dropped whole (PLAN-0059 risk 1).

(in-package :loom-analyzer)

(defclass manifest-analyzer (analyzer)
  ()
  (:default-initargs :language nil :file-types '())
  (:documentation "Reads the dependencies of requirements*.txt and package.json
(DES-0055 D3). Claims by file name, so it declares no extension."))

(defmethod analyzer-handles-p ((analyzer manifest-analyzer) path)
  "REQUIREMENTS-FILE-P or the name package.json, outside a vendored or excluded
path. Acorn's package.json under tools/js/vendor/ and a venv's installed
packages declare nothing about this repository."
  (and (or (requirements-file-p path)
           (string= "package.json" (file-namestring (pathname path))))
       (not (vendored-path-p path))
       (not (python-excluded-path-p path))
       t))

;;;; ------------------------------------------------------------------
;;;; requirements*.txt
;;;; ------------------------------------------------------------------

(defun requirement-name-char-p (char)
  (or (alphanumericp char) (find char "-_.")))

(defun requirement-egg-name (line)
  "The name after `#egg=' in LINE, or NIL."
  (let ((start (search "#egg=" line)))
    (when start
      (let* ((from (+ start 5))
             (end (or (position-if-not #'requirement-name-char-p line :start from)
                      (length line))))
        (when (< from end) (subseq line from end))))))

(defun requirement-line-entry (line)
  "What one requirements line declares, as one of
  NIL                    nothing: blank, a comment, or an option dropped whole
  (:include \"-r X\")      another file this one pulls in
  (:unnamed)             a requirement naming no package
  (:module name spec)    a dependency; SPEC is a string, :URL, or NIL

A trailing ` #' comment is cut first. `-r' and `-c' are the only options kept,
because every other option line (--extra-index-url, --hash, -e) can carry a
credential and names no package."
  (let* ((cut (search " #" line))
         (text (string-trim '(#\Space #\Tab #\Return) (if cut (subseq line 0 cut) line))))
    (cond ((or (zerop (length text)) (char= #\# (char text 0))) nil)
          ((and (> (length text) 2) (char= #\- (char text 0))
                (find (char text 1) "rc") (member (char text 2) '(#\Space #\Tab)))
           (list :include (format nil "-~a ~a" (char text 1)
                                  (string-trim '(#\Space #\Tab) (subseq text 3)))))
          ((char= #\- (char text 0)) nil)
          ((or (search "://" text) (find (char text 0) "./"))
           (let ((egg (requirement-egg-name text)))
             (if egg (list :module egg :url) (list :unnamed))))
          (t (let ((end (or (position-if-not #'requirement-name-char-p text) (length text))))
               (if (zerop end)
                   (list :unnamed)
                   (let ((spec (string-trim '(#\Space #\Tab) (subseq text end))))
                     (list :module (subseq text 0 end)
                           (if (zerop (length spec)) nil spec)))))))))

;;;; ------------------------------------------------------------------
;;;; package.json
;;;; ------------------------------------------------------------------

(defparameter *package-json-sections*
  '(("dependencies" . :dependencies)
    ("devDependencies" . :dev-dependencies)
    ("peerDependencies" . :peer-dependencies)
    ("optionalDependencies" . :optional-dependencies))
  "The package.json keys that declare dependencies, with the section each becomes.
Their order is the order a repeated name lists its sections in.")

(defun dependency-repository-form-p (spec)
  "True for npm's `user/repo' shorthand, which names a git repository."
  (let ((slash (position #\/ spec))
        (text (subseq spec 0 (position #\# spec))))
    (and slash (= 1 (count #\/ text))
         (> slash 0) (< slash (1- (length text)))
         (every (lambda (c) (or (requirement-name-char-p c) (char= #\/ c))) text))))

(defun dependency-spec-kind (spec)
  "SPEC, a package.json version value, as written when it is a version range, and
as its kind -- :GIT, :URL, :PATH or :ALIAS -- when it can carry a location or a
credential. The kind is all that is kept of those four."
  (flet ((starts (prefix) (and (>= (length spec) (length prefix))
                               (string= prefix spec :end2 (length prefix)))))
    (cond ((or (starts "git+") (starts "git:") (starts "github:")
               (dependency-repository-form-p spec))
           :git)
          ((search "://" spec) :url)
          ((or (starts "file:") (starts "link:")) :path)
          ((starts "npm:") :alias)
          (t spec))))

(defun package-json-key-line (lines key)
  "The 1-based number of the first line of LINES holding the quoted KEY followed
by a colon, or NIL."
  (let ((quoted (format nil "\"~a\"" key)))
    (loop for line in lines
          for number from 1
          for at = (search quoted line)
          when (and at
                    (let ((after (position-if-not (lambda (c) (member c '(#\Space #\Tab)))
                                                  line :start (+ at (length quoted)))))
                      (and after (char= #\: (char line after)))))
            return number)))

(defun package-json-dependencies (parsed lines)
  "Dependency plists (:NAME :SPECS :SECTIONS :START-LINE) of PARSED, a package.json
table, one per name in the order first met. LINES locate the declaring line."
  (let ((found '()))
    (loop for (key . section) in *package-json-sections*
          for table = (gethash key parsed)
          when (hash-table-p table)
            do (maphash (lambda (name value)
                          (let ((spec (dependency-spec-kind (or (as-string value) "")))
                                (entry (find name found :key (lambda (e) (getf e :name))
                                                        :test #'string=)))
                            (if entry
                                (setf (getf entry :specs) (append (getf entry :specs) (list spec))
                                      (getf entry :sections) (append (getf entry :sections)
                                                                     (list section)))
                                (push (list :name name :specs (list spec) :sections (list section)
                                            :start-line (package-json-key-line lines name))
                                      found))))
                        table))
    (nreverse found)))

;;;; ------------------------------------------------------------------
;;;; Entities
;;;; ------------------------------------------------------------------

(defun dependency-merge (entries entry)
  "ENTRIES, a list of dependency plists, with ENTRY added: a name already present
keeps one plist and gains ENTRY's :SPECS (CON-0005 -- one :MODULE per name per
file)."
  (let ((old (find (getf entry :name) entries :key (lambda (e) (getf e :name))
                                              :test #'string=)))
    (if old
        (substitute (list* :specs (append (getf old :specs) (getf entry :specs))
                           (loop for (k v) on old by #'cddr
                                 unless (eq k :specs) append (list k v)))
                    old entries :test #'eq)
        (append entries (list entry)))))

(defun requirements-dependencies (lines)
  "The dependencies, :INCLUDES and unnamed count of requirements LINES, as
(values dependency-plists includes unnamed-count)."
  (let ((entries '()) (includes '()) (unnamed 0))
    (loop for line in lines
          for number from 1
          for entry = (requirement-line-entry line)
          do (case (first entry)
               (:include (push (second entry) includes))
               (:unnamed (incf unnamed))
               (:module (setf entries
                              (dependency-merge entries
                                                (list :name (second entry)
                                                      :specs (when (third entry)
                                                               (list (third entry)))
                                                      :start-line number))))))
    (values entries (nreverse includes) unnamed)))

(defun make-dependency-module (path ecosystem entry)
  "The :MODULE for ENTRY, a dependency plist, declared in manifest PATH."
  (make-instance
   'module-entity :name (getf entry :name) :origin-file path
   :properties
   (properties-table
    (append (list :qualified-name (getf entry :name) :file path :ecosystem ecosystem)
            (when (getf entry :specs) (list :specs (getf entry :specs)))
            (when (getf entry :sections) (list :sections (getf entry :sections)))
            (when (getf entry :start-line) (list :start-line (getf entry :start-line)))))))

(defun make-manifest-file-entity (path contents &rest properties)
  (make-instance 'file-entity :name path :origin-file path
                 :properties (properties-table
                              (append (list :path path :line-count (line-count contents))
                                      properties))))

(defun manifest-failed-file (path contents)
  (make-manifest-file-entity
   path contents :analysis-failed-p t
   :analysis-error (format nil "~a is not strict JSON" (file-namestring (pathname path)))))

(defun manifest-ops (path contents workspace-id file ecosystem entries)
  (append (list (retract-file path workspace-id)
                (assert-entity file workspace-id))
          (loop for entry in entries
                for module = (make-dependency-module path ecosystem entry)
                collect (assert-entity module workspace-id)
                collect (assert-edge :contains file module :workspace-id workspace-id))))

(defmethod analyze-file ((analyzer manifest-analyzer) path contents workspace-id)
  "A :FILE for the manifest and a :MODULE per declared dependency. Opens nothing:
CONTENTS is what it reads."
  (let ((lines (coerce (string-lines contents) (quote list))))
    (if (requirements-file-p path)
        (multiple-value-bind (entries includes unnamed) (requirements-dependencies lines)
          (manifest-ops path contents workspace-id
                        (apply #'make-manifest-file-entity path contents
                               (append (when includes (list :includes includes))
                                       (when (plusp unnamed) (list :unnamed-requirements unnamed))))
                        :pypi entries))
        (let ((parsed (parse-json-text contents)))
          (if parsed
              (manifest-ops path contents workspace-id
                            (make-manifest-file-entity path contents)
                            :npm (package-json-dependencies parsed lines))
              (list (retract-file path workspace-id)
                    (assert-entity (manifest-failed-file path contents) workspace-id)))))))

(register-analyzer (make-instance 'manifest-analyzer))
