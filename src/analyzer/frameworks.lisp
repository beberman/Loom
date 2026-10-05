;;;; What a repository knows about its own frameworks, that Loom cannot.
;;;;
;;;; DES-0025 D4. Loom ships knowing fiveam, because Loom's own tree uses
;;;; fiveam -- that is a fact about Loom, not a policy about frameworks. Every
;;;; other tree declares its own in .loom/frameworks.yaml:
;;;;
;;;;   definer-macros:
;;;;     - macro: defroute
;;;;       package: easy-routes
;;;;       defines: function
;;;;       name-index: 1
;;;;       body-index: 3
;;;;       route-index: 2
;;;;   route-callers:
;;;;     - callee: [get, post, sendGet, sendPost]
;;;;       argument-index: 0
;;;;   archived-paths:
;;;;     - docs/archive/
;;;;
;;;; Three keys now, and the file's name has grown a little narrow: what it
;;;; holds is what a repository declares about itself that Loom cannot derive.
;;;; A third key is cheaper than a second file, and every one of them has the
;;;; same shape of justification -- a fact only this repository's author has.
;;;;
;;;; Without this, game-server's 27 (easy-routes:defroute NAME ("/public/..."))
;;;; forms produce nothing at all: PUBLIC-API-CREATE-GAME is not an entity, and
;;;; DEFROUTE is not even reported by UNHANDLED-DEFINER-MACROS, because that
;;;; report covers macros the tree itself defines and DEFROUTE comes from a
;;;; library. A definer nobody declared is invisible rather than counted, which
;;;; is the one shape of gap this project rules out (CON-0001) -- so declaring
;;;; it has to be possible from outside Loom's source.
;;;;
;;;; A SEPARATE FILE FROM .loom/manifest.yaml, and structurally so rather than
;;;; for tidiness. READ-MANIFEST is a line scanner: loom-workspace does not
;;;; depend on a YAML parser and DES-0018 kept it that way deliberately. A
;;;; nested declaration cannot be line-scanned honestly, and pretending
;;;; otherwise would put a half-parser in the layer that has no parser on
;;;; purpose. This file lives in loom-analyzer, which has cl-yaml already, and
;;;; loom-workspace hands the result to the passes exactly the way it already
;;;; hands in *MACRO-GENERATORS*.

(in-package :loom-analyzer)

