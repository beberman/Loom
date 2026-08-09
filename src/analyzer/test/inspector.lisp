;;;
;;; Tests for src/analyzer/inspector.lisp and src/analyzer/lisp-inspector.lisp
;;; -- the inspector protocol, its registry, and the SBCL child (ARCH-0011).
;;;

(in-package :loom-analyzer-test)

(def-suite inspector
  :in all-tests
  :description "The inspector protocol and registry.")

(in-suite inspector)

;;; A stub, so the registry can be tested without a toolchain. Two classes,
;;; because replace-by-class is the semantics under test and one class cannot
;;; show it.

(defclass stub-inspector (inspector)
  ()
  (:default-initargs :language :lisp))

(defclass other-stub-inspector (inspector)
  ()
  (:default-initargs :language :typescript))

(defmethod inspector-available-p ((inspector stub-inspector) root)
  (declare (ignore root))
  (values nil "stub inspector: nothing to run"))

(defmacro with-empty-registry (&body body)
  "Run BODY against a registry of its own, so a test cannot leave the image's
real registrations behind it."
  `(let ((*inspectors* '())) ,@body))

(test registering-an-inspector-twice-leaves-one-entry
  ;; A recompiled file re-runs its registration form, and an accumulating
  ;; registry would then ask the same toolchain twice per pass.
  (with-empty-registry
    (register-inspector (make-instance 'stub-inspector))
    (register-inspector (make-instance 'stub-inspector))
    (is (= 1 (length *inspectors*)))))

(test registering-a-second-class-does-not-displace-the-first
  (with-empty-registry
    (register-inspector (make-instance 'stub-inspector))
    (register-inspector (make-instance 'other-stub-inspector))
    (is (= 2 (length *inspectors*)))))

(test find-inspectors-answers-for-one-language-only
  (with-empty-registry
    (register-inspector (make-instance 'stub-inspector))
    (register-inspector (make-instance 'other-stub-inspector))
    (is (= 1 (length (find-inspectors :lisp))))
    (is (typep (first (find-inspectors :lisp)) 'stub-inspector))
    (is (null (find-inspectors :python))
        "a language with no inspector is REQ-0018 R2's recorded absence")))

(test an-unavailable-inspector-says-what-was-missing
  ;; REQ-0018 R2. A bare NIL is indistinguishable from "nothing to do", and
  ;; ENRICH-REPOSITORY reports this string verbatim.
  (multiple-value-bind (available reason)
      (inspector-available-p (make-instance 'stub-inspector) "/nowhere/")
    (is (null available))
    (is (stringp reason))
    (is (plusp (length reason)))))

;;; No test asserts that no inspector method reaches LOOM-GRAPH, and the
;;; omission is deliberate rather than an oversight. What enforces it is
;;; loom-analyzer.asd's :DEPENDS-ON, which does not name loom-graph -- so a
;;; reference would fail to compile, in this system and in every future
;;; inspector. A runtime assertion here would test the test suite's own
;;; imports, which prove nothing about the production system, and CON-0003
;;; would rather have no test than one that cannot fail for the right reason.

;;; ==================================================================
;;; The Lisp inspector's child (ARCH-0011 R3, R4)
;;; ==================================================================

(def-suite lisp-inspector
  :in all-tests
  :description "DISCOVER-UNITS, the generated child driver, and its output.")

(in-suite lisp-inspector)

;;; Reached with :: on purpose. DISCOVER-UNITS, WRITE-DRIVER-SCRIPT and
;;; READ-INSPECTION-FILE are the inspector's internals -- the exported surface
;;; is the protocol plus the four bound knobs -- and exporting them so a test
;;; could see them would make the boundary a fiction.

(defun discover-units (root &key include-test-units)
  (loom-analyzer::discover-units root :include-test-units include-test-units))

(defun write-driver-script (path)
  (loom-analyzer::write-driver-script path))

(defun read-inspection-file (path)
  (loom-analyzer::read-inspection-file path))

(defun inspector-spawns (inspector)
  (loom-analyzer::inspector-spawns inspector))

(defun fixture-root (name)
  (asdf:system-relative-pathname
   :loom-analyzer (format nil "test/fixtures/inspect/~a/" name)))

(defun inspect-fixtures-root ()
  (asdf:system-relative-pathname :loom-analyzer "test/fixtures/inspect/"))

(defun scratch-file (name)
  (merge-pathnames (format nil "loom-inspector-test-~36r-~a" (random (expt 2 40)) name)
                   (uiop:temporary-directory)))

(defmacro with-child-run ((forms root &rest units) &body body)
  "Generate the driver, run it against ROOT by hand, and bind FORMS to what it
wrote. Deliberately not through INSPECT-REPOSITORY: step 5 of PLAN-0010 makes
the child debuggable on its own before any parent depends on its output, and a
failure here should point at the child rather than at the spawn logic."
  (let ((driver (gensym)) (result (gensym)))
    `(let ((,driver (scratch-file "driver.lisp"))
           (,result (scratch-file "result.sexp")))
       (unwind-protect
            (progn
              (write-driver-script ,driver)
              (ignore-errors (delete-file ,result))
              (uiop:run-program (list "timeout" "60" "/usr/bin/sbcl" "--script"
                                      (namestring ,driver)
                                      (namestring ,root) (namestring ,result)
                                      ,@units)
                                :ignore-error-status t
                                :output nil :error-output nil)
              (let ((,forms (read-inspection-file ,result)))
                ,@body))
         (ignore-errors (delete-file ,driver))
         (ignore-errors (delete-file ,result))))))

