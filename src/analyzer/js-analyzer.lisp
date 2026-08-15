;;;; The JavaScript analyzer -- REQ-0024.
;;;;
;;;; The Lisp analyzer reads through Eclector because Common Lisp has a reader
;;;; and Loom could own a client for it. JavaScript has no equivalent inside
;;;; SBCL, and hand-rolling a parser for a language with ASI, JSX, destructuring
;;;; and template literals is a project rather than a file. So this analyzer
;;;; parses in a child process running acorn (REQ-0024 R2), which is SS9.2's
;;;; stated preference for subprocesses over FFI. cl-yaml remains the only FFI
;;;; dependency in the system.
;;;;
;;;; ------------------------------------------------------------------
;;;; The one place this strains the analyzer protocol, stated rather than
;;;; absorbed (REQ-0024 R1)
;;;; ------------------------------------------------------------------
;;;;
;;;; ANALYZE-FILE takes one path and its contents, and ANALYZER is documented as
;;;; configuration with no state. A child process is state, and starting one per
;;;; file would cost ~23ms of node startup 468 times over on ~/github/front-end
;;;; -- around eleven seconds added to a whole-tree pass measured in seconds.
;;;;
;;;; REQ-0024 predicted this would force a batching interface. It does not. The
;;;; child is a *server*, not a batch: one long-lived process, framed
;;;; request/reply, started on first use and reused for every file after. The
;;;; per-file interface survives untouched, nothing upstream of this file
;;;; changed, and the measured cost of the whole tree is 0.65s.
;;;;
;;;; What is genuinely new is that the process handle is global mutable state in
;;;; a system whose analyzers have none. It is a cache of a resource rather than
;;;; per-repository knowledge -- nothing about which repository is being indexed
;;;; is stored in it, so one registered instance still serves every repository,
;;;; which is the property the "no state" rule exists to protect. It is guarded
;;;; by a lock because the file monitor's thread and a console command can both
;;;; reach ANALYZE-FILE, and it is restarted rather than trusted if it dies.
;;;;
;;;; ------------------------------------------------------------------
;;;; Emitting properties, not edges
;;;; ------------------------------------------------------------------
;;;;
;;;; Like the Lisp analyzer, this one asserts no relationships at all. Every
;;;; cross-file name -- a callee, a superclass, an import specifier -- is
;;;; recorded as a property that LOOM-GRAPH re-derives edges from on every pass.
;;;; That is DEC-0003: a resolution pass that consumed its input could never
;;;; rebuild an edge a retract destroyed.

(in-package :loom-analyzer)

;;;; ==================================================================
;;;; Configuration
;;;; ==================================================================

