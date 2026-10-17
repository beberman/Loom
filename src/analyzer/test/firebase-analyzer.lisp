;;;
;;; Tests for src/analyzer/firebase-analyzer.lisp -- DES-0054 D4 and R4.
;;;
;;; The contents are strings and the paths are made up, and one of them names a
;;; directory that does not exist: the analyzer opens nothing, and a test that let
;;; it read the disk would not notice if it started to.
;;;

(in-package :synoptik-analyzer-test)

(def-suite firebase-analyzer
  :in all-tests
  :description "firebase.json's codebases and .firebaserc's project aliases.")

(in-suite firebase-analyzer)

(defparameter *lfia-firebase-json*
  "{
  \"functions\": [{ \"source\": \"functions\", \"codebase\": \"default\", \"runtime\": \"python312\",
                  \"ignore\": [\"venv\", \".env.example\", \"__pycache__\", \"tests\"] }],
  \"firestore\": {
    \"rules\": \"firestore.rules\",
    \"indexes\": \"firestore.indexes.json\"
  },
  \"emulators\": {
    \"auth\": { \"port\": 9099 },
    \"ui\": { \"enabled\": false },
    \"singleProjectMode\": true
  }
}
"
  "lfia-accounting/firebase.json as it stood when this step landed.")

(defparameter *lfia-firebaserc*
  "{
  \"projects\": { \"default\": \"example-project\" }
}
")

(defun fb-file (path contents)
  "The :FILE entity ANALYZE-FILE asserts for PATH, after the ops are applied."
  (let ((g (make-graph)))
    (apply-transaction g (analyze-file (make-instance 'synoptik-analyzer::firebase-analyzer)
                                       path contents "ws-test"))
    (first (all-entities g))))

(defun fb-codebases (contents)
  (getp (fb-file "firebase.json" contents) :codebases))

(test lfias-firebase-json-gives-one-codebase
  (let ((codebases (fb-codebases *lfia-firebase-json*)))
    (is (equal '((:source "functions" :codebase "default" :runtime "python312"
                  :ignore ("venv" ".env.example" "__pycache__" "tests")
                  :defaulted nil))
               codebases))))

(test the-legacy-object-form-is-one-codebase-with-the-name-defaulted
  (is (equal '((:source "fn" :codebase "default" :ignore nil :defaulted (:codebase)))
             (fb-codebases "{\"functions\": {\"source\": \"fn\"}}"))))

(test an-empty-entry-takes-both-defaults-and-no-runtime
  (let ((codebase (first (fb-codebases "{\"functions\": [{}]}"))))
    (is (equal "functions" (getf codebase :source)))
    (is (equal "default" (getf codebase :codebase)))
    (is (equal '(:source :codebase) (getf codebase :defaulted)))
    (is (not (member :runtime codebase))
        "an absent runtime stays absent: guessing one is a fabricated fact")))

(test two-codebases-are-two-plists-in-file-order
  (is (equal '("a" "b")
             (mapcar (lambda (c) (getf c :codebase))
                     (fb-codebases "{\"functions\": [{\"codebase\": \"a\", \"source\": \"x\"},
 {\"codebase\": \"b\", \"source\": \"y\"}]}")))))

(test a-comment-makes-the-file-unparsed-and-says-so
  (let ((file (fb-file "firebase.json" "{
  // the functions
  \"functions\": [{\"source\": \"fn\"}]
}")))
    (is (not (null (getp file :analysis-error))))
    (is-true (getp file :analysis-failed-p) "`status' counts it under unparsed")
    (is (null (getp file :codebases)))))

(test lfias-firebaserc-gives-its-project-alias
  (is (equal '(("default" . "example-project"))
             (getp (fb-file ".firebaserc" *lfia-firebaserc*) :project-aliases))))

(test only-the-two-names-are-claimed-and-never-under-a-vendored-path
  (let ((analyzer (make-instance 'synoptik-analyzer::firebase-analyzer)))
    (dolist (path '("firebase.json" ".firebaserc" "apps/api/firebase.json" "fn/.firebaserc"))
      (is-true (analyzer-handles-p analyzer path) "~a" path))
    (dolist (path '("node_modules/x/firebase.json" "vendor/y/.firebaserc"
                    "package.json" "firebase.json.bak" "my-firebase.json" "tsconfig.json"))
      (is-false (analyzer-handles-p analyzer path) "~a" path))))

(test a-path-that-does-not-exist-is-analyzed-from-its-contents
  (let ((file (fb-file "no/such/dir/firebase.json" *lfia-firebase-json*)))
    (is (equal "no/such/dir/firebase.json" (getp file :path)))
    (is (= 1 (length (getp file :codebases))))))

(test the-file-is-found-by-the-registry
  (is (typep (find-analyzer "functions/firebase.json") 'synoptik-analyzer::firebase-analyzer))
  (is (typep (find-analyzer ".firebaserc") 'synoptik-analyzer::firebase-analyzer)))

(test a-config-that-is-not-an-object-is-unparsed
  (is-true (getp (fb-file "firebase.json" "[1, 2]") :analysis-failed-p))
  (is-true (getp (fb-file ".firebaserc" "") :analysis-failed-p)))
