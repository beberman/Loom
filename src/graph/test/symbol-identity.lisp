;;;; The package graph and symbol identity (DES-0015, PLAN-0015 step 7).
;;;;
;;;; Written before anything keys on HOME-PACKAGE, which is the point. The
;;;; second test here is the regression guard for the naive implementation --
;;;; keying on the package a definition was WRITTEN in -- and it has to exist
;;;; before stage C, because that mistake produces a plausible index rather
;;;; than an obviously broken one.

(in-package :synoptik-graph-test)

(in-suite graph-manager)

(defun cl-externals ()
  "COMMON-LISP as BUILD-PACKAGE-GRAPH's :EXTERNAL-PACKAGES wants it.

Built here rather than reached for, which is the point of the argument: the
graph no longer knows what language it is indexing, so a test that wants CL
seeded has to say so. synoptik-analyzer:EXTERNAL-PACKAGE-EXPORTS is the production
source of the same triple."
  (list (list "COMMON-LISP" '("CL")
              (let ((exports '()))
                (do-external-symbols (s (find-package :common-lisp))
                  (push (symbol-name s) exports))
                exports))))

(defun package-fixture (&rest declarations)
  "A graph holding one :PACKAGE per DECLARATION, each a plist of the
properties DEFPACKAGE-shaped forms produce."
  (let ((g (make-graph)))
    (dolist (d declarations g)
      (add-entity g (make-instance 'synoptik-ontology::package-entity
                                   :name (getf d :qualified-name)
                                   :properties (properties-table d))))))

(defun defining (name package)
  "A function entity named NAME, written in PACKAGE."
  (make-instance 'synoptik-ontology::function-entity
                 :name name
                 :properties (properties-table
                              (list :file (format nil "~a.lisp" name)
                                    :start-line 1
                                    :system (intern (string-upcase package)
                                                    :keyword)))))

(test an-imported-symbol-extended-elsewhere-is-one-callable-not-two
  ;; DES-0015 R7, first half. game-server's `id': mpackage/object declares the
  ;; accessor and exports the symbol, mpackage/filter imports that symbol and
  ;; declares a reader of the same name. One generic function, two definitions,
  ;; and a resolver that cannot see the import calls them two callables and
  ;; resolves neither (BUG-0021).
  (let* ((g (package-fixture
             (list :qualified-name "MPACKAGE/OBJECT"
                   :uses '("CL") :exports '("ID"))
             (list :qualified-name "MPACKAGE/FILTER"
                   :nicknames '("MPACKAGE.FILTER")
                   :uses '("CL")
                   :imported-symbols '(("ID" . "MPACKAGE/OBJECT")))))
         (pg (build-package-graph g :external-packages (cl-externals))))
    (is (equal "MPACKAGE/OBJECT" (home-package pg "id" "MPACKAGE/OBJECT")))
    (is (equal "MPACKAGE/OBJECT" (home-package pg "id" "MPACKAGE/FILTER"))
        "the importing package's ID is the exporter's symbol -- following the
import is what collapses six apparent definitions of `id' into the generics
they actually are")
    (is (equal (entity-home-package pg (defining "id" "mpackage/object") "id")
               (entity-home-package pg (defining "id" "mpackage.filter") "id"))
        "and a nickname in the IN-PACKAGE reaches the same answer, which is the
canonicalisation the analyzer is forbidden to do")))

(test a-generic-inherited-from-cl-stays-one-callable-across-every-user
  ;; DES-0015 R7, second half, and the regression test for the naive design.
  ;; game-server has PRINT-OBJECT defined ten times across seven packages. It
  ;; is CL:PRINT-OBJECT, one symbol, reached everywhere by (:use :cl). Today
  ;; the string key merges them and dispatch works by accident; a key on the
  ;; writing package would make seven unrelated generics of it and resolve
  ;; every call to only its own package's subset.
  (let* ((g (package-fixture
             (list :qualified-name "MPACKAGE/OBJECT" :uses '("CL"))
             (list :qualified-name "MPACKAGE/FILTER" :uses '("CL"))
             (list :qualified-name "DATA-API/DB" :uses '("CL"))))
         (pg (build-package-graph g :external-packages (cl-externals)))
         (homes (mapcar (lambda (p) (home-package pg "print-object" p))
                        '("MPACKAGE/OBJECT" "MPACKAGE/FILTER" "DATA-API/DB"))))
    (is (equal '("COMMON-LISP" "COMMON-LISP" "COMMON-LISP") homes)
        "one symbol, inherited -- if this fails, every CL generic specialised
in more than one package has just been split into several")
    (is (= 1 (length (remove-duplicates homes :test #'equal)))
        "which is the property stage C keys on")))

(test a-name-that-could-come-from-a-package-we-cannot-see-is-not-placed
  ;; CON-0001, and the safety property the whole migration rests on. A package
  ;; that uses something undeclared here might be inheriting the name from it,
  ;; so refusing to place it means an unplaceable name falls back to name-only
  ;; matching -- exactly today's behaviour. Nothing this cannot place can
  ;; regress.
  (let* ((g (package-fixture
             (list :qualified-name "INTEGRATION-TEST"
                   :uses '("CL" "FIVEAM" "DRAKMA"))
             (list :qualified-name "SELF-CONTAINED" :uses '("CL"))))
         (pg (build-package-graph g :external-packages (cl-externals))))
    (is (null (home-package pg "id" "INTEGRATION-TEST"))
        "FIVEAM and DRAKMA are not declared in this workspace, so ID might be
theirs; a guess here would be the fabricated binding CON-0001 forbids")
    (is (equal "SELF-CONTAINED" (home-package pg "id" "SELF-CONTAINED"))
        "but a package whose every :use is known interns its own")
    (is (null (home-package pg "id" "NEVER-DECLARED"))
        "and a package with no declaration places nothing")))

(test an-import-from-outside-the-workspace-still-names-one-namespace
  ;; :import-from a package we have no declaration for. The exporter is still a
  ;; distinct namespace and naming it lets two importers agree, which is worth
  ;; more than refusing.
  (let* ((g (package-fixture
             (list :qualified-name "A" :uses '("CL")
                   :imported-symbols '(("PARSE" . "UTILS")))
             (list :qualified-name "B" :uses '("CL")
                   :imported-symbols '(("PARSE" . "UTILS")))))
         (pg (build-package-graph g :external-packages (cl-externals))))
    (is (equal "UTILS" (home-package pg "parse" "A")))
    (is (equal (home-package pg "parse" "A") (home-package pg "parse" "B"))
        "two packages importing one symbol from a third agree about it even
when the third is not declared here")))

(test a-use-cycle-terminates
  ;; Two packages using each other is legal to write and must not hang the
  ;; resolver.
  (let* ((g (package-fixture
             (list :qualified-name "A" :uses '("B" "CL") :exports '("SHARED"))
             (list :qualified-name "B" :uses '("A" "CL") :exports '("SHARED"))))
         (pg (build-package-graph g :external-packages (cl-externals))))
    (is (not (null (home-package pg "shared" "A")))
        "an answer, rather than a stack overflow")))

(test a-re-exported-symbol-resolves-to-where-it-is-homed
  ;; A uses B's symbol, B imported it from C. Following exports rather than
  ;; stopping at the first hop is what makes the chain resolve.
  (let* ((g (package-fixture
             (list :qualified-name "C" :uses '("CL") :exports '("DEEP"))
             (list :qualified-name "B" :uses '("CL") :exports '("DEEP")
                   :imported-symbols '(("DEEP" . "C")))
             (list :qualified-name "A" :uses '("B" "CL"))))
         (pg (build-package-graph g :external-packages (cl-externals))))
    (is (equal "C" (home-package pg "deep" "A"))
        "not B, which merely passes it on")))
