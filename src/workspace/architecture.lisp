;;;; Rendering a structural report into an architecture document.
;;;;
;;;; REQ-0021 R5/R6, DES-0022 S3, PLAN-0024. The report STRUCTURE-REPORT
;;;; produces is data; this turns it into a document a human reads and the index
;;;; holds, and writes it into a prepared tree.
;;;;
;;;; The whole difficulty is one sentence of REQ-0021: "A generated invariant is
;;;; a defect." Its reasoning is worth having in front of you while reading this
;;;; file, because every restraint below is a consequence of it -- "Code being
;;;; consistent with an invariant is not evidence the invariant was intended,
;;;; and a violation is not evidence that it was not."
;;;;
;;;; So this generator has no license to characterise. It renders fields that
;;;; were measured and it does not summarise them, because a summary is the
;;;; interpretive act the requirement forbids. An LLM asked to infer invariants
;;;; from source will produce confident, plausible, unfalsifiable prose, and it
;;;; would sit in the graph next to a hand-written architecture document with
;;;; nothing to tell them apart.
;;;;
;;;; What it does have that a hand-written document does not: every name in it
;;;; resolved against real code at the moment it was written, and it names the
;;;; commit it was derived from. That is the trade -- it says less, and what it
;;;; says is checkable.

(in-package :loom-workspace)

