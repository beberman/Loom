;;;; Edges that cross a repository boundary.
;;;;
;;;; REQ-0027, DES-0025. "What in the front-end breaks if I change this
;;;; endpoint" is the question neither tree can answer alone, and it is the one
;;;; a product built from two repositories most needs answered.
;;;;
;;;; This is the first thing in the system that reads more than one graph. It
;;;; lives in synoptik-workspace because synoptik-workspace is the only layer that
;;;; knows a repository exists at all: synoptik-graph depends on synoptik-ontology and
;;;; RULE-0001 to RULE-0003 keep it there, and the analyzers are per file by
;;;; construction. Neither analyzer learns that another repository is watched,
;;;; and neither graph learns what a repository is.
;;;;
;;;; ------------------------------------------------------------------
;;;; Why a wholesale re-derivation rather than an incremental one
;;;; ------------------------------------------------------------------
;;;;
;;;; A federated edge points at an entity in another graph, so REQ-0027 R2 --
;;;; "reindexing one repository does not corrupt the other" -- is the hazard
;;;; the whole design has to answer. Retracting a handler in game-server would
;;;; ordinarily leave front-end holding an edge to an id that no longer names
;;;; anything.
;;;;
;;;; The answer is disposability, not bookkeeping. FEDERATE-REPOSITORIES
;;;; retracts every edge it owns, everywhere, and re-derives the lot, whenever
;;;; any watched repository reindexes. An edge re-derived from scratch cannot
;;;; be stale, and a retraction in a far tree removes the far endpoint before
;;;; the next derivation looks for it. VIOLATION-OPS already works exactly this
;;;; way for rule violations, for the same reason.
;;;;
;;;; The cost is honest: this is O(watched repositories) on every reindex of
;;;; any of them. It is re-resolution over properties already in memory, not
;;;; re-analysis -- two claim scans and a hash lookup. If it ever stops being
;;;; cheap the answer is the separate join index DES-0025 considered and did
;;;; not take, rather than an incremental patch on this.
;;;;
;;;; ------------------------------------------------------------------
;;;; Locking, and the second lock this deliberately does not take
;;;; ------------------------------------------------------------------
;;;;
;;;; Every repository has its own analysis lock (DES-0004 R1). This pass reads
;;;; two graphs at once and takes only the writing side's lock: taking both
;;;; would let two repositories reindexing at once deadlock on each other, and
;;;; the obvious fix -- a global ordering on repositories -- buys a guarantee
;;;; that is not needed. Deriving against a graph mid-rebuild produces edges
;;;; that the rebuild's own completion immediately re-derives, because
;;;; completing a reindex runs this pass again.

(in-package :synoptik-workspace)

(defun federated-edge-p (relationship)
  "Is this an edge FEDERATE-REPOSITORIES owns the lifecycle of?

Keyed on the property rather than on the type, so a :SERVES edge asserted by
anything else -- a future analyzer for a framework that can see both ends --
would not be swept away by this pass on its next run."
  (and (eq :serves (rel-type relationship))
       (getp relationship :federated)))

