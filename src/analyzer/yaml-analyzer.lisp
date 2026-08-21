;;;; The documentation analyzer: YAML under docs/ becomes graph entities.
;;;; Implements Phase 1 Software Architecture (Revision 2) SS10.
;;;;
;;;; SS10.2 chose YAML over prose-with-front-matter for a reason worth
;;;; repeating, because it shapes this whole file: documents "parse into
;;;; structured data with no heuristic extraction, validate against a schema
;;;; per type, and can be written reliably by an agent -- a decision record
;;;; with a malformed header is a parsing problem; a decision record with a
;;;; missing key is a validation error with a line number." So there is no
;;;; guessing here. A field is present or it is not.
;;;;
;;;; Like every analyzer (SS9.1) this one is stateless and emits operations.
;;;; That matters more than usual for documents: SS10.3 resolves affects: and
;;;; supersedes: "against the entity index", and an analyzer has no index. The
;;;; names are carried through as properties and LOOM-GRAPH:RESOLVE-DOCUMENT-
;;;; LINKS turns them into edges -- the same shape as unresolved calls, and
;;;; for the same reason.
;;;;
;;;; It lives in LOOM-ANALYZER rather than in a system of its own. SS4 lists a
;;;; separate loom-docs owning "YAML documentation analyzer ... link
;;;; resolution; the rule compiler", but link resolution needs the entity
;;;; index, which would give loom-docs an edge into loom-graph and contradict
;;;; SS14.3's invariant that it has none. Resolution therefore sits on the
;;;; graph side, the rule compiler is PARSE-CHECK below, and what remains is
;;;; one more implementation of the SS9.1 protocol -- which is what this system
;;;; is for.

(in-package :loom-analyzer)

