;;;; Package census for DES-0015.
;;;;
;;;; Every function here is prefixed PC-, and that is not a style choice. Loom
;;;; indexes its own tree, so a measuring script that defines REPORT or CLAUSE
;;;; puts those names into the callable index and changes the numbers it is
;;;; about to report -- which is exactly what happened to
;;;; tools/test/call-site-census.lisp, whose REPORT and TALLY moved the resolving
;;;; count by 2 and the covered-unit count by 1 before they were renamed.
;;;; Verified here: promoting this file from the scratchpad into tools/ raised
;;;; the callable-name count from 789 to 808 and left "defined more than once"
;;;; at 20, "spanning 2+ packages" at 11 and the at-risk edge count at 120,
;;;; all unchanged.
;;;;
;;;;   sbcl --script pkg-census.lisp /path/to/repo
;;;;
;;;; Two halves. The first text-reads every .lisp file for DEFPACKAGE /
;;;; DEFINE-PACKAGE / IN-PACKAGE forms, so we learn what package declarations
;;;; this tree actually uses. The second indexes the tree through Loom and asks
;;;; how many callable names are ambiguous only because CALLABLE-INDEX ignores
;;;; the package, which is the number that decides whether DES-0015 can land
;;;; in one step.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(loom-harness:load-systems "tools/test/package-census.lisp"
                           :systems '("utils/" "embed/" "ontology/" "graph/" "analyzer/" "knowledge/" "docstore/" "workspace/" "process/")
                           :libraries '("cl-yaml" "bordeaux-threads" "fiveam" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :loom-workspace)

(defpackage #:pkg-census
  (:use #:cl #:loom-ontology #:loom-graph #:loom-workspace))
(in-package #:pkg-census)

;;; ------------------------------------------------------------------
;;; Half one: what the source says about packages.

(defvar *scratch* (or (find-package :pkg-scratch)
                      (make-package :pkg-scratch :use nil)))

(defun pc-read-forms (path)
  "Every form in PATH we can get, and how far we got. Reading stops at the
first condition -- the position is lost once READ signals -- so FULLP says
whether the file was exhausted. Package forms sit at the top of a file, so a
truncated read still answers this census; the count of truncated files is
reported rather than hidden."
  (let ((*package* *scratch*)
        (*read-eval* nil)
        (forms '())
        (fullp nil))
    (handler-case
        (with-open-file (in path :external-format :utf-8)
          (loop (let ((form (read in nil :eof)))
                  (when (eq form :eof) (setf fullp t) (return))
                  (push form forms))))
      (error () nil))
    (values (nreverse forms) fullp)))

(defun pc-head-name (form)
  (and (consp form) (symbolp (car form)) (symbol-name (car form))))

(defun pc-designator-name (x)
  (typecase x
    (symbol (symbol-name x))
    (string (string-upcase x))
    (t nil)))

(defun pc-clause-heads (form)
  "The clause keywords a DEFPACKAGE-shaped FORM uses, as strings."
  (loop for clause in (cddr form)
        when (consp clause)
          collect (pc-designator-name (car clause))))

(defun pc-clause (form name)
  (find name (cddr form)
        :key (lambda (c) (and (consp c) (pc-designator-name (car c))))
        :test #'equal))

(defstruct pkg name nicknames uses imports exports shadows kind file)

(defvar *imported-by* (make-hash-table :test #'equal))

(defun pc-collect-packages (root)
  (let ((packages '()) (in-packages '()) (truncated 0) (files 0))
    (dolist (path (directory (merge-pathnames "**/*.lisp" root)))
      (unless (char= #\~ (char (file-namestring path)
                               (1- (length (file-namestring path)))))
        (incf files)
        (multiple-value-bind (forms fullp) (pc-read-forms path)
          (unless fullp (incf truncated))
          (dolist (form forms)
            (let ((head (pc-head-name form)))
              (cond
                ((and head (member head '("DEFPACKAGE" "DEFINE-PACKAGE")
                                   :test #'equal))
                 (push (make-pkg
                        :name (pc-designator-name (second form))
                        :nicknames (mapcar #'pc-designator-name
                                           (rest (pc-clause form "NICKNAMES")))
                        :uses (mapcar #'pc-designator-name
                                      (rest (pc-clause form "USE")))
                        ;; Every :import-from clause, not the first: a package
                        ;; may import from many, and each clause is
                        ;; (:import-from PKG SYM ...).
                        :imports (remove-if-not
                                  (lambda (c)
                                    (and (consp c)
                                         (equal "IMPORT-FROM" (pc-designator-name (car c)))))
                                  (cddr form))
                        :exports (rest (pc-clause form "EXPORT"))
                        :shadows (append (rest (pc-clause form "SHADOW"))
                                         (rest (pc-clause form "SHADOWING-IMPORT-FROM")))
                        :kind head
                        :file (enough-namestring path root))
                       packages))
                ((equal head "IN-PACKAGE")
                 (push (cons (pc-designator-name (second form))
                             (enough-namestring path root))
                       in-packages))))))))
    (values (nreverse packages) (nreverse in-packages) truncated files)))

;;; ------------------------------------------------------------------
;;; Half two: what the index does with the names.

(defun pc-callable-collisions (root canonical)
  "For every callable name in ROOT's index, how many distinct packages define
it. CANONICAL maps a declared designator or nickname to one canonical package
name, so a nickname does not read as a second package."
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (view (repository-graph repository))
         (by-name (make-hash-table :test #'equal))
         (id->name (make-hash-table :test #'equal))
         (calls 0) (cross-calls 0))
    (dolist (type '(:function :method :interface))
      (dolist (e (entities-of-type view type))
        (let* ((raw (and (entity-system e) (symbol-name (entity-system e))))
               (pkg (or (gethash raw canonical) raw))
               (key (string-downcase (name e))))
          (setf (gethash (id e) id->name) key)
          (push pkg (gethash key by-name)))))
    (let ((multi 0) (single 0) (spanning 0) (worst '())
          (spanning-names (make-hash-table :test #'equal)))
      (maphash (lambda (nm pkgs)
                 (let* ((distinct-defs (length pkgs))
                        (distinct-pkgs (length (remove-duplicates pkgs :test #'equal))))
                   (cond ((= 1 distinct-defs) (incf single))
                         (t (incf multi)
                            (when (> distinct-pkgs 1)
                              (incf spanning)
                              (setf (gethash nm spanning-names) t)
                              (push (list nm distinct-defs distinct-pkgs) worst))))))
               by-name)
      ;; :CALLS edges landing on a definition whose name is defined in more
      ;; than one package -- the edges package-aware keying could move.
      (dolist (r (all-relationships view))
        (when (eq :calls (rel-type r))
          (incf calls)
          (let ((target (gethash (to-id r) id->name)))
            (when (and target (gethash target spanning-names))
              (incf cross-calls)))))
      (values single multi spanning
              (subseq (sort worst #'> :key #'third)
                      0 (min 15 (length worst)))
              calls cross-calls (hash-table-count by-name)))))

;;; ------------------------------------------------------------------

(defun pc-report (root)
  (format t "~&~%Package census -- ~a~%~%" root)
  (multiple-value-bind (packages in-packages truncated files)
      (pc-collect-packages root)
    (let ((canonical (make-hash-table :test #'equal))
          (declared (make-hash-table :test #'equal)))
      (dolist (p packages)
        (setf (gethash (pkg-name p) declared) p)
        (setf (gethash (pkg-name p) canonical) (pkg-name p))
        (dolist (n (pkg-nicknames p))
          (setf (gethash n canonical) (pkg-name p))))
      (format t "  files scanned                       ~5d~%" files)
      (format t "  files whose read was truncated      ~5d~%" truncated)
      (format t "  package declarations                ~5d~%" (length packages))
      (format t "    defpackage                        ~5d~%"
              (count "DEFPACKAGE" packages :key #'pkg-kind :test #'equal))
      (format t "    define-package (uiop)             ~5d~%"
              (count "DEFINE-PACKAGE" packages :key #'pkg-kind :test #'equal))
      (format t "    declaring nicknames               ~5d~%"
              (count-if #'pkg-nicknames packages))
      (format t "    with :import-from                 ~5d~%"
              (count-if #'pkg-imports packages))
      (format t "    with :export                      ~5d~%"
              (count-if #'pkg-exports packages))
      (format t "    with :shadow/:shadowing-import    ~5d~%"
              (count-if #'pkg-shadows packages))
      (format t "  in-package forms                    ~5d~%" (length in-packages))
      (let ((nick 0) (unknown 0))
        (dolist (ip in-packages)
          (let ((name (car ip)))
            (cond ((gethash name declared))
                  ((gethash name canonical) (incf nick))
                  (t (incf unknown)))))
        (format t "    naming a nickname, not the declared name ~5d~%" nick)
        (format t "    naming a package declared nowhere here   ~5d~%" unknown))
      (let ((per-file (make-hash-table :test #'equal)))
        (dolist (ip in-packages) (incf (gethash (cdr ip) per-file 0)))
        (let ((multi 0))
          (maphash (lambda (k v) (declare (ignore k)) (when (> v 1) (incf multi)))
                   per-file)
          (format t "    files with more than one in-package      ~5d~%" multi)))
      (format t "~%")
      ;; How far does honouring :import-from collapse the apparent span? For a
      ;; name defined in packages P1..Pk, a Pi that imports that very name from
      ;; some Pj is not a separate symbol. This is the difference between "the
      ;; file's in-package" and "the symbol's home package", and it is the
      ;; whole reason the design cannot key on :SYSTEM as it stands.
      (let ((imported-by (make-hash-table :test #'equal)))
        (dolist (p packages)
          (dolist (clause (pkg-imports p))
            (let ((from (pc-designator-name (second clause))))
              (dolist (sym (cddr clause))
                (let ((s (pc-designator-name sym)))
                  (when s
                    (push (cons (pkg-name p) (or (gethash from canonical) from))
                          (gethash (string-downcase s) imported-by))))))))
        (format t "  symbol names imported by name somewhere    ~5d~%"
                (hash-table-count imported-by))
        (setf *imported-by* imported-by))
      (multiple-value-bind (single multi spanning worst calls cross total)
          (pc-callable-collisions root canonical)
        (format t "  callable names (function/method/interface) ~5d~%" total)
        (format t "    defined once                             ~5d~%" single)
        (format t "    defined more than once                   ~5d~%" multi)
        (format t "    ...whose definitions span 2+ packages    ~5d~%" spanning)
        (format t "    ...of those, named in some :import-from  ~5d~%"
                (let ((n 0))
                  (dolist (w worst n)
                    (when (gethash (first w) *imported-by*) (incf n)))))
        (format t "  :calls edges in the index                  ~5d~%" calls)
        (format t "  :calls edges onto a package-spanning name  ~5d~%" cross)
        (format t "~%  worst names by package span:~%")
        (dolist (w worst)
          (format t "    ~24a ~3d defs across ~2d packages~%"
                  (first w) (second w) (third w)))))))

;; The default is the tree this script was loaded from, so a clone measures
;; itself. REQ-0079 R1; the default was one developer's home directory.
(pc-report (or (second sb-ext:*posix-argv*)
        (namestring (truename (merge-pathnames
                               "../../"
                               (make-pathname :name nil :type nil
                                              :defaults *load-truename*))))))
