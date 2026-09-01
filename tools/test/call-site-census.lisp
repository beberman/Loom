;;;; What DES-0014's three :CALL-SITE generators would mint, counted against
;;;; the current index without writing anything.
;;;;
;;;;   sbcl --script tools/test/call-site-census.lisp [/path/to/repo]
;;;;
;;;; PLAN-0014 step 1. It lives under tools/ rather than /tmp because R2's
;;;; ceiling is a number that has to be re-measured after every generator step,
;;;; and a measurement nobody can repeat is an anecdote. Re-run it after each
;;;; step and compare: a population that moved is either the step or a defect,
;;;; and the only way to tell is to have the previous number.
;;;;
;;;; It replays the passes' own predicates rather than restating them.
;;;; EFFECTIVE-GENERATOR-REGISTRY and GENERATED-DEFINITION-PLAN decide which
;;;; definer call sites are orphaned, exactly as RESOLVE-GENERATED-DEFINITIONS
;;;; does, and CALLABLE-INDEX plus CLASSIFY-CALL below decide what a name
;;;; resolves to. A census that reimplemented either would measure something
;;;; the passes do not do, which is worse than not measuring.
;;;;
;;;; CLASSIFY-CALL is the one thing here that is not a call into loom-graph,
;;;; and it is deliberately CALL-TARGETS' clause order written out rather than
;;;; a call to CALL-TARGETS: the census has to separate populations that
;;;; CALL-TARGETS folds together (a fan-out and a single function are both
;;;; "resolves") and one CALL-TARGETS does not yet have at all (the ambiguous
;;;; clause is PLAN-0014 step 8). :AMBIGUOUS is therefore counted here before
;;;; the code that acts on it exists, which is the point of taking the baseline
;;;; first. When step 8 lands, this function and CALL-TARGETS' cond must agree;
;;;; they are five lines apart in meaning and the comment is the only link.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

;; "embed/" since PLAN-0043: loom-knowledge depends on loom-embed, so a
;; registry without it cannot load the system this census measures. drakma and
;; cl-json are loom-embed's, reached through loom-knowledge.
(loom-harness:load-systems "tools/test/call-site-census.lisp"
                           :systems '("utils/" "ontology/" "graph/" "analyzer/"
                                      "knowledge/" "workspace/" "embed/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid"
                                        "eclector" "stem" "cl-json" "drakma")
                           :load :loom-workspace)