(defun yaml-problem (condition)
  "CONDITION as a message a reader can act on.

cl-yaml numbers lines from zero. Every other line number Loom reports counts
from one -- a definition's :START-LINE, a suppressed region, the ranges
`find' and `describe' print -- so the parser's own report sends a reader to
the line above the mistake. YAML.ERROR:PARSING-ERROR carries LINE and COLUMN
as exported readers, so the number is corrected here rather than by editing
the string it appears in: rewriting a library's prose would break the first
time the library rephrased it, and would be a fabricated fact in the shape
CON-0001 is least able to catch.

Anything without those readers renders as itself. BUG-0033 is why this
matters at all: the line number is the whole distance between \"a document is
missing\" and \"quote the title\"."
  (if (typep condition 'yaml.error:parsing-error)
      (format nil "~a at line ~d, column ~d"
              (yaml.error:message condition)
              (1+ (yaml.error:line condition))
              (1+ (yaml.error:column condition)))
      (princ-to-string condition)))

(define-condition document-error (error)
  ((path    :initarg :path    :reader document-error-path)
   (problem :initarg :problem :reader document-error-problem))
  (:report (lambda (c s)
             (format s "~a: ~a" (document-error-path c) (document-error-problem c)))))

;;;; ==================================================================
;;;; Layout: the directory names the type (SS10.1)
;;;; ==================================================================

(defparameter *document-type-directories*
  ;; The agent workflow's directories are registered here rather than special
  ;; cased anywhere: a requirement is answered by an architecture note, which a
  ;; plan sequences, which a review or a bug report closes. All of them index,
  ;; and refines: is what chains them.
  ;; Three tiers, not two, and the names mean what an engineer means by them
  ;; (BUG-0023's sibling rename): a decision records a choice, a design argues
  ;; how to implement a requirement, and an architecture document describes
  ;; structure and mechanism as it stands. docs/arch held sixteen of the middle
  ;; kind until they were renamed DES-nnnn and moved here.
  '(("decisions"    . :decision)
    ("design"       . :design)
    ("rules"        . :rule)
    ("arch"         . :architecture)
    ("requirements" . :document)
    ("plans"        . :document)
    ("reviews"      . :document)
    ("bugs"         . :document)
    ("concepts"     . :concept))
  "docs/ subdirectory -> entity type.

A registry rather than content sniffing, so \"adding a category means creating
a directory and registering a type rather than changing code\", and so the
convention stays obvious to a human reading the tree.")

(defun register-document-type (directory type-key)
  (setf *document-type-directories*
        (cons (cons directory type-key)
              (remove directory *document-type-directories*
                      :key #'car :test #'string=))))

(defun path-segments (path)
  (loop with start = 0
        for slash = (position #\/ path :start start)
        collect (subseq path start (or slash (length path)))
        while slash do (setf start (1+ slash))))

(defun docs-relative-p (path)
  "The segments of PATH below docs/, or NIL when it is not under docs/."
  (let* ((segments (path-segments (substitute #\/ #\\ (namestring path))))
         (tail (member "docs" segments :test #'string-equal)))
    (rest tail)))

(defun document-category (path)
  "The docs/ subdirectory PATH sits in, or NIL for a file directly in docs/."
  (let ((below (docs-relative-p path)))
    (when (rest below) (first below))))

(defun document-type-for (path)
  "The entity type PATH's directory names, and whether it was registered.

SS10.1: \"A subdirectory with no registered type is indexed as a generic
Document and reported in status, rather than being silently ignored -- a
documentation directory that Loom is quietly skipping is exactly the kind of
thing that erodes trust in the graph.\""
  (let* ((category (document-category path))
         (entry (and category (assoc category *document-type-directories*
                                     :test #'string-equal))))
    (if entry
        (values (cdr entry) t)
        (values :document nil))))

;;;; ==================================================================
;;;; Reading YAML into plain data
;;;; ==================================================================

(defun yaml-value (table key)
  "The value of KEY in a parsed YAML mapping, or NIL.
cl-yaml returns EQUALP hash tables with string keys."
  (when (hash-table-p table)
    (gethash (string-downcase (string key)) table)))

(defun as-string (value)
  (typecase value
    (null nil)
    (string (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) value)))
              (if (zerop (length trimmed)) nil trimmed)))
    (t (princ-to-string value))))

(defun as-list-of-strings (value)
  "A YAML scalar or sequence as a list of strings.
A bare scalar is accepted where a list is expected -- `affects: loom-graph`
is what a human writes, and refusing it would be pedantry."
  (typecase value
    (null '())
    (string (let ((s (as-string value))) (if s (list s) '())))
    (cons (remove nil (mapcar #'as-string value)))
    (vector (remove nil (map 'list #'as-string value)))
    (t (let ((s (as-string value))) (if s (list s) '())))))

(defun as-keyword (value &optional allowed)
  (let ((s (as-string value)))
    (when s
      (let ((k (intern (string-upcase s) :keyword)))
        (when (or (null allowed) (member k allowed)) k)))))

(defun parse-document (contents &optional path)
  "CONTENTS as a YAML mapping. Signals DOCUMENT-ERROR on anything else.

A document that is not a mapping is a malformed document, not an empty one,
and saying so with the path is the \"validation error with a line number\"
half of why SS10.2 chose YAML."
  ;; YAML.ERROR:YAML-ERROR is named alongside ERROR deliberately. cl-yaml
  ;; defines its conditions as (define-condition yaml-error () ...) -- direct
  ;; subtypes of CONDITION, not of ERROR -- so a malformed document sails
  ;; straight through a handler that names ERROR alone. What that cost is not
  ;; a bad message: it is the watcher thread, which SS3.3 exists to keep
  ;; alive, and the console, whose *DEBUGGER-HOOK* turns any escaping
  ;; condition into an ABORT.
  (let ((parsed (handler-case (yaml:parse contents)
                  ((or error yaml.error:yaml-error) (condition)
                    (error 'document-error :path path
                                           :problem (yaml-problem condition))))))
    (unless (hash-table-p parsed)
      (error 'document-error :path path
                             :problem "expected a YAML mapping at the top level"))
    parsed))

;;;; ==================================================================
;;;; Prose blocks and the names mentioned in them (SS10.3)
;;;; ==================================================================

(defparameter *prose-fields* '(:rationale :consequences :statement :summary :invariants
                               :description :notes :body :lessons)
  "Fields whose values are prose rather than metadata.
Their text becomes the entity's :BODY, which is both what an agent reads and
what mentioned-link scanning runs over.")

(defun collect-body (table)
  (let ((parts '()))
    (dolist (field *prose-fields*)
      (let ((value (as-string (yaml-value table field))))
        (when value (push value parts))))
    (when parts (format nil "~{~a~^~2%~}" (nreverse parts)))))

(defparameter *mention-minimum-length* 4
  "Shorter tokens produce too many accidental matches to be worth resolving.")

(defun prose-mentions (body)
  "Candidate entity names appearing in BODY.

SS10.3's \"mentioned links\": these become :inferred edges at lower
confidence, and they are what make \"what decisions touch this function?\"
work without the author having enumerated every consequence. Kept to tokens
that look like identifiers -- containing a hyphen, an underscore, or an
interior capital -- because prose is mostly English and matching English words
against entity names would bury the real hits."
  (when body
    (let ((tokens '())
          (current (make-string-output-stream)))
      (flet ((finish ()
               (let ((word (get-output-stream-string current)))
                 (when (and (>= (length word) *mention-minimum-length*)
                            (or (find #\- word) (find #\_ word)
                                (find-if #'upper-case-p word :start 1))
                            (alpha-char-p (char word 0)))
                   (pushnew (string-downcase word) tokens :test #'string=)))))
        (loop for char across body
              do (if (or (alphanumericp char) (member char '(#\- #\_ #\* #\%)))
                     (write-char char current)
                     (finish))
              finally (finish)))
      (nreverse tokens))))

;;;; ==================================================================
;;;; Building the entity (SS10.3)
;;;; ==================================================================

(defun base-properties (table path category body)
  ;; :REFINES is read for every kind of document, not just decisions, because
  ;; the workflow chain runs through all of them: a requirement is answered by
  ;; a design, sequenced by a plan, and reported on by a review. Any document
  ;; may name the one it answers.
  ;; :SUMMARY is read from TABLE, the raw parse -- not from BODY and not from
  ;; any property computed above. COLLECT-BODY reads the same table and folds
  ;; summary: into :BODY as it always did; this is a second independent read of
  ;; unchanged source, which is what DEC-0003 permits and distinguishes from a
  ;; pass that rewrites its own input.
  (list :title    (as-string (yaml-value table :title))
        :summary  (as-string (yaml-value table :summary))
        :category category
        :body     body
        :refines  (as-list-of-strings (yaml-value table :refines))
        :mentions (prose-mentions body)
        :unresolved-references '()))

(defgeneric document-properties (type-key table path category body)
  (:documentation "The property plist for a document of TYPE-KEY.
A generic function so SS10.1's \"adding a category means creating a directory
and registering a type\" stays true of the fields as well as the directory."))

(defmethod document-properties ((type-key (eql :decision)) table path category body)
  (append (base-properties table path category body)
          (list :doc-id       (or (as-string (yaml-value table :id)) path)
                :status       (or (as-keyword (yaml-value table :status)
                                              '(:proposed :accepted :superseded :rejected))
                                  :proposed)
                :date         (as-string (yaml-value table :date))
                :rationale    (as-string (yaml-value table :rationale))
                :consequences (as-string (yaml-value table :consequences))
                :decision     (as-string (yaml-value table :decision))
                :tags         (as-list-of-strings (yaml-value table :tags))
                :lessons      (as-list-of-strings (yaml-value table :lessons))
                :affects      (as-list-of-strings (yaml-value table :affects))
                :supersedes   (as-list-of-strings (yaml-value table :supersedes)))))

(defmethod document-properties ((type-key (eql :rule)) table path category body)
  (append (base-properties table path category body)
          (list :doc-id     (or (as-string (yaml-value table :id)) path)
                :status     (or (as-keyword (yaml-value table :status) '(:active :retired))
                                :active)
                :severity   (or (as-keyword (yaml-value table :severity)
                                            '(:error :warning :advisory))
                                :error)
                :statement  (as-string (yaml-value table :statement))
                :applies-to (as-list-of-strings (yaml-value table :|applies-to|))
                :check      (parse-check (yaml-value table :check)))))

(defmethod document-properties ((type-key (eql :design)) table path category body)
  ;; The nine fields the sixteen renamed documents actually use, counted rather
  ;; than assumed: id, title, tags, summary, status, date, body, refines,
  ;; affects. No decision:/rationale:/consequences: -- a design argues in its
  ;; body rather than in named slots, which is what distinguishes the genre
  ;; from an ADR and why this is not simply :DECISION with a wider status list.
  (append (base-properties table path category body)
          (list :doc-id     (or (as-string (yaml-value table :id)) path)
                :status     (or (as-keyword (yaml-value table :status)
                                            '(:draft :proposed :accepted :final
                                              :superseded :rejected
                                              :implemented :partial))
                                :draft)
                :date       (as-string (yaml-value table :date))
                :tags       (as-list-of-strings (yaml-value table :tags))
                :affects    (as-list-of-strings (yaml-value table :affects))
                :supersedes (as-list-of-strings (yaml-value table :supersedes))
                :system     (default-system-for-path path))))

(defmethod document-properties ((type-key (eql :architecture)) table path category body)
  ;; DESCRIBES:, not AFFECTS:, and the analyzer is where that becomes true
  ;; rather than a convention: an architecture document that wrote affects:
  ;; would have it read by nothing, which is exactly the silent drop BUG-0023
  ;; closed, so the genre distinction is enforced by which key is looked up.
  (append (base-properties table path category body)
          (list :doc-id     (or (as-string (yaml-value table :id)) path)
                :status     (or (as-keyword (yaml-value table :status)
                                            '(:draft :accepted :superseded))
                                :draft)
                :date       (as-string (yaml-value table :date))
                :tags       (as-list-of-strings (yaml-value table :tags))
                :invariants (as-string (yaml-value table :invariants))
                :describes  (as-list-of-strings (yaml-value table :describes))
                :supersedes (as-list-of-strings (yaml-value table :supersedes))
                :system     (default-system-for-path path))))

(defmethod document-properties ((type-key (eql :concept)) table path category body)
  (append (base-properties table path category body)
          ;; No :SUMMARY line here: BASE-PROPERTIES now supplies the same value
          ;; from the same YAML key for every document type.
          (list :doc-id  (or (as-string (yaml-value table :id)) path))))

(defmethod document-properties ((type-key (eql :document)) table path category body)
  ;; :DOC-ID is read here for the same reason a decision reads it: it is how
  ;; one document names another. Every workflow category -- arch, requirements,
  ;; plans, reviews, bugs -- lands on :DOCUMENT, so without this the entire
  ;; chain is unreachable by id: `describe REQ-0002' finds nothing and a
  ;; refines: naming it resolves to nothing.
  (append (base-properties table path category body)
          (list :doc-id (or (as-string (yaml-value table :id)) path)
                ;; AS-KEYWORD with an allowed list, so a value outside the three
                ;; lands as NIL rather than as a fourth level nobody defined.
                ;; Silent, and deliberately: a typo'd importance is a document
                ;; whose author said something the vocabulary does not have, and
                ;; the report for that belongs to `check' over the whole tree
                ;; rather than to an analyzer reading one file.
                :importance (as-keyword (yaml-value table :importance)
                                        '(:critical :major :minor))
                ;; Read here for the same reason :DOC-ID is: every workflow
                ;; category lands on :DOCUMENT, so a field only the :DECISION
                ;; method reads is a field fifteen architecture notes, fourteen
                ;; requirements, fifteen plans and twenty-two bug reports write
                ;; and nothing ever sees. It resolved to nothing and was not
                ;; even reported unresolved, because a field that is never read
                ;; produces no name to fail.
                :affects (as-list-of-strings (yaml-value table :affects))
                :status (as-keyword (yaml-value table :status)
                                    ;; :IMPLEMENTED and :PARTIAL complete
                                    ;; CON-0004's vocabulary. Without them
                                    ;; AS-KEYWORD returned NIL for every
                                    ;; document that had actually landed, so
                                    ;; the status of the work that was done was
                                    ;; the one status the index never held.
                                    '(:draft :proposed :accepted :final
                                      :superseded :rejected :open :closed
                                      :implemented :partial))
                :path path
                ;; DES-0009 R3. A document has no grouping construct of its
                ;; own to read, so it gets the shared default and nothing
                ;; stronger. Only here: :RULE, :DECISION and :CONCEPT declare
                ;; no :SYSTEM property, so a value written on one of those
                ;; would be dropped by nothing and read by nothing.
                :system (default-system-for-path path)
                :format :yaml)))

;;;; ==================================================================
;;;; Rules: compiling the check clause (SS10.4)
;;;; ==================================================================

(defparameter *check-kinds* '(:no-edge :requires-edge :property-constraint
                              :property-absent :no-call-to)
  "SS10.4: \"Phase 1 supports a small set of check kinds ... which is enough
for the layering and single-writer rules Loom needs on itself.\"

Five now, not SS10.4's original three. :PROPERTY-ABSENT was added by DES-0012
for RULE-0006, and it is the mirror of :PROPERTY-CONSTRAINT rather than a new
kind of question -- \"this property must be absent\" against \"this property
must be present\". :NO-CALL-TO was added for BUG-0009's cause two: :NO-EDGE
can only say \"no edge to that whole system\", and RULE-0003's claim is
narrower than the system it names -- loom-knowledge depends on loom-graph
precisely so it can read, and only a write is forbidden. :NO-CALL-TO keeps
:NO-EDGE's from-system/to-system framing and adds TO-NAMES, so a rule can
name the callees it means. The list grows when a rule someone wants to write
is one a generic check can express; the discipline SS10.4 sets is that a rule
needing more than that stays prose, which PARSE-CHECK enforces by returning
NIL for a kind not named here.")

(defun conflicting-side-p (value system-key family-key)
  "Does this clause name one side of the comparison twice, both ways?

A rule writing from-system: and from-family: together is a rule whose author
did not decide what they meant, and guessing which one they intended is the
fabricated fact CON-0001 rules out. PARSE-CHECK refuses the whole clause, the
document still indexes, and UNENFORCED-RULES counts the rule where a human will
see it -- the same treatment `kind: vibes' already gets."
  (and (yaml-value value system-key) (yaml-value value family-key) t))

(defun side-designator (value system-key family-key)
  "One side of a :no-edge-style comparison, as a system designator.

from-system: yields a bare keyword, which is what every rule in docs/rules/
writes and what LOOM-GRAPH:SYSTEM-SATISFIES-P compares with EQ. from-family:
yields (:family NAME), matched by delimiter-anchored prefix instead.

Both land in the same plist slot on purpose (DES-0024 D3). Nothing downstream
learns a new key: RUN-CHECK reads :from-system as it always did, and :no-call-to
-- which hands both slots to EDGES-BETWEEN-SYSTEMS untouched -- gains family
matching without an edit of its own."
  (let ((family (as-keyword (yaml-value value family-key))))
    (if family
        (list :family family)
        (as-keyword (yaml-value value system-key)))))

(defun parse-check (value)
  "A rule's check: clause as a plist, or NIL.

NIL is not a failure. SS10.4: \"A rule that cannot be expressed as a check
remains valid as prose with severity advisory; it is not enforced, and status
reports the count of unenforced rules so that prose-only drift stays visible
rather than comfortable.\" An unrecognised kind therefore yields NIL and the
rule falls back to prose, rather than the document failing to index. A clause
writing both from-system: and from-family: takes the same path -- see
SIDE-DESIGNATOR."
  (when (hash-table-p value)
    (let ((kind (as-keyword (yaml-value value :kind) *check-kinds*)))
      (when (and kind
                 (not (conflicting-side-p value :|from-system| :|from-family|))
                 (not (conflicting-side-p value :|to-system| :|to-family|)))
        (list :kind        kind
              :from-system (side-designator value :|from-system| :|from-family|)
              :to          (as-keyword (yaml-value value :to))
              :to-system   (side-designator value :|to-system| :|to-family|)
              :rel-types   (mapcar (lambda (s) (intern (string-upcase s) :keyword))
                                   (as-list-of-strings (yaml-value value :|rel-types|)))
              :entity-type (as-keyword (yaml-value value :|entity-type|))
              :property    (as-keyword (yaml-value value :property))
              :equals      (as-string (yaml-value value :equals))
              ;; Kept as written, not interned: these are entity names, which
              ;; are strings on the graph, and RUN-CHECK compares them with
              ;; STRING-EQUAL. Interning them would make the rule's vocabulary
              ;; depend on which package read the document.
              :to-names    (as-list-of-strings (yaml-value value :|to-names|)))))))

;;;; ==================================================================
;;;; The analyzer
;;;; ==================================================================

(defclass document-analyzer (analyzer)
  ()
  (:default-initargs :language nil :file-types '("yaml" "yml"))
  (:documentation "Reads the YAML documentation tree of SS10."))

(defmethod analyzer-handles-p ((analyzer document-analyzer) path)
  "YAML, and under docs/. The extension alone is not enough: a CI config at
the repository root is YAML too, and indexing it as engineering knowledge
would be worse than ignoring it."
  (and (call-next-method) (docs-relative-p path) t))

(defun entity-class-for (type-key)
  (entity-type-class-name (find-entity-type type-key)))

(defmethod analyze-file ((analyzer document-analyzer) path contents workspace-id)
  "Ontology operations for one YAML document.

One entity, typed by its directory, carrying its scalar fields as properties
and its prose as :BODY. Declared references (affects:, supersedes:,
applies-to:) and prose mentions are carried as properties for the workspace to
resolve -- SS10.3 resolves them \"against the entity index\", which an
analyzer does not have and must not acquire."
  (declare (ignore analyzer))
  (handler-case
      (let* ((table (parse-document contents path))
             (type-key (document-type-for path))
             (category (document-category path))
             (body (collect-body table))
             (properties (document-properties type-key table path category body))
             (entity (make-instance (entity-class-for type-key)
                                    :name (or (getf properties :doc-id)
                                              (getf properties :title)
                                              path)
                                    :origin-file path
                                    :source :human-validated
                                    :properties (properties-table properties))))
        (list (retract-file path workspace-id)
              (assert-entity entity workspace-id)))
    ((or error yaml.error:yaml-error) (condition)
      ;; SS3.3 / SS9.3, the same contract the source analyzers honour: a file
      ;; that will not parse is marked, not omitted, and the condition does
      ;; not escape to take the watcher thread down. YAML-ERROR is named
      ;; explicitly for the reason PARSE-DOCUMENT gives: cl-yaml's conditions
      ;; are not ERROR subtypes, so this guard is only a guard if it says so.
      (list (retract-file path workspace-id)
            (assert-entity
             (make-instance 'document-entity
                            :name path
                            :origin-file path
                            :properties (properties-table
                                         (list :path path
                                               :category (document-category path)
                                               :format :yaml
                                               :analysis-error (princ-to-string condition))))
             workspace-id)))))

;;;; The one registered instance -- stateless, so one serves every document.
(register-analyzer (make-instance 'document-analyzer))
