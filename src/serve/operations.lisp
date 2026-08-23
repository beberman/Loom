;;;; The read- and write-tier operations.
;;;;
;;;; Every entry here is a thin call onto a function console.lisp already
;;;; calls, stopping one step short of console.lisp's formatting. Nothing in
;;;; this file renders; DES-0005's argument is that the data is already
;;;; structured and only the console's last step is prose, so a second
;;;; rendering step would be a second thing to keep in agreement with the first.
;;;;
;;;; Repository selection is explicit and never guessed. CURRENT-REPOSITORY's
;;;; convenience -- imply the one watched repository, refuse to guess among
;;;; several -- is right for a human who forgot to type a name and wrong for a
;;;; program, which either knows which repository it means or should ask first.
;;;; REQUIRE-REPOSITORY is where that is enforced once rather than eleven times.

(in-package :loom-serve)

;;;; ==================================================================
;;;; Selecting what to operate on
;;;; ==================================================================

(defvar *workspace-registry-lock* (bt:make-recursive-lock "loom-serve-workspace-registry")
  "Serializes the two operations that add to or remove from *REPOSITORIES*.

PLAN-0005 FINDING 2. src/workspace/workspace.lisp:52 declares *REPOSITORIES* as
a bare DEFVAR; line 424 pushes onto it and line 446 SETFs it to a REMOVE, and
neither PUSH nor SETF is atomic on SBCL. WITH-REPOSITORY-LOCK (line 40) cannot
cover either: it takes its lock out of a repository struct, and at line 424 the
struct exists but nothing else can name it, while at line 446 the point of the
operation is that it stops existing. Under the console this can never fire --
one stdin loop dispatches one line at a time, so no two `watch` calls overlap.
Under N Hunchentoot worker threads two concurrent watches of different paths
can lose a registration and two concurrent unwatches can resurrect one.

The lock lives here and not in loom-workspace because REQ-0008 forbids editing
that system, and this is the caller that created the need.

Acquisition order, stated because DES-0004 states one and a lock added above
it is only safe if it never inverts: this lock is always acquired *before* any
repository's analysis-lock and never from inside one. The only things called
while holding it are the WATCH-REPOSITORY and UNWATCH-REPOSITORY calls it
exists to serialize, and both take a repository lock beneath it, never above.
Recursive for the same reason DES-0004's is: a re-entry must not self-deadlock.")

(defun require-repository (designator)
  "The repository DESIGNATOR names, or a malformed request naming it.

No default, no fallback to the sole watched repository, no CURRENT-REPOSITORY.
DES-0006 is explicit that an operation invoked without a designator is a
malformed request rather than an ambiguous one to be resolved by guessing."
  (cond ((null designator)
         (error 'malformed-request
                :message "This operation needs the name of a repository. Ask status for the list."))
        ((find-repository designator))
        (t (error 'malformed-request
                  :message (format nil "No repository named ~a. Ask status for the list."
                                   designator)))))

(defun resolve-entity (graph term)
  "The entity TERM names: an id if it is one, otherwise the best name match.

Re-implemented here rather than reached for. console.lisp has a function of
this name and shape, and calling it would make loom-serve depend on
loom-process, which DES-0006 R5 forbids and PLAN-0005's RISKS names as one of
the three ways that dependency arrives looking reasonable. CURRENT-REPOSITORY,
which sits beside it in that file, is deliberately *not* reproduced: refusing
to guess which repository a program meant is the point."
  (or (get-entity graph term)
      ;; BEST-NAME-MATCH rather than SEARCH-ENTITIES with a limit of one
      ;; (BUG-0032). The two differ only where a file and a definition match a
      ;; name equally well, and there the caller of *this* function wants the
      ;; definition: `describe' and `impact' both ask questions a container
      ;; answers badly. `find' still calls SEARCH-ENTITIES and still lists the
      ;; file first.
      (let ((hit (best-name-match graph term)))
        (when hit (get-entity graph (getf hit :id))))
      (error 'unknown-entity
             :message (format nil "Nothing in the index matches ~s." term))))

(defun repository-view (designator)
  "The graph REQUIRE-REPOSITORY's answer holds."
  (repository-graph (require-repository designator)))

;;;; ==================================================================
;;;; Reading a wire value -- one predicate and one converter per type
;;;; ==================================================================
;;;;
;;;; Both skins reach the same entry with different types: an HTTP query
;;;; parameter is always a string, a JSON body carries a real number or a real
;;;; boolean, and an entry should not have to know which arrived.
;;;;
;;;; Split into a predicate, a converter and a request-level coercer because
;;;; the three answer different questions and a caller usually wants only one
;;;; of them. IS-INTEGER-P asks whether a value can be read. TO-INTEGER reads
;;;; it. REQUEST-INTEGER reads it or refuses the request, which is the one an
;;;; operation entry wants and the only one that knows what to call the
;;;; argument in a message.
;;;;
;;;; game-server BUG-0001 is what this shape is answering. That tree decodes an
;;;; integer by signalling on junk and a boolean by returning false on junk,
;;;; three lines apart in one function, and has three exported predicates
;;;; disagreeing about what a number is. The lesson taken here is not that
;;;; strict beats permissive -- it is that the policy must be stated once and
;;;; shared, because the two branches there were written by the same author on
;;;; the same day and still disagreed.

(defparameter *true-tokens* '("true" "t" "1" "yes" "on")
  "Spellings of true a caller may send. Compared case-insensitively.

Wider than a JSON boolean because a query string has no booleans: `?source=1'
and `?source=true' are both ordinary, and refusing one would make the REST
surface stricter than the MCP one for no reason a caller could discover.")

(defparameter *false-tokens* '("false" "nil" "0" "no" "off")
  "Spellings of false. An explicit false is a request and not junk, so it is
enumerated rather than left to fall through -- the whole point of BUG-0031's
sibling defect is that unreadable input must not arrive at the same answer an
author deliberately asked for.")

(defun is-integer-p (value)
  "True when VALUE can be read as an integer -- already one, or a string
spelling one exactly. A partial parse is not an integer: \"3x\" is a question
about intent and REV-0001 finding 4 is why it is not answered as 3."
  (typecase value
    (integer t)
    (string (multiple-value-bind (n end) (parse-integer value :junk-allowed t)
              (and n (= end (length value)) t)))
    (t nil)))

(defun to-integer (value)
  "VALUE as an integer, or NIL when it is not one. IS-INTEGER-P is the test."
  (typecase value
    (integer value)
    (string (multiple-value-bind (n end) (parse-integer value :junk-allowed t)
              (and n (= end (length value)) n)))
    (t nil)))

(defun is-boolean-p (value)
  "True when VALUE can be read as a boolean.

T counts, and so does every spelling in *TRUE-TOKENS* and *FALSE-TOKENS*. NIL
does not: an absent argument and an argument spelled `false' are different
requests, and every caller here distinguishes them by testing for NIL first."
  (or (eq value t)
      (and (member value '(:true :false)) t)
      (and (stringp value)
           (or (member value *true-tokens* :test #'string-equal)
               (member value *false-tokens* :test #'string-equal))
           t)))

(defun to-boolean (value)
  "VALUE as a boolean, and a second value saying whether it could be read.

Two values because one cannot carry the answer: NIL is both a legitimate false
and the only thing an unreadable value could return, and collapsing them is
precisely game-server BUG-0001's silent misread. A caller that ignores the
second value has written the bug that report is about."
  (cond ((eq value t) (values t t))
        ((eq value :true) (values t t))
        ((eq value :false) (values nil t))
        ((and (stringp value) (member value *true-tokens* :test #'string-equal))
         (values t t))
        ((and (stringp value) (member value *false-tokens* :test #'string-equal))
         (values nil t))
        (t (values nil nil))))

(defun request-integer (value what)
  "VALUE as a non-negative integer, NIL when absent, or a malformed request.

Junk is refused rather than truncated, which is console.lisp's RESOLVE-COUNT
answer and REV-0001 finding 4's reason -- `depth 3x' meaning 3 is a guess about
intent, and a wrong guess about a bound is invisible in the output, because the
report is simply smaller than the caller asked for."
  (cond ((null value) nil)
        ((and (is-integer-p value) (not (minusp (to-integer value))))
         (to-integer value))
        (t (error 'malformed-request
                  :message (format nil "~a must be a non-negative integer, not ~s."
                                   what value)))))

(defun request-boolean (value what)
  "VALUE as a flag, NIL when absent, or a malformed request.

REQUEST-INTEGER's policy applied to the other shape the skins disagree about,
and applied deliberately rather than by coincidence: junk is refused, not read
as false.

That asymmetry is the whole point and game-server BUG-0001 is the counterexample
that argues it. A caller who sent `source=yep' asked for something; answering as
though they had asked for nothing returns a smaller answer than they wanted with
nothing in it saying so. It is REQUEST-INTEGER's invisible-wrong-bound failure
in the one place it would be quieter still, because a suppressed body reads
exactly like a definition that has none."
  (if (null value)
      nil
      (multiple-value-bind (result readable) (to-boolean value)
        (unless readable
          (error 'malformed-request
                 :message (format nil "~a must be true or false, not ~s."
                                  what value)))
        result)))

;;;; ==================================================================
;;;; Read tier (R2's seven names)
;;;; ==================================================================

(defparameter *find-limit* 20
  "How many hits :FIND returns when the caller does not say.
The console's own cap, so the two answer the same question the same way.")

;; ENTITY-TYPE rather than TYPE, and the argument a caller sends is named to
;; match. TYPE is an external symbol of COMMON-LISP, and SBCL's package lock
;; refuses to bind one as a local variable -- a compile-time failure, not a
;; style question.
(define-operation :find :read (repository term (entity-type) (limit))
    "Where something is defined."
  ;; Wrapped under :ENTITIES rather than returned as a bare list, so that every
  ;; operation in this system answers with a plist and every JSON response is
  ;; therefore an object. A bare list would also make an empty result encode as
  ;; null instead of [], which is the ambiguity *ARRAY-VALUED-KEYS* exists to
  ;; prevent and which a top-level value has no key to be rescued by.
  (multiple-value-bind (entities total)
      (search-entities (repository-view repository)
                       :name term
                       :type (and entity-type
                                  (intern (string-upcase (string entity-type)) :keyword))
                       :limit (or (request-integer limit "limit") *find-limit*))
    ;; BUG-0002. :TOTAL and :TRUNCATED alongside the rows, because a caller
    ;; that received the limit and nothing else cannot tell a complete answer
    ;; from a cut one -- and an agent asking how many of a type exist gets a
    ;; number rather than a page of rows to count.
    (list :entities entities
          :total total
          :truncated (> total (length entities)))))

(define-operation :describe :read (repository term (source))
    "Full detail for one entity, with its neighbours grouped by edge type. \
Pass source=true for the definition's text."
  ;; REQ-0031 R1 and R2. The optional SOURCE is what makes this available on
  ;; REST and MCP at once: loom-rest walks ARG-SHAPE for routes and loom-mcp
  ;; walks it for tools/list, so declaring the argument declares both surfaces
  ;; and neither file is edited. DES-0006 R5's property, exercised.
  (let* ((repository-struct (require-repository repository))
         (graph (repository-graph repository-struct))
         (entity (resolve-entity graph term))
         (detail (describe-entity graph (id entity))))
    (if (request-boolean source "source")
        ;; Appended under its own key rather than folded into :PROPERTIES: the
        ;; text is not a fact the analyzer asserted about the entity, it is a
        ;; read of a file performed now, and its :STATUS is about that read.
        (append detail (list :source (definition-source repository-struct (id entity))))
        detail)))

(define-operation :impact :read (repository term (depth))
    "What may need attention if this changes, with paths and depths."
  (let ((graph (repository-view repository)))
    (impact-report graph (id (resolve-entity graph term))
                   :max-depth (or (request-integer depth "depth")
                                  *default-impact-depth*))))

(define-operation :context :read (repository task)
    "A budgeted context bundle for a task: what to know before editing."
  ;; BUILD-CONTEXT and no RENDER-CONTEXT. The rendering step is what turns the
  ;; bundle into the text a console prints, and a program wants the bundle.
  ;; SOURCE-FN rather than a call from inside BUILD-CONTEXT: DEFINITION-SOURCE
  ;; is loom-workspace's because it needs REPOSITORY-ROOT, and loom-knowledge
  ;; cannot reach up there (DES-0027 D1). This entry has the repository, so the
  ;; fetch is passed in and the tier logic stays where the bundle is built.
  (let ((repo (require-repository repository)))
    (let ((started (get-internal-real-time)))
      (multiple-value-bind (bundle instrumentation)
          ;; DEC-0006. Bound here rather than read inside BUILD-CONTEXT for the
          ;; reason the SOURCE-FN comment above gives: loom-knowledge is handed
          ;; a graph and never learns which repository it belongs to, and this
          ;; entry has the repository. REPOSITORY-VECTORS is NIL until somebody
          ;; builds a store, so on an ordinary tree both bindings are NIL and
          ;; SEED-ENTITIES takes the path it has taken since S3.
          (let ((loom-knowledge:*context-vector-store* (repository-vectors repo))
                (loom-knowledge:*context-embedder* (current-embedder)))
            (build-context (repository-graph repo) task
                           :source-fn (lambda (id) (definition-source repo id))))
        ;; REQ-0036 R1 and R8. The record is additive: the identifier is one
        ;; more key on a bundle a caller already reads, and with
        ;; *CONTEXT-LOG-DIRECTORY* NIL -- the default -- RECORD-CONTEXT-CALL
        ;; returns NIL and writes nothing, so this is what it was before.
        ;;
        ;; The latency is measured around the build rather than reported by it,
        ;; because what a judgement needs is what the caller waited for.
        (let ((id (record-context-call
                   repo bundle instrumentation
                   :seconds (/ (float (- (get-internal-real-time) started))
                               internal-time-units-per-second))))
          (if id (append bundle (list :record id)) bundle))))))

(define-operation :structure :read (repository)
    "Systems, protocols, entry points and hubs, derived from the index."
  ;; REQ-0021 R5, and the shape matters more than usual: DES-0022 D4 requires
  ;; that the console printer and the document generator walk the same plist,
  ;; so this returns the report and renders nothing. An init script asking for
  ;; a tree's structure over REST gets the data a human sees formatted, not a
  ;; second, prose-shaped answer it would have to parse.
  (let ((watched (require-repository repository)))
    (multiple-value-bind (commit reason) (repository-commit watched)
      (structure-report (repository-graph watched)
                        :commit commit
                        :commit-reason reason
                        :repository (repository-name watched)))))

(define-operation :drift :read (repository)
    "Where the prose and the index disagree. Candidates for review, not findings."
  (let ((watched (require-repository repository)))
    (prose-report (repository-graph watched) :repository (repository-name watched))))

(define-operation :status :read ((repository))
    "Index size, watcher health, unresolved references, rule violations."
  ;; The one operation with no designator requirement, because with none it is
  ;; the repository-discovery call a caller makes once before naming one to
  ;; everything else. Two shapes on purpose: a named repository answers with
  ;; its own status plist, and no name answers with the list under
  ;; :REPOSITORIES, which is what tells an empty answer from a single one.
  (if repository
      (repository-status (require-repository repository))
      (list :repositories (mapcar #'repository-status (all-repositories)))))

;;;; ------------------------------------------------------------------
;;;; check and rules: the assembly DES-0006 accepts as duplication
;;;;
;;;; CONSEQUENCES records this as a small, named duplication rather than
;;;; hiding it: console.lisp's `check` and `rules` commands already make this
;;;; same handful of loom-graph calls, as formatting rather than as data,
;;;; because no single loom-knowledge function bundles them and adding one
;;;; would edit loom-knowledge, which REQ-0008 excludes.
;;;;
;;;; This is the one place in this system where a future document adding
;;;; CHECK-REPORT and RULES-REPORT to loom-knowledge would delete code: both
;;;; this file and console.lisp would call it, and neither's external behaviour
;;;; would change.
;;;; ------------------------------------------------------------------

(defun violation-summary (violation)
  (list :rule-id (getp violation :rule-id)
        :severity (getp violation :severity)
        :detail (getp violation :detail)))

(defun rule-summary (rule)
  (list :doc-id (getp rule :doc-id)
        :title (getp rule :title)
        :severity (getp rule :severity)
        ;; The console prints "[prose only]" here. The same fact, as a boolean
        ;; a program can branch on.
        :enforceable (and (enforceable-rule-p rule) t)))

(defun pair-summary (pair)
  (list :from (car pair) :to (cdr pair)))

(defun dropped-edge-summary (drop)
  "One BUG-0030 F1 drop, as the four facts a caller can act on: which
relationship, between which two types, from which file, and the ontology's own
sentence about it."
  (list :rel-type (getf drop :rel-type)
        :from-type (getf drop :from-type)
        :to-type (getf drop :to-type)
        :origin-file (getf drop :origin-file)
        :problem (getf drop :problem)))

(define-operation :check :read (repository)
    "Files that would not parse, rule violations, unresolved document
references, unread definers, and dropped edges."
  (let ((graph (repository-view repository)))
    (list ;; BUG-0033, first for the reason console.lisp gives: every other key
          ;; here describes something the index knows and got wrong, and this
          ;; one describes a file it does not know at all.
          :unparsed (unparsed-facts graph)
          :violations (mapcar #'violation-summary
                              (entities-of-type graph :rule-violation))
          :unenforced (mapcar #'rule-summary (unenforced-rules graph))
          :unresolved (mapcar #'pair-summary (unresolved-references graph))
          ;; DES-0029 D3. Additive: a caller reading :UNRESOLVED sees the
          ;; population that is rot, and one reading :AMBIGUOUS sees the
          ;; population that is not, with the candidate ids it needs to act.
          :ambiguous (ambiguous-references graph)
          :unhandled-definer-macros
          (mapcar (lambda (macro)
                    (list :name (name macro)
                          :file (getp macro :file)
                          :start-line (getp macro :start-line)))
                  (unhandled-definer-macros graph))
          :collisions (mapcar #'pair-summary
                              (generated-definition-collisions graph *macro-generators*))
          ;; BUG-0030 F1. Empty on all three watched trees, and carried anyway:
          ;; the whole point of the mechanism is that a fourth missing :TO
          ;; entry shows up here instead of taking a repository dark.
          :dropped-edges (mapcar #'dropped-edge-summary (dropped-edges graph)))))

(define-operation :check-document :read (repository path (contents))
    "What one document's declared references resolve to, before it is written \
or indexed. Pass contents to check a draft that is not on disk."
  ;; REQ-0034 R5. A :READ operation and nothing else: the answer is computed
  ;; from the live index and the draft, and no transaction is built, so R4's
  ;; "the graph after the call is identical to the graph before it" is a
  ;; property of the code rather than a promise about it.
  ;;
  ;; Scoped to one document, which is the whole requirement. `check' answers
  ;; what is unresolved in the repository, and an author adding a document has
  ;; to subtract that baseline by hand before they can tell whether they made
  ;; things worse. Loom's own baseline is 9 unresolved and 7 ambiguous.
  (check-document-references (require-repository repository) path
                             :contents contents))

(define-operation :context-used :write (record used)
    "Record what an agent went on to use for a context call, quoting the \
identifier that call returned. `used' is a JSON array of {name, how}."
  ;; REQ-0036 R2. :WRITE because it writes, and nothing about it is a read --
  ;; the tier it would have had if it had been designed on its own.
  ;;
  ;; USED as a JSON array inside a string because BUG-0031 types every MCP
  ;; argument as a string, and a shape a caller builds in one line beats three
  ;; parallel arguments it has to keep aligned. What it names is deliberately
  ;; not restricted to what the bundle returned: a feedback channel sampling
  ;; only from the returned items can never record a miss, and the miss is the
  ;; population that would raise recall.
  (let ((entries (decode-used-entries used)))
    (handler-case (record-context-use record entries)
      (context-record-error (condition)
        (error 'malformed-request
               :detail (princ-to-string condition))))))

(defun decode-used-entries (used)
  "The JSON array USED as a list of plists, or a refusal.

Refused rather than salvaged: an entry Loom could not read would become a
judgement about an entity nobody named, and a used set that silently lost half
its entries is worse than a call that failed."
  (let ((decoded (handler-case (json:decode-json-from-string (or used "[]"))
                   (error (condition)
                     (error 'malformed-request
                            :detail (format nil "used is not JSON: ~a" condition))))))
    (unless (listp decoded)
      (error 'malformed-request :detail "used must be a JSON array."))
    (loop for entry in decoded
          unless (and (consp entry) (consp (first entry)))
            do (error 'malformed-request
                      :detail "each used entry must be a JSON object.")
          collect (list :name (cdr (assoc :name entry))
                        :how (cdr (assoc :how entry))))))

(define-operation :rules :read (repository)
    "Active rules and what they constrain."
  (list :rules (mapcar #'rule-summary (active-rules (repository-view repository)))))

;;;; ==================================================================
;;;; Write tier
;;;; ==================================================================

(define-operation :watch :write (path)
    "Register a repository, index it, and begin watching. Resumes a paused one."
  ;; Under the registry lock: this is one of the two entries that adds to or
  ;; removes from *REPOSITORIES*. See the lock's own comment for why the list
  ;; needs one and this file is where it goes.
  ;; :QUIET T, unlike console.lisp's `watch`, which prints its progress to the
  ;; developer watching it happen. A service has no such developer: the answer
  ;; is the status plist this returns, and per-file progress on the process's
  ;; own *STANDARD-OUTPUT* would be noise in a log nobody asked for.
  (bt:with-recursive-lock-held (*workspace-registry-lock*)
    (repository-status (watch-repository path :quiet t))))

(define-operation :pause :write (repository)
    "Stop watching but keep the index. Resume with watch."
  ;; No registry lock. PAUSE mutates no list -- it stops a monitor thread and
  ;; leaves the registration exactly where it was -- and taking the lock here
  ;; would look consistent while widening it for no reason.
  (let ((watched (require-repository repository)))
    (repository-status (pause-repository (repository-name watched)))))

(define-operation :unwatch :write (repository)
    "Stop watching and drop the index."
  (bt:with-recursive-lock-held (*workspace-registry-lock*)
    (let ((watched (require-repository repository)))
      (repository-status (unwatch-repository (repository-name watched))))))

(define-operation :init :write (path (document-directory) (endpoint) (append-claude-md))
    "Prepare a repository for the Loom workflow. Writes files; never commits."
  ;; The consent is an argument here for the reason it is one at the console:
  ;; REQ-0021 R16 puts the asking where a terminal is, and a service has none.
  ;; A caller that omits APPEND-CLAUDE-MD gets the conservative answer, which
  ;; is that an existing CLAUDE.md is not touched.
  (prepare-repository path
                      :document-directory (or document-directory "docs")
                      :endpoint (or endpoint *default-endpoint*)
                      :append-claude-md
                      (and append-claude-md
                           (not (string-equal "false" (princ-to-string append-claude-md)))
                           t)))

(define-operation :architecture :write (repository)
    "Write an ARCH document from the index. Says only what was measured."
  ;; :WRITE rather than :READ, and the tier is the whole point: :STRUCTURE
  ;; returns the same measurements and changes nothing, while this puts a file
  ;; in somebody's repository.
  (generate-architecture (require-repository repository)))

(define-operation :remove :write (repository (mode))
    "Take Loom out of a prepared repository. Documents stay unless mode is all."
  (let ((watched (require-repository repository)))
    (remove-preparation (repository-root watched)
                        :mode (if (and mode (string-equal "all" (princ-to-string mode)))
                                  :all
                                  :tooling))))

(define-operation :reindex :write (repository)
    "Discard and rebuild the index from disk. Always safe."
  ;; No registry lock either, for PAUSE's reason: REINDEX-REPOSITORY replaces
  ;; the graph inside a repository that stays registered throughout, and
  ;; DES-0004's own lock is what makes that safe.
  (let ((watched (require-repository repository)))
    (reindex-repository watched :quiet t)
    (repository-status watched)))

;;;; ------------------------------------------------------------------
;;;; Document state transitions (REQ-0022 R6, DES-0019 D9)
;;;;
;;;; The first two entries in this table that write a file rather than an
;;;; index, and the reason they are here at all rather than only in the console.
;;;; REQ-0021 requires installed agents to reach Loom through the service --
;;;; REST under /v1/ or MCP at /mcp -- rather than through a path inside Loom's
;;;; own tree, because a prepared worktree has no tools/loom.sh in it. A
;;;; console-only transition command would be unusable in exactly the deployment
;;;; that motivated building it.
;;;;
;;;; They name their repository like everything else here, and REQUIRE-REPOSITORY
;;;; refuses to guess. That refusal matters more for these two than for any read
;;;; entry above: a misdirected query is a wrong answer, while a transition that
;;;; wrote into the wrong worktree has edited somebody else's documents.
;;;; ------------------------------------------------------------------

(defun transition-result (report)
  "REPORT as an answer, or a MALFORMED-REQUEST naming every problem it collected.

A refusal is a statement about the request -- a status outside the document's
vocabulary, a verdict for a blocked document, a plan whose file has no top-level
status line -- so it belongs on the 400 path rather than arriving as a 200 with
a problems array a client has to remember to read. All of them in one message,
because the underlying command collected them all for that purpose."
  (let ((problems (getf report :problems)))
    (if problems
        (error 'malformed-request
               :message (format nil "~{~a~^~%~}" problems))
        report)))

(define-operation :set-status :write (repository document status)
    "Set one document's status and file it where that status belongs."
  (transition-result
   (set-document-status (require-repository repository) document status)))

(define-operation :complete :write (repository plan (verdicts))
    "Set a plan final and restate every document it implements. Without verdicts, a dry run."
  ;; VERDICTS is one string -- "DES-0019=implemented REQ-0022=partial" -- and
  ;; not an object, because an MCP tool argument is declared a string by
  ;; TOOL-INPUT-SCHEMA and an HTTP query parameter is one whatever it means.
  ;; One spelling that works on all three surfaces beats a richer shape that
  ;; works on one of them.
  (transition-result
   (complete-plan (require-repository repository) plan :verdicts verdicts)))
