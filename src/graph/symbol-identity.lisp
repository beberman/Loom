;;;; The package graph, and the symbol identity it exists to answer (DES-0015).
;;;;
;;;; CALLABLE-INDEX keys candidates on a downcased name, so two definitions are
;;;; the same callable when they are spelled the same. In Common Lisp they are
;;;; the same when they name the same symbol. On game-server 55% of :CALLS
;;;; edges land on a name defined in more than one package, so the difference
;;;; is most of that tree's call graph.
;;;;
;;;; This is the assembling half of DES-0015's split. The analyzer records
;;;; each declaration as it reads it -- one file at a time, which is all
;;;; RULE-0002 allows -- and cannot canonicalise a nickname or follow an
;;;; import, because test/fixture.lisp is only (in-package :integration-test)
;;;; with the DEFPACKAGE in another file. Here every declaration is present at
;;;; once, so here is where the question can be answered.
;;;;
;;;; Nothing in this file asserts an operation. It computes; PLAN-0015 stage C
;;;; is what keys on the answer.

(in-package :loom-graph)

(defstruct (package-graph (:constructor %make-package-graph))
  "Every package declaration in a workspace, indexed for symbol lookup.

CANONICAL maps any designator -- a declared name or a nickname -- to the
declared name, so MPACKAGE.FILTER and MPACKAGE/FILTER are one key. The other
three are keyed by declared name only."
  (canonical (make-hash-table :test #'equal) :type hash-table)
  (exports   (make-hash-table :test #'equal) :type hash-table)
  (imports   (make-hash-table :test #'equal) :type hash-table)
  (uses      (make-hash-table :test #'equal) :type hash-table))

(defun canonical-package (pg designator)
  "DESIGNATOR's declared name, or NIL if no declaration in this workspace
names it. A nickname resolves; an undeclared package does not."
  (and designator (gethash (string-upcase (string designator))
                           (package-graph-canonical pg))))

(defun build-package-graph (view &key external-packages)
  "The namespace graph of every :PACKAGE entity in VIEW.

EXTERNAL-PACKAGES describes namespaces no declaration in the tree provides --
Common Lisp itself, or a library the tree uses but does not contain -- as an
alist of (name aliases exports). It is HANDED IN rather than reached for, for
the reason workspace.lisp gives about *MACRO-GENERATORS*: loom-graph depends on
loom-ontology alone, so it cannot see an analyzer's table, and it must not
reach into the host image either. `(find-package :common-lisp)' lived here
briefly and was the only place in this system that knew what language it was
indexing -- which is the thing DES-0012 puts in an analyzer and CON-0005 says
the writer must not do. The traversal below is namespace-generic; what
Common Lisp exports is a fact about Common Lisp, and it now arrives as data.

Without any external packages every name inherited from outside the tree is
unplaceable, which HOME-PACKAGE reports rather than guesses at. Supplying more
of them is how a workspace turns those recorded gaps into answers."
  (let ((pg (%make-package-graph)))
    (flet ((set-of (names)
             (let ((table (make-hash-table :test #'equal)))
               (dolist (n names table)
                 (setf (gethash (string-upcase (string n)) table) t)))))
      ;; The supplied namespaces first, so a tree that declares one of them
      ;; itself wins over what was handed in.
      (loop for (name aliases exports) in external-packages
            for canon = (string-upcase (string name))
            do (setf (gethash canon (package-graph-canonical pg)) canon)
               (dolist (alias aliases)
                 (setf (gethash (string-upcase (string alias))
                                (package-graph-canonical pg))
                       canon))
               (setf (gethash canon (package-graph-exports pg)) (set-of exports)))
      (dolist (p (entities-of-type view :package))
        (let ((declared (getp p :qualified-name)))
          (when declared
            (setf (gethash declared (package-graph-canonical pg)) declared)
            (dolist (nick (getp p :nicknames))
              (setf (gethash (string-upcase (string nick))
                             (package-graph-canonical pg))
                    declared))
            (setf (gethash declared (package-graph-exports pg))
                  (set-of (getp p :exports))
                  (gethash declared (package-graph-uses pg))
                  (getp p :uses))
            (let ((table (make-hash-table :test #'equal)))
              (loop for (symbol . from) in (getp p :imported-symbols)
                    do (setf (gethash (string-upcase (string symbol)) table)
                             (string-upcase (string from))))
              (setf (gethash declared (package-graph-imports pg)) table))))))
    pg))

(defun home-package (pg name package)
  "Which package's symbol NAME is, when read in PACKAGE. NIL when unknowable.

The three routes of DES-0015, in the order Common Lisp applies them:

  IMPORT       an :IMPORT-FROM naming NAME makes it the exporter's symbol, so
               the answer is that package's -- followed onward, since the
               exporter may itself have imported it.
  INHERITANCE  a :USE of a package that EXPORTS NAME makes it that package's
               symbol. Following exports rather than stopping is what makes a
               re-exported symbol resolve to where it is actually homed.
  INTERNING    otherwise NAME is interned in PACKAGE and is its own.

NIL is returned rather than a guess when PACKAGE is undeclared here, or when
it uses a package this workspace has no declaration for and could therefore be
inheriting NAME from outside. That second case is the conservative one and it
is the whole safety property: an unplaceable name falls back to name-only
matching, which is exactly today's behaviour, so nothing this cannot place can
regress. CON-0001 -- a recorded gap, never a fabricated binding."
  (let ((wanted (string-upcase (string name)))
        (visited (make-hash-table :test #'equal)))
    (labels ((walk (designator)
               (let ((canon (canonical-package pg designator)))
                 (cond
                   ;; A package we have no declaration for. If we got here by
                   ;; following an import it is still a distinct namespace and
                   ;; naming it is better than losing it; the caller entered
                   ;; through CANON below, which refuses an undeclared start.
                   ((null canon) (and designator (string-upcase (string designator))))
                   ((gethash canon visited) canon)   ; a :use cycle stops here
                   (t
                    (setf (gethash canon visited) t)
                    (let ((from (gethash wanted
                                         (or (gethash canon (package-graph-imports pg))
                                             (load-time-value (make-hash-table :test #'equal))))))
                      (cond
                        (from (walk from))
                        (t
                         (let ((exporter nil) (unknown nil))
                           (dolist (used (gethash canon (package-graph-uses pg)))
                             (let ((c (canonical-package pg used)))
                               (cond ((null c) (setf unknown t))
                                     ((gethash wanted (gethash c (package-graph-exports pg)
                                                                (make-hash-table :test #'equal)))
                                      (setf exporter c)))))
                           (cond (exporter (walk exporter))
                                 ;; Might be inherited from a package we cannot
                                 ;; see. Refuse to place it.
                                 (unknown nil)
                                 (t canon)))))))))))
      (and (canonical-package pg package) (walk package)))))

(defun entity-home-package (pg entity name)
  "The home package of NAME as ENTITY refers to it, or as ENTITY declares it.
ENTITY-PACKAGE reads :SYSTEM, which DES-0009 derives from the IN-PACKAGE
chain -- PLAN-0015 step 4 records why that is the package rather than a second
property holding the same string."
  (home-package pg name (entity-package entity)))