(defun route-static-prefix (route)
  "ROUTE up to its first parameter segment.

  public/game/create        -> public/game/create
  public/game/delete/:gameid -> public/game/delete

The two ends of an HTTP contract spell a parameterized path differently and
both spell the static part the same way. easy-routes writes
\"/public/game/delete/:gameid\"; the client writes
`\"public/game/delete\" + \"/\" + game.id'. Neither can know the other's
parameter, and both wrote the prefix literally, so the prefix is where they
meet.

This is not the glob-matching CON-0001 and REQ-0027 R3 rule out. Nothing here
matches a pattern against a *value* -- \"public/game/17\" is never constructed
or compared. Two literals that both appear in source are compared to each
other, and the match is recorded at a lower confidence than an exact one
because a shorter string is weaker evidence."
  (let* ((route (or route ""))
         (segments (loop with start = 0
                         for slash = (position #\/ route :start start)
                         collect (subseq route start (or slash (length route)))
                         while slash do (setf start (1+ slash))))
         (static (loop for segment in segments
                       until (and (plusp (length segment)) (char= #\: (char segment 0)))
                       collect segment)))
    (when static (format nil "~{~a~^/~}" static))))

(defun route-claims (graph role)
  "Normalized route -> entities in GRAPH claiming it in ROLE.

Both ends of an HTTP contract carry :ROUTES and the strings are identical, so
:ROUTE-ROLE is what separates a handler from a client. It is declared in each
repository's .synoptik/frameworks.yaml rather than inferred here -- guessing from
the language would make Lisp the server and JavaScript the client, which is
true of these two trees and is not a fact about anything."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (type '(:function :method))
      (dolist (entity (entities-of-type graph type))
        (when (eq role (getp entity :route-role))
          (dolist (route (getp entity :routes))
            ;; Keyed on the static prefix, which is where the two ends meet.
            ;; The entity keeps its own full route, so the match kind below can
            ;; still tell an exact agreement from a prefix one.
            (let ((key (route-static-prefix route)))
              (when key
                (push (cons entity route) (gethash key index))))))))
    index))

(defun short-commit (repository)
  "REPOSITORY's HEAD, abbreviated, or NIL.

REQ-0027 R5's half of a federated answer: which working tree, at which commit.
REPOSITORY-COMMIT is DES-0022 D5's and already does the bounded, guarded
`git rev-parse' -- this only shortens it for display. A first attempt at this
file defined a second REPOSITORY-COMMIT of its own, which loaded after
workspace.lisp and silently replaced the real one; `find repository-commit'
reported both and two plans' references to it became ambiguous, which is how
it was caught. RULE-0006 is about exactly this shape of collision within one
file; across two files in one package, Synoptik's own index is what reports it."
  (let ((commit (repository-commit repository)))
    (when (and commit (>= (length commit) 7)) (subseq commit 0 7))))

(defun federated-serves-ops (publisher consumer workspace-id)
  "Operations linking PUBLISHER's handlers to the clients CONSUMER declares.

The edge is stored in the publisher's graph and runs publisher -> consumer,
which is what makes `impact' on a handler reach the client (:SERVES declares
:IMPACT-DIRECTION :FORWARD). REQ-0027 R6 is that traversal and no other.

