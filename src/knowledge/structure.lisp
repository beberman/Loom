;;;; The structural report: what the index can say about a tree's shape.
;;;;
;;;; REQ-0021 R5 and DES-0022 S1. The first half of preparing a repository Loom
;;;; did not write is being able to describe it, and the whole value of doing
;;;; that here rather than in an LLM's prose is that everything below is
;;;; *derived*: every name in this report resolved against real code, so a
;;;; document generated from it cannot be rotten on the day it is written.
;;;;
;;;; What this file is careful not to do is the point of it. REQ-0021 splits a
;;;; codebase into what an index can produce and what it cannot, and puts the
;;;; invariants -- "one writer", "analyzers cannot reach storage" -- firmly in
;;;; the second half: "Code being consistent with an invariant is not evidence
;;;; the invariant was intended, and a violation is not evidence that it was
;;;; not." So this reports edges between systems and never calls one a
;;;; violation; it reports inbound edge counts and never calls an entity
;;;; important; and it reports what it could not attribute beside what it
;;;; could, so a reader can tell a small answer from a blind one.
;;;;
;;;; Read-only, like everything else in loom-knowledge (RULE-0003). It takes a
;;;; view and returns a plist. The console prints it, DES-0022 S3's document
;;;; generation will walk it, and neither may add a field the other has --
;;;; which is what keeps a generated architecture document confined to what was
;;;; actually measured.

(in-package :loom-knowledge)

