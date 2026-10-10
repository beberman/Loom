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

(defun require-repository-now (designator)
  "REQUIRE-REPOSITORY without waiting for an index still being built.

For `status' alone. Every other operation reads the graph and must not see an
empty one, but status is the operation whose job is to say what state things
are in -- and an introspection call that blocked until the thing it was
introspecting finished would be unable to report the state it exists to
report.

Two values, the repository and the domain, for the reason REQUIRE-REPOSITORY
gives."
  (when (null designator)
    (error 'malformed-request
           :message "This operation needs the name of a repository. Ask status for the list."))
  (multiple-value-bind (repository domain) (split-designator designator)
    (if (null repository)
        (error 'malformed-request
               :message (format nil "No repository named ~a is watched." designator))
        (values repository domain))))

(defun require-repository (designator)
  "The repository DESIGNATOR names, and the domain it named inside it.

  (require-repository \"front-end/server\")  => repository, the server domain
  (require-repository \"front-end\")         => repository, NIL

No default, no fallback to the sole watched repository, no CURRENT-REPOSITORY.
DES-0006 is explicit that an operation invoked without a designator is a
malformed request rather than an ambiguous one to be resolved by guessing.

PLAN-0050 S13. SPLIT-DESIGNATOR rather than FIND-REPOSITORY, so a designator
naming a domain resolves to its repository and the domain travels back. An
undeclared domain refuses inside the split, naming the ones the repository has,
and that refusal is a REQUEST-ERROR which INVOKE-OPERATION carries out whole.

The seventeen call sites that bind one value are unchanged: a second value
nobody asks for costs them nothing.

Written with the binding outside any COND, which is where the second value was
lost on the first attempt. A COND clause with no body returns only the primary
value of its test, so the domain never left this function and every scoped call
answered about the whole repository -- a silent wrong answer of exactly the kind
R-i is about, produced by the code meant to prevent it.

The wait is here and not in each operation because this is the one place they
all pass through. loom-serve.lisp registers a repository and indexes it on
another thread so the listener can bind its port at once; a request arriving in
that window waits for the graph rather than being answered from an empty one.
An empty graph is not a slow answer, it is a confident wrong one -- `find'
would report that nothing matches, indistinguishable from the truthful version
of itself.

*INDEX-BUILD-WAIT* is a grace period rather than the wait it used to be, and is
0: a caller who would rather block sets it. Reporting beats waiting, because a
caller that waits has nothing to say for as long as the wait lasts, and over
MCP that is an agent sitting on a tool call with no way to know whether
anything is happening."
  (when (null designator)
    (error 'malformed-request
           :message "This operation needs the name of a repository. Ask status for the list."))
  (multiple-value-bind (repository domain) (split-designator designator)
    (when (null repository)
      (error 'malformed-request
             :message (format nil "No repository named ~a. Ask status for the list."
                              designator)))
    (unless (await-repository-index repository *index-build-wait*)
      (error 'repository-indexing
             :message (format nil "~a is still being indexed. ~
Ask again in a few seconds; `status' says when it is ready."
                              (repository-name repository))))
    (values repository domain)))

(defun requested-kind (value)
  "VALUE as a family keyword, or NIL, or a malformed request naming the two.

The two words rather than a free keyword, because a caller who writes
`kind=documents' should be told what to write rather than silently answered
about everything."
  (when (and (stringp value) (plusp (length value)))
    (let ((kind (intern (string-upcase value) :keyword)))
      (unless (member kind loom-knowledge:*find-kinds*)
        (error 'malformed-request
               :message (format nil "kind must be one of ~{~(~a~)~^, ~}, not ~s."
                                loom-knowledge:*find-kinds* value)))
      kind)))

(defun resolve-entity (graph term &key property-filters)
  "The entity TERM names: an id if it is one, otherwise the best name match.

PROPERTY-FILTERS narrows the name match, which is how a domain address reaches
`describe' and `impact' -- both resolve through here."
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
      (let ((hit (best-name-match graph term :property-filters property-filters)))
        (when hit (get-entity graph (getf hit :id))))
      (error 'unknown-entity
             :message (format nil "Nothing in the index matches ~s." term))))

(defun repository-view (designator)
  "The graph REQUIRE-REPOSITORY's answer holds."
  (repository-graph (require-repository designator)))

;;;; ==================================================================
;;;; Refusing a wire value -- the request-level half
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
;;;; The first two of the three are LOOM-UTILS', since REV-0002 C2. They are
;;;; the half with no opinion about requests, and console.lisp had its own copy
;;;; of the integer walk in RESOLVE-COUNT. Only the coercers are here, because
;;;; only they signal MALFORMED-REQUEST, and only this system maps that to a
;;;; status code.

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

(defun request-cosine (value what)
  "VALUE as a cosine in [0,1], NIL when absent, or a malformed request.

The range is checked and the console's is not, because the two failures differ.
A console reader who types 5 sees an empty table under a heading saying 5.00
and knows what they did. A survey answering an out-of-range cut over HTTP
returns an empty rows array, which is the one thing DES-0041 D10 forbids this
pair of operations to be ambiguous about: no pair reaches the cut, and no pair
could have."
  (cond ((null value) nil)
        ((let ((cosine (to-cosine value)))
           (and cosine (<= 0.0 cosine 1.0) cosine)))
        (t (error 'malformed-request
                  :message (format nil "~a must be a cosine between 0 and 1, not ~s."
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
(defun requested-entity-type (entity-type)
  (and entity-type
       (intern (string-upcase (string entity-type)) :keyword)))

;; REQ-0051 R1, DES-0043 D8. REPOSITORY is optional here and required on every
;; other read entry, which is the whole change on this surface: VALIDATE-ARGUMENTS
;; reads the shape to decide what to refuse and TOOL-INPUT-SCHEMA reads it to
;; build MCP's `required' vector, so neither skin is edited. `:status' is the
;; precedent and has been the one operation with no designator requirement since
;; it was written -- for the same reason, that it is the call a caller makes
;; before it knows which repository to name.
(define-operation :find :read ((repository) term (entity-type) (kind) (limit) (trigger))
    "Where something is defined. Without a repository, every watched one is \
searched and each row says which it came from. trigger lists what a declaration \
marked as an entry point of that kind; term may then be empty."
  ;; Wrapped under :ENTITIES rather than returned as a bare list, so that every
  ;; operation in this system answers with a plist and every JSON response is
  ;; therefore an object. A bare list would also make an empty result encode as
  ;; null instead of [], which is the ambiguity *ARRAY-VALUED-KEYS* exists to
  ;; prevent and which a top-level value has no key to be rescued by.
  (let ((type (requested-entity-type entity-type))
        (kind (requested-kind kind))
        (limit (or (request-integer limit "limit") *find-limit*)))
    (when (and trigger (null repository))
      (error 'malformed-request :message "find with a trigger needs a repository argument."))
    (if (null repository)
        ;; The federated form returns SEARCH-REPOSITORIES' plist whole: the same
        ;; :ENTITIES, :TOTAL and :TRUNCATED a named search answers with, plus
        ;; the three lists REQ-0051 R4 and R5 need -- what was searched, what
        ;; was not, and what it cost.
        (search-repositories term :type type :kind kind :limit limit)
        (multiple-value-bind (watched domain) (require-repository repository)
          (multiple-value-bind (entities total)
              (search-entities (repository-graph watched)
                               :name (and (plusp (length term)) term)
                               :type type :kind kind :limit limit
                               :property-filters (append (domain-property-filter domain)
                                                         (trigger-property-filter trigger)))
            ;; BUG-0002. :TOTAL and :TRUNCATED alongside the rows, because a
            ;; caller that received the limit and nothing else cannot tell a
            ;; complete answer from a cut one -- and an agent asking how many of
            ;; a type exist gets a number rather than a page of rows to count.
            (append
             ;; REQ-0051 R2. The row names its tree on this form too. A caller
             ;; who named the repository already knows it, and the row is what
             ;; gets pasted into a document.
             (list :entities (mapcar (lambda (row)
                                       (list* :repository (repository-name watched) row))
                                     entities)
                   :total total
                   :truncated (> total (length entities))
                   ;; REQ-0065 R1, and only on the named form. The federated
                   ;; `find' searches every watched tree, so there is no one
                   ;; index for a provenance to be about -- it already answers
                   ;; that question in its own vocabulary with :SEARCHED and
                   ;; :SKIPPED, which say which trees the answer covers. A
                   ;; single :DIFF there would be one tree's fingerprint
                   ;; presented as the whole answer's, which is worse than none.
                   :provenance (answer-provenance watched))
             ;; REQ-0051 R3, and the clause the whole requirement is for. Paid
             ;; only on the miss, which is where the reader decides to reach for
             ;; grep instead.
             ;; Not for a trigger query: the miss bands look the term up in other
             ;; trees and in the text, and an empty term would look up everything.
             (when (and (null entities) (null trigger))
               (append
                (list :elsewhere
                      (repositories-holding term :type type
                                            :exclude (repository-name watched)))
                ;; REQ-0059 R3, the same rule on a third surface. REQ-0051 made
                ;; a zero hit say what the other trees hold and REQ-0054 asks
                ;; that it say what this tree holds in prose; this says what the
                ;; index could not have read at all. `find acceptance' against
                ;; Loom is a miss because Python is analyzed by nobody, and it
                ;; was byte-identical to a miss on a name that exists nowhere.
                ;;
                ;; Read off the struct, so the miss costs nothing: the walk and
                ;; the `git ls-files' behind it were paid at index time.
                (let ((unclaimed (repository-unclaimed watched)))
                  (when (and unclaimed (plusp (or (getf unclaimed :count) 0)))
                    (list :unanalyzed
                          (list :files (getf unclaimed :count)
                                :by-extension (getf unclaimed :by-extension)))))
                ;; REQ-0054, the third band and the one that tells the two
                ;; absences apart. A term no definition carries may still be a
                ;; route, a config key or a word in a comment, and those imply
                ;; the opposite next move from a name that is simply dead.
                ;;
                ;; Paid on the miss and only there, which is R4: a `find' that
                ;; matched does what it did before, and this scan runs where the
                ;; caller is already deciding whether to reach for grep.
                (list :occurrences
                      (textual-occurrences (repository-root watched) term))))))))))

(define-operation :describe :read (repository term (source))
    "Full detail for one entity, with its neighbours grouped by edge type. \
Pass source=true for the definition's text."
  ;; REQ-0031 R1 and R2. The optional SOURCE is what makes this available on
  ;; REST and MCP at once: loom-rest walks ARG-SHAPE for routes and loom-mcp
  ;; walks it for tools/list, so declaring the argument declares both surfaces
  ;; and neither file is edited. DES-0006 R5's property, exercised.
  (multiple-value-bind (repository-struct domain) (require-repository repository)
   (let* ((graph (repository-graph repository-struct))
         (entity (resolve-entity graph term :property-filters (domain-property-filter domain)))
         ;; REQ-0050 R1. A REST or MCP consumer cannot see the console's
         ;; drift line and has no other way to ask what tree this answer is
         ;; about, so it travels on the data.
         (detail (describe-entity graph (id entity)
                                  :provenance (file-provenance
                                               repository-struct (getp entity :file)))))
    (if (request-boolean source "source")
        ;; Appended under its own key rather than folded into :PROPERTIES: the
        ;; text is not a fact the analyzer asserted about the entity, it is a
        ;; read of a file performed now, and its :STATUS is about that read.
        (append detail (list :source (definition-source repository-struct (id entity))))
        detail))))

(defun sites-answer (repository term limit)
  "The answer to :SITES. A function of its own for the reason PRINT-SITES is: the
DEFINE-OPERATION body mints one :CALL-SITE per distinct name it calls."
  (multiple-value-bind (watched domain) (require-repository repository)
   (let* ((graph (repository-graph watched))
          (entity (resolve-entity graph term
                                  :property-filters (domain-property-filter domain))))
     (list :entity (entity-summary entity)
           ;; NIL is the answer when no call form is recorded, and *ARRAY-
           ;; VALUED-KEYS* carries :GROUPS so it encodes as [] and not null.
           :groups (shape-sites graph (id entity)
                                :per-group (or (request-integer limit "limit") 20))
           :provenance (answer-provenance watched)))))

(define-operation :sites :read (repository term (limit))
    "The calls to one definition grouped by how they are written, the rarest \
group first, with file, line and caller for each. Pass limit for the rows \
shown per group; the default is 20."
  ;; DES-0055 D12, REQ-0041 R4. TERM resolves exactly as :DESCRIBE's does,
  ;; domain filter included, so `describe' and `sites' on one name are about one
  ;; entity.
  (sites-answer repository term limit))

(define-operation :impact :read (repository term (depth))
    "What may need attention if this changes, with paths and depths."
  (multiple-value-bind (watched domain) (require-repository repository)
   (let ((graph (repository-graph watched)))
    ;; The domain scopes the seed and never the walk: the cross-domain edges
    ;; step 6 draws are the answer rather than noise, so `impact' on a
    ;; definition in one domain still reports what it reaches in another.
    (append (impact-report graph (id (resolve-entity graph term
                                                     :property-filters
                                                     (domain-property-filter domain)))
                           :max-depth (or (request-integer depth "depth")
                                          *default-impact-depth*))
            ;; REQ-0065 R1.
            (list :provenance (answer-provenance watched))))))

(defparameter *context-scoring-keys*
  '(:cost :via :direction :convergence :effective-cost :relation-count)
  "The per-item fields a bundle carries for judging its own ranking.

REQ-0036 reads these; a reading agent does not. They are what the console
prints as `->calls 3 x2' beside an item and what a judgement of the ranking is
made from, and both of those happen where the bundle is built -- the console
has the plist in hand, and RECORD-CONTEXT-CALL is given the whole bundle before
anything is encoded. So dropping them from the wire costs neither.

Measured on front-end 2026-08-27: 12,063 bytes of a 81,793-byte bundle, 16%,
spread over 124 items that carry all six keys whether or not any is set.")

(defun lean-context-item (item)
  "ITEM without the fields that exist for scoring rather than for reading.

BUG-0054 F2. The entities were never the expensive part: a caller that hits its
output limit today loses the whole bundle, and 16% of what pushed it over is
instrumentation the caller has no use for.

Applied to the items and not to the bundle's totals, which are the caller's
own budget arithmetic and belong on every answer."
  (loop for (key value) on item by #'cddr
        unless (member key *context-scoring-keys*)
          append (list key value)))

(defun leaned-bundle (bundle)
  "BUNDLE with every item thinned by LEAN-CONTEXT-ITEM.

The items and nothing else. :TOKENS, :BUDGET, :TRUNCATED and the withheld
counts are the caller's own arithmetic about what it asked for and what it got,
and they are now in the same currency as the bytes -- which is the other half
of BUG-0054 and the reason they must survive."
  (loop for (key value) on bundle by #'cddr
        append (list key (if (eq key :items)
                             (mapcar #'lean-context-item value)
                             value))))

(defun context-item-tokens (item)
  "ITEM's cost in the currency a REST or MCP caller actually spends.

BUG-0054 F1, and the reason it is one function rather than two: this prices the
*same* shape LEAN-CONTEXT-ITEM emits, so the budget cannot be charged for
something the caller does not receive. Charging RENDER-ITEM -- the console text
-- is what left `budget=6000' delivering 81,793 characters.

ENCODE-RESULT rather than a length estimate over the plist. The plist is not
what goes on the wire: JSON-VALUE renames keys, drops nothing, and writes
`null' for every unset field, and those nulls are 11,806 of the bytes measured.
An estimate that ignored them would be the same class of error one layer down."
  (estimate-tokens (encode-result (lean-context-item item))))

(define-operation :context :read (repository task (budget))
    "A budgeted context bundle for a task: what to know before editing."
  ;; BUILD-CONTEXT and no RENDER-CONTEXT. The rendering step is what turns the
  ;; bundle into the text a console prints, and a program wants the bundle.
  ;; SOURCE-FN rather than a call from inside BUILD-CONTEXT: DEFINITION-SOURCE
  ;; is loom-workspace's because it needs REPOSITORY-ROOT, and loom-knowledge
  ;; cannot reach up there (DES-0027 D1). This entry has the repository, so the
  ;; fetch is passed in and the tier logic stays where the bundle is built.
  (multiple-value-bind (repo context-domain) (require-repository repository)
    (let ((started (get-internal-real-time)))
      (multiple-value-bind (bundle instrumentation)
          ;; DEC-0006. Bound here rather than read inside BUILD-CONTEXT for the
          ;; reason the SOURCE-FN comment above gives: loom-knowledge is handed
          ;; a graph and never learns which repository it belongs to, and this
          ;; entry has the repository. REPOSITORY-VECTORS is NIL until somebody
          ;; builds a store, so on an ordinary tree both bindings are NIL and
          ;; SEED-ENTITIES takes the path it has taken since S3.
          (let ((loom-knowledge:*context-vector-store* (repository-vectors repo))
                (loom-knowledge:*context-embedder* (current-embedder))
                ;; BUG-0054. The budget is charged in the currency this skin
                ;; delivers, which is the whole of REQ-0040 R1: "an MCP caller
                ;; has a hard output limit and until now no way to say so".
                ;; Bound here rather than defaulted in loom-knowledge because
                ;; the encoder is this system's and the console's price is
                ;; correctly the console's.
                (loom-knowledge:*context-item-cost* #'context-item-tokens))
            ;; PLAN-0045 S2. REQ-0040 R1: an MCP caller has a hard output
            ;; limit and until now no way to say so. REQUEST-INTEGER refuses
            ;; junk rather than truncating it -- a budget silently read as 3
            ;; from "3x" returns a bundle that is simply smaller than the one
            ;; asked for, with nothing in the output saying why.
            (build-context (repository-graph repo) task
                           :property-filters (domain-property-filter context-domain)
                           :budget (or (request-integer budget "budget")
                                       *context-token-budget*)
                           :provenance (index-provenance repo)
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
          ;; The strip is after the record and before the return, and the order
          ;; is the whole of why REQ-0036 loses nothing: RECORD-CONTEXT-CALL is
          ;; handed the bundle with its scoring fields intact, and only the
          ;; copy going to the caller is thinned.
          ;;
          ;; BUG-0053. :FEEDBACK is on every answer, in both states, and it is
          ;; the field that makes :RECORD readable. The prepared guidance tells
          ;; an agent to quote the record id when it has finished the work a
          ;; bundle was for; *CONTEXT-LOG-DIRECTORY* is NIL by default, so on an
          ;; ordinary deployment no answer carried one and the agent had an
          ;; absent key to reason about. An absent key cannot say which of
          ;; "feedback is off here", "this build predates REQ-0036" and "the
          ;; write failed" it means, and the first is the only one an agent
          ;; should act on. CON-0001's rule, at the scale of one field.
          (let ((answer (append (leaned-bundle bundle)
                                (list :feedback
                                      (if loom-workspace:*context-log-directory*
                                          :on :off)))))
            (if id (append answer (list :record id)) answer)))))))

(define-operation :structure :read (repository)
    "Systems, protocols, entry points and hubs, derived from the index."
  ;; REQ-0021 R5, and the shape matters more than usual: DES-0022 D4 requires
  ;; that the console printer and the document generator walk the same plist,
  ;; so this returns the report and renders nothing. An init script asking for
  ;; a tree's structure over REST gets the data a human sees formatted, not a
  ;; second, prose-shaped answer it would have to parse.
  (let ((watched (require-repository repository)))
    ;; REQ-0050 R1. INDEX-PROVENANCE rather than REPOSITORY-COMMIT: the commit
    ;; this report is about is the one the analyzer read, and asking git now
    ;; answers about the tree now. The plist carries the drift beside it, so a
    ;; consumer reads whether the answer is behind rather than computing it.
    (apply #'structure-report (repository-graph watched)
           :repository (repository-name watched)
           (index-provenance watched))))

(define-operation :drift :read (repository)
    "Where the prose and the index disagree. Candidates for review, not findings."
  (let ((watched (require-repository repository)))
    (prose-report (repository-graph watched) :repository (repository-name watched))))

;;;; ------------------------------------------------------------------
;;;; Resemblance (REQ-0042, DES-0041; registered by BUG-0052)
;;;;
;;;; DES-0041 D9 puts the query in loom-knowledge and leaves the stores to the
;;;; caller, "the arrangement console.lisp and operations.lisp already use for
;;;; *CONTEXT-VECTOR-STORE* and *CONTEXT-EMBEDDER*". console.lisp got that
;;;; arrangement and this file did not, so for six days the one query `find'
;;;; structurally cannot answer was reachable only by a human at a console --
;;;; and an agent in a prepared worktree, which is who REQ-0021 R8 says reaches
;;;; Loom through the service, got UNKNOWN-OPERATION.
;;;;
;;;; Neither entry binds a special variable. `similar' and `survey' take their
;;;; stores as arguments, unlike `context', so there is nothing here for a
;;;; concurrent request on another thread to see.
;;;; ------------------------------------------------------------------

(defun require-vectors (designator)
  "The repository DESIGNATOR names and its vector store, or a malformed request.

REQUIRE-REPOSITORY decides the first and LOOM-WORKSPACE:REQUIRE-REPOSITORY-VECTORS
the second, including the sentence a caller reads -- REV-0002 A2 moved that down
to the system owning REPOSITORY-VECTORS, because loom-process\'s console had a
second copy of it and the two systems are peers.

What stays here is the re-typing, and it is the whole reason this wrapper
exists. MALFORMED-REQUEST rather than the REFUSAL underneath, which is the other
refusal a caller can be handed about a repository that will answer later:
REPOSITORY-INDEXING is 503 because the request succeeds unchanged in a few
seconds; this one does not succeed until somebody runs `embed\', so 400 and the
command that fixes it."
  (let ((watched (require-repository designator)))
    (handler-case (require-repository-vectors watched)
      (loom-utils:refusal (condition)
        (error 'malformed-request
               :message (loom-utils:refusal-message condition))))))

(define-operation :similar :read (repository term (against) (limit))
    "Definitions that resemble one, by meaning rather than by name. \
Pass against to search a different repository than the subject's."
  ;; REQ-0042 R1 and R2. AGAINST is the second repository and not a second
  ;; term: a resemblance query names two trees at most and one subject, and the
  ;; cross-repository form is the case the requirement was written for.
  (multiple-value-bind (source source-store) (require-vectors repository)
    ;; The domain comes from the designator rather than from REQUIRE-VECTORS,
    ;; which answers about the store. SPLIT-DESIGNATOR has already refused an
    ;; undeclared one by the time REQUIRE-VECTORS returned, so this cannot
    ;; refuse twice.
    (let* ((similar-domain (nth-value 1 (split-designator repository)))
           (subject (resolve-entity (repository-graph source) term
                                    :property-filters
                                    (domain-property-filter similar-domain))))
      (multiple-value-bind (target target-store)
          (if against (require-vectors against) (values source source-store))
        (list :repository (repository-name source)
              :against (repository-name target)
              ;; The subject travels with the answer for the reason a survey
              ;; row carries :SUBJECT-LOCATION: TERM is what the caller typed,
              ;; and BEST-NAME-MATCH may have resolved it to one of several
              ;; definitions spelling that name.
              :subject (entity-summary subject)
              ;; NIL here is the store's answer and not its absence --
              ;; REQUIRE-VECTORS has already refused that case -- so [] is the
              ;; honest encoding. *ARRAY-VALUED-KEYS* carries :RESEMBLING.
              :resembling (resembling subject source-store
                                      (repository-graph target) target-store
                                      :limit (or (request-integer limit "limit")
                                                 *resemblance-limit*)))))))

(define-operation :survey :read (repository against (cut))
    "Definitions in one repository that resemble something in another, best first."
  ;; REQ-0042 R3. AGAINST is required here and optional on :SIMILAR, which is
  ;; the shape of the two questions: a survey with one repository is a survey
  ;; of a tree against itself, and every definition resembles itself.
  (multiple-value-bind (source source-store) (require-vectors repository)
    (multiple-value-bind (target target-store) (require-vectors against)
      (let ((floor (or (request-cosine cut "cut") *survey-cut*)))
        (multiple-value-bind (rows same-name reached)
            (resemblance-survey (repository-graph source) source-store
                                (repository-graph target) target-store
                                :cut floor)
          (list :repository (repository-name source)
                :against (repository-name target)
                :cut floor
                :rows rows
                ;; BUG-0002's pair of keys, for BUG-0002's reason: forty rows
                ;; read as the whole truth is worse than a long table, and the
                ;; console prints "40 of 486 shown" from exactly these two.
                :total reached
                :truncated (> reached (length rows))
                ;; DES-0041 D4. Counted rather than listed: `find' answers
                ;; these, and all of them score 1.0000, so listing them would
                ;; spend the table on the question that was not asked.
                :same-name same-name))))))

(define-operation :status :read ((repository))
    "Index size, watcher health, unresolved references, rule violations."
  ;; The one operation with no designator requirement, because with none it is
  ;; the repository-discovery call a caller makes once before naming one to
  ;; everything else. Two shapes on purpose: a named repository answers with
  ;; its own status plist, and no name answers with the list under
  ;; :REPOSITORIES, which is what tells an empty answer from a single one.
  (if repository
      (repository-status (require-repository-now repository))
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
  ;; The repository as well as the view: REQ-0056's partition asks which other
  ;; watched tree answered a reference, and REPOSITORY-VIEW returns the graph
  ;; alone. REQUIRE-REPOSITORY is what REPOSITORY-VIEW already goes through, so
  ;; this refuses an unwatched designator exactly as it did.
  (let* ((watched (require-repository repository))
         (graph (repository-view repository))
         (classified (classified-unresolved-references watched)))
    (list ;; BUG-0033, first for the reason console.lisp gives: every other key
          ;; here describes something the index knows and got wrong, and this
          ;; one describes a file it does not know at all.
          :unparsed (unparsed-facts graph)
          :violations (mapcar #'violation-summary
                              (entities-of-type graph :rule-violation))
          :unenforced (mapcar #'rule-summary (unenforced-rules graph))
          ;; REQ-0056. :UNRESOLVED is the population that is rot and nothing
          ;; else: a name another watched tree defines moves to :ELSEWHERE and a
          ;; path-qualified id naming a deleted file to :QUALIFIED. The three
          ;; are different states with different repairs, and reporting them as
          ;; one list is how eight entries from one plan taught a reader that
          ;; the whole list was noise.
          ;;
          ;; Split here rather than filtered, and each of the other two names
          ;; where it was answered, because which trees the service holds
          ;; decides what lands where -- a caller has to be able to see that.
          :unresolved (mapcar #'pair-summary
                              (loop for entry in (getf classified :rot)
                                    collect (cons (getf entry :document)
                                                  (getf entry :reference))))
          :unresolved-elsewhere (getf classified :elsewhere)
          :unresolved-qualified (getf classified :qualified)
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
          :dropped-edges (mapcar #'dropped-edge-summary (dropped-edges graph))
          ;; DES-0053 D6. A call through an import to a name its module no
          ;; longer holds. Empty on a tree with no Python in it, and carried
          ;; anyway for the reason :DROPPED-EDGES is.
          :missing-imported-calls (missing-imported-calls graph)
          ;; BUG-0062 F2 / BUG-0063 F4. A document that wrote a vocabulary
          ;; field and spelled the value wrong, which sets nothing and until now
          ;; looked exactly like not writing the field at all.
          :dropped-fields (dropped-document-fields graph)
          ;; REQ-0065 R1. `check' is run after writing a document and again
          ;; after the edit that answers it, so whether an answer predates the
          ;; write is exactly the question a caller has here.
          :provenance (answer-provenance watched))))

(defun dropped-document-fields (graph)
  "Every document carrying a vocabulary field whose value went nowhere.

The report half of BUG-0062 F2 and BUG-0063 F4. The analyzer records the names
because the raw key is only visible while the YAML is in hand; this asks the
whole tree, which is where a caller can act on the answer."
  (loop for type in *document-types*
        append (loop for document in (entities-of-type graph type)
                     for fields = (getp document :dropped-fields)
                     when fields
                       collect (list :document (or (getp document :doc-id)
                                                   (name document))
                                     :file (getp document :path)
                                     :fields fields))))

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
  ;; REQ-0065 R1. Provenance nested under one key rather than spread inline,
  ;; matching `describe'. R3's divergence with `status' and `structure' is kept
  ;; rather than removed, and it is not arbitrary: there the commit and the
  ;; fingerprint ARE the answer -- both commands are about the state of the
  ;; index -- while here they are metadata about an answer that is about
  ;; something else, and a caller reading a rule should not have to skip four
  ;; keys that are not rules.
  (list :rules (mapcar #'rule-summary (active-rules (repository-view repository)))
        :provenance (answer-provenance (require-repository repository))))

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

(defun init-flag (value)
  "A wire value read as a consent. Absent or \"false\" is no."
  (and value (not (string-equal "false" (princ-to-string value))) t))

(define-operation :init :write (path (document-directory) (endpoint) (append-claude-md)
                                     (update) (replace-unproven) (apply-changes))
    "Prepare a repository for the Loom workflow. Writes files; never commits. \
update=true reports what refreshing an already-prepared repository would \
change; add apply-changes=true to write it."
  ;; The consent is an argument here for the reason it is one at the console:
  ;; REQ-0021 R16 puts the asking where a terminal is, and a service has none.
  ;; A caller that omits APPEND-CLAUDE-MD gets the conservative answer, which
  ;; is that an existing CLAUDE.md is not touched. REPLACE-UNPROVEN is the
  ;; third consent DES-0044 D5 adds and defaults the same way: a file whose
  ;; digest was never recorded is reported, not rewritten.
  (prepare-repository path
                      :document-directory (or document-directory "docs")
                      :endpoint (or endpoint *default-endpoint*)
                      :append-claude-md (init-flag append-claude-md)
                      :update (init-flag update)
                      :replace-unproven (init-flag replace-unproven)
                      :apply-changes (init-flag apply-changes)))

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

(define-operation :embed :write (repository)
    "Build or update the vector store semantic seeding reads. Returns at once."
  ;; :WRITE because it writes a sidecar, and it returns before the writing is
  ;; done -- which is the point rather than a compromise. tools/loom-serve.sh
  ;; calls this once per repository after the listener answers, and a build is
  ;; 66 seconds for game-server and 183 for front-end. A launcher that waited
  ;; would turn "start Loom" into three minutes of silence for a dependency
  ;; that is optional.
  ;;
  ;; A query that wants the store waits for the build instead
  ;; (*VECTOR-BUILD-WAIT*), so the cost falls on whoever asks first. On the
  ;; normal path -- start Loom, read the banner, type a question -- it has
  ;; already been paid by then.
  (let ((watched (require-repository repository)))
    (start-vector-build watched)
    (vector-build-status watched)))

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
        (boolean-fields report '(:dry-run)))))

(defun boolean-fields (plist keys)
  "PLIST with a NIL under any of KEYS replaced by the JSON literal `false'.

BUG-0065 D2. :DRY-RUN is the field a caller reads to learn whether it is
looking at a preview, and NIL is this encoder's overloaded value -- false,
empty, and absent all at once -- so it arrived as `null'. Measured on
PLAN-0006: `\"dry-run\": null' on a cascade where every row was
`already-finished'. The field was therefore `true' or missing and never
`false', which is not a boolean a client can branch on.

Here rather than in COMPLETE-PLAN, and that is layering rather than taste:
loom-workspace does not depend on loom-serve, and *JSON-FALSE* is truthy to
Lisp -- the console reads (getf report :dry-run) directly and would see every
false as true if this value reached it. It is applied at the boundary that
encodes, which is the only place that needs it."
  (loop for (key value) on plist by #'cddr
        append (list key (if (and (null value) (member key keys))
                             *json-false*
                             value))))

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
