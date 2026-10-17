;;;
;;; Tests for src/analyzer/frameworks.lisp -- what a repository declares about
;;; its own frameworks (DES-0025 D4).
;;;

(in-package :synoptik-analyzer-test)

(def-suite frameworks
  :in all-tests
  :description "Reading .synoptik/frameworks.yaml, and keeping it per repository.")

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
  ;; The normal case for every repository Synoptik indexed before DES-0025.
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

(test the-longest-matching-root-wins-over-nested-ones
  ;; DES-0047 R4. Longest-prefix rather than first-match is what makes nested
  ;; roots an identity rather than an invariant somebody has to enforce: the
  ;; answer does not depend on the order the declaration listed them in.
  (let ((*domains* (domain-table (domains-of "domains:
  - name: ui
    root: src/ui/
  - name: app
    root: src/
"))))
    (is (eq :ui (domain-for-path "src/ui/Home.jsx")) "the longer root wins")
    (is (eq :app (domain-for-path "src/main.js")) "and the shorter still places what it alone matches")
    (is (keywordp (domain-for-path "src/ui/Home.jsx")) "as a keyword")))

(test a-path-under-no-declared-root-is-in-the-default-domain
  (let ((*domains* (domain-table (domains-of "domains:
  - name: ui
    root: src/ui/
"))))
    (is (eq :default (domain-for-path "server/api.js")))))

(test with-no-declaration-every-path-is-in-the-default-domain
  ;; The state every tree has had until now, and why this step changes no
  ;; answer on any of them.
  (let ((*domains* nil))
    (is (eq :default (domain-for-path "src/ui/Home.jsx")))
    (is (eq :default (domain-for-path "anything")))))

(test the-order-of-declaration-cannot-change-which-domain-a-path-is-in
  ;; The same three roots, declared both ways round.
  (let ((forward "domains:
  - name: a
    root: src/
  - name: b
    root: src/ui/
  - name: c
    root: src/ui/widgets/
")
        (backward "domains:
  - name: c
    root: src/ui/widgets/
  - name: b
    root: src/ui/
  - name: a
    root: src/
")
        (path "src/ui/widgets/Button.jsx"))
    (is (eq (let ((*domains* (domain-table (domains-of forward)))) (domain-for-path path))
            (let ((*domains* (domain-table (domains-of backward)))) (domain-for-path path)))
        "declaration order is not part of the answer")
    (is (eq :c (let ((*domains* (domain-table (domains-of forward)))) (domain-for-path path))))))

;;; ------------------------------------------------------------------
;;; entry-points and setting-declarations (DES-0054 D3, R3)
;;; ------------------------------------------------------------------

(defparameter *lfia-frameworks*
  "# Declarations Synoptik reads for this tree (DES-0054 D3). Functions registered by
# these decorators are called by Firebase, not by anything in the tree.
domains:
  - name: functions
    root: functions/
entry-points:
  - framework: firebase-functions
    trigger: schedule
    module: firebase_functions.scheduler_fn
    names: [on_schedule]
    settings: [secrets]
  - framework: firebase-functions
    trigger: https
    module: firebase_functions.https_fn
    names: [on_request, on_call]
    settings: [secrets]
setting-declarations:
  - source: secret
    module: firebase_functions.params
    names: [SecretParam]
  - source: param
    module: firebase_functions.params
    names: [StringParam, IntParam, BoolParam, ListParam]
"
  "lfia-accounting/.synoptik/frameworks.yaml as written when this step
landed, so these tests are evidence about the file that tree carries.")

(defun problems-of (yaml)
  "FRAMEWORKS-PROBLEMS for a scratch tree whose frameworks file is YAML."
  (let ((root (merge-pathnames (format nil "synoptik-frameworks-~36r/" (random (expt 2 48) (make-random-state t)))
                               (uiop:temporary-directory))))
    (unwind-protect
         (let ((path (frameworks-path root)))
           (ensure-directories-exist path)
           (with-open-file (out path :direction :output :if-exists :supersede)
             (write-string yaml out))
           (frameworks-problems root))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test lfias-file-parses-into-its-entry-points-and-setting-declarations
  (let ((frameworks (parse-frameworks *lfia-frameworks*)))
    (is (equal '(:schedule :https)
               (mapcar (lambda (e) (getf e :trigger)) (getf frameworks :entry-points)))
        "the trigger is interned as a keyword")
    (let ((schedule (first (getf frameworks :entry-points))))
      (is (equal "firebase-functions" (getf schedule :framework)))
      (is (equal "firebase_functions.scheduler_fn" (getf schedule :module)))
      (is (equal '("on_schedule") (getf schedule :names)))
      (is (equal '("secrets") (getf schedule :settings))))
    (is (equal '(:secret :param)
               (mapcar (lambda (e) (getf e :source)) (getf frameworks :setting-declarations))))
    (is (equal '("StringParam" "IntParam" "BoolParam" "ListParam")
               (getf (second (getf frameworks :setting-declarations)) :names)))
    (is (null (problems-of *lfia-frameworks*)))))

(test an-entry-with-no-trigger-declares-nothing-and-is-named
  (let* ((yaml "entry-points:
  - module: m
    names: [a]
  - trigger: https
    module: m
    names: [b]
")
         (frameworks (parse-frameworks yaml)))
    (is (equal '("b") (getf (first (getf frameworks :entry-points)) :names)))
    (is (= 1 (length (getf frameworks :entry-points))))
    (let ((problems (problems-of yaml)))
      (is (= 1 (length problems)))
      (is (search "entry-points[0]" (first problems)))
      (is (search "trigger" (first problems))))))

(test a-setting-declaration-needs-a-source-a-module-and-names
  (let ((frameworks (parse-frameworks "setting-declarations:
  - source: secret
    module: m
  - module: m
    names: [A]
")))
    (is (null (getf frameworks :setting-declarations)))
    (is (= 2 (length (getf frameworks :declaration-problems))))
    (is (search "names" (first (getf frameworks :declaration-problems))))
    (is (search "source" (second (getf frameworks :declaration-problems))))))

(test a-callee-named-by-two-entries-is-applied-by-neither
  (let* ((yaml "entry-points:
  - trigger: schedule
    module: m
    names: [on_schedule, other]
  - trigger: https
    module: m
    names: [on_schedule]
")
         (frameworks (parse-frameworks yaml)))
    (is (equal '(("other")) (mapcar (lambda (e) (getf e :names))
                                    (getf frameworks :entry-points)))
        "the shared callee is removed from both; the entry left empty goes")
    (let ((problems (problems-of yaml)))
      (is (= 1 (length problems)))
      (is (search "m.on_schedule" (first problems)))
      (is (search "entry-points[0]" (first problems)))
      (is (search "entry-points[1]" (first problems))))))

(test a-callee-named-across-the-two-keys-is-applied-by-neither
  (let ((frameworks (parse-frameworks "entry-points:
  - trigger: https
    module: m
    names: [f]
setting-declarations:
  - source: secret
    module: m
    names: [f]
")))
    (is (null (getf frameworks :entry-points)))
    (is (null (getf frameworks :setting-declarations)))
    (is (search "setting-declarations[0]"
                (first (getf frameworks :declaration-problems))))))

(test a-file-holding-one-usable-key-is-not-called-useless
  ;; DES-0054 R3. The check counted three keys, so a file with only
  ;; entry-points -- or only domains, which DES-0047 added -- read as
  ;; "declares nothing usable".
  (dolist (yaml '("entry-points:
  - trigger: https
    module: m
    names: [f]
"
                  "domains:
  - name: app
    root: app/
"))
    (is (null (problems-of yaml)) "~a" yaml))
  (is (search "declares nothing usable" (first (problems-of "definer-macros:
  - macro: x
")))
      "a file with no usable key is still called so"))

;;; DES-0055 D6, PLAN-0059 step 4: the dependency-modules: key.

(defparameter *dependency-modules-yaml*
  "dependency-modules:
  - distribution: google-auth
    modules: [google.auth, google.oauth2]
  - distribution: google-api-python-client
    modules: [googleapiclient, apiclient]
  - distribution: requests
    modules: [requests]
"
  "DES-0055 D6's three-entry example, verbatim.")

(test dependency-modules-parse-to-distribution-key-and-modules
  (let ((entries (getf (parse-frameworks *dependency-modules-yaml*) :dependency-modules)))
    (is (= 3 (length entries)))
    (is (equal '("google-auth" "google-api-python-client" "requests")
               (mapcar (lambda (e) (getf e :distribution)) entries)))
    (is (equal '("google-auth" "google-api-python-client" "requests")
               (mapcar (lambda (e) (getf e :key)) entries)))
    (is (equal '("google.auth" "google.oauth2") (getf (first entries) :modules)))
    (is (null (problems-of *dependency-modules-yaml*)))))

(test a-dependency-modules-entry-without-modules-declares-nothing
  (let* ((yaml "dependency-modules:
  - distribution: requests
  - distribution: six
    modules: [six]
")
         (entries (getf (parse-frameworks yaml) :dependency-modules)))
    (is (equal '("six") (mapcar (lambda (e) (getf e :distribution)) entries)))
    (is (equal '("dependency-modules[0] declares nothing: it has no modules")
               (problems-of yaml)))))

(test a-dependency-modules-entry-without-distribution-declares-nothing
  (let ((yaml "dependency-modules:
  - modules: [six]
"))
    (is (null (getf (parse-frameworks yaml) :dependency-modules)))
    ;; The file declares nothing else, so the general report comes first.
    (is (member "dependency-modules[0] declares nothing: it has no distribution"
                (problems-of yaml) :test #'string=))))

(test two-spellings-of-one-distribution-are-applied-by-neither
  (let* ((yaml "dependency-modules:
  - distribution: google-auth
    modules: [google.auth]
  - distribution: Google_Auth
    modules: [google.oauth2]
  - distribution: requests
    modules: [requests]
")
         (frameworks (parse-frameworks yaml))
         (problems (problems-of yaml)))
    (is (equal '("requests")
               (mapcar (lambda (e) (getf e :distribution))
                       (getf frameworks :dependency-modules))))
    (is (= 1 (length problems)))
    (is (and (search "dependency-modules[0]" (first problems))
             (search "dependency-modules[1]" (first problems)))
        "one problem names both indexes: ~s" problems)))

(test a-file-holding-only-dependency-modules-is-not-called-useless
  (is (null (problems-of *dependency-modules-yaml*))
      "the key was not counted before the declares-nothing-usable report"))