(defparameter *structure-hub-limit* 12
  "How many hubs the report lists.

A cap, on *CONTEXT-RELATION-LIMIT*'s precedent: the ranking is over every
entity in the index and the tail is uninformative. Twelve because the report is
read whole by a human and by a document generator, and neither wants a page of
them.")

(defparameter *structure-entry-point-limit* 25
  "How many entry points the report lists.

Larger than the hub cap and still a cap. On a tree Loom cannot read well, this
list is mostly DES-0001's blind spots rather than real entry points -- see
ENTRY-POINT-QUALIFIER -- so a long one is a signal about the index rather than
about the code, and the count travels with it either way.")

(defparameter *definition-types* '(:function :method :interface :class :variable)
  "Entity types that are definitions in source, for per-system counts.
:FILE and :PACKAGE are containers rather than definitions and :TEST is counted
separately, because \"how much of this system is tested\" is the question the
per-system numbers exist to answer.

:MODULE is not here since PLAN-0059 FINDINGS 5: it is a dependency a manifest
declares (DES-0055 D2), not a definition in source, and HUB-REPORT would rank
react's inbound :IMPORTS above every function.")

;;;; ==================================================================
;;;; Systems, and the edges that actually run between them
;;;; ==================================================================

(defun system-tally (view)
  "Alist of system -> (entities definitions tests), for every placed system.

One walk rather than ENTITIES-IN-SYSTEM per system: that function scans every
entity, and asking it about forty-eight systems would scan the index
forty-eight times. Entities with no system are counted separately by the
caller; they are not a system called NIL."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entity (all-entities view))
      (let ((system (entity-system entity)))
        (when system
          (let ((row (or (gethash system table)
                         (setf (gethash system table) (list 0 0 0)))))
            (incf (first row))
            (when (member (entity-type entity) *definition-types*) (incf (second row)))
            (when (eq :test (entity-type entity)) (incf (third row)))))))
    table))

(defun tested-units-by-system (view)
  "System -> how many distinct entities in it something tests.

Derived from :TESTS edges, which RESOLVE-TESTS produces from what a test's body
actually calls, so this is coverage as the index observed it rather than as a
naming convention suggests. Under-reports wherever DES-0001's blind spots do --
a test whose calls are made inside a macro body attributes to nothing."
  (let ((seen (make-hash-table :test #'equal))
        (table (make-hash-table :test #'eq)))
    (dolist (r (all-relationships view))
      (when (eq :tests (rel-type r))
        (unless (gethash (to-id r) seen)
          (setf (gethash (to-id r) seen) t)
          (let* ((target (get-entity view (to-id r)))
                 (system (and target (entity-system target))))
            (when system (incf (gethash system table 0)))))))
    table))

(defun system-edge-tally (view)
  "Alist of (from . to) -> (count . rel-types), for edges crossing a system
boundary.

EDGES-BETWEEN-SYSTEMS answers this for one ordered pair and scans every
relationship to do it, so asking it for every pair on a forty-eight-system tree
is two thousand scans. One walk instead, tallying as it goes.

Both directions are reported and neither is judged. A calls B and B calls A is
a fact; calling one of them wrong requires knowing which was intended, and that
is exactly the intent REQ-0021 says no index holds."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (r (all-relationships view))
      (unless (stale-p r)
        (let* ((from (get-entity view (from-id r)))
               (to   (get-entity view (to-id r)))
               (from-system (and from (entity-system from)))
               (to-system   (and to (entity-system to))))
          (when (and from-system to-system (not (eq from-system to-system)))
            (let ((row (or (gethash (cons from-system to-system) table)
                           (setf (gethash (cons from-system to-system) table)
                                 (cons 0 '())))))
              (incf (car row))
              (pushnew (rel-type r) (cdr row)))))))
    table))

;;;; ==================================================================
;;;; Which prose describes which system
;;;;
;;;; The half of an architecture a hand-written document has and a derived one
;;;; was missing. REQ-0021 says it plainly: the markdown "says what the author
;;;; believed, which is exactly the material the index cannot supply."
;;;;
;;;; A first version of this report left it out entirely, on the reading that
;;;; R6 confines a generated document to what the report derived. That was
;;;; right about R6 and wrong about the report: which document describes which
;;;; system *is* derivable, from the same :MENTIONS edges the mention band
;;;; already ranks on. Measured on ~/lisp/game-server: docs/data-layer.md names
;;;; eighteen entities in DATA-API and seven in MPACKAGE/NAMESPACE, which is not
;;;; a guess about what it is about.
;;;;
;;;; The line this must not cross is paraphrase. Summarising data-layer.md into
;;;; a sentence of generated prose is the plausible, unfalsifiable text R6
;;;; exists to stop. Pointing at it, with the count that earned the pointer, is
;;;; a measurement -- and it turns the generated document into a map into the
;;;; prose rather than a replacement for it.
;;;; ==================================================================

(defparameter *system-prose-limit* 4
  "How many documents are attributed to one system.
Ranked by how much of the system each names, so the tail is prose that
mentioned one thing in passing.")

(defun prose-attribution (view)
  "Two values: system -> documents describing it, and document -> systems.

Both from the same walk over :MENTIONS edges. A document naming eighteen things
in one system is describing that system; one naming a single entity is
mentioning it. The counts travel so a reader can tell those apart rather than
being asked to trust the attribution."
  (let ((by-system (make-hash-table :test #'eq))
        (by-document '()))
    (dolist (document (entities-of-type view :document))
      (let ((tally (make-hash-table :test #'eq))
            (name (and (slot-boundp document 'name) (princ-to-string (name document)))))
        (dolist (n (neighbors view (id document) :rel-types '(:mentions) :direction :out))
          (let ((system (entity-system (neighbor-entity n))))
            (when system (incf (gethash system tally 0)))))
        (when (plusp (hash-table-count tally))
          (let ((systems (sort (loop for system being the hash-keys of tally
                                       using (hash-value count)
                                     collect (list :name system :names count))
                               #'> :key (lambda (row) (getf row :names)))))
            (push (list :document name
                        :path (or (getp document :path) (origin-file document))
                        ;; The resolution rate, so a reader can tell a document
                        ;; about this codebase from one about something else --
                        ;; the same measurement the drift report ranks on.
                        :percent (let ((row (document-prose-row view document)))
                                   (and row (getf row :percent)))
                        :systems systems)
                  by-document)
            (dolist (row systems)
              (push (list :document name :names (getf row :names))
                    (gethash (getf row :name) by-system)))))))
    (values by-system
            (sort (nreverse by-document) #'>
                  :key (lambda (row) (reduce #'+ (getf row :systems)
                                             :key (lambda (s) (getf s :names))))))))

(defun system-prose (by-system system)
  "The documents describing SYSTEM, best first and capped."
  (let ((rows (sort (copy-list (gethash system by-system)) #'>
                    :key (lambda (row) (getf row :names)))))
    (if (> (length rows) *system-prose-limit*)
        (subseq rows 0 *system-prose-limit*)
        rows)))

;;;; ==================================================================
;;;; Protocols, entry points, hubs
;;;; ==================================================================

(defun protocol-report (view)
  "Every :INTERFACE and the definitions that implement it.

A generic function with methods on it is the one architectural shape the index
can name without interpreting anything: the :IMPLEMENTS edge is structural, and
an interface with several implementors is a protocol whether or not anyone
called it one. An interface with none is reported too -- it is a contract
nothing in this tree answers, which is a fact worth seeing."
  (flet ((entity-name (e) (if (slot-boundp e 'name) (princ-to-string (name e)) "")))
    (loop for interface in (entities-of-type view :interface)
          for implementors = (loop for n in (neighbors view (id interface)
                                                       :rel-types '(:implements)
                                                       :direction :in)
                                   collect (neighbor-entity n))
          for ordered = (sort (copy-list implementors) #'string< :key #'entity-name)
          collect (list :name (entity-name interface)
                        :system (entity-system interface)
                        :location (entity-location interface)
                        :implementor-count (length implementors)
                        :implementors
                        (loop for e in ordered
                              collect (list :name (entity-name e)
                                            :location (entity-location e)))))))

(defun inbound-count (view id)
  (length (remove-if #'stale-p (relationships-to view id))))

(defun entry-point-qualifier (view)
  "What makes the entry-point list less than it looks, as a sentence, or NIL.

DES-0001's blind spots land squarely on this computation: a definition called
only from inside a macro body has no attributed :CALLS edge, so it is
indistinguishable from one nothing calls. A list that presented those as entry
points would be CON-0001's fabricated fact in list form, so the number of call
sites Loom could not attribute travels with the list and says so."
  (let ((sites (length (entities-of-type view :call-site))))
    (when (plusp sites)
      (format nil "~d call site~:p could not be attributed to a definition, ~
so some of these are called from places the index cannot see (DES-0001)."
              sites))))

(defun entry-point-report (view)
  "Callable definitions with no in-tree caller, capped and qualified."
  (let ((found (loop for type in '(:function :method :interface)
                     append (loop for entity in (entities-of-type view type)
                                  ;; DES-0054 D8. A function a framework calls has no
                                  ;; caller in the tree and is not an unexplained
                                  ;; definition: it is in the trigger band.
                                  when (and (null (getp entity :trigger))
                                            (zerop (length
                                                    (remove-if-not
                                                     (lambda (r) (member (rel-type r)
                                                                         '(:calls :implements)))
                                                     (relationships-to view (id entity))))))
                                    collect entity))))
    (setf found (sort found #'string<
                      :key (lambda (e) (princ-to-string
                                        (and (slot-boundp e 'name) (name e))))))
    (values (mapcar #'entity-summary
                    (if (> (length found) *structure-entry-point-limit*)
                        (subseq found 0 *structure-entry-point-limit*)
                        found))
            (length found))))

(defun triggered-report (view)
  "Entities a declaration marked as entry points, grouped by trigger. DES-0054 D8.

One plist per trigger, in name order: :TRIGGER, :COUNT, and :ENTITIES capped at
*STRUCTURE-ENTRY-POINT-LIMIT*, each row carrying :DEPLOYED, which is :YES, :NO or
:UNKNOWN once a codebase covers it and absent before. :NO is the row worth
reading: a function registered and never deployed."
  (let ((groups (make-hash-table :test #'eq)))
    (dolist (type '(:function :method :variable))
      (dolist (entity (entities-of-type view type))
        (let ((trigger (getp entity :trigger)))
          (when trigger (push entity (gethash trigger groups))))))
    (loop for trigger in (sort (loop for key being the hash-keys of groups collect key)
                               #'string< :key #'symbol-name)
          for found = (sort (copy-list (gethash trigger groups)) #'string<
                            :key (lambda (e) (princ-to-string (name e))))
          collect (list :trigger trigger
                        :count (length found)
                        :entities
                        (loop for entity in (subseq found 0 (min (length found)
                                                                *structure-entry-point-limit*))
                              collect (append
                                       (entity-summary entity)
                                       (let ((deployed (getf (first (getp entity :entry-point))
                                                             :deployed)))
                                         (when deployed (list :deployed deployed)))))))))

(defun hub-report (view)
  "The most-depended-on definitions, by inbound edge count.

A measurement and not a verdict. What a hub *means* -- a core abstraction, or a
utility everything reaches for, or a god object -- is a judgement, and the
report's job is to hand a reader the number rather than the adjective."
  (let ((ranked (sort (loop for type in *definition-types*
                            append (loop for entity in (entities-of-type view type)
                                         for inbound = (inbound-count view (id entity))
                                         when (plusp inbound)
                                           collect (cons entity inbound)))
                      (lambda (a b)
                        (if (= (cdr a) (cdr b))
                            (string< (princ-to-string (and (slot-boundp (car a) 'name)
                                                           (name (car a))))
                                     (princ-to-string (and (slot-boundp (car b) 'name)
                                                           (name (car b)))))
                            (> (cdr a) (cdr b)))))))
    (loop for (entity . inbound) in (subseq ranked 0 (min *structure-hub-limit*
                                                          (length ranked)))
          collect (append (entity-summary entity) (list :inbound inbound)))))

;;;; ==================================================================
;;;; The report
;;;; ==================================================================

(defun structure-report (view &key commit commit-reason branch diff dirty drift
                                  repository)
  "What the index can say about this tree's shape, as data. REQ-0021 R5.

COMMIT is what the report was derived from, so a document generated later can
be checked against the tree it described; the caller supplies it because
loom-knowledge does not run subprocesses and does not know what a repository
is (RULE-0003, and DES-0022 D3).

BRANCH, DIFF, DIRTY and DRIFT are REQ-0050 R1 and R3 and arrive the same way,
from LOOM-WORKSPACE:INDEX-PROVENANCE. Until they did, this report named the
commit `git rev-parse HEAD\' printed when the report was built, which measures
the tree and is read as measuring the index -- and the two differ by every
uncommitted edit and by however long since the watcher last polled. DRIFT is
the half that answers the question and DIRTY says whether the commit named is
the whole of what was read.

:INDEXED-P is the field that keeps this honest on a repository Loom cannot
read. front-end holds 455 .js files, produces 27 entities and no relationships
at all, and a report of empty lists there is indistinguishable from a report on
a simple, clean architecture. One is a description and the other is an absence,
and only this flag tells them apart."
  (let* ((entities (all-entities view))
         (relationships (all-relationships view))
         (tally (system-tally view))
         (tested (tested-units-by-system view))
         (edges (system-edge-tally view))
         (placed (loop for entity in entities count (entity-system entity))))
    (multiple-value-bind (by-system prose) (prose-attribution view)
    (multiple-value-bind (entry-points entry-point-count) (entry-point-report view)
      (list
       :repository repository
       :commit commit
       :commit-reason commit-reason
       :branch branch
       :diff diff
       :dirty dirty
       :drift drift
       :entities (length entities)
       :relationships (length relationships)
       ;; Not "is this tree simple" but "did Loom read it". A tree with entities
       ;; and no relationships is one whose language has no analyzer.
       :indexed-p (and (plusp (length entities)) (plusp (length relationships)))
       :unplaced-entities (- (length entities) placed)
       :systems
       (sort (loop for system being the hash-keys of tally using (hash-value row)
                   collect (list :name system
                                 :entities (first row)
                                 :definitions (second row)
                                 :tests (third row)
                                 :tested-units (gethash system tested 0)
                                 ;; What an author wrote about this system, if
                                 ;; anything did. The half the index cannot
                                 ;; supply, attached to the half it can.
                                 :described-by (system-prose by-system system)))
             #'> :key (lambda (row) (getf row :entities)))
       :system-edges
       (sort (loop for pair being the hash-keys of edges using (hash-value row)
                   collect (list :from (car pair) :to (cdr pair)
                                 :count (car row)
                                 :rel-types (sort (copy-list (cdr row)) #'string<
                                                  :key #'symbol-name)))
             #'> :key (lambda (row) (getf row :count)))
       :protocols
       (sort (protocol-report view) #'> :key (lambda (row) (getf row :implementor-count)))
       :entry-points entry-points
       :entry-point-count entry-point-count
       :entry-point-qualifier (entry-point-qualifier view)
       :triggered (triggered-report view)
       :hubs (hub-report view)
       ;; Ordered by how much of the codebase each names, so the prose most
       ;; worth reading first is first.
       :prose prose)))))

;;;; ==================================================================
;;;; Rendering -- formats, decides nothing (DES-0022 D4)
;;;; ==================================================================

(defun render-structure (report)
  "REPORT as the text block a human reads.

Formats and does not decide. Every number here is in the plist, and nothing in
the plist is omitted because this function judged it uninteresting -- DES-0022
D4 requires that the document generator and this printer walk the same data, so
a judgement made here is one the generator cannot reproduce and would invent
differently."
  (with-output-to-string (out)
    (format out "~&# Structure of ~a~@[ at ~a~]~@[ (~a)~]~@[ ~a~]~%"
            (or (getf report :repository) "this repository") (getf report :commit)
            (getf report :branch)
            (and (getf report :dirty) "+ uncommitted edits"))
    (when (getf report :commit-reason)
      (format out "~&# commit unknown: ~a~%" (getf report :commit-reason)))
    ;; REQ-0050 R3. The comparison is made here rather than left to a reader
    ;; holding two hashes: what a caller wants to know is whether this report
    ;; describes the tree they are looking at, and the answer is a sentence.
    ;;
    ;; Printed on both outcomes, because a report that says nothing about
    ;; freshness cannot be told from one whose index is current -- and this is
    ;; the surface REQ-0050 was written from, where a commit field agreeing
    ;; with HEAD was read as the index agreeing with the tree.
    (let ((drift (getf report :drift)))
      (format out "~&# ~a~%"
              (cond ((null drift) "freshness unknown: no drift was measured")
                    ((zerop drift) "index current with the tree")
                    (t (format nil "STALE INDEX: ~d claimed file~:p changed since it was read"
                               drift)))))
    (format out "~&# ~d entities, ~d relationships~@[, ~d with no system~]~%"
            (getf report :entities) (getf report :relationships)
            (let ((n (getf report :unplaced-entities))) (and (plusp n) n)))
    (unless (getf report :indexed-p)
      ;; Said first and said plainly. This is the case a reader is most likely
      ;; to misread as a clean result.
      (format out "~&
## nothing here is indexed
No relationships were derived, so no analyzer claimed this tree's source. What
follows describes what Loom could read, which may be only its documents.~%"))
    (format out "~&~%## systems~%")
    (dolist (row (getf report :systems))
      (format out "  ~28a ~5d entities  ~4d definitions  ~4d tests covering ~d~%"
              (getf row :name) (getf row :entities) (getf row :definitions)
              (getf row :tests) (getf row :tested-units))
      ;; What an author wrote about this system. A pointer and a count, never a
      ;; paraphrase -- the reader is sent to the document rather than given a
      ;; generated summary of it.
      (dolist (prose (getf row :described-by))
        (format out "      described by ~a (~d name~:p here)~%"
                (getf prose :document) (getf prose :names))))
    (when (null (getf report :systems)) (format out "  (none placed)~%"))
    (format out "~&~%## edges between systems~%")
    (format out "  Both directions are reported and neither is judged. A cycle here is a~%")
    (format out "  fact about the code, not a finding -- which one was intended is not in~%")
    (format out "  the index.~%")
    (dolist (row (getf report :system-edges))
      (format out "  ~24a -> ~24a ~5d  ~{~(~a~)~^ ~}~%"
              (getf row :from) (getf row :to) (getf row :count) (getf row :rel-types)))
    (when (null (getf report :system-edges)) (format out "  (none)~%"))
    (format out "~&~%## protocols~%")
    (dolist (row (getf report :protocols))
      (format out "  ~a~@[  [~a]~]  ~d implementor~:p~{~%      ~a~}~%"
              (getf row :name) (getf row :location) (getf row :implementor-count)
              (mapcar (lambda (i) (format nil "~a~@[  [~a]~]"
                                          (getf i :name) (getf i :location)))
                      (getf row :implementors))))
    (when (null (getf report :protocols)) (format out "  (none)~%"))
    (format out "~&~%## entry points~%")
    (format out "  ~d definition~:p with no caller in this tree~@[, showing ~d~].~%"
            (getf report :entry-point-count)
            (let ((shown (length (getf report :entry-points))))
              (and (< shown (getf report :entry-point-count)) shown)))
    (when (getf report :entry-point-qualifier)
      (format out "  ~a~%" (getf report :entry-point-qualifier)))
    (dolist (row (getf report :entry-points))
      (format out "  ~(~a~) ~a~@[  [~a]~]~%"
              (getf row :type) (getf row :name) (getf row :location)))
    (format out "~&~%## entry points by trigger~%")
    (dolist (group (getf report :triggered))
      (format out "  ~(~a~)  ~d~%" (getf group :trigger) (getf group :count))
      (dolist (row (getf group :entities))
        (format out "    ~(~a~) ~a~@[  [~a]~]~@[  deployed: ~(~a~)~]~%"
                (getf row :type) (getf row :name) (getf row :location)
                (getf row :deployed))))
    (when (null (getf report :triggered)) (format out "  (none declared)~%"))
    (format out "~&~%## hubs, by inbound edges~%")
    (dolist (row (getf report :hubs))
      (format out "  ~5d  ~(~a~) ~a~@[  [~a]~]~%"
              (getf row :inbound) (getf row :type) (getf row :name)
              (getf row :location)))
    (when (null (getf report :hubs)) (format out "  (none)~%"))
    (format out "~&~%## prose describing this codebase~%")
    (format out "  What an author wrote, which is the half no index can supply. Ranked by~%")
    (format out "  how much of the code each names; the percentage is how much of the~%")
    (format out "  document's own vocabulary resolved, so a low one is prose about~%")
    (format out "  something this repository does not contain.~%")
    (dolist (row (getf report :prose))
      (format out "  ~a~@[  (~d% of its names resolve)~]~%"
              (getf row :document) (getf row :percent))
      (format out "      ~{~a~^  ~}~%"
              (mapcar (lambda (s) (format nil "~a:~d" (getf s :name) (getf s :names)))
                      (getf row :systems))))
    (when (null (getf report :prose)) (format out "  (none indexed)~%"))))
