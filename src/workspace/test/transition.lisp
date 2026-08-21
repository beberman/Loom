;;;
;;; Tests for the document state transition of REQ-0022 / DES-0019.
;;;
;;; These build their own document trees in a scratch directory rather than
;;; running against docs/, and that is forced rather than fastidious: the thing
;;; under test edits files and renames them, so a test pointed at this
;;; repository would either mutate the tree it is being run from or have to
;;; undo its own writes and be believed about it.
;;;
;;; The scratch trees are small on purpose. Each names the one property it
;;; exists to witness -- a status line that is not the one in the prose, a
;;; second unfinished plan that blocks a design, a second document whose
;;; refusal must leave the first file untouched -- and CON-0003 applies to
;;; every one of them: the fixture is built so the assertion fails if the
;;; behaviour is removed.
;;;

(in-package :loom-workspace-test)

(def-suite transition
  :in all-tests
  :description "Setting a document's status, and the cascade a plan drives.")

(in-suite transition)

;;; ------------------------------------------------------------------
;;; Fixtures
;;; ------------------------------------------------------------------

(defmacro with-document-tree ((root) &body body)
  "A throwaway directory with a docs/ tree in it, deleted afterwards."
  `(let ((,root (ensure-directories-exist
                 (merge-pathnames (format nil "loom-transition-~a/" (random 100000))
                                  (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun write-document (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string contents out))
    path))

(defun document-text (root relative)
  (utils:read-file (merge-pathnames relative root)))

(defun watch-tree (root)
  "Index ROOT without starting a monitor. A poll would race every write below."
  (watch-repository root :monitor nil :quiet t))

(defun drop-tree (repository)
  (unwatch-repository (repository-name repository)))

(defmacro with-indexed-tree ((repository root) &body body)
  `(let ((,repository (watch-tree ,root)))
     (unwind-protect (progn ,@body) (drop-tree ,repository))))

