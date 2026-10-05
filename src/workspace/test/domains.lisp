;;;; Domains, end to end (REQ-0063 R9, DES-0047 R13, PLAN-0050 S8).
;;;;
;;;; Every other test of this work exercises one layer: the parser against a
;;;; string, the resolver against a hand-built table, the pass against a graph
;;;; assembled in memory. This one writes a repository to disk, declares three
;;;; domains in its .loom/frameworks.yaml, and indexes it through the pipeline
;;;; -- which is what makes step 11 a measurement rather than the test.
;;;;
;;;; Through WITH-WORKSPACE-FIXTURE rather than through ANALYZE-FILE, and that
;;;; is not a preference. ANALYZE-PATH is what stamps :DOMAIN, and every
;;;; analyzer test helper in this tree calls ANALYZE-FILE instead -- so a
;;;; fixture built the usual way would assert on a property nothing had
;;;; written and fail for a reason that has nothing to do with domains.

(in-package :loom-workspace-test)

(in-suite all-tests)

(defparameter *domain-frameworks* "domains:
  - name: app
    root: app/
    resolution: bundler
    aliases:
      widgets: app/ui/widgets
      lib: app/lib
  - name: strict
    root: app/strict/
    resolution: node-esm
    aliases-from: app
  - name: legacy
    root: legacy/
    resolution: commonjs
"
  "Three domains: a bundler root with two alias keys, a nested node-esm root
inheriting them through `aliases-from', and a commonjs root with none.

The nesting is the point of the second: app/strict/ lies under app/, so
longest-prefix matching is what decides which one a file in it belongs to.")

(defun make-domain-repository ()
  "A repository on disk declaring *DOMAIN-FRAMEWORKS*, indexed through the
pipeline."
  (setf *fixture-root*
        (merge-pathnames (format nil "loom-domains-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *fixture-root*)
  (write-file ".loom/frameworks.yaml" *domain-frameworks*)
  ;; The alias target, reached from app/ by its key rather than by a path.
  (write-file "app/ui/widgets/Panel.jsx"
              "export function Panel() { return null; }
")
  (write-file "app/lib/helpers.js"
              "export function help() { return 1; }
")
  ;; Written in app/, resolving through the alias map.
  (write-file "app/Home.jsx"
              "import { Panel } from 'widgets/Panel.jsx';
export function Home() { return Panel(); }
")
  ;; Written in app/, extensionless: bundler guesses.
  (write-file "app/Guessing.jsx"
              "import { help } from 'lib/helpers';
export function g() { return help(); }
")
  ;; The nested domain. Inherits app's aliases and resolves under node-esm,
  ;; which guesses nothing.
  (write-file "app/strict/Guard.js"
              "import { Panel } from 'widgets/Panel.jsx';
import { help } from 'lib/helpers';
export function guard() { return Panel() && help(); }
")
  ;; The four causes, one file each.
  (write-file "app/CauseExternal.js" "import x from 'react';
export const a = x;
")
  (write-file "app/CauseUnresolved.js" "import x from './nowhere';
export const b = x;
")
  (write-file "app/CauseUnclaimed.js" "import x from 'widgets/Missing.jsx';
export const c = x;
")
  (write-file "legacy/CauseOutOfDomain.js" "import x from 'widgets/Panel.jsx';
export const d = x;
")
  (watch-repository *fixture-root* :monitor nil :quiet t))

(defmacro with-domain-repository ((repository) &body body)
  `(let ((,repository (make-domain-repository)))
     (unwind-protect (progn ,@body)
       (unwatch-repository (repository-name ,repository))
       (cleanup-fixture))))

(defun node-available-p ()
  "True when a JavaScript child can actually be started.

JS-ANALYZER's JS-AVAILABLE-P by another name, and the duplication is
deliberate: that one lives in LOOM-ANALYZER-TEST, which this system does not
load and should not start loading for one predicate. Both ask
LOOM-ANALYZER::ENSURE-JS-CHILD under its own lock, which is the question."
  (bt:with-lock-held (loom-analyzer::*js-child-lock*)
    (not (null (loom-analyzer::ensure-js-child)))))