Confidence is 0.9 rather than 1.0 deliberately. The two literals agree, which
is evidence that these two checkouts were written against one contract -- not
that the running client talks to this server. Spending the remaining 0.1 on
that distinction is cheaper than a reader assuming a deployment was verified."
  (let ((published (route-claims (repository-graph publisher) :publishes))
        (consumed  (route-claims (repository-graph consumer) :consumes))
        (commit (short-commit consumer))
        (ops '()))
    (maphash
     (lambda (prefix clients)
       (dolist (handler-claim (gethash prefix published))
         (dolist (client-claim clients)
           (destructuring-bind (handler . handler-route) handler-claim
           (destructuring-bind (client . client-route) client-claim
           (let* ((exact (string= handler-route client-route))
                  ;; Exact agreement is stronger evidence than agreement on a
                  ;; static prefix, and the report says which it had rather
                  ;; than averaging them into one number nobody can read.
                  (confidence (if exact 0.9 0.75)))
           (push (assert-relationship
                  (make-instance
                   'relationship
                   :rel-type :serves
                   :from-id (id handler) :to-id (id client)
                   :origin-file (origin-file handler)
                   :source :inferred
                   :confidence confidence
                   :properties (properties-table
                                (list :federated t
                                      :route prefix
                                      :match-kind (if exact :exact :prefix)
                                      :handler-route handler-route
                                      :client-route client-route
                                      ;; The far endpoint by name as well as by
                                      ;; id. Ids are per graph and churn on
                                      ;; reanalysis; a natural key does not, so
                                      ;; this is the evidence that lets a reader
                                      ;; -- or a later incremental pass -- tell
                                      ;; whether the edge pointed at what it
                                      ;; claims to have pointed at.
                                      :foreign-repository (repository-name consumer)
                                      :foreign-key (format nil "~s"
                                                           (entity-natural-key client))
                                      :foreign-commit commit
                                      ;; Enough to *name* the far end without
                                      ;; reading the far graph. DES-0025 D5
                                      ;; planned a resolver that synoptik-knowledge
                                      ;; would call back through; carrying the
                                      ;; name on the edge is strictly better and
                                      ;; is what was built. `describe' and
                                      ;; `impact' then answer about a federated
                                      ;; edge from the edge alone -- no second
                                      ;; graph read while a query is running, no
                                      ;; lock taken on a repository that may be
                                      ;; mid-reindex, and no dependency from
                                      ;; synoptik-knowledge back up to this system.
                                      ;; The cost is that the name is as fresh
                                      ;; as the last federation pass, which runs
                                      ;; on every reindex of either side.
                                      :foreign-name (and (slot-boundp client 'name)
                                                         (name client))
                                      :foreign-file (getp client :file)
                                      :foreign-type (string-downcase
                                                     (symbol-name (entity-type client)))
                                      :foreign-line (getp client :start-line))))
                  workspace-id)
                 ops)))))))
     consumed)
    (nreverse ops)))

(defun path-shaped-token-p (token)
  "Does TOKEN claim to be a file rather than merely be a word?

DES-0025 D6. A backticked token that resolves nowhere is dropped in silence,
because prose is full of ordinary words in backticks and REQ-0028's rule about
that is right. `src/ui/edit/piece/mock/PieceEditorMock.jsx' is not an ordinary
word: a path separator and a file extension make it a claim about a file, and a
claim about a file no watched repository holds is the documentation staleness
`check' exists to find."
  (and (stringp token)
       (find #\/ token)
       (let ((dot (position #\. token :from-end t))
             (slash (position #\/ token :from-end t)))
         (and dot slash (> dot slash) (< dot (1- (length token)))))))

(defun entity-at-path (graph path)
  "The entity in GRAPH whose file is PATH, preferring the :FILE entity itself.

Matched on a suffix rather than equality: a document in one repository writes
the path as the other repository's author would type it -- `src/domain/pieces/
Piece.js' -- and that is exactly the far tree's repository-relative path, but a
reference could reasonably be written with a leading `./' or a longer prefix.

Compared case-insensitively, which BUG-0029 makes worth defending rather than
letting pass. MARKDOWN-MENTIONS downcases every token it extracts, so by the
time a reference arrives here `src/domain/pieces/Piece.js' is already
`src/domain/pieces/piece.js' and an exact comparison matches nothing on a
case-sensitive filesystem -- which is precisely how this failed the first time
it was run. Folding is therefore not a decision about paths; it is the only
comparison available against an input that has already been folded. The cost is
that two files differing only in case would both match. Neither tree measured
here contains such a pair, and a reader should know it is possible."
  (or (find-if (lambda (e) (let ((p (getp e :path)))
                             (and p (or (string-equal p path)
                                        (and (> (length p) (length path))
                                             (string-equal path p :start2 (- (length p)
                                                                            (length path))))))))
               (entities-of-type graph :file))
      ;; :DOCUMENT as well as :FILE, and leaving it out was a real defect
      ;; rather than an omission: a markdown file indexes as a :DOCUMENT, so a
      ;; document referring to another document -- which is most of what
      ;; documents do -- found nothing and was reported rotten. It took the
      ;; count on these two trees from 121 to a fraction of that, and every one
      ;; of the differences was a file sitting right there.
      (find-if (lambda (e) (let ((p (getp e :path)))
                             (and p (or (string-equal p path)
                                        (and (> (length p) (length path))
                                             (string-equal path p :start2 (- (length p)
                                                                            (length path))))))))
               (entities-of-type graph :document))))

(defun local-mention-targets (graph document)
  "The mention tokens DOCUMENT already resolved inside its own repository."
  (let ((names '()))
    (dolist (r (relationships-from graph (id document)))
      (when (eq :mentions (rel-type r))
        (let ((target (get-entity graph (to-id r))))
          (when (and target (slot-boundp target 'name))
            (push (string-downcase (name target)) names)))))
    names))

(defun federated-mentions-ops (source consumer workspace-id)
  "Operations linking SOURCE's documents to code in CONSUMER they name.

The prose half of federation, and it is a change to resolution *order* rather
than a new extraction: the markdown analyzer already pulls every backticked
token out of a document, and RESOLVE-DOCUMENT-LINKS already drops the ones that
match nothing locally. This looks in the other watched repositories before that
drop is final.

Only path-shaped tokens cross. A bare name resolving in another repository
would be a coincidence of spelling as often as a reference -- `handler' exists
in both these trees -- and DES-0025 D6's whole argument is that a path is a
claim and a word is not."
  (let ((graph (repository-graph source))
        (far (repository-graph consumer))
        (commit (short-commit consumer))
        (ops '()))
    (dolist (document (entities-of-type graph :document))
      (let ((resolved (local-mention-targets graph document)))
        (dolist (token (getp document :mentions))
          (when (and (path-shaped-token-p token)
                     (not (member (string-downcase token) resolved :test #'string=)))
            (let ((target (entity-at-path far token)))
              (when target
                (push (assert-relationship
                       (make-instance
                        'relationship
                        :rel-type :mentions
                        :from-id (id document) :to-id (id target)
                        :origin-file (origin-file document)
                        :source :inferred
                        ;; The same confidence a within-tree markdown mention
                        ;; carries. Crossing a repository boundary does not make
                        ;; a prose mention weaker evidence -- it is the same
                        ;; claim, about a file that happens to live elsewhere.
                        :confidence *mention-confidence*
                        :properties (properties-table
                                     (list :federated t
                                           :route token
                                           :foreign-repository (repository-name consumer)
                                           :foreign-key (format nil "~s"
                                                                (entity-natural-key target))
                                           :foreign-commit commit
                                           :foreign-name (and (slot-boundp target 'name)
                                                              (name target))
                                           :foreign-file (or (getp target :path)
                                                             (getp target :file))
                                           :foreign-type (string-downcase
                                                          (symbol-name (entity-type target)))
                                           :foreign-line (getp target :start-line))))
                       workspace-id)
                      ops)))))))
    (nreverse ops)))

(defun federated-affects-ops (source consumer workspace-id)
  "Operations linking SOURCE's documents to code in CONSUMER they declare.

REQ-0027 R4: one document governing code in two repositories. \"Soft delete
must hide a record from every read path\" is a claim about both trees, and
until this it could be written in one repository or duplicated in both.

A declared reference, unlike a prose mention, may cross on a bare name. An
`affects:' entry is an author stating that this document bears on that thing;
a backticked word in a paragraph is not. So this matches names and
FEDERATED-MENTIONS-OPS matches only paths, and the difference is the strength
of the claim being made rather than a difference in the matching machinery.

The edge type is the declared one -- :DECIDES for a decision or design,
:DOCUMENTS for everything else -- exactly as within a tree. Crossing a
repository boundary does not change what an author meant by `affects:'."
  (let ((graph (repository-graph source))
        (far (repository-graph consumer))
        (commit (short-commit consumer))
        (ops '()))
    (dolist (document (entities-of-type graph :document))
      (dolist (name (getp document :unresolved-references))
        (let ((matches (remove-if-not
                        (lambda (e) (and (slot-boundp e 'name)
                                         (string-equal name (name e))))
                        (append (entities-of-type far :function)
                                (entities-of-type far :method)
                                (entities-of-type far :class)
                                (entities-of-type far :interface)))))
          ;; One match or none. Several is CON-0001's ambiguous name and stays
          ;; unresolved: an `affects:' that reaches two definitions in another
          ;; repository is a claim nobody can act on, and picking one would be
          ;; the fabricated fact this codebase refuses.
          (when (and matches (null (rest matches)))
            (let ((target (first matches)))
              (push (assert-relationship
                     (make-instance
                      'relationship
                      :rel-type (declared-edge-type-for document)
                      :from-id (id document) :to-id (id target)
                      :origin-file (origin-file document)
                      :source :structural
                      :confidence 1.0
                      :properties (properties-table
                                   (list :federated t
                                         :route name
                                         :foreign-repository (repository-name consumer)
                                         :foreign-key (format nil "~s"
                                                              (entity-natural-key target))
                                         :foreign-commit commit
                                         :foreign-name (name target)
                                         :foreign-file (getp target :file)
                                         :foreign-type (string-downcase
                                                        (symbol-name (entity-type target)))
                                         :foreign-line (getp target :start-line))))
                     workspace-id)
                    ops))))))
    (nreverse ops)))

(defun declared-edge-type-for (document)
  "What this document's affects: means, as an edge type.

The same rule RESOLVE-DOCUMENT-LINKS applies within a tree (CON-0004): a
decision or a design *governs* what it affects and earns :DECIDES; a
requirement, plan, bug or review merely bears on it and earns :DOCUMENTS."
  (let ((id (or (getp document :doc-id) "")))
    (if (or (search "DEC-" id) (search "DES-" id))
        :decides
        :documents)))

(defun federated-declared-names (repository)
  "Every declared name in REPOSITORY that a federated edge already answered.

A hash of document name -> set of declared names. FEDERATED-AFFECTS-OPS records
the name it matched on as :ROUTE, so this reads what that pass concluded rather
than asking the other trees a second question.

REQ-0056. The edges were being drawn and the report was not reading them:
game-server\'s PLAN-0002 carries federated `documents\' edges to utils\'
json-encode and json-decode, and `check\' listed both as unresolved on the same
run. :UNRESOLVED-REFERENCES is a true statement about local resolution -- DEC-0003
has it re-derived every pass and never consumed -- so the partition belongs
here, where the registry is, rather than in a rewrite of the property."
  (let ((table (make-hash-table :test #'equal))
        (graph (repository-graph repository)))
    (dolist (document (entities-of-type graph :document) table)
      ;; FEDERATED-RELATIONSHIPS and not FEDERATED-EDGE-P, which is narrower
      ;; than its name: that predicate answers "an edge this pass owns the
      ;; lifecycle of" and tests for :SERVES, so it rejects every federated
      ;; :DOCUMENTS and :DECIDES edge -- which is all of them here.
      (dolist (relationship (federated-relationships graph (id document)))
        (when (getp relationship :route)
          (push (list :name (getp relationship :route)
                      :repository (getp relationship :foreign-repository)
                      :file (getp relationship :foreign-file)
                      :line (getp relationship :foreign-line))
                (gethash (name document) table)))))))

(defun classified-unresolved-references (repository)
  "REPOSITORY\'s unresolved document references, partitioned by what they mean.

Three lists, because the eight game-server reports for one plan are three
different states and only one of them is rot:

  :ELSEWHERE   a name another watched tree has. Either a federated edge already
               placed it, in which case the entry carries the file and line, or
               the tree holds it under several definitions and federation
               refused to choose -- which is CON-0001 working and must not come
               back as rot. PLAN-0002 moved these out of game-server and naming
               them is what the plan is about, so reporting them as rot makes an
               accurate document permanently wrong.

  :QUALIFIED   a path-qualified id naming a file no tree has --
               `function:utils/dict.lisp:make-dict\', whose file the plan
               deleted. The bare name resolves in utils; that id cannot resolve
               anywhere again, and the repair is to rewrite the reference
               rather than to restore anything. REQ-0056 R3.

  :ROT         a name no watched tree holds. The entry the category exists to
               surface, and R2 forbids any mechanism costing it: `get-package-file\'
               is gone from both trees, which is a finding, and `config-get\' was
               renamed by the plan whose text records the new name.

The elsewhere list depends on which repositories the service happens to hold,
and that is why each entry names the tree it was found in rather than
disappearing: a reader can see that the answer was federated, and a reader whose
service holds fewer trees sees the name under :ROT with nothing hidden."
  (let ((federated (federated-declared-names repository))
        (elsewhere '()) (qualified '()) (rot '()))
    (loop for (document . reference) in (unresolved-references
                                         (repository-graph repository))
          for found = (find reference (gethash document federated)
                            :key (lambda (entry) (getf entry :name))
                            :test #'string-equal)
          do (cond
               (found
                (push (list :document document :reference reference
                            :repository (getf found :repository)
                            :file (getf found :file)
                            :line (getf found :line))
                      elsewhere))
               ((path-shaped-token-p reference)
                (push (list :document document :reference reference
                            :bare (qualified-bare-name reference))
                      qualified))
               ;; A name another tree has but federation would not place. The
               ;; edge is refused deliberately -- FEDERATED-AFFECTS-OPS takes
               ;; one match or none, because an `affects:' reaching two
               ;; definitions elsewhere is a claim nobody can act on -- and the
               ;; refusal must not come back as rot. utils answers `dict-value'
               ;; with an interface, two methods, a function and four tests, so
               ;; the name is emphatically present and emphatically not one
               ;; definition.
               ;;
               ;; REPOSITORIES-HOLDING rather than the edge is also R2's exact
               ;; test: what makes a reference a finding is that *no* watched
               ;; tree holds the name, and that is the question this asks.
               ((let ((held (repositories-holding reference
                                                  :exclude (repository-name repository))))
                  (when held
                    (push (list :document document :reference reference
                                :repository (getf (first held) :repository)
                                :candidates (reduce #'+ held
                                                    :key (lambda (row) (getf row :total))))
                          elsewhere)
                    t)))
               (t (push (list :document document :reference reference) rot))))
    (list :elsewhere (nreverse elsewhere)
          :qualified (nreverse qualified)
          :rot (nreverse rot))))

(defun qualified-bare-name (reference)
  "The name inside a path-qualified reference, or NIL.

`function:utils/dict.lisp:make-dict\' is MAKE-DICT. What a reader needs to know
about such an entry is whether the thing still exists under a name they could
write instead, and the last colon-separated segment is that name."
  (let ((last-colon (position #\: reference :from-end t)))
    (when (and last-colon (< (1+ last-colon) (length reference)))
      (subseq reference (1+ last-colon)))))

(defun unresolved-path-references (&key (repositories *repositories*))
  "Path-shaped prose tokens no watched repository holds a file for.

DES-0025 D6, and the cost it names is worth restating where it is computed:
this is a function of which repositories are registered. A document naming a
file in a tree nobody watched has that reference reported as rotten when it is
merely unwatched, and `check' must not be read as a claim about repositories
the service was never told about."
  (let ((out '()))
    (dolist (source repositories)
      (let ((graph (repository-graph source))
            (archived (getf (repository-frameworks source) :archived-paths)))
        (dolist (document (entities-of-type graph :document))
          ;; DES-0025 D6a. An archived document names files that no longer
          ;; exist because that is what archiving *is*; reporting it as
          ;; staleness would be reporting the tree's own history back at it.
          (unless (archived-document-p document archived)
            (let ((resolved (local-mention-targets graph document)))
              (dolist (token (getp document :mentions))
                (when (and (path-shaped-token-p token)
                           (not (member (string-downcase token) resolved :test #'string=))
                           (notany (lambda (r)
                                     (entity-at-path (repository-graph r) token))
                                   repositories))
                  (push (list :repository (repository-name source)
                              :document (name document)
                              :reference token)
                        out))))))))
    (nreverse out)))

(defun archived-document-p (document archived-paths)
  "Does DOCUMENT sit under a path this repository declared archival?

Declared rather than guessed, for the same reason every other fact in
.synoptik/frameworks.yaml is. \"archive\" is a convention this tree happens to
use; another calls the directory `old', `historical', or nothing at all, and
a directory-name allowlist is exactly the proxy REQ-0028 deleted for markdown.

Matched on a path prefix, case-insensitively, so `docs/archive/' covers
everything beneath it and a declaration written with or without the trailing
slash behaves the same."
  (let ((path (or (getp document :path) (origin-file document))))
    (when path
      (some (lambda (prefix)
              (let ((prefix (string-right-trim "/" prefix)))
                (and (>= (length path) (length prefix))
                     (string-equal prefix path :end2 (length prefix)))))
            archived-paths))))

(defun federated-retractions (repository workspace-id)
  "Retractions for every federated edge REPOSITORY currently holds."
  (loop for r in (all-relationships (repository-graph repository))
        when (federated-edge-p r)
          collect (retract (id r) workspace-id)))

(defun federate-repositories (&key (repositories *repositories*) quiet)
  "Re-derive every cross-repository edge, everywhere. Returns how many it drew.

Called after any repository finishes indexing, which is what keeps R2 true --
see this file's header for why that is wholesale rather than incremental.

A single watched repository is the ordinary case and costs one claim scan
finding nothing to pair with, which is why this is unconditional rather than
guarded on a count."
  (let ((drawn 0))
    (dolist (publisher repositories)
      (let ((ops (federated-retractions publisher (repository-name publisher))))
        (dolist (consumer repositories)
          ;; A repository does not federate with itself: an edge between two
          ;; entities of one graph is an ordinary edge and belongs to whichever
          ;; resolution pass owns that language, not to this one.
          (unless (eq publisher consumer)
            (setf ops (append ops
                              (federated-serves-ops publisher consumer
                                                    (repository-name publisher))
                              ;; The prose half. Same pass, same wholesale
                              ;; retraction, so a document edited in one tree
                              ;; and a file deleted in the other both come out
                              ;; right on the next index of either.
                              (federated-mentions-ops publisher consumer
                                                      (repository-name publisher))
                              ;; REQ-0027 R4. A declared affects: that resolves
                              ;; nowhere locally may be naming code in the other
                              ;; tree.
                              (federated-affects-ops publisher consumer
                                                     (repository-name publisher))))))
        (when ops
          (handler-case
              (with-repository-lock (publisher)
                (apply-transaction (repository-graph publisher) ops))
            (error (condition)
              (note-error publisher "federate" condition)
              (unless quiet
                (format *standard-output* "~&  ! federate ~a: ~a~%"
                        (repository-name publisher) condition))))
          (incf drawn (count-if (lambda (op) (typep op 'assert-relationship-op)) ops)))))
    drawn))

(defun federation-report (&key (repositories *repositories*))
  "What federation matched and what it could not, as a plist.

Both halves, because a count of edges drawn is not evidence on its own:
REQ-0027 R3 asks that an unmatched claim be reported rather than dropped, and
a parameterized route -- \"public/game/:gameid\" -- is designed to match
nothing and would otherwise look like a silent failure."
  (let ((published '()) (consumed '()) (matched '()))
    (dolist (repository repositories)
      (let ((graph (repository-graph repository)))
        (maphash (lambda (route entities)
                   (declare (ignore entities))
                   (pushnew route published :test #'string=))
                 (route-claims graph :publishes))
        (maphash (lambda (route entities)
                   (declare (ignore entities))
                   (pushnew route consumed :test #'string=))
                 (route-claims graph :consumes))
        (dolist (r (all-relationships graph))
          (when (and (federated-edge-p r) (getp r :route))
            (pushnew (getp r :route) matched :test #'string=)))))
    ;; Sorted into the variables before the plist is built, and each difference
    ;; taken from a copy. BUG-0038: CL:SORT is destructive on a list and the
    ;; arguments of one LIST form are evaluated left to right, so sorting
    ;; PUBLISHED in the first slot left it naming the sorted list from its old
    ;; head onwards -- and the SET-DIFFERENCE two slots later then took the
    ;; difference of a suffix of the claims against a suffix of the matches,
    ;; which is REQ-0027 R3's dropped claim produced by the function written to
    ;; report it. The COPY-LIST is the same hazard one step on: SET-DIFFERENCE
    ;; may share structure with its first argument, so sorting the difference in
    ;; place can relink conses :PUBLISHED has already been handed.
    (setf published (sort published #'string<)
          consumed  (sort consumed  #'string<)
          matched   (sort matched   #'string<))
    (list :published published
          :consumed consumed
          :matched matched
          :unmatched-published (sort (copy-list (set-difference published matched
                                                                :test #'string=))
                                     #'string<)
          :unmatched-consumed (sort (copy-list (set-difference consumed matched
                                                              :test #'string=))
                                    #'string<))))