(defparameter *frameworks-file* ".loom/frameworks.yaml"
  "Where a repository declares what its own frameworks mean, relative to its
root. Dot-prefixed, so REPOSITORY-FILES skips it for the same reason it skips
the manifest: this is Loom's own configuration, not the repository's content,
and indexing it as engineering knowledge would be a category error.")

(defun frameworks-path (root)
  (merge-pathnames *frameworks-file* (pathname root)))

(defun as-index (value)
  "A non-negative integer from a YAML scalar, or NIL.

NIL for anything else, including a negative or a non-number. An index is a
position in a form and a wrong one mints an entity named after the wrong
subform -- CON-0001's fabricated fact -- so a malformed one declines to
declare rather than defaulting to something plausible."
  (let ((n (typecase value
             (integer value)
             (string (parse-integer value :junk-allowed t))
             (t nil))))
    (and n (>= n 0) n)))

(defun parse-definer-macro (table)
  "One definer-macros: entry as a generator registry plist, or NIL.

The shape REGISTER-MACRO-GENERATOR produces, plus :ROUTE-INDEX, so nothing
downstream can tell a declared entry from a shipped one -- REQ-0003's one
table and one pass over it, which EFFECTIVE-GENERATOR-REGISTRY already relies
on for in-tree macros.

:MACRO and :DEFINES are required. An entry without a name has nothing to match
a call site against, and one without an entity type would mint an entity of no
type; both are dropped, and FRAMEWORKS-PROBLEMS reports them rather than
letting the file look like it worked."
  (let ((macro (as-string (yaml-value table :macro)))
        (defines (as-keyword (yaml-value table :defines))))
    (when (and macro defines)
      (list :name (string-downcase macro)
            :package (let ((p (as-string (yaml-value table :package))))
                       (and p (string-downcase p)))
            :entity-type defines
            :name-index (or (as-index (yaml-value table :|name-index|)) 1)
            :body-index (as-index (yaml-value table :|body-index|))
            ;; DES-0025 D1. The position of a literal to record as :ROUTE on
            ;; the minted entity -- the claim one side of an HTTP join
            ;; publishes. Absent for a definer that defines no endpoint, which
            ;; is most of them.
            :route-index (as-index (yaml-value table :|route-index|))
            :framework (as-keyword (yaml-value table :framework))
            :declared t))))

(defun parse-route-caller (table)
  "One route-callers: entry, or NIL.

The client half of DES-0025 D1: which callees carry a route as a literal
argument, and at which position. `callee:' takes a scalar or a sequence,
because a tree that routes through four wrapper names should write them once."
  (let ((callees (as-list-of-strings (yaml-value table :callee)))
        (index (or (as-index (yaml-value table :|argument-index|)) 0)))
    (when callees
      (list :callees (mapcar #'string-downcase callees)
            :argument-index index))))

(defparameter *resolution-presets*
  '((:bundler   :extensions (".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx")
                 :guess-extension t :index-fallback t)
    (:node-esm  :extensions ()
                :guess-extension nil :index-fallback nil)
    (:commonjs  :extensions (".js" ".json" ".node")
                :guess-extension t :index-fallback t))
  "What each resolution name means, as data. DES-0047.

Three names rather than a set of switches, because the three are what real
toolchains do and a reader recognises them: a bundler guesses an extension and
falls back to index files, Node's ESM loader does neither and requires the
specifier to name the file, and CommonJS guesses among a different extension
list. A tree that wants a fourth combination is telling us about a toolchain we
have not met, and should say so rather than assemble one from flags.

Here rather than in loom-graph because the analyzer is what parses the name.
The graph receives the expansion as data and reads no configuration, which is
the property DES-0025 D4 established and this keeps.")

(defparameter *default-domain* :default
  "The domain a path falls in when no declared root is a prefix of it.

Reserved: a declaration using this name is refused rather than merged, because
two things would then answer to one name and neither could be addressed.")

(defun parse-domain (table)
  "One `domains:' entry as (:name :root :resolution :aliases :aliases-from).

NAME and ROOT are required and an entry missing either declares nothing, which
is PARSE-FRAMEWORKS' rule one level down: a half-read domain would place files
into a prefix whose alias map nobody wrote.

NAME is interned as a keyword here, once, when the declaration is read. That is
the whole bound on the keyword package -- three entries on front-end -- and it
is the bound :SYSTEM has always had. The root, the alias keys and the alias
targets stay strings, because they are compared against paths.

RESOLUTION defaults to bundler and a name outside the three is left NIL rather
than defaulted, so DOMAIN-PROBLEMS can report it. Defaulting an unknown name
would silently give a tree the wrong toolchain."
  (let* ((name (as-string (yaml-value table :name)))
         (root (as-string (yaml-value table :root)))
         (declared (as-string (yaml-value table :resolution)))
         (resolution (cond ((null declared) :bundler)
                           ((string-equal declared "bundler") :bundler)
                           ((string-equal declared "node-esm") :node-esm)
                           ((string-equal declared "commonjs") :commonjs)
                           (t nil)))
         (aliases (let ((raw (yaml-value table :aliases))
                        (pairs '()))
                    (when (hash-table-p raw)
                      (maphash (lambda (k v)
                                 (let ((key (as-string k)) (target (as-string v)))
                                   (when (and key target)
                                     (push (cons key target) pairs))))
                               raw))
                    (nreverse pairs))))
    (when (and name root)
      (list :name (intern (string-upcase name) :keyword)
            :root root
            :resolution resolution
            :declared-resolution declared
            :aliases aliases
            :aliases-from (let ((from (as-string (yaml-value table :|aliases-from|))))
                            (and from (intern (string-upcase from) :keyword)))))))

(defun as-sequence (value)
  "A YAML sequence as a list, whatever cl-yaml made of it."
  (typecase value
    (null '())
    (cons value)
    (vector (coerce value 'list))
    (t (list value))))

(defun parse-declaration-block (table)
  "A YAML mapping as a plist of keywords to strings, or NIL.

Uninterpreted on purpose. DES-0052 D3: which keys a document store's
declaration may carry is written down in that store's constructor and nowhere
else, so this renders the block and stops. A value that is not a scalar is
rendered by AS-STRING, which is what every other scalar in this file gets."
  (when (hash-table-p table)
    (loop for key being the hash-keys of table using (hash-value value)
          append (list (intern (string-upcase (string key)) :keyword)
                       (as-string value)))))

(defun callee-names (module names)
  "MODULE joined to each of NAMES with a dot: the callees an entry declares."
  (mapcar (lambda (name) (format nil "~a.~a" module name)) names))

(defun missing-fields (table required)
  "The keys of REQUIRED, in order, that TABLE leaves empty. `names:' is empty
when it holds no string; every other field when it is not a non-blank scalar."
  (loop for key in required
        unless (if (eq key :names)
                   (as-list-of-strings (yaml-value table key))
                   (as-string (yaml-value table key)))
          collect key))

(defparameter *entry-point-required* '(:module :names :trigger)
  "The fields an entry-points: entry cannot declare without (DES-0054 D3).")

(defparameter *setting-declaration-required* '(:source :module :names)
  "The fields a setting-declarations: entry cannot declare without (DES-0054 D3).")

(defun parse-entry-point (table)
  "One entry-points: entry as (:FRAMEWORK :TRIGGER :MODULE :NAMES :SETTINGS
:POSITIONAL). The caller has checked *ENTRY-POINT-REQUIRED*.

DES-0054 D3. TRIGGER is interned as a keyword here, once, which bounds the
keyword package by the declarations as DOMAIN names are bounded (DES-0047 D1).
FRAMEWORK is a label for the reader and defaults to the module. MODULE and the
names stay as written, since they are compared against what a source file
binds."
  (let ((module (as-string (yaml-value table :module))))
    (list :framework (or (as-string (yaml-value table :framework)) module)
          :trigger (as-keyword (yaml-value table :trigger))
          :module module
          :names (as-list-of-strings (yaml-value table :names))
          :settings (as-list-of-strings (yaml-value table :settings))
          :positional (as-list-of-strings (yaml-value table :positional)))))

(defun parse-setting-declaration (table)
  "One setting-declarations: entry as (:SOURCE :MODULE :NAMES). The caller has
checked *SETTING-DECLARATION-REQUIRED*. SOURCE is interned as a keyword here,
once, for PARSE-ENTRY-POINT's reason (DES-0054 D3)."
  (list :source (as-keyword (yaml-value table :source))
        :module (as-string (yaml-value table :module))
        :names (as-list-of-strings (yaml-value table :names))))

(defun read-callee-entries (key parsed required parser)
  "PARSED's KEY entries as (values ((INDEX . ENTRY) ...) PROBLEMS). An entry
missing a field of REQUIRED is left out and a problem names its key and index."
  (let ((entries '()) (problems '()))
    (loop for table in (as-sequence (yaml-value parsed key))
          for index from 0
          for missing = (missing-fields table required)
          do (if missing
                 (push (format nil "~(~a~)[~d] declares nothing: it has no ~{~(~a~)~^, ~}"
                               key index missing)
                       problems)
                 (push (cons index (funcall parser table)) entries)))
    (values (nreverse entries) (nreverse problems))))

(defun parse-callee-declarations (parsed)
  "PARSED's entry-points and setting-declarations as (values ENTRY-POINTS
SETTING-DECLARATIONS PROBLEMS).

A callee, module.name, declared by two entries -- within one key or across the
two -- is removed from both and PROBLEMS names both: picking one would be a guess
between two declarations (CON-0001), and an entry left with no name declares
nothing. Removing it here is what makes `neither applies it' true of every
consumer, so the passes need not check."
  (multiple-value-bind (entry-points entry-problems)
      (read-callee-entries :|entry-points| parsed *entry-point-required*
                           #'parse-entry-point)
    (multiple-value-bind (declarations declaration-problems)
        (read-callee-entries :|setting-declarations| parsed *setting-declaration-required*
                             #'parse-setting-declaration)
      (let ((where (make-hash-table :test #'equal)))
        (loop for (key entries) in (list (list "entry-points" entry-points)
                                         (list "setting-declarations" declarations))
              do (loop for (index . entry) in entries
                       do (dolist (callee (callee-names (getf entry :module)
                                                        (getf entry :names)))
                            (push (format nil "~a[~d]" key index) (gethash callee where)))))
        (let ((twice (sort (loop for callee being the hash-keys of where
                                   using (hash-value places)
                                 when (rest places) collect callee)
                           #'string<)))
          (flet ((kept (entries)
                   (loop for (nil . entry) in entries
                         for names = (remove-if
                                      (lambda (name)
                                        (member (format nil "~a.~a" (getf entry :module) name)
                                                twice :test #'string=))
                                      (getf entry :names))
                         when names
                           collect (let ((copy (copy-list entry)))
                                     (setf (getf copy :names) names)
                                     copy))))
            (values (kept entry-points)
                    (kept declarations)
                    (append entry-problems declaration-problems
                            (loop for callee in twice
                                  collect (format nil "~a is declared by ~{~a~^ and ~}; neither applies it"
                                                  callee (reverse (gethash callee where))))))))))))

(defun parse-frameworks (contents)
  "A .loom/frameworks.yaml as (:definer-macros ... :route-callers ...).

Returns NIL for a file that does not parse. A repository whose declaration is
malformed gets no declarations rather than some of them: a partially applied
framework file would index half a tree's handlers and leave the reader to work
out which half."
  ;; RULE-0004, and this file broke it on the first attempt. cl-yaml defines
  ;; its conditions as direct subtypes of CONDITION rather than of ERROR, so a
  ;; handler naming ERROR alone lets a malformed document sail straight
  ;; through -- taking the watcher thread with it, which is the whole reason
  ;; the rule exists. PARSE-DOCUMENT names both for the same reason.
  (let ((parsed (handler-case (yaml:parse contents)
                  ((or error yaml.error:yaml-error) () nil))))
    (when (hash-table-p parsed)
      (multiple-value-bind (entry-points setting-declarations declaration-problems)
          (parse-callee-declarations parsed)
        (list :definer-macros
              (remove nil (mapcar #'parse-definer-macro
                                  (as-sequence (yaml-value parsed :|definer-macros|))))
              :route-callers
              (remove nil (mapcar #'parse-route-caller
                                  (as-sequence (yaml-value parsed :|route-callers|))))
              ;; Path prefixes whose documents describe a state the tree has left
              ;; behind. DES-0025 D6a.
              :archived-paths
              (mapcar #'string-downcase
                      (as-list-of-strings (yaml-value parsed :|archived-paths|)))
              ;; DES-0047. The fourth key, built the way :ROUTE-CALLERS is.
              :domains
              (remove nil (mapcar #'parse-domain
                                  (as-sequence (yaml-value parsed :|domains|))))
              ;; DES-0052. The fifth, and the only one this system does not read
              ;; itself: a block handed through to a document store's
              ;; constructor, which is the one thing that knows what its keys
              ;; mean. Parsed into a plist and not interpreted.
              :document-store
              (parse-declaration-block (yaml-value parsed :|document-store|))
              ;; DES-0054 D3. The sixth and seventh, and the problems found
              ;; reading them: an entry left out is only visible through them.
              :entry-points entry-points
              :setting-declarations setting-declarations
              :declaration-problems declaration-problems)))))

(defun domain-table (domains)
  "DOMAINS as a keyword-to-plist table, with :DEFAULT always present.

:DEFAULT is the domain a path falls in when no declared root is a prefix of it,
and it is in the table whether or not anybody declared it -- root \"\", no
aliases, bundler -- so DOMAIN-FOR-PATH always has somewhere to put a file and
no caller has to test for NIL.

`aliases-from' is resolved here by copying the named domain's map, and a chain
is refused rather than followed: an entry whose source itself uses
`aliases-from' contributes no aliases, and DOMAIN-PROBLEMS says so. One hop is
a convenience for two domains that share a map; a chain is a small language,
and a small language in a configuration file is how the file stops being
readable.

Entries the problems report rejects are still in the table, carrying what they
declared. Refusing to build them would make the report and the behaviour
disagree, and the report is what a reader acts on."
  (let ((table (make-hash-table :test #'eq)))
    (setf (gethash *default-domain* table)
          (append (cdr (assoc :bundler *resolution-presets*))
                  (list :name *default-domain* :root "" :resolution :bundler
                        :aliases '())))
    (dolist (domain domains)
      ;; The preset is expanded HERE, into the plist, so loom-graph receives
      ;; the extension list and the two flags as data and reads no
      ;; configuration -- DES-0025 D4, and PLAN-0050 S2's "the graph receives
      ;; the expansion as data in step 4". A graph that reached for
      ;; *RESOLUTION-PRESETS* would be a production dependency on the analyzer,
      ;; which is what S3 already had to undo once.
      (setf (gethash (getf domain :name) table)
            (append (cdr (assoc (or (getf domain :resolution) :bundler)
                                *resolution-presets*))
                    domain)))
    ;; Second pass: a copy needs every entry present, whatever order they came in.
    (maphash (lambda (name domain)
               (let ((from (getf domain :aliases-from)))
                 (when from
                   (let ((source (gethash from table)))
                     (setf (gethash name table)
                           (append (list :aliases
                                         (if (and source (null (getf source :aliases-from)))
                                             (getf source :aliases)
                                             '()))
                                   domain))))))
             table)
    table))

(defun domain-problems (domains)
  "Human-readable refusals for DOMAINS, each naming the entries it is about.

DES-0047 R3's six checkable refusals. The seventh -- a root under which no
indexed file lies -- needs the file list, which this function does not have and
the caller in loom-workspace does.

Reported rather than signalled, and the declaration is applied anyway. A
repository whose domains are half wrong still indexes; what it must not do is
index quietly. CON-0001 is the rule: the gap is recorded where somebody reads
it."
  (let ((problems '())
        (by-name (make-hash-table :test #'eq))
        (by-root (make-hash-table :test #'equal)))
    (dolist (domain domains)
      (let ((name (getf domain :name))
            (root (getf domain :root)))
        (when (eq name *default-domain*)
          (push (format nil "domain `~(~a~)' uses the reserved name -- it is what ~
a path falls in when no declared root matches, so a declaration cannot take it"
                        name)
                problems))
        (let ((seen (gethash name by-name)))
          (if seen
              (push (format nil "domains `~(~a~)' at roots ~s and ~s share one name"
                            name (getf seen :root) root)
                    problems)
              (setf (gethash name by-name) domain)))
        (let ((seen (gethash root by-root)))
          (if seen
              (push (format nil "domains `~(~a~)' and `~(~a~)' share the root ~s"
                            (getf seen :name) name root)
                    problems)
              (setf (gethash root by-root) domain)))
        (unless (getf domain :resolution)
          (push (format nil "domain `~(~a~)' declares resolution ~s, which is not ~
one of bundler, node-esm or commonjs"
                        name (getf domain :declared-resolution))
                problems))))
    ;; The two aliases-from refusals, once every name is known.
    (dolist (domain domains)
      (let ((from (getf domain :aliases-from)))
        (when from
          (let ((source (gethash from by-name)))
            (cond
              ((null source)
               (push (format nil "domain `~(~a~)' takes aliases from `~(~a~)', ~
which is not declared"
                             (getf domain :name) from)
                     problems))
              ((getf source :aliases-from)
               (push (format nil "domain `~(~a~)' takes aliases from `~(~a~)', ~
which takes its own from `~(~a~)' -- one hop is allowed and a chain is not"
                             (getf domain :name) from (getf source :aliases-from))
                     problems)))))))
    (nreverse problems)))

(defun read-frameworks (root)
  "ROOT's framework declarations, or NIL when it has none.

Absent is the normal case and is not an error: every repository Loom has ever
indexed until now has had none, and a tree with no unusual definers needs no
file."
  (let ((path (frameworks-path root)))
    (when (probe-file path)
      (let ((contents (handler-case
                          (with-open-file (in path :external-format :utf-8)
                            (let ((text (make-string (file-length in))))
                              (subseq text 0 (read-sequence text in))))
                        (error () nil))))
        (when contents (parse-frameworks contents))))))

(defun parse-json-text (text)
  "TEXT as a parsed JSON object, or NIL.

cl-yaml reads strict JSON, which is what jsconfig.json, package.json and
firebase.json are when they parse at all. A file carrying comments -- JSONC,
which some editors write -- does not parse here, and NIL is the honest answer: a
partial read of a configuration file is worse than none, because the half that
parsed looks like the whole. Takes contents rather than a path so the firebase
analyzer, which is handed contents and opens nothing, can call it (DES-0054 D4).

Names both ERROR and YAML.ERROR:YAML-ERROR: cl-yaml's conditions are direct
subtypes of CONDITION, which is RULE-0004."
  (handler-case
      (let ((parsed (yaml:parse text)))
        (and (hash-table-p parsed) parsed))
    ((or error yaml.error:yaml-error) () nil)))

(defun read-json-file (path)
  "PATH as a parsed JSON object, or NIL. PARSE-JSON-TEXT's rules apply."
  (when (probe-file path)
    (let ((text (handler-case
                    (with-open-file (in path :external-format :utf-8)
                      (let ((text (make-string (file-length in))))
                        (subseq text 0 (read-sequence text in))))
                  (error () nil))))
      (and text (parse-json-text text)))))

(defun preset-for-module-resolution (name)
  "The resolution preset a tsconfig `moduleResolution' names, or :BUNDLER."
  (cond ((null name) :bundler)
        ((string-equal name "bundler") :bundler)
        ((string-equal name "node16") :node-esm)
        ((string-equal name "nodenext") :node-esm)
        ((string-equal name "node") :commonjs)
        ((string-equal name "classic") :commonjs)
        (t :bundler)))

(defun trailing-wildcard-p (text)
  "True when TEXT ends in `/*'."
  (let ((n (length text)))
    (and (>= n 2) (string= "/*" text :start2 (- n 2)))))

(defun without-trailing-wildcard (text)
  (subseq text 0 (- (length text) 2)))

(defun translate-paths (paths)
  "A tsconfig `paths' table as (alias-list . problem-list).

Only one shape translates: \"key/*\": [\"target/*\"] -- one target, a trailing
wildcard on both sides. That is what every entry front-end writes looks like,
and it is the only form whose meaning as a prefix is unambiguous.

An entry with several targets or a wildcard anywhere but the end is reported
and not translated. CON-0001: a guess at which of three targets a key means
would be a fabricated fact in a file the author is about to confirm."
  (let ((aliases '()) (problems '()))
    (when (hash-table-p paths)
      (maphash
       (lambda (key value)
         (let* ((key (as-string key))
                (targets (as-list-of-strings value)))
           (cond
             ((null key))
             ((/= 1 (length targets))
              (push (format nil "~s names ~d targets; a domain alias names one"
                            key (length targets))
                    problems))
             ((not (trailing-wildcard-p key))
              (push (format nil "~s does not end in /*, so its prefix is not clear" key)
                    problems))
             ((not (trailing-wildcard-p (first targets)))
              (push (format nil "~s maps to ~s, which does not end in /*"
                            key (first targets))
                    problems))
             (t (push (cons (without-trailing-wildcard key)
                            (without-trailing-wildcard (first targets)))
                      aliases)))))
       paths))
    (cons (nreverse aliases) (nreverse problems))))

(defun propose-domains (root)
  "Domains ROOT's own configuration suggests, and what could not be read.

  (propose-domains root) => (values proposals problems)

Proposes, never decides. Every value here comes from a file the repository
already keeps for its own toolchain, and the one fact that matters most is
usually in neither: front-end's server/ resolves under node rules, and that is
stated in a runtime hook rather than in any config a parser can read. The
author supplies it. This exists to make the other thirty-two entries something
nobody types.

Two signals.

A jsconfig.json or tsconfig.json proposes one domain per `include' root, with
the preset its `moduleResolution' names and the aliases its `paths' translate
to. A nested package.json declaring no `type' proposes commonjs at its own
directory, which is Node's own default and the reason front-end's functions/
resolves differently from the rest of the tree."
  (let ((proposals '()) (problems '()))
    (dolist (config '("jsconfig.json" "tsconfig.json"))
      (let ((parsed (read-json-file (merge-pathnames config (pathname root)))))
        (when parsed
          (let* ((options (yaml-value parsed :|compilerOptions|))
                 (preset (preset-for-module-resolution
                          (and (hash-table-p options)
                               (as-string (yaml-value options :|moduleResolution|)))))
                 (translated (translate-paths
                              (and (hash-table-p options)
                                   (yaml-value options :|paths|))))
                 (includes (as-list-of-strings (yaml-value parsed :|include|))))
            (dolist (problem (cdr translated))
              (push (format nil "~a: ~a" config problem) problems))
            (dolist (include includes)
              ;; "src/**/*" names the root src/. The glob is the file set, and
              ;; a domain root is the prefix in front of it.
              (let* ((star (search "*" include))
                     (root-path (string-right-trim "/" (if star (subseq include 0 star) include))))
                (when (plusp (length root-path))
                  (push (list :name (intern (string-upcase root-path) :keyword)
                              :root (concatenate 'string root-path "/")
                              :resolution preset
                              :aliases (car translated)
                              :from config)
                        proposals))))))))
    (dolist (nested (directory (merge-pathnames "*/package.json" (pathname root))))
      (let ((parsed (read-json-file nested)))
        (when (and parsed (null (as-string (yaml-value parsed :|type|))))
          (let ((directory (car (last (pathname-directory nested)))))
            (push (list :name (intern (string-upcase directory) :keyword)
                        :root (concatenate 'string directory "/")
                        :resolution :commonjs
                        :aliases '()
                        :from "package.json")
                  proposals)))))
    (values (nreverse proposals) (nreverse problems))))

(defun frameworks-registry (frameworks &optional (base *macro-generators*))
  "BASE plus FRAMEWORKS' definer macros, as a fresh table.

Fresh, and that is the whole point of taking BASE as an argument rather than
pushing into it: two repositories watched by one service must not teach each
other their frameworks. game-server declaring DEFROUTE cannot make Loom's own
tree start looking for one, and a REGISTER-MACRO-GENERATOR call would have
exactly that effect -- it mutates a global, which is right for a fact about a
language and wrong for a fact about one repository."
  (let ((index (make-hash-table :test #'equal)))
    (when base
      (maphash (lambda (name entries) (setf (gethash name index) (copy-list entries)))
               base))
    (dolist (entry (getf frameworks :definer-macros))
      (push entry (gethash (getf entry :name) index)))
    index))

(defun frameworks-problems (root)
  "Why ROOT's frameworks file declared less than it looks like it does.

A list of human-readable strings, empty when the file is absent or wholly
usable. This exists because the failure mode of a declaration file is silence:
a mistyped `defines:' yields a tree that indexes exactly as it did before, and
nothing about that looks like an error. `status' reports these."
  (let ((path (frameworks-path root)))
    (when (probe-file path)
      (let ((frameworks (read-frameworks root)))
        (cond ((null frameworks)
               (list (format nil "~a does not parse as YAML" *frameworks-file*)))
              ;; Every key the parse returns, not the first three. A repository
              ;; with no unusual definers and no route conventions may still
              ;; declare an archive, domains or entry points, and calling that
              ;; file useless would be a false report about a file doing its job.
              ((notany (lambda (key) (getf frameworks key))
                       '(:definer-macros :route-callers :archived-paths :domains
                         :document-store :entry-points :setting-declarations))
               (cons (format nil "~a declares nothing usable: a definer-macros entry needs both macro: and defines:"
                             *frameworks-file*)
                     (getf frameworks :declaration-problems)))
              (t (getf frameworks :declaration-problems)))))))