(defmacro domain-test (name &body body)
  "A test needing a live node, skipping rather than failing without one.

JS-TEST's rule, restated here because that macro is the analyzer suite's: a red
suite on a machine that cannot run acorn teaches nobody anything, and a skip is
a branch rather than an early return because FiveAM's TEST establishes no block
to return from."
  `(test ,name
     (if (node-available-p)
         (progn ,@body)
         (skip "node is not on PATH; the JavaScript analyzer cannot run here"))))

(defun file-entity (repository path)
  (find path (entities-of-type (repository-graph repository) :file)
        :key (lambda (e) (getp e :path)) :test #'equal))

(defun imports-of (repository path)
  "The paths the file at PATH draws :IMPORTS edges to."
  (let* ((graph (repository-graph repository))
         (file (file-entity repository path)))
    (when file
      (loop for r in (relationships-from graph (id file))
            when (eq :imports (rel-type r))
              collect (getp (get-entity graph (to-id r)) :path)))))

(defun causes-of (repository path)
  "Specifier to cause, for everything in PATH that resolved to nothing."
  (let ((file (file-entity repository path)))
    (loop for entry in (and file (getp file :unresolved-imports))
          collect (cons (getf entry :specifier) (getf entry :cause)))))

(domain-test an-alias-key-resolves-through-the-declared-map
  ;; The tier REQ-0063 exists for: 1320 of front-end's 1885 in-tree imports are
  ;; written this way and resolved to nothing.
  (with-domain-repository (repository)
    (is (member "app/ui/widgets/Panel.jsx" (imports-of repository "app/Home.jsx")
                :test #'equal)
        "app/Home.jsx imports ~a" (imports-of repository "app/Home.jsx"))))

(domain-test a-nested-root-takes-the-file-from-the-domain-above-it
  ;; Longest-prefix matching as an equality on the property itself, rather than
  ;; through anything it goes on to affect.
  (with-domain-repository (repository)
    (is (eq :strict (getp (file-entity repository "app/strict/Guard.js") :domain)))
    (is (eq :app (getp (file-entity repository "app/Home.jsx") :domain)))
    (is (eq :legacy (getp (file-entity repository "legacy/CauseOutOfDomain.js") :domain)))))

(domain-test aliases-from-gives-the-nested-domain-the-map-it-inherits
  (with-domain-repository (repository)
    (is (member "app/ui/widgets/Panel.jsx"
                (imports-of repository "app/strict/Guard.js") :test #'equal)
        "the inherited key resolves in the nested domain too")))

(domain-test a-cross-domain-import-is-an-ordinary-edge
  ;; Nothing about the boundary is recorded on the edge. A file in app/strict/
  ;; importing a file in app/ draws what any other import draws -- the domain
  ;; is a property of the endpoints, not of the relationship.
  (with-domain-repository (repository)
    (let* ((graph (repository-graph repository))
           (from (file-entity repository "app/strict/Guard.js"))
           (edge (find :imports (relationships-from graph (id from)) :key #'rel-type)))
      (is-true edge "there is an :IMPORTS edge to examine")
      (when edge
        (is (eq :strict (getp from :domain)))
        (is (eq :app (getp (get-entity graph (to-id edge)) :domain))
            "the two ends are in different domains")))))

(domain-test node-esm-refuses-the-guess-that-bundler-makes
  ;; One assertion with two different answers, which is what makes the presets
  ;; data rather than decoration: the same extensionless specifier, written in
  ;; two domains, resolving in one and not the other.
  (with-domain-repository (repository)
    (is (member "app/lib/helpers.js" (imports-of repository "app/Guessing.jsx")
                :test #'equal)
        "bundler guesses the extension")
    (is (not (member "app/lib/helpers.js" (imports-of repository "app/strict/Guard.js")
                     :test #'equal))
        "and node-esm does not, for the same specifier against the same file")))

(domain-test each-of-the-four-causes-is-recorded-on-the-file-that-produced-it
  (with-domain-repository (repository)
    (is (equal '(:external) (mapcar #'cdr (causes-of repository "app/CauseExternal.js"))))
    (is (equal '(:unresolved) (mapcar #'cdr (causes-of repository "app/CauseUnresolved.js"))))
    (is (equal '(:unclaimed-target)
               (mapcar #'cdr (causes-of repository "app/CauseUnclaimed.js")))
        "the alias rewrote it and the index holds nothing under the result")
    (is (equal '(:out-of-domain)
               (mapcar #'cdr (causes-of repository "legacy/CauseOutOfDomain.js")))
        "a key app declares and legacy does not")))

(domain-test a-root-no-indexed-file-lies-under-is-reported
  ;; R3's seventh refusal, and the only one that needs the tree rather than the
  ;; declaration -- which is why it is checked in REPOSITORY-STATUS and tested
  ;; here against a real repository instead of a hand-built status plist.
  ;;
  ;; It is the shape a stale declaration takes: a root renamed in the tree and
  ;; not in the file partitions nothing, every file that should have been in it
  ;; falls to :DEFAULT, every alias it declared stops applying, and the file
  ;; still looks exactly as correct as it did.
  (with-domain-repository (repository)
    (write-file ".loom/frameworks.yaml"
                (concatenate 'string *domain-frameworks*
                             "  - name: ghost
    root: no/such/directory/
"))
    (index-repository repository :quiet t)
    (let ((problems (getf (repository-status repository) :domain-problems)))
      (is-true (find-if (lambda (p) (search "ghost" p)) problems)
               "the ghost root is reported: ~a" problems)
      (is-true (find-if (lambda (p) (search "no indexed file lies under" p)) problems)
               "and the reason is named"))))

(domain-test the-status-splits-imports-by-cause-with-the-zeroes-kept
  ;; S9 puts the decision in REPOSITORY-STATUS rather than in the printer: a
  ;; module-scoped tree gets five numbers and a Common Lisp tree gets NIL, so
  ;; the printer has nothing to decide. This asserts the decision.
  ;;
  ;; Every key present including the zeroes, which is DES-0002 R10's rule: a
  ;; count that vanishes when it is nought cannot be told from a count nobody
  ;; computed. On this fixture out-of-domain is the one that is non-zero and
  ;; external is not, which is the opposite of a real tree -- so asserting
  ;; presence rather than magnitude is what makes the test portable.
  (with-domain-repository (repository)
    (let ((imports (getf (repository-status repository) :unresolved-imports)))
      (is-true imports "a tree with JavaScript in it reports an import split")
      (dolist (key '(:resolved :external :out-of-domain :unresolved :unclaimed-target
                     :unrooted))
        (is-true (integerp (getf imports key))
                 "~a is absent or not a number: ~a" key imports))
      (is (plusp (getf imports :resolved)) "the fixture resolves something")
      (is (plusp (getf imports :out-of-domain))
          "and legacy/ importing an app/ alias key is counted out-of-domain"))))

(test the-import-summary-counts-an-unrooted-python-import
  ;; DES-0053 D5's sixth cause, summed from what RESOLVE-IMPORTS wrote on the
  ;; :FILE. Built by hand: no Python file is claimed by an analyzer in this
  ;; commit, and what is asserted is the summing and not the resolution.
  (with-workspace-fixture (repository)
    (add-entity (repository-graph repository)
                (make-instance 'file-entity :name "functions/tests/t.py"
                               :origin-file "functions/tests/t.py"
                               :properties (properties-table
                                            (list :path "functions/tests/t.py"
                                                  :language :python
                                                  :unresolved-imports
                                                  '((:specifier "ledger.refs" :cause :unrooted)
                                                    (:specifier "ledger.dates" :cause :unrooted)
                                                    (:specifier "pytest" :cause :external))))))
    (let ((imports (loom-workspace::import-summary repository)))
      (is (= 2 (getf imports :unrooted)))
      (is (= 1 (getf imports :external))))
    (is (getf (repository-status repository) :unresolved-imports)
        "and a repository holding a Python file is module-scoped, so it reports a split")))

(test a-repository-with-no-module-scoped-file-reports-no-import-split
  ;; A Common Lisp tree has no import graph, and five noughts there would be a
  ;; count of a question nobody asked. No node needed: this asserts the absence.
  (with-workspace-fixture (repository)
    (is (null (getf (repository-status repository) :unresolved-imports))
        "a Lisp-only tree reports no import split at all")))

;;; ------------------------------------------------------------------
;;; Addressing a domain (PLAN-0050 S12)
;;; ------------------------------------------------------------------

(test splitting-a-designator-never-breaks-a-path-that-names-a-repository
  ;; R-h. Every path has slashes in it. A split that ran before the lookup
  ;; would read "/home/beberman/lisp/Loom" as a repository called
  ;; "/home/beberman/lisp" and a domain called "Loom", and the path spelling
  ;; the console encourages would stop working.
  ;;
  ;; The three FIND-REPOSITORY branches, asserted through SPLIT-DESIGNATOR: the
  ;; name, the normalised path, and the raw path.
  (with-workspace-fixture (repository)
    (let ((name (repository-name repository))
          (root (namestring (repository-root repository))))
      (dolist (designator (list name root (string-right-trim "/" root)))
        (multiple-value-bind (found domain) (split-designator designator)
          (is (eq repository found) "~s did not find the repository" designator)
          (is (null domain) "~s bound a domain and should not" designator))))))

(domain-test a-designator-can-name-a-domain-of-a-repository
  (with-domain-repository (repository)
    (let ((name (repository-name repository)))
      (multiple-value-bind (found domain)
          (split-designator (concatenate 'string name "/strict"))
        (is (eq repository found))
        (is (eq :strict (getf domain :name)))))))

(domain-test an-unknown-domain-is-refused-and-names-the-declared-ones
  ;; The refusal is why the lookup happens before the name is interned: a typo
  ;; must not add a keyword to the image, and the caller is told what they
  ;; could have written.
  (with-domain-repository (repository)
    (let ((name (repository-name repository)))
      (handler-case
          (progn (split-designator (concatenate 'string name "/nosuchdomain"))
                 (is-true nil "an unknown domain was accepted"))
        (loom-utils:refusal (condition)
          (let ((text (loom-utils:refusal-message condition)))
            (is-true (search "nosuchdomain" text) "~a" text)
            (is-true (search "app" text) "the declared domains are named: ~a" text)
            (is-true (search "strict" text) "~a" text)))))))

(test a-designator-naming-no-repository-returns-nothing-rather-than-refusing
  ;; The callers already have a message for an unwatched repository and it is
  ;; not this function's to duplicate.
  (with-workspace-fixture (repository)
    (is-true repository "the fixture is watched, so the lookup has somewhere to fail")
    (multiple-value-bind (found domain) (split-designator "no-such-repository")
      (is (null found))
      (is (null domain)))))
