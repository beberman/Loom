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

(test archived-paths-parse-and-are-downcased
  ;; DES-0025 D6a. Declared rather than guessed: "archive" is this tree's
  ;; convention, and a directory-name allowlist is the proxy REQ-0028 deleted.
  (let ((frameworks (parse-frameworks
                     "archived-paths:
  - docs/archive/
  - docs/OLD/
")))
    (is (equal '("docs/archive/" "docs/old/") (getf frameworks :archived-paths)))))

(test a-frameworks-file-declaring-only-archived-paths-is-usable
  ;; The three keys are independent. A repository with no unusual definers and
  ;; no route conventions may still have an archive, and FRAMEWORKS-PROBLEMS
  ;; must not call that file useless.
  (let ((frameworks (parse-frameworks "archived-paths: [docs/archive/]")))
    (is (null (getf frameworks :definer-macros)))
    (is (equal '("docs/archive/") (getf frameworks :archived-paths)))))

(test an-absent-frameworks-file-is-not-a-problem
  ;; The normal case for every repository Loom indexed before DES-0025.
  (is (null (read-frameworks "/nonexistent-tree-for-this-test/")))
  (is (null (frameworks-problems "/nonexistent-tree-for-this-test/"))))

;;; ------------------------------------------------------------------
;;; Domains (DES-0047, PLAN-0050 S2)
;;; ------------------------------------------------------------------

(defun domains-of (yaml)
  (getf (parse-frameworks yaml) :domains))

(test a-domain-declares-a-name-a-root-and-a-resolution
  (let ((d (first (domains-of "domains:
  - name: server
    root: src/server/
    resolution: node-esm
"))))
    (is (eq :server (getf d :name)) "the name is interned as a keyword, once")
    (is (string= "src/server/" (getf d :root)) "the root stays a string: it is compared against paths")
    (is (eq :node-esm (getf d :resolution)))))

(test a-domain-defaults-to-bundler-resolution
  (is (eq :bundler (getf (first (domains-of "domains:
  - name: ui
    root: src/ui/
")) :resolution))))

(test a-domain-missing-a-name-or-a-root-declares-nothing
  ;; PARSE-FRAMEWORKS' own rule one level down: a half-read domain would place
  ;; files into a prefix whose alias map nobody wrote.
  (is (null (domains-of "domains:
  - root: src/ui/
")))
  (is (null (domains-of "domains:
  - name: ui
"))))

(test an-unknown-resolution-is-refused-rather-than-defaulted
  ;; Defaulting it would hand a tree the wrong toolchain in silence.
  (let* ((yaml "domains:
  - name: ui
    root: src/ui/
    resolution: webpack5
")
         (d (first (domains-of yaml))))
    (is (null (getf d :resolution)) "no resolution rather than bundler")
    (is (= 1 (length (domain-problems (domains-of yaml)))))
    (is (search "webpack5" (first (domain-problems (domains-of yaml)))))))

(test two-domains-cannot-share-a-name
  (let ((problems (domain-problems (domains-of "domains:
  - name: ui
    root: src/ui/
  - name: ui
    root: src/other/
"))))
    (is (= 1 (length problems)))
    (is (search "share one name" (first problems)))
    (is (search "src/other/" (first problems)) "and it names the entries it is about")))

(test two-domains-cannot-share-a-root
  (let ((problems (domain-problems (domains-of "domains:
  - name: ui
    root: src/ui/
  - name: widgets
    root: src/ui/
"))))
    (is (= 1 (length problems)))
    (is (search "share the root" (first problems)))))

(test the-default-name-is-reserved
  (let ((problems (domain-problems (domains-of "domains:
  - name: default
    root: src/ui/
"))))
    (is (= 1 (length problems)))
    (is (search "reserved name" (first problems)))))

(test aliases-from-must-name-a-declared-domain
  (let ((problems (domain-problems (domains-of "domains:
  - name: ui
    root: src/ui/
    aliases-from: nowhere
"))))
    (is (= 1 (length problems)))
    (is (search "not declared" (first problems)))))

(test aliases-from-is-one-hop-and-not-a-chain
  ;; A chain is a small language, and a small language in a configuration file
  ;; is how the file stops being readable.
  (let* ((yaml "domains:
  - name: base
    root: src/base/
    aliases:
      utils: src/base/utils/
  - name: middle
    root: src/middle/
    aliases-from: base
  - name: leaf
    root: src/leaf/
    aliases-from: middle
")
         (problems (domain-problems (domains-of yaml)))
         (table (domain-table (domains-of yaml))))
    (is (= 1 (length problems)))
    (is (search "one hop is allowed and a chain is not" (first problems)))
    (is (equal '(("utils" . "src/base/utils/"))
               (getf (gethash :middle table) :aliases))
        "the one legal hop still copies")
    (is (null (getf (gethash :leaf table) :aliases))
        "and the refused one contributes nothing rather than half a map")))

(test the-default-domain-is-in-the-table-whether-declared-or-not
  ;; So DOMAIN-FOR-PATH always has somewhere to put a file and no caller tests
  ;; for NIL.
  (let ((table (domain-table (domains-of "domains:
  - name: ui
    root: src/ui/
"))))
    (is (gethash :default table))
    (is (string= "" (getf (gethash :default table) :root)))
    (is (eq :bundler (getf (gethash :default table) :resolution)))))

(test every-resolution-name-has-a-preset
  ;; The three names PARSE-DOMAIN accepts and the three the graph will expand
  ;; must be the same three, or a declaration parses and resolves nothing.
  (dolist (name '(:bundler :node-esm :commonjs))
    (is-true (assoc name *resolution-presets*)
             "~a parses and has no preset" name)))