(defpackage #:loom-census
  (:use #:cl #:loom-ontology #:loom-graph #:loom-analyzer #:loom-workspace))

(in-package #:loom-census)

;;;; ------------------------------------------------------------------
;;;; What a name resolves to
;;;; ------------------------------------------------------------------

(defun classify-call (index name &optional referrer)
  "CALL-TARGETS' clause order, as a keyword rather than a list of edges.

:FUNCTION, :DISPATCH and :INTERFACE are its three resolving clauses in order.
:AMBIGUOUS is the clause PLAN-0014 step 8 adds before (t nil) -- two or more
plain functions, no methods, not exactly one interface -- and :NONE is (t nil)
as it stands today. Everything but :NONE is a name that reaches something.

REFERRER is the entity the name was read from, and it is what makes the
candidate set the one CALL-TARGETS actually sees after DES-0015: a name is
looked up as the symbol it is in the referrer's package, not as the string it
is spelled. Passing NIL is the pre-DES-0015 answer and is what the initform
and orphan censuses use where no entity is at hand."
  (let* ((candidates (candidate-entities index name referrer))
         (functions  (remove-if-not (lambda (e) (eq :function  (entity-type e))) candidates))
         (methods    (remove-if-not (lambda (e) (eq :method    (entity-type e))) candidates))
         (interfaces (remove-if-not (lambda (e) (eq :interface (entity-type e))) candidates)))
    (cond ((and (= 1 (length functions)) (null methods) (null interfaces)) :function)
          (methods :dispatch)
          ((= 1 (length interfaces)) :interface)
          ((>= (length functions) 2) :ambiguous)
          (t :none))))

(defun resolvingp (kind) (not (eq kind :none)))

(defun definer-site-referrer (file site)
  "A stand-in entity carrying the package a definer call site was written in.

A definer call site is a plist on the :FILE entity rather than an entity of its
own, so there is nothing to hand CLASSIFY-CALL as a referrer. PLAN-0015 step 5
put the package in effect on the site for exactly this reason; this wraps it in
something ENTITY-PACKAGE can read."
  (make-instance 'loom-ontology::function-entity
                 :name (or (getf site :operator) "definer-call-site")
                 :properties (properties-table
                              (list :file (getp file :path)
                                    :start-line (getf site :start-line)
                                    :system (getf site :system)))))

;;;; ------------------------------------------------------------------
;;;; R3 -- initforms (BUG-0017)
;;;; ------------------------------------------------------------------
;;;;
;;;; This population had no predicate to replay when the census was written:
;;;; PLAN-0014 step 6 is what introduces LOOM-ANALYZER::INITFORM-CALL-SITES,
;;;; and the census had to be runnable before it, so the walk stood written out
;;;; here. Step 6 has landed and it is a call to that function, because two
;;;; copies of a walk is exactly the drift this file exists to detect.

(defun initform-census (root index)
  "Every (file, line, name) an initform contributes, as a list of plists."
  (let ((sites '()))
    (dolist (path (directory (merge-pathnames "**/*.lisp" root)))
      (let ((contents (with-open-file (in path :external-format :utf-8)
                        (let ((text (make-string (file-length in))))
                          (subseq text 0 (read-sequence text in))))))
        (let ((reading (ignore-errors (loom-analyzer::read-source contents))))
          (when (and reading (null (loom-analyzer::reading-fatal reading)))
            (dolist (spec (loom-analyzer::reading-forms reading))
              (destructuring-bind (form start end start-offset) spec
                (declare (ignore end start-offset))
                (let ((head (and (consp form) (symbolp (car form)) (car form)
                                 (loom-analyzer::token-name (car form)))))
                  (when head
                    (dolist (name (loom-analyzer::initform-call-sites
                                   form head reading))
                      (push (list :file (enough-namestring path root)
                                  :line start
                                  :name name
                                  ;; No referring entity: pass 1 has a form,
                                  ;; not an entity, so this is the name-only
                                  ;; answer and a floor on what resolves.
                                  :kind (classify-call index name))
                            sites))))))))))
    (nreverse sites)))

;;;; ------------------------------------------------------------------
;;;; R4 -- orphaned definer call sites (BUG-0016)
;;;; ------------------------------------------------------------------

(defun orphaned-definer-census (view registry index)
  "Every (file, line, name) a definer call site that minted no entity orphans.

The produced set is keyed on the site plist by identity, which is how
RESOLVE-GENERATED-DEFINITIONS itself will key it: GENERATED-DEFINITION-PLAN
already carries the site in its :SITE key, so no second predicate is written
and the two populations cannot disagree about which sites minted."
  (let ((produced (make-hash-table :test #'eq))
        (sites '()))
    (dolist (plan (loom-graph::generated-definition-plan
                   view (loom-graph::effective-generator-registry view registry)))
      (setf (gethash (getf plan :site) produced) t))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        (unless (gethash site produced)
          (dolist (name (getf site :call-names))
            (push (list :file (getp file :path)
                        :line (getf site :start-line)
                        :name name
                        :operator (getf site :operator)
                        :kind (classify-call index name (definer-site-referrer file site)))
                  sites)))))
    (nreverse sites)))

;;;; ------------------------------------------------------------------
;;;; R5 -- ambiguous calls from ordinary callers (REQ-0015)
;;;; ------------------------------------------------------------------

(defun ambiguous-call-census (view index)
  "Every (file, caller-line, name) an existing caller drops as ambiguous.

The key collapses per caller line rather than per name, which is why the site
count and the occurrence count are reported separately: they are equal on this
tree and will not be on one where a caller names two ambiguous functions."
  (let ((sites '()))
    (dolist (type '(:function :method :test))
      (dolist (caller (entities-of-type view type))
        (dolist (name (getp caller :call-names))
          (when (eq :ambiguous (classify-call index name caller))
            (push (list :file (getp caller :file)
                        :line (getp caller :start-line)
                        :name name
                        :caller (name caller))
                  sites)))))
    (nreverse sites)))

;;;; ------------------------------------------------------------------
;;;; Reporting
;;;; ------------------------------------------------------------------

(defun distinct-keys (sites)
  (let ((keys (make-hash-table :test #'equal)))
    (dolist (site sites)
      (setf (gethash (list (getf site :file) (getf site :line) (getf site :name)) keys) t))
    (hash-table-count keys)))

(defun count-kind (sites kind)
  (count kind sites :key (lambda (s) (getf s :kind))))

(defun census-tally (sites key)
  "KEY -> occurrences, as an alist sorted by descending count."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (site sites) (incf (gethash (funcall key site) counts 0)))
    (sort (loop for k being the hash-keys of counts using (hash-value v)
                collect (cons k v))
          #'> :key #'cdr)))

;;; CENSUS-REPORT, not REPORT. Measured: a function named REPORT in this file
;;; puts REPORT into the callable index, and two `report' names orphaned by
;;; DEFINE-COMMAND bodies in console.lisp then resolve to it -- so the
;;; instrument moved the population it exists to measure, by 2. Every name
;;; defined here is prefixed or compound for that reason, and a future addition
;;; must be too.
(defun census-report (root)
  (let* ((repository (watch-repository root :monitor nil :quiet t))
         (view (repository-graph repository))
         ;; The package-aware lookup, not the bare name index. DES-0015 made
         ;; CALL-TARGETS ask which symbol a name is before asking what it
         ;; matches, and a census that skipped that step would report the
         ;; populations of a pass that no longer exists -- the drift this
         ;; file's own header warned about when step 8 was still ahead of it.
         (index (callable-lookup
                 view :external-packages (loom-analyzer:external-package-exports)))
         (initforms (initform-census (repository-root repository) index))
         (orphans (orphaned-definer-census view loom-analyzer:*macro-generators* index))
         (ambiguous (ambiguous-call-census view index))
         (resolving (remove-if-not (lambda (s) (resolvingp (getf s :kind))) orphans)))
    (format t "~&~%Call-site census -- ~a~%" (repository-name repository))
    (format t "  entities ~d, relationships ~d~%~%"
            (length (all-entities view))
            (length (all-relationships view)))

    (format t "  R3  initform (form, name) pairs                  ~5d~%" (length initforms))
    (format t "        of which resolve to a callee               ~5d~%"
            (count-if (lambda (s) (resolvingp (getf s :kind))) initforms))
    (format t "        of which resolve to nothing                ~5d~%"
            (count-kind initforms :none))
    (format t "        distinct (file, line, name)                ~5d~%~%"
            (distinct-keys initforms))

    (format t "  R4  orphaned definer (site, name) pairs          ~5d~%" (length orphans))
    (format t "        of which resolve to a callee               ~5d~%" (length resolving))
    (format t "          one plain function                       ~5d~%"
            (count-kind orphans :function))
    (format t "          dispatched across methods                ~5d~%"
            (count-kind orphans :dispatch))
    (format t "          one interface                            ~5d~%"
            (count-kind orphans :interface))
    (format t "          two or more plain functions              ~5d~%"
            (count-kind orphans :ambiguous))
    (format t "        of which resolve to nothing                ~5d~%"
            (count-kind orphans :none))
    (format t "        distinct (file, line, name)                ~5d~%"
            (distinct-keys orphans))
    (format t "        by macro, resolving only:~%")
    (loop for (operator . n) in (census-tally resolving (lambda (s) (getf s :operator)))
          do (format t "          ~16a ~5d~%" operator n))
    (terpri)

    (format t "  R5  ambiguous occurrences                        ~5d~%" (length ambiguous))
    (format t "        distinct (file, caller-line, name)         ~5d~%"
            (distinct-keys ambiguous))
    (format t "        names:~%")
    (loop for (name . n) in (census-tally ambiguous (lambda (s) (getf s :name)))
          do (format t "          ~24a ~5d~%" name n))
    (terpri)

    (format t "  minted by DES-0014 as PLAN-0014 implements it:~%")
    (format t "        R3 all pairs + R4 resolving + R5 sites     ~5d~%~%"
            (+ (length initforms) (length resolving) (distinct-keys ambiguous)))))

(census-report (or (second sb-ext:*posix-argv*) "/home/beberman/lisp/Loom/"))
