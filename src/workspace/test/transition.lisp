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

(defvar *transition-store* :file
  "Which document store the fixture builds: :FILE or :MEMORY.
DES-0051 D9 part B. WITH-DOCUMENT-TREES runs a body under each.")

(defvar *transition-docstore* nil
  "The in-memory store the current fixture holds its documents in, or NIL when
they are files.")

(defmacro with-document-tree ((root) &body body)
  "A throwaway directory with a docs/ tree in it, deleted afterwards.

The directory exists under either store: a tree has code files and a .git
directory as well as documents, and only the documents move into the store."
  `(let ((,root (ensure-directories-exist
                 (merge-pathnames (format nil "loom-transition-~a/" (random 100000))
                                  (uiop:temporary-directory))))
         (*transition-docstore* (and (eq *transition-store* :memory)
                                     ;; With CON-0004's terminal column, as
                                     ;; REPOSITORY-DOCUMENT-STORE gives its
                                     ;; default store: a store told nothing
                                     ;; moves no document, and every one of
                                     ;; the placement tests below would pass
                                     ;; by never transitioning anything.
                                     (loom-docstore:make-memory-docstore
                                      :terminal-p #'terminal-category-status-p))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defmacro with-document-trees ((root) &body body)
  "WITH-DOCUMENT-TREE once with the file store and once with the in-memory one.

DES-0051 D9 part B: a test that passes on files and fails in memory has found
a caller that assumes a document is a file. A failure names the assertion and
not the run, because both runs are one test -- bind *TRANSITION-STORE* to see
which of the two it was."
  `(dolist (*transition-store* '(:file :memory))
     (with-document-tree (,root) ,@body)))

(defun store-document-path-p (relative)
  "True when RELATIVE is a path the document store holds: YAML under docs/."
  (let ((name (string relative)))
    (and (eql 0 (search "docs/" name))
         (member (pathname-type name) '("yaml" "yml") :test #'string-equal)
         t)))

(defun document-ref (relative)
  "The in-memory store's ref for the document at RELATIVE, or NIL."
  (let ((record (find relative (loom-docstore:docstore-enumerate *transition-docstore*)
                      :key #'loom-docstore:docstore-record-address :test #'string=)))
    (and record (loom-docstore:docstore-record-ref record))))

(defun write-document (root relative contents)
  "Put CONTENTS at RELATIVE, in whichever store the fixture holds.

A path the store does not claim is written to disk under either store: the
trees below carry a file in the way of a completed/ directory, and a .rst that
no analyzer claims, and neither is a document."
  (let ((path (merge-pathnames relative root)))
    (cond ((and *transition-docstore* (store-document-path-p relative))
           (let ((ref (document-ref relative)))
             (if ref
                 (loom-docstore:memory-docstore-replace *transition-docstore* ref contents)
                 (loom-docstore:memory-docstore-put
                  *transition-docstore*
                  (second (loom-utils:path-segments relative))
                  (pathname-name relative)
                  contents))))
          (t
           (ensure-directories-exist path)
           (with-open-file (out path :direction :output :if-exists :supersede)
             (write-string contents out))))
    path))

(defun document-text (root relative)
  "The text of the document at RELATIVE, from whichever store holds it.

A test that asserts on this is asking what the document says, which every
store can answer. A test that asks where the file is uses PROBE-FILE and is a
file-store test (DES-0051 D9 part C)."
  (let ((ref (and *transition-docstore* (document-ref relative))))
    (if ref
        (loom-docstore:docstore-read *transition-docstore* ref)
        (utils:read-file (merge-pathnames relative root)))))

(defun document-at-p (root relative)
  "True when the store the fixture holds has a document at RELATIVE.

PROBE-FILE's question, asked of whichever store this is. Where a document is
filed is placement, and every store answers that with an address; that the
address is also a path on disk is the file property, and a test that needs it
says PROBE-FILE and stays on the file store (DES-0051 D9 part C)."
  (if *transition-docstore*
      (and (document-ref relative) t)
      (and (probe-file (merge-pathnames relative root)) t)))

(defun watch-tree (root)
  "Index ROOT without starting a monitor. A poll would race every write below."
  (watch-repository root :monitor nil :quiet t :docstore *transition-docstore*))

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

(defun decision-document (id refines &key (status "accepted"))
  ;; BUG-0065 F1b's fixture. A decision's vocabulary -- proposed, accepted,
  ;; superseded, rejected -- has no terminal member, which is what makes it
  ;; the genre the walk could neither finish nor pass.
  (format nil "id: ~a~%title: a decision~%status: ~a~%refines: [~{~a~^, ~}]~%~
rationale: |~%  because.~%" id status refines))

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
  (with-document-trees (root)
    (write-document root "docs/bugs/BUG-0001.yaml"
                    (format nil "id: BUG-0001~%title: a defect~%status: open~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "BUG-0001" "closed")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (null (document-at-p root "docs/bugs/BUG-0001.yaml"))
            "the flat file is gone")
        (is-true (document-at-p root "docs/bugs/completed/BUG-0001.yaml")
                 "the file is in completed/")
        (is (search (format nil "~%status: closed~%")
                    (document-text root "docs/bugs/completed/BUG-0001.yaml")))))))

(test a-status-that-stops-being-terminal-moves-the-file-back-out
  ;; The other direction of R3. Without it "placement and status cannot
  ;; disagree" holds in one direction only, and reopening a bug leaves a closed
  ;; file in completed/ saying open.
  (with-document-trees (root)
    (write-document root "docs/bugs/completed/BUG-0002.yaml"
                    (format nil "id: BUG-0002~%title: a defect~%status: closed~%"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "BUG-0002" "open")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is-true (document-at-p root "docs/bugs/BUG-0002.yaml"))
        (is (null (document-at-p root "docs/bugs/completed/BUG-0002.yaml")))))))

(test a-superseded-design-is-filed-with-the-finished-ones
  ;; A superseded design has no work left in it. It stayed flat until
  ;; 2026-08-23 because RULE-0007's text named `implemented' and nothing else,
  ;; which left DES-0034 and DES-0036 -- both built, measured and withdrawn --
  ;; sitting in docs/design/ where `ls' and `context' read them as work in
  ;; progress.
  (with-document-trees (root)
    (write-document root "docs/design/DES-0001.yaml"
                    (design-document "DES-0001" '("REQ-0001")))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "DES-0001" "superseded")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (null (document-at-p root "docs/design/DES-0001.yaml"))
            "the flat file is gone")
        (is-true (document-at-p root "docs/design/completed/DES-0001.yaml")
                 "the file is in completed/")
        (is (search (format nil "~%status: superseded~%")
                    (document-text root "docs/design/completed/DES-0001.yaml")))))))

(test a-partial-design-stays-flat-because-outstanding-is-work
  ;; The line the terminal set is drawn on. `partial' and `superseded' are both
  ;; end states of a design in the sense that no plan is running against them,
  ;; and only one of them means there is nothing left to do.
  (with-document-trees (root)
    (write-document root "docs/design/DES-0002.yaml"
                    (design-document "DES-0002" '("REQ-0001")))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "DES-0002" "partial")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is-true (document-at-p root "docs/design/DES-0002.yaml")
                 "the file is still flat")
        (is (null (document-at-p root "docs/design/completed/DES-0002.yaml")))))))

(test a-requirement-can-be-closed-and-is-filed-with-the-finished-ones
  ;; REQ-0009. A requirement that is finished and not implemented had no word
  ;; for itself: draft reads as work in progress and implemented is false. The
  ;; word is `closed', and it is terminal, so the document is filed where the
  ;; finished ones are rather than left flat offering itself to `context'.
  ;;
  ;; Before the vocabulary change this failed with "closed is not a status a
  ;; requirements document takes. Try: draft, accepted, implemented, partial".
  (with-document-trees (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "REQ-0001" "closed")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is-true (document-at-p root "docs/requirements/completed/REQ-0001.yaml")
                 "a closed requirement stayed flat")
        (is (search (format nil "~%status: closed~%")
                    (document-text root "docs/requirements/completed/REQ-0001.yaml")))))))

