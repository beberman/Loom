;;;
;;; Tests for src/analyzer/frameworks.lisp -- what a repository declares about
;;; its own frameworks (DES-0025 D4).
;;;

(in-package :loom-analyzer-test)

(def-suite frameworks
  :in all-tests
  :description "Reading .loom/frameworks.yaml, and keeping it per repository.")

(in-suite frameworks)

(defparameter *game-server-frameworks*
  "definer-macros:
  - macro: defroute
    package: easy-routes
    defines: function
    name-index: 1
    body-index: 4
    route-index: 2
    framework: easy-routes
route-callers:
  - callee: [get, post, sendGet, sendPost]
    argument-index: 0
"
  "game-server's declaration, verbatim in shape. Copied rather than invented
so these tests are evidence about the file that tree actually carries.")

(test a-declared-definer-macro-parses-to-a-registry-entry
  (let* ((frameworks (parse-frameworks *game-server-frameworks*))
         (entry (first (getf frameworks :definer-macros))))
    (is (not (null entry)) "the entry parses at all")
    (is (string= "defroute" (getf entry :name)))
    (is (string= "easy-routes" (getf entry :package)))
    (is (eq :function (getf entry :entity-type)))
    (is (eql 1 (getf entry :name-index)))
    (is (eql 4 (getf entry :body-index)))
    (is (eql 2 (getf entry :route-index))
        "the route literal's position is what the HTTP join is derived from")))

(test a-declared-route-caller-parses-its-whole-callee-list
  (let* ((frameworks (parse-frameworks *game-server-frameworks*))
         (entry (first (getf frameworks :route-callers))))
    (is (equal '("get" "post" "sendget" "sendpost") (getf entry :callees))
        "downcased, because a callee name is matched case-insensitively here
and the tree writes sendGet")
    (is (eql 0 (getf entry :argument-index)))))

(test an-entry-missing-what-it-defines-is-dropped-rather-than-guessed
  ;; Minting an entity of no type, or one named from an index nobody supplied,
  ;; is CON-0001's fabricated fact. The file still yields its other entries.
  (let ((frameworks (parse-frameworks
                     "definer-macros:
  - macro: defroute
    package: easy-routes
  - macro: defhandler
    defines: function
")))
    (is (= 1 (length (getf frameworks :definer-macros)))
        "the entry with no defines: is dropped, the usable one survives")
    (is (string= "defhandler"
                 (getf (first (getf frameworks :definer-macros)) :name)))))

(test a-frameworks-file-that-does-not-parse-declares-nothing
  ;; Not half a tree's handlers indexed and the reader left to work out which
  ;; half.
  (is (null (parse-frameworks "definer-macros: [unclosed"))))

(test a-declared-registry-does-not-mutate-the-shipped-one
  ;; DES-0025 D4's whole reason for being a function rather than a
  ;; REGISTER-MACRO-GENERATOR call: two watched repositories must not teach
  ;; each other their frameworks. Before this, the only way to add a generator
  ;; was to push into a global.
  (let* ((base (let ((table (make-hash-table :test #'equal)))
                 (setf (gethash "test" table) (list (list :name "test")))
                 table))
         (frameworks (parse-frameworks *game-server-frameworks*))
         (registry (frameworks-registry frameworks base)))
    (is (gethash "defroute" registry) "the declared entry is in the new table")
    (is (gethash "test" registry) "and the shipped entry came along")
    (is (null (gethash "defroute" base))
        "game-server declaring defroute must not make another tree look for one")))

(test an-absent-frameworks-file-is-not-a-problem
  ;; The normal case for every repository Loom indexed before DES-0025.
  (is (null (read-frameworks "/nonexistent-tree-for-this-test/")))
  (is (null (frameworks-problems "/nonexistent-tree-for-this-test/"))))
