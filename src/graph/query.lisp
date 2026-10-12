;;;; The query protocol and the impact engine.
;;;; Implements Phase 1 Software Architecture SS5.3 and SS9.
;;;;
;;;; Read-only, always. Nothing here submits a transaction -- SS12.3 states
;;;; that as an architectural invariant ("No CALLS from a Knowledge Services
;;;; entity to any transaction-submitting function"), and the split between
;;;; this file and transaction.lisp is what makes it askable of the graph.
;;;;
;;;; SS5.3 names the view, not the graph, as what queries run against: SS7.1's
;;;; overlay model composes a committed base with a workspace's uncommitted
;;;; edits, "which is what all queries run against." LOOM-WORKSPACE does not
;;;; exist yet, so a view is a GRAPH today. Every function here takes its view
;;;; as its first argument and reads it only through the accessors in
;;;; graph-manager.lisp, so composing base and overlay behind that argument
;;;; later changes nothing in this file.
;;;;
;;;; SS5.3 also promises each of these "has an obvious translation to Cypher
;;;; later." That is why traversal is expressed in terms of one-hop steps
;;;; rather than clever index walking: the shape survives being pushed down
;;;; into a graph database.

(in-package :loom-graph)

;;;; ==================================================================
;;;; Entity search (SS5.3)
;;;; ==================================================================

(defun name-matches-p (entity pattern)
  "True when PATTERN occurs in ENTITY's name, case-insensitively.
Substring rather than glob: agents ask for \"overlay\" and mean anything with
overlay in the name, and a caller wanting precision can filter the result."
  (let ((name (and (slot-boundp entity 'name) (name entity))))
    (and (stringp name)
         (search pattern name :test #'char-equal)
         t)))

(defun properties-match-p (entity filters)
  "True when ENTITY has every property in FILTERS, a plist of key and value."
  (loop for (key value) on filters by #'cddr
        always (equal value (gethash key (properties entity)))))

(defun find-entities (view &key entity-type entity-types name-like
                                property-filters include-stale)
  "Entities matching every supplied criterion; all of them are optional, so
no criteria returns everything non-stale.

The entry point behind \"where is X defined\" (SS11's loom_find). Stale
entities are excluded by default for the same reason stale edges are excluded
from traversal: SS9 keeps unverified facts out of agent context until they are
re-confirmed.

ENTITY-TYPES is a set, beside the single ENTITY-TYPE. Both are kept because
seventeen callers pass the singular and none of them wants a list, and both
apply when both are given -- they intersect rather than one winning, which is
the only reading that cannot surprise a caller who passed both by accident.

No family logic here. This layer is handed a set of types and filters on it,
the same shape as PROPERTY-FILTERS and for the same reason: DES-0025 D4 keeps
vocabulary and configuration out of loom-graph. Deciding that six of these
types are documents and the rest are code is loom-knowledge's job."
  (flet ((admitted-p (e)
           (and (or (null entity-type) (eq entity-type (entity-type e)))
                (or (null entity-types) (member (entity-type e) entity-types))
                (properties-match-p e property-filters)
                (or include-stale (not (stale-p e))))))
    (if name-like
        ;; Looked up in the trigram index and not found by comparing the token
        ;; with every name: that scan was 21% of a `context' query's CPU after
        ;; the names had been lowercased once. BUG-0082.
        (let ((pattern (coerce (string-downcase name-like) 'name-string)))
          (loop for (e . name) in (name-candidates view pattern)
                when (and name
                          (contains-p pattern name)
                          (admitted-p e))
                  collect e))
        (loop for e in (all-entities view)
              when (admitted-p e)
                collect e))))

(deftype name-string () '(simple-array character (*)))

(defun contains-p (pattern string)
  "True when PATTERN occurs in STRING. Both are NAME-STRINGs.

What SEARCH answers for two strings, written for two simple character strings so
that the compiler can drop the sequence dispatch: SEARCH was 46% of a `context'
query's CPU after the names were lowercased once. BUG-0080."
  (declare (type name-string pattern string) (optimize (speed 3) (safety 0)))
  (let ((m (length pattern))
        (n (length string)))
    (cond ((zerop m) t)
          ((> m n) nil)
          (t (let ((first (schar pattern 0)))
               (loop for start of-type fixnum from 0 to (- n m)
                     thereis (and (char= first (schar string start))
                                  (loop for i of-type fixnum from 1 below m
                                        always (char= (schar pattern i)
                                                      (schar string (+ start i)))))))))))

(defstruct (name-index (:constructor make-name-index (entries trigrams)))
  "Every entity of a graph with its lowercased name, and where each three
character substring of those names occurs.

ENTRIES is a vector of (entity . name) in ALL-ENTITIES order, NAME being NIL for
an entity with none. TRIGRAMS maps a substring, as one integer, to the
ascending positions in ENTRIES of the names holding it."
  entries
  trigrams)

(declaim (inline trigram-key))
(defun trigram-key (string start)
  (declare (type name-string string) (type fixnum start) (optimize (speed 3) (safety 0)))
  (+ (ash (char-code (schar string start)) 42)
     (ash (char-code (schar string (+ start 1))) 21)
     (char-code (schar string (+ start 2)))))

(defun name-index (graph)
  "The NAME-INDEX of GRAPH, rebuilt after any change to it. See GRAPH-DERIVED."
  (graph-derived graph :name-index
                 (lambda ()
                   (let* ((entries (coerce
                                    (loop for e in (all-entities graph)
                                          collect (cons e (let ((name (and (slot-boundp e 'name)
                                                                           (name e))))
                                                            (and (stringp name)
                                                                 (coerce (string-downcase name)
                                                                         'name-string)))))
                                    'simple-vector))
                          (table (make-hash-table :test #'eql)))
                     (loop for position from 0 below (length entries)
                           for name = (cdr (svref entries position))
                           when (and name (>= (length name) 3))
                             do (let ((seen '()))
                                  (loop for start from 0 to (- (length name) 3)
                                        for key = (trigram-key name start)
                                        unless (member key seen)
                                          do (push key seen)
                                             (push position (gethash key table)))))
                     ;; Pushed in order, so each list is descending.
                     (maphash (lambda (key positions)
                                (setf (gethash key table)
                                      (coerce (nreverse positions) 'simple-vector)))
                              table)
                     (make-name-index entries table)))))

(defun name-candidates (graph pattern)
  "The (entity . name) entries of GRAPH whose name may hold PATTERN, in
ALL-ENTITIES order, and every one that does.

A pattern of three or more characters can only occur in a name holding each of
its trigrams, so the entries come from the pattern's rarest trigram and the
caller checks the rest. A shorter pattern has no trigram, and every entry is
returned. A trigram no name holds answers nothing."
  (let* ((index (name-index graph))
         (entries (name-index-entries index)))
    (if (< (length pattern) 3)
        (coerce entries 'list)
        (let ((best nil))
          (loop for start from 0 to (- (length pattern) 3)
                do (let ((positions (gethash (trigram-key pattern start)
                                             (name-index-trigrams index))))
                     (when (null positions)
                       (return-from name-candidates '()))
                     (when (or (null best) (< (length positions) (length best)))
                       (setf best positions))))
          (loop for position across best
                collect (svref entries position))))))

;;;; ==================================================================
;;;; System membership and cross-system edges (SS6.3)
;;;; ==================================================================
;;;;
;;;; SS6.3 adds EDGES-BETWEEN-SYSTEMS to the query protocol to back "the
;;;; architectural rule checks of Sections 10.4 and 14.3". Those checks are
;;;; the whole payoff of self-hosting -- the layering rules stated in the
;;;; document, executed against the index Loom builds of its own source -- and
;;;; they all have the same shape: are there edges of these types leaving this
;;;; system for that one.
;;;;
;;;; A system is a fact the analyzer that read the file asserted, not something
;;;; this layer derives: LOOM-ANALYZER writes :SYSTEM onto the seven code types
;;;; that already carry :LANGUAGE -- :FILE, :FUNCTION, :VARIABLE, :CLASS,
;;;; :INTERFACE, :METHOD, :TEST -- and onto :DOCUMENT, from a Lisp file's
;;;; IN-PACKAGE binding and from DEFAULT-SYSTEM-FOR-PATH's path segment for a
;;;; language with no such construct, and ENTITY-SYSTEM reads the property
;;;; back. Not every entity: :RULE, :DECISION and :CONCEPT are given no :SYSTEM
;;;; property at all and DOCUMENT-PROPERTIES writes them none (DES-0009 R1),
;;;; so they read as NIL here exactly as they did under the path convention,
;;;; which declined to place them for want of a :PATH -- a no-op for those
;;;; three, pinned by A-RULE-DOCUMENT-CARRIES-NO-SYSTEM-AT-ALL. DES-0009 moved
;;;; it there because the query layer
;;;; is the one place in the stack that structurally cannot know what a path
;;;; means in a given language, and a path convention is only ever a guess
;;;; standing in for the language's own grouping construct.
;;;;
;;;; The header this replaces predicted the shape of its own replacement --
;;;; "this function changes and no caller does" -- and that is what happened,
;;;; even though :REPOSITORY and :PACKAGE stayed unpopulated: the caller-facing
;;;; contract was never about where the value came from. EDGES-BETWEEN-SYSTEMS,
;;;; IN-SYSTEM-P and ENTITIES-IN-SYSTEM are unchanged, keyword-EQ comparison
;;;; and :OUTSIDE sentinel included.
;;;;
;;;; What moved with it is a whole vocabulary. :SYSTEM holds real package names
;;;; now (:LOOM-GRAPH, :LOOM-ANALYZER-TEST), not path segments (:GRAPH,
;;;; :ANALYZER), so a rule document's from-system: has to name the package --
;;;; DES-0009 R8, and the reason RULE-0001 to RULE-0003 were edited in the
;;;; same commit as this function. The two are the sides of one EQ comparison:
;;;; changing either alone makes every :no-edge check match nothing and `check`
;;;; report "No violations.", which is precisely the vacuous success BUG-0006
;;;; existed to close.

(defun entity-system (entity)
  "The system ENTITY belongs to, as a keyword, or NIL."
  (getp entity :system))

(defparameter *system-family-delimiters* '(#\/ #\.)
  "The characters that separate a package-name family from its members.

game-server spells its two families with `/' -- :GAME/MAP, :MPACKAGE/OBJECT --
and cl-dbi spells its three with `.' -- :DBI.DRIVER, :DBD.MYSQL.ERROR. Both
were counted directly (REQ-0029), and a scheme hard-coding either one answers
half the trees that have families at all.

`#\\-' is absent deliberately and this is the load-bearing omission. It is the
character joining all eight of Loom's own production/test package pairs --
:LOOM-ANALYZER and :LOOM-ANALYZER-TEST, and seven more of the same shape -- so
admitting it would make (:family :loom-analyzer) match the test package and
re-open BUG-0009's cause one, the thirty-seven RULE-0002 false positives
DES-0009 closed. cl-dbi reproduces the trap independently: :DBI-TEST.DBI would
join family :DBI. A dash is how a Lisp package name spells a space, not how it
spells a hierarchy.")

(defun system-satisfies-p (designator system)
  "Does SYSTEM satisfy DESIGNATOR?

Two designator shapes, and the first is the one every rule in docs/rules/ uses:

  :loom-graph      satisfied by :loom-graph and nothing else -- EQ, which is
                   what this comparison was before DES-0024 and what it stays
                   for every caller that passes a keyword.
  (:family :game)  satisfied by :game itself, and by any system whose name
                   begins with GAME followed by a family delimiter --
                   :GAME/MAP, :GAME/SYSTEM. Not :GAME-SERVER, not :GAME-TEST.

The anchoring is the whole design (REQ-0029 R3). A raw string prefix was
measured wrong on both trees that have families: `game' captures four
game-server packages belonging to no family, and `dbi' captures cl-dbi's two
test packages. Requiring a delimiter after the family name is what separates
a hierarchy from a coincidence of spelling.

Nesting needs no code of its own: :DBD.MYSQL.ERROR begins with DBD followed by
`.' and with DBD.MYSQL followed by `.', so it satisfies both families by this
one test."
  (cond ((null system) nil)
        ((keywordp designator) (eq designator system))
        ((and (consp designator) (eq :family (first designator)))
         (let ((family (string (second designator)))
               (name (string system)))
           (and (<= (length family) (length name))
                (string-equal family name :end2 (length family))
                (or (= (length family) (length name))
                    (member (char name (length family))
                            *system-family-delimiters* :test #'char=)))))))

(defun in-system-p (view id system)
  (let ((entity (get-entity view id)))
    (and entity (system-satisfies-p system (entity-system entity)))))

(defun entities-in-system (view system)
  (remove-if-not (lambda (e) (system-satisfies-p system (entity-system e)))
                 (all-entities view)))

(defun edges-between-systems (view from-system to-system &key rel-types include-stale)
  "Relationships of REL-TYPES running from FROM-SYSTEM into TO-SYSTEM.

Both are system designators in SYSTEM-SATISFIES-P's sense: a keyword names one
system, `(:family NAME)' names a family. Passing keywords is the behaviour this
function has always had.

TO-SYSTEM may be :OUTSIDE, meaning any system that does not satisfy FROM-SYSTEM,
which is the form the layering rules want: \"no edge leaves loom-ontology\" is a
question about everything that is not itself. That relative reading is what
makes a family rule useful rather than deafening -- where the from side is
`(:family :game)', outside means outside the family, so game-server's fourteen
`game/*' packages calling each other is internal traffic and not fourteen
packages' worth of findings. DES-0024 D2; the clause was already defined
against the from side, so this cost one word.

Edges to entities with no identifiable system are not counted -- an unplaceable
endpoint is not evidence of a violation."
  (loop for r in (all-relationships view)
        for from = (get-entity view (from-id r))
        for to   = (get-entity view (to-id r))
        when (and from to
                  (or include-stale (not (stale-p r)))
                  (or (null rel-types) (member (rel-type r) rel-types))
                  (system-satisfies-p from-system (entity-system from))
                  (let ((target (entity-system to)))
                    (and target
                         (if (eq to-system :outside)
                             (not (system-satisfies-p from-system target))
                             (system-satisfies-p to-system target)))))
          collect r))

(defun federated-relationships (view id &key (direction :out))
  "Edges at ID whose far endpoint lives in another repository. DES-0025.

NEIGHBORS cannot answer this and should not learn to. It returns entities, and
the far end of a federated edge has no entity in this graph by construction --
that is what federation means -- so NEIGHBORS drops these edges and every
caller of it stays correct. This returns the relationships themselves, which
carry enough to name the far end without reading another graph: the
repository, the entity's name, file and line, and the commit the tree was at
when the edge was derived.

loom-graph therefore learns nothing about repositories. It hands back edges
whose properties a caller may read, exactly as it does for every other edge."
  (remove-if-not
   (lambda (r) (getp r :federated))
   (append (when (member direction '(:out :both)) (relationships-from view id))
           (when (member direction '(:in :both)) (relationships-to view id)))))

;;;; ==================================================================
;;;; Neighbors (SS5.3)
;;;; ==================================================================

(defstruct (neighbor (:conc-name neighbor-))
  "One step away from an entity: what was reached, across which edge, and
which way the edge ran."
  (entity nil)
  (relationship nil)
  (direction nil :type (member :out :in nil)))

(defun neighbors (view id &key rel-types (direction :both) include-stale)
  "The entities one edge away from ID.

REL-TYPES limits which edge types are followed; NIL follows all. DIRECTION is
:OUT for edges originating at ID, :IN for edges terminating at it, or :BOTH.
This is the raw adjacency query -- impact-set below is the one that knows
which direction means what."
  (flet ((collect (rels way far)
           (loop for r in rels
                 for e = (get-entity view (funcall far r))
                 when (and e (or (null rel-types) (member (rel-type r) rel-types)))
                   collect (make-neighbor :entity e :relationship r :direction way))))
    (append
     (when (member direction '(:out :both))
       (collect (relationships-from view id :include-stale include-stale) :out #'to-id))
     (when (member direction '(:in :both))
       (collect (relationships-to view id :include-stale include-stale) :in #'from-id)))))

;;;; ==================================================================
;;;; Impact analysis (SS9)
;;;; ==================================================================
;;;;
;;;; "Impact of an entity E is the set of entities that may need attention if
;;;; E changes. The computation is a reverse traversal: impact flows against
;;;; the direction of dependency edges."
;;;;
;;;; The SS9 table is not transcribed here. It is already declared, per type,
;;;; in code-ontology.lisp as :TRANSITIVE-IMPACT and :IMPACT-DIRECTION, and
;;;; this engine reads the registry -- so the table has exactly one executable
;;;; form, and adding a relationship type teaches the impact engine about it
;;;; without touching this file.

(defparameter *default-impact-depth* 5
  "SS9: traversal is \"bounded by max-depth (default 5 ...)\".")

(defparameter *max-impact-depth* 20
  "SS9: \"... maximum 20\". Requests above this are clamped rather than
refused: the bound exists to keep a traversal from running away, and failing
an agent's query over an out-of-range tuning parameter helps nobody.")

(defstruct (hop (:conc-name hop-))
  "One edge of the path by which impact arrived somewhere.

EDGE-SOURCE and EDGE-CONFIDENCE are the *relationship's* provenance, not the
entity's, and they are here because a path is only as certain as its least
certain hop. BUG-0055: a JavaScript member call whose receiver names no class
in the tree fans out to every method of that property, and those edges are
already asserted `:inferred' at 1/N -- the number was simply not carried
anywhere a reader could see it, so an entity reached only through a guess was
reported exactly like one reached through a resolved call."
  (rel-type nil)
  (entity-id nil)
  (edge-source :structural)
  (edge-confidence 1.0))

(defstruct (impact-entry (:conc-name impact-entry-))
  "One impacted entity, with the evidence for why it is in the set.
SS9: \"Each result entry carries the path by which impact arrived and a depth,
so agents can rank near impact above distant impact.\""
  (entity nil)
  (depth 0 :type integer)
  (path '() :type list))                ; list of HOP, seed-exclusive

(defstruct (impact-result (:conc-name impact-result-))
  "The answer to \"what does changing this touch?\""
  (seed nil)
  (impacted '() :type list)             ; list of IMPACT-ENTRY, nearest first
  (collected '() :type list)            ; alist collect-as -> entities (SS4.3)
  (possibly-affected '() :type list)    ; reached only through a stale edge
  (truncated-p nil))                    ; frontier remained at max-depth

(defun impact-result-tests (result)
  (cdr (assoc :tests (impact-result-collected result))))

(defun impact-result-documents (result)
  (cdr (assoc :documents (impact-result-collected result))))

(defun impact-result-mentions (result)
  "Documents that merely name the seed. Separate from IMPACT-RESULT-DOCUMENTS
and from IMPACT-RESULT-DECISIONS deliberately: a mention claims that a file
writes this name, not that it governs what the name refers to. REQ-0014 R5."
  (cdr (assoc :mentions (impact-result-collected result))))

(defun impact-result-decisions (result)
  (cdr (assoc :decisions (impact-result-collected result))))

(defun impact-rel-types ()
  "The registered relationship types, partitioned the way SS9 traverses them.
Returns three alists of (type-key . spec): transitive, one-step, and terminal
-- the ones with a :COLLECT-AS, gathered into their own result field \"rather
than mixed into the impact set\"."
  (let ((transitive '()) (one-step '()) (terminal '()))
    (dolist (key (all-relationship-types))
      (let ((spec (find-relationship-type key)))
        (cond ((relationship-type-collect-as spec)      (push (cons key spec) terminal))
              ((relationship-type-transitive-impact spec) (push (cons key spec) transitive))
              (t                                        (push (cons key spec) one-step)))))
    (values transitive one-step terminal)))

(defun impact-step (view id rel-type direction &key include-stale)
  "The (relationship . neighbour-id) pairs impact flows to from ID.

The whole of the direction convention, in one place: :REVERSE means impact
runs against the edge, so it is the *incoming* edges that carry it -- a change
to a callee reaches the callers who point at it. :FORWARD means the edge
already points the way impact travels, which is how :BELONGS-TO carries a
member's change up to its container."
  (ecase direction
    (:reverse (loop for r in (relationships-to view id :rel-type rel-type
                                                       :include-stale include-stale)
                    collect (cons r (from-id r))))
    (:forward (loop for r in (relationships-from view id :rel-type rel-type
                                                         :include-stale include-stale)
                    collect (cons r (to-id r))))))

(defun impact-set (view id &key (max-depth *default-impact-depth*)
                                (include-tests t) (include-docs t))
  "What may need attention if the entity ID changes. NIL when ID is unknown.

Transitive types are followed breadth-first to MAX-DEPTH; one-step types are
followed a single hop from everything already impacted, so \"a changed
function marks its module, not the world\"; terminal types are gathered at the
end into their declared :COLLECT-AS field.

Stale edges are excluded from traversal entirely, but SS9 requires that what
they led to not simply vanish: anything reachable only across a stale edge is
returned in POSSIBLY-AFFECTED, so an agent sees the doubt instead of a silent
omission."
  (let ((seed (get-entity view id)))
    (when seed
      (multiple-value-bind (transitive one-step terminal) (impact-rel-types)
        (let* ((cap   (max 0 (min max-depth *max-impact-depth*)))
               (seen  (make-hash-table :test #'equal))
               (order '())                      ; impact entries, discovery order
               (truncated nil))
          (flet ((note (entity depth path)
                   (let ((entry (make-impact-entry :entity entity :depth depth :path path)))
                     (setf (gethash (id entity) seen) entry)
                     (push entry order)
                     entry)))
            ;; The seed is marked seen so it never re-enters as its own impact,
            ;; but it is not itself part of the impacted set.
            (setf (gethash id seen) (make-impact-entry :entity seed))

            ;; --- transitive types, breadth-first to CAP ------------------
            (let ((frontier (list (cons id '()))))
              (loop for depth from 1 to cap
                    while frontier
                    do (let ((next '()))
                         (dolist (item frontier)
                           (destructuring-bind (from . path) item
                             (dolist (pair transitive)
                               (dolist (step (impact-step view from (car pair)
                                                          (relationship-type-impact-direction
                                                           (cdr pair))))
                                 (let ((entity (get-entity view (cdr step))))
                                   (when (and entity (not (gethash (cdr step) seen)))
                                     (let ((extended
                                             (append path
                                                     (list (make-hop
                                                            :rel-type (rel-type (car step))
                                                            :entity-id (cdr step)
                                                            :edge-source (source (car step))
                                                            :edge-confidence
                                                            (confidence (car step)))))))
                                       (note entity depth extended)
                                       (push (cons (cdr step) extended) next))))))))
                         (setf frontier next)))
              (setf truncated (and frontier t)))

            ;; --- one-step types, a single hop that does not expand --------
            (dolist (base (cons (gethash id seen) (reverse order)))
              (dolist (pair one-step)
                (dolist (step (impact-step view (id (impact-entry-entity base)) (car pair)
                                           (relationship-type-impact-direction (cdr pair))))
                  (let ((entity (get-entity view (cdr step))))
                    (when (and entity (not (gethash (cdr step) seen)))
                      (note entity
                            (1+ (impact-entry-depth base))
                            (append (impact-entry-path base)
                                    (list (make-hop :rel-type (rel-type (car step))
                                                    :entity-id (cdr step)
                                                    :edge-source (source (car step))
                                                    :edge-confidence
                                                    (confidence (car step)))))))))))

            ;; --- terminal types, gathered into their own fields -----------
            (let ((impacted  (reverse order))
                  (collected '())
                  (possibly  '()))
              (dolist (base (cons (gethash id seen) impacted))
                (let ((from (id (impact-entry-entity base))))
                  (dolist (pair terminal)
                    (let ((field (relationship-type-collect-as (cdr pair)))
                          (way   (relationship-type-impact-direction (cdr pair))))
                      (when (case field
                              (:tests include-tests)
                              ;; :MENTIONS is gated with :DOCUMENTS rather
                              ;; than on its own: a caller asking for an
                              ;; impact set without documentation means
                              ;; without documentation, and a flag that
                              ;; suppressed the strong documentation edge
                              ;; while letting the weak one through would be
                              ;; the opposite of what it says.
                              ((:documents :mentions) include-docs)
                              (t t))
                        (dolist (step (impact-step view from (car pair) way))
                          (let ((entity (get-entity view (cdr step))))
                            (when entity
                              (let ((cell (or (assoc field collected)
                                              (car (push (cons field '()) collected)))))
                                (pushnew entity (cdr cell)))))))))
                  ;; --- what the stale edges led to, kept visible ----------
                  (dolist (pair (append transitive one-step terminal))
                    (dolist (step (impact-step view from (car pair)
                                               (relationship-type-impact-direction (cdr pair))
                                               :include-stale t))
                      (when (stale-p (car step))
                        (let ((entity (get-entity view (cdr step))))
                          (when (and entity (not (gethash (cdr step) seen)))
                            (pushnew entity possibly))))))))

              (make-impact-result
               :seed seed
               :impacted (stable-sort impacted #'< :key #'impact-entry-depth)
               :collected collected
               :possibly-affected possibly
               :truncated-p truncated))))))))
