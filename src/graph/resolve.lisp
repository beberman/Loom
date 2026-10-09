;;;; Cross-file call resolution.
;;;; Implements the workspace half of Phase 1 Software Architecture SS8.3:
;;;; "CALLS relationships where the callee resolves within the workspace
;;;; (unresolved calls are recorded as a property, not a dangling edge)."
;;;;
;;;; This cannot live in an analyzer. SS8.1 makes analyzers stateless and
;;;; file-scoped, so one sees the call to APPLY-TRANSACTION but has no way to
;;;; know that transaction.lisp defines it -- it records the name and moves
;;;; on. Resolution is the first thing that needs the whole workspace in one
;;;; place, which is here.
;;;;
;;;; It is also the difference between a graph that can answer questions and
;;;; one that cannot. Without it, :CALLS edges stop at file boundaries, so
;;;; "what calls this?" and "what breaks if I change this?" -- the two
;;;; questions the impact engine exists to answer -- return almost nothing.
;;;;
;;;; Reads a view and returns operations; it does not apply them. The caller
;;;; submits them like any other transaction, which keeps the Graph Manager
;;;; the only writer (SS5.1).

(in-package :loom-graph)

(defparameter *callable-types* '(:function :method :interface)
  "Entity types a :CALLS edge may terminate at, per the :CALLS declaration in
code-ontology.lisp.

:INTERFACE is here because a generic function is callable, not because calls
route through generics -- DES-0001 says they do not. It is the target of last
resort, taken only when a protocol has no implementation in the workspace to
fan out to.")

(defun entities-by-name (view types)
  "Name -> list of entities of TYPES defined under it, downcased.
A list rather than a single entity because nothing stops two files defining
the same name, and pretending otherwise is how a resolver invents edges."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (type types)
      (dolist (entity (entities-of-type view type))
        (when (slot-boundp entity 'name)
          (push entity (gethash (string-downcase (name entity)) index)))))
    index))

(defun callable-index (view) (entities-by-name view *callable-types*))