(defun plan-document (id refines &key (status "draft"))
  (format nil "id: ~a~%title: a plan~%status: ~a~%refines: [~{~a~^, ~}]~%~
body: |~%  STEPS~%~%  1. do the thing.~%" id status refines))

(defun design-document (id refines &key (status "draft"))
  (format nil "id: ~a~%title: a design~%status: ~a~%refines: [~{~a~^, ~}]~%~
body: |~%  D1  the shape.~%" id status refines))

(defun requirement-document (id &key (status "draft") (refines '()))
  (format nil "id: ~a~%title: a requirement~%status: ~a~%~@[refines: [~{~a~^, ~}]~%~]~
body: |~%  R1  the ask.~%" id status refines))

;;; ------------------------------------------------------------------
;;; The edit rule (DES-0019 D2)
;;; ------------------------------------------------------------------

(test the-status-line-is-the-top-level-key-and-never-the-one-in-the-prose
  ;; The hazard REQ-0022 ranked second, and the reason the scan is a rule
  ;; rather than a line match. Every document in Loom's tree has a body: block
  ;; scalar and prose inside one routinely contains lines like "status: draft"
  ;; while discussing statuses -- this test's fixture does, twice, and one of
  ;; them appears *before* the real key so a naive first-match scan picks the
  ;; wrong line rather than merely risking it.
  (let ((contents (format nil "id: DES-0001~%summary: |~%  A design whose ~
summary says~%  status: accepted~%  and means nothing by it.~%status: draft~%~
body: |~%  status: implemented is written here too.~%")))
    (multiple-value-bind (start end current) (loom-workspace::top-level-status-line contents)
      (is (eql :draft current) "the value read is the top-level key's, not the prose's")
      (let ((edited (loom-workspace::replace-status-line contents start end :implemented)))
        (is (search (format nil "~%status: implemented~%") edited)
            "the top-level key was rewritten")
        (is (search (format nil "  status: accepted~%") edited)
            "the indented status inside the summary block scalar is untouched")
        (is (search "  status: implemented is written here too." edited)
            "the indented status inside the body block scalar is untouched")
        ;; Byte for byte apart from the one line: no round-trip, no
        ;; reserialisation, nothing reordered.
        (is (= (- (length edited) (length contents))
               (- (length "status: implemented") (length "status: draft")))
            "exactly one line's worth of text changed")))))

(test a-trailing-comment-does-not-become-part-of-the-status
  ;; CON-0004's own bug template writes `status: open              # closed once
  ;; fixed'. Reading the comment as part of the value makes the status
  ;; unrecognisable, which would make the command refuse every document written
  ;; from that template.
  (multiple-value-bind (start end current)
      (loom-workspace::top-level-status-line
       (format nil "id: BUG-0001~%status: open              # closed once fixed~%"))
    (declare (ignore start end))
    (is (eql :open current))))

(test a-document-with-no-top-level-status-line-has-none-to-find
  (is (null (loom-workspace::top-level-status-line
             (format nil "id: CON-0001~%title: a concept~%body: |~%  status: none~%")))))

;;; ------------------------------------------------------------------
;;; set-status: the primitive
;;; ------------------------------------------------------------------

(test setting-a-terminal-status-moves-the-file-into-completed
  ;; R3: placement and status can no longer disagree, because one operation
  ;; sets both.
  (with-document-tree (root)
    (write-document root "docs/bugs/BUG-0001.yaml"
                    (format nil "id: BUG-0001~%title: a defect~%status: open~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "BUG-0001" "closed")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (null (probe-file (merge-pathnames "docs/bugs/BUG-0001.yaml" root)))
            "the flat file is gone")
        (is-true (probe-file (merge-pathnames "docs/bugs/completed/BUG-0001.yaml" root))
                 "the file is in completed/")
        (is (search (format nil "~%status: closed~%")
                    (document-text root "docs/bugs/completed/BUG-0001.yaml")))))))

(test a-status-that-stops-being-terminal-moves-the-file-back-out
  ;; The other direction of R3. Without it "placement and status cannot
  ;; disagree" holds in one direction only, and reopening a bug leaves a closed
  ;; file in completed/ saying open.
  (with-document-tree (root)
    (write-document root "docs/bugs/completed/BUG-0002.yaml"
                    (format nil "id: BUG-0002~%title: a defect~%status: closed~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "BUG-0002" "open")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is-true (probe-file (merge-pathnames "docs/bugs/BUG-0002.yaml" root)))
        (is (null (probe-file (merge-pathnames "docs/bugs/completed/BUG-0002.yaml" root))))))))

(test a-status-outside-the-categorys-vocabulary-is-refused
  ;; The union of the four workflow vocabularies is what the :DOCUMENT entity
  ;; type declares, so validating against the ontology alone would let a
  ;; requirement be set to `closed'. The category is what narrows it, and
  ;; without that narrowing this test passes for the wrong reason.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "REQ-0001" "closed")))
        (is (= 1 (length (getf report :problems))))
        (is (search "closed" (first (getf report :problems))))
        (is (search "status: draft" (document-text root "docs/requirements/REQ-0001.yaml"))
            "the file was not touched")))))

(test a-document-whose-type-has-no-status-property-is-refused-not-repaired
  ;; DES-0019 D3. :CONCEPT declares no :STATUS, so inserting a line would write
  ;; a fact the index cannot hold -- and the file would then carry a field
  ;; nothing reads, which is the shape BUG-0019 and BUG-0023 are both made of.
  (with-document-tree (root)
    (write-document root "docs/concepts/CON-0001.yaml"
                    (format nil "id: CON-0001~%title: a concept~%body: |~%  words.~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "CON-0001" "superseded")))
        (is (= 1 (length (getf report :problems))))
        (is (search "no status field" (first (getf report :problems))))))))

(test setting-the-status-a-document-already-has-writes-nothing
  ;; R7's shape at the primitive. An idempotent command that rewrites the file
  ;; anyway is one that shows a diff on every run, which is how a developer
  ;; learns to stop reading them.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "DES-0001" "draft")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (null (getf report :changed)) "nothing was written")))))

;;; ------------------------------------------------------------------
;;; The propagation query (DES-0019 D4)
;;; ------------------------------------------------------------------

(test a-document-a-second-unfinished-plan-still-refines-is-left-alone
  ;; REQ-0022's strongest argument for building this rather than restating it.
  ;; Two plans refine one design; completing the first must not mark the design
  ;; implemented, and saying which plan is in the way is the useful answer.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (write-document root "docs/plans/PLAN-0002.yaml" (plan-document "PLAN-0002" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let* ((report (complete-plan repository "PLAN-0001"
                                    :verdicts "DES-0001=implemented"))
             (row (find "DES-0001" (getf report :documents)
                        :key (lambda (r) (getf r :doc-id)) :test #'string=)))
        (is (equal '("PLAN-0002") (getf row :blocked-by)))
        (is (eq :blocked (getf row :action)))
        (is (some (lambda (problem) (search "PLAN-0002" problem)) (getf report :problems))
            "the refusal names the plan in the way: ~a" (getf report :problems))
        (is (null (getf report :changed)))
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))
            "a refusal leaves the tree exactly as it was")))))

(test the-last-plan-refining-a-document-unblocks-it
  ;; The complement, and the half that makes the test above mean something: with
  ;; the second plan already final, the same call goes through. Without this the
  ;; blocking test would pass against an implementation that blocked everything.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (write-document root "docs/plans/completed/PLAN-0002.yaml"
                    (plan-document "PLAN-0002" '("DES-0001") :status "final"))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001" :verdicts "DES-0001=implemented")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (= 2 (length (getf report :changed))))
        (is-true (probe-file (merge-pathnames "docs/design/completed/DES-0001.yaml" root)))
        (is-true (probe-file (merge-pathnames "docs/plans/completed/PLAN-0001.yaml" root)))))))

(test the-cascade-walks-upward-only-through-a-terminal-verdict
  ;; RULE-0005: "The walk continues upward only on implemented." A design marked
  ;; partial has an OUTSTANDING section, which is work, so the requirement above
  ;; it is not implemented either and must not be offered as though it were.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let* ((full (complete-plan repository "PLAN-0001"))
             (ids (mapcar (lambda (r) (getf r :doc-id)) (getf full :documents))))
        (is (equal '("PLAN-0001" "DES-0001" "REQ-0001") ids)
            "a dry run previews the whole chain: ~a" ids))
      (let* ((report (complete-plan repository "PLAN-0001" :verdicts "DES-0001=partial"))
             (ids (mapcar (lambda (r) (getf r :doc-id)) (getf report :documents))))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (equal '("PLAN-0001" "DES-0001") ids)
            "the walk stopped at the partial design: ~a" ids)
        (is (search "status: draft" (document-text root "docs/requirements/REQ-0001.yaml"))
            "the requirement above a partial design stays where it is")
        (is-true (probe-file (merge-pathnames "docs/design/DES-0001.yaml" root))
                 "a partial document stays flat -- it has an OUTSTANDING section")))))

(test a-terminal-verdict-carries-the-cascade-to-the-requirement
  ;; The whole point, end to end: plan, design and requirement move together in
  ;; one command, with three status lines and three renames.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001"
                                   :verdicts "DES-0001=implemented REQ-0001=implemented")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (= 3 (length (getf report :changed))))
        (is (every (lambda (change) (getf change :moved)) (getf report :changed)))
        (is (search (format nil "~%status: final~%")
                    (document-text root "docs/plans/completed/PLAN-0001.yaml")))
        (is (search (format nil "~%status: implemented~%")
                    (document-text root "docs/design/completed/DES-0001.yaml")))
        (is (search (format nil "~%status: implemented~%")
                    (document-text root "docs/requirements/completed/REQ-0001.yaml")))))))

(test completing-a-plan-twice-changes-nothing-the-second-time
  ;; R7. The second run has to find the moved files, which is what makes this a
  ;; test of the reindex as well as of idempotence.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (complete-plan repository "PLAN-0001" :verdicts "DES-0001=implemented")
      (let ((again (complete-plan repository "PLAN-0001" :verdicts "DES-0001=implemented")))
        (is (null (getf again :problems)) "~a" (getf again :problems))
        (is (null (getf again :changed)) "the second run wrote nothing")
        (is (every (lambda (row) (member (getf row :action) '(:unchanged :already-finished)))
                   (getf again :documents))
            "~a" (getf again :documents))))))

(test a-cascade-with-a-missing-verdict-is-refused-whole
  ;; All or nothing. A cascade that applied the verdict it was given and left
  ;; the other document in draft would produce exactly the half-updated state
  ;; RULE-0005 was written to prevent, one command later.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001" :verdicts "DES-0001=implemented")))
        (is (some (lambda (problem) (search "REQ-0001 needs a verdict" problem))
                  (getf report :problems))
            "~a" (getf report :problems))
        (is (null (getf report :changed)))
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))
            "not even the plan was written")))))

(test a-dry-run-writes-nothing-and-names-what-it-would-need
  ;; D5: the dry run is the default rather than a flag, which is the right
  ;; default for a command whose failure mode is editing files.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001")))
        (is-true (getf report :dry-run))
        (is (null (getf report :problems)) "a dry run refuses nothing")
        (is (null (getf report :changed)))
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml")))
        (let ((row (find "DES-0001" (getf report :documents)
                         :key (lambda (r) (getf r :doc-id)) :test #'string=)))
          (is (eq :awaiting-verdict (getf row :action))))))))

(test completing-something-that-is-not-a-plan-is-refused
  ;; A plan is identified by its :CATEGORY -- the fact the indexer recorded from
  ;; the directory -- and not by a PLAN- prefix, which a foreign tree prepared
  ;; by REQ-0021 need not share.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "DES-0001" :verdicts "REQ-0001=implemented")))
        (is (= 1 (length (getf report :problems))))
        (is (search "not a plan" (first (getf report :problems))))))))

;;; ------------------------------------------------------------------
;;; Plan, then apply (DES-0019 D6)
;;; ------------------------------------------------------------------

(test a-refusal-on-the-second-document-leaves-the-first-file-untouched
  ;; The property the whole plan-then-apply split exists for: nothing is written
  ;; until everything has been checked. Here a plain file occupies the name the
  ;; requirement's completed/ directory needs, so its move cannot be prepared --
  ;; and the plan and the design, which were checked and would have been written
  ;; first, must still be exactly as they were.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    ;; No extension, so no analyzer claims it and it is not a document; it is
    ;; simply in the way. ENSURE-DIRECTORIES-EXIST cannot make a directory here.
    (write-document root "docs/requirements/completed" "not a directory")
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001"
                                   :verdicts "DES-0001=implemented REQ-0001=implemented")))
        (is-true (getf report :problems) "the blocked destination had to refuse something")
        (is (null (getf report :changed)))
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))
            "the plan, which would have been written first, is untouched")
        (is (search "status: draft" (document-text root "docs/design/DES-0001.yaml"))
            "and so is the design")))))

(test a-document-whose-file-declares-an-unknown-status-is-reported-not-overwritten
  ;; BUG-0019's shape: `status: fixed' was dropped to NIL by AS-KEYWORD, so the
  ;; index held no status while the file held a word. A document in an unknown
  ;; state is exactly where a human should look.
  (with-document-tree (root)
    (write-document root "docs/bugs/BUG-0001.yaml"
                    (format nil "id: BUG-0001~%title: a defect~%status: fixed~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "BUG-0001" "closed")))
        (is-true (getf report :problems))
        (is (some (lambda (problem) (search "fixed" problem)) (getf report :problems))
            "~a" (getf report :problems))
        (is (search "status: fixed" (document-text root "docs/bugs/BUG-0001.yaml")))))))

;;; ------------------------------------------------------------------
;;; Argument parsing
;;; ------------------------------------------------------------------

(test verdicts-parse-the-same-from-a-string-and-from-console-tokens
  ;; One spelling on three surfaces: a console line arrives split, a REST query
  ;; parameter and an MCP argument arrive whole.
  (is (equal '(("DES-0019" . :implemented) ("REQ-0022" . :partial))
             (parse-verdicts "DES-0019=implemented REQ-0022=partial")))
  (is (equal '(("DES-0019" . :implemented))
             (parse-verdicts '("DES-0019=implemented"))))
  (is (null (parse-verdicts nil)))
  (multiple-value-bind (verdicts problems) (parse-verdicts "DES-0019")
    (is (null verdicts))
    (is (= 1 (length problems)))))

(test a-verdict-for-a-document-the-cascade-never-reaches-is-refused
  ;; BUG-0026. The verdict lookup is driven by the walk, so a verdict for a
  ;; document the walk never visits was never consulted and never reported --
  ;; the caller typed it, nothing happened to it, and the command said nothing.
  ;;
  ;; The walk stopping is correct: a `partial' design has an OUTSTANDING
  ;; section, which is work, so the requirement above it is not implemented
  ;; either. What was wrong is that the stop silently invalidated an argument
  ;; already supplied. This is the case the suite did not have -- a well-formed
  ;; verdict for a document that is neither blocked nor reached.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001"
                                   :verdicts "DES-0001=partial REQ-0001=partial")))
        (is (some (lambda (problem) (search "REQ-0001" problem)) (getf report :problems))
            "the unused verdict has to be named: ~a" (getf report :problems))
        (is (null (getf report :changed))
            "and nothing is written, because the command is all or nothing")
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))
            "not even the plan, which would otherwise have been written first")))))

(test a-verdict-for-every-document-the-cascade-reaches-is-not-refused
  ;; The complement, without which the test above passes against an
  ;; implementation that refuses every cascade with a non-terminal verdict in
  ;; it. Here the walk stops at the partial design and no verdict is left over.
  (with-document-tree (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001" :verdicts "DES-0001=partial")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (= 2 (length (getf report :changed))))))))


;;; ------------------------------------------------------------------
;;; A document is checkable before it is written (REQ-0034, DES-0029 D5)
;;; ------------------------------------------------------------------
;;;
;;; The loop this replaces: write the file, wait for the monitor, run `check',
;;; subtract the repository's own baseline from the report, edit, repeat. Four
;;; round trips on the game-server session that prompted the requirement, to
;;; learn something the index could answer before any file existed.

(defun reference-status (report name)
  (let ((entry (find name (getf report :references)
                     :key (lambda (e) (getf e :name)) :test #'string=)))
    (getf entry :status)))

(defun reference-entry (report name)
  (find name (getf report :references)
        :key (lambda (e) (getf e :name)) :test #'string=))

(test a-draft-resolves-against-the-index-without-being-written
  (with-document-tree (root)
    ;; A tree with two same-named functions in it, so the ambiguous case is
    ;; real rather than simulated, and one that is unique.
    (write-document root "src/server.lisp"
                    (format nil "(in-package :app)~%(defun check-database () t)~%~
(defun start-server () (check-database))~%"))
    (write-document root "src/api.lisp"
                    (format nil "(in-package :app)~%(defun check-database () t)~%"))
    (with-indexed-tree (repository root)
      (let* ((draft (format nil "id: DES-0001~%title: a design~%status: draft~%~
affects: [start-server, check-database, no-such-name]~%~
body: |~%  D1  the shape.~%"))
             (report (check-document-references
                      repository "docs/design/DES-0001.yaml" :contents draft)))
        (is (null (getf report :error))
            "a path the document analyzer claims needs no file on disk: ~a"
            (getf report :error))
        (is (equal "DES-0001" (getf report :document)))
        (is (eq :resolved (reference-status report "start-server"))
            "the name with one definition")
        (is (eq :ambiguous (reference-status report "check-database"))
            "the name with two, and it is not reported as rot")
        (is (= 2 (length (getf (reference-entry report "check-database") :candidates)))
            "with the candidates an author pastes back into the field")
        (is (eq :unresolved (reference-status report "no-such-name"))
            "and the name that is genuinely not there")))))

(test checking-a-document-asserts-nothing
  ;; REQ-0034 R4, and the acceptance is the count rather than the intent: a
  ;; report is worth nothing if asking for it changes the answer.
  (with-document-tree (root)
    (write-document root "src/server.lisp"
                    (format nil "(in-package :app)~%(defun start-server () t)~%"))
    (with-indexed-tree (repository root)
      (let* ((graph (repository-graph repository))
             (before-entities (length (all-entities graph)))
             (before-edges (length (all-relationships graph)))
             (draft (format nil "id: DES-0001~%title: a design~%status: draft~%~
affects: [start-server]~%body: |~%  D1  the shape.~%")))
        (check-document-references repository "docs/design/DES-0001.yaml"
                                   :contents draft)
        (is (= before-entities (length (all-entities graph))))
        (is (= before-edges (length (all-relationships graph)))
            "the draft named a function and earned it no edge")))))

(test a-path-no-analyzer-claims-is-refused-with-a-reason
  ;; A path no analyzer claims produced nothing, and saying so is a different
  ;; answer from reporting a document with no references. Reporting them alike
  ;; would be CON-0001's fabricated fact in the report's own shape.
  ;;
  ;; .rst rather than .txt: REQ-0028 claims .txt, .md and .markdown wherever
  ;; the repository keeps them, and a claimed file really is a document -- one
  ;; with no declared fields, which this operation reports as no references
  ;; rather than as a refusal.
  (with-document-tree (root)
    (write-document root "src/server.lisp"
                    (format nil "(in-package :app)~%(defun start-server () t)~%"))
    (with-indexed-tree (repository root)
      (let ((report (check-document-references repository "notes.rst"
                                               :contents "id: DES-0001")))
        (is (stringp (getf report :error)))
        (is (null (getf report :references))))
      (let ((markdown (check-document-references repository "notes.md"
                                                 :contents "# Notes")))
        (is (null (getf markdown :error))
            "a markdown file is a document REQ-0028 claims")
        (is (null (getf markdown :references))
            "and it declares no references, which is not the same as failing")))))

(test an-id-in-a-draft-names-one-candidate-of-an-ambiguous-name
  ;; REQ-0030 R3 reaching the author through REQ-0034's operation, which is
  ;; the pair working: the report says a name is ambiguous and prints the ids,
  ;; and an id put back in the field resolves to exactly one entity.
  (with-document-tree (root)
    (write-document root "src/server.lisp"
                    (format nil "(in-package :app)~%(defun check-database () t)~%"))
    (write-document root "src/api.lisp"
                    (format nil "(in-package :app)~%(defun check-database () t)~%"))
    (with-indexed-tree (repository root)
      (let* ((first-pass (check-document-references
                          repository "docs/design/DES-0001.yaml"
                          :contents (format nil "id: DES-0001~%title: a design~%~
status: draft~%affects: [check-database]~%body: |~%  D1~%")))
             (candidate (first (getf (reference-entry first-pass "check-database")
                                     :candidates)))
             (second-pass (check-document-references
                           repository "docs/design/DES-0001.yaml"
                           :contents (format nil "id: DES-0001~%title: a design~%~
status: draft~%affects: [~a]~%body: |~%  D1~%" candidate))))
        (is (eq :resolved (reference-status second-pass candidate))
            "the id the first report printed resolves in the second")
        (is (equal candidate (getf (reference-entry second-pass candidate) :target)))))))