(defparameter *node-program* "node"
  "The Node binary. A name rather than a path: node is commonly installed by a
version manager under the user's home, so PATH is the only thing that knows
where it is, and hard-coding /usr/bin/node would find the wrong one or none.")

(defparameter *js-extractor*
  ;; loom-analyzer.asd lives in src/analyzer/, so the tree root is two up.
  (asdf:system-relative-pathname :loom-analyzer "../../tools/js/extract.js")
  "The child script, with its vendored parser beside it.

Resolved against Loom's own source rather than against the repository being
indexed, which is the point: front-end has acorn in its node_modules and
depending on that would make Loom's ability to read a JavaScript tree
contingent on somebody having run `npm install' in it. A tree that has never
been installed, or one whose install is broken, is exactly when an index is
most useful.")

(defparameter *js-parse-timeout-seconds* 30
  "How long to wait for one file's reply before giving up on the child.

Bounds the whole exchange rather than the parse alone, because a child that has
stopped replying is indistinguishable from one parsing very slowly and both
need the same answer. On the measured tree the median reply is under a
millisecond, so this fires only when something is wrong.")

;;;; ==================================================================
;;;; The child process
;;;; ==================================================================

(defvar *js-child* nil
  "The live extractor process, or NIL. See this file's header for why an
analyzer may hold one.")

(defvar *js-child-lock* (bt:make-lock "loom-js-extractor")
  "Serialises both the request/reply exchange and the process's lifecycle. The
exchange has to be serialised regardless of the lifecycle: two threads writing
frames into one stdin would interleave their bodies, and neither could tell
which reply was its own.")

(defvar *js-unavailable-reason* nil
  "Why the toolchain could not be started, or NIL.

REQ-0024 R2, on REQ-0018 R2's precedent: a missing toolchain is a recorded
absence rather than a failure. A tree analyzed without node still indexes --
every file becomes a :FILE entity carrying this string -- so the reader sees a
gap they can name instead of an empty result they cannot explain.")

(defun js-child-alive-p ()
  (and *js-child* (uiop:process-alive-p *js-child*)))

(defun start-js-child ()
  "Launch the extractor, or record why it could not be launched. Returns the
process or NIL."
  (handler-case
      (let ((process (uiop:launch-program
                      (list *node-program* (namestring *js-extractor*))
                      :input :stream :output :stream :error-output nil)))
        (setf *js-unavailable-reason* nil)
        (setf *js-child* process))
    (error (condition)
      ;; No node on PATH is the ordinary case here and must not signal: a
      ;; developer indexing a mixed tree on a machine without node gets their
      ;; Lisp answers and a note about the JavaScript.
      (setf *js-child* nil)
      (setf *js-unavailable-reason*
            (format nil "cannot run ~a: ~a" *node-program* condition))
      nil)))

(defun ensure-js-child ()
  "The live child, starting it if necessary. NIL when the toolchain is absent.

Called with *JS-CHILD-LOCK* held."
  (unless (js-child-alive-p)
    (when *js-child*
      ;; A child that died mid-tree leaves its stdin buffered and its reply
      ;; stream half-read. Close before relaunching so the next exchange starts
      ;; from a clean pair of streams rather than inheriting a partial frame.
      (ignore-errors (uiop:close-streams *js-child*))
      (setf *js-child* nil))
    (start-js-child))
  *js-child*)

(defun stop-js-child ()
  "Shut the extractor down. Safe to call when none is running.

Nothing in the indexing path calls this -- the child is meant to outlive a
tree pass -- but a test that has just proved the restart behaviour needs to put
the world back, and a long-lived service reindexing a tree that no longer has
any JavaScript in it should not keep a node process alive forever."
  (bt:with-lock-held (*js-child-lock*)
    (when *js-child*
      (ignore-errors (uiop:close-streams *js-child*))
      (ignore-errors (uiop:terminate-process *js-child* :urgent t))
      (setf *js-child* nil))))

(defmacro with-timeout-or-nil ((seconds) &body body)
  "BODY's value, or NIL if it took longer than SECONDS.

SB-EXT:WITH-TIMEOUT signals rather than returning, and the caller wants the
distinction between `no answer' and `an answer' rather than a condition to
re-handle. On an implementation without it the body simply runs unbounded,
which is worse than a timeout and better than not compiling.

Defined above its one caller because a macro used before it is defined is
expanded as a function call, and the timeout would silently not exist."
  #+sbcl `(handler-case (sb-ext:with-timeout ,seconds ,@body)
            (sb-ext:timeout () nil))
  #-sbcl `(progn ,seconds ,@body))

(defun utf8-byte-length (string)
  "How many bytes STRING occupies as UTF-8.

The frame header counts bytes and the stream is character-oriented, so this is
the one number the two ends have to agree on: a file with any non-ASCII in it
makes the character count and the byte count different, and a wrong header
would desynchronise every frame after it rather than just this one."
  #+sbcl (length (sb-ext:string-to-octets string :external-format :utf-8))
  #-sbcl (loop for character across string
               sum (let ((code (char-code character)))
                     (cond ((< code #x80) 1) ((< code #x800) 2)
                           ((< code #x10000) 3) (t 4)))))

(defun write-frame (process path contents)
  "Write one length-prefixed request. See tools/js/extract.js for the frame."
  (let ((stream (uiop:process-info-input process)))
    (format stream "~a~%~d~%" path (utf8-byte-length contents))
    (write-string contents stream)
    (finish-output stream)))

(defun read-reply (process)
  "One line of JSON from the child, decoded. NIL if the stream closed."
  (let ((line (read-line (uiop:process-info-output process) nil nil)))
    (when line
      (json:decode-json-from-string line))))

(defun parse-javascript (path contents)
  "Two values: the child's decoded reply for PATH, and a reason string when
there is none.

One retry, and only one, and only for a child that was not alive. A parse that
fails is the child's business to report in its reply (R3) and is not retried; a
child that has *died* is a different thing, and the next file after it should
not be lost to a process that is already gone. Retrying more than once would
turn a node that cannot start into a loop across every file in the tree."
  (bt:with-lock-held (*js-child-lock*)
    (loop for attempt from 0 below 2
          for process = (ensure-js-child)
          do (unless process
               (return (values nil *js-unavailable-reason*)))
             (handler-case
                 (let ((reply (with-timeout-or-nil (*js-parse-timeout-seconds*)
                                (write-frame process path contents)
                                (read-reply process))))
                   (if reply
                       (return (values reply nil))
                       ;; No reply: the child died, or took too long. Drop it so
                       ;; ENSURE-JS-CHILD relaunches on the next pass, and let
                       ;; the loop have its one retry.
                       (progn
                         (ignore-errors (uiop:close-streams process))
                         (ignore-errors (uiop:terminate-process process :urgent t))
                         (setf *js-child* nil)
                         (when (= attempt 1)
                           (return (values nil "javascript extractor stopped responding"))))))
               (error (condition)
                 (ignore-errors (uiop:close-streams process))
                 (setf *js-child* nil)
                 (when (= attempt 1)
                   (return (values nil (princ-to-string condition)))))))))

;;;; ==================================================================
;;;; Reading the reply
;;;; ==================================================================

(defun jget (alist key)
  (cdr (assoc key alist)))

(defun jlist (alist key)
  "KEY's value as a list. cl-json gives an absent key and an empty array the
same NIL, which is the right answer for every list this file reads."
  (let ((value (jget alist key)))
    (if (listp value) value (list value))))

;;;; ==================================================================
;;;; Decisions this analyzer makes, and REQ-0024 names each one
;;;; ==================================================================

(defun js-system-for-path (path)
  "The :SYSTEM for a JavaScript file -- REQ-0024 R5, decided rather than
inherited.

The path convention, DEFAULT-SYSTEM-FOR-PATH, which gives src/domain :DOMAIN
and src/data-api :DATA-API. The alternative the language offers is the module,
and the module is the file: keying :SYSTEM on it would make every one of 468
files its own system, which is not a grouping at all -- the layering rules
would have 468 systems and nothing to say about any of them, and `structure'
would report a flat list as long as the tree.

So this is the first language where the strongest construct the language has is
weaker than the path convention, and the convention wins. It is a real cost and
worth naming: src/domain is a directory somebody chose, and nothing in the
source asserts that a file in it belongs there. A Lisp file's IN-PACKAGE is
evidence; a directory is a habit."
  (default-system-for-path path))

(defun js-call-names (definition)
  "Every name this definition reaches -- ordinary calls and JSX usage together.

REQ-0024 R4. `<Thing />' contributes THING to :CALL-NAMES exactly as `thing()'
would, so RESOLVE-CALLS turns it into a :CALLS edge with no new relationship
type and no change to any resolution pass. The requirement is blunt about the
stakes: a component tree in which `<Thing />' produces no edge would leave
`impact' answering nothing useful about most of a front-end, and a front-end is
mostly components.

Rendering is not calling, and the two are not merged blindly -- :JSX-NAMES
below keeps the distinction available on the entity for anything that later
wants to ask `what renders this' as opposed to `what calls this'. What is
rejected is spending a relationship type on it now: a new type would have to be
threaded through impact's propagation, `describe's grouping and the JSON
encoders to answer a question nobody has yet asked, and DES-0014 priced that
same uniformity argument and refused it for the same reason.

Host elements -- <div>, <span> -- never arrive here; the child drops them,
since a lowercase JSX name resolves to nothing in any tree and would be
noise in every caller's call list."
  (remove-duplicates
   (append (jlist definition :calls) (jlist definition :jsx))
   :test #'string=))

;;;; ==================================================================
;;;; Reconciling same-key definitions (CON-0005, REQ-0024 R6)
;;;; ==================================================================

(defun reconcile-definitions (definitions)
  "DEFINITIONS with same-key collisions resolved, in JavaScript's semantics.

ANALYZE-FILE must assert each natural key at most once per file, and the key
here is (:file :name). JavaScript replaces rather than merges: a second `function
foo' in one module is what `foo' means afterwards and the first is dead code,
which is Common Lisp's rule and not TypeScript's -- declaration merging would
have to union these instead, and REQ-0024 is explicit that TypeScript is not
what this analyzer claims.

So the last definition in source order wins, and the ones it superseded are
recorded as line ranges in :SHADOWED-DEFINITIONS rather than dropped silently,
exactly as SUPERSEDE-SHADOWED-DEFINITIONS does for Lisp. A reader who wants the
dead text opens the file at those lines; the graph does not carry an entity for
code that does not survive loading.

Anonymous definitions -- an unnamed default export -- carry no name and cannot
collide, so they pass through untouched."
  (let ((by-key (make-hash-table :test #'equal))
        (order '()))
    (dolist (definition definitions)
      (let ((name (jget definition :name)))
        (if (null name)
            (push definition order)
            (let ((key (list (jget definition :kind) name)))
              (multiple-value-bind (previous foundp) (gethash key by-key)
                (when foundp
                  (setf definition
                        (acons :shadowed
                               (append (jget previous :shadowed)
                                       (list (format nil "~a-~a"
                                                     (jget previous :start-line)
                                                     (jget previous :end-line))))
                               definition)))
                (setf (gethash key by-key) definition)
                (unless foundp (push key order)))))))
    (nreverse
     (mapcar (lambda (item)
               (if (listp item) (or (gethash item by-key) item) item))
             order))))

;;;; ==================================================================
;;;; Entities
;;;; ==================================================================

(defun js-definition-name (definition path)
  "The entity name for DEFINITION, or NIL if it has none and cannot be given
one.

REQ-0024's fourth open question: a default export has no name at the definition
site while the importing module names it whatever it likes, so the exported
name cannot be the natural key. The answer taken here is the module's own base
name -- src/components/Card.jsx becomes CARD -- because that is both stable and
what importers overwhelmingly do call it by convention.

The requirement's own suggestion, the full path, is rejected for a concrete
reason rather than a stylistic one: it would make the entity's name a string
with slashes in it, and `find' and `context' both tokenise names to rank them,
so a path-named entity ranks against queries by its directories as much as by
itself."
  (or (jget definition :name)
      (and (jget definition :default)
           (pathname-name (pathname path)))))

(defun make-js-file-entity (path contents reply reason)
  "The :FILE entity, which is asserted whether or not anything parsed.

Damage lands in :SUPPRESSED-REGIONS rather than :RECOVERED-REGIONS, and the
choice is not cosmetic. :RECOVERED-REGIONS means the reader repaired something
and kept going, which is what Eclector does for Lisp; acorn does not recover --
it stops at the first error -- so what is true here is DES-0013's other case:
these lines would have defined things and did not. The region runs from the
error to the end of the file because that is genuinely what is unknown, and
claiming a tighter range would be a fabricated fact of exactly CON-0001's kind.

:ANALYSIS-FAILED-P carries both a parse error and an absent toolchain, since
from a reader's point of view they are the same fact -- this file's definitions
are not in the index -- and :ANALYSIS-ERROR is what tells them apart."
  (let ((damage (jget reply :damage))
        (sources (remove nil (mapcar (lambda (import) (jget import :source))
                                     (jlist reply :imports)))))
    (make-instance 'file-entity
                   :name path
                   :origin-file path
                   :properties
                   (properties-table
                    (append
                     (list :path path
                           :language :javascript
                           :system (js-system-for-path path)
                           :line-count (or (jget reply :line-count)
                                           (line-count contents)))
                     ;; Recorded, not resolved -- see the property's own
                     ;; documentation and REQ-0024's WHAT THIS IS NOT.
                     (when sources (list :import-sources sources))
                     (when (or reason damage)
                       (list :analysis-failed-p t
                             :analysis-error (or reason
                                                 (jget damage :message)
                                                 (jget reply :error))))
                     (when damage
                       (list :suppressed-regions
                             (list (list :reason "javascript parse error"
                                         :start-line (jget damage :start-line)
                                         :end-line (jget damage :end-line))))))))))

(defun make-js-definition-entity (definition path system)
  "One entity for one definition, or NIL when it cannot be named."
  (let* ((kind (jget definition :kind))
         (name (js-definition-name definition path))
         (calls (js-call-names definition))
         (jsx (jlist definition :jsx))
         (shadowed (jget definition :shadowed))
         (common (list :file path
                       :start-line (jget definition :start-line)
                       :end-line (jget definition :end-line)
                       :language :javascript
                       :system system)))
    (when name
      (flet ((properties (&rest extra)
               ;; :CALL-NAMES only where a :CALLS edge may legally originate.
               ;; The relationship's :FROM is (:function :method :test
               ;; :call-site), so writing call names onto a :VARIABLE or a
               ;; :CLASS would ask RESOLVE-CALLS for an edge the ontology
               ;; forbids. That costs the calls in a module-level initialiser --
               ;; `const emitter = mitt()' -- and the loss is real rather than
               ;; theoretical: 782 of front-end's 3486 definitions are
               ;; variables. DES-0014 already built the right answer for
               ;; exactly this position, a :CALL-SITE entity for a designator
               ;; in an initform whose enclosing form is not a legal source
               ;; (BUG-0017), and minting them here is the follow-on this
               ;; analyzer does not yet do. Dropping the names is a recorded
               ;; gap; asserting an illegal edge would be a fabrication.
               ;; EXTRA is appended whole rather than filtered: it is a plist,
               ;; and dropping its NIL *values* would pair each surviving key
               ;; with the next key along. A NIL here is a real answer -- not
               ;; exported, no superclass -- and the property declarations
               ;; default to exactly that.
               (let ((callable (member kind '("function" "method") :test #'string=)))
                 (properties-table
                  (append common
                          (when (and callable calls) (list :call-names calls))
                          (when (and callable jsx)
                            (list :jsx-names (remove-duplicates jsx :test #'string=)))
                          (when shadowed (list :shadowed-definitions shadowed))
                          extra)))))
        (cond
          ((string= kind "function")
           (make-instance 'function-entity
                          :name name :origin-file path
                          :properties (properties
                                       :arguments (jlist definition :params)
                                       :exported-p (and (jget definition :exported) t))))
          ((string= kind "method")
           (make-instance 'method-entity
                          :name name :origin-file path
                          :properties (properties
                                       :arguments (jlist definition :params))))
          ((string= kind "class")
           (make-instance 'class-entity
                          :name name :origin-file path
                          :properties (properties
                                       :superclass-names
                                       (let ((super (jget definition :superclass)))
                                         (when super (list super)))
                                       :exported-p (and (jget definition :exported) t))))
          ((string= kind "variable")
           (make-instance 'variable-entity
                          :name name :origin-file path
                          :properties (properties
                                       :exported-p (and (jget definition :exported) t))))
          (t nil))))))

;;;; ==================================================================
;;;; The analyzer
;;;; ==================================================================

(defclass js-analyzer (analyzer)
  ()
  (:default-initargs :language :javascript
                     :file-types '("js" "jsx" "mjs" "cjs"))
  (:documentation "Parses JavaScript and JSX through acorn in a child process.

Not TypeScript. `.ts' and `.tsx' are deliberately absent from the extensions
above even though acorn's ecosystem can be made to accept them: REQ-0024's WHAT
THIS IS NOT is explicit that a parser accepting TS by accident would produce
entities whose properties nothing in the ontology models, and front-end's one
.ts file is a vite config."))

(defparameter *vendored-directories* '("vendor" "node_modules" "bower_components")
  "Directory names whose contents are somebody else's code.")

(defun vendored-path-p (path)
  "True when PATH lies under a directory holding third-party code.

BUG-0024 made a vendored tree invisible by asking git what it ignores, and that
is the better instrument wherever it applies: it needs no list and it is the
project's own answer. It cannot apply here. Loom vendors acorn under
tools/js/vendor/ and that code has to be *committed* -- the whole point of
carrying it is that analyzing a JavaScript tree does not depend on anyone
having run `npm install' -- so git is right not to ignore it and the question
of whether Loom should index it is a different question from whether git should
track it.

Left unexcluded it is not a small cost. 528K of acorn defines several thousand
functions whose names collide with Loom's own, which turned previously
unambiguous call names ambiguous and minted 30 extra :CALL-SITE entities in
Loom's own index -- caught by
A-CALL-SITE-EXISTS-ONLY-WHERE-A-CALLS-EDGE-FROM-A-DEFINITION-IS-IMPOSSIBLE,
whose DES-0014 ceiling exists for exactly that drift.

A name list is a convention rather than a fact, which is what BUG-0024's
approach avoided and REQ-0028 removed from the markdown analyzer. It is
accepted here for the reason REQ-0028 kept its own two exclusions: this tests
what the code *is* rather than where it sits. A file under vendor/ is not
written by this project, so no answer about this project should cite it -- and
unlike `docs/', these three names are near-universal in the JavaScript
ecosystem rather than one tree's habit."
  (member-if (lambda (segment)
               (and (stringp segment)
                    (member segment *vendored-directories* :test #'string=)))
             (rest (pathname-directory (pathname path)))))

(defmethod analyzer-handles-p ((analyzer js-analyzer) path)
  (and (call-next-method) (not (vendored-path-p path))))

(defmethod analyze-file ((analyzer js-analyzer) path contents workspace-id)
  "Ontology operations for one JavaScript file.

Always a :FILE entity, whatever happened -- REQ-0024 R2 and R3 both turn on
this. A file whose parse failed, and a file analyzed on a machine with no node
at all, are both indexed with the reason recorded on them. An unreadable file
that vanished from the index entirely would be a silent gap, and CON-0001's
whole argument is that a recorded gap beats both a fabrication and a silence."
  (declare (ignore analyzer))
  (multiple-value-bind (reply reason) (parse-javascript path contents)
    (let ((system (js-system-for-path path)))
      (list* (retract-file path workspace-id)
             (assert-entity (make-js-file-entity path contents reply reason)
                            workspace-id)
             (remove nil
                     (mapcar (lambda (definition)
                               (let ((entity (make-js-definition-entity
                                              definition path system)))
                                 (when entity (assert-entity entity workspace-id))))
                             (reconcile-definitions (jlist reply :definitions))))))))

;;;; The one registered instance. Stateless in the sense that matters: it holds
;;;; no repository, so one serves every tree. The child process it reaches is a
;;;; module-level resource, not a slot -- see this file's header.
(register-analyzer (make-instance 'js-analyzer))