(defparameter *module-file-extensions*
  '(".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx")
  "Extensions a module specifier may have left off, in the order tried.

A specifier is written without one -- `import { X } from \'./widget\'` -- and the
file on disk is widget.js, widget.jsx or widget/index.js. Resolution here is
against the *index* and never against the filesystem: loom-graph has no
filesystem and must not acquire one, and a specifier naming a file no analyzer
claimed is a specifier that resolves to nothing, which is the right answer
either way.")

(defun normalize-segments (segments)
  "SEGMENTS with `.', `..' and empty components resolved away."
  (let ((out '()))
    (dolist (segment segments (nreverse out))
      (cond ((or (string= segment ".") (string= segment "")) nil)
            ((string= segment "..") (pop out))
            (t (push segment out))))))

(defun matching-alias (specifier aliases)
  "The longest alias key of ALIASES that SPECIFIER is written under, or NIL.

A key matches a specifier equal to it or beginning with it followed by `/',
never a bare prefix of a longer word: `utils' must not claim `utilsx/thing'.

Longest first, so a declaration carrying both `ui' and `ui/widgets' sends
`ui/widgets/Button' to the second. Two returns -- the key and its target -- so
the caller does not look the target up again."
  (let ((best nil) (best-length -1))
    (dolist (pair aliases)
      (let* ((key (car pair))
             (length (length key)))
        (when (and (> length best-length)
                   (<= length (length specifier))
                   (string= key specifier :end2 length)
                   (or (= length (length specifier))
                       (char= (char specifier length) #\/)))
          (setf best pair best-length length))))
    best))

(defun resolution-preset (domain)
  "The extension list, guessing flag and index fallback DOMAIN resolves under.

Read from the plist the analyzer handed in, never from a table this system
reaches for. DOMAIN-TABLE expands the preset into the plist precisely so that
loom-graph reads no configuration -- DES-0025 D4, and the production dependency
S3 already had to undo once.

A domain carrying no expansion falls back to the six bundler extensions with
guessing and the index fallback, which is what every tree resolved under before
domains existed."
  (if (getf domain :resolution)
      ;; :RESOLUTION is the marker that DOMAIN-TABLE expanded this plist, and
      ;; it is the right one because :EXTENSIONS is not: node-esm's list is
      ;; legitimately empty, so testing the list made node-esm indistinguishable
      ;; from a caller who named no domain -- and it then resolved under
      ;; bundler, which is the one answer node-esm exists to refuse.
      (values (getf domain :extensions)
              (getf domain :guess-extension)
              (getf domain :index-fallback))
      ;; No expansion on the plist: a caller that named no domain at all. The
      ;; six bundler extensions with guessing and the index fallback, which is
      ;; what *MODULE-FILE-EXTENSIONS* has always held and what every tree
      ;; resolved under before domains existed.
      (values *module-file-extensions* t t)))

(defun resolve-under-preset (target known extensions guess index-fallback)
  "TARGET as an indexed path under a preset, or NIL.

The exact path first, whatever the preset: a specifier that names a file this
index holds resolves to it under every toolchain. Guessing and the index
fallback are what the presets differ on."
  (or (and (gethash target known) target)
      (and guess
           (loop for extension in extensions
                 for candidate = (concatenate 'string target extension)
                 when (gethash candidate known) do (return candidate)))
      (and index-fallback
           (loop for extension in extensions
                 for candidate = (concatenate 'string target "/index" extension)
                 when (gethash candidate known) do (return candidate)))))

(defun resolve-module-specifier (specifier importer known &key domain sibling-aliases)
  "The workspace path SPECIFIER names when written in IMPORTER, and why not.

  (resolve-module-specifier specifier importer known &key domain sibling-aliases)
  ;; -> (values target-path-or-nil cause-when-nil)

KNOWN is a table of every file path the index holds. DOMAIN is the plist the
analyzer parsed, handed in and never read from disk -- loom-graph reads no
configuration. NIL means the default domain, which means the six bundler
extensions with guessing and the index fallback, and therefore today's
behaviour character for character: DES-0047 R2's promise that every tree keeps
the behaviour it has.

SIBLING-ALIASES is the set of alias keys OTHER domains declare, and exists for
one cause. A specifier written under a key this domain does not declare and
another does is a different fact from one written under a key nobody declares:
the first is a file importing across a boundary its own domain cannot see, and
the second is an external package. Telling them apart needs the whole table,
which this function is not given, so the caller passes the keys.

THE FOUR CAUSES, which is what makes a miss actionable rather than a silence:

  :EXTERNAL          not relative, no alias key matched anywhere. `react'.
  :OUT-OF-DOMAIN     an alias key another domain declares and this one does not.
  :UNCLAIMED-TARGET  it resolved to a path no indexed file holds -- the target
                     exists as text and the index has nothing under it, which
                     on a real tree means a directory the analyzer does not
                     claim rather than a typo.
  :UNRESOLVED        relative, and no candidate under the preset is indexed.

CON-0001 at the import layer. 1320 of front-end's 1885 in-tree imports resolve
to nothing today and the index records only that they did not; the cause is the
half a reader acts on, because an alias nobody declared and a path that is
simply wrong need different repairs."
  (unless (and (stringp specifier) (plusp (length specifier)))
    (return-from resolve-module-specifier (values nil :unresolved)))
  (multiple-value-bind (extensions guess index-fallback) (resolution-preset domain)
    (let ((relative (char= (char specifier 0) #\.)))
      (cond
        (relative
         (let* ((directory (butlast (path-segments importer)))
                (target (format nil "~{~a~^/~}"
                                (normalize-segments
                                 (append directory (path-segments specifier))))))
           (let ((found (resolve-under-preset target known extensions guess index-fallback)))
             (if found (values found nil) (values nil :unresolved)))))
        (t
         (let ((alias (matching-alias specifier (getf domain :aliases))))
           (cond
             (alias
              (let* ((key (car alias))
                     (rest (subseq specifier (length key)))
                     (target (concatenate 'string (cdr alias) rest))
                     (found (resolve-under-preset target known extensions
                                                  guess index-fallback)))
                (if found (values found nil) (values nil :unclaimed-target))))
             ((and sibling-aliases (matching-alias specifier sibling-aliases))
              (values nil :out-of-domain))
             (t (values nil :external)))))))))

;;;; ==================================================================
;;;; Python specifiers (DES-0053 D5)
;;;; ==================================================================
;;;;
;;;; A Python specifier names a module by where Python looks for it, and the
;;;; places are a function of the importer: its own directory when that is not
;;;; a package, the parent of the package it sits in, and a declared domain
;;;; root. Package-ness is read from the index -- a directory is a package when
;;;; "<dir>/__init__.py" is an indexed path -- so nothing here reads the
;;;; filesystem, and a file that exists on disk and is not indexed is not there.

(defstruct (python-index (:constructor %make-python-index))
  "What the Python resolver asks of the index, built once per pass.
KNOWN is every indexed path. DIRECTORIES holds every directory prefix, ending
in a slash, above an indexed .py file. TOP-NAMES holds every module, package
and directory name that appears in the tree, which is what separates :UNROOTED
from :EXTERNAL."
  (known       nil)
  (directories (make-hash-table :test #'equal) :type hash-table)
  (top-names   (make-hash-table :test #'equal) :type hash-table))

(defun make-python-index (known)
  "The PYTHON-INDEX over KNOWN, a table of every indexed file path."
  (let ((index (%make-python-index :known known)))
    (maphash
     (lambda (path present)
       (declare (ignore present))
       (when (and (> (length path) 3) (string= ".py" path :start2 (- (length path) 3)))
         (let* ((segments (path-segments path))
                (file (car (last segments)))
                (stem (subseq file 0 (- (length file) 3))))
           (unless (string= stem "__init__")
             (setf (gethash stem (python-index-top-names index)) t))
           (loop for segment in (butlast segments)
                 for prefix = (format nil "~a/" segment)
                   then (format nil "~a~a/" prefix segment)
                 do (setf (gethash prefix (python-index-directories index)) t
                          (gethash segment (python-index-top-names index)) t)))))
     known)
    index))

(defun directory-prefix (path)
  "PATH's directory as a prefix ending in a slash, or \"\" at the root."
  (let ((slash (position #\/ path :from-end t)))
    (if slash (subseq path 0 (1+ slash)) "")))

(defun parent-directory-prefix (directory)
  "The prefix of DIRECTORY's parent: a/b/ is a/, and a/ and \"\" are \"\"."
  (let ((slash (position #\/ directory :from-end t
                                       :end (max 0 (1- (length directory))))))
    (if slash (subseq directory 0 (1+ slash)) "")))

(defun python-module-file (index directory segments)
  "The indexed path of the module SEGMENTS name under DIRECTORY, or NIL.

\"a.b\" is a/b.py or a/b/__init__.py. No segments names the package DIRECTORY
itself, which is its __init__.py."
  (let ((known (python-index-known index))
        (base (format nil "~a~{~a~^/~}" directory segments)))
    (flet ((held (path) (and (gethash path known) path)))
      (if (null segments)
          (held (concatenate 'string directory "__init__.py"))
          (or (held (concatenate 'string base ".py"))
              (held (concatenate 'string base "/__init__.py")))))))

(defun python-import-roots (importer index domain)
  "The directories an absolute specifier written in IMPORTER is tried under, in
D5's order, without repeats.

  1. IMPORTER's own directory, when it holds no indexed __init__.py. Python
     puts a script's directory on sys.path, and a directory that is not a
     package can only be imported from by being on sys.path.
  2. The parent of the outermost package containing IMPORTER. A package named
     ledger is imported as `ledger' only when its parent is on sys.path.
  3. DOMAIN's root, which arrives as data: loom-graph reads no configuration.
     Only a declared domain's. The implicit :DEFAULT domain has root \"\" and is
     in the table whether or not anything declared it, so taking its root would
     make a repository-root module importable from tools/ whenever some
     unrelated JavaScript domain is declared and not otherwise (REV-0003 item 4).

Never \"walk up until some directory holds the module\". Python does not look
there, and the first local file named like a library would capture every import
of it."
  (let* ((known (python-index-known index))
         (directory (directory-prefix importer))
         (roots '()))
    (flet ((package-p (dir)
             (gethash (concatenate 'string dir "__init__.py") known)))
      (if (package-p directory)
          (let ((top directory))
            (loop while (and (plusp (length top)) (package-p top))
                  do (setf top (parent-directory-prefix top)))
            (push top roots))
          (push directory roots)))
    (let ((root (and (not (eq :default (getf domain :name))) (getf domain :root))))
      (when root
        (push (if (or (string= root "") (char= #\/ (char root (1- (length root)))))
                  root
                  (concatenate 'string root "/"))
              roots)))
    (remove-duplicates (nreverse roots) :test #'string= :from-end t)))

(defun split-dotted (string)
  "STRING's non-empty components between dots."
  (loop with start = 0
        for dot = (position #\. string :start start)
        for part = (subseq string start dot)
        when (plusp (length part)) collect part
        while dot do (setf start (1+ dot))))

(defun resolve-python-specifier (specifier importer index &key domain)
  "The workspace path SPECIFIER names when written in IMPORTER, and why not.

  (resolve-python-specifier specifier importer index &key domain)
  ;; -> (values target-path-or-nil cause-when-nil)

The causes are DES-0047's with one more:

  :UNRESOLVED  relative and no such module, or absolute and the first segment
               is held under one of the importer's roots but the whole name is
               not. An in-tree miss, which is what a reader acts on.
  :UNROOTED    absolute, no root of this importer holds the name, and a module
               or package of that top-level name is indexed somewhere else.
               functions/tests' `from ledger.refs import ...' is this until a
               domain declares functions/ as a root, and the cause says which
               declaration is missing where :EXTERNAL would have called ledger
               a library.
  :EXTERNAL    no root holds the name and no indexed file is named for it.

A relative specifier starts in the importer's directory and climbs one
directory per dot after the first."
  (unless (and (stringp specifier) (plusp (length specifier)))
    (return-from resolve-python-specifier (values nil :unresolved)))
  (let* ((dots (or (position #\. specifier :test-not #'char=) (length specifier)))
         (segments (split-dotted (subseq specifier dots))))
    (if (plusp dots)
        (let ((directory (directory-prefix importer)))
          (dotimes (climb (1- dots))
            (declare (ignorable climb))
            (when (string= directory "")
              (return-from resolve-python-specifier (values nil :unresolved)))
            (setf directory (parent-directory-prefix directory)))
          (let ((found (python-module-file index directory segments)))
            (if found (values found nil) (values nil :unresolved))))
        (let ((roots (python-import-roots importer index domain)))
          (dolist (root roots)
            (let ((found (python-module-file index root segments)))
              (when found
                (return-from resolve-python-specifier (values found nil)))))
          (let ((top (first segments)))
            (cond ((null top) (values nil :unresolved))
                  ((some (lambda (root)
                           (or (python-module-file index root (list top))
                               (gethash (format nil "~a~a/" root top)
                                        (python-index-directories index))))
                         roots)
                   (values nil :unresolved))
                  ((gethash top (python-index-top-names index))
                   (values nil :unrooted))
                  (t (values nil :external))))))))

(defun python-submodule-specifier (specifier name)
  "The specifier `from SPECIFIER import NAME' may also be naming: the submodule.
`from ledger import dates' reads ledger/dates.py when ledger/__init__.py does
not define dates, and Python tries both."
  (if (char= #\. (char specifier (1- (length specifier))))
      (concatenate 'string specifier name)
      (format nil "~a.~a" specifier name)))

(defun python-submodule-targets (file importer index domain)
  "The files FILE's `from S import a' bindings name as submodules S.a.

Read from :IMPORT-BINDINGS, which holds module-level bindings only. A from-import
inside a function adds nothing to the module scope; its calls still resolve,
because they are :IMPORTED-CALLS entries and the walk tries the submodule
itself (DES-0053 D6 step 3)."
  (loop for binding in (getp file :import-bindings)
        for specifier = (getf binding :specifier)
        for name = (getf binding :name)
        when (and specifier name (string/= name "*") (plusp (length specifier)))
          append (let ((target (resolve-python-specifier
                                (python-submodule-specifier specifier name)
                                importer index :domain domain)))
                   (and target (list target)))))

(defun sibling-alias-keys (domains except)
  "Every alias key declared by a domain in DOMAINS other than EXCEPT.

The set :OUT-OF-DOMAIN is decided against, as keys rather than a second map: a
specifier written under a key some other domain declares is a file importing
across a boundary its own domain cannot see, and that is a different fact from
an external package. What it resolves TO is that other domain's business."
  (let ((keys '()))
    (when domains
      (maphash (lambda (name domain)
                 (unless (eq name except)
                   (dolist (pair (getf domain :aliases))
                     (pushnew (car pair) keys :test #'string=))))
               domains))
    (mapcar (lambda (key) (cons key nil)) keys)))

(defun build-module-scope (view &key domains)
  "File path -> the paths of the files it imports, and what did not resolve.

  (build-module-scope view &key domains)
  ;; -> (values scope unresolved)

Empty for a tree of Common Lisp, which is what makes this cost nothing where it
buys nothing: VISIBLE-CANDIDATES asks the table only after
MODULE-SCOPED-LANGUAGE-P has already said yes.

DOMAINS is the keyword-to-plist table the analyzer built. Each importer's
domain is looked up by the :DOMAIN keyword its :FILE entity already carries --
no prefix matching here, because step 3 decided the partition and this reads
the answer. A file carrying no domain, which is every file in every tree that
declared none, gets NIL and therefore the behaviour this function has always
had.

The second value is CON-0001 at the import layer: path to a list of
(:specifier ... :cause ...) for everything that resolved to nothing. Recorded
rather than dropped, because the cause is the half a reader acts on."
  (let ((known (make-hash-table :test #'equal))
        (scope (make-hash-table :test #'equal))
        (unresolved (make-hash-table :test #'equal))
        ;; Built on the first Python importer, so a tree with none pays nothing.
        (python-index nil))
    (dolist (file (entities-of-type view :file))
      (let ((path (getp file :path)))
        (when path (setf (gethash path known) t))))
    (dolist (file (entities-of-type view :file))
      (let ((path (getp file :path)))
        (when (and path (module-scoped-language-p (getp file :language)))
          (let* ((name (getp file :domain))
                 (domain (and domains name (gethash name domains)))
                 (siblings (and domains name (sibling-alias-keys domains name)))
                 (python-p (eq :python (getp file :language)))
                 (targets '())
                 (misses '()))
            (when (and python-p (null python-index))
              (setf python-index (make-python-index known)))
            (dolist (specifier (getp file :import-sources))
              ;; The importer's language chooses the resolver: Python's rules
              ;; are not JavaScript's, and every other language keeps
              ;; RESOLVE-MODULE-SPECIFIER exactly as it was (DES-0053 D5).
              (multiple-value-bind (target cause)
                  (if python-p
                      (resolve-python-specifier specifier path python-index
                                                :domain domain)
                      (resolve-module-specifier specifier path known
                                                :domain domain
                                                :sibling-aliases siblings))
                (if target
                    (pushnew target targets :test #'equal)
                    (push (list :specifier specifier :cause cause) misses))))
            (when python-p
              (dolist (target (python-submodule-targets file path python-index domain))
                (pushnew target targets :test #'equal)))
            (setf (gethash path scope) targets)
            (when misses (setf (gethash path unresolved) (nreverse misses)))))))
    (values scope unresolved)))

(defun resolve-imports (view &key workspace-id domains module-scope unresolved)
  "Operations linking each import specifier to the file it names.

One :IMPORTS edge per resolved (importer, target) pair, and one
UPDATE-PROPERTIES writing :UNRESOLVED-IMPORTS onto every :FILE that recorded
any specifier at all.

DEC-0003, and the shape RESOLVE-CALLS already has with :CALL-NAMES: both
outputs are derived from :IMPORT-SOURCES on every pass and neither consumes it.
A pass that rewrote its own input could not be re-run, and the edge a retract
destroyed would never come back.

The UPDATE-PROPERTIES is unconditional for a file with any :IMPORT-SOURCES, for
the reason the :UNRESOLVED-CALLS write gives a hundred lines down: a file whose
every specifier now resolves has to have that written down, and one whose
target has since been deleted has to have the entry grow back. Writing only
when something failed would make the property a high-water mark.

MODULE-SCOPE and UNRESOLVED are BUILD-MODULE-SCOPE's two values and are handed
in together by a caller that already has them -- which is what
RESOLVE-AND-CHECK will do, because building the scope twice would compute the
same misses twice and report them once. Taking only the first and recomputing
the second would be that same waste wearing the argument that avoids it, so
they arrive as a pair or not at all."
  (multiple-value-bind (scope unresolved)
      (if module-scope
          (values module-scope (or unresolved (make-hash-table :test #'equal)))
          (build-module-scope view :domains domains))
    (let ((ops '())
          ;; Path to entity, built on the walk this function already makes.
          ;; A natural-key lookup per import would ask the same question once
          ;; per specifier and would encode the key shape here, where it is not
          ;; this function's to know.
          (by-path (make-hash-table :test #'equal)))
      (dolist (file (entities-of-type view :file))
        (let ((path (getp file :path)))
          (when path (setf (gethash path by-path) file))))
      (dolist (file (entities-of-type view :file))
        (let ((path (getp file :path)))
          (when (and path (module-scoped-language-p (getp file :language)))
            (dolist (target (gethash path scope))
              (let ((to (gethash target by-path)))
                (when to
                  (push (assert-edge :imports file to :workspace-id workspace-id)
                        ops))))
            (when (getp file :import-sources)
              (push (update-properties (id file)
                                       (list :unresolved-imports
                                             (gethash path unresolved))
                                       workspace-id)
                    ops)))))
      (nreverse ops))))

(defun visible-candidates (candidates caller scope)
  "CANDIDATES reduced to the ones the module CALLER is written in can see.

Two tiers, and the order is the language's. A definition in the calling file
shadows every same-named definition elsewhere, so if any candidate is local
the local ones are the whole answer. Otherwise the candidates in files this one
imports are, because a name from a module nobody imported is not in scope at
all.

Never empties the set. Where neither tier applies the original is returned
unchanged. What the rule can do is reduce a fan-out; what it must never do is
refuse a name this reasoning does not govern.

A member call is the name this reasoning does not govern, and after BUG-0036 it
no longer arrives here at all: `log.commit()' is recorded as LOG.COMMIT and
answered by MEMBER-CALL-CANDIDATES, whose property tier does not call this
function. A method is a property of an object rather than a module binding, so
which modules the caller imports says nothing about which class the receiver
holds. What still passes through here is that call's third tier -- the property
as a bare name, where no method of it exists anywhere and the receiver is a
module namespace."
  (let ((language (and caller (getp caller :language)))
        (file     (and caller (getp caller :file))))
    (if (or (null scope) (null file) (not (module-scoped-language-p language)))
        candidates
        (let ((local (remove-if-not (lambda (e) (equal file (getp e :file)))
                                    candidates)))
          (or local
              (let ((visible (gethash file scope)))
                (and visible
                     (remove-if-not (lambda (e)
                                      (member (getp e :file) visible :test #'equal))
                                    candidates)))
              candidates)))))

(defstruct (name-lookup (:constructor %make-name-lookup))
  "Entities under a name, keyed two ways (DES-0015).

BY-NAME is CALLABLE-INDEX, name to definitions, and stays the answer whenever
symbol identity cannot be established. BY-HOME is keyed on (home-package .
name), which is the identity a Common Lisp callable actually has.

Both, rather than one, because HOME-PACKAGE cannot place every name -- 8 of
Loom's 11 package-spanning names and 54 of game-server's 95, measured
2026-08-10, because their packages use packages no declaration in the tree
describes. Falling back to BY-NAME for those makes this strictly more precise
or identical: a name that can be placed resolves against its own package, and
a name that cannot resolves exactly as it did before. Nothing this cannot
place can regress, which is what lets game-server's 7085 at-risk edges move in
one step and still be reviewable."
  (by-name       (make-hash-table :test #'equal) :type hash-table)
  (by-home       (make-hash-table :test #'equal) :type hash-table)
  (package-graph nil)
  ;; BUG-0035. Empty on a tree with no module-scoped language in it, and
  ;; consulted only after MODULE-SCOPED-LANGUAGE-P has said the caller is
  ;; written in one, so a Lisp-only tree pays one empty table.
  (module-scope  (make-hash-table :test #'equal) :type hash-table)
  ;; BUG-0036. Property name -> the methods defined under it, whatever class
  ;; each belongs to. A method entity is named Class.method, so BY-NAME can
  ;; only be asked about a member call whose receiver is spelled like the
  ;; class; this is the index for the ones that are not, and it holds methods
  ;; alone because a plain function is not what a property access reaches.
  (by-property   (make-hash-table :test #'equal) :type hash-table))

(defun name-lookup (view types &key external-packages package-graph module-scope)
  "ENTITIES-BY-NAME plus the package-aware index over the same entities.

PACKAGE-GRAPH may be supplied by a caller resolving several kinds of name in
one pass, so the graph is assembled once rather than once per index.

MODULE-SCOPE is there for the same reason and defaults to NIL meaning build
one. A caller that already built the scope -- because it also wanted the
unresolved specifiers, which building it twice would compute twice and report
once -- hands it in."
  (let* ((by-name (entities-by-name view types))
         (pg (or package-graph
                 (build-package-graph view :external-packages external-packages)))
         (by-home (make-hash-table :test #'equal)))
    (maphash (lambda (name entities)
               (dolist (e entities)
                 (let ((home (entity-home-package pg e name)))
                   (when home
                     (push e (gethash (cons home name) by-home))))))
             by-name)
    (%make-name-lookup :by-name by-name :by-home by-home :package-graph pg
                       :module-scope (or module-scope (build-module-scope view))
                       :by-property (methods-by-property by-name))))

(defun callable-lookup (view &key external-packages package-graph module-scope)
  "The callable half of NAME-LOOKUP, which is what RESOLVE-CALLS wants."
  (name-lookup view *callable-types*
               :external-packages external-packages :package-graph package-graph
               :module-scope module-scope))

(defun member-call-parts (name)
  "The receiver and the property of a member call name -- `log.commit\' is LOG
and COMMIT -- or NIL for a name that is not one.

One dot, with a non-empty half on each side. A second dot means the receiver
was itself an expression rather than a name, and the extractor reports the
property alone for that case (BUG-0036), so a two-dot name arriving here is
not something this can read.

A Common Lisp caller never takes this path: CANDIDATE-ENTITIES asks
MODULE-SCOPED-LANGUAGE-P first, and a dot in a Lisp symbol is a character in a
name rather than a property access."
  (let ((dot (position #\. name)))
    (when (and dot (plusp dot) (< (1+ dot) (length name))
               (not (find #\. name :start (1+ dot))))
      (values (subseq name 0 dot) (subseq name (1+ dot))))))

(defun methods-by-property (by-name)
  "BY-NAME\'s methods, re-keyed on the property half of their names.

Methods only. A member call reaches a property of an object, and a plain
module-level function of the same spelling is not one -- which is the whole of
BUG-0036: `set.persist()\' matched three unrelated `function persist\' in test
files and none of the eight `persist\' methods, because a method entity is
named TypeSet.persist and nothing was asking for it under PERSIST."
  (let ((index (make-hash-table :test #'equal)))
    (maphash (lambda (key entities)
               (multiple-value-bind (receiver property) (member-call-parts key)
                 (declare (ignore receiver))
                 (when property
                   (dolist (entity entities)
                     (when (and (eq :method (entity-type entity))
                                (module-scoped-language-p (getp entity :language)))
                       (push entity (gethash property index)))))))
             by-name)
    index))

(defun same-identifier-p (a b language-a language-b)
  "True when the identifiers A and B, written in LANGUAGE-A and LANGUAGE-B, are
the same identifier.

Case is folded only when *both* languages fold it. That asymmetry is the whole
of BUG-0029: the index is keyed on a downcased name and therefore matches
`error\' to `Error\', which is right for two Common Lisp symbols and wrong for
two JavaScript ones. Requiring both sides rather than either is the
conservative reading -- a pair that disagrees about case gets the strict rule,
so a language Loom has never seen cannot inherit Lisp\'s folding by being
compared against a Lisp definition."
  (if (and (case-insensitive-language-p language-a)
           (case-insensitive-language-p language-b))
      (string-equal a b)
      (string= a b)))

(defun same-identifier-candidates (candidates name caller)
  "CANDIDATES reduced to those whose name really is NAME, read from CALLER.

The downcased index is a *search structure* after BUG-0029 and not the
equality itself: it returns a superset keyed on a fold every language may not
share, and this is where the pair-wise judgement happens. It has to be
pair-wise, because whether two spellings are one identifier depends on both
languages and no single hash key can express that.

A NIL CALLER keeps the whole set. That is RESOLVE-GENERATED-DEFINITIONS asking
whether a name reaches anything at all, with nothing to take a language from,
and the old answer is the only one available."
  (let ((language (and caller (getp caller :language))))
    (if (null caller)
        candidates
        (remove-if-not (lambda (entity)
                         (and (slot-boundp entity 'name)
                              (same-identifier-p name (name entity)
                                                 language (getp entity :language))))
                       candidates))))

(defun property-candidates (candidates property caller)
  "CANDIDATES reduced to the methods whose own property really is PROPERTY.

METHODS-BY-PROPERTY keys on a downcased half, the way ENTITIES-BY-NAME keys on
a downcased name, and for the same reason: the table is a search structure and
not the equality. SAME-IDENTIFIER-P decides, so a JavaScript `Commit\' and a
JavaScript `commit\' stay two properties (BUG-0029).

VISIBLE-CANDIDATES deliberately does not follow. A property is not a module
binding -- that is what makes BUG-0036 a separate defect from BUG-0035 -- so
which modules the caller imports is evidence about its own bindings and not
about what its receiver holds. Narrowing this fan-out by imports would often
leave one candidate, and a single :CALLS edge asserting that `set.persist()\'
reaches TypeSet.persist because the file imports TypeSet is the confident wrong
edge BUG-0036 refuses. Fanned out at 1/N it stays a reported guess (CON-0001)."
  (let ((language (and caller (getp caller :language))))
    (remove-if-not
     (lambda (entity)
       (and (slot-boundp entity 'name)
            (multiple-value-bind (receiver own) (member-call-parts (name entity))
              (declare (ignore receiver))
              (and own (same-identifier-p property own
                                          language (getp entity :language))))))
     candidates)))

(defun member-call-candidates (index name property caller)
  "The definitions the member call NAME could reach, read from CALLER.

Three tiers, tried in order, and the first that answers is the answer. This is
DES-0015\'s shape in a language with no packages: place the name where the
source actually put it, and fall back to the spelling only when it cannot be
placed.

  the receiver names a class  the methods named exactly NAME. `this.commit()\'
                              inside GestureLog is recorded as
                              GestureLog.commit by the extractor, so the
                              enclosing class -- which is not a guess -- makes
                              this one edge at full confidence.

  some method has the
  property                    every method of that property, whatever class.
                              `set.persist()\' reaches one of the eight
                              `persist\' methods and the source does not say
                              which, which is a union of genuine possibilities
                              and so fans out as dispatch does (DES-0001)
                              rather than as an ambiguity.

  none does                   the property as a bare name, which is exactly
                              what this call resolved to before BUG-0036. It is
                              the namespace import -- `import * as api\' then
                              `api.fetchGame()\' -- where the receiver is a
                              module and the property really is a plain
                              function.

What the tiers never do is let a member call reach a plain function while any
method of that property exists. That is the population BUG-0036 measured: 18 of
front-end\'s 50 fan-outs were `persist\' pointing at two test-local `function
persist\' and one arrow in a mock."
  (flet ((admit (candidates spelling)
           (visible-candidates
            (same-identifier-candidates candidates spelling caller)
            caller
            (name-lookup-module-scope index))))
    (or (admit (gethash (string-downcase name) (name-lookup-by-name index)) name)
        (property-candidates
         (gethash (string-downcase property) (name-lookup-by-property index))
         property caller)
        ;; The third tier is JavaScript's namespace import, `api.fetchGame()'.
        ;; The Python extractor has already written every namespace access as an
        ;; :IMPORTED-CALLS entry, so a Python caller reaching here has a receiver
        ;; that is no module, and a bare function of the property's name is the
        ;; wrong edge (DES-0053 D6).
        (unless (python-caller-p caller)
          (admit (gethash (string-downcase property) (name-lookup-by-name index))
                 property)))))

(defun candidate-entities (index name caller)
  "The definitions NAME could name, as read from CALLER.

INDEX may be a bare hash table, which is what CALLABLE-INDEX returns and what
every caller passed before DES-0015. That path is the old behaviour exactly,
which is why tools/test/call-site-census.lisp keeps working unchanged and why a
CALLER of NIL -- RESOLVE-GENERATED-DEFINITIONS asking whether a name reaches
anything at all -- still gets the unrestricted answer.

Both index paths are filtered through SAME-IDENTIFIER-CANDIDATES on the way
out, including the package-placed one: DES-0015 establishes that a name is one
*symbol*, which is a Common Lisp question, and answering it does not make the
spelling right in a language that has no packages.

A member call takes neither path. MEMBER-CALL-CANDIDATES answers it, because
`log.commit\' is placed by its receiver and not by a package, and the tiers it
tries are what BUG-0036 is. Only where the caller\'s language is module-scoped:
a dot in a Common Lisp symbol is a character in a name.

VISIBLE-CANDIDATES follows it on the NAME-LOOKUP path, and only there: the
bare-hash-table path is RESOLVE-GENERATED-DEFINITIONS asking whether a definer
name reaches anything at all, which is a Common Lisp question about a tree with
no module scope in it. The two filters compose in the order they are named --
which spellings are this identifier, then which of those this module can see --
and neither can ever add a candidate."
  (let ((key (string-downcase name)))
    (flet ((admit (candidates)
             (visible-candidates
              (same-identifier-candidates candidates name caller)
              caller
              (and (typep index 'name-lookup) (name-lookup-module-scope index)))))
      (etypecase index
        (hash-table (values (admit (gethash key index)) nil))
        (name-lookup
         (multiple-value-bind (receiver property)
             (when (and caller (module-scoped-language-p (getp caller :language)))
               (member-call-parts name))
           (declare (ignore receiver))
           (when property
             ;; A member call is placed by its receiver, not by its package:
             ;; the home-package lookup below has nothing to say about a
             ;; language with no packages, and the spelling lookup it falls
             ;; back to is the defect. Second value NIL -- symbol identity is
             ;; a Common Lisp question and was not established here.
             (return-from candidate-entities
               (values (member-call-candidates index name property caller) nil))))
         (let* ((home (and caller
                           (home-package (name-lookup-package-graph index)
                                         name (entity-package caller))))
                (placed (and home (gethash (cons home key)
                                           (name-lookup-by-home index)))))
           ;; The second value says whether symbol identity was established.
           ;; A caller that fans out across the candidate set needs to know:
           ;; fanning across a set assembled by spelling alone would assert
           ;; edges between definitions that share nothing but a name, which is
           ;; the fabrication DES-0015 exists to stop.
           (if placed
               (values (admit placed) t)
               (values (admit (gethash key (name-lookup-by-name index))) nil))))))))

(defun unique-match (index name &optional referrer)
  "The one entity INDEX holds under NAME as REFERRER sees it, or NIL for none
or several.

REFERRER is what makes this package-aware: a superclass or a specialiser named
in two packages matched several candidates and therefore resolved to nothing,
which is CON-0001 refusing to guess. Given the referring entity, the candidates
are those NAME actually reaches from where it was written, so the honest answer
is often one. A NIL REFERRER, or an INDEX that is a bare hash table, is the old
behaviour exactly."
  (let ((candidates (candidate-entities index name referrer)))
    (when (and candidates (null (rest candidates)))
      (first candidates))))

;;;; ==================================================================
;;;; Structure: inheritance, dispatch, and protocols (DES-0001)
;;;; ==================================================================
;;;;
;;;; Three more kinds of cross-file name, resolved the same way calls are and
;;;; for the same reason: a superclass, a specializer and a generic can each be
;;;; declared in a file the analyzer was not looking at. Each is derived from a
;;;; property the analyzer wrote and never rewrites, per DEC-0003, so an edge
;;;; destroyed by retracting the file it pointed into comes back on the next
;;;; pass.

(defun resolve-inheritance (view &key workspace-id package-graph)
  "Operations linking each class to the superclasses it declares.

A name that matches no class in the workspace is left alone rather than
recorded: unlike a call, a superclass that is not here is almost always
STANDARD-OBJECT, ERROR, or another part of the language, and reporting those
as unresolved would be noise rather than a staleness signal."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (class (entities-of-type view :class))
      (dolist (name (getp class :superclass-names))
        (let ((super (unique-match index name class)))
          (when (and super (not (eq super class)))
            (push (assert-edge :inherits class super :workspace-id workspace-id) ops)))))
    (nreverse ops)))

(defun eql-specializer-p (name)
  "True for a rendered EQL specializer such as \"(eql :svg)\".
It dispatches on a value, not a class, so there is no class edge to draw."
  (and (plusp (length name)) (char= #\( (char name 0))))

(defun resolve-specializers (view &key workspace-id package-graph)
  "Operations linking each method to the classes its parameters dispatch on.

One edge per specialised parameter, which is the whole answer to multiple
dispatch: a method has no owning class, it has as many class edges as it has
specialisers. A parameter specialised on T dispatches on everything and so
says nothing worth recording."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (dolist (specializer (getp method :specializers))
        (unless (or (string-equal specializer "t") (eql-specializer-p specializer))
          (let ((class (unique-match index specializer method)))
            (when class
              (push (assert-edge :uses method class :workspace-id workspace-id) ops))))))
    (nreverse ops)))

(defun resolve-method-protocols (view &key workspace-id package-graph)
  "Operations linking each method to the generic function it implements.

Only a declared generic: a method whose DEFGENERIC is implicit has no protocol
entity to point at, and DES-0001 refuses to synthesise one because there
would be no source region to send an agent to."
  (let ((index (name-lookup view '(:interface) :package-graph package-graph))
        (ops '()))
    (dolist (method (entities-of-type view :method))
      (let ((generic (unique-match index (or (getp method :generic-function)
                                             (name method)))))
        (when generic
          (push (assert-edge :implements method generic :workspace-id workspace-id) ops))))
    (nreverse ops)))

(defun resolve-definitions (view &key workspace-id external-packages)
  "Every structural edge the definition forms imply, as one batch.

The package graph is assembled once and shared: all three passes below resolve
a name against the same declarations, and building it three times would be
three walks of every :PACKAGE entity for one answer."
  (let ((pg (build-package-graph view :external-packages external-packages)))
    (append (resolve-inheritance view :workspace-id workspace-id :package-graph pg)
            (resolve-specializers view :workspace-id workspace-id :package-graph pg)
            (resolve-method-protocols view :workspace-id workspace-id :package-graph pg))))

;;;; ==================================================================
;;;; Generated definitions (DES-0002)
;;;; ==================================================================
;;;;
;;;; A name can be brought into existence by a form that does not spell it:
;;;; a DEFSTRUCT slot generates an accessor, a DEFCLASS slot generates a
;;;; generic function, and a call to a definer macro generates whatever its
;;;; template defines. DES-0001 indexed the first two and marked them with
;;;; :GENERATED-BY, but a property is not an edge and nothing traversed it --
;;;; measured on Loom's own index, `impact repository 2' reported one row
;;;; while `describe repository-graph', its own accessor, listed six callers.
;;;;
;;;; This pass closes both halves with one edge type. :USES already carries
;;;; impact in the right direction (:REVERSE -- from the thing that changed to
;;;; whatever relied on it), which is exactly generator to generated.

(defun structural-generated-uses (view &key workspace-id package-graph)
  "Operations linking each DEFSTRUCT or DEFCLASS generated name to its class.

DES-0002 R6, and it needs no analyzer change at all: DES-0001 was already
writing :GENERATED-BY on every accessor, constructor, predicate and copier.
Only the edge was missing.

A name matching zero or several classes is left alone, per CON-0001. That
matters more here than it looks: the same property is what the macro half of
this pass writes, naming a macro rather than a class, and a macro is a
:FUNCTION -- so looking the name up in an index of classes is also what keeps
the two halves from crossing."
  (let ((index (name-lookup view '(:class) :package-graph package-graph))
        (ops '()))
    (dolist (type '(:function :interface))
      (dolist (entity (entities-of-type view type))
        (let ((generator (getp entity :generated-by)))
          (when generator
            (let ((class (unique-match index generator entity)))
              (when (and class (not (eq class entity)))
                (push (assert-edge :uses entity class :workspace-id workspace-id)
                      ops)))))))
    (nreverse ops)))

;;;; ------------------------------------------------------------------
;;;; Definitions a macro call brings into existence (DES-0002 R5, R7)
;;;;
;;;; The registry arrives as an argument rather than being read from
;;;; LOOM-ANALYZER, and that is not a style choice. loom-graph.asd depends on
;;;; loom-ontology alone; RULE-0001 to RULE-0003 put the analyzers above the
;;;; graph and a reference to LOOM-ANALYZER:*MACRO-GENERATORS* here would
;;;; invert the layering as well as failing to compile. LOOM-WORKSPACE is the
;;;; first system that uses both packages, so it is the one that hands the
;;;; shipped half across. That it also makes this pass testable against a
;;;; synthetic registry is a second reason and not the first.
;;;; ------------------------------------------------------------------

(defparameter *generatable-types* '(:function :class :method :test)
  "Entity types a registry entry may declare, and so the types the retract
half has to sweep. Mirrors LOOM-ANALYZER's *TEMPLATE-DEFINER-HEADS* plus
:TEST, which only a shipped entry can name -- no template reads as one.")

(defun workspace-generator-entry (macro)
  "The registry entry a workspace macro contributes from its own template, or
NIL when the analyzer could not characterise it.

An in-tree macro and a shipped framework entry are deliberately the same kind
of thing here: REQ-0003 asks for one table and one pass over it, and nothing
downstream can tell which is which. The one difference is :MACRO, the entity
to point the :USES edge at -- a shipped entry names a macro defined outside
the tree, which has no entity to reach."
  (let ((type (getp macro :generator-entity-type)))
    (when type
      (list :name (string-downcase (name macro))
            :package nil
            :entity-type type
            :name-index (getp macro :generator-name-index)
            :body-index (getp macro :generator-body-index)
            :framework nil
            :macro macro))))

(defun effective-generator-registry (view registry)
  "Downcased macro name -> entries, the shipped REGISTRY plus every workspace
macro carrying its own :GENERATOR-ENTITY-TYPE.

A fresh table: REGISTRY belongs to whoever passed it and a pass that pushed
in-tree entries into it would accumulate a duplicate on every poll."
  (let ((index (make-hash-table :test #'equal)))
    (when registry
      (maphash (lambda (name entries) (setf (gethash name index) (copy-list entries)))
               registry))
    (dolist (macro (entities-of-type view :function))
      (let ((entry (workspace-generator-entry macro)))
        (when entry
          (push entry (gethash (getf entry :name) index)))))
    index))

(defun definer-site-name (site index)
  "The name a call site supplies at INDEX, or NIL when it supplied no name.

NIL is the answer for a computed name -- (test (make-name i) ...) -- and it is
why :SYMBOL-ARGUMENTS is consulted rather than the rendered string. Minting
from a form nobody has evaluated would produce a garbage-named entity that
resolves nothing and never goes away, which is CON-0001's fabricated fact in
its most durable form."
  (let ((arguments (getf site :arguments)))
    (when (and index (member index (getf site :symbol-arguments))
               (<= index (length arguments)))
      (nth (1- index) arguments))))

(defun normalize-route (route)
  "ROUTE with a leading and trailing `/' stripped, or NIL.

DES-0025 D1, and deliberately the whole of the normalization. game-server
writes \"/public/game/create\" and front-end writes \"public/game/create\";
that one character is the entire difference between the two trees, measured
rather than assumed. Inventing more -- case folding, collapsing a trailing
segment, treating a parameter as a wildcard -- is how a matcher starts
producing joins nobody wrote."
  (let ((trimmed (and (stringp route) (string-trim "/" route))))
    (when (and trimmed (plusp (length trimmed))) trimmed)))

(defun definer-site-literal (site index)
  "The string literal a call site supplied at INDEX, or NIL.

:STRING-ARGUMENTS' counterpart to DEFINER-SITE-NAME above, and NIL for the
same class of reason: a site that computed its route rather than spelling it
supplies nothing here, and a route built at runtime is not a claim this pass
can honestly record."
  (when index
    (cdr (assoc index (getf site :string-arguments)))))

(defun generated-natural-key (type file name)
  "The natural key a generated entity of TYPE at FILE named NAME will carry.

Read off the declared key rather than assumed to be (:FILE :NAME), so a type
with more parts -- :METHOD's qualifier and specializers -- is looked up under
the key the entity itself will derive rather than under a shorter one that
would never match."
  (let ((spec (find-entity-type type)))
    (when (and spec (entity-type-natural-key spec))
      (cons type (loop for key in (entity-type-natural-key spec)
                       collect (case key
                                 (:name name)
                                 (:file file)
                                 (t nil)))))))

(defun generated-definition-plan (view index)
  "What this pass should produce, and what it had to refuse: two values, a
list of plan plists and a list of (file . name) collisions.

A separate function from the one that emits operations because the collisions
have to be countable without applying anything -- DES-0002 requires a
collision to be counted rather than merely not crashing, and R1 forbids
recording it by writing :DEFINER-STATUS onto the macro, which is a property
the analyzer owns."
  (let ((plans '())
        (collisions '()))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        (let ((entries (gethash (string-downcase (getf site :operator)) index)))
          ;; Zero or several entries: left alone, per CON-0001. Several is a
          ;; real possibility rather than a theoretical one -- two packages may
          ;; name a macro identically, which is why the table holds a list --
          ;; and picking one would be the fabricated fact this codebase refuses.
          (when (and entries (null (rest entries))
                     ;; DEF-SUITE's entry declares no type: it exists so the
                     ;; call is recognised as accounted for, not so it mints.
                     (getf (first entries) :entity-type))
            (let* ((entry (first entries))
                   (type (getf entry :entity-type))
                   (path (getp file :path))
                   (name (definer-site-name site (getf entry :name-index))))
              (cond
                ((null name)
                 (push (cons path (getf site :operator)) collisions))
                (t
                 (let ((existing (find-entity-by-key
                                  view (generated-natural-key type path name))))
                   (if (and existing (null (getp existing :generated-by))
                            ;; ...unless the image put it there. An
                            ;; :INTROSPECTED entity is this same definition seen
                            ;; from the other side -- the compiler reporting
                            ;; what the macro call expanded into -- so reading
                            ;; it as a hand-written claim would make the first
                            ;; enrich the last one that could mint: the key
                            ;; would stay occupied, every later pass would
                            ;; report a collision, and the :USES edge back to
                            ;; the generator would never be drawn. Minting over
                            ;; it is the upsert the two passes are supposed to
                            ;; meet in (DES-0011 R6).
                            (not (eq :introspected (source existing))))
                       ;; A hand-written definition already claims this natural
                       ;; key. Left alone and counted: a macro call that happens
                       ;; to name something a real DEFUN already defines must
                       ;; not clobber it, and an overwrite nobody counted is
                       ;; indistinguishable from nothing having happened.
                       (push (cons path name) collisions)
                       (push (list :type type :file file :site site
                                   :entry entry :name name)
                             plans))))))))))
    (values (nreverse plans) (nreverse collisions))))

(defun declared-properties-only (type plist)
  "PLIST reduced to the properties TYPE declares.

VALIDATE-ENTITY iterates declared properties, so an undeclared one is stored,
never validated, and absent from the schema the ontology exists to be the
single copy of. Filtering here rather than assembling per type keeps the one
list of what a generated entity knows in one place.

The cost is worth naming: :GENERATED-BY is declared on :FUNCTION, :INTERFACE
and :TEST but not on :CLASS or :METHOD, so a macro whose template is a
DEFCLASS or DEFMETHOD mints an entity the retract half below cannot see -- it
keys on exactly that property. No macro in this tree takes that shape and
DES-0002 named none, so it is a gap on the record rather than a defect being
worked around; closing it is two property declarations."
  (filter-plist plist (lambda (key) (find-property type key))))

(defun generated-entity (plan)
  "The entity a definer call site brings into existence.

:ORIGIN-FILE is the *calling* file, never the macro's. That is what makes
RETRACT-FILE clean the entity up when the call site is edited or deleted, and
it is half of what keeps an incrementally updated index identical to a rebuilt
one. The macro's file is reachable through the :USES edge, which is where it
belongs."
  (destructuring-bind (&key type file site entry name) plan
    (let ((path (getp file :path)))
      (make-instance (entity-type-class-name (find-entity-type type))
                     :name name
                     :origin-file path
                     :properties
                     (properties-table
                      (declared-properties-only
                       type
                       (list :file path
                             :start-line (getf site :start-line)
                             :end-line (getf site :end-line)
                             :generated-by (getf entry :name)
                             :call-names (getf site :call-names)
                             :framework (getf entry :framework)
                             ;; DES-0025 D1. Present only for a declared
                             ;; :ROUTE-INDEX, which is absent on every definer
                             ;; that defines no endpoint -- that is, on all of
                             ;; them but one so far.
                             :routes (let ((route (normalize-route
                                                   (definer-site-literal
                                                    site (getf entry :route-index)))))
                                       (when route (list route)))
                             :route-role (when (definer-site-literal
                                                site (getf entry :route-index))
                                           :publishes)
                             :language (getp file :language)
                             ;; DES-0009 R6, and the same shortcut :LANGUAGE
                             ;; takes one line up, for the same reason: a
                             ;; macro-minted entity has no form of its own to
                             ;; read a package from, so it takes its file's.
                             :system (getp file :system))))))))

(defun known-generator-names (view registry)
  "Downcased names this pass owns the lifecycle of: every shipped REGISTRY
key, plus the name of every workspace macro currently marked :MACRO-P,
whether or not it presently qualifies as a definer.

Deliberately broader than EFFECTIVE-GENERATOR-REGISTRY, which names only
generators that qualify *right now* -- and :GENERATOR-ENTITY-TYPE is exactly
the property a macro loses the moment its template is edited into a wrapper.
Sweeping against EFFECTIVE-GENERATOR-REGISTRY would make the predicate below
answer NIL for a macro that just stopped qualifying, which is
indistinguishable from a name that was never a macro at all -- the entity it
minted would then never be retracted, and the incremental index would drift
from a rebuilt one for as long as the call site's own file happened not to
change. :MACRO-P persists across that edit because it is set independently
of the generator inspection, so it is what this function reads instead."
  (let ((names (make-hash-table :test #'equal)))
    (when registry
      (maphash (lambda (name entries)
                 (declare (ignore entries))
                 (setf (gethash name names) t))
               registry))
    (dolist (macro (entities-of-type view :function))
      (when (getp macro :macro-p)
        (setf (gethash (string-downcase (name macro)) names) t)))
    names))

(defun generated-entity-retractions (view known-generators produced workspace-id)
  "Retract every entity a registered macro minted that this pass did not
produce again.

This pass owns a lifecycle no earlier resolution pass has had to carry. The
others only assert edges or update properties, and a stale edge is cleaned up
for free when RETRACT-FILE clears its origin file and the next analysis does
not reassert it. A generated entity has no single file whose reanalysis is
guaranteed to invalidate it: a macro can stop qualifying as a definer in its
own file while the call site's file never changes, so nothing retracts what
the call site still asks for and the macro no longer delivers. Recomputing the
full set every pass and taking back the difference is what keeps this a
derivation rather than an accumulation, per DEC-0003, despite creating
entities.

Two ways to get the predicate wrong, both silent.

Keyed on KNOWN-GENERATOR-NAMES, not on the presence of :GENERATED-BY. A
DEFSTRUCT accessor carries that property too -- naming a class rather than a
macro -- so a predicate reading the property alone would retract every
accessor in the tree on the first pass and re-mint none of them. The symptom
would be a large drop in entity count and a flood of newly unresolved calls.
KNOWN-GENERATOR-NAMES, not EFFECTIVE-GENERATOR-REGISTRY, for the reason given
on that function: the latter drops a macro from its index the moment the
macro stops qualifying, which is the one case this predicate exists to catch.

Keyed on absence from PRODUCED, not on anything about the entity. An entity
this pass did produce is a refresh, and a refresh is an upsert by natural key
-- a bare ASSERT-ENTITY. Emitting a retract and an assert for one key in one
transaction would risk the retract removing what the assert had just landed,
depending on the order the operations happen to be applied in."
  (let ((ops '()))
    (dolist (type *generatable-types*)
      (dolist (entity (entities-of-type view type))
        (let ((generator (getp entity :generated-by)))
          (when (and generator
                     (gethash (string-downcase generator) known-generators)
                     (not (gethash (id entity) produced)))
            (push (retract (id entity) workspace-id) ops)))))
    (nreverse ops)))

(defun call-site-retractions (view kind produced workspace-id)
  "Retract every :CALL-SITE of KIND this pass did not produce again.

DES-0014 R6 says RETRACT-FILE needs nothing, and that is true of exactly one
of the three kinds. An initform site is derived from one file, so editing that
file removes it and the next analysis re-derives it. The graph's two are not:
an ambiguous site's origin file is the *caller's*, so deleting one of two
colliding definitions from a third file leaves the site behind with a live edge
to the survivor while the caller also acquires its own direct edge -- one call
reported twice, at two different confidences. A definer site's is the calling
file, so a macro that becomes characterised in its own file leaves the call
sites its calls used to orphan, beside the definition that now carries the same
names.

Both traps GENERATED-ENTITY-RETRACTIONS records apply here unchanged. The
retracts go last in the batch and name only entities no assert in it touches,
which is what keying on absence from PRODUCED buys: a site this pass did
produce is a refresh, and a refresh is an upsert by natural key, so emitting a
retract and an assert for one key in one transaction would risk the retract
removing what the assert had just landed.

KIND is the third condition and it is not a convenience. Each pass owns exactly
one referrer kind, and a sweep keyed on absence alone would retract every one
of the analyzer's sites on its first run and re-mint none of them -- the same
shape of silent, total loss that reading :GENERATED-BY alone would have had."
  (let ((ops '()))
    (dolist (site (entities-of-type view :call-site))
      (when (and (eq kind (getp site :referrer-kind))
                 (not (gethash (id site) produced)))
        (push (retract (id site) workspace-id) ops)))
    (nreverse ops)))

(defun definer-call-site-entities (view index minted)
  "One :CALL-SITE per resolving call name on a definer call site that minted no
definition, as a list of (file . entity) pairs.

BUG-0016's second half. A macro whose expansion is a runtime table entry --
DEFINE-OPERATION, DEFINE-COMMAND -- swallows a real body, and the names in it
reach no entity at all: there is no definition to source a :CALLS edge at, so
every REST route and every MCP tool is invisible in the call graph. The call
site is the node DES-0014 mints to be that source.

MINTED is the set of site plists GENERATED-DEFINITION-PLAN produced an entity
from, keyed by identity, which is why no second predicate is written: the plan
already carries the site in its :SITE key, so the two populations cannot
disagree about which sites minted. That disjointness is also what keeps the two
kinds of key apart -- a generated definition's start line is its site's start
line, so DES-0014's uniqueness argument (\"a definer call site cannot begin on
a definition's line\") holds only because a site that mints one never mints the
other.

Only where CALL-TARGETS returns something, which is PLAN-0014 decision 2 rather
than R4's literal text. Measured on this tree, R4 read literally is 266 nodes
of which 142 name something that is not in the workspace at all -- against
DES-0014's own R9 (\"expected order 100\") and against its own census
reasoning, that a node per absent callee is a node per thing that is not there.
A name that resolves to nothing carries no edge, and the fact that it went
nowhere already lives on the site's :CALL-NAMES and in `check''s definer-macro
report. The asymmetry with the analyzer's initform sites, which mint all 20, is
deliberate: the analyzer holds no callable index and cannot ask this question."
  (let ((pairs '()))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        (unless (gethash site minted)
          (dolist (name (getf site :call-names))
            (when (call-targets index name nil)
              (push (cons file
                          (make-call-site-entity
                           :file (getp file :path)
                           :start-line (getf site :start-line)
                           :end-line (getf site :end-line)
                           :call-name name
                           :referrer-kind :definer-call
                           :generated-by (getf site :operator)
                           ;; The file's, not re-decided: a call site read out
                           ;; of a macro call has no form of its own to take a
                           ;; package from, the same shortcut GENERATED-ENTITY
                           ;; takes one function up (DES-0009 R6).
                           :language (getp file :language)
                           :system (getp file :system)))
                    pairs))))))
    (nreverse pairs)))

(defun resolve-generated-definitions (view &key workspace-id registry external-packages)
  "Operations for every definition a generator brought into existence.

Both halves of DES-0002's R4: the edge from a DEFSTRUCT or DEFCLASS generated
name to its class, which needed no analyzer change because DES-0001 was
already writing the property; and the entities a definer macro's call sites
define, which exist nowhere in the source as a DEFUN and so have to be minted.

This is the first resolution pass to create entities, so it is also the first
to owe a retract. The order the operations come back in matters: the asserts
precede the edges that name them, because the Graph Manager resolves an edge's
endpoints against the asserts already planned in the same transaction, and the
retracts come last, naming only entities no assert in this batch touches."
  (let* ((index (effective-generator-registry view registry))
         (produced (make-hash-table :test #'equal))
         ;; The sites that minted, keyed by identity, so the call-site half
         ;; below can tell an orphaned site from an accounted-for one without
         ;; re-deciding it.
         (minted (make-hash-table :test #'eq))
         ;; The call sites this pass produced, for the sweep below. Kept apart
         ;; from PRODUCED, which GENERATED-ENTITY-RETRACTIONS reads against a
         ;; different type list and a different predicate.
         (produced-sites (make-hash-table :test #'equal))
         (asserts '())
         (edges '()))
    (dolist (plan (generated-definition-plan view index))
      (let ((entity (generated-entity plan))
            (macro (getf (getf plan :entry) :macro)))
        (setf (gethash (id entity) produced) t)
        (setf (gethash (getf plan :site) minted) t)
        (push (assert-entity entity workspace-id) asserts)
        ;; No edge when the macro lives outside the tree -- fiveam's TEST is
        ;; the common case -- because there is no entity to point at. The
        ;; :GENERATED-BY property still records what made it.
        (when macro
          (push (assert-edge :uses entity macro :workspace-id workspace-id) edges))))
    ;; BUG-0016's second half. CALLABLE-INDEX of this same view is stable
    ;; between here and RESOLVE-CALLS, because neither pass mints a :FUNCTION,
    ;; :METHOD or :INTERFACE -- so a name that resolves here resolves there too,
    ;; and a call site is never minted for an edge that will not be drawn.
    (let ((callables (callable-index view)))
      (dolist (pair (definer-call-site-entities view callables minted))
        (destructuring-bind (file . site) pair
          (setf (gethash (id site) produced-sites) t)
          (push (assert-entity site workspace-id) asserts)
          (push (assert-edge :contains file site :workspace-id workspace-id) edges))))
    (append (structural-generated-uses
             view :workspace-id workspace-id
             :package-graph (build-package-graph
                             view :external-packages external-packages))
            (nreverse asserts)
            (nreverse edges)
            (generated-entity-retractions
             view (known-generator-names view registry) produced workspace-id)
            (call-site-retractions view :definer-call produced-sites workspace-id))))

(defun generated-definition-collisions (view registry)
  "Every definer call site this pass refused, as (file . name).

Recounted by reading the view rather than recorded while the pass ran, for the
reason DES-0002 R1 gives: the obvious place to put the fact -- :DEFINER-STATUS
on the macro's entity -- is a property the analyzer owns and resolution must
not overwrite. Same shape as UNRESOLVED-REFERENCES, and REPOSITORY-STATUS
folds it in the same way."
  (nth-value 1 (generated-definition-plan
                view (effective-generator-registry view registry))))

(defun body-swallowing-macro-names (view)
  "Downcased names of macros whose calls stand as top-level forms carrying call
names of their own.

The discriminator BUG-0016 identified and left unused. A macro whose template
contains no DEFUN, DEFCLASS or DEFMETHOD claims to define nothing, and
MACRO-GENERATOR-PROPERTIES deliberately records nothing for it -- its docstring
is right that flagging every wrapper would put every WITH-LOCK in the tree into
a count that exists to be read and acted on. But a WITH-LOCK is never a
top-level form, and DEFINE-OPERATION is nothing but: its calls appear in
:DEFINER-CALL-SITES with non-empty :CALL-NAMES, which is the signature of a
macro swallowing real bodies whose calls then reach no entity at all.

Read from the whole workspace rather than from one file, because that is where
the fact lives and it is the reason this is not the analyzer's job.
DEFINE-OPERATION is defined in src/serve/registry.lisp and called in three
other files, so no file-scoped analyzer can see both halves (RULE-0002). Of
BUG-0016's two FIX options for counting, this is why the second -- decide it
where the whole tree is visible -- is the one taken.

Returns a table of name -> how many distinct call names its sites orphan,
because the count is what makes the report readable and the bare predicate does
not separate two populations that look alike from here. Measured on this tree:
DEFINE-OPERATION 42 and DEFINE-COMMAND 70, both of them real calls into
loom-knowledge, against DEFRELATIONSHIP's 12 -- which are `decision',
`document', `file' and the like, the heads of the keyword lists in its :FROM
and :TO arguments rather than calls to anything. That is COLLECT-CALL-NAMES'
own imprecision showing through: it reads the head of any non-quoted list as an
operator, and a keyword is a symbol. Both populations are honest members of
this count -- a macro whose declarations the ontology cannot model really is a
gap -- but only the first is a dropped call, so the number travels with the
name rather than being folded away."
  (let ((names (make-hash-table :test #'equal)))
    (dolist (file (entities-of-type view :file))
      (dolist (site (getp file :definer-call-sites))
        ;; :OPERATOR is already TOKEN-NAME's downcased rendering, so it is
        ;; comparable with (STRING-DOWNCASE (NAME macro)) without further folding.
        (let ((call-names (getf site :call-names)))
          (when call-names
            (setf (gethash (getf site :operator) names)
                  (union call-names (gethash (getf site :operator) names)
                         :test #'string=))))))
    (let ((counts (make-hash-table :test #'equal)))
      (maphash (lambda (operator call-names)
                 (setf (gethash operator counts) (length call-names)))
               names)
      counts)))

(defun unhandled-definer-macros (view)
  "Every macro whose expansion Loom could not read, in either of the two ways
that can happen.

DES-0002 R6: a macro that looks like a definer and cannot be read statically
is reported, not guessed at. Counted alongside the collisions, because both
are the same thing from a reader's point of view -- a definition the index
knows it is missing.

Two populations, summed into one list because a reader wants one answer to
\"what is the index missing\":

  :DEFINER-STATUS :UNHANDLED   the template defines something and the name is
                               computed -- INTERN or FORMAT -- so it cannot be
                               read without running the code that builds it.
  a body-swallowing macro      the template defines nothing this ontology
                               models, and yet the macro's call sites carry
                               call names, which therefore attach to nothing.

The second population is BUG-0016, and adding it is what stops `status'
reporting one gap on a tree that has two kinds. Before this, DEFINE-OPERATION's
15 call sites orphaned 42 distinct names -- every REST route and every MCP tool
invisible in the call graph -- and the tool whose job is to report gaps
reported this one as no gap. Silence that reads as success is the failure
CON-0001 exists to prevent, and it is worse here than a wrong number would be.

Reporting is all this does. What a DEFINE-OPERATION call should actually mint
is an ontology question BUG-0016 declined to settle inside a bug fix and
DES-0014 answers separately."
  (let ((swallowing (body-swallowing-macro-names view)))
    (remove-if-not
     (lambda (entity)
       (or (eq :unhandled (getp entity :definer-status))
           (and (getp entity :macro-p)
                (null (getp entity :generator-entity-type))
                (null (getp entity :definer-status))
                (gethash (string-downcase (name entity)) swallowing))))
     (entities-of-type view :function))))

(defun python-caller-p (caller)
  (and caller (eq :python (getp caller :language))))

(defun python-caller-candidates (candidates caller)
  "CANDIDATES CALLER can reach, with the Python line drawn in both directions.

CPython code does not call Lisp or JavaScript in process, and neither calls into
CPython, so a same-named definition across that line is a candidate the source
cannot have meant. DES-0053 D6, and BUG-0070 for the half that was missing: a
Lisp or JavaScript name that fell back to its spelling used to reach a Python
definition at confidence 1.0.

A Python caller also keeps only the plain functions of its own file. A bare
name no import binds cannot reach another file (the imported-calls tier is how
one does), and `d[k].get(x)' is written as the bare name `get', so VISIBLE-
CANDIDATES' never-empty fallback used to hand it every `get' in the tree. A
method is kept from any file: that is the member-call tiers' union of genuine
possibilities, and nothing else produces one for a Python caller.

A NIL caller keeps the set it had, because it asks only whether a name reaches
anything (RESOLVE-GENERATED-DEFINITIONS)."
  (flet ((python-p (e) (eq :python (getp e :language))))
    (cond ((null caller) candidates)
          ((python-caller-p caller)
           (let ((file (getp caller :file)))
             (remove-if-not (lambda (e)
                              (and (python-p e)
                                   (or (eq :method (entity-type e))
                                       (equal file (getp e :file)))))
                            candidates)))
          (t (remove-if #'python-p candidates)))))

(defun call-targets (index name caller)
  "What a call to NAME from CALLER links to: a list of edge plists, each
naming a :CALLEE and, when the link is a guess rather than a fact, the
:CONFIDENCE and :DERIVED-FROM that say so. NIL leaves the name unresolved.

The precedence is DES-0001's, and the order of the clauses is the design:

  one plain function     one structural edge. Nothing is being guessed: the
                         name has exactly one definition and the call reaches
                         it.
  any methods, or two
  or more accessor-
  generated interfaces   one :inferred edge per dispatch target. Dispatch is a
                         union of genuine possibilities, not an ambiguity among
                         mutually exclusive candidates, which is why fanning
                         out is not the fabricated edge CON-0001 forbids.

                         An accessor-generated :INTERFACE is a dispatch target
                         and not a rival protocol (REQ-0020). `:accessor id\' on
                         six classes is one generic function acquiring six
                         methods, and Loom mints an :INTERFACE for each because
                         no DEFGENERIC was written -- so a name with N of them
                         and no methods used to match no clause at all and
                         resolve to nothing. That was BUG-0021 on game-server:
                         144 dropped call sites for `id\'.

                         Only when the candidate set was package-placed. Fanning
                         out across a set assembled by spelling alone would
                         assert edges between accessors of genuinely different
                         generics -- the fabrication BUG-0021 warned the cheap
                         fix would cause -- so an unplaced set keeps the old
                         answer.
  one interface, no
  methods                one structural edge to the protocol. A generated slot
                         accessor, or a generic implemented outside the tree:
                         there is nothing to fan out to, and refusing would
                         make the commonest accessor in a CLOS codebase
                         uncallable.
  two or more plain
  functions              one edge per candidate at 1/N, sourced at a
                         :CALL-SITE the caller contains rather than at the
                         caller (REQ-0015, DES-0014).
  anything else          unresolved, and recorded as such.

A target may carry :CALL-SITE, the entity the edge runs from instead of CALLER.
RESOLVE-CALLS is what asserts it, because only the caller of this function is
in a transaction.

CALLER may be NIL, which asks the bare question \"does this name reach
anything\" without a caller to remove from the candidates or to hang a node on.
RESOLVE-GENERATED-DEFINITIONS asks it that way, so it can decide whether an
orphaned definer name is worth a call site at all."
  (multiple-value-bind (all placedp) (candidate-entities index name caller)
   (let* ((candidates (python-caller-candidates (remove caller all) caller))
         (functions  (remove-if-not (lambda (e) (eq :function  (entity-type e))) candidates))
         (methods    (remove-if-not (lambda (e) (eq :method    (entity-type e))) candidates))
         (interfaces (remove-if-not (lambda (e) (eq :interface (entity-type e))) candidates))
         ;; An :INTERFACE carrying :GENERATED-BY was synthesised from a slot
         ;; declaration -- `:accessor id\' -- rather than written as a
         ;; DEFGENERIC. It is one method of a generic function, not a protocol
         ;; of its own, and the analyzer already records which is which.
         (accessors  (remove-if-not (lambda (e) (getp e :generated-by)) interfaces))
         (protocols  (remove-if     (lambda (e) (getp e :generated-by)) interfaces))
         ;; Fan out over accessors only where the candidate set is one
         ;; symbol\'s. REQ-0020 R5 and BUG-0021\'s ordering argument.
         (dispatch   (append methods (if placedp accessors '()))))
    (cond ((and (= 1 (length functions)) (null methods) (null interfaces))
           (list (list :callee (first functions))))
          ((or methods (rest dispatch))
           (let ((confidence (dispatch-confidence (length dispatch)))
                 (generic (when (= 1 (length protocols)) (id (first protocols)))))
             (loop for target in dispatch
                   collect (list :callee target
                                 :confidence confidence
                                 :derived-from (when generic (list generic))))))
          ((= 1 (length interfaces))
           (list (list :callee (first interfaces))))
          ;; REQ-0015. The clauses above have already excluded every case with
          ;; a method or with exactly one interface, so two or more plain
          ;; functions is all that is left to test -- which is also exactly
          ;; CLASSIFY-CALL's :AMBIGUOUS clause in tools/test/call-site-census.lisp,
          ;; and the two have to keep agreeing for the census to measure this
          ;; pass rather than something adjacent to it.
          ;;
          ;; DISPATCH-CONFIDENCE, the same 1/N the method fan-out uses, but the
          ;; edges do not mean the same thing and the node is the difference.
          ;; Dispatch is a union of genuine possibilities, so it runs from the
          ;; caller; ambiguity is one call the resolver could not place, and
          ;; running N edges from the caller is what CALL-TARGETS' docstring has
          ;; always refused -- every caller of a common name looking coupled to
          ;; code it never touches. One hop away and labelled, it is a report of
          ;; a guess rather than a fabricated fact (CON-0001).
          ((>= (length functions) 2)
           (let ((confidence (dispatch-confidence (length functions)))
                 ;; Decision 6: a call site is already an anchor for an
                 ;; ambiguity, so it fans out directly. Minting a second node
                 ;; from the first one's file and line would recur on every
                 ;; pass. A NIL caller has nothing to build a node from and is
                 ;; only asking whether the name reaches anything, so it takes
                 ;; the same branch.
                 (directp (or (null caller)
                              (eq :call-site (entity-type caller)))))
             (let ((site (unless directp
                           (make-call-site-entity
                            :file (getp caller :file)
                            :start-line (getp caller :start-line)
                            :end-line (getp caller :end-line)
                            :call-name name
                            :referrer-kind :ambiguous
                            :candidate-count (length functions)
                            :language (getp caller :language)
                            :system (getp caller :system)))))
               (loop for candidate in functions
                     collect (list :callee candidate
                                   :confidence confidence
                                   :call-site site)))))
          (t nil)))))

(defparameter *minimum-dispatch-confidence* 0.1
  "The floor for a fanned-out call edge, so a generic with a great many
methods still produces edges a consumer can find rather than ones rounding to
nothing.")

(defun dispatch-confidence (method-count)
  "How much to believe one edge of a fan-out across METHOD-COUNT methods.

1/n, which is worth more than it looks: 70% of the generics in the repository
that motivated DES-0001 have exactly one method, and a call to a generic with
one method reaches it with certainty. The number falls away exactly as the
real uncertainty rises, so a consumer filtering on confidence keeps the calls
it can rely on and drops the sixteen-way guesses."
  (if (<= method-count 1)
      1.0
      (max *minimum-dispatch-confidence* (/ 1.0 method-count))))

(defun caller-call-names (caller)
  "The call names CALLER records, whatever kind of caller it is.

A :CALL-SITE is one call, so its names are the one-element list holding its
:CALL-NAME. Every other caller carries the list the analyzer wrote on it.

Deriving rather than reading a stored :CALL-NAMES is what keeps the referenced
name in exactly one place on a call site: :CALL-NAME is a natural-key
component, so a stored copy that drifted from it would leave the entity
resolving one name while keying on another, and nothing downstream could tell.
DES-0014, PLAN-0014 step 4."
  (if (eq :call-site (entity-type caller))
      ;; A site bound to an import carries its binding in :IMPORTED-CALLS and
      ;; its :CALL-NAME is only the dotted spelling kept for the key and the
      ;; label. Resolved here as a bare name it would re-enter
      ;; VISIBLE-CANDIDATES' never-empty fallback, so the name is resolved once,
      ;; through the binding (DES-0053 D4).
      (let ((name (getp caller :call-name)))
        (when (and name (null (getp caller :imported-calls)))
          (list name)))
      (getp caller :call-names)))

;;;; ==================================================================
;;;; Imported calls (DES-0053 D6)
;;;; ==================================================================
;;;;
;;;; A Python call bound to an import is written by the analyzer as a specifier
;;;; and an attribute path, never as a bare name: a bare name re-enters
;;;; VISIBLE-CANDIDATES' never-empty fallback, and on lfia that put three wrong
;;;; fan-outs on `build' alone. This tier resolves the specifier to a file (D5)
;;;; and walks the path the way Python looks an attribute up on a module. It
;;;; chooses between no candidates: at each step a file holds at most one
;;;; binding of a name (CON-0005), so a hit is one edge at full confidence and a
;;;; miss is a recorded cause.

(defparameter *imported-call-walk-limit* 16
  "Steps one imported call may take through re-exports before it is a miss.")

(defstruct (walk-context (:constructor make-walk-context
                             (index definitions files domains)))
  "What an imported-call walk reads, built once per pass: the PYTHON-INDEX, the
Python definitions keyed on (file . name), the :FILE entities by path, and the
domain table."
  index definitions files domains)

(defun build-walk-context (view domains)
  (let ((known (make-hash-table :test #'equal))
        (files (make-hash-table :test #'equal))
        (definitions (make-hash-table :test #'equal)))
    (dolist (file (entities-of-type view :file))
      (let ((path (getp file :path)))
        (when path
          (setf (gethash path known) t
                (gethash path files) file))))
    (dolist (type '(:function :method :class :variable))
      (dolist (entity (entities-of-type view type))
        (when (and (eq :python (getp entity :language)) (slot-boundp entity 'name))
          (setf (gethash (cons (getp entity :file) (name entity)) definitions) entity))))
    (make-walk-context (make-python-index known) definitions files domains)))

(defun walk-resolve-specifier (context specifier importer)
  "(values file cause) for SPECIFIER written in the file IMPORTER, under that
file's own domain."
  (let* ((file (gethash importer (walk-context-files context)))
         (name (and file (getp file :domain)))
         (domains (walk-context-domains context)))
    (resolve-python-specifier specifier importer (walk-context-index context)
                              :domain (and domains name (gethash name domains)))))

(defun specifier-miss-cause (cause)
  "The :UNRESOLVED-IMPORTED-CALLS cause for a specifier that named no file.

:UNRESOLVED -- a relative name, or a held package missing the module -- is
:MISSING-IN-TARGET. It is rot of the kind `check' reports: a module a call still
names and the tree no longer holds."
  (if (eq cause :unresolved) :missing-in-target cause))

(defun import-binding-of (context file name)
  "FILE's module-level import binding of NAME, as its :IMPORT-BINDINGS plist."
  (let ((entity (gethash file (walk-context-files context))))
    (and entity
         (find name (getp entity :import-bindings)
               :key (lambda (binding) (getf binding :local)) :test #'equal))))

(defun package-submodule (context file name)
  "The file of the submodule NAME of the package whose __init__.py is FILE."
  (let ((directory (directory-prefix file)))
    (when (string= file (concatenate 'string directory "__init__.py"))
      (python-module-file (walk-context-index context) directory (list name)))))

(defvar *walk-nesting* 0
  "How many walks are open inside another: a base class followed, or a star
import entered. Bounded by *IMPORTED-CALL-WALK-LIMIT*, because two classes that
name each other as bases and two modules that star-import each other are both
legal text that a walk must not follow forever.")

(defun nested-walk (context file names)
  "(values callee cause) for NAMES walked from FILE inside the walk now open.

Past the limit the answer is :INHERITED, not :MISSING-IN-TARGET: a walk that
stopped because it was told to has not shown the name is absent."
  (if (>= *walk-nesting* *imported-call-walk-limit*)
      (values nil :inherited)
      (let ((*walk-nesting* (1+ *walk-nesting*)))
        (walk-attribute-path context file names))))

(defun inherited-method (context class name)
  "(values callee cause) for the method NAME that CLASS does not define itself.

Python looks it up on the bases, so each base is walked from the class's own
file in the order written, which is the order of the method resolution for the
shapes this follows. A class with no base but `object' really lacks it:
:MISSING-IN-TARGET, the one claim `check' reports. Otherwise the answer is
:INHERITED unless a base yields the method, because a base the tree does not
hold (pydantic's BaseModel, an exception) may define anything, and BUG-0071 is
what reporting that as rot cost. A base is read by the name :SUPERCLASS-NAMES
holds, which is the name as written except that an import alias is undone; an
aliased base therefore fails to resolve and ends as :INHERITED, never as a
wrong edge."
  (let ((bases (remove "object" (getp class :superclass-names) :test #'equal)))
    (if (null bases)
        (values nil :missing-in-target)
        (dolist (base bases (values nil :inherited))
          (multiple-value-bind (callee cause)
              (nested-walk context (getp class :file) (list base name))
            (declare (ignore cause))
            (when callee (return (values callee nil))))))))

(defvar *walk-lands-on-variables* nil
  "True while RESOLVE-SETTINGS walks to a :VARIABLE rather than to something a
call could reach. DES-0054 D5. A special and not an argument because the walk
recurses through four functions, none of which has any other reason to know.")

(defun landing (context definition rest)
  "(values callee cause) for a walk that reached DEFINITION with REST left.

A function or method ends the walk. A class goes to its __init__, which is what
calling it runs, or to the method REST names, or to a base class that defines
it. A :VARIABLE is not callable."
  (let ((file (getp definition :file))
        (definitions (walk-context-definitions context)))
    (case (entity-type definition)
      ((:function :method)
       (if rest (values nil :not-callable) (values definition nil)))
      (:class
       (cond ((null rest)
              (let ((init (gethash (cons file (format nil "~a.__init__" (name definition)))
                                   definitions)))
                (if init (values init nil) (values nil :not-callable))))
             ((null (rest rest))
              (let ((method (gethash (cons file (format nil "~a.~a" (name definition)
                                                        (first rest)))
                                     definitions)))
                (if method
                    (values method nil)
                    (inherited-method context definition (first rest)))))
             (t (values nil :not-callable))))
      (:variable
       ;; Only RESOLVE-SETTINGS asks for this, to find the declaring variable a
       ;; registration argument names. A call to a variable stays not callable.
       (if (and *walk-lands-on-variables* (null rest))
           (values definition nil)
           (values nil :not-callable)))
      (t (values nil :not-callable)))))

(defun star-specifiers (context file)
  "The specifiers of FILE's module-level `from S import *', last written first.
Python binds in statement order, so a later star wins a name two of them hold."
  (let ((entity (gethash file (walk-context-files context))))
    (and entity
         (reverse (loop for binding in (getp entity :import-bindings)
                        when (equal "*" (getf binding :name))
                          collect (getf binding :specifier))))))

(defun walk-stars (context file names)
  "(values callee cause) for NAMES looked up through FILE's star imports, after
FILE itself has no definition, binding or submodule of the first name.

Each star module is walked as FILE's own namespace. A hit is the edge. A miss in
every one of them, with every one read, is the :MISSING-IN-TARGET that is true.
A star module the tree does not hold, or a walk that ended for any other reason,
leaves the name unknowable, and that is :STAR-IMPORT, which `check' does not
report. A file with no star import has nothing to add, and the miss stands."
  (let ((unknowable nil))
    (dolist (specifier (star-specifiers context file)
                       (values nil (if unknowable :star-import :missing-in-target)))
      (let ((module (walk-resolve-specifier context specifier file)))
        (if (null module)
            (setf unknowable t)
            (multiple-value-bind (callee cause) (nested-walk context module names)
              (cond (callee (return (values callee nil)))
                    ((not (eq cause :missing-in-target)) (setf unknowable t)))))))))

(defun walk-attribute-path (context start names)
  "(values callee cause), walking NAMES from the module file START.

Per step, in D6's order: a definition of the name in the file; a module-level
import binding of it, which is the re-export through ledger/__init__.py; a
submodule of that name; a star import of the file, which may bind any name. None
of the first three is a miss. The walk refuses a cycle and stops at
*IMPORTED-CALL-WALK-LIMIT*, and both end as :MISSING-IN-TARGET."
  (let ((file start) (seen '()))
    (dotimes (step *imported-call-walk-limit* (values nil :missing-in-target))
      (declare (ignorable step))
      (when (null names)
        (return-from walk-attribute-path (values nil :not-callable)))
      (let ((key (cons file names)))
        (when (member key seen :test #'equal)
          (return-from walk-attribute-path (values nil :missing-in-target)))
        (push key seen))
      (let* ((name (first names))
             (rest (rest names))
             (definition (gethash (cons file name) (walk-context-definitions context)))
             (binding (and (null definition) (import-binding-of context file name))))
        (cond
          (definition
           (return-from walk-attribute-path (landing context definition rest)))
          (binding
           (let ((specifier (getf binding :specifier))
                 (imported (getf binding :name)))
             (multiple-value-bind (module cause)
                 (walk-resolve-specifier context specifier file)
               (cond
                 ((null module)
                  (return-from walk-attribute-path
                    (values nil (specifier-miss-cause cause))))
                 ((null imported) (setf file module names rest))
                 ((string/= module file)
                  ;; The next step finds the name as a definition, a binding or
                  ;; a submodule of MODULE, in that order.
                  (setf file module names (cons imported rest)))
                 (t
                  ;; `from . import dates' written in the package's own
                  ;; __init__.py names itself, and only the submodule is left.
                  (let ((sub (resolve-python-specifier
                              (python-submodule-specifier specifier imported) file
                              (walk-context-index context))))
                    (if sub
                        (setf file sub names rest)
                        (return-from walk-attribute-path
                          (values nil :missing-in-target)))))))))
          (t
           (let ((sub (package-submodule context file name)))
             (if sub
                 (setf file sub names rest)
                 (return-from walk-attribute-path
                   (walk-stars context file names))))))))))

(defun imported-call-target (context importer entry)
  "(values callee cause) for one :IMPORTED-CALLS ENTRY made in the file IMPORTER."
  (multiple-value-bind (file cause)
      (walk-resolve-specifier context (getf entry :specifier) importer)
    (if file
        (walk-attribute-path context file (getf entry :path))
        (values nil (specifier-miss-cause cause)))))

(defun missing-imported-calls (view)
  "Every :IMPORTED-CALLS entry whose module was found and which holds no such
name, as plists naming the caller, its file and line, and what was written.

`check' reports these and no other cause (DES-0053 D6). :EXTERNAL and :UNROOTED
are counted gaps, a library or a missing domain declaration. This one is a call
that names a function the tree no longer holds, which is the rot REQ-0078 R2
asks for."
  (let ((found '()))
    (dolist (type '(:function :method :test :call-site))
      (dolist (caller (entities-of-type view type))
        (dolist (miss (getp caller :unresolved-imported-calls))
          (when (eq :missing-in-target (getf miss :cause))
            (push (list :caller (name caller)
                        :file (getp caller :file)
                        :line (getf miss :line)
                        :specifier (getf miss :specifier)
                        :path (getf miss :path))
                  found)))))
    (nreverse found)))

(defun resolve-calls (view &key workspace-id external-packages module-scope domains)
  "Operations linking each recorded call name to the definition it names.

For every callable carrying :CALL-NAMES, each name is looked up in the
workspace:

  exactly one definition  -- assert a :CALLS edge to it
  several definitions     -- assert an ambiguous :CALL-SITE the caller
                             contains, and one edge from it to each candidate
                             at 1/N (REQ-0015). The caller still acquires no
                             direct edge, which is the false coupling this
                             clause has always refused; what changes is that
                             the refusal is now reportable rather than silent.
  none                    -- record it unresolved. It is a genuine external
                             dependency, and a standing record of one.

:UNRESOLVED-CALLS is rewritten from scratch each pass rather than whittled
down, and :CALL-NAMES is never touched. That distinction is what makes the
pipeline's ordering work rather than merely look right. Reanalyzing a file
retracts it first (SS5.4), which destroys the :CALLS edges pointing *into* it
from files that did not change. Those files are not reanalyzed, so the only
record that they call anything is whatever is already on their entities -- and
while this function consumed that record, resolution could not rebuild what the
retract had just destroyed. Deriving instead of consuming means every pass sees
the same question and can answer it again.

Idempotent: an edge that already exists upserts onto itself by natural key, and
a name that resolved last pass resolves to the same edge this pass. Safe to run
after every analysis pass."
  (let ((index (callable-lookup view :external-packages external-packages
                                     :module-scope module-scope))
        ;; The ambiguous call sites this pass produced, keyed by id: the
        ;; dedupe for the asserts below and the produced set for the sweep at
        ;; the end, which are the same question asked twice.
        (asserted (make-hash-table :test #'equal))
        ;; Built on the first :IMPORTED-CALLS, so a tree with none pays nothing.
        (walk nil)
        (ops '()))
    ;; :TEST alongside the two callables, per DES-0002 R8. No new logic: it
    ;; was always a permitted :CALLS source in the ontology and had simply
    ;; never been fed a :CALL-NAMES, because until a resolution pass minted
    ;; one there were no :TEST entities at all.
    ;;
    ;; :CALL-SITE is the fourth, and it is the same move for the same reason
    ;; (DES-0014). A call site is one more kind of caller, so the fan-out, the
    ;; confidence handling, the :UNRESOLVED-CALLS write and DEC-0003's rebuild
    ;; property all apply to it without a second copy of any of them. The only
    ;; thing that differs is where the names come from, which is
    ;; CALLER-CALL-NAMES' whole job.
    (dolist (type '(:function :method :test :call-site))
      (dolist (caller (entities-of-type view type))
        (let ((names (caller-call-names caller))
              (linked '())          ; edge plists, reversed
              (left '()))
          (dolist (name names)
            (let ((targets (call-targets index name caller)))
              (if targets
                  (dolist (target targets) (push target linked))
                  (push name left))))
          ;; A target may name the :CALL-SITE its edge runs from rather than the
          ;; caller, which is REQ-0015's fan-out. The site is asserted once and
          ;; its :CONTAINS edge from the caller with it, both before the :CALLS
          ;; edges naming it, because the Graph Manager resolves an edge's
          ;; endpoints against the asserts already planned in the same
          ;; transaction. Keyed on id rather than on identity: CALL-TARGETS
          ;; builds a fresh entity per name, and two names from one caller are
          ;; two sites while one name asked twice is one.
          (dolist (target (nreverse linked))
            (destructuring-bind (&key callee confidence derived-from call-site) target
              (when (and call-site (null (gethash (id call-site) asserted)))
                (setf (gethash (id call-site) asserted) t)
                (push (assert-entity call-site workspace-id) ops)
                (push (assert-edge :contains caller call-site
                                   :workspace-id workspace-id)
                      ops))
              (let ((source (or call-site caller)))
                (push (if confidence
                          (assert-edge :calls source callee
                                       :workspace-id workspace-id
                                       :source :inferred
                                       :confidence confidence
                                       :derived-from derived-from)
                          (assert-edge :calls source callee
                                       :workspace-id workspace-id))
                      ops))))
          ;; Unconditional where it used to be (WHEN LINKED ...): a caller
          ;; whose every name went external still has to have that written
          ;; down, and a caller whose callee has since been deleted has to
          ;; have :UNRESOLVED-CALLS grow back.
          (when names
            (push (update-properties (id caller)
                                     (list :unresolved-calls (nreverse left))
                                     workspace-id)
                  ops))
          ;; DES-0053 D6. Written unconditionally whenever the caller has
          ;; entries, as :UNRESOLVED-CALLS is, and for the same reason: a call
          ;; whose target was since renamed has to have that written down. Read
          ;; from :IMPORTED-CALLS and never rewritten (DEC-0003).
          (let ((entries (getp caller :imported-calls)))
            (when entries
              (unless walk (setf walk (build-walk-context view domains)))
              (let ((hit (make-hash-table :test #'equal))
                    (misses '()))
                (dolist (entry entries)
                  (multiple-value-bind (callee cause)
                      (imported-call-target walk (getp caller :file) entry)
                    (cond ((null callee)
                           (push (list :specifier (getf entry :specifier)
                                       :path (getf entry :path)
                                       :line (getf entry :line)
                                       :cause cause)
                                 misses))
                          ((null (gethash (id callee) hit))
                           (setf (gethash (id callee) hit) t)
                           (push (assert-edge :calls caller callee
                                              :workspace-id workspace-id)
                                 ops)))))
                (push (update-properties (id caller)
                                         (list :unresolved-imported-calls
                                               (nreverse misses))
                                         workspace-id)
                      ops)))))))
    ;; The sweep last, so it names only sites no assert above touched. An
    ;; :UPDATE-PROPERTIES for a site being retracted is emitted above and is
    ;; harmless: it lands on an entity that is still there when it is applied.
    (append (nreverse ops)
            (call-site-retractions view :ambiguous asserted workspace-id))))

(defparameter *tested-types* '(:function :method :interface)
  "What a :TESTS edge may be derived onto: exactly the things a :CALLS edge
can terminate at, since that is what this derivation reads.")

(defun resolve-tests (view &key workspace-id)
  "Operations linking each test to the units its body invokes.

DES-0002 R9: a :TESTS edge to every :FUNCTION, :METHOD or :INTERFACE the test
already has a :CALLS edge to. Derived from what the body actually calls, which
is the choice worth recording because the ontology's own documentation used to
describe a different one -- \"matched by import graph plus naming
convention\".

Naming conventions do not work for Lisp here. fiveam test names in this
codebase are prose: resolve-links-a-call-to-a-definition-in-another-file names
no function literally, so a naming heuristic would resolve almost nothing and
a looser one would fabricate. The import half describes a mechanism that does
not exist either -- the Lisp analyzer produces no :IMPORTS edges. What a test
calls is available now and safe by construction: a call that does not resolve
simply stays unresolved, exactly as anywhere else.

The same pass answers JavaScript, and the import half turns out to be a
narrowing rather than a derivation of its own (REQ-0053 R4). A vitest case
carries the calls its body and its hooks make, RESOLVE-CALLS has already
reduced each name to the definitions the file's imports make visible, and what
is left is the same question this asks of a fiveam test: did the body reach it.
143 of front-end's 144 test files have a case calling a name the file imports.

Reads the :CALLS edges rather than the :CALL-NAMES property, which is why this
has to run after RESOLVE-CALLS and not merely near it. That is a derivation
from a derivation, and still a derivation -- nothing here is consumed, so a
re-run after a retract rebuilds what the retract destroyed (DEC-0003).

A definition in a file that holds a test is not a tested unit (REQ-0053 R6).
The set of such files is read off the tests themselves, which is what makes it
work for both languages without either analyzer declaring anything: a file
holding a fiveam test is a test file, and so is one holding a vitest case.
Without it `tested-units\' counts the tests\' own scaffolding -- 192 of
front-end's 1,351 resolvable case calls reach a fixture defined in the test
file itself, `withServer\' and `coloredTileLoader\' among them. What it costs is
a tree that writes its cases in the same file as its code: vitest\'s
`import.meta.vitest\' block reports no tested unit for its own module."
  (let ((ops '())
        (tests (entities-of-type view :test)))
    (let ((test-files (make-hash-table :test #'equal)))
      (dolist (test tests)
        (let ((path (getp test :file)))
          (when path (setf (gethash path test-files) t))))
      (dolist (test tests)
        (dolist (edge (relationships-from view (id test) :rel-type :calls))
          (let ((target (get-entity view (to-id edge))))
            (when (and target
                       (member (entity-type target) *tested-types*)
                       (not (gethash (getp target :file) test-files)))
              (push (assert-edge :tests test target :workspace-id workspace-id)
                    ops))))))
    (nreverse ops)))

(defparameter *setting-reader-types* '(:function :method :test :variable :file)
  "What a :READS edge may start at: the same list the ontology declares.")

;;; ------------------------------------------------------------------
;;; Which registration a declaration names (DES-0054 D3)
;;; ------------------------------------------------------------------

(defun relative-specifier-p (specifier)
  "True for `.x', `..' and `./x': a specifier that names a place relative to the
file writing it, and so names no module a declaration could."
  (and (plusp (length specifier)) (char= #\. (char specifier 0))))

(defun registration-matches-callee-p (registration language module name)
  "True when REGISTRATION, a plist with :SPECIFIER and :PATH, is a call of NAME
in MODULE as LANGUAGE writes it.

Python joins the specifier and path with dots, since module paths are dotted and
the split point does not matter: `from firebase_functions import scheduler_fn'
and `import firebase_functions.scheduler_fn as s' both give
firebase_functions.scheduler_fn.on_schedule. JavaScript compares the specifier to
the module exactly, because a specifier is a path and is never re-split, and the
path joined with dots to the name. Any other language matches nothing: a
registration is matched on the module path its source binds and never on the
spelling of a decorator, so one language's rule cannot fire on another's."
  (let ((specifier (getf registration :specifier))
        (path (getf registration :path)))
    (and specifier
         (not (relative-specifier-p specifier))
         (case language
           (:python (string= (format nil "~a~{.~a~}" specifier path)
                             (format nil "~a.~a" module name)))
           (:javascript (and (string= specifier module)
                             (string= (format nil "~{~a~^.~}" path) name)))
           (t nil)))))

(defun match-registration (registration language declarations)
  "(values DECLARATION nil) for the one of DECLARATIONS REGISTRATION calls, (values
nil MATCHES) when it calls two, and (values nil nil) when it calls none.

DECLARATIONS are entry-points or setting-declarations entries, each with :MODULE
and :NAMES. Two matches are refused, not chosen between (CON-0001); the parse
already removes a callee two entries declare, so this is the second guard."
  (let ((matches (remove-if-not
                  (lambda (declaration)
                    (some (lambda (name)
                            (registration-matches-callee-p
                             registration language (getf declaration :module) name))
                          (getf declaration :names)))
                  declarations)))
    (if (rest matches)
        (values nil matches)
        (values (first matches) nil))))

;;; ------------------------------------------------------------------
;;; Settings (DES-0053 D10, DES-0054 D5)
;;; ------------------------------------------------------------------

(defun variable-table (view)
  "(file . name) to the module-level :VARIABLE of that name, for every language.
A local name in a registration argument is looked up here and nowhere else, so
it can reach a variable of its own file and never one of the same spelling in
another (DES-0054 risk 6)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (variable (entities-of-type view :variable) table)
      (when (slot-boundp variable 'name)
        (setf (gethash (cons (getp variable :file) (name variable)) table) variable)))))

(defun argument-references (value direct)
  "The names and dotted chains inside one encoded argument VALUE, flattened
through lists, as the encoded plists. When DIRECT, a string literal is a
reference too, as the bare string: the keyword it sits under names settings
(`secrets=[\"K\"]'). A call is the marker :EXPRESSION and names nothing."
  (cond ((and (consp value) (eq :list (first value)))
         (loop for element in (rest value) append (argument-references element direct)))
        ((and (consp value) (member (first value) '(:name :dotted))) (list value))
        ((and direct (stringp value)) (list value))
        (t nil)))

(defun reference-variable (reference file language walk variables)
  "The :VARIABLE the encoded REFERENCE names, written in FILE, or NIL.

A local name is the module-level variable of that name in FILE. An imported one
is walked to the file it came from, for Python only: JavaScript has no resolver
here, and walking its specifiers as Python's would be a fabricated edge. A dotted
chain is followed from its first name's import binding; one rooted in a local
names nothing. WALK is a function returning the walk context, built on first
use."
  (flet ((walked (specifier names)
           (let ((module (and (eq language :python)
                              (walk-resolve-specifier (funcall walk) specifier file))))
             (when (and module names)
               (let ((*walk-lands-on-variables* t))
                 (values (walk-attribute-path (funcall walk) module names)))))))
    (case (first reference)
      (:name
       (if (eq :local (getf reference :binding))
           (gethash (cons file (second reference)) variables)
           (walked (getf reference :specifier) (getf reference :path))))
      (:dotted
       (when (getf reference :specifier)
         (walked (getf reference :specifier)
                 (append (getf reference :path)
                         (rest (split-on (second reference) #\.)))))))))

(defun split-on (text char)
  "TEXT split at every CHAR."
  (loop for start = 0 then (1+ end)
        for end = (position char text :start start)
        collect (subseq text start end)
        while end))

(defun registrations-of (entity)
  "ENTITY's registration plists: every decorator of a function or method, or the
one :REGISTRATION of a variable."
  (case (entity-type entity)
    ((:function :method) (getp entity :decorators))
    (:variable (let ((registration (getp entity :registration)))
                 (and registration (list registration))))))

(defun registration-arguments (registration)
  "REGISTRATION's argument values with the keyword each sat under, as (key .
value), keyword NIL for a positional one."
  (append (getf registration :arguments)
          (loop for value in (getf registration :positional) collect (cons nil value))))

(defun declared-setting-names (view declarations)
  "Variable id to (name . source) for every :VARIABLE whose :VALUE-CALL calls a
setting declaration and carries a :FIRST-STRING (DES-0054 D5). One that carries
none names nothing."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (variable (entities-of-type view :variable) table)
      (let* ((call (getp variable :value-call))
             (declaration (and call (getf call :first-string)
                               (match-registration call (getp variable :language)
                                                   declarations))))
        (when declaration
          (setf (gethash (id variable) table)
                (cons (getf call :first-string) (getf declaration :source))))))))

(defun resolve-settings (view &key workspace-id setting-declarations entry-points domains)
  "Operations minting one :SETTING per name read and one :READS edge per reader.

DES-0053 D10. The analyzer writes :ENVIRONMENT-READS on the entity whose code
makes the read and nothing else. That a name read in two files is one thing is
a fact about the whole workspace, which no analyzer can see, so the node is
derived here, on every pass, from the property. The property is never
rewritten, and so a re-run after a retract rebuilds what the retract destroyed
(DEC-0003).

DES-0054 D5 adds two inputs, both derived. A declaration: a :VARIABLE whose
:VALUE-CALL calls one of SETTING-DECLARATIONS and carries a :FIRST-STRING names
that setting, takes the declaration's source into :SOURCES, and reads it. A
registration argument: each name or dotted chain in the arguments of a
decorator or :REGISTRATION that one of ENTRY-POINTS matches is resolved by its
binding to a declaring variable, and the registered entity then reads that
variable's setting, keyword-blind. A string literal in a list under a keyword
the entry lists in :SETTINGS names the setting directly. DOMAINS places the
specifiers an import walk resolves.

Sources are gathered per name before anything is asserted, so each setting is
asserted once with the union of what named it: two asserts of one key would make
the later overwrite the earlier. A secret and an environment variable of one
name are one node, since Firebase hands a bound secret to the function as an
environment variable of that name.

A registered entity's edge to a setting reached through a variable takes the
variable's file as its origin, so editing that file alone retracts it. An edge
from a literal takes the entity's own file. A setting no input names any more is
retracted, as CALL-SITE-RETRACTIONS sweeps an ambiguous site. A reader that
stops reading needs no edge sweep: its file was reanalyzed, and RETRACT-FILE took
its edges first. The retracts go last and name only settings no assert above
touches, for the reason CALL-SITE-RETRACTIONS gives. The pass returns operations
and calls nothing that writes the graph."
  (let ((sources (make-hash-table :test #'equal))
        (edges (make-hash-table :test #'equal))
        (declared (declared-setting-names view setting-declarations))
        (variables (variable-table view))
        (walk nil)
        (reads '()))
    (labels ((note (name source)
               ;; Keyed even with no source, so a name only a literal argument
               ;; gave is still minted.
               (setf (gethash name sources)
                     (if source
                         (adjoin source (gethash name sources))
                         (gethash name sources))))
             (read-edge (reader name origin)
               (let ((key (cons (id reader) name)))
                 (unless (gethash key edges)
                   (setf (gethash key edges) t)
                   (push (list reader name origin) reads))))
             (context ()
               (or walk (setf walk (build-walk-context view domains)))))
      ;; The environment, as before.
      (dolist (type *setting-reader-types*)
        (dolist (reader (entities-of-type view type))
          (dolist (name (remove-duplicates (getp reader :environment-reads)
                                           :test #'string=))
            (note name :environment)
            (read-edge reader name nil))))
      ;; A declaring variable reads the setting it declares.
      (dolist (variable (entities-of-type view :variable))
        (let ((declaration (gethash (id variable) declared)))
          (when declaration
            (note (car declaration) (cdr declaration))
            (read-edge variable (car declaration) nil))))
      ;; A registered entity reads what its arguments bind.
      (when entry-points
        (dolist (type '(:function :method :variable))
          (dolist (entity (entities-of-type view type))
            (dolist (registration (registrations-of entity))
              (let ((entry (match-registration registration (getp entity :language)
                                               entry-points))
                    (file (getp entity :file)))
                (when entry
                  (dolist (argument (registration-arguments registration))
                    (let ((direct (and (car argument)
                                       (member (car argument) (getf entry :settings)
                                               :test #'string=))))
                      (dolist (reference (argument-references (cdr argument) direct))
                        (if (stringp reference)
                            (progn (note reference nil)
                                   (read-edge entity reference nil))
                            (let* ((variable (reference-variable
                                              reference file (getp entity :language)
                                              #'context variables))
                                   (declaration (and variable
                                                     (gethash (id variable) declared))))
                              (when declaration
                                (read-edge entity (car declaration)
                                           (getp variable :file))))))))))))))
      ;; Each setting once, with every source that named it.
      (let ((ops '()))
        (maphash (lambda (name found)
                   (let ((setting (make-instance
                                   'setting-entity :name name
                                   :properties (properties-table
                                                (list :name name
                                                      :sources (sort (copy-list found)
                                                                     #'string<))))))
                     (push (assert-entity setting workspace-id) ops)))
                 sources)
        (loop for (reader name origin) in (nreverse reads)
              do (let ((setting (make-instance 'setting-entity :name name)))
                   (push (assert-edge :reads reader setting :workspace-id workspace-id
                                                            :origin-file origin)
                         ops)))
        (dolist (setting (entities-of-type view :setting))
          (unless (nth-value 1 (gethash (name setting) sources))
            (push (retract (id setting) workspace-id) ops)))
        (nreverse ops)))))

;;;; ==================================================================
;;;; Entry points (DES-0054 D6)
;;;; ==================================================================
;;;;
;;;; A function a framework calls has no caller in the tree, and `structure' lists
;;;; it beside the definitions nothing uses. The facts that say why are derived
;;;; here from what the analyzers wrote -- :DECORATORS, :REGISTRATION, :CODEBASES --
;;;; and the declarations the repository handed in, and are written back onto the
;;;; entity every pass (DEC-0003).

(defun glob-segment-match-p (pattern string &optional (p 0) (s 0))
  "True when STRING from S matches PATTERN from P, `*' for any run of characters
and `?' for one, inside a single path segment."
  (cond ((= p (length pattern)) (= s (length string)))
        ((char= #\* (char pattern p))
         (loop for end from s to (length string)
                 thereis (glob-segment-match-p pattern string (1+ p) end)))
        ((= s (length string)) nil)
        ((or (char= #\? (char pattern p)) (char= (char pattern p) (char string s)))
         (glob-segment-match-p pattern string (1+ p) (1+ s)))
        (t nil)))

(defun glob-segments-match-p (pattern path)
  "True when the segment lists PATTERN and PATH match whole, `**' standing for
any number of segments, none included."
  (cond ((null pattern) (null path))
        ((string= "**" (first pattern))
         (or (glob-segments-match-p (rest pattern) path)
             (and path (glob-segments-match-p pattern (rest path)))))
        ((null path) nil)
        (t (and (glob-segment-match-p (first pattern) (first path))
                (glob-segments-match-p (rest pattern) (rest path))))))

(defun glob-path-segments (text)
  "TEXT's non-empty segments between slashes, a leading `./' dropped."
  (remove "" (remove "." (split-on text #\/) :test #'string=) :test #'string=))

(defun interpretable-ignore-p (pattern)
  "True when PATTERN uses only the syntax IGNORE-MATCHES-P reads: plain names,
`*', `?' and `**'. Any other glob syntax is not interpreted, and excluding on a
pattern Loom cannot read would hide a deployed function (DES-0054 D6)."
  (notany (lambda (char) (find char "[]{}()!,")) pattern))

(defun ignore-matches-p (pattern relative)
  "True when the interpretable PATTERN excludes RELATIVE, a path relative to the
source directory. A plain name, one segment with no `**', matches that segment
at any depth below the source, as Firebase reads it. Any other pattern is
matched from the source against a leading run of the path, so excluding a
directory excludes what is under it."
  (let ((pattern (glob-path-segments pattern))
        (path (glob-path-segments relative)))
    (and pattern
         (if (and (null (rest pattern)) (string/= "**" (first pattern)))
             (some (lambda (segment) (glob-segment-match-p (first pattern) segment)) path)
             (loop for end from 1 to (length path)
                     thereis (glob-segments-match-p pattern (subseq path 0 end)))))))

(defun codebase-roots (view)
  "One plist per codebase of every firebase.json in VIEW: :FILE the :FILE entity,
:PREFIX the directory it deploys, with a trailing slash, :SOURCE, :CODEBASE,
:RUNTIME and :IGNORE."
  (let ((roots '()))
    (dolist (file (entities-of-type view :file) (nreverse roots))
      (let ((path (getp file :path)))
        (when (and path (getp file :codebases)
                   (string= "firebase.json" (subseq path (length (directory-prefix path)))))
          (dolist (codebase (getp file :codebases))
            (let ((source (format nil "~{~a/~}" (glob-path-segments (getf codebase :source)))))
              (push (list :file file
                          :prefix (concatenate 'string (directory-prefix path) source)
                          :source (getf codebase :source) :codebase (getf codebase :codebase)
                          :runtime (getf codebase :runtime) :ignore (getf codebase :ignore))
                    roots))))))))

(defun covering-codebases (path roots)
  "(values COVERING TIED). The codebase of ROOTS whose directory is the longest
prefix of PATH and whose ignore list does not exclude it. A tie at one length is
no answer: TIED lists the roots and COVERING is NIL."
  (let ((candidates
          (remove-if-not
           (lambda (root)
             (let ((prefix (getf root :prefix)))
               (and (>= (length path) (length prefix))
                    (string= prefix path :end2 (length prefix))
                    (notany (lambda (pattern)
                              (and (interpretable-ignore-p pattern)
                                   (ignore-matches-p pattern (subseq path (length prefix)))))
                            (getf root :ignore)))))
           roots)))
    (when candidates
      (let* ((longest (reduce #'max candidates :key (lambda (r) (length (getf r :prefix)))))
             (best (remove-if-not (lambda (r) (= longest (length (getf r :prefix))))
                                  candidates)))
        (if (rest best) (values nil best) (values (first best) nil))))))

(defun main-reach (context main-path)
  "The ids of the functions MAIN-PATH's explicit module-level imports bind, each
walked to its definition. `import handlers' binds a module and reaches nothing,
which is Firebase's behaviour: getmembers sees a module object, not a function."
  (let ((reached (make-hash-table :test #'equal))
        (main (gethash main-path (walk-context-files context))))
    (dolist (binding (and main (getp main :import-bindings)) reached)
      (let ((local (getf binding :local)))
        (when local
          (let ((callee (walk-attribute-path context main-path (list local))))
            (when callee (setf (gethash (id callee) reached) t))))))))

(defun reached-through-stars (context main-path entity)
  "(values REACHED UNKNOWABLE) for ENTITY through MAIN-PATH's star imports. A star
module the tree does not hold, or a walk that ended for another reason than a
true miss, leaves the answer unknowable. A name beginning with an underscore is
not bound by a star, unless __all__ lists it, which is not read, so it is
unknowable too."
  (let ((unknowable nil)
        (simple (name entity)))
    (dolist (specifier (star-specifiers context main-path) (values nil unknowable))
      (let ((module (walk-resolve-specifier context specifier main-path)))
        (if (null module)
            (setf unknowable t)
            (multiple-value-bind (callee cause)
                (walk-attribute-path context module (list simple))
              (cond ((and callee (eq callee entity))
                     (if (char= #\_ (char simple 0))
                         (setf unknowable t)
                         (return (values t nil))))
                    ((and (null callee) (not (eq cause :missing-in-target)))
                     (setf unknowable t)))))))))

(defun python-deployed-state (context entity main-path reaches)
  "ENTITY's :DEPLOYED for a Python function under the main.py at MAIN-PATH, by
DES-0054 D6: :YES when it is defined there or main.py binds it by name or star,
:NO when main.py is indexed whole and does not, :UNKNOWN otherwise.

main.py not indexed gives :UNKNOWN, as does one with a damaged region: the
binding that would deploy the function may be in the statement that did not
parse, and :NO is printed as a defect (REV-0003 finding 2). A method or a
variable is never a module-level function, so it is :UNKNOWN rather than :NO.
Known gap: a function bound in main.py by assignment, `g = handlers.f', is
deployed by Python and reads :NO here, which D6 accepts."
  (let ((main (gethash main-path (walk-context-files context))))
    (cond ((not (eq :function (entity-type entity))) :unknown)
          ((equal (getp entity :file) main-path) :yes)
          ((null main) :unknown)
          ((find "python syntax error" (getp main :suppressed-regions)
                 :key (lambda (region) (getf region :reason)) :test #'equal)
           :unknown)
          ((gethash (id entity) (funcall reaches main-path)) :yes)
          (t (multiple-value-bind (reached unknowable)
                 (reached-through-stars context main-path entity)
               (cond (reached :yes) (unknowable :unknown) (t :no)))))))

(defun matched-registrations (entity entry-points)
  "(registration . entry) for each of ENTITY's registrations one entry matches."
  (loop for registration in (registrations-of entity)
        for entry = (match-registration registration (getp entity :language) entry-points)
        when entry collect (cons registration entry)))

(defun registration-callee (registration language entry)
  "module.name of the one of ENTRY's names REGISTRATION calls."
  (let ((name (find-if (lambda (name)
                         (registration-matches-callee-p registration language
                                                        (getf entry :module) name))
                       (getf entry :names))))
    (format nil "~a.~a" (getf entry :module) name)))

(defun entry-point-options (registration entry)
  "REGISTRATION's arguments as (label . value): a keyword by its name, a positional
one by the label ENTRY declares for its position or else by its index."
  (append (getf registration :arguments)
          (loop for value in (getf registration :positional)
                for index from 0
                collect (cons (or (nth index (getf entry :positional)) index) value))))

(defun entry-point-plist (entity matched roots deployed)
  "One :ENTRY-POINT plist for MATCHED, a (registration . entry) pair of ENTITY.
DEPLOYED is a function of a root and the entity answering :YES, :NO or :UNKNOWN."
  (destructuring-bind (registration . entry) matched
    (let ((language (getp entity :language)))
      (multiple-value-bind (root tied) (covering-codebases (getp entity :file) roots)
        (append (list :framework (getf entry :framework)
                      :trigger (getf entry :trigger)
                      :callee (registration-callee registration language entry)
                      :options (entry-point-options registration entry)
                      :line (getf registration :line))
                (when root
                  (append (list :codebase (getf root :codebase)
                                :runtime (getf root :runtime)
                                :deployed (funcall deployed root entity))
                          (let ((open (remove-if #'interpretable-ignore-p (getf root :ignore))))
                            (when open (list :uninterpreted-ignores open)))))
                (when tied
                  (list :codebase-tie (mapcar (lambda (r) (getp (getf r :file) :path))
                                              tied))))))))

(defun resolve-entry-points (view &key workspace-id entry-points domains)
  "Operations writing :TRIGGER and :ENTRY-POINT onto every entity that carries a
registration, and a :DEPENDS-ON edge from each deployed one to the firebase.json
that deploys it. DES-0054 D6.

Every entity carrying :DECORATORS or :REGISTRATION gets both properties on every
pass, as a value or as NIL, so a declaration removed on a reindex clears its marks
with no file reanalyzed. :TRIGGER is the one registration's trigger, :MULTIPLE
when several matched, NIL when none did. A registration matching no declaration
marks nothing, and an entity with no codebase still gets both, so a Flask tree
uses the same key.

The :DEPENDS-ON edge takes <source>/main.py as its origin, because main.py's
bindings are what decided :DEPLOYED: editing it retracts the edge, and editing
firebase.json retracts the target. ENTRY-POINTS and DOMAINS are data from the
repository; the pass returns operations and calls nothing that writes the graph."
  (let* ((roots (codebase-roots view))
         (walk nil)
         (reach-cache (make-hash-table :test #'equal))
         (ops '()))
    (labels ((context () (or walk (setf walk (build-walk-context view domains))))
             (reaches (main-path)
               (or (gethash main-path reach-cache)
                   (setf (gethash main-path reach-cache) (main-reach (context) main-path))))
             (deployed (root entity)
               (if (eq :python (getp entity :language))
                   (python-deployed-state (context) entity
                                          (concatenate 'string (getf root :prefix) "main.py")
                                          #'reaches)
                   :unknown)))
      (dolist (type '(:function :method :variable))
        (dolist (entity (entities-of-type view type))
          (when (registrations-of entity)
            (let* ((matched (matched-registrations entity entry-points))
                   (plists (mapcar (lambda (m) (entry-point-plist entity m roots #'deployed))
                                   matched)))
              (push (update-properties
                     (id entity)
                     (list :trigger (cond ((null matched) nil)
                                          ((rest matched) :multiple)
                                          (t (getf (cdr (first matched)) :trigger)))
                           :entry-point plists)
                     workspace-id)
                    ops)
              (dolist (plist plists)
                (when (eq :yes (getf plist :deployed))
                  (let ((root (covering-codebases (getp entity :file) roots)))
                    (push (assert-edge :depends-on entity (getf root :file)
                                       :workspace-id workspace-id
                                       :origin-file (concatenate 'string (getf root :prefix)
                                                                 "main.py"))
                          ops))))))))
      (nreverse ops))))

;;;; ==================================================================
;;;; Declared dependencies (DES-0055 D4 to D8)
;;;; ==================================================================
;;;;
;;;; A :MODULE is a dependency a manifest declares. This pass joins an external
;;;; import to it by the ecosystem's own rule for npm and by a declaration for
;;;; Python, and never by spelling (U1). loom-graph reads no configuration, so
;;;; the declarations arrive as data from RESOLVE-AND-CHECK.

(defun npm-package-name (specifier)
  "The package SPECIFIER names under Node's rule: its first segment, or its first
two when it begins with `@'. NIL for a `node:' specifier, a builtin by its syntax
(DES-0055 D5), which RESOLVE-DEPENDENCIES counts as stdlib."
  (unless (and (>= (length specifier) 5) (string= "node:" specifier :end2 5))
    (let* ((slash (position #\/ specifier))
           (second-slash (and slash (char= #\@ (char specifier 0))
                              (position #\/ specifier :start (1+ slash)))))
      (subseq specifier 0 (if (char= #\@ (char specifier 0)) second-slash slash)))))

(defun dependency-ecosystem (language)
  (if (eq language :python) :pypi :npm))

(defun dependency-manifests (view)
  "Ecosystem -> directory prefix -> the :MODULEs declared there."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (module (entities-of-type view :module) table)
      (let ((file (getp module :file)))
        (when file
          (push module (gethash (list (getp module :ecosystem) (directory-prefix file))
                                table)))))))

(defun nearest-declaring-modules (manifests path ecosystem declares)
  "Every :MODULE in the nearest directory above PATH, up to the root, whose
manifests of ECOSYSTEM hold one that DECLARES accepts (D4). The first directory
that declares the name governs; a nearer one that does not is passed over."
  (let ((directory (directory-prefix path)))
    (loop
      (let ((found (remove-if-not declares (gethash (list ecosystem directory) manifests))))
        (when found (return found))
        (when (string= directory "") (return nil))
        (setf directory (parent-directory-prefix directory))))))

(defun dotted-prefix-length (prefix module)
  "The length of PREFIX when it is MODULE or a dotted prefix of it, else NIL."
  (and (>= (length module) (length prefix))
       (string= prefix module :end2 (length prefix))
       (or (= (length module) (length prefix))
           (char= #\. (char module (length prefix))))
       (length prefix)))

(defun longest-prefix-declarations (declarations module)
  "(values winner tied) for MODULE: the one declaration holding the longest dotted
prefix of it, or T as the second value when two declarations share that length
(DES-0055 D6)."
  (let ((best 0) (winners '()))
    (dolist (declaration declarations)
      (let ((length (loop for prefix in (getf declaration :modules)
                          for n = (dotted-prefix-length prefix module)
                          when n maximize n)))
        (when length
          (cond ((> length best) (setf best length winners (list declaration)))
                ((= length best) (push declaration winners))))))
    (values (and winners (null (rest winners)) (first winners))
            (and (rest winners) t))))

(defun pypi-joins (manifests declarations path module)
  "(values modules tied) for the dotted MODULE imported from PATH."
  (multiple-value-bind (winner tied) (longest-prefix-declarations declarations module)
    (values (and winner
                 (nearest-declaring-modules
                  manifests path :pypi
                  (lambda (m) (string= (getf winner :key)
                                       (distribution-name-key (name m))))))
            tied)))

(defun dependency-provides (module declarations)
  "What MODULE provides: its own name for npm, its declaration's modules for PyPI."
  (if (eq :npm (getp module :ecosystem))
      (list (name module))
      (let ((key (distribution-name-key (name module))))
        (getf (find key declarations :key (lambda (d) (getf d :key)) :test #'string=)
              :modules))))

(defun file-dependency-joins (manifests declarations file)
  "(values joined undeclared) for FILE's :EXTERNAL imports. JOINED is the :MODULEs
to draw :IMPORTS to; UNDECLARED the (:specifier s [:ambiguous t]) plists for the
specifiers that are neither stdlib nor joined (D8)."
  (let* ((path (getp file :path))
         (python-p (eq :python (getp file :language)))
         (joined '()) (undeclared '()))
    (dolist (miss (getp file :unresolved-imports))
      (when (eq :external (getf miss :cause))
        (let ((specifier (getf miss :specifier)) (modules '()) (tied nil) (stdlib nil))
          (if python-p
              (dolist (entry (remove-if-not (lambda (e) (string= specifier (getf e :source)))
                                             (getp file :import-modules)))
                (if (getf entry :stdlib)
                    (setf stdlib t)
                    (multiple-value-bind (found tie)
                        (pypi-joins manifests declarations path (getf entry :module))
                      (setf modules (append found modules) tied (or tied tie)))))
              (let ((package (npm-package-name specifier)))
                (if package
                    (setf modules (nearest-declaring-modules
                                   manifests path :npm
                                   (lambda (m) (string= package (name m)))))
                    (setf stdlib t))))
          (cond (modules (dolist (m modules) (pushnew m joined)))
                (stdlib nil)
                (t (push (append (list :specifier specifier) (when tied (list :ambiguous t)))
                         undeclared))))))
    (values joined (nreverse undeclared))))

(defun call-dependency-joins (manifests declarations caller)
  "The :MODULEs CALLER's :EXTERNAL imported calls reach, by the dotted name of each."
  (let ((found '()))
    (dolist (miss (getp caller :unresolved-imported-calls))
      (when (eq :external (getf miss :cause))
        (let ((dotted (format nil "~a~{.~a~}" (getf miss :specifier) (getf miss :path))))
          (dolist (m (pypi-joins manifests declarations (getp caller :file) dotted))
            (pushnew m found)))))
    found))

(defun dependency-sweep (view produced workspace-id)
  "Retract each :IMPORTS or :DEPENDS-ON edge into a :MODULE that PRODUCED, a table
of (type from to) keys, does not hold. Nothing but this pass writes such an edge,
so every one it finds and did not draw again is stale (FINDINGS 2). Read only to
remove it, never to derive from it (DEC-0003)."
  (let ((ops '()))
    (dolist (module (entities-of-type view :module))
      (dolist (type '(:imports :depends-on))
        (dolist (r (relationships-to view (id module) :rel-type type))
          (unless (gethash (relationship-natural-key r) produced)
            (push (retract (id r) workspace-id) ops)))))
    (nreverse ops)))

(defun resolve-dependencies (view &key workspace-id dependency-modules)
  "Operations joining external imports to the :MODULEs a manifest declares.
DES-0055 D8. DEPENDENCY-MODULES is the repository's declarations, data from
.loom/frameworks.yaml.

Writes :IMPORTS from a module-scoped :FILE, :DEPENDS-ON from a caller whose
:UNRESOLVED-IMPORTED-CALLS name a dependency, :PROVIDES on each :MODULE when it
changed, and :UNDECLARED-IMPORTS on every module-scoped :FILE with imports. Reads
:UNRESOLVED-IMPORTS, :IMPORT-MODULES and :UNRESOLVED-IMPORTED-CALLS and rewrites
none of them. The edges are swept last: any such edge this pass did not draw again
is retracted, so a nearer manifest or a withdrawn declaration leaves nothing behind."
  (let ((manifests (dependency-manifests view))
        (produced (make-hash-table :test #'equal))
        (ops '()))
    (flet ((draw (type from to)
             (let ((edge (assert-edge type from to :workspace-id workspace-id)))
               (unless (gethash (relationship-natural-key (op-rel edge)) produced)
                 (setf (gethash (relationship-natural-key (op-rel edge)) produced) t)
                 (push edge ops)))))
      (dolist (module (entities-of-type view :module))
        (let ((provides (dependency-provides module dependency-modules)))
          (unless (equal provides (getp module :provides))
            (push (update-properties (id module) (list :provides provides) workspace-id)
                  ops))))
      (dolist (file (entities-of-type view :file))
        (when (and (getp file :path) (module-scoped-language-p (getp file :language))
                   (getp file :import-sources))
          (multiple-value-bind (joined undeclared)
              (file-dependency-joins manifests dependency-modules file)
            (dolist (module joined) (draw :imports file module))
            (push (update-properties (id file) (list :undeclared-imports undeclared)
                                     workspace-id)
                  ops))))
      (dolist (type '(:function :method :test :call-site))
        (dolist (caller (entities-of-type view type))
          (when (getp caller :unresolved-imported-calls)
            (dolist (module (call-dependency-joins manifests dependency-modules caller))
              (draw :depends-on caller module)))))
      (append (nreverse ops) (dependency-sweep view produced workspace-id)))))

;;;; ==================================================================
;;;; Document links (SS10.3)
;;;; ==================================================================
;;;;
;;;; The same problem in a different costume. A decision's affects: field
;;;; names entities the document analyzer cannot see, for the same reason the
;;;; Lisp analyzer cannot see across a file boundary: SS9.1 keeps analyzers
;;;; stateless. The names ride through as properties and are resolved here,
;;;; where the whole index is in one place.
;;;;
;;;; SS10.3 asks for two mechanisms with different provenance, and the
;;;; difference is the point:
;;;;
;;;;   Declared -- affects:, supersedes:, applies-to:. Someone wrote these
;;;;   down deliberately, so they resolve to :structural edges at confidence
;;;;   1.0, and a name that resolves to nothing is recorded rather than
;;;;   dropped. That record is the documentation staleness detector.
;;;;
;;;;   Mentioned -- names appearing in prose. Nobody promised these, so they
;;;;   resolve to :inferred edges at lower confidence with derived-from
;;;;   populated, which is what makes them go stale when the code moves.

(defparameter *document-types* '(:decision :design :architecture :rule :concept :document)
  "Entity types the documentation analyzer produces.")

(defparameter *governing-document-types* '(:decision :design)
  "Document types whose affects: is a claim to *govern* rather than to bear on.

A decision's affects: says this decision governs that code, which is what
:DECIDES means and why `impact' gathers it into the decisions field. Nothing
else in the workflow makes that claim: a requirement asks for a change, a plan
sequences one, a bug report locates one. All three bear on the code they name
without governing it, so they earn :DOCUMENTS instead -- the type declared for
exactly this since SS11 and, until affects: was read for them, the type with no
producer at all (DES-0016 D7 recorded that gap and predicted this would close
it).")

(defparameter *declared-link-fields*
  '((:affects    . :decides)
    (:describes  . :documents)
    (:applies-to . :applies-to)
    (:supersedes . :supersedes)
    (:refines    . :refines))
  "Document property -> the relationship type it declares.

:AFFECTS is the entry DECLARED-EDGE-TYPE overrides: the value here is what a
governing document asserts, and every other kind of document asserts
:DOCUMENTS instead.

:REFINES is the one that points at another document rather than at code, which
LINKABLE-INDEX already supports: it keys on doc-id as well as on name, so
refines: [REQ-0002] finds the requirement. That is what makes the workflow a
graph rather than a filing convention -- the design that answers a requirement,
the plan that sequences the design, and the report of what went wrong are all
one walkable chain.")

(defun declared-edge-type (field document)
  "The relationship DOCUMENT's declared FIELD asserts.

Only :AFFECTS depends on the speaker; every other declared field means one
thing whoever writes it. A rule's applies-to: constrains, a supersedes:
replaces, a refines: answers -- none of those change meaning with the document
type, because only one type may write them."
  (let ((declared (cdr (assoc field *declared-link-fields*))))
    (if (and (eq field :affects)
             (not (member (entity-type document) *governing-document-types*)))
        :documents
        declared)))

(defparameter *mention-confidence* 0.5
  "Confidence for an edge inferred from prose.
Low enough that a caller filtering on confidence drops them, present enough
that \"what decisions touch this?\" answers without the author having
enumerated every consequence.")

(defun linkable-index (view)
  "Name -> entities that a document reference could name.

Keyed three ways. On the entity name, which is what an author writes. On the
doc-id, because a decision's supersedes: names another decision by its id
rather than by a function name. And on the entity id, which is DES-0029 D2:
`find\' prints function:server/server.lisp:check-database, and an author facing
a name two functions answer to should be able to paste that back and mean one
of them.

An id cannot collide with a name. Every id carries a colon, and a name spelled
with one would have to be written that way in the source."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (entity (all-entities view))
      (when (slot-boundp entity 'name)
        (push entity (gethash (string-downcase (name entity)) index)))
      (let ((doc-id (getp entity :doc-id)))
        (when doc-id
          (pushnew entity (gethash (string-downcase doc-id) index))))
      (pushnew entity (gethash (string-downcase (id entity)) index)))
    index))

(defun reads-setting-p (view variable setting)
  "True when VARIABLE has a :READS edge to SETTING. DES-0054 D5."
  (some (lambda (edge) (equal (to-id edge) (id setting)))
        (relationships-from view (id variable) :rel-type :reads)))

(defun setting-with-readers (candidates view)
  "The one :SETTING among CANDIDATES when every other candidate is a :VARIABLE that
reads it, else NIL.

`SPREADSHEET_ID = os.environ.get(\"SPREADSHEET_ID\", \"\")' mints a :VARIABLE and a
:SETTING of one name, and `ZEFFY_API_KEY = SecretParam(...)' does the same. They
are one fact stated twice, since the variable is the read, so a name that reaches
exactly these means the setting. A variable of the same name that reads something
else is a different thing, and the set stays ambiguous (CON-0001). A variable
reads the setting when its :ENVIRONMENT-READS holds the name or, with a VIEW, when
it has a :READS edge to it. Shared by RESOLVE-ONE and by the console's
RESOLVE-ENTITY, so a document and a `describe' agree on what a name means."
  (let ((settings (remove-if-not (lambda (e) (eq :setting (entity-type e))) candidates)))
    (and (= 1 (length settings))
         (every (lambda (e)
                  (or (eq e (first settings))
                      (and (eq :variable (entity-type e))
                           (or (member (name (first settings)) (getp e :environment-reads)
                                       :test #'string=)
                               (and view (reads-setting-p view e (first settings)))))))
                candidates)
         (first settings))))

(defun resolve-one (index name &key view)
  "The single entity NAME identifies, and the candidates it was declined over.

Two values. A name that resolves answers the entity and NIL. A name matching
nothing answers NIL and NIL. A name matching several answers NIL and the
candidates -- DES-0029 D1, because the set is in hand at the moment of the
refusal and the caller is the one that has to tell an author which of the two
NILs it got. A caller wanting one answer ignores the second value and behaves
exactly as it did.

Refusing an ambiguous name is the same judgement RESOLVE-CALLS makes: a
fabricated edge is worse than a recorded miss. What changes is that the refusal
is now reportable rather than indistinguishable from rot.

A generic function and its methods are the exception, and not by relaxing the
rule -- they are not several things sharing a name, they are one protocol and
its implementations, all answering to the protocol's name. A document that
names analyze-file means the contract; picking one of its methods would be
arbitrary and refusing outright reports the reference as rotten when it is
perfectly good. So a candidate set consisting of exactly one :INTERFACE plus
methods resolves to the interface.

A setting and the variables that read it are the other. `SPREADSHEET_ID =
os.environ.get(\"SPREADSHEET_ID\", \"\")' mints a :VARIABLE and a :SETTING of one
name, and every one of lfia's eight config reads has that shape. They are one
fact stated twice, since the variable is the read, and a document naming
SPREADSHEET_ID means the thing the environment holds. So a set of exactly one
:SETTING plus :VARIABLEs each carrying the name in :ENVIRONMENT-READS resolves
to the setting. A variable of the same name that does not read it is a
different thing, and the set stays ambiguous (CON-0001).

VIEW widens the variable clause (DES-0054 D5): a variable with a :READS edge to
the setting counts too, which is what `ZEFFY_API_KEY = SecretParam(...)' is. The
old clause stays as a disjunct, so a caller that passes no view, which
UNAMBIGUOUS-NAMES is, resolves exactly what it did and nothing that resolves
today stops resolving."
  (let ((candidates (gethash (string-downcase name) index)))
    (cond ((null candidates) (values nil nil))
          ((null (rest candidates)) (values (first candidates) nil))
          (t (let ((interfaces (remove-if-not
                                (lambda (e) (eq :interface (entity-type e)))
                                candidates))
                   (setting (setting-with-readers candidates view)))
               (cond ((and (= 1 (length interfaces))
                           (every (lambda (e)
                                    (member (entity-type e) '(:interface :method)))
                                  candidates))
                      (values (first interfaces) nil))
                     (setting (values setting nil))
                     (t (values nil candidates))))))))

(defun resolve-document-links (view &key workspace-id)
  "Operations linking each document's declared and mentioned references.

Declared names that resolve become :structural edges of the type their field
declares -- DECLARED-EDGE-TYPE, because affects: means :DECIDES from a
decision and :DOCUMENTS from anything else; the rest are collected onto the
document's :UNRESOLVED-REFERENCES,
which is what SS10.3 asks be \"flagged ... counted in status, and exposed
through the API\" instead of quietly discarded. Prose mentions that resolve
become :inferred :MENTIONS edges -- the weaker type, which claims that the
document names the entity and nothing more (DES-0016 D7). It was :DOCUMENTS
until REQ-0014, and this loop was that type's only producer in the tree; a
markdown backtick and a YAML backtick are the same fact and now say so with
the same word.

Idempotent, like RESOLVE-CALLS: edges upsert by natural key, and a name that
resolved on a previous pass is still in the property, so nothing drifts."
  (let ((index (linkable-index view))
        (ops '()))
    (dolist (type *document-types*)
      (dolist (document (entities-of-type view type))
        (let ((unresolved '())
              (ambiguous '()))
          ;; --- declared links ------------------------------------------
          (dolist (field-and-type *declared-link-fields*)
            (let* ((field (car field-and-type))
                   (edge-type (declared-edge-type field document)))
              (dolist (name (getp document field))
                (multiple-value-bind (target candidates) (resolve-one index name :view view)
                  (cond
                    ((and target (not (eq target document)))
                     (push (assert-edge edge-type document target
                                        :workspace-id workspace-id)
                           ops))
                    ;; DES-0029 D3. A name several entities answer to is not
                    ;; the same fact as a name nothing answers to, and it is
                    ;; the candidates -- not the count -- that let an author
                    ;; act: the ids are what goes back into the field.
                    (candidates
                     (pushnew (list :name name
                                    :candidates (mapcar #'id candidates))
                              ambiguous
                              :test #'string= :key (lambda (e) (getf e :name))))
                    (t (pushnew name unresolved :test #'string=)))))))
          ;; --- link targets (BUG-0027) ---------------------------------
          ;; The same weak edge a mention earns, and a different failure. A
          ;; link target is a path an author wrote; when it resolves to nothing
          ;; the file is not there, which is a fact rather than the ambiguity a
          ;; backticked word might be. So it is reported where `check' looks
          ;; instead of being dropped into REQ-0014's silence, which was written
          ;; for ordinary prose and inherited by links only because the two
          ;; populations were merged before anything could tell them apart.
          (dolist (name (getp document :link-targets))
            (let ((target (resolve-one index name :view view)))
              (cond
                ;; Not in the index. That is NOT the same as not on disk, and
                ;; the difference is the whole of why this branch does not
                ;; report anything: game-server links to CLAUDE.md, which
                ;; REQ-0028 excludes by name, and to data-api/sql/test.sql,
                ;; which no analyzer claims. Both files are right there. Calling
                ;; them broken would be a fabricated fact with a plausible
                ;; shape, which is worse than the silence BUG-0027 set out to
                ;; end.
                ;;
                ;; Whether a path exists is a filesystem question and loom-graph
                ;; has no filesystem. CHECK-DOCUMENT-LINKS in loom-workspace
                ;; owns it, because that is the layer that knows a repository
                ;; has a root.
                ((null target) nil)
                ;; A link to another document. It resolved -- the file exists --
                ;; so it is emphatically not broken, and reporting it would be a
                ;; false positive of exactly the kind that teaches a reader to
                ;; stop reading the list. It earns no edge because :MENTIONS may
                ;; not terminate at a :DOCUMENT: the type is declared to reach
                ;; code, and a document-to-document link is a different claim
                ;; that CON-0004's refines: is for.
                ;;
                ;; The transaction validator caught this rather than the tests:
                ;; docs/README.md links to design-summary/api.md, and the first
                ;; version of this branch tried to assert an edge the ontology
                ;; refuses. It refused the whole transaction, which is why a
                ;; whole repository's document links vanished instead of one
                ;; edge being silently wrong.
                ((member (entity-type target) *document-types*) nil)
                ((eq target document) nil)
                (t (push (assert-edge :mentions document target
                                      :workspace-id workspace-id
                                      :source :inferred
                                      :confidence *mention-confidence*
                                      :derived-from (list (id target)))
                         ops)))))
          ;; --- mentioned links -----------------------------------------
          (dolist (name (getp document :mentions))
            (let ((target (resolve-one index name :view view)))
              (when (and target
                         (not (eq target document))
                         (not (member (entity-type target) *document-types*)))
                (push (assert-edge :mentions document target
                                   :workspace-id workspace-id
                                   :source :inferred
                                   :confidence *mention-confidence*
                                   :derived-from (list (id target)))
                      ops))))
          (push (update-properties (id document)
                                   (list :unresolved-references (nreverse unresolved)
                                         :ambiguous-references (nreverse ambiguous))
                                   workspace-id)
                ops))))
    (nreverse ops)))

(defun unparsed-facts (view)
  "Every file and document the analyzer could not read, as plists carrying
:PATH, :TYPE and :ERROR.

The analyzer\'s half of this has always worked and is SS3.3\'s contract: a file
that will not parse is *marked, not omitted*, so a YAML document whose title
carries an unquoted colon lands in the index as a :DOCUMENT named by its path
and carrying :ANALYSIS-ERROR -- with the parser\'s own line and column in it.
Nothing read that property. BUG-0033 is the reporting half arriving twelve days
and two lost documents later.

Worth being exact about what the silence was, because the bug document offered
two hypotheses and the answer is the less obvious one. The document is not
dropped and the count does not fall: `documents\' counts the entity like any
other, so the number looks right while the document has no id, no fields, no
references and no title. That is the shape CON-0006 calls the expensive error --
a reader cannot tell it from a document that says nothing.

:FILE is here beside the document types because it carries the same property
for the same reason. A JavaScript file acorn could not parse, or one whose
toolchain is absent entirely, is the same fact about the same index."
  (loop for type in (cons :file *document-types*)
        append (loop for entity in (entities-of-type view type)
                     for problem = (getp entity :analysis-error)
                     when problem
                       collect (list :path (or (getp entity :path)
                                               (and (slot-boundp entity \'name)
                                                    (princ-to-string (name entity))))
                                     :type type
                                     :error problem))))

(defun ambiguous-references (view)
  "Every declared reference that named several entities, as plists carrying the
document, the name as written, and the candidate ids.

Read separately from UNRESOLVED-REFERENCES because the two are different facts
about a document. That one answers what the document names that is not there;
this one answers what it names that is there more than once, which no author
has to fix and every author has to be able to tell apart from rot (DES-0029
D4)."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type view type)
                     append (loop for entry in (getp document :ambiguous-references)
                                  collect (list :document (name document)
                                                :name (getf entry :name)
                                                :candidates (getf entry :candidates))))))

(defun unresolved-references (view)
  "Every document reference that named nothing, as (document-name . name).
What the status command reports, per SS3.2.

Two properties, one report. :UNRESOLVED-REFERENCES holds names the index could
not place -- a decision naming a function that no longer exists. :BROKEN-LINKS
holds paths the filesystem does not have, which loom-workspace establishes
because loom-graph cannot stat anything. They are separate where they are
written, because they are found by different means at different layers, and
together where they are read, because to somebody fixing a document they are one
question: what does this name that is not there."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type view type)
                     append (loop for name in (append (getp document :unresolved-references)
                                                      (getp document :broken-links))
                                  collect (cons (name document) name)))))