(test a-status-outside-the-categorys-vocabulary-is-refused
  ;; The union of the four workflow vocabularies is what the :DOCUMENT entity
  ;; type declares, so validating against the ontology alone would let a
  ;; requirement be set to `final'. The category is what narrows it, and
  ;; without that narrowing this test passes for the wrong reason.
  ;;
  ;; `final' and not `closed'. Closed was the word here until REQ-0009 gave it
  ;; to requirements as well, at which point this test started failing -- which
  ;; is the narrowing doing its job on a vocabulary that had moved. A plan
  ;; reaches final and a requirement does not.
  (with-document-trees (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (with-indexed-tree (repository root)
      (let ((report (set-document-status repository "REQ-0001" "final")))
        (is (= 1 (length (getf report :problems))))
        (is (search "final" (first (getf report :problems))))
        (is (search "status: draft" (document-text root "docs/requirements/REQ-0001.yaml"))
            "the file was not touched")))))

(test every-document-type-declares-a-status-property
  ;; DES-0019 D3 wrote a refusal for a document whose type declares no :STATUS:
  ;; inserting a line would write a fact the index cannot hold, and the file
  ;; would then carry a field nothing reads, which is the shape BUG-0019 and
  ;; BUG-0023 are both made of. Its exemplar was :CONCEPT.
  ;;
  ;; BUG-0066 removed that exemplar and the last one beside it. A concept
  ;; declares :STATUS now because five concept files across three trees were
  ;; already writing one, and :RULE declares it because the :RULE method had
  ;; always read it and only the declaration was missing -- which made
  ;; DOCUMENT-STATUS-VOCABULARY, reading the declaration and not the stored
  ;; property, answer NIL for every rule.
  ;;
  ;; So the refusal stays as defensive code and this asserts the invariant that
  ;; makes it unreachable, which is the stronger statement and the one that
  ;; fails if a genre is added without a status. The old test asserted a
  ;; property of :CONCEPT that was a defect rather than a design.
  (dolist (type loom-graph::*document-types*)
    (is-true (loom-ontology:find-property type :status)
             "~a declares no :STATUS, so SET-DOCUMENT-STATUS would refuse every ~
document of that genre and `complete' would report it :NO-STATUS" type)))

(test setting-the-status-a-document-already-has-writes-nothing
  ;; R7's shape at the primitive. An idempotent command that rewrites the file
  ;; anyway is one that shows a diff on every run, which is how a developer
  ;; learns to stop reading them.
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (write-document root "docs/plans/completed/PLAN-0002.yaml"
                    (plan-document "PLAN-0002" '("DES-0001") :status "final"))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001" :verdicts "DES-0001=implemented")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (= 2 (length (getf report :changed))))
        (is-true (document-at-p root "docs/design/completed/DES-0001.yaml"))
        (is-true (document-at-p root "docs/plans/completed/PLAN-0001.yaml"))))))

(test the-cascade-walks-upward-only-through-a-terminal-verdict
  ;; RULE-0005: "The walk continues upward only on implemented." A design marked
  ;; partial has an OUTSTANDING section, which is work, so the requirement above
  ;; it is not implemented either and must not be offered as though it were.
  (with-document-trees (root)
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
        (is-true (document-at-p root "docs/design/DES-0001.yaml")
                 "a partial document stays flat -- it has an OUTSTANDING section")))))

(test a-terminal-verdict-carries-the-cascade-to-the-requirement
  ;; The whole point, end to end: plan, design and requirement move together in
  ;; one command, with three status lines and three renames.
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  ;;
  ;; File property (DES-0051 D9 part C), and the only one of these that is: the
  ;; thing in the way is a plain file, and a directory that cannot be created
  ;; is a refusal no store without directories has. The property being tested
  ;; is the protocol's -- DOCSTORE-APPLY-BATCH refuses the whole batch before
  ;; writing -- and this is the cheapest way to make a store refuse one entry.
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

(test an-edit-the-monitor-has-not-seen-is-kept-and-the-status-written-into-it
  ;; DES-0051 D2 closes a window with EXPECTED-VERSION, and the version that
  ;; goes in it has to be the one read at plan time rather than the one the
  ;; index holds. A developer saving a document the monitor has not polled yet
  ;; is the ordinary case: the index is behind, the store is not, and DEC-0001
  ;; settles it in the file's favour. Comparing against the indexed version
  ;; would refuse this write and hand back a conflict about an edit the caller
  ;; never made.
  (with-document-trees (root)
    (write-document root "docs/bugs/BUG-0001.yaml"
                    (format nil "id: BUG-0001~%title: a defect~%status: open~%"))
    (with-indexed-tree (repository root)
      ;; Saved after the index read it, and no poll in between.
      (write-document root "docs/bugs/BUG-0001.yaml"
                      (format nil "id: BUG-0001~%title: a defect, described at last~%~
status: open~%"))
      (let ((report (set-document-status repository "BUG-0001" "closed")))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (let ((text (document-text root "docs/bugs/completed/BUG-0001.yaml")))
          (is (search "described at last" text)
              "the unseen edit was overwritten with what the index remembered")
          (is (search (format nil "~%status: closed~%") text)
              "the status was not written into the text that was there"))))))

(test a-partial-apply-reports-what-landed-and-the-same-command-finishes-the-rest
  ;; DES-0051 D4, the :PLANNED guarantee's second half. Planning finds every
  ;; refusal before a byte is written; what it cannot rule out is a failure
  ;; once writing has begun, and a file store cannot be atomic across files --
  ;; Loom does not commit, and `complete' leaves the tree dirty on purpose.
  ;;
  ;; File property (DES-0051 D9 part C): the failure is a rename out of a
  ;; directory that is not writable, which is the only cheap way to make a
  ;; write fail after it has been planned. The in-memory store is :ATOMIC and
  ;; has nothing that can fail here.
  ;;
  ;; docs/design/completed/ exists before the run, so planning succeeds:
  ;; ENSURE-DIRECTORIES-EXIST has nothing to create and PROBE-WRITABLE opens
  ;; the file itself, which mode 555 on the directory above does not stop. The
  ;; rename does need to write that directory, and that is where it fails.
  (with-document-tree (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '()))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (ensure-directories-exist (merge-pathnames "docs/design/completed/" root))
    (with-indexed-tree (repository root)
      (let ((design-directory (namestring (merge-pathnames "docs/design/" root))))
        (uiop:run-program (list "chmod" "555" design-directory))
        (unwind-protect
             (let ((report (complete-plan repository "PLAN-0001"
                                          :verdicts "DES-0001=implemented")))
               (is-true (getf report :problems) "the failed rename reported nothing")
               (is (search "1 of 2" (first (getf report :problems)))
                   "the problem does not say how much landed: ~a" (getf report :problems))
               (is (= 1 (length (getf report :changed)))
                   "~a landed" (length (getf report :changed)))
               (is (equal "PLAN-0001" (getf (first (getf report :changed)) :doc-id))
                   "the entry that landed is not the one reported")
               (is-true (probe-file (merge-pathnames "docs/plans/completed/PLAN-0001.yaml" root))
                        "the plan did not move")
               (is-true (probe-file (merge-pathnames "docs/design/DES-0001.yaml" root))
                        "the design moved after all"))
          (uiop:run-program (list "chmod" "755" design-directory)))
        ;; The tree is part-way and says so. Finishing it is SET-DOCUMENT-STATUS
        ;; rather than the same `complete' again, and the difference is worth
        ;; keeping: the design's file already declares `implemented', so the
        ;; cascade reads it as already finished and plans no edit for it. The
        ;; primitive plans one anyway, the store sees a status whose placement
        ;; disagrees, and the move is what it writes.
        (let ((report (set-document-status repository "DES-0001" "implemented")))
          (is (null (getf report :problems)) "~a" (getf report :problems))
          (is (= 1 (length (getf report :changed)))
              "a document already declaring its status was left where it was")
          (is-true (probe-file (merge-pathnames "docs/design/completed/DES-0001.yaml" root))
                   "the design is still flat"))))))

(test a-document-whose-file-declares-an-unknown-status-is-reported-not-overwritten
  ;; BUG-0019's shape: `status: fixed' was dropped to NIL by AS-KEYWORD, so the
  ;; index held no status while the file held a word. A document in an unknown
  ;; state is exactly where a human should look.
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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
  (with-document-trees (root)
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

(test checking-a-document-with-no-contents-reads-it-from-the-store
  ;; REQ-0034 lets an agent ask what a document's references resolve to before
  ;; the document is written, which is why CONTENTS overrides what is stored.
  ;; With no CONTENTS the operation has to find the text itself, and DES-0051
  ;; moves where that is: a document the index holds is read through
  ;; DOCSTORE-READ, so the answer no longer depends on there being a file.
  ;;
  ;; The in-memory run is the one that means something. Before this the file
  ;; store answered from disk and the in-memory store answered "no such file,
  ;; and no contents given" about a document it was holding.
  (with-workspace-fixtures (repository)
    (let ((report (check-document-references repository "docs/decisions/DEC-0001.yaml")))
      (is (null (getf report :error))
          "the store holds this document: ~a" (getf report :error))
      (is (equal "DEC-0001" (getf report :document)))
      (is (eq :resolved (reference-status report "alpha"))
          "the one name DEC-0001 affects: ~a" (getf report :references)))))

(test checking-a-path-the-store-does-not-hold-keeps-its-old-answer
  ;; The fallback stays. A path that is neither in the store nor on disk is
  ;; the same refusal it has always been, because reading nothing and being
  ;; handed nothing are one answer: there is no text to check.
  (with-workspace-fixtures (repository)
    (let ((report (check-document-references repository "docs/decisions/DEC-0099.yaml")))
      (is (equal "no such file, and no contents given" (getf report :error))))))

(test a-path-no-analyzer-claims-is-refused-with-a-reason
  ;; A path no analyzer claims produced nothing, and saying so is a different
  ;; answer from reporting a document with no references. Reporting them alike
  ;; would be CON-0001's fabricated fact in the report's own shape.
  ;;
  ;; .rst rather than .txt: REQ-0028 claims .txt, .md and .markdown wherever
  ;; the repository keeps them, and a claimed file really is a document -- one
  ;; with no declared fields, which this operation reports as no references
  ;; rather than as a refusal.
  (with-document-trees (root)
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
  (with-document-trees (root)
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


;;; ------------------------------------------------------------------
;;; A cascade with nothing to decide writes (BUG-0057)
;;; ------------------------------------------------------------------
;;;
;;; Dry run is the default because the command's failure mode is editing files,
;;; and all-or-nothing exists so a cascade cannot be left half applied. Neither
;;; argument reaches a cascade that has no verdict to give: there is nothing to
;;; withhold and nothing that could be left behind, and the behaviour chosen was
;;; the one that never finishes.

(test a-plan-that-refines-nothing-is-finished-rather-than-previewed-forever
  ;; game-server's PLAN-0002, 2026-08-21. `complete' returned `would-set' on
  ;; every run; a verdict offered for the plan itself was refused as not in the
  ;; cascade; `set-status' was the way through, and both the skill and the
  ;; generated CLAUDE.md say "run the transition command" and mean `complete'.
  (with-document-trees (root)
    (write-document root "docs/plans/PLAN-0001.yaml"
                    (format nil "id: PLAN-0001~%title: a plan~%status: draft~%~
body: |~%  STEPS~%~%  1. do the thing.~%"))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001")))
        (is (null (getf report :dry-run))
            "there is no verdict to preview, so this is not a preview")
        (is (null (getf report :problems)) "and nothing to refuse")
        (is-true (getf report :changed) "the plan is finished")
        ;; Read from completed/: a terminal status moves the file, which is the
        ;; same write path SET-DOCUMENT-STATUS uses and the thing a caller was
        ;; reaching for it to do.
        (is (search "status: final"
                    (document-text root "docs/plans/completed/PLAN-0001.yaml"))
            "and the file says so, where a finished plan belongs")))))

(test a-cascade-whose-documents-are-all-finished-already-writes-too
  ;; The commoner shape, and the one a narrow fix for "refines nothing" would
  ;; have missed: the frontier is not empty, every document on it is already
  ;; terminal, and so no verdict is possible here either.
  (with-document-trees (root)
    (write-document root "docs/requirements/REQ-0001.yaml"
                    (requirement-document "REQ-0001" :status "implemented"))
    (write-document root "docs/design/DES-0001.yaml"
                    (design-document "DES-0001" '("REQ-0001") :status "implemented"))
    (write-document root "docs/plans/PLAN-0001.yaml"
                    (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001")))
        (is (null (getf report :dry-run)))
        (is-true (getf report :changed))
        (is (search "status: final"
                    (document-text root "docs/plans/completed/PLAN-0001.yaml")))
        (let ((row (find "DES-0001" (getf report :documents)
                         :key (lambda (r) (getf r :doc-id)) :test #'string=)))
          (is (eq :already-finished (getf row :action))
              "the finished document is reported and left alone"))))))

(test the-walk-passes-through-a-document-that-was-already-finished
  ;; BUG-0065 D1. The walk used to stop at a terminal document on the ground
  ;; that "nothing about it changed, so nothing above it changed because of
  ;; it" -- true of one this cascade finished, false of one finished earlier.
  ;; front-end is the case: DES-0006 closed weeks before PLAN-0004 ran, so
  ;; REQ-0004 above it was reachable from no plan at all and had to be set
  ;; blind with set-status.
  (with-document-trees (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/design/completed/DES-0001.yaml"
                    (design-document "DES-0001" '("REQ-0001") :status "implemented"))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let* ((report (complete-plan repository "PLAN-0001" :verdicts "REQ-0001=implemented"))
             (rows   (getf report :documents))
             (row    (find "DES-0001" rows :key (lambda (r) (getf r :doc-id)) :test #'equal)))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (eq :already-finished (getf row :action))
            "the finished design is still reported as finished")
        (is (find "REQ-0001" rows :key (lambda (r) (getf r :doc-id)) :test #'equal)
            "and the requirement above it is reached rather than invisible")
        (is (search (format nil "~%status: implemented~%")
                    (document-text root "docs/requirements/completed/REQ-0001.yaml")))))))

(test a-decision-in-the-chain-is-in-force-rather-than-awaiting-a-verdict
  ;; BUG-0065 D3, which only exists once D1 is fixed. A decision has a status
  ;; vocabulary with no terminal member, so it is not terminal, and
  ;; FINISHABLE-P already keeps it from blocking -- leaving :AWAITING-VERDICT,
  ;; where the all-or-nothing rule would refuse the whole cascade until the
  ;; caller supplied a verdict for a decision. No verdict would help: none of
  ;; the four is terminal, so the walk would stop having extracted a judgement
  ;; that changed nothing.
  (with-document-trees (root)
    (write-document root "docs/requirements/REQ-0001.yaml" (requirement-document "REQ-0001"))
    (write-document root "docs/decisions/DEC-0001.yaml" (decision-document "DEC-0001" '("REQ-0001")))
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("DEC-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let* ((report (complete-plan repository "PLAN-0001"
                                    :verdicts "DES-0001=implemented REQ-0001=implemented"))
             (rows   (getf report :documents))
             (row    (find "DEC-0001" rows :key (lambda (r) (getf r :doc-id)) :test #'equal)))
        (is (null (getf report :problems)) "~a" (getf report :problems))
        (is (eq :in-force (getf row :action))
            "the decision is reported in force, not awaiting a verdict")
        (is (null (getf row :verdict)) "and no verdict was applied to it")
        (is (find "REQ-0001" rows :key (lambda (r) (getf r :doc-id)) :test #'equal)
            "the requirement beyond it is reached")))))

(test a-cascade-with-something-to-decide-is-still-a-dry-run
  ;; The control, and the property the change must not cost. DES-0019 D5's
  ;; default is right wherever there is a verdict to withhold, and an agent that
  ;; runs `complete' and walks away must still have done nothing.
  (with-document-trees (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let ((report (complete-plan repository "PLAN-0001")))
        (is-true (getf report :dry-run))
        (is (null (getf report :changed)) "nothing written")
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))))))
  ;; A blocked cascade is not a shape with nothing to decide (BUG-0069).
  ;; DES-0001 cannot be decided while PLAN-0002 still refines it, and the
  ;; preview is how the caller learns that. Finishing PLAN-0001 here would
  ;; leave a final plan over a draft design. `set-status' is the explicit way
  ;; to finish the plan alone.
  (with-document-trees (root)
    (write-document root "docs/design/DES-0001.yaml" (design-document "DES-0001" '("REQ-0001")))
    (write-document root "docs/plans/PLAN-0001.yaml" (plan-document "PLAN-0001" '("DES-0001")))
    (write-document root "docs/plans/PLAN-0002.yaml" (plan-document "PLAN-0002" '("DES-0001")))
    (with-indexed-tree (repository root)
      (let* ((report (complete-plan repository "PLAN-0001"))
             (rows (getf report :documents))
             (row (find "DES-0001" rows
                        :key (lambda (r) (getf r :doc-id)) :test #'string=))
             (plan-row (find "PLAN-0001" rows
                             :key (lambda (r) (getf r :doc-id)) :test #'string=)))
        (is (eq :blocked (getf row :action)) "DES-0001 is still refined by PLAN-0002")
        (is-true (getf report :dry-run) "a blocked cascade is previewed")
        (is (null (getf report :changed)) "nothing is written")
        (is (eq :would-set (getf plan-row :action)) "the plan's row says what would happen")
        (is (search "status: draft" (document-text root "docs/plans/PLAN-0001.yaml"))
            "the plan is still a draft")
        (is (search "status: draft" (document-text root "docs/design/DES-0001.yaml"))
            "and so is the blocked design")))))
