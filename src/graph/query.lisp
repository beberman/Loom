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

(defun find-entities (view &key entity-type name-like property-filters include-stale)
  "Entities matching every supplied criterion; all of them are optional, so
no criteria returns everything non-stale.

The entry point behind \"where is X defined\" (SS11's loom_find). Stale
entities are excluded by default for the same reason stale edges are excluded
from traversal: SS9 keeps unverified facts out of agent context until they are
re-confirmed."
  (loop for e in (all-entities view)
        when (and (or (null entity-type) (eq entity-type (entity-type e)))
                  (or (null name-like) (name-matches-p e name-like))
                  (properties-match-p e property-filters)
                  (or include-stale (not (stale-p e))))
          collect e))

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
;;;; property at all and DOCUMENT-PROPERTIES writes them none (ARCH-0009 R1),
;;;; so they read as NIL here exactly as they did under the path convention,
;;;; which declined to place them for want of a :PATH -- a no-op for those
;;;; three, pinned by A-RULE-DOCUMENT-CARRIES-NO-SYSTEM-AT-ALL. ARCH-0009 moved
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
;;;; ARCH-0009 R8, and the reason RULE-0001 to RULE-0003 were edited in the
;;;; same commit as this function. The two are the sides of one EQ comparison:
;;;; changing either alone makes every :no-edge check match nothing and `check`
;;;; report "No violations.", which is precisely the vacuous success BUG-0006
;;;; existed to close.

(defun entity-system (entity)
  "The system ENTITY belongs to, as a keyword, or NIL."
  (getp entity :system))

(defun in-system-p (view id system)
  (let ((entity (get-entity view id)))
    (and entity (eq system (entity-system entity)))))

(defun entities-in-system (view system)
  (remove-if-not (lambda (e) (eq system (entity-system e))) (all-entities view)))

(defun edges-between-systems (view from-system to-system &key rel-types include-stale)
  "Relationships of REL-TYPES running from FROM-SYSTEM into TO-SYSTEM.

TO-SYSTEM may be :OUTSIDE, meaning any system other than FROM-SYSTEM, which
is the form the layering rules want: \"no edge leaves loom-ontology\" is a
question about everything that is not itself. Edges to entities with no
identifiable system are not counted -- an unplaceable endpoint is not evidence
of a violation."
  (loop for r in (all-relationships view)
        for from = (get-entity view (from-id r))
        for to   = (get-entity view (to-id r))
        when (and from to
                  (or include-stale (not (stale-p r)))
                  (or (null rel-types) (member (rel-type r) rel-types))
                  (eq from-system (entity-system from))
                  (let ((target (entity-system to)))
                    (and target
                         (if (eq to-system :outside)
                             (not (eq target from-system))
                             (eq to-system target)))))
          collect r))

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
  "One edge of the path by which impact arrived somewhere."
  (rel-type nil)
  (entity-id nil))

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
                                                            :entity-id (cdr step))))))
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
                                                    :entity-id (cdr step))))))))))

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
