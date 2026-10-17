;;;
;;; Tests for src/analyzer/manifest-analyzer.lisp -- PLAN-0059 step 2, DES-0055
;;; D2 and D3.
;;;
;;; Contents are strings and paths are made up: the analyzer opens nothing.
;;;

(in-package :synoptik-analyzer-test)

(def-suite manifest-analyzer
  :in all-tests
  :description "requirements*.txt and package.json read as declared dependencies.")

(in-suite manifest-analyzer)

(defun mf-graph (path contents)
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'synoptik-analyzer::manifest-analyzer)
                                       path contents "ws-test"))
    g))

(defun mf-modules (g) (entities-of-type g :module))

(defun mf-module (g name)
  (find name (mf-modules g) :key #'name :test #'string=))

(defun mf-file (g) (first (entities-of-type g :file)))

(defparameter *des-0055-requirements*
  "google-auth>=2.29
requests>=2.31
firebase-functions>=0.4.0
tzdata
")

(defun mf-claims-p (path)
  (analyzer-handles-p (make-instance 'synoptik-analyzer::manifest-analyzer) path))

(test the-manifest-analyzer-claims-manifests-and-refuses-the-look-alikes
  (dolist (path '("requirements.txt" "requirements-dev.txt" "sub/requirements_test.txt"
                  "package.json" "functions/package.json"))
    (is-true (mf-claims-p path) "~a should be claimed" path))
  (dolist (path '("requirements.md" "my-requirements.txt" "package.json.bak"
                  "tools/js/vendor/acorn/package.json" "venv/lib/x/package.json"))
    (is-false (mf-claims-p path) "~a should not be claimed" path)))

(test the-markdown-analyzer-declines-requirements-and-keeps-other-text
  (let ((markdown (make-instance 'markdown-analyzer)))
    (is-false (analyzer-handles-p markdown "requirements.txt"))
    (is-true (analyzer-handles-p markdown "design.txt")))
  (is (typep (find-analyzer "requirements.txt") 'synoptik-analyzer::manifest-analyzer)))

(test a-requirements-file-gives-a-module-per-line
  (let ((g (mf-graph "requirements.txt" *des-0055-requirements*)))
    (is (= 4 (length (mf-modules g))))
    (is (equal "module:requirements.txt:google-auth"
               (id (mf-module g "google-auth"))))
    (is (equal '(">=2.29") (getp (mf-module g "google-auth") :specs)))
    (is (null (getp (mf-module g "tzdata") :specs)))
    (is (every (lambda (m) (eq :pypi (getp m :ecosystem))) (mf-modules g)))
    (is (= 2 (getp (mf-module g "requests") :start-line)))
    (is (= 4 (count :contains (all-relationships g) :key #'rel-type)))))

(test an-include-is-recorded-on-the-file-and-is-not-a-module
  (let ((g (mf-graph "requirements-dev.txt" "-r requirements.txt
pytest>=8.0
")))
    (is (equal '("-r requirements.txt") (getp (mf-file g) :includes)))
    (is (equal '("pytest") (mapcar #'name (mf-modules g))))))

(test extras-and-a-marker-stay-in-the-spec
  (let ((g (mf-graph "requirements.txt" "foo[bar]>=1; python_version<\"3.9\"
")))
    (is (equal '("[bar]>=1; python_version<\"3.9\"")
               (getp (mf-module g "foo") :specs)))))

(test a-name-listed-twice-is-one-module-with-both-specs
  (let ((g (mf-graph "requirements.txt" "foo>=1
foo<3
")))
    (is (= 1 (length (mf-modules g))))
    (is (equal '(">=1" "<3") (getp (mf-module g "foo") :specs)))))

(test package-json-sections-and-scope
  (let ((g (mf-graph "package.json" "{
  \"dependencies\": { \"react\": \"^18.3.1\" },
  \"devDependencies\": { \"@testing-library/react\": \"^14.0.0\" },
  \"peerDependencies\": { \"react\": \">=17\" }
}
")))
    (is (= 2 (length (mf-modules g))))
    (is (equal '(:dependencies :peer-dependencies)
               (getp (mf-module g "react") :sections)))
    (is (equal '("^18.3.1" ">=17") (getp (mf-module g "react") :specs)))
    (is (equal '(:dev-dependencies)
               (getp (mf-module g "@testing-library/react") :sections)))
    (is (eq :npm (getp (mf-module g "react") :ecosystem)))
    (is (= 2 (getp (mf-module g "react") :start-line)))))

(test no-module-carries-a-system
  (dolist (g (list (mf-graph "requirements.txt" *des-0055-requirements*)
                   (mf-graph "package.json" "{\"dependencies\": {\"a\": \"1\"}}")))
    (is (plusp (length (mf-modules g))))
    (is (every (lambda (m) (and (null (getp m :system)) (null (getp m :domain))
                                (null (getp m :language))))
               (mf-modules g)))))

(test a-package-json-that-is-not-json-is-a-failed-file-with-no-module
  (let ((g (mf-graph "package.json" "{ not json")))
    (is (null (mf-modules g)))
    (is-true (getp (mf-file g) :analysis-failed-p))))

;;; A credential embedded in a spec must not reach the index (PLAN-0059 risk 1).

(defun mf-mentions-p (value needle)
  (typecase value
    (string (and (search needle value) t))
    (cons (or (mf-mentions-p (car value) needle) (mf-mentions-p (cdr value) needle)))
    (hash-table (let ((hit nil))
                  (maphash (lambda (k v) (when (or (mf-mentions-p k needle)
                                                   (mf-mentions-p v needle))
                                           (setf hit t)))
                           value)
                  hit))
    (t nil)))

(defun mf-graph-mentions-p (g needle)
  (some (lambda (e) (or (mf-mentions-p (id e) needle)
                        (mf-mentions-p (properties e) needle)))
        (all-entities g)))

(test a-credential-in-a-requirement-or-a-spec-is-never-stored
  (let ((requirements (mf-graph "requirements.txt"
                                "--extra-index-url https://user:SENTINEL@host/simple
pkg @ https://user:SENTINEL@host/pkg.whl
git+https://user:SENTINEL@host/r.git#egg=named
"))
        (package (mf-graph "package.json" "{\"dependencies\": {
 \"a\": \"git+https://user:SENTINEL@host/r.git\",
 \"b\": \"https://SENTINEL@host/x.tgz\",
 \"c\": \"file:../SENTINEL\",
 \"d\": \"npm:SENTINEL@1\" }}"))
        (control (mf-graph "requirements.txt" "SENTINEL-pkg>=1
")))
    (is-true (mf-graph-mentions-p control "SENTINEL")
             "the walk finds a SENTINEL that was stored, or it proves nothing")
    (is-false (mf-graph-mentions-p requirements "SENTINEL"))
    (is-false (mf-graph-mentions-p package "SENTINEL"))
    (is (equal '(:url) (getp (mf-module requirements "named") :specs)))
    (is (= 1 (getp (mf-file requirements) :unnamed-requirements)))
    (is (equal '(:git :url :path :alias)
               (mapcar (lambda (n) (first (getp (mf-module package n) :specs)))
                       '("a" "b" "c" "d"))))))
