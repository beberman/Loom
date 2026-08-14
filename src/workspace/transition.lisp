;;;; Document state transitions -- the write path of REQ-0022, shaped by
;;;; DES-0019.
;;;;
;;;; Loom had never written a document before this file. Everything above it
;;;; reads: an analyzer turns a file into operations, the graph stores them, and
;;;; loom-knowledge answers questions about what is stored. The one thing the
;;;; workflow asked a human to do by hand -- move a document out of draft when
;;;; the plan that implemented it lands -- was a rule (RULE-0005) that could
;;;; never be checked, because `check' inspects a state and the rule describes a
;;;; transition. There is no snapshot in which "a plan reached final and did not
;;;; restate what it implemented" is visible: by the time anything looks, the
;;;; only evidence is a document whose status is now false, which is
;;;; indistinguishable from one nobody has finished yet.
;;;;
;;;; So the transition is performed instead of remembered, and this is where it
;;;; is performed. Four properties carry the whole design:
;;;;
;;;;   The edit is one line, found by a rule that cannot be wrong. A block
;;;;   scalar's content must be indented past the key that introduces it and
;;;;   every top-level key sits at column zero, so the first line beginning
;;;;   `status:' with no leading whitespace *is* the top-level key. A `status:'
;;;;   written in prose -- and the documents in this tree are full of them -- is
;;;;   indented and invisible to the scan. Everything else in the file is copied
;;;;   through byte for byte: no YAML round-trip, because reserialising from the
;;;;   graph would destroy key order, block scalars, comments and every field
;;;;   the ontology does not model.
;;;;
;;;;   The verdict comes from the caller. Whether a plan *fully* implemented
;;;;   what it refines is a judgement about intent, not a fact in the graph, and
;;;;   a command that guessed `implemented' would be writing a false claim into
;;;;   a file and then indexing it -- CON-0001's fabricated fact with a commit
;;;;   behind it.
;;;;
;;;;   The propagation query is the part a person will not run. A document may
;;;;   leave draft only if no *other* unfinished plan also refines it. That is
;;;;   one graph query and it is exactly what someone closing a long change does
;;;;   not think to do.
;;;;
;;;;   It plans before it applies. A filesystem is not transactional, so
;;;;   everything is resolved, read, located, validated and probed before one
;;;;   byte is written -- APPLY-TRANSACTION's discipline, applied to files.
;;;;
;;;; It lives in loom-workspace because it writes files and then reindexes,
;;;; which is this system's existing job: loom-knowledge is read-only by
;;;; RULE-0003 and an analyzer may not touch the tree at all.

(in-package :loom-workspace)

;;;; ==================================================================
;;;; CON-0004's vocabulary, per category (DES-0019 D3)
;;;; ==================================================================

(defparameter *workflow-status-vocabulary*
  '(("requirements" (:draft :accepted :implemented :partial)             (:implemented))
    ("design"       (:draft :accepted :implemented :partial :superseded) (:implemented))
    ("plans"        (:draft :final)                                      (:final))
    ("bugs"         (:open :closed)                                      (:closed))
    ("reviews"      (:open :closed)                                      (:closed))
    ("arch"         (:draft :accepted :superseded)                       ())
    ("decisions"    (:proposed :accepted :superseded :rejected)          ())
    ("rules"        (:active :retired)                                   ()))
  "Document category -> (allowed statuses, terminal statuses).

Per category and not per entity type, which is the whole reason this table
exists rather than the ontology being read alone. Four of CON-0004's nine
categories -- requirements, plans, reviews, bugs -- all land on the :DOCUMENT
entity type, whose declared :ONE-OF is the union of their four vocabularies.
Validating against that union alone would let a plan be set to `closed' and a
bug to `final', which is not a status the workflow has.

The terminal column is RULE-0007's, read literally: \"implemented for a REQ or
a DES, final for a PLAN, closed for a BUG or REV\". A partial document stays
flat, because it has an OUTSTANDING section, which is work. `superseded' is
deliberately not terminal for a design even though a superseded design is
finished -- the rule names one word and departing from it silently would put
this table and the document a human reads into disagreement, which is the drift
the rule was written to stop.

The last three categories have no terminal status at all and therefore no
completed/ subdirectory. An accepted decision, an active rule and a current
architecture document are in force rather than finished, and filing them under a
name meaning \"done with these\" would bury exactly the documents `impact'
exists to surface.

