;;;; The Common Lisp inspector: what SBCL knows about a tree it has loaded.
;;;; Implements ARCH-0011 R3 and R4 behind the protocol in inspector.lisp.
;;;;
;;;; This is the only file in the tree that knows what SBCL is. That is the
;;;; whole of ARCH-0011's second-language answer: a TypeScript inspector is a
;;;; node script emitting the same facts schema over its own wire, and nothing
;;;; outside its own file learns what a tsconfig is either. Concretely, the
;;;; word FAST-METHOD -- SBCL's spelling of a method in a WHO-CALLS key --
;;;; appears here and nowhere else, because REQ-0018 R8 makes parsing it an
;;;; inspector's obligation rather than the graph's.
;;;;
;;;; Loading is running. Every top-level form and initform in the target
;;;; executes, so it happens in a child process bounded by `timeout' and
;;;; --dynamic-space-size, and Loom's own image still never evaluates a form of
;;;; target code (REQ-0018 R3). The process boundary is what enforces that; the
;;;; system boundary could not, and ARCH-0008 is the precedent -- every path
;;;; that runs code outside the current image's control is a fresh process
;;;; driven from outside.
;;;;
;;;; The child and the parent are coupled by a string with no edge between
;;;; them: Loom cannot see a subprocess, so nothing in its own index will ever
;;;; record that *DRIVER-SOURCE* below is a program. That is why the generated
;;;; script's shape is asserted by a test rather than trusted.

(in-package :loom-analyzer)

;;;; ==================================================================
;;;; The inspector
;;;; ==================================================================

(defclass lisp-inspector (inspector)
  ((timeout-seconds :initarg :timeout-seconds :accessor inspector-timeout-seconds
                    :initform 300
                    :documentation "Wall-clock seconds a child may take before
`timeout' kills it. Generous, because a cold tree compiles from scratch; a test
binds it to seconds.")
   (heap-mb :initarg :heap-mb :accessor inspector-heap-mb
            :initform 4096
            :documentation "--dynamic-space-size for the child, in megabytes.")
   (isolate-p :initarg :isolate-p :accessor inspector-isolate-p
              :initform t
              :documentation "Whether to wrap the child in `unshare --user
--net' when the probe finds that it works. T means \"when available\", not
\"always\": a machine where unshare misbehaves must not lose the pass.")
   (include-test-units :initarg :include-test-units
                       :accessor inspector-include-test-units
                       :initform nil
                       :documentation "Whether a tree's test systems are units.


NIL by default, which ARCH-0011 left to the implementing plan and PLAN-0010 R-7
settled. It changes the acceptance numbers and so has to be stated with them:
with primary systems only, SB-INTROSPECT:WHO-CALLS APPLY-TRANSACTION returns 3
callers; with the test systems loaded it returns 8, the extra five being DEFUNs
in test files.")
   (spawns :initform 0 :accessor inspector-spawns
           :documentation "Children spawned by the most recent
INSPECT-REPOSITORY, reset at its entry.

Not bookkeeping. It is the only way to tell a bound that fired inside the child
from one that killed it: a heap exhaustion the child's SERIOUS-CONDITION guard
caught costs one unit and no re-spawn, while the same failure under a guard
naming ERROR kills the child and costs a second spawn. Both leave identical
unit statuses, so without this the two are indistinguishable and RULE-0004's
measurement here would be unfalsifiable."))
  (:default-initargs :language :lisp)
  (:documentation "Drives /usr/bin/sbcl over a tree's ASDF systems."))

;;;; ==================================================================
;;;; Units
;;;; ==================================================================

(defun dot-prefixed-name-p (name)
  (and (stringp name) (plusp (length name)) (char= #\. (char name 0))))

(defun hidden-path-p (path)
  "True when PATH lies inside a dot-directory or is itself dot-prefixed.
The same exclusion REPOSITORY-FILES makes, for the same reason: nothing in
.git or a tool's bookkeeping directory is a system to load.

PATH is relative to the repository root -- see DISCOVER-UNITS."
  (or (dot-prefixed-name-p (file-namestring path))
      (some #'dot-prefixed-name-p (rest (pathname-directory path)))))

(defun test-unit-path-p (path)
  "True when PATH's .asd looks like a test system rather than a primary one.

PATH is relative to the repository root, and that is not a detail -- see
DISCOVER-UNITS, which is where it is made relative.

Two clauses, each measured against a real tree. game-server's seventh .asd is
test/game-integ-test.asd, which matches on both. This tree's own inspector
fixtures are src/analyzer/test/fixtures/inspect/fixture-*/fixture-*.asd, which
match on the directory alone -- and excluding them is not tidiness: fixture-hang
exists to never return and fixture-hog to exhaust the heap, so a default unit
set that included them would make `enrich' on Loom spend its whole timeout
proving that."
  (or (search "test" (pathname-name path) :test #'char-equal)
      (member "test" (rest (pathname-directory path)) :test #'string-equal)
      (member "tests" (rest (pathname-directory path)) :test #'string-equal)))

(defun discover-units (root &key include-test-units)
  "The system names to attempt under ROOT, in the order they will be attempted.

The stem of each .asd file, which is ASDF's own convention for where a system
is found. Sorted rather than left in DIRECTORY's order, because the re-spawn
logic that follows a child's death identifies the in-flight unit by position --
so the order has to be a fact about the tree rather than about the filesystem.

Dependency order is ASDF's business and not this list's: a unit whose
dependency has not loaded pulls it in, so the order affects only how tidily the
per-unit statuses read.

Both exclusions are applied to the path *relative to ROOT*, and that is the
whole of what UIOP:ENOUGH-PATHNAME is doing here. Applied to the absolute path,
a repository checked out under a directory named `test' -- or under a hidden
one, ~/.local/src/foo -- has every one of its systems excluded, and the failure
does not describe itself: INSPECTOR-AVAILABLE-P reports \"no .asd files under
root\", which is a statement about the tree and is false. What is being asked
is whether the tree puts this system in a test directory of its own, and only
the relative path can answer that."
  (let ((paths (remove-if (lambda (path)
                            (let ((relative (uiop:enough-pathname path root)))
                              (or (hidden-path-p relative)
                                  (and (not include-test-units)
                                       (test-unit-path-p relative)))))
                          (directory (merge-pathnames "**/*.asd" (pathname root))))))
    (sort (remove-duplicates (mapcar #'pathname-name paths) :test #'string=)
          #'string<)))

;;;; ==================================================================
;;;; The child program
;;;; ==================================================================
;;;;
;;;; Written to a file and run as `sbcl --script <driver> <root> <result-file>
;;;; <unit>...'. Its contract, which the parent depends on and no compiler
;;;; checks:
;;;;
;;;;   It appends one (:UNIT name :STATUS ...) form to the result file as each
;;;;   unit settles, flushing before it moves on, so a child killed in flight
;;;;   leaves a well-formed prefix rather than a torn form.
;;;;
;;;;   It appends one (:LOOM-INSPECTION ...) facts document at the end.
;;;;
;;;;   It never writes protocol on stdout. Loading a foreign tree sprays
;;;;   compile chatter there, and a crash mid-form would be indistinguishable
;;;;   from a short read -- which is why ARCH-0011 rejected parsing stdout and
;;;;   had the parent name a result file instead.
;;;;
;;;;   It guards each unit with SERIOUS-CONDITION and not ERROR. RULE-0004 with
;;;;   a measurement behind it: a MAKE-ARRAY past --dynamic-space-size inside
;;;;   (handler-case ... (error (c) ...)) is not caught -- the child prints the
;;;;   heap-exhaustion table and dies with "unhandled condition in
;;;;   --disable-debugger mode", exit 1 -- while the same form inside
;;;;   (handler-case ... (storage-condition (c) ...)) catches
;;;;   HEAP-EXHAUSTED-ERROR and the child carries on to the next unit, exit 0.
;;;;
;;;;   Every name crosses as a downcased string with its package as a separate
;;;;   string, so no symbol from target code is ever interned into a Loom
;;;;   package (REQ-0018 R3). That is enforced here, in the child's printing,
;;;;   rather than in the parent's reading.
;;;;
;;;;   It keeps a definition only when the truename of its source file is under
;;;;   ROOT, and emits the path relative to ROOT and forward-slashed. That one
;;;;   filter is what drops every dependency system's symbols, and it makes
;;;;   package ownership irrelevant. The rendering is WORKSPACE-RELATIVE-PATH's,
;;;;   and it is load-bearing twice over: the natural keys ENRICH-OPS computes
;;;;   are keyed on it, and so is the origin index RETRACT-FILE reads to age the
;;;;   fact out.

(defparameter *driver-source*
  "(require :asdf)
(require :sb-introspect)
(defpackage #:loom-inspect-child (:use #:cl))
(in-package #:loom-inspect-child)
(defvar *root* nil)
(defvar *result* nil)
(defvar *definitions* '())
(defvar *calls* '())
(defun emit (form)
  (with-open-file (out *result* :direction :output
                       :if-exists :append :if-does-not-exist :create)
    (let ((*package* (find-package \"COMMON-LISP-USER\"))
          (*print-readably* nil) (*print-pretty* nil) (*print-circle* nil))
      (write form :stream out :escape t))
    (terpri out)
    (finish-output out)))
(defun down (symbol) (string-downcase (symbol-name symbol)))
(defun render-object (x) (if (symbolp x) (down x) (princ-to-string x)))
(defun render-name (name)
  (if (consp name)
      (format nil \"(~{~a~^ ~})\" (mapcar #'render-object name))
      (render-object name)))
(defun name-package (name)
  (let* ((symbol (if (consp name) (second name) name))
         (package (and (symbolp symbol) (symbol-package symbol))))
    (and package (string-downcase (package-name package)))))
(defun relative-file (pathname)
  (let ((truename (ignore-errors (namestring (truename pathname)))))
    (when (and truename (<= (length *root*) (length truename))
               (string= *root* truename :end2 (length *root*)))
      (substitute #\\/ #\\\\ (subseq truename (length *root*))))))
(defun source-file (source)
  (let ((pathname (and source (sb-introspect:definition-source-pathname source))))
    (and pathname (relative-file pathname))))
(defun first-source (name kind)
  (first (ignore-errors (sb-introspect:find-definition-sources-by-name name kind))))
(defun method-designator (generic qualifiers specializers)
  (list :method (render-name generic)
        (when (first qualifiers) (list (render-object (first qualifiers))))
        specializers))
(defun render-key-specializer (spec)
  (if (consp spec)
      (format nil \"(~{~a~^ ~})\" (mapcar #'render-object spec))
      (render-object spec)))
(defun caller-designator (name)
  (cond ((symbolp name) (list :function (render-name name) (name-package name)))
        ((not (consp name)) nil)
        ((not (symbolp (car name))) nil)
        ((string= (symbol-name (car name)) \"SETF\")
         (list :function (render-name name) (name-package name)))
        ((search \"METHOD\" (symbol-name (car name)))
         (let ((tail (rest name)))
           (when (and tail (listp (car (last tail))))
             (method-designator (first tail)
                                (butlast (rest tail))
                                (mapcar #'render-key-specializer (car (last tail)))))))
        (t nil)))
(defun record-callers (callee-designator name)
  (dolist (entry (ignore-errors (sb-introspect:who-calls name)))
    (let ((caller (caller-designator (car entry)))
          (file (source-file (cdr entry))))
      (when (and caller file)
        (push (list :caller caller :caller-file file :callee callee-designator)
              *calls*)))))
(defun definition-entry (kind name source file &rest extra)
  (list* :kind kind
         :name (render-name name)
         :package (name-package name)
         :system (name-package name)
         :file file
         :form-path (sb-introspect:definition-source-form-path source)
         extra))
(defun record-definition (entry &key xref-name)
  (push entry *definitions*)
  (when xref-name
    (record-callers (list (getf entry :kind) (getf entry :name) (getf entry :package))
                    xref-name)))
(defun record-methods (generic)
  (dolist (method (sb-mop:generic-function-methods generic))
    (let* ((source (ignore-errors (sb-introspect:find-definition-source method)))
           (file (source-file source))
           (qualifiers (sb-mop:method-qualifiers method))
           (specializers (mapcar (lambda (s)
                                   (if (typep s 'sb-mop:eql-specializer)
                                       (format nil \"(eql ~a)\"
                                               (render-object
                                                (sb-mop:eql-specializer-object s)))
                                       (down (class-name s))))
                                 (sb-mop:method-specializers method)))
           (name (sb-mop:generic-function-name generic)))
      (when file
        (push (definition-entry :method name source file
                :qualifier (when (first qualifiers) (render-object (first qualifiers)))
                :specializers specializers)
              *definitions*)))))
(defun class-kind (class)
  (cond ((subtypep (class-name class) 'condition) :condition)
        ((typep class 'structure-class) :structure)
        (t :class)))
(defun record-callable (symbol name kind)
  (let* ((source (first-source name kind))
         (file (source-file source)))
    (when file
      (record-definition (definition-entry kind name source file)
                         :xref-name name)))
  (values symbol))
(defun record-symbol (symbol)
  (when (fboundp symbol)
    (cond ((macro-function symbol) (record-callable symbol symbol :macro))
          ((typep (fdefinition symbol) 'generic-function)
           (record-callable symbol symbol :generic-function)
           (record-methods (fdefinition symbol)))
          (t (record-callable symbol symbol :function))))
  (let ((setf-name (list 'setf symbol)))
    (when (fboundp setf-name) (record-callable symbol setf-name :function)))
  (let ((class (find-class symbol nil)))
    (when class
      (let* ((kind (class-kind class))
             (source (first-source symbol kind))
             (file (source-file source)))
        (when file
          (record-definition (definition-entry kind symbol source file))))))
  (when (member (sb-int:info :variable :kind symbol) (list :special :global :constant))
    (let* ((source (first-source symbol :variable))
           (file (source-file source)))
      (when file
        (record-definition (definition-entry :variable symbol source file))))))
(defun introspect ()
  (dolist (package (list-all-packages))
    (unless (eq package (find-package \"KEYWORD\"))
      (do-symbols (symbol package)
        (when (eq (symbol-package symbol) package)
          (ignore-errors (record-symbol symbol)))))))
(defun setup-registry ()
  (dolist (path (directory (merge-pathnames \"**/*.asd\" *root*)))
    (pushnew (make-pathname :name nil :type nil :defaults path)
             asdf:*central-registry* :test #'equal)))
(defun load-unit (name)
  (handler-case
      (progn (handler-bind ((warning #'muffle-warning)) (asdf:load-system name))
             (list :unit name :status :loaded))
    (serious-condition (condition)
      (list :unit name :status :failed :phase :load
            :error (princ-to-string condition)))))
(defun child-main ()
  (let* ((arguments (rest sb-ext:*posix-argv*))
         (root (namestring (truename (first arguments)))))
    (setf *root* root
          *result* (second arguments))
    (let ((setup (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname))))
      (when (probe-file setup)
        (handler-bind ((warning #'muffle-warning)) (load setup))))
    (setup-registry)
    (dolist (unit (cddr arguments)) (emit (load-unit unit)))
    (introspect)
    (emit (list :loom-inspection 1
                :language :lisp
                :toolchain (lisp-implementation-version)
                :root root
                :definitions (nreverse *definitions*)
                :calls (nreverse *calls*)))))
(child-main)
"
  "The child program, verbatim.

A string and not a file in this system's components, because it must not be
loaded into this image under any circumstances -- it calls
ASDF:LOAD-SYSTEM on whatever tree it is pointed at. Kept whole rather than
assembled from fragments so that what is written to disk is what a reader sees
here.")

(defun write-driver-script (path)
  "Write the child program to PATH and return PATH."
  (with-open-file (out path :direction :output
                            :if-exists :supersede :if-does-not-exist :create)
    (write-string *driver-source* out))
  path)

;;;; ==================================================================
;;;; Reading what the child wrote
;;;; ==================================================================

(defun read-inspection-file (path)
  "Every complete form in PATH, in order; NIL when there is no such file.

*READ-EVAL* NIL and a throwaway package, exactly as READ-FORMS-WITH-SPANS does
and for a sharper reason: this text was produced by a process that just loaded
foreign code, so `#.(delete-file ...)' in it would be a remote execution
primitive rather than a curiosity. The package is deleted on the way out, so a
symbol the child happened to print carries nothing into this image. Safety here
is *READ-EVAL*, not the package: reading a symbol is not running anything.

The scratch package USEs COMMON-LISP, unlike READ-FORMS-WITH-SPANS', and that
one word is load-bearing. Under :USE NIL the child's `NIL' -- which every
unqualified method's :QUALIFIER is -- interns as a fresh symbol named \"NIL\" in
the scratch package, and a fresh symbol is TRUE. ENRICH-OPS would then read a
qualifier where there is none, derive :NIL into every unqualified method's
natural key, match nothing, and assert a duplicate :METHOD entity beside every
one the text pass made. Nothing would signal and the entity count would go up,
which is PLAN-0010 R-2's silent doubling arriving through the reader rather
than through a rendering. Found by a test asserting on a parsed caller
designator, which is the only reason it is not in the tree.

A truncated trailing form is expected rather than exceptional. The child
appends and flushes per unit precisely so that a kill leaves a well-formed
prefix, and everything read before the break is kept -- which is what makes a
timeout cost one unit instead of the pass.

CONDITION and not ERROR, on ELEMENT-SPANS' precedent: what is being guarded is
a reader consuming input nobody controls, and READER-ERROR's siblings are not
all ERROR subtypes. The cost of catching too much here is a short read that is
already the expected case; the cost of catching too little is the pass."
  (let ((*package* (make-package (gensym "LOOM-INSPECT-SCRATCH-")
                                 :use '(#:common-lisp)))
        (*read-eval* nil)
        (forms '()))
    (unwind-protect
         (handler-case
             (with-open-file (in path :direction :input :if-does-not-exist nil)
               (when in
                 (loop (let ((form (read in nil :eof)))
                         (when (eq form :eof) (return))
                         (push form forms)))))
           (condition () nil))
      (delete-package *package*))
    (nreverse forms)))

;;;; ==================================================================
;;;; Running the child
;;;; ==================================================================

(defparameter *sbcl-program* "/usr/bin/sbcl"
  "The toolchain this inspector drives.

Absolute rather than found on PATH, and named here rather than assumed, for the
reason the loom skill states about the whole tree: the SBCL behind SLIME is not
necessarily this one, and a pass whose answers depend on which SBCL ran should
be able to say which.")

(defvar *isolation-available* :unprobed
  "Whether `unshare --user --net' works here: T, NIL, or :UNPROBED.

A special variable rather than a slot so a test can bind it, and cached rather
than probed per run because the answer is a property of the kernel and not of
the tree. Measured 2026-08-07: it succeeds unprivileged on this machine, and a
real system compiles inside it with both a warm and a cold fasl cache -- so the
wrapper costs nothing here. What it does break is a target whose dependencies
are not yet downloaded, since quicklisp cannot reach the network inside it, and
that arrives as a unit load failure rather than as anything self-describing.")

(defun isolation-available-p ()
  (when (eq *isolation-available* :unprobed)
    (setf *isolation-available*
          (handler-case
              (zerop (nth-value 2
                                (uiop:run-program '("unshare" "--user" "--net" "/bin/true")
                                                  :ignore-error-status t
                                                  :output nil :error-output nil)))
            ;; A machine with no `unshare' at all signals rather than exiting
            ;; non-zero, and the answer is the same either way.
            (serious-condition () nil))))
  *isolation-available*)

(defun child-command (inspector driver root result units)
  "The argv for one child.

`timeout' and --dynamic-space-size are REQ-0018 R7's two bounds, and both are
outside the child's control on purpose: a target that has redefined a handler,
or exhausted the heap so thoroughly that no handler can run, must still be
killable by something it cannot reach."
  (append (when (and (inspector-isolate-p inspector) (isolation-available-p))
            (list "unshare" "--user" "--net"))
          (list "timeout" (princ-to-string (inspector-timeout-seconds inspector))
                *sbcl-program*
                "--dynamic-space-size" (princ-to-string (inspector-heap-mb inspector))
                "--script" (namestring driver)
                (namestring root) (namestring result))
          units))

(defun run-child (inspector root units)
  "Spawn one child for UNITS. Three values: the forms it wrote, its exit code,
and everything it printed.

:IGNORE-ERROR-STATUS, because a non-zero exit is information rather than a
failure -- 124 is `timeout' having fired, and 1 is a condition no handler in
the child could catch. Stdout and stderr are captured for the log and parsed by
nothing: the protocol is in the result file, which is what makes a crash
mid-form a short read rather than a torn one.

Both paths come from UIOP:WITH-TEMPORARY-FILE, which creates the file itself
and fails rather than reuses when the name is taken. A name built from RANDOM,
which is what this used to do, is not unique between processes: SBCL's initial
*RANDOM-STATE* is fixed at image start, so three fresh `sbcl --eval (random
(expt 2 48))' runs print the same number. Two Loom images enriching at once
would have written one driver over the other, read one result file for both,
and deleted a file the other was still writing -- and on a shared /tmp a local
user could pre-create either path and feed the parent whatever facts they
liked. *READ-EVAL* NIL bounds that to poisoned facts rather than code, which is
not the same as it being bounded."
  (uiop:with-temporary-file (:pathname driver :prefix "loom-inspect-driver" :type "lisp")
    (uiop:with-temporary-file (:pathname result :prefix "loom-inspect-result" :type "sexp")
      (incf (inspector-spawns inspector))
      (write-driver-script driver)
      (multiple-value-bind (output error-output code)
          (uiop:run-program (child-command inspector driver root result units)
                            :ignore-error-status t
                            :output :string :error-output :string)
        (values (read-inspection-file result)
                code
                (concatenate 'string (or output "") (or error-output "")))))))

;;;; ==================================================================
;;;; Assembling what came back
;;;; ==================================================================

(defun form-of-kind (form kind)
  (and (consp form) (eq kind (first form))))

(defun absorb-child-forms (forms units definitions calls)
  "Fold one child's FORMS into the three accumulators, each a reversed list.
Three values, the accumulators."
  (dolist (form forms)
    (cond ((form-of-kind form :unit) (push form units))
          ((form-of-kind form :loom-inspection)
           (dolist (definition (getf form :definitions)) (push definition definitions))
           (dolist (call (getf form :calls)) (push call calls)))))
  (values units definitions calls))

(defun child-toolchain (forms)
  (let ((document (find-if (lambda (form) (form-of-kind form :loom-inspection)) forms)))
    (getf document :toolchain)))

(defun definition-identity (definition)
  (list (getf definition :kind) (getf definition :name)
        (getf definition :package) (getf definition :file)))

(defun call-identity (call)
  (list (getf call :caller) (getf call :callee) (getf call :caller-file)))

(defun deduplicate (items identity)
  "ITEMS with the first of each IDENTITY kept, in order.

Needed because a re-spawned child's xref is scoped to the units IT loaded, so
no single child holds the whole answer and the union across them is what the
parent reports -- with an overlap wherever two children loaded the same
dependency. First rather than last, so the earliest child's account wins and
the result does not depend on how many re-spawns happened to be needed."
  (let ((seen (make-hash-table :test #'equal))
        (kept '()))
    (dolist (item items)
      (let ((key (funcall identity item)))
        (unless (gethash key seen)
          (setf (gethash key seen) t)
          (push item kept))))
    (nreverse kept)))

;;;; ------------------------------------------------------------------
;;;; Line ranges (ARCH-0011 R4)
;;;;
;;;; The child reports a file and a form-path; a Loom entity needs a
;;;; :START-LINE, which is :REQUIRED on every code entity type. The parent maps
;;;; one to the other through the same READ-FORMS-WITH-SPANS the text pass uses,
;;;; applied to the file's own text -- so a definition and its confirmation land
;;;; on the same lines by construction rather than by agreement.
;;;;
;;;; The leading index of the form-path is the top-level form, which is what
;;;; makes a macro-generated definition point at the *call site* that generated
;;;; it rather than at the macro. That is ARCH-0010's wider truth and it is the
;;;; right answer here: it is the region an agent has to open to change it.
;;;;
;;;; A definition whose location cannot be recovered is dropped and counted,
;;;; never given a fabricated range. ENRICH-OPS refuses the same case
;;;; independently, and the duplication is deliberate: a range invented here
;;;; would send an agent to the wrong lines of a real file, which is the
;;;; fabrication hardest to notice (CON-0001).
;;;; ------------------------------------------------------------------

(defun file-form-spans (root file cache)
  "The spans of FILE's top-level forms, read once per file per pass.

CONDITION and not ERROR, on ELEMENT-SPANS' precedent: a file that has changed
since the child read it, or that will not read at all, costs its own
definitions their ranges and nothing else."
  (multiple-value-bind (spans present) (gethash file cache)
    (if present
        spans
        (setf (gethash file cache)
              (handler-case
                  (read-forms-with-spans (slurp-file (merge-pathnames file root)))
                (condition () nil))))))

(defun locate-definitions (root definitions)
  "Two values: DEFINITIONS carrying :START-LINE and :END-LINE, and how many
had to be dropped for want of a range."
  (let ((cache (make-hash-table :test #'equal))
        (located '())
        (dropped 0))
    (dolist (definition definitions)
      (let* ((spans (file-form-spans root (getf definition :file) cache))
             (index (first (getf definition :form-path)))
             (span (when (and spans (integerp index) (< -1 index (length spans)))
                     (nth index spans))))
        (if span
            ;; Prepended, so GETF finds the recovered range and the child's
            ;; plist is left whole rather than edited.
            (push (list* :start-line (second span) :end-line (third span) definition)
                  located)
            (incf dropped))))
    (values (nreverse located) dropped)))

(defun in-flight-failure (unit code)
  "The status a unit gets when the child died before reporting it.

The exit code is named because it is the only diagnosis available: 124 is
`timeout' having fired, measured at exactly the bound, and anything else is a
condition no handler in the child could catch -- a heap exhaustion under a
guard that named ERROR, or a load-time segfault."
  (list :unit unit :status :failed :phase :load
        :error (if code
                   (format nil "child exited ~a before this unit settled~@[~a~]"
                           code (when (eql code 124) "; the timeout fired"))
                   "not attempted: the re-spawn cap was reached")))

(defmethod inspector-available-p ((inspector lisp-inspector) root)
  "Whether there is a toolchain to run and anything to run it on.

Two probes and two reasons, because a caller has to be able to tell \"SBCL is
not installed\" from \"this tree has no systems\" -- the first is worth fixing
and the second is REQ-0018 R2's ordinary recorded absence."
  (cond ((null (probe-file *sbcl-program*))
         (values nil (format nil "no Common Lisp toolchain at ~a" *sbcl-program*)))
        ((null (discover-units root :include-test-units
                                    (inspector-include-test-units inspector)))
         (values nil (format nil "no .asd files under ~a" root)))
        (t (values t nil))))

(defmethod inspect-repository ((inspector lisp-inspector) root &key units)
  "Load ROOT's systems in child SBCLs and return what the image knows.

UNITS overrides the discovered set, which is what lets a caller ask about one
system and a test fix the order.

More than one child, because a bound that fires outside the child's control
takes the whole process with it. After each child, any unit that reported no
status is one the child never reached: the first in the passed order was in
flight when it died, so it is recorded as that unit's gap and the remainder are
attempted again without it. A hard kill therefore costs one unit rather than
the pass (REQ-0018 R4), which is the property that makes bounding the child
acceptable in the first place.

Capped at one re-spawn per unit, so termination is guaranteed rather than
hoped for: every iteration either finishes or drops a unit from the pending
list. Anything still unattempted at the cap gets a status of its own, because a
unit nobody reported is indistinguishable from a unit that loaded clean."
  (let* ((all (or units
                  (discover-units root :include-test-units
                                       (inspector-include-test-units inspector))))
         (pending all)
         (statuses '())
         (definitions '())
         (calls '())
         (toolchain nil))
    (setf (inspector-spawns inspector) 0)
    (loop repeat (length all)
          while pending
          do (multiple-value-bind (forms code) (run-child inspector root pending)
               (setf toolchain (or toolchain (child-toolchain forms)))
               (multiple-value-setq (statuses definitions calls)
                 (absorb-child-forms forms statuses definitions calls))
               (let* ((reported (mapcar (lambda (form) (getf form :unit)) statuses))
                      (missing (remove-if (lambda (unit)
                                            (member unit reported :test #'string=))
                                          pending)))
                 (cond ((null missing) (setf pending '()))
                       (t (push (in-flight-failure (first missing) code) statuses)
                          (setf pending (rest missing)))))))
    (dolist (unit pending) (push (in-flight-failure unit nil) statuses))
    (multiple-value-bind (located dropped)
        (locate-definitions root (deduplicate (nreverse definitions)
                                              #'definition-identity))
      (list :loom-inspection 1
            :language (inspector-language inspector)
            :toolchain toolchain
            :root (namestring root)
            :units (nreverse statuses)
            :definitions located
            :dropped-no-location dropped
            :calls (deduplicate (nreverse calls) #'call-identity)))))

;;;; The one registered instance, mirroring lisp-analyzer.lisp's last line.
;;;; Registering it costs nothing until someone asks: no path in the indexing
;;;; pipeline consults *INSPECTORS*, and ENRICH-REPOSITORY is reachable only
;;;; from the console's `enrich' verb.
(register-inspector (make-instance 'lisp-inspector))