(defparameter *architecture-describes-limit* 40
  "How many names a generated document claims to describe.

A cap for the reason every other cap in this tree exists: the report ranks hubs
and protocols, and the tail of that ranking describes nothing in particular. A
describes: field naming two hundred entities is a claim nobody can check, which
is the opposite of what makes a generated document worth having.")

(defun unambiguous-names (graph names)
  "Two values: those NAMES resolving to exactly one entity, and how many did not.

REQ-0021 R6 requires that a generated document not raise `unresolved', and
describes: resolves through the same path every declared reference does -- which
refuses a name matching several entities rather than guessing (CON-0001). On
game-server `dhandler-delete-selector' names seven things, so a generator that
wrote every hub it found would produce exactly the rotten references R6 is
measured by.

The count of what was dropped is returned rather than swallowed, because a
document describing nine of twelve hubs should say so."
  (let ((index (linkable-index graph))
        (kept '())
        (dropped 0))
    (dolist (name names)
      ;; RESOLVE-ONE rather than a candidate count, and the difference is not
      ;; cosmetic. A first version of this counted entries in the index and
      ;; called anything with more than one ambiguous, which drops precisely the
      ;; names most worth describing: a protocol with 23 implementors has 24
      ;; entries under its name. RESOLVE-ONE knows that a lone :INTERFACE plus
      ;; its methods is one protocol rather than several things sharing a
      ;; spelling, and resolves it -- so a field built from its answer says what
      ;; the resolver will actually accept, instead of a stricter guess.
      ;;
      ;; Measured on the prepared game-server copy: the naive test kept 40 of
      ;; 277 candidates and every interesting protocol was in the 237 it threw
      ;; away.
      (if (resolve-one index name)
          (pushnew name kept :test #'string=)
          (incf dropped)))
    (values (nreverse kept) dropped)))

(defun architecture-describes (graph report)
  "The names a generated document may claim to describe.

Drawn from what the report ranked -- protocols first, then hubs -- because those
are the entities a reader of an architecture document is most likely to want to
find, and because both lists are already ordered by a measurement rather than by
an opinion."
  (let ((candidates (append (mapcar (lambda (row) (getf row :name))
                                    (getf report :protocols))
                            (mapcar (lambda (row) (getf row :name))
                                    (getf report :hubs)))))
    (multiple-value-bind (kept dropped)
        (unambiguous-names graph (remove nil candidates))
      (values (if (> (length kept) *architecture-describes-limit*)
                  (subseq kept 0 *architecture-describes-limit*)
                  kept)
              dropped))))

(defun yaml-block (text indent)
  "TEXT indented to sit inside a YAML block scalar."
  (with-output-to-string (out)
    (let ((pad (make-string indent :initial-element #\Space)))
      (loop with start = 0
            with length = (length text)
            while (< start length)
            do (multiple-value-bind (end next) (line-end text start)
                 (let ((line (subseq text start end)))
                   (if (zerop (length line))
                       (format out "~%")
                       (format out "~a~a~%" pad line)))
                 (setf start next))))))

(defun render-architecture (report doc-id describes dropped)
  "REPORT as an ARCH document. Renders; decides nothing.

Every number here came from the report and nothing is characterised on the way
through. The two sections that would normally carry an author's judgement --
invariants, and what the layering ought to be -- are present and empty, and say
why they are empty. An absent section reads as an oversight and a filled one is
fabrication; an empty one that explains itself is the only honest form."
  (with-output-to-string (out)
    (format out "id: ~a~%" doc-id)
    (format out "title: The structure of ~a as the index sees it~%"
            (getf report :repository))
    ;; draft, deliberately. It is the one ARCH status the rest of the system
    ;; does not treat as settled, which is REQ-0021 R9's "a status the rest of
    ;; the system will not treat as settled".
    (format out "status: draft~%")
    (format out "date: ~a~%"
            (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
              (declare (ignore s m h))
              (format nil "~d-~2,'0d-~2,'0d" y mo d)))
    (format out "tags: [generated, structure, loom]~%")
    (when describes
      (format out "describes: [~{~a~^, ~}]~%" describes))
    (format out "summary: |~%")
    (write-string
     (yaml-block
      (format nil "GENERATED by Loom from the index~@[ at commit ~a~], and not written by a~%~
person. Everything below was derived from what the analyzers read; nothing in it~%~
is a claim about intent, and the invariants section is empty on purpose.~%~%~
It is worth exactly as much as that makes it. No name in it was invented -- each~%~
one resolved against real code when this was written -- and no sentence in it~%~
says why the code is the way it is, because an index cannot know that. A human~%~
editing this document should expect to add the second kind and keep the first.~%~%~
~d entities and ~d relationships across ~d system~:p.~@[ ~a~]~@[~%~%~a~]"
              (getf report :commit)
              (getf report :entities) (getf report :relationships)
              (length (getf report :systems))
              (unless (getf report :indexed-p)
                "No relationships were derived at all, so no analyzer claimed this tree's source -- what follows describes only what Loom could read.")
              ;; REQ-0050 R1 and R3, and it matters more here than on a console
              ;; line: this sentence is written into a file and read months
              ;; later, when nothing else can say whether the index behind it
              ;; had caught up with the tree. Said only when it had not, because
              ;; a generated document that recites its own freshness on every
              ;; line is noise, and a reader of a document with no such
              ;; sentence can take the commit at its word.
              (let ((drift (getf report :drift))
                    (dirty (getf report :dirty)))
                (cond ((and drift (plusp drift))
                       (format nil "Derived from an index that was ~d claimed file~:p behind the tree when this was written, so the commit above names the reference point rather than the bytes described." drift))
                      (dirty
                       "The tree had uncommitted edits when this was derived, so the commit above names the reference point rather than the bytes described.")
                      (t nil))))
      2)
     out)
    (format out "invariants: |~%")
    (write-string
     (yaml-block
      (format nil "None. This section is empty because it was generated, and it says so rather~%~
than being omitted.~%~%~
An invariant is a statement of intent -- \"one writer\", \"analyzers cannot reach~%~
storage\". Code being consistent with one is not evidence anybody intended it,~%~
and a violation is not evidence that they did not. Nothing in an index~%~
distinguishes a rule the team holds from an accident that has not broken yet, so~%~
anything written here by a generator would be plausible, unfalsifiable, and~%~
indistinguishable from the real thing.~%~%~
This is the section to fill in by hand. It is the half of an architecture~%~
document a tool cannot write, and the reason a generated one is a starting point~%~
rather than an answer." )
      2)
     out)
    (format out "body: |~%")
    (write-string (yaml-block (architecture-body report describes dropped) 2) out)))

(defun architecture-body (report describes dropped)
  (with-output-to-string (out)
    (format out "SYSTEMS~%~%")
    (format out "  Grouping as the index placed it: a package for source, the path for~%")
    (format out "  documents. Counts are entities, definitions, tests, and the number of~%")
    (format out "  distinct units something tests.~%~%")
    (dolist (row (getf report :systems))
      (format out "    ~28a ~5d ~5d ~5d ~5d~%"
              (getf row :name) (getf row :entities) (getf row :definitions)
              (getf row :tests) (getf row :tested-units))
      (dolist (prose (getf row :described-by))
        (format out "        described by ~a (~d name~:p here)~%"
                (getf prose :document) (getf prose :names))))
    (when (null (getf report :systems)) (format out "    (none placed)~%"))
    (format out "~%DEPENDENCIES BETWEEN SYSTEMS~%~%")
    (format out "  Both directions are reported and neither is judged. A cycle here is a fact~%")
    (format out "  about the code, not a finding: which direction was intended is not in the~%")
    (format out "  index, and calling one of them wrong would be the generated invariant this~%")
    (format out "  document refuses to write.~%~%")
    (dolist (row (getf report :system-edges))
      (format out "    ~24a -> ~24a ~5d  ~{~(~a~)~^ ~}~%"
              (getf row :from) (getf row :to) (getf row :count) (getf row :rel-types)))
    (when (null (getf report :system-edges)) (format out "    (none)~%"))
    (format out "~%PROTOCOLS~%~%")
    (format out "  A generic function and the definitions implementing it. The one~%")
    (format out "  architectural shape an index can name without interpreting anything.~%~%")
    (dolist (row (getf report :protocols))
      (format out "    ~a~@[  [~a]~]  ~d implementor~:p~%"
              (getf row :name) (getf row :location) (getf row :implementor-count)))
    (when (null (getf report :protocols)) (format out "    (none)~%"))
    (format out "~%ENTRY POINTS~%~%")
    (format out "  ~d definition~:p with no caller in this tree.~%"
            (getf report :entry-point-count))
    (when (getf report :entry-point-qualifier)
      (format out "  ~a~%" (getf report :entry-point-qualifier)))
    (format out "~%")
    (dolist (row (getf report :entry-points))
      (format out "    ~(~a~) ~a~@[  [~a]~]~%"
              (getf row :type) (getf row :name) (getf row :location)))
    (format out "~%HUBS~%~%")
    (format out "  Ranked by inbound edges. A measurement, not a verdict -- whether a hub is~%")
    (format out "  a core abstraction or a god object is a judgement, and this document does~%")
    (format out "  not make it.~%~%")
    (dolist (row (getf report :hubs))
      (format out "    ~5d  ~(~a~) ~a~@[  [~a]~]~%"
              (getf row :inbound) (getf row :type) (getf row :name) (getf row :location)))
    (when (null (getf report :hubs)) (format out "    (none)~%"))
    (format out "~%WHAT AN AUTHOR ALREADY WROTE~%~%")
    (format out "  This section is a map, not a summary. Each document below is named~%")
    (format out "  because it mentions that many entities in this codebase -- a count, not~%")
    (format out "  a judgement -- and nothing here paraphrases what any of them says. Go~%")
    (format out "  and read them: they hold the half an index cannot derive, which is why~%")
    (format out "  the code is the way it is.~%~%")
    (format out "  The percentage is how much of each document's own vocabulary resolved.~%")
    (format out "  A low one means prose about something this repository does not contain,~%")
    (format out "  not prose that is wrong.~%~%")
    (dolist (row (getf report :prose))
      (format out "    ~a~@[  (~d%)~]~%      ~{~a~^  ~}~%"
              (getf row :document) (getf row :percent)
              (mapcar (lambda (s) (format nil "~a:~d" (getf s :name) (getf s :names)))
                      (getf row :systems))))
    (when (null (getf report :prose))
      (format out "    (no indexed prose names anything in this codebase)~%"))
    (format out "~%WHAT THIS DOCUMENT DESCRIBES~%~%")
    (format out "  The describes: field names ~d entit~:@p, drawn from the protocols and hubs~%"
            (length describes))
    (format out "  above.~@[ ~d candidate~:p ~:*~[~;was~:;were~] left out because the name matches~%  several entities and a reference to it would resolve to none of them.~]~%"
            (and (plusp dropped) dropped))))

(defun generate-architecture (repository &key document-directory)
  "Write an architecture document for REPOSITORY from its index. Returns a report.

Create-only, like everything else init writes: an existing document is reported
and left alone, so re-running never overwrites what a human improved (REQ-0021
R9). The document directory comes from the manifest where there is one, because
that is where R2's choice was recorded and a generator that guessed `docs' would
write into the wrong place in exactly the trees that chose otherwise."
  (let* ((repository (if (repository-p repository)
                         repository
                         (or (find-repository repository)
                             (return-from generate-architecture
                               (list :problems (list (format nil "No repository named ~a."
                                                             repository)))))))
         (root (repository-root repository))
         (graph (repository-graph repository))
         (manifest (read-manifest root))
         (docs-name (or document-directory
                        (getf manifest :document-directory)
                        "docs"))
         (arch-dir (merge-pathnames (format nil "~a/arch/" docs-name) root)))
    (with-repository-lock (repository)
      (let ((provenance (index-provenance repository)))
        (let* ((report (apply #'structure-report graph
                              :repository (repository-name repository)
                              provenance))
               (doc-id (next-document-id arch-dir "ARCH"))
               (path (merge-pathnames (format nil "~a.yaml" doc-id) arch-dir)))
          (multiple-value-bind (describes dropped) (architecture-describes graph report)
            (cond
              ((probe-file path)
               (list :repository (repository-name repository)
                     :problems (list (format nil "~a already exists." path))
                     :created nil))
              (t
               (ensure-directories-exist path)
               (with-open-file (out path :direction :output :if-exists :error
                                         :if-does-not-exist :create)
                 (write-string (render-architecture report doc-id describes dropped) out))
               (let ((relative (workspace-relative-path path root)))
                 ;; So that removal can account for it. Init records what it
                 ;; wrote, but this runs later -- once there is an index to
                 ;; derive a report from -- and without recording itself here
                 ;; full removal meets a document the manifest cannot explain
                 ;; and refuses on it, which is R13a protecting the tree from
                 ;; Loom's own output. Found by running removal against a
                 ;; prepared copy of game-server.
                 (record-created-path root relative)
                 (list :repository (repository-name repository)
                       :problems '()
                       :document doc-id
                       :commit (getf provenance :commit)
                       :describes (length describes)
                       :dropped dropped
                       :recorded (and (read-manifest root) t)
                       :created relative))))))))))