Concepts are absent on purpose and their absence is not what refuses them:
:CONCEPT declares no :STATUS property at all, so DOCUMENT-STATUS-VOCABULARY
refuses one before it ever consults this table.")

(defun category-vocabulary (category)
  "Two values: the statuses CATEGORY allows and the ones that are terminal.
The second value is NIL for a category with no completed/ subdirectory, which
is also what an unregistered category returns."
  (let ((entry (assoc category *workflow-status-vocabulary* :test #'string-equal)))
    (values (second entry) (third entry))))

(defun document-status-vocabulary (entity)
  "Two values for ENTITY: the statuses it may take, and the terminal ones.

NIL for the first when the entity's type declares no :STATUS property, which is
DES-0019 D3's refusal: four concepts in this tree carry no status line and
:CONCEPT has nowhere to put one, so inserting a line would write a fact the
index cannot hold.

The category narrows the ontology rather than replacing it. Where a category is
registered above, the answer is the intersection -- so a plan gets two statuses
out of :DOCUMENT's ten, and a status the ontology would refuse cannot be smuggled
in by a table entry. Where it is not, the ontology's declaration stands alone,
which is the honest answer for a document filed somewhere the workflow does not
name."
  (let ((declared (let ((spec (find-property (entity-type entity) :status)))
                    (and spec (property-one-of spec)))))
    (if (null declared)
        (values nil nil)
        (multiple-value-bind (allowed terminal)
            (category-vocabulary (getp entity :category))
          (if allowed
              (values (remove-if-not (lambda (s) (member s declared)) allowed)
                      terminal)
              (values declared nil))))))

(defun terminal-status-p (entity status)
  "True when STATUS means ENTITY's document is finished and belongs in completed/."
  (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
    (declare (ignore allowed))
    (and (member status terminal) t)))

;;;; ==================================================================
;;;; Finding the document (DES-0019 D4)
;;;; ==================================================================

(defun document-entity-p (entity)
  (member (entity-type entity) *document-types*))

(defun documents-named (graph designator)
  "Every document entity DESIGNATOR could mean, matched on doc-id then on name.

Two passes rather than one index, because a doc-id match is what a caller
almost always means and a name match is the fallback for a document that has no
id. Returning the whole set rather than the best of it is CON-0001: two files
carrying one id is a real state this tree can reach -- an id-keyed type absorbs
them into one entity, a path-keyed type keeps two -- and picking one of them
before editing a file would be the worst possible moment to guess."
  (flet ((collect (test)
           (loop for type in *document-types*
                 append (remove-if-not test (entities-of-type graph type)))))
    (or (collect (lambda (e) (let ((id (getp e :doc-id)))
                               (and id (string-equal id designator)))))
        (collect (lambda (e) (and (slot-boundp e 'name)
                                  (string-equal (name e) designator)))))))

(defun document-category-of (entity)
  "The docs/ subdirectory ENTITY was read from, or NIL.
:CATEGORY for the types that declare it, and the path for the ones that do not
-- :DECISION, :RULE and :CONCEPT carry no such property, and a transition that
could not name a decision's category could not validate its status."
  (or (getp entity :category)
      (let ((file (origin-file entity)))
        (and file (document-category file)))))

(defun document-file (repository entity)
  "The absolute path ENTITY was read from, or NIL when it has no origin.
ORIGIN-FILE rather than a :PATH property, because only :DOCUMENT declares one:
the id-keyed types are deliberately findable after their file moves, and the
origin is the one place every document type records where it came from."
  (let ((relative (origin-file entity)))
    (when relative
      (merge-pathnames (parse-namestring relative) (repository-root repository)))))

;;;; ==================================================================
;;;; The edit: one line, found by a rule that cannot be wrong (D2)
;;;; ==================================================================

(defun whitespace-char-p (character)
  (member character '(#\Space #\Tab #\Return #\Newline #\Page)))

(defun line-end (contents start)
  "Two values: the index just past the last character of the line beginning at
START, and the index the next line begins at."
  (let ((newline (position #\Newline contents :start start)))
    (if newline
        (values newline (1+ newline))
        (values (length contents) (length contents)))))

(defun status-key-line-p (line)
  "True when LINE is a top-level `status:' key.

Column zero is the whole test, and it is not a heuristic. A block scalar's
content must be indented more than the key that introduces it, and every
top-level key of a YAML mapping sits at column zero, so a line whose first
character is not whitespace is not inside a block scalar. `status:' at column
zero is therefore the document's own status field, and the ones this file's
sibling documents write in prose -- indented under a summary: or a body: -- are
invisible here by construction.

Case-sensitive, because YAML keys are: `Status:' is a different key and
silently treating it as this one would edit a field nothing reads."
  (let ((key "status:"))
    (and (>= (length line) (length key))
         (string= key line :end2 (length key))
         (not (whitespace-char-p (char line 0))))))

(defun status-line-value (line)
  "The status LINE declares, as a keyword, or NIL when it declares none.

The trailing comment is dropped rather than parsed: YAML starts one at a `#'
preceded by whitespace, and CON-0004's own bug template writes
`status: open              # closed once fixed'. Reading the comment as part of
the value would make every such document's status unrecognisable."
  (let* ((rest (subseq line (length "status:")))
         (comment (loop for i from 0 below (length rest)
                        when (and (char= #\# (char rest i))
                                  (or (zerop i) (whitespace-char-p (char rest (1- i)))))
                          return i))
         (text (string-trim '(#\Space #\Tab #\Return)
                            (subseq rest 0 (or comment (length rest))))))
    (when (plusp (length text))
      (intern (string-upcase text) :keyword))))

(defun top-level-status-line (contents)
  "Three values for CONTENTS: the character range of its top-level status line
and the status that line declares. NIL when there is none.

The first such line and not the only one: a well-formed YAML mapping cannot
have two, and a document that somehow does is one where editing the first is
the same choice a parser makes."
  (loop with length = (length contents)
        with start = 0
        while (< start length)
        do (multiple-value-bind (end next) (line-end contents start)
             (let ((line (subseq contents start end)))
               (when (status-key-line-p line)
                 (return (values start end (status-line-value line)))))
             (setf start next))
        finally (return nil)))

(defun replace-status-line (contents start end status)
  "CONTENTS with the line between START and END replaced by one declaring STATUS.

Everything outside the range is copied through untouched, which is what makes a
completed plan's diff one changed line. A carriage return at the end of the old
line is carried onto the new one, so a CRLF file does not acquire one mixed
ending where the edit landed."
  (let ((crlf (and (> end start) (char= #\Return (char contents (1- end))))))
    (concatenate 'string
                 (subseq contents 0 start)
                 (format nil "status: ~(~a~)" status)
                 (if crlf (string #\Return) "")
                 (subseq contents end))))

;;;; ==================================================================
;;;; Where the file belongs (RULE-0007, and R3)
;;;; ==================================================================

(defparameter *completed-directory* "completed"
  "The subdirectory a terminal document lives in. RULE-0007's convention, named
once because both directions of the move read it.")

(defun flat-directory (path)
  "The directory PATH's document lives in when its status is not terminal --
its own directory, or the parent when it is already inside completed/."
  (let ((directory (pathname-directory path)))
    (if (string-equal *completed-directory* (car (last directory)))
        (make-pathname :directory (butlast directory) :name nil :type nil
                       :defaults path)
        (make-pathname :directory directory :name nil :type nil :defaults path))))

(defun status-destination (path terminal)
  "Where the document at PATH belongs, given whether its status is TERMINAL.

Derived from the directory the file is in rather than from a `docs' segment in
its path, so a foreign tree prepared by REQ-0021 -- which may keep its documents
anywhere -- gets the same answer this one does.

Both directions, which is what R3's \"placement and status can no longer
disagree\" means: a status that becomes terminal moves the file in, and one that
stops being terminal moves it back out. A category with no terminal status never
computes a destination different from where the file already is, so decisions,
rules and architecture documents never move."
  (let ((flat (flat-directory path)))
    (merge-pathnames
     (make-pathname :name (pathname-name path) :type (pathname-type path))
     (if terminal
         (merge-pathnames (make-pathname :directory (list :relative *completed-directory*))
                          flat)
         flat))))

;;;; ==================================================================
;;;; Plan, then apply (D6)
;;;; ==================================================================

(defstruct (document-edit (:conc-name edit-))
  "One document's whole transition, computed before anything is written."
  (doc-id "")
  (category nil)
  (source nil)          ; absolute pathname, as it stands
  (destination nil)     ; absolute pathname, where the new status puts it
  (from nil)            ; the status the file currently declares
  (to nil)              ; the status it will declare
  (contents nil)        ; the whole new file, or NIL when the line is unchanged
  (blocked-by '()))     ; doc-ids of unfinished plans still refining this one

(defun edit-writes-p (edit)
  (or (edit-contents edit)
      (not (equal (namestring (edit-source edit))
                  (namestring (edit-destination edit))))))

(defun probe-writable (path)
  "NIL when PATH can be written, or a sentence saying why not.

Opened for append and closed without writing a byte, which is a real probe
rather than a guess about permissions: the alternatives are reading a mode
bitmask, which says nothing about ACLs or a read-only mount, and finding out
during the write, which is the one thing the plan-then-apply split exists to
prevent."
  (handler-case
      (progn (with-open-file (out path :direction :output :if-exists :append
                                       :if-does-not-exist :error))
             nil)
    (error (condition) (format nil "cannot be written: ~a" condition))))

(defun plan-document-edit (repository entity status)
  "Two values: the DOCUMENT-EDIT setting ENTITY's status to STATUS, and a list
of problems. One or the other is always NIL.

Everything that can refuse happens here and nothing here writes. The order is
cheapest-first only incidentally; what matters is that every problem is
collected rather than the first one signalled, because an agent that has to run
a command five times to discover five problems will stop reading the fifth."
  (let* ((doc-id (or (getp entity :doc-id) (and (slot-boundp entity 'name) (name entity))))
         (category (document-category-of entity))
         (problems '()))
    (flet ((refuse (format &rest arguments)
             (push (format nil "~a: ~?" doc-id format arguments) problems)))
      (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
        (declare (ignore terminal))
        (when (null allowed)
          ;; Returned rather than collected with the rest, because every check
          ;; below it is downstream of a status field existing: a concept has no
          ;; top-level status line either, and reporting that second fact would
          ;; describe the same absence twice and bury the one a reader can act
          ;; on.
          (refuse "~(~a~) documents have no status field, so there is nothing to set."
                  (entity-type entity))
          (return-from plan-document-edit (values nil (nreverse problems))))
        (unless (member status allowed)
          (refuse "~(~a~) is not a status a ~a document takes. Try: ~{~(~a~)~^, ~}"
                  status (or category (string-downcase (entity-type entity)))
                  allowed))
        (let ((source (document-file repository entity)))
          (cond
            ((null source) (refuse "the index does not record which file it came from."))
            ((null (probe-file source)) (refuse "~a is not on disk." source))
            (t
             (let ((contents (handler-case (slurp-file source)
                               (error (condition)
                                 (refuse "~a cannot be read: ~a" source condition)
                                 nil))))
               (when contents
                 (multiple-value-bind (start end current) (top-level-status-line contents)
                   (cond
                     ((null start)
                      ;; D3: refused, not repaired. A document with no top-level
                      ;; status line is one whose type may not have a status at
                      ;; all, and inserting one would invent a field its author
                      ;; never wrote.
                      (refuse "~a has no top-level status: line." source))
                     (t
                      (when (and allowed current (not (member current allowed)))
                        ;; BUG-0019's shape: `status: fixed', dropped to NIL by
                        ;; AS-KEYWORD, so the index held no status while the file
                        ;; held a word. A document in an unknown state is exactly
                        ;; where a human should look, so it is reported rather
                        ;; than silently overwritten.
                        (refuse "the file declares ~(~a~), which is not a status this ~
document takes; fix it by hand first." current))
                      (let* ((destination (status-destination
                                           source (terminal-status-p entity status)))
                             (moving (not (equal (namestring source)
                                                 (namestring destination)))))
                        (when (and moving (probe-file destination))
                          (refuse "~a already exists." destination))
                        (when moving
                          (handler-case (ensure-directories-exist destination)
                            (error (condition)
                              (refuse "~a cannot be created: ~a"
                                      (make-pathname :name nil :type nil
                                                     :defaults destination)
                                      condition))))
                        (let ((unwritable (probe-writable source)))
                          (when unwritable (refuse "~a ~a" source unwritable)))
                        (unless problems
                          (return-from plan-document-edit
                            (values (make-document-edit
                                     :doc-id doc-id
                                     :category category
                                     :source source
                                     :destination destination
                                     :from current
                                     :to status
                                     :contents (unless (eq current status)
                                                 (replace-status-line contents start end status)))
                                    nil)))))))))))))
      (values nil (nreverse problems)))))

(defun apply-document-edit (edit)
  "Write one planned EDIT: the line, then the move. Returns a report plist.

Called only with a list PLAN-DOCUMENT-EDIT refused nothing in, which is what
makes this the short function. It is not atomic across files and cannot be; what
the split buys is that nothing is written until everything has been checked, so
the surviving failure mode is a full disk or a permission change between the
check and the write."
  (let ((source (edit-source edit))
        (destination (edit-destination edit)))
    (when (edit-contents edit)
      (with-open-file (out source :direction :output :if-exists :supersede
                                  :if-does-not-exist :error)
        (write-string (edit-contents edit) out)))
    (unless (equal (namestring source) (namestring destination))
      (ensure-directories-exist destination)
      (rename-file source destination))
    (list :doc-id (edit-doc-id edit)
          :from (edit-from edit)
          :to (edit-to edit)
          :file (namestring destination)
          :moved (not (equal (namestring source) (namestring destination))))))

(defun apply-transition (repository edits &key reindex)
  "Apply every EDIT and rebuild the index. Returns the list of change reports.

REINDEX-REPOSITORY rather than a poll, and RULE-0007 records why: a :DOCUMENT's
natural key is (:PATH), so a move changes its id and therefore every edge
endpoint, and INDEX-REPOSITORY does not retract what is no longer on disk. The
cheaper call would leave the old path in the index beside the new one and every
reference to it ambiguous."
  (let ((changed (mapcar #'apply-document-edit edits)))
    (when (and reindex (some (lambda (report) (getf report :moved)) changed))
      (reindex-repository repository :quiet t))
    changed))

;;;; ==================================================================
;;;; set-status: the primitive
;;;; ==================================================================

(defun resolve-document (repository designator)
  "Two values: the one document DESIGNATOR names, and a list of problems."
  (let ((found (documents-named (repository-graph repository) designator)))
    (cond ((null found)
           (values nil (list (format nil "No document in ~a is named ~a."
                                     (repository-name repository) designator))))
          ((rest found)
           (values nil (list (format nil "~d documents are named ~a: ~{~a~^, ~}. ~
Two files carrying one id is a defect worth fixing before anything is written."
                                     (length found) designator
                                     (mapcar (lambda (e) (or (origin-file e) (id e)))
                                             found)))))
          (t (values (first found) nil)))))

(defun as-status (value)
  "VALUE as a status keyword, whatever a console token or a JSON string gave us."
  (typecase value
    (null nil)
    (keyword value)
    (string (let ((text (string-trim '(#\Space #\Tab) value)))
              (when (plusp (length text)) (intern (string-upcase text) :keyword))))
    (t (intern (string-upcase (princ-to-string value)) :keyword))))

(defun set-document-status (repository designator status &key (reindex t))
  "Set one document's status, move its file if the new status is terminal, and
reindex. Returns a report plist; :PROBLEMS non-empty means nothing was written.

The primitive DES-0019 D1 asks for, wanted in its own right -- accepting a
requirement, closing a bug, retiring a rule -- and the single write path
COMPLETE-PLAN is built from, so there is one of these to get right rather than
two.

Deliberately without the propagation query COMPLETE-PLAN runs. This is the way
to say \"I know what I am doing\" about one document, and files are truth: a
developer with an editor can always do the same thing, so a primitive that
refused would only be telling them to use the editor."
  (let ((repository (if (repository-p repository)
                        repository
                        (or (find-repository repository)
                            (return-from set-document-status
                              (list :problems (list (format nil "No repository named ~a."
                                                            repository))))))))
    (with-repository-lock (repository)
      (let ((status (as-status status)))
        (multiple-value-bind (entity problems) (resolve-document repository designator)
          (when problems
            (return-from set-document-status
              (list :repository (repository-name repository)
                    :document designator :problems problems :changed '())))
          (multiple-value-bind (edit edit-problems) (plan-document-edit repository entity status)
            (if edit-problems
                (list :repository (repository-name repository)
                      :document (or (getp entity :doc-id) designator)
                      :problems edit-problems :changed '())
                (list :repository (repository-name repository)
                      :document (edit-doc-id edit)
                      :problems '()
                      :changed (if (edit-writes-p edit)
                                   (apply-transition repository (list edit) :reindex reindex)
                                   '())
                      :status (edit-to edit)
                      :file (namestring (edit-destination edit))))))))))

;;;; ==================================================================
;;;; The propagation query (D4)
;;;; ==================================================================

(defparameter *plan-category* "plans"
  "The document category whose completion drives the cascade.

A plan is identified by its :CATEGORY -- a fact the indexer recorded from the
directory -- rather than by a PLAN- prefix on its id. The prefix is a naming
convention this tree happens to use; the category is what a foreign tree
prepared by REQ-0021 will also have.")

(defun plan-document-p (entity)
  (string-equal *plan-category* (or (document-category-of entity) "")))

(defun refines-targets (graph document)
  "The documents DOCUMENT refines -- its outgoing :REFINES edges.
CON-0004's chain read upward: a design refines the requirement that asked for
it, a plan refines the design it sequences."
  (loop for neighbor in (neighbors graph (id document) :rel-types '(:refines)
                                                       :direction :out)
        for entity = (neighbor-entity neighbor)
        when (document-entity-p entity)
          collect entity))

(defun finishable-p (entity)
  "True when ENTITY's category has a terminal status at all.

False for a decision, a rule, an architecture document and a concept, and that
is what stops them blocking anything. Those are *in force* rather than
outstanding: an active rule refining a concept is not unfinished work holding
the concept open, and treating it as one would make every such parent
permanently blocked by documents that are behaving correctly."
  (multiple-value-bind (allowed terminal) (document-status-vocabulary entity)
    (and allowed terminal t)))

(defun document-blockers (graph document settled)
  "Doc-ids of the unfinished documents still refining DOCUMENT, SETTLED aside.

This is the query REQ-0022 was written for and the strongest argument for
building the command rather than restating the rule. A document may leave draft
only if no *other* unfinished work still refines it. Loom knows that -- the
edges are in the graph and the statuses are properties -- and a human closing a
plan at the end of a long change does not, and will not check.

Every refining document counts, not only plans, which is RULE-0005 read whole:
\"If any sibling is still open -- another architecture, an unfixed bug, an
unanswered review -- the parent stays where it is. Marking a requirement
implemented while a bug refining it is still open is the same false claim in the
other direction.\"

SETTLED is what this cascade is in the act of finishing, the plan included. Its
members are not blockers because their unfinished state is precisely what is
being ended; without it the plan would block every document it refines and the
command could never do anything."
  (loop for neighbor in (neighbors graph (id document) :rel-types '(:refines)
                                                       :direction :in)
        for other = (neighbor-entity neighbor)
        when (and (document-entity-p other)
                  (not (member other settled))
                  (finishable-p other)
                  (not (terminal-status-p other (getp other :status))))
          collect (or (getp other :doc-id) (name other))))

;;;; ==================================================================
;;;; complete: the cascade
;;;; ==================================================================

(defun parse-verdicts (spec)
  "Two values: SPEC as an alist of (document . status), and a list of problems.

SPEC is `DES-0019=implemented REQ-0022=implemented' -- one string, whether it
arrived as console tokens, a REST query parameter or an MCP argument, because
all three can carry a string and only one of them can carry an object. A list of
tokens is accepted too, which is what the console has after splitting its line."
  (let ((tokens (etypecase spec
                  (null '())
                  (string (let ((words '()) (current (make-string-output-stream)))
                            (flet ((finish ()
                                     (let ((word (get-output-stream-string current)))
                                       (when (plusp (length word)) (push word words)))))
                              (loop for character across spec
                                    do (if (whitespace-char-p character)
                                           (finish)
                                           (write-char character current))
                                    finally (finish)))
                            (nreverse words)))
                  (cons spec)))
        (verdicts '())
        (problems '()))
    (dolist (token tokens)
      (let ((equals (position #\= token)))
        (cond ((or (null equals) (zerop equals) (= equals (1- (length token))))
               (push (format nil "~s is not a verdict. Write it as DOC-ID=status." token)
                     problems))
              (t (push (cons (subseq token 0 equals)
                             (as-status (subseq token (1+ equals))))
                       verdicts)))))
    (values (nreverse verdicts) (nreverse problems))))

(defun complete-plan (repository designator &key verdicts (reindex t))
  "Set a plan final and restate every document it implements. Returns a report.

REQ-0022 R1, and the one command that replaces RULE-0005. With no VERDICTS it
writes nothing and reports what it would do: which documents the plan refines,
what each currently says, which are still blocked by another unfinished plan,
and what the caller has to decide. Dry run by default rather than behind a flag,
which is the right default for a command whose failure mode is editing files --
and it means an agent that runs `complete PLAN-0019' and walks away has done
nothing, which is deliberate and will occasionally be surprising.

With verdicts it is all or nothing: every refined document that is not blocked
needs one. A cascade that applied the two verdicts it was given and left the
third document in draft would produce exactly the half-updated state RULE-0005
was written to prevent, one command later.

A blocked document is reported and left alone, and a verdict naming one is
refused rather than obeyed. SET-DOCUMENT-STATUS is the way past that, and the
refusal exists so the caller sees the blocking plan before deciding to."
  (let ((repository (if (repository-p repository)
                        repository
                        (or (find-repository repository)
                            (return-from complete-plan
                              (list :problems (list (format nil "No repository named ~a."
                                                            repository))))))))
    (with-repository-lock (repository)
      (let ((graph (repository-graph repository)))
        (multiple-value-bind (parsed parse-problems) (parse-verdicts verdicts)
          (multiple-value-bind (plan problems) (resolve-document repository designator)
            (let ((problems (append parse-problems problems)))
              (when (and plan (not (plan-document-p plan)))
                (push (format nil "~a is a ~a document, not a plan; `complete' cascades ~
from a plan. Use set-status for one document."
                              (or (getp plan :doc-id) designator)
                              (or (document-category-of plan) "categoryless"))
                      problems))
              (when problems
                (return-from complete-plan
                  (list :repository (repository-name repository) :plan designator
                        :problems problems :documents '() :changed '())))
              (let ((dry-run (null parsed))
                    (edits '())
                    (rows '())
                    ;; What this cascade is in the act of finishing. The plan
                    ;; leads it, because its own draft status is the first thing
                    ;; that would otherwise block every document it refines.
                    (settled (list plan))
                    (visited (list plan))
                    ;; BUG-0026. The verdict lookup is driven by the walk, so a
                    ;; verdict for a document the walk never reaches is never
                    ;; the subject of an ASSOC and cannot be reported by any
                    ;; code path that reads it. Every consulted doc-id is
                    ;; recorded here instead, and what is left over is refused
                    ;; below rather than discarded in silence.
                    (consulted '())
                    (frontier '()))
                (flet ((record (row) (push row rows))
                       (edit-for (document status)
                         (multiple-value-bind (edit edit-problems)
                             (plan-document-edit repository document status)
                           (if edit-problems
                               (progn (setf problems (append problems edit-problems)) nil)
                               (progn (push edit edits) edit)))))
                  ;; --- the plan itself ----------------------------------
                  ;; First, so that a plan whose own file refuses the edit is
                  ;; refused before a single refined document is touched.
                  (let ((edit (edit-for plan :final)))
                    (when edit
                      (record (list :doc-id (edit-doc-id edit)
                                    :category (edit-category edit)
                                    :status (edit-from edit)
                                    :verdict (edit-to edit)
                                    :blocked-by '()
                                    :action (cond (dry-run :would-set)
                                                  ((edit-writes-p edit) :set)
                                                  (t :unchanged))))
                      (setf frontier (refines-targets graph plan))))
                  ;; --- the walk upward ----------------------------------
                  ;; RULE-0005: "The walk continues upward only on
                  ;; implemented. If a plan implements an architecture and that
                  ;; architecture was the last outstanding child of a
                  ;; requirement, the requirement is implemented too." One hop
                  ;; would leave that requirement in draft, which is the same
                  ;; false claim the command exists to stop, arrived at one
                  ;; level further up.
                  ;;
                  ;; Level by level rather than depth-first, because a parent's
                  ;; blockers include its other children and every one of them
                  ;; has to be decided before the parent is judged.
                  (loop while frontier
                        do (let ((finished '())
                                 (next '()))
                             (dolist (document frontier)
                               (unless (member document visited)
                                 (push document visited)
                                 (let* ((doc-id (or (getp document :doc-id) (name document)))
                                        (category (document-category-of document))
                                        (vocabulary (document-status-vocabulary document))
                                        (blocked (document-blockers graph document settled))
                                        (verdict (cdr (assoc doc-id parsed
                                                             :test #'string-equal))))
                                   (push doc-id consulted)
                                   (cond
                                     ;; A type with no status field at all --
                                     ;; a concept, which REQ documents in this
                                     ;; tree routinely refine. The walk stops
                                     ;; here and says so rather than stopping
                                     ;; silently, because "nothing happened to
                                     ;; CON-0004" is a fact the caller wants.
                                     ((null vocabulary)
                                      (record (list :doc-id doc-id :category category
                                                    :status nil :verdict nil
                                                    :blocked-by '() :action :no-status)))
                                     ;; Already finished before this cascade
                                     ;; started. It needs no verdict, it blocks
                                     ;; nothing, and the walk stops here rather
                                     ;; than climbing through it: nothing about
                                     ;; it changed, so nothing above it changed
                                     ;; because of it. Reported anyway, because
                                     ;; a caller reading the chain wants to see
                                     ;; where it already ends.
                                     ((terminal-status-p document (getp document :status))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by '()
                                                    :action :already-finished)))
                                     (blocked
                                      (when verdict
                                        (push (format nil "~a is still refined by ~
~{~a~^, ~}, which ~:[is~;are~] not finished. Close ~:*~:[it~;them~] first, or use ~
set-status to override." doc-id blocked (rest blocked))
                                              problems))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by blocked
                                                    :action :blocked)))
                                     ((null verdict)
                                      (unless dry-run
                                        (push (format nil "~a needs a verdict. Add ~
~a=<status> -- one of ~{~(~a~)~^, ~}." doc-id doc-id vocabulary)
                                              problems))
                                      (record (list :doc-id doc-id :category category
                                                    :status (getp document :status)
                                                    :verdict nil :blocked-by '()
                                                    :action :awaiting-verdict)))
                                     (t
                                      (let ((edit (edit-for document verdict)))
                                        (when edit
                                          (record (list :doc-id doc-id
                                                        :category (edit-category edit)
                                                        :status (edit-from edit)
                                                        :verdict verdict :blocked-by '()
                                                        :action (cond (dry-run :would-set)
                                                                      ((edit-writes-p edit) :set)
                                                                      (t :unchanged))))
                                          ;; Terminal only. A `partial' verdict
                                          ;; means work remains, so the parent
                                          ;; is not finished either and the
                                          ;; walk stops rather than climbing
                                          ;; past an OUTSTANDING section.
                                          (when (terminal-status-p document verdict)
                                            (push document finished)))))))))
                             ;; Every document at this level is decided before
                             ;; the next level is computed, so a parent sees all
                             ;; of its children's outcomes and none of its
                             ;; grandchildren's.
                             (setf settled (append finished settled))
                             (dolist (document finished)
                               (setf next (append next (refines-targets graph document))))
                             ;; A dry run walks the whole chain on the
                             ;; assumption that every document it reports would
                             ;; be finished, which is what makes it a preview of
                             ;; the verdicts the caller has to supply.
                             (when dry-run
                               (dolist (document frontier)
                                 (unless (or (member document settled)
                                             (not (finishable-p document))
                                             (terminal-status-p document
                                                                (getp document :status))
                                             (document-blockers graph document settled))
                                   (push document settled)
                                   (setf next (append next
                                                      (refines-targets graph document))))))
                             (setf frontier (remove-duplicates next :from-end t)))))
                ;; BUG-0026: a verdict nobody asked for. Refused rather than
                ;; warned, for the reason a missing verdict is refused -- the
                ;; command is all-or-nothing, and a caller who named a document
                ;; the cascade does not reach has either mistyped it or misread
                ;; the chain. The message says which of the walk's two stopping
                ;; conditions applies, because "not in this cascade" invites the
                ;; reply that it is right there in the refines: chain.
                (let ((unused (remove-if (lambda (pair)
                                           (member (car pair) consulted
                                                   :test #'string-equal))
                                         parsed)))
                  (when unused
                    (push (format nil "~{~a~^, ~} ~:[is~;are~] not in this cascade, so ~
~:*~:[its verdict was~;their verdicts were~] not applied. The walk stops at a document ~
whose verdict is not terminal, and goes no further than what the plan refines -- run ~
`complete' with no verdicts to see the chain it reaches."
                                  (mapcar #'car unused) (rest unused))
                          problems)))
                (let ((rows (nreverse rows))
                      (edits (remove-if-not #'edit-writes-p (nreverse edits))))
                  (list :repository (repository-name repository)
                        :plan (or (getp plan :doc-id) designator)
                        :dry-run dry-run
                        :problems problems
                        :documents rows
                        ;; R7: re-running on a completed plan changes nothing
                        ;; and says so. The empty :CHANGED list is the saying.
                        :changed (if (or dry-run problems)
                                     '()
                                     (apply-transition repository edits
                                                       :reindex reindex))))))))))))