(defun facts-document (forms)
  (find :loom-inspection forms :key (lambda (f) (and (consp f) (first f)))))

(defun unit-forms (forms)
  (remove :unit forms :key (lambda (f) (and (consp f) (first f))) :test-not #'eq))

(defun definition-named (inspection name)
  (find name (getf inspection :definitions)
        :key (lambda (d) (getf d :name)) :test #'string=))

(test discover-units-names-the-primary-systems-and-not-the-test-ones
  ;; Loom's own root is the tree to ask, because it is the one whose numbers
  ;; PLAN-0010 is graded on -- nine .asd files under src/, plus four fixture
  ;; systems under src/analyzer/test/ which must not be units by default. One
  ;; of those fixtures never returns.
  (let* ((root (asdf:system-relative-pathname :loom-analyzer "../../"))
         (units (discover-units root)))
    (is (member "loom-analyzer" units :test #'string=))
    (is (member "loom-ontology" units :test #'string=))
    (is (null (member "fixture-hang" units :test #'string=))
        "a fixture that hangs on purpose must not be in the default unit set")
    (is (equal units (sort (copy-list units) #'string<))
        "the order is a fact about the tree, because the re-spawn logic counts on it")))

(test discover-units-includes-test-systems-when-asked
  (let ((units (discover-units (inspect-fixtures-root) :include-test-units t)))
    (is (equal '("fixture-boom" "fixture-hang" "fixture-hog" "fixture-ok") units))))

(test discover-units-judges-a-path-by-its-place-under-the-root
  ;; The same four fixture systems the test above refuses to see under Loom's
  ;; root, asked about as a repository of their own. Under Loom they sit below
  ;; src/analyzer/test/ and are test units; rooted here, nothing below the root
  ;; says test, so they are the tree's primary systems -- and the exclusions
  ;; have to be able to tell those two questions apart.
  ;;
  ;; What failed while the components came off the absolute path: a repository
  ;; checked out under any directory named `test' -- or a hidden one, such as
  ;; ~/.local/src/foo -- had every unit excluded, and INSPECTOR-AVAILABLE-P then
  ;; reported "no .asd files under root". That is a statement about the tree,
  ;; and it was false.
  (is (equal '("fixture-boom" "fixture-hang" "fixture-hog" "fixture-ok")
             (discover-units (inspect-fixtures-root)))))

(test discover-units-finds-nothing-under-a-tree-with-no-systems
  (is (null (discover-units (asdf:system-relative-pathname
                             :loom-analyzer "test/fixtures/inspect/fixture-ok/nowhere/")))))

(test the-child-reports-a-loaded-unit-and-then-its-facts
  (with-child-run (forms (fixture-root "fixture-ok") "fixture-ok")
    (is (= 1 (length (unit-forms forms))))
    (is (eq :loaded (getf (first (unit-forms forms)) :status)))
    (let ((inspection (facts-document forms)))
      (is (not (null inspection)))
      (is (eq :lisp (getf inspection :language)))
      (is (not (null (definition-named inspection "inner-callee"))))
      (is (not (null (definition-named inspection "outer-caller"))))
      (is (not (null (definition-named inspection "shape-area"))))
      (is (find-if (lambda (call)
                     (and (equal '(:function "outer-caller" "fixture-ok")
                                 (getf call :caller))
                          (equal '(:function "inner-callee" "fixture-ok")
                                 (getf call :callee))))
                   (getf inspection :calls))
          "the DEFUN-to-DEFUN edge both passes can see"))))

(test the-child-sees-a-function-a-macro-generated
  ;; ARCH-0011 R10's DEFENTITY case in miniature, and the whole argument for
  ;; asking the toolchain: GENERATED-READER appears nowhere in the source as a
  ;; DEFUN, and the image knows exactly where it came from.
  (with-child-run (forms (fixture-root "fixture-ok") "fixture-ok")
    (let ((definition (definition-named (facts-document forms) "generated-reader")))
      (is (not (null definition)))
      (is (equal '(6) (getf definition :form-path))
          "the DEFINE-READER call site's own form, which is where an agent
should be sent -- ARCH-0010's wider truth"))))

(test the-compound-method-caller-key-is-parsed-inside-the-inspector
  ;; REQ-0018 R8. SBCL reports this caller as
  ;; (SB-PCL::FAST-METHOD SHAPE-AREA (INTEGER)); nothing outside
  ;; lisp-inspector.lisp may ever see that spelling.
  (with-child-run (forms (fixture-root "fixture-ok") "fixture-ok")
    (let ((inspection (facts-document forms)))
      (is (find-if (lambda (call)
                     (equal '(:method "shape-area" nil ("integer"))
                            (getf call :caller)))
                   (getf inspection :calls)))
      (is (null (search "FAST-METHOD"
                        (with-output-to-string (s) (prin1 inspection s))))
          "SBCL's spelling must not cross the boundary"))))

(test every-definition-the-child-reports-carries-a-relative-file
  ;; The precondition for both halves of the staleness design: ENRICH-OPS keys
  ;; on this string and RETRACT-FILE ages the fact out on it.
  (with-child-run (forms (fixture-root "fixture-ok") "fixture-ok")
    (dolist (definition (getf (facts-document forms) :definitions))
      (let ((file (getf definition :file)))
        (is (stringp file))
        (is (char/= #\/ (char file 0)) "~a is absolute" file)))))

(test the-child-drops-every-definition-outside-the-root
  ;; The one filter that makes package ownership irrelevant. CL-USER, SB-KERNEL
  ;; and ASDF are all loaded in the child and none of them is under the root.
  (with-child-run (forms (fixture-root "fixture-ok") "fixture-ok")
    (let ((packages (remove-duplicates
                     (mapcar (lambda (d) (getf d :package))
                             (getf (facts-document forms) :definitions))
                     :test #'equal)))
      (is (equal '("fixture-ok") packages)))))

;;; ------------------------------------------------------------------
;;; The parent: spawn, bound, read
;;; ------------------------------------------------------------------

(defun fixture-inspector (&rest initargs)
  "A LISP-INSPECTOR bound small enough for a test.

:INCLUDE-TEST-UNITS is on because the fixtures live under a directory named
test, which is exactly what DISCOVER-UNITS excludes by default -- and must, or
`enrich' on this tree would try to load a system whose whole purpose is to
hang."
  ;; INITARGS first: MAKE-INSTANCE takes the leftmost of a repeated initarg, so
  ;; defaults appended after a caller's value would silently win. That cost one
  ;; run of the timeout test sixty seconds instead of three.
  (apply #'make-instance 'lisp-inspector
         (append initargs (list :timeout-seconds 60 :include-test-units t))))

(test inspect-repository-returns-what-the-child-found
  (let ((inspection (inspect-repository (fixture-inspector)
                                        (fixture-root "fixture-ok"))))
    (is (= 1 (length (inspection-units inspection))))
    (is (eq :loaded (getf (first (inspection-units inspection)) :status)))
    (is (eq :lisp (getf inspection :language)))
    (is (stringp (getf inspection :toolchain)))
    (is (not (null (definition-named inspection "inner-callee"))))
    (is (= 3 (length (inspection-calls inspection)))
        "three callers of inner-callee: a DEFUN, a method, and a generated function")))

(test the-result-reader-does-not-evaluate-what-it-reads
  ;; *READ-EVAL* NIL is REQ-0018 R3's concrete content, and this file was
  ;; written by a process that had just loaded foreign code -- so a read-time
  ;; evaluation here is a remote execution primitive, not a curiosity.
  (let ((path (scratch-file "evil.sexp"))
        (witness (scratch-file "witness")))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "(:unit \"a\" :status :loaded)~%")
             (format out "#.(with-open-file (w ~s :direction :output) (print 1 w))~%"
                     (namestring witness)))
           (let ((forms (read-inspection-file path)))
             (is (null (probe-file witness)) "the reader must not have run anything")
             (is (= 1 (length forms))
                 "and everything before the refusal is kept")))
      (ignore-errors (delete-file path))
      (ignore-errors (delete-file witness)))))

(test a-truncated-result-file-yields-every-complete-form-before-the-break
  ;; The expected shape after a kill, not an exceptional one: the child appends
  ;; and flushes per unit precisely so that this is what a timeout leaves.
  (let ((path (scratch-file "truncated.sexp")))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "(:unit \"a\" :status :loaded)~%")
             (format out "(:unit \"b\" :status :loaded)~%")
             (format out "(:loom-inspection 1 :definitions ((:kind :func"))
           (let ((forms (read-inspection-file path)))
             (is (= 2 (length forms)))
             (is (equal '(:unit "b" :status :loaded) (second forms)))))
      (ignore-errors (delete-file path)))))

(test an-unavailable-inspector-names-which-absence-it-found
  (let ((empty (merge-pathnames "loom-inspector-empty/" (uiop:temporary-directory))))
    (ensure-directories-exist empty)
    (multiple-value-bind (available reason)
        (inspector-available-p (fixture-inspector) empty)
      (is (null available))
      (is (search "no .asd files" reason)
          "\"nothing to run it on\" has to read differently from \"no toolchain\""))
    (let ((loom-analyzer::*sbcl-program* "/nonexistent/sbcl"))
      (multiple-value-bind (available reason)
          (inspector-available-p (fixture-inspector) (fixture-root "fixture-ok"))
        (is (null available))
        (is (search "toolchain" reason))))))

(test an-available-inspector-says-so
  (multiple-value-bind (available reason)
      (inspector-available-p (fixture-inspector) (fixture-root "fixture-ok"))
    (is-true available)
    (is (null reason))))

;;; ------------------------------------------------------------------
;;; The bounds fire, and failure is partial (REQ-0018 R4, R7)
;;; ------------------------------------------------------------------

(defun unit-status (inspection name)
  (find name (inspection-units inspection) :key (lambda (u) (getf u :unit))
                                           :test #'string=))

(defun inspect-units (inspector &rest units)
  (inspect-repository inspector (inspect-fixtures-root) :units units))

(test one-units-failure-is-that-units-gap
  ;; REQ-0018 R4. The whole argument for a per-unit guard: fixture-boom signals
  ;; at load time and fixture-ok, loaded after it in the same child, is
  ;; unaffected.
  (let* ((inspector (fixture-inspector))
         (inspection (inspect-units inspector "fixture-ok" "fixture-boom")))
    (is (eq :loaded (getf (unit-status inspection "fixture-ok") :status)))
    (is (eq :failed (getf (unit-status inspection "fixture-boom") :status)))
    (is (plusp (length (getf (unit-status inspection "fixture-boom") :error))))
    (is (not (null (definition-named inspection "inner-callee")))
        "what loaded is introspected, whatever else did not")
    (is (= 1 (inspector-spawns inspector))
        "a condition the child caught costs no re-spawn")))

(test the-timeout-fires-and-costs-one-unit-not-the-pass
  ;; The step's headline. fixture-hang never returns, so no handler in the child
  ;; can help; only the clock can, and the child dies with a whole unit
  ;; unreported. fixture-ok is reachable only through the re-spawn -- the first
  ;; child never got to it. Measured 2026-08-07: `timeout 3' kills at 3.01s,
  ;; exit 124.
  (let* ((inspector (fixture-inspector :timeout-seconds 3))
         (start (get-internal-real-time))
         (inspection (inspect-units inspector "fixture-hang" "fixture-ok"))
         (elapsed (/ (- (get-internal-real-time) start)
                     internal-time-units-per-second)))
    (is (eq :failed (getf (unit-status inspection "fixture-hang") :status)))
    (is (search "124" (getf (unit-status inspection "fixture-hang") :error)))
    (is (eq :loaded (getf (unit-status inspection "fixture-ok") :status)))
    (is (not (null (definition-named inspection "inner-callee"))))
    (is (= 2 (inspector-spawns inspector)) "one kill, one re-spawn")
    (is (< elapsed 30) "the bound has to be a bound: took ~,1fs" elapsed)))

(test the-heap-cap-fires-inside-the-child-rather-than-killing-it
  ;; RULE-0004 with the measurement that settles it. fixture-hog allocates past
  ;; --dynamic-space-size 96, and the spawn count is what distinguishes the two
  ;; guards: SERIOUS-CONDITION catches HEAP-EXHAUSTED-ERROR and the child
  ;; carries on to fixture-ok in the same process, while ERROR alone does not
  ;; catch it and the child dies unhandled at exit 1 -- identical unit statuses,
  ;; two spawns instead of one. Measured 2026-08-07 under /usr/bin/sbcl.
  (let* ((inspector (fixture-inspector :heap-mb 96))
         (inspection (inspect-units inspector "fixture-hog" "fixture-ok")))
    (is (eq :failed (getf (unit-status inspection "fixture-hog") :status)))
    (is (search "HEAP-EXHAUSTED"
                (getf (unit-status inspection "fixture-hog") :error)))
    (is (eq :loaded (getf (unit-status inspection "fixture-ok") :status)))
    (is (= 1 (inspector-spawns inspector))
        "two spawns here means the child's guard named ERROR")))

(test isolation-is-a-knob-and-works-both-ways
  ;; Both directions, so a machine where `unshare' misbehaves fails visibly
  ;; here rather than mysteriously on a real tree. Measured on this machine:
  ;; the probe succeeds unprivileged and a system compiles inside the namespace.
  (dolist (isolate '(nil t))
    (let ((inspection (inspect-units (fixture-inspector :isolate-p isolate)
                                     "fixture-ok")))
      (is (eq :loaded (getf (unit-status inspection "fixture-ok") :status))
          "isolate-p ~a" isolate)
      (is (not (null (definition-named inspection "inner-callee")))))))

;;; ------------------------------------------------------------------
;;; Line ranges, recovered or refused (ARCH-0011 R4)
;;; ------------------------------------------------------------------
;;;
;;; The numbers below are fixture-ok.lisp's own line numbers. Editing that
;;; file means re-measuring them, which its own header says.

(test a-definition-gets-the-real-span-of-its-defining-form
  (let* ((inspection (inspect-repository (fixture-inspector)
                                         (fixture-root "fixture-ok")))
         (callee (definition-named inspection "inner-callee"))
         (generic (definition-named inspection "shape-area")))
    (is (eql 18 (getf callee :start-line)))
    (is (eql 19 (getf callee :end-line)))
    (is (eql 24 (getf generic :start-line)))
    (is (eql 26 (getf generic :end-line)))
    (is (eql 0 (getf inspection :dropped-no-location)))))

(test a-macro-generated-function-is-located-at-the-call-site-that-made-it
  ;; Measured, and worth stating because it is not the tidy answer: the child
  ;; reports form-path (6), which is (define-reader generated-reader) at line
  ;; 32 -- not the DEFMACRO at 28-30. That is ARCH-0010's wider truth and it is
  ;; the right one: the call site is the region an agent has to open to change
  ;; what GENERATED-READER is.
  (let ((definition (definition-named
                        (inspect-repository (fixture-inspector)
                                            (fixture-root "fixture-ok"))
                      "generated-reader")))
    (is (eql 32 (getf definition :start-line)))
    (is (eql 32 (getf definition :end-line)))))

(test a-form-path-past-the-end-of-the-file-is-dropped-and-counted
  ;; A fabricated range would send an agent to the wrong lines of a real file,
  ;; which is the failure hardest to notice. Refusing is the only honest answer
  ;; (CON-0001), and it has to be counted or the refusal is invisible.
  (multiple-value-bind (located dropped)
      (loom-analyzer::locate-definitions
       (fixture-root "fixture-ok")
       (list (list :kind :function :name "inner-callee" :package "fixture-ok"
                   :file "fixture-ok.lisp" :form-path '(2))
             (list :kind :function :name "beyond" :package "fixture-ok"
                   :file "fixture-ok.lisp" :form-path '(9999))
             (list :kind :function :name "nowhere" :package "fixture-ok"
                   :file "no-such-file.lisp" :form-path '(0))))
    (is (= 1 (length located)))
    (is (= 2 dropped))
    (is (eql 18 (getf (first located) :start-line)))))

(test a-pass-in-which-every-unit-fails-still-reports-the-units
  ;; R-5's failure mode, tested rather than described: zero facts and no error
  ;; is what a clean tree looks like too, and only the statuses tell them apart.
  (let ((inspection (inspect-units (fixture-inspector) "fixture-boom")))
    (is (= 1 (length (inspection-units inspection))))
    (is (eq :failed (getf (unit-status inspection "fixture-boom") :status)))
    (is (null (inspection-definitions inspection)))))
