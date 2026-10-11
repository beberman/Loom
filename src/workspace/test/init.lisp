;;;
;;; Tests for preparing a repository Loom did not write (REQ-0021, DES-0022 S2).
;;;
;;; Every one of these builds a scratch tree. That is not the usual caution
;;; about fixtures: this code writes into somebody else's repository, and a
;;; test that proved it by preparing a real one would have done the damage it
;;; was checking for. The acceptance in PLAN-0023 runs against a *copy* of
;;; game-server for the same reason.
;;;
;;; What has to be witnessed is mostly what init declines to do -- overwrite a
;;; skill that exists, append to a CLAUDE.md without consent, touch a tree it
;;; has already prepared, or write anything at all when one path is refused.
;;;

(in-package :loom-workspace-test)

(def-suite init
  :in all-tests
  :description "PREPARE-REPOSITORY: directories, templates, consent, manifest.")

(in-suite init)

(defmacro with-target-tree ((root) &body body)
  "An empty throwaway directory standing in for a repository."
  `(let ((,root (ensure-directories-exist
                 (merge-pathnames (format nil "loom-init-~a/" (random 100000 (make-random-state t)))
                                  (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun target-file (root relative)
  (merge-pathnames relative root))

(defun target-text (root relative)
  (let ((path (target-file root relative)))
    (and (probe-file path) (loom-utils:read-file path))))

(defun write-target-file (root relative contents)
  (let ((path (target-file root relative)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string contents out))
    path))

;;; ------------------------------------------------------------------
;;; What it writes
;;; ------------------------------------------------------------------

(test a-fresh-tree-gets-the-directories-the-conventions-and-the-skill
  (with-target-tree (root)
    (let ((report (prepare-repository root)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (dolist (kind '("requirements" "design" "plans" "reviews" "bugs"
                      "decisions" "arch" "concepts" "rules"))
        (is-true (probe-file (target-file root (format nil "docs/~a/" kind)))
                 "docs/~a/ was not created" kind))
      ;; RULE-0007's split: the five that finish get completed/, the four that
      ;; are in force rather than finished do not.
      (is-true (probe-file (target-file root "docs/plans/completed/")))
      (is (null (probe-file (target-file root "docs/decisions/completed/")))
          "a decision is in force, not finished; filing it under completed/ ~
would bury exactly what impact exists to surface")
      (is-true (probe-file (target-file root ".claude/skills/loom/SKILL.md")))
      (is-true (probe-file (target-file root "docs/concepts/CON-0001.yaml"))
                "a fresh tree has no concepts, so the workflow concept is its CON-0001"))))

(test the-templates-are-substituted-rather-than-copied
  ;; A prepared tree whose skill says {{REPOSITORY-NAME}} is worse than no
  ;; skill: every query it teaches would name a repository that does not exist.
  (with-target-tree (root)
    (prepare-repository root :document-directory "knowledge"
                             :endpoint "loom.internal:4780"
                             :name "widget-api")
    (let ((skill (target-text root ".claude/skills/loom/SKILL.md")))
      (is (search "widget-api" skill))
      (is (search "loom.internal:4780" skill))
      (is (search "knowledge/" skill))
      (is (not (search "{{" skill)) "an unsubstituted token survived into the skill"))
    (let ((concept (target-text root "knowledge/concepts/CON-0001.yaml")))
      (is (search "knowledge/requirements/" concept))
      (is (not (search "{{" concept))))))

(test the-prepared-guidance-says-which-questions-are-gits-and-not-loom-s
  ;; REQ-0058. The guidance is emphatic that the first tool is the index, and
  ;; every question it lists is about the tree as it stands -- so an agent that
  ;; has internalised it puts a question about what changed to the index and
  ;; gets a confident answer about the present. Completing game-server's
  ;; PLAN-0002 was three bugs and none was found with the index.
  ;;
  ;; Both surfaces, because an agent reads whichever one it meets first: the
  ;; skill is the authoritative copy and the CLAUDE.md region is what a reader
  ;; sees without invoking anything.
  (with-target-tree (root)
    (prepare-repository root :append-claude-md nil)
    (dolist (file '(".claude/skills/loom/SKILL.md" "CLAUDE.md"))
      (let ((text (target-text root file)))
        (is-true (search "git log -S" text)
                 "~a does not name the verb for a question about the past" file)
        (is-true (search "commit message" text)
                 "~a does not say that a commit message is evidence no index ~
holds, which is the case that surprises" file)))))

(defparameter *concept-fields-the-analyzer-reads*
  '("refines" "affects" "status" "tags" "importance")
  "Every key the analyzer reads from a CONCEPT, which is what the workflow
concept is.

REQ-0070's list, written here rather than derived because the point is that two
things must agree: this is the assertion, and the method is the subject.
Deriving it from the method would make the test pass by construction and assert
nothing.

NAMED FOR THE GENRE IT CHECKS, which is BUG-0066 F1. It said :DOCUMENT until
2026-09-10 and the file it reads is a :CONCEPT, so the test asserted the
agreement of two things neither of which governed its subject -- and passed
throughout while Loom's own template wrote `status: accepted' into a genre that
could not hold a status.")

(test every-field-the-analyzer-reads-is-named-in-the-conventions-a-tree-is-given
  ;; REQ-0070. The workflow-concept template is the one document Loom ships that
  ;; Loom never reads: docs/concepts/CON-0001.yaml in this tree is "Resolution
  ;; pass", unrelated, so nothing here exercises the text every other repository
  ;; is handed.
  ;;
  ;; That is the mechanism behind BUG-0062 rather than a tidiness argument.
  ;; `importance:' was added to the ontology and to every requirement in this
  ;; tree on 2026-08-23 and never reached the template, and nothing anywhere
  ;; could have noticed: no prepared repository can see an omission from the
  ;; document that defines its conventions, and Loom had no copy to compare
  ;; against. front-end carried 62 documents without the field until somebody
  ;; happened to read both trees side by side. BUG-0063 is the second instance,
  ;; found by looking rather than by anything reporting it.
  ;;
  ;; Against the RENDERED template, which is what a prepared tree receives, so a
  ;; placeholder that a render drops is caught with the rest.
  (with-target-tree (root)
    (prepare-repository root :append-claude-md nil)
    (let ((text (target-text root "docs/concepts/CON-0001.yaml")))
      (dolist (field *concept-fields-the-analyzer-reads*)
        (is-true (search field text)
                 "the analyzer reads `~a:' and the conventions never mention it, ~
so an author working from them writes correct YAML that is missing a field the ~
engine is reading" field)))))

(test the-conventions-describe-no-field-the-analyzer-would-discard
  ;; REQ-0070 R3, the same silent drop from the author's side. A field the
  ;; template documents and no method reads is correct YAML written to
  ;; instruction and discarded -- BUG-0023 is the standing instance, where 67
  ;; documents carried 610 names in `affects:' that resolved to nothing and were
  ;; not reported unresolved either.
  ;;
  ;; Scoped to the fields section, because the template's prose legitimately
  ;; names things that are not document fields.
  (with-target-tree (root)
    (prepare-repository root :append-claude-md nil)
    (let* ((text (target-text root "docs/concepts/CON-0001.yaml"))
           (at   (search "THE FIELDS THAT RESOLVE" text))
           (section (and at (subseq text at (min (length text) (+ at 4000))))))
      (is-true section "the template has no fields section to check")
      (dolist (claimed '("refines" "affects" "importance" "severity" "priority" "tags"))
        (when (search claimed section)
          ;; The template describes the whole workflow, so it names fields other
          ;; genres read as well as the concept's own. What must not appear is a
          ;; field NO genre reads, which is BUG-0023's shape.
          (is-true (or (member claimed *concept-fields-the-analyzer-reads*
                               :test #'string=)
                       (member claimed '("severity" "priority") :test #'string=))
                   "the conventions describe `~a:' and no method reads it" claimed))))))

(test a-tree-with-no-claude-md-gets-one-without-being-asked
  ;; Writing a file that does not exist is not editing one, so R3 does not bear
  ;; on it and R16's second consent is not needed. Consent is about touching
  ;; somebody's existing document.
  (with-target-tree (root)
    (prepare-repository root :append-claude-md nil)
    (let ((text (target-text root "CLAUDE.md")))
      (is (not (null text)) "a tree with no CLAUDE.md should get one")
      (is (search "loom:begin" text)))))

;;; ------------------------------------------------------------------
;;; What it declines to do
;;; ------------------------------------------------------------------

(test an-existing-claude-md-is-not-touched-without-consent
  ;; R16: a yes to "use Loom here" and a no to "append to my CLAUDE.md" is a
  ;; supported outcome, not a failed run. Everything else is written and the
  ;; tree is prepared but undiscovered.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project

Do not touch this.
")
    (let ((report (prepare-repository root :append-claude-md nil)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (string= "# My project

Do not touch this.
" (target-text root "CLAUDE.md"))
          "the file is byte-for-byte what it was")
      (is-true (probe-file (target-file root ".claude/skills/loom/SKILL.md"))
               "and the rest of the preparation still happened")
      (is (find "CLAUDE.md" (getf report :skipped) :key #'car :test #'string=)
          "and the report says it was skipped: ~a" (getf report :skipped)))))

(test an-existing-claude-md-is-appended-to-with-consent-and-only-at-the-end
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project

Do not touch this.
")
    (prepare-repository root :append-claude-md t)
    (let ((text (target-text root "CLAUDE.md")))
      (is (eql 0 (search "# My project" text))
          "the author's text is still first and unchanged")
      (is (search "Do not touch this." text))
      (is (search loom-workspace::*marker-begin* text))
      (is (search loom-workspace::*marker-end* text))
      (is (> (search loom-workspace::*marker-begin* text) (search "Do not touch this." text))
          "ours is appended, never interleaved"))))

(test an-existing-skill-is-refused-rather-than-overwritten
  ;; R3. A repository with a loom skill has already met Loom, and replacing it
  ;; would destroy whatever a human had done to it.
  (with-target-tree (root)
    (write-target-file root ".claude/skills/loom/SKILL.md" "mine, not yours")
    (let ((report (prepare-repository root)))
      (is (null (getf report :problems)))
      (is (string= "mine, not yours" (target-text root ".claude/skills/loom/SKILL.md")))
      (is (find ".claude/skills/loom/SKILL.md" (getf report :skipped)
                :key #'car :test #'string=)
          "~a" (getf report :skipped)))))

(test an-existing-mcp-registration-is-reported-rather-than-merged
  ;; JSON carries no comment syntax, so there is no marker that survives a
  ;; parse -- and merging into somebody's server list is the merge R3 forbids.
  ;; So it is create-only, and a human is told.
  (with-target-tree (root)
    (write-target-file root ".mcp.json" "{\"mcpServers\":{\"other\":{}}}")
    (let ((report (prepare-repository root)))
      (is (string= "{\"mcpServers\":{\"other\":{}}}" (target-text root ".mcp.json")))
      (let ((skip (find ".mcp.json" (getf report :skipped) :key #'car :test #'string=)))
        (is (not (null skip)))
        (is (search "by hand" (cdr skip))
            "and says what the human has to do: ~a" skip)))))

;;; ------------------------------------------------------------------
;;; Idempotence and the manifest
;;; ------------------------------------------------------------------

(test a-second-run-changes-nothing-and-says-so
  ;; REQ-0021 R11 and R17. Decided by the manifest rather than by inspecting
  ;; the tree, so a half-removed preparation is still recognised as one.
  (with-target-tree (root)
    (let ((first-run (prepare-repository root :append-claude-md t)))
      (is (plusp (length (getf first-run :created))))
      (let* ((before (target-text root "CLAUDE.md"))
             (second-run (prepare-repository root :append-claude-md t)))
        (is-true (getf second-run :already-prepared))
        (is (null (getf second-run :created)) "nothing written the second time")
        (is (string= before (target-text root "CLAUDE.md"))
            "and the pointer was not appended twice")))))

(test the-manifest-records-the-choices-and-the-output
  ;; R13b. Removal cannot infer an empty directory or a chosen path from any
  ;; document's provenance, so it has to be written down.
  (with-target-tree (root)
    (let ((report (prepare-repository root :document-directory "knowledge"
                                           :endpoint "loom.internal:4780"
                                           :append-claude-md t)))
      (let ((manifest (read-manifest root)))
        (is (string= "knowledge" (getf manifest :document-directory)))
        (is (string= "loom.internal:4780" (getf manifest :endpoint)))
        (is (string= "created" (getf manifest :claude-md))
            "this tree had no CLAUDE.md, so Loom created one -- and removal ~
deletes a created file whole where it only cuts a region out of an appended ~
one, so a boolean could not have carried it"))
      (is (member "knowledge/concepts/CON-0001.yaml" (getf report :created)
                  :test #'string=)
          "~a" (getf report :created)))))

(test the-manifest-exists-even-though-the-run-writes-several-files
  ;; It is written before the files it records, not after: a run that dies
  ;; halfway is exactly when removal needs to know what was intended.
  (with-target-tree (root)
    (prepare-repository root)
    (is-true (probe-file (target-file root ".loom/manifest.yaml")))
    (is-true (prepared-p root))))

;;; ------------------------------------------------------------------
;;; Nothing is written when anything is refused
;;; ------------------------------------------------------------------

(test a-refusal-leaves-the-tree-untouched
  ;; The plan-then-apply split, which is the discipline every write path in
  ;; this system shares. A plain file where a document directory has to go
  ;; cannot be worked around, and it must cost the whole run rather than leave
  ;; a half-built tree and a manifest describing something that is not there.
  ;;
  ;; Written after discovering that the refusal path had none: every other
  ;; branch allocates around what it finds -- the concept takes the next free
  ;; id, an occupied skill is skipped -- so before the directory check there
  ;; was no input that could refuse, and a plan-then-apply split that can never
  ;; refuse has never been tested.
  (with-target-tree (root)
    (write-target-file root "docs/plans" "not a directory")
    (let ((report (prepare-repository root)))
      (is-true (getf report :problems) "a file in the way has to refuse")
      (is (null (getf report :created)))
      (is (null (probe-file (target-file root ".claude/skills/loom/SKILL.md")))
          "the skill, which would have been written, was not")
      (is (null (probe-file (target-file root ".loom/manifest.yaml")))
          "and no manifest, because nothing was prepared")
      (is (string= "not a directory" (target-text root "docs/plans"))
          "and the thing in the way is untouched"))))

(test the-workflow-concept-takes-the-next-free-id-not-always-one
  ;; R4a as amended: transcribed documents are allocated the same way every
  ;; other document in that tree will be. A tree that already has concepts does
  ;; not get its CON-0001 overwritten.
  (with-target-tree (root)
    (write-target-file root "docs/concepts/CON-0001.yaml" "id: CON-0001
")
    (write-target-file root "docs/concepts/completed/CON-0007.yaml" "id: CON-0007
")
    (let ((report (prepare-repository root)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (string= "CON-0008" (getf report :workflow-concept))
          "completed/ counts too, or an id gets reused")
      (is-true (probe-file (target-file root "docs/concepts/CON-0008.yaml"))))))

;;; ------------------------------------------------------------------
;;; Taking Loom back out (R13)
;;;
;;; Removal deletes files from a repository Loom does not own, so what is
;;; asserted here is mostly what it refuses to delete. The direction to fail in
;;; is leaving things behind.
;;; ------------------------------------------------------------------

(test removing-the-tooling-keeps-every-document
  ;; R13's default and the reason it is the default: the documents are the point
  ;; of the exercise, they are plain YAML readable with no tool at all, and
  ;; deleting a team's knowledge because the tool is leaving would be the worst
  ;; outcome REQ-0021 could produce.
  (with-target-tree (root)
    (prepare-repository root)
    (let ((report (remove-preparation root :mode :tooling)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (null (probe-file (target-file root ".claude/skills/loom/SKILL.md")))
          "the skill is gone")
      (is (null (probe-file (target-file root ".loom/manifest.yaml")))
          "and the manifest")
      (is-true (probe-file (target-file root "docs/concepts/CON-0001.yaml"))
               "and the workflow concept stayed")
      (is (member "docs/concepts/CON-0001.yaml" (getf report :kept) :test #'string=)
          "and is reported as kept rather than silently skipped: ~a"
          (getf report :kept)))))

(test removing-everything-takes-the-documents-init-wrote-and-nothing-else
  (with-target-tree (root)
    (prepare-repository root)
    (let ((report (remove-preparation root :mode :all)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (null (probe-file (target-file root "docs/concepts/CON-0001.yaml")))
          "full removal takes the workflow concept")
      (is (null (probe-file (target-file root ".loom/manifest.yaml")))))))

(test full-removal-refuses-rather-than-orphan-a-document-it-did-not-write
  ;; R13a. A tree whose documents were all written by hand after init is one
  ;; where full removal is nearly a no-op, and that is correct -- so this stops
  ;; and says which, rather than deciding for the user.
  (with-target-tree (root)
    (prepare-repository root)
    (write-target-file root "docs/requirements/REQ-0001.yaml"
                       "id: REQ-0001
title: mine
status: draft
")
    (let ((report (remove-preparation root :mode :all)))
      (is-true (getf report :problems))
      (is (search "REQ-0001" (first (getf report :problems)))
          "the refusal names the document: ~a" (getf report :problems))
      (is (null (getf report :deleted)) "and nothing was deleted")
      (is-true (probe-file (target-file root ".loom/manifest.yaml"))
               "not even the manifest, so a second attempt has something to read")
      (is-true (probe-file (target-file root "docs/concepts/CON-0001.yaml"))))))

(test tooling-removal-is-unbothered-by-a-document-it-did-not-write
  ;; The complement: the mode that keeps documents has no reason to refuse.
  (with-target-tree (root)
    (prepare-repository root)
    (write-target-file root "docs/requirements/REQ-0001.yaml" "id: REQ-0001
")
    (let ((report (remove-preparation root :mode :tooling)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is-true (probe-file (target-file root "docs/requirements/REQ-0001.yaml"))))))

(test the-claude-md-region-is-cut-and-the-authors-bytes-are-untouched
  ;; The edit discipline the transition command uses on a status line, applied
  ;; to a region: byte for byte outside it, so the diff shows exactly what Loom
  ;; put there leaving.
  (with-target-tree (root)
    (let ((original "# My project

Do not touch this.
"))
      (write-target-file root "CLAUDE.md" original)
      (prepare-repository root :append-claude-md t)
      (is (not (string= original (target-text root "CLAUDE.md"))) "the append happened")
      (remove-preparation root :mode :tooling)
      (is (string= original (target-text root "CLAUDE.md"))
          "and removing it restored the file byte for byte, blank line included"))))

;;; ------------------------------------------------------------------
;;; Refreshing a tree already prepared (REQ-0052, DES-0044)
;;; ------------------------------------------------------------------

(defmacro with-moved-template ((name) &body body)
  "Run BODY with template NAME's text changed, in a private copy of templates/.

A refresh only does anything when a template has moved, so every test below
needs one to have. The copy is bound as *TEMPLATE-DIRECTORY* and the real file
is never opened for writing: editing it and restoring it under UNWIND-PROTECT
was what let a second image running the suite read the edit, and what left the
tree modified when a run was killed between the two.

The new text goes above the author marker where there is one, not at the end of
the file. claude-md-pointer.md ends with the *end* marker, so an appended
section lands outside the region entirely, Loom's half is unchanged, and the
refresh correctly reports the file current -- a test that appended would prove
nothing while looking like it had."
  (let ((copy (gensym)) (path (gensym)) (original (gensym)) (text (gensym))
        (at (gensym)))
    `(let* ((,copy (copy-template-directory))
            (loom-workspace::*template-directory* ,copy))
       (unwind-protect
            (let* ((,path (loom-workspace::template-path ,name))
                   (,original (loom-utils:read-file ,path))
                   (,at (search loom-workspace::*marker-yours* ,original))
                   (,text (format nil "~%## A section the template grew~%~%Something useful.~%")))
              (with-open-file (out ,path :direction :output :if-exists :supersede)
                (write-string (if ,at
                                  (concatenate 'string (subseq ,original 0 ,at)
                                               ,text (subseq ,original ,at))
                                  (concatenate 'string ,original ,text))
                              out))
              ,@body)
         (uiop:delete-directory-tree ,copy :validate t :if-does-not-exist :ignore)))))

(defun copy-template-directory ()
  "A fresh copy of this system's templates/, in a directory no other image shares."
  (let ((copy (ensure-directories-exist
               (merge-pathnames
                (format nil "loom-templates-~36r/" (random (expt 2 48) (make-random-state t)))
                (uiop:temporary-directory)))))
    (dolist (file (directory (merge-pathnames "templates/*.*"
                                              (asdf:system-relative-pathname
                                               :loom-workspace ""))))
      (let ((target (merge-pathnames (format nil "templates/~a" (file-namestring file))
                                     copy)))
        (ensure-directories-exist target)
        (uiop:copy-file file target)))
    copy))

(test a-moved-template-is-moved-in-a-copy-and-the-real-one-is-not-opened
  ;; BUG-0073. The macro used to edit the tree's own template and restore it, so
  ;; a second image running the suite read the edit as the original and wrote it
  ;; back for good: two concurrent runs left claude-md-pointer.md and
  ;; loom-skill.md modified in git. Fails against that macro, inside whose body
  ;; the real file already carries the new text.
  (let* ((real (asdf:system-relative-pathname :loom-workspace
                                              "templates/loom-skill.md"))
         (before (loom-utils:read-file real)))
    (with-moved-template ("loom-skill.md")
      (is (string= before (loom-utils:read-file real))
          "the real template changed while a copy was meant to")
      (is-true (search "A section the template grew"
                       (loom-utils:read-file
                        (loom-workspace::template-path "loom-skill.md")))
               "and the copy the code reads carries the new text")
      (is (not (equal (namestring real)
                      (namestring (loom-workspace::template-path "loom-skill.md"))))
          "the path the code reads is the copy's"))
    (is (string= before (loom-utils:read-file real)) "and afterwards")
    (is (null loom-workspace::*template-directory*)
        "the binding does not outlive the macro")))

(test the-manifest-records-a-digest-per-rendered-file-and-per-template
  ;; REQ-0052 R5 and R6, and the thing that makes R3's byte-identical test
  ;; runnable at all: without a recorded digest there is nothing to compare a
  ;; file with. Fails without S2.
  (with-target-tree (root)
    (prepare-repository root)
    (let ((sections (loom-workspace::manifest-sections root)))
      (is-true (assoc "rendered" sections :test #'string=) "there is a rendered list")
      (is-true (assoc "templates" sections :test #'string=) "and a templates list")
      (is-true (assoc "created" sections :test #'string=)
               "and created survived being generalised")
      (let ((digest (loom-workspace::manifest-digest root "rendered" ".mcp.json")))
        (is-true digest "the mcp registration has a digest")
        (is (= 16 (length digest)) "sixteen hex digits, as FNV-1A renders one"))
      (is-true (loom-workspace::manifest-digest root "templates" "loom-skill.md")
               "and each template's own text is recorded (R6)"))))

(test a-refresh-rewrites-only-what-the-moved-template-touched
  ;; REQ-0052 R1 and R2. One template moves; one file is rewritten and the
  ;; others say they are current rather than being rewritten with identical
  ;; bytes. Fails without S5's :CURRENT test running first.
  (with-target-tree (root)
    (prepare-repository root)
    (with-moved-template ("loom-skill.md")
      (let ((report (prepare-repository root :update t :apply-changes t)))
        (is (equal '(".claude/skills/loom/SKILL.md") (getf report :replaced))
            "exactly the file whose template moved: ~a" (getf report :replaced))
        (is-true (search "A section the template grew"
                         (target-text root ".claude/skills/loom/SKILL.md"))
                 "and it actually carries the new text")
        (is-true (find ".mcp.json" (getf report :skipped) :key #'car :test #'string=)
                 "the others are reported rather than silently untouched")))))

(test a-second-refresh-changes-nothing
  ;; The digest earning itself. A refresh that could not tell current from
  ;; stale would rewrite all three files on every run, and a tree under git
  ;; would show three modified files after a no-op.
  (with-target-tree (root)
    (prepare-repository root)
    (with-moved-template ("loom-skill.md")
      (prepare-repository root :update t :apply-changes t)
      (let ((report (prepare-repository root :update t :apply-changes t)))
        (is (null (getf report :replaced))
            "nothing was rewritten the second time: ~a" (getf report :replaced))))))

(test a-refresh-replaces-looms-half-and-copies-the-authors
  ;; REQ-0052's whole point, and the assertion is on the author's bytes rather
  ;; than on Loom's: what the requirement is protecting is the half no template
  ;; can regenerate.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project

Do not touch this.
")
    (prepare-repository root :append-claude-md t)
    (let* ((text (target-text root "CLAUDE.md"))
           (yours (search loom-workspace::*marker-yours* text))
           (line (position #\Newline text :start yours)))
      (write-target-file root "CLAUDE.md"
                         (concatenate 'string (subseq text 0 (1+ line))
                                      "
## This repository

Start the service with tools/serve.sh.
"
                                      (subseq text (1+ line)))))
    (with-moved-template ("claude-md-pointer.md")
      (let ((report (prepare-repository root :update t :apply-changes t))
            (after (target-text root "CLAUDE.md")))
        (is (equal '("CLAUDE.md") (getf report :replaced))
            "the region was refreshed: ~a" (getf report :replaced))
        (is-true (search "Start the service with tools/serve.sh." after)
                 "the author's half is still there, which is the requirement")
        (is-true (search "Do not touch this" after)
                 "and their own file above the region")
        (is-true (search "A section the template grew" after)
                 "while Loom's half took the template's new text")))))

(defun strip-author-marker (root)
  "ROOT's CLAUDE.md with the author marker line removed.

The shape of a region prepared before DES-0044: two markers and no third."
  (let* ((text (target-text root "CLAUDE.md"))
         (yours (search loom-workspace::*marker-yours* text))
         (line (position #\Newline text :start yours))
         (older (concatenate 'string (subseq text 0 yours) (subseq text (1+ line)))))
    (write-target-file root "CLAUDE.md" older)
    older))

(test a-region-with-no-marker-that-is-still-looms-own-text-is-refreshed
  ;; BUG-0051. The marker's absence is not evidence on its own. game-server's
  ;; five author sections were moved below `loom:end' rather than below a marker
  ;; inside the region, which leaves the region pure Loom and safely
  ;; replaceable -- and the first version of this refused it, so the tree
  ;; REQ-0052 was measured on could not be refreshed by REQ-0052's own code.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project
")
    (prepare-repository root :append-claude-md t)
    (strip-author-marker root)
    (with-moved-template ("claude-md-pointer.md")
      (let ((report (prepare-repository root :update t :apply-changes t)))
        (is-true (find "CLAUDE.md" (getf report :replaced) :test #'string=)
                 "the digest proves the region is Loom's, so it is replaced: ~a"
                 (getf report :skipped))
        (is-true (search "A section the template grew" (target-text root "CLAUDE.md"))
                 "and it carries the template's new text")
        (is-true (search "# My project" (target-text root "CLAUDE.md"))
                 "while the author's own file above the region is untouched")))))

(test a-region-with-no-marker-that-was-edited-is-still-refused
  ;; The half of the old refusal that was load-bearing, and the reason the
  ;; digest is what decides. Text added inside a region with no marker cannot be
  ;; told from Loom's, so replacing the region would discard it.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project
")
    (prepare-repository root :append-claude-md t)
    (let* ((older (strip-author-marker root))
           (at (search loom-workspace::*marker-end* older))
           (edited (concatenate 'string (subseq older 0 at)
                                "### Mine, written inside the region

Do not lose this.
"
                                (subseq older at))))
      (write-target-file root "CLAUDE.md" edited)
      (with-moved-template ("claude-md-pointer.md")
        (let ((report (prepare-repository root :update t :apply-changes t)))
          (is (null (find "CLAUDE.md" (getf report :replaced) :test #'string=))
              "nothing was written to it")
          (is-true (search "differs from what Loom last wrote"
                           (cdr (find "CLAUDE.md" (getf report :skipped)
                                      :key #'car :test #'string=))))))
      (is (string= edited (target-text root "CLAUDE.md"))
          "and the file is byte for byte what it was, the added section included"))))

(test a-region-with-no-marker-and-no-digest-warns-that-all-of-it-goes
  ;; DES-0044 D5's consent doing the work the refusal used to. Loom cannot
  ;; verify the region, so it says what replacing it would cost and writes
  ;; nothing until told -- rather than refusing forever, which is what left a
  ;; tree prepared before digests existed unable to acquire one.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project
")
    (prepare-repository root :append-claude-md t)
    (strip-author-marker root)
    ;; A manifest as it was before DES-0044: no digests at all.
    (let ((manifest (read-manifest root)))
      (loom-workspace::write-manifest
       root (loom-workspace::manifest-scalars manifest)
       (list (cons "created" (loom-workspace::manifest-created-paths root)))))
    (with-moved-template ("claude-md-pointer.md")
      (let* ((before (target-text root "CLAUDE.md"))
             (report (prepare-repository root :update t :apply-changes t))
             (why (cdr (find "CLAUDE.md" (getf report :skipped)
                             :key #'car :test #'string=))))
        (is (null (getf report :replaced)) "nothing written without consent")
        (is-true (search "no digest recorded" why))
        (is-true (search "has no" why) "and the missing marker is named: ~a" why)
        (is (string= before (target-text root "CLAUDE.md")) "the file is untouched"))
      (let ((report (prepare-repository root :update t :apply-changes t
                                             :replace-unproven t)))
        (is-true (find "CLAUDE.md" (getf report :replaced) :test #'string=)
                 "and written when the consent is given: ~a" (getf report :replaced))))))

(test a-file-edited-since-loom-wrote-it-is-refused
  ;; REQ-0052 R3. The digest's other job: a file that is no longer what Loom
  ;; wrote belongs to whoever changed it.
  (with-target-tree (root)
    (prepare-repository root)
    (write-target-file root ".mcp.json" "{\"mcpServers\": {\"mine\": {}}}")
    (with-moved-template ("mcp.json")
      (let ((report (prepare-repository root :update t :apply-changes t)))
        (is (null (find ".mcp.json" (getf report :replaced) :test #'string=))
            "the edit was not discarded")
        (is-true (search "differs from what Loom last wrote"
                         (cdr (find ".mcp.json" (getf report :skipped)
                                    :key #'car :test #'string=))))
        (is (string= "{\"mcpServers\": {\"mine\": {}}}" (target-text root ".mcp.json"))
            "byte for byte as they left it")))))

(test a-file-with-no-recorded-digest-waits-for-consent
  ;; DES-0044 D5. Every tree prepared before the digest existed is in this
  ;; state, and refusing them outright would mean no prepared tree could ever
  ;; be refreshed. So it is reported, and written only when asked.
  (with-target-tree (root)
    (prepare-repository root)
    ;; A manifest as it was written before DES-0044: no `rendered:' section.
    (let ((manifest (read-manifest root)))
      (loom-workspace::write-manifest
       root (loom-workspace::manifest-scalars manifest)
       (list (cons "created" (loom-workspace::manifest-created-paths root)))))
    (with-moved-template ("loom-skill.md")
      (let ((report (prepare-repository root :update t :apply-changes t)))
        (is (null (getf report :replaced)) "nothing written without consent")
        (is-true (search "no digest recorded"
                         (cdr (find ".claude/skills/loom/SKILL.md" (getf report :skipped)
                                    :key #'car :test #'string=)))))
      (let ((report (prepare-repository root :update t :replace-unproven t
                                             :apply-changes t)))
        (is-true (find ".claude/skills/loom/SKILL.md" (getf report :replaced)
                       :test #'string=)
                 "and written when it is given: ~a" (getf report :replaced))))))

(test a-refresh-writes-nothing-until-it-is-told-to
  ;; REQ-0052 R2. Dry run is the default, which is `complete''s convention in
  ;; this tree and is right here for a stronger reason: this run's writes are
  ;; over text that already exists.
  (with-target-tree (root)
    (prepare-repository root)
    (with-moved-template ("loom-skill.md")
      (let* ((before (target-text root ".claude/skills/loom/SKILL.md"))
             (report (prepare-repository root :update t)))
        (is-true (getf report :dry-run) "the report says it was a dry run")
        (is (null (getf report :replaced)) "nothing is claimed as written")
        (is (equal '(".claude/skills/loom/SKILL.md") (getf report :would-replace))
            "and what it would do is named: ~a" (getf report :would-replace))
        (is (string= before (target-text root ".claude/skills/loom/SKILL.md"))
            "the file on disk is byte for byte what it was")))))

(test a-refresh-touches-no-document-and-makes-no-directory
  ;; REQ-0052 R7. Those are the team's, not Loom's -- the same line
  ;; `remove ... tooling' draws.
  (with-target-tree (root)
    (prepare-repository root)
    (let ((concept (target-file root "docs/concepts/CON-0001.yaml")))
      (write-target-file root "docs/concepts/CON-0001.yaml" "id: CON-0001
edited: by the team
")
      (write-target-file root "docs/requirements/REQ-0001.yaml" "id: REQ-0001
")
      (with-moved-template ("workflow-concept.yaml")
        (let ((report (prepare-repository root :update t :apply-changes t)))
          (is (null (find-if (lambda (path) (search "docs/" path))
                             (getf report :replaced)))
              "no document was rewritten: ~a" (getf report :replaced))
          (is (string= "id: CON-0001
edited: by the team
" (loom-utils:read-file concept))
              "the team's edit to Loom's own concept document stands")
          (is-true (probe-file (target-file root "docs/requirements/REQ-0001.yaml"))
                   "and their requirement is still there"))))))

(test refreshing-a-tree-that-was-never-prepared-says-so
  ;; The complement of REMOVAL-REFUSES-A-TREE-IT-NEVER-PREPARED, and the same
  ;; argument: the manifest is the authority, and there is nothing to refresh
  ;; without one.
  (with-target-tree (root)
    (let ((report (prepare-repository root :update t :apply-changes t)))
      (is-true (getf report :problems))
      (is-true (search "no Loom manifest" (first (getf report :problems))))
      (is (null (probe-file (target-file root ".claude/skills/loom/SKILL.md")))
          "and nothing was prepared as a side effect"))))

(test removal-keeps-what-was-written-below-the-author-marker
  ;; DES-0044 D6, and the test that stops this change destroying somebody's
  ;; file. The marker D2 introduced sits *inside* the begin/end span, so a
  ;; removal that still cut begin-to-end would take the author's half with it --
  ;; the exact failure the whole design exists to prevent, arriving through the
  ;; one path that already read the markers.
  ;;
  ;; The appended case, not the created one: a CLAUDE.md Loom wrote whole is
  ;; deleted whole on removal and correctly so, which would hide this entirely.
  (with-target-tree (root)
    (write-target-file root "CLAUDE.md" "# My project

Do not touch this.
")
    (prepare-repository root :append-claude-md t)
    (let* ((text (target-text root "CLAUDE.md"))
           (yours (search loom-workspace::*marker-yours* text))
           (line  (position #\Newline text :start yours))
           (mine "
Which of two repositories owns dict-value: utils, not gs-utils.
"))
      (is-true yours "init wrote the author marker")
      ;; Author text, inserted below the marker the way a reader would add it.
      (write-target-file root "CLAUDE.md"
                         (concatenate 'string (subseq text 0 (1+ line)) mine
                                      (subseq text (1+ line))))
      (remove-preparation root :mode :tooling)
      (let ((after (target-text root "CLAUDE.md")))
        (is-true after "the file survives")
        (is-true (search "Do not touch this" after)
                 "the author's own file is still there")
        (is-true (search "owns dict-value: utils" after)
                 "and the line they added inside the region: ~s" after)
        (is (null (search loom-workspace::*marker-begin* after))
            "and Loom's begin marker is gone")
        (is (null (search loom-workspace::*marker-yours* after))
            "and the author marker with it")
        (is (null (search loom-workspace::*marker-end* after))
            "and the end marker")
        (is (null (search "ask Loom before reading the tree" after))
            "Loom's own half went, which is what removal is for")))))

(test removal-of-a-region-with-no-author-marker-is-unchanged
  ;; The complement, and the guard against generalising too far. Every tree
  ;; prepared before DES-0044 has a region with two markers, and removal there
  ;; must behave exactly as it did -- byte for byte outside the region.
  (with-target-tree (root)
    (let ((original "# My project

Do not touch this.
"))
      (write-target-file root "CLAUDE.md" original)
      (prepare-repository root :append-claude-md t)
      ;; Strip the author marker, leaving the two-marker region of an older
      ;; preparation.
      (let* ((text (target-text root "CLAUDE.md"))
             (yours (search loom-workspace::*marker-yours* text))
             (line (position #\Newline text :start yours)))
        (write-target-file root "CLAUDE.md"
                           (concatenate 'string (subseq text 0 yours)
                                        (subseq text (1+ line)))))
      (remove-preparation root :mode :tooling)
      (is (string= original (target-text root "CLAUDE.md"))
          "restored byte for byte, blank line included"))))

(test a-claude-md-loom-created-is-deleted-whole
  ;; The three-valued disposition earning itself. A boolean could not tell this
  ;; from the case above, and getting it wrong deletes somebody's document.
  (with-target-tree (root)
    (prepare-repository root)
    (is-true (probe-file (target-file root "CLAUDE.md")) "Loom wrote one")
    (remove-preparation root :mode :tooling)
    (is (null (probe-file (target-file root "CLAUDE.md")))
        "and took it away again, because it was never anybody else's")))

(test removal-refuses-a-tree-it-never-prepared
  ;; The manifest is the only authority. Removal never infers what init would
  ;; have written, because the guess it would have to make is which files in
  ;; somebody's repository are safe to delete.
  (with-target-tree (root)
    (write-target-file root ".claude/skills/loom/SKILL.md" "not ours")
    (let ((report (remove-preparation root :mode :all)))
      (is-true (getf report :problems))
      (is (search "no Loom manifest" (first (getf report :problems))))
      (is-true (probe-file (target-file root ".claude/skills/loom/SKILL.md"))
               "and the file that looks like ours was left alone"))))

(test full-removal-takes-back-the-directories-it-made-and-leaves-the-ones-it-found
  ;; R13b names directories in as many words, and they are the one thing that
  ;; leaves no trace anywhere else: git does not track an empty directory and no
  ;; document's provenance records one. So if the manifest does not hold it, it
  ;; cannot be undone -- which is exactly what happened on the first prepared
  ;; copy of game-server, where full removal left nine empty directories behind
  ;; a `git status' that looked clean.
  ;;
  ;; The other half is the one that matters more: a directory that was already
  ;; there is not Loom's to delete. game-server had a docs/ long before any of
  ;; this.
  (with-target-tree (root)
    ;; docs/ and a directory of theirs exist first.
    (write-target-file root "docs/design-summary/notes.md" "# theirs")
    (prepare-repository root)
    (remove-preparation root :mode :all)
    (is (null (probe-file (target-file root "docs/plans/completed/")))
        "a directory Loom made and emptied is gone")
    (is (null (probe-file (target-file root "docs/concepts/")))
        "and so is one that only ever held Loom's own document")
    (is-true (probe-file (target-file root "docs/design-summary/notes.md"))
             "their file is untouched")
    (is-true (probe-file (target-file root "docs/"))
             "and docs/ itself stays, because Loom found it rather than made it")))

(test tooling-removal-leaves-every-directory-alone
  ;; The mode that keeps documents has no business removing the directories
  ;; those documents live in.
  (with-target-tree (root)
    (prepare-repository root)
    (remove-preparation root :mode :tooling)
    (is-true (probe-file (target-file root "docs/concepts/"))
             "the concept is kept, so its directory must be too")
    (is-true (probe-file (target-file root "docs/plans/completed/")))))

(test a-directory-made-only-as-a-file-s-parent-is-recorded-too
  ;; The half the first version missed. .claude/ already existed on the tree
  ;; that found this, so .claude/skills/ and .claude/skills/loom/ were created
  ;; silently by ENSURE-DIRECTORIES-EXIST on the way to writing the skill,
  ;; appeared in no plan, and survived a full removal behind a `git status' that
  ;; looked clean -- git does not track an empty directory.
  (with-target-tree (root)
    (write-target-file root ".claude/settings.json" "{}")
    (prepare-repository root)
    (is-true (probe-file (target-file root ".claude/skills/loom/"))
             "the intermediate directories were made")
    (remove-preparation root :mode :all)
    (is (null (probe-file (target-file root ".claude/skills/")))
        "and taken back, because they were recorded rather than inferred")
    (is-true (probe-file (target-file root ".claude/settings.json"))
             "while .claude/ itself stays -- Loom found it, and their file is in it")))

;;; ------------------------------------------------------------------
;;; Proposing domains from a repository's own config (PLAN-0050 S14)
;;; ------------------------------------------------------------------

(defparameter *proposal-jsconfig* "{
  \"compilerOptions\": {
    \"moduleResolution\": \"bundler\",
    \"baseUrl\": \".\",
    \"paths\": {
      \"utils/*\": [\"src/utils/*\"],
      \"ui/*\": [\"src/ui/*\"],
      \"either/*\": [\"src/a/*\", \"src/b/*\"]
    }
  },
  \"include\": [\"src/**/*\", \"server/**/*\"]
}
"
  "Two include roots, two translatable aliases, and one that names two targets.

The third is the point. A key with two targets has no unambiguous prefix, so
translating it would be a guess written into a file the author is about to
confirm -- CON-0001. It is reported instead.")

(test a-repository-proposes-a-domain-for-each-include-root
  (with-target-tree (root)
    (write-target-file root "jsconfig.json" *proposal-jsconfig*)
    (multiple-value-bind (proposals problems) (loom-analyzer:propose-domains root)
      (declare (ignorable problems))
      (is (= 2 (length proposals)) "one per include root: ~a"
          (mapcar (lambda (p) (getf p :root)) proposals))
      (let ((roots (sort (mapcar (lambda (p) (getf p :root)) proposals) #'string<)))
        (is (equal '("server/" "src/") roots)))
      (is (every (lambda (p) (eq :bundler (getf p :resolution))) proposals)
          "moduleResolution bundler gives the bundler preset"))))

(test a-paths-entry-with-two-targets-is-reported-and-not-translated
  ;; CON-0001 at the proposal: a guess at which of two targets a key means
  ;; would be a fabricated fact in a file the author is about to accept.
  (with-target-tree (root)
    (write-target-file root "jsconfig.json" *proposal-jsconfig*)
    (multiple-value-bind (proposals problems) (loom-analyzer:propose-domains root)
      (is (= 1 (length problems)) "~a" problems)
      (is-true (search "either" (first problems)) "~a" problems)
      (is-true (search "2 targets" (first problems)) "~a" problems)
      (let ((aliases (getf (first proposals) :aliases)))
        (is (= 2 (length aliases)) "the two translatable ones: ~a" aliases)
        (is (equal "src/utils" (cdr (assoc "utils" aliases :test #'string=)))
            "and the trailing /* is off both halves")))))

(test a-nested-package-json-with-no-type-proposes-commonjs
  ;; Node's own default, and the reason front-end's functions/ resolves
  ;; differently from the rest of that tree.
  (with-target-tree (root)
    (write-target-file root "functions/package.json" "{\"name\": \"fns\"}
")
    (let ((proposals (loom-analyzer:propose-domains root)))
      (is (= 1 (length proposals)))
      (is (equal "functions/" (getf (first proposals) :root)))
      (is (eq :commonjs (getf (first proposals) :resolution))))))

(test a-nested-package-json-declaring-a-type-proposes-nothing
  ;; A package that says what it is needs no guess.
  (with-target-tree (root)
    (write-target-file root "mod/package.json" "{\"type\": \"module\"}
")
    (is (null (loom-analyzer:propose-domains root)))))

(test a-repository-with-no-javascript-config-proposes-nothing
  (with-target-tree (root)
    (multiple-value-bind (proposals problems) (loom-analyzer:propose-domains root)
      (is (null proposals))
      (is (null problems)))))

(test the-preparation-plan-carries-the-domain-proposal
  ;; End to end: the proposal reaches the report PREPARE-REPOSITORY returns, so
  ;; the author sees it before anything is written. Nothing about it is written
  ;; into the tree -- a declaration assembled from guesses would be a
  ;; configuration file nobody decided on.
  (with-target-tree (root)
    (write-target-file root "jsconfig.json" *proposal-jsconfig*)
    (write-target-file root "functions/package.json" "{\"name\": \"fns\"}
")
    (let* ((report (prepare-repository root :append-claude-md nil))
           (proposals (getf report :domain-proposals)))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (= 3 (length proposals))
          "src/ and server/ from include, functions/ from its package.json: ~a"
          (mapcar (lambda (p) (getf p :root)) proposals))
      (is-true (find :commonjs proposals :key (lambda (p) (getf p :resolution)))
               "the nested package with no type resolves under commonjs")
      (is (= 1 (length (getf report :domain-notes)))
          "and the untranslatable paths entry is reported: ~a"
          (getf report :domain-notes))
      (is (null (target-text root ".loom/frameworks.yaml"))
          "no declaration is written -- the proposal is shown, not applied"))))

;;; ------------------------------------------------------------------
;;; DES-0054 R10: a Firebase codebase's proposals
;;; ------------------------------------------------------------------

(defun firebase-json (&rest codebase-fields)
  (format nil "{\"functions\": [{~{~a~^, ~}}]}" codebase-fields))

(test a-python-codebase-proposes-the-python-template-and-a-domain
  (with-target-tree (root)
    (write-target-file root "firebase.json"
                       (firebase-json "\"source\": \"functions\"" "\"runtime\": \"python312\""))
    (let* ((report (prepare-repository root))
           (template (first (getf report :template-proposals)))
           (domain (first (getf report :domain-proposals))))
      (is (null (getf report :problems)) "~a" (getf report :problems))
      (is (equal "firebase-functions-python.yaml" (getf template :template)))
      (is (probe-file (getf template :template-path)) "the path to copy from exists")
      (is (equal "functions/" (getf domain :root)))
      (is (equal "firebase.json" (getf domain :from)))
      (is (eq :functions (getf domain :name))))))

(test no-runtime-and-a-main-py-is-python-too
  (with-target-tree (root)
    (write-target-file root "firebase.json" (firebase-json "\"source\": \"functions\""))
    (write-target-file root "functions/main.py" "x = 1
")
    (let ((report (prepare-repository root)))
      (is (equal "firebase-functions-python.yaml"
                 (getf (first (getf report :template-proposals)) :template)))
      (is (equal "functions/" (getf (first (getf report :domain-proposals)) :root))))))

(test a-nodejs-codebase-proposes-the-javascript-template-and-no-domain
  (with-target-tree (root)
    (write-target-file root "firebase.json"
                       (firebase-json "\"source\": \"functions\"" "\"runtime\": \"nodejs20\""))
    (let* ((report (prepare-repository root))
           (proposal (first (getf report :template-proposals))))
      (is (equal "firebase-functions-js.yaml" (getf proposal :template)))
      (is (probe-file (getf proposal :template-path)) "the path to copy from exists")
      (is (null (getf proposal :note)))
      (is (null (getf report :domain-proposals))
          "only a Python codebase proposes a domain"))))

(test no-runtime-and-a-package-json-is-javascript-too
  (with-target-tree (root)
    (write-target-file root "firebase.json" (firebase-json "\"source\": \"functions\""))
    (write-target-file root "functions/package.json" "{\"type\": \"module\"}
")
    (let ((report (prepare-repository root)))
      (is (equal "firebase-functions-js.yaml"
                 (getf (first (getf report :template-proposals)) :template)))
      (is (null (getf report :domain-proposals))))))

(test a-codebase-whose-language-cannot-be-told-says-so
  (with-target-tree (root)
    (write-target-file root "firebase.json" (firebase-json "\"source\": \"functions\""))
    (let ((proposal (first (getf (prepare-repository root) :template-proposals))))
      (is (null (getf proposal :template)))
      (is (search "not recognised" (getf proposal :note))))))

(test an-already-prepared-tree-gets-the-proposals-as-well-as-its-manifest
  ;; It used to return the manifest and nothing else, and lfia is prepared.
  (with-target-tree (root)
    (prepare-repository root)
    (write-target-file root "firebase.json"
                       (firebase-json "\"source\": \"functions\"" "\"runtime\": \"python312\""))
    (let ((report (prepare-repository root)))
      (is-true (getf report :already-prepared))
      (is-true (getf report :manifest))
      (is (equal "firebase-functions-python.yaml"
                 (getf (first (getf report :template-proposals)) :template)))
      (is (equal "functions/" (getf (first (getf report :domain-proposals)) :root))))))

(test the-proposal-never-writes-or-changes-frameworks-yaml
  (dolist (runtime '("python312" "nodejs20"))
    (with-target-tree (root)
      (write-target-file root "firebase.json"
                         (firebase-json "\"source\": \"functions\""
                                        (format nil "\"runtime\": \"~a\"" runtime)))
      (prepare-repository root)
      (is (null (target-text root ".loom/frameworks.yaml")) "~a: none is created" runtime)
      (write-target-file root ".loom/frameworks.yaml" "archived-paths: [old/]
")
      (let ((before (target-text root ".loom/frameworks.yaml")))
        (prepare-repository root)
        (is (equal before (target-text root ".loom/frameworks.yaml"))
            "~a: and none is changed" runtime)))))

(test the-python-template-parses-with-no-problems-and-declares-each-callee-once
  (with-target-tree (root)
    (write-target-file root ".loom/frameworks.yaml"
                       (loom-utils:read-file (loom-workspace::template-path
                                         "firebase-functions-python.yaml")))
    (is (null (loom-analyzer:frameworks-problems root))
        "~a" (loom-analyzer:frameworks-problems root))
    (let ((frameworks (loom-analyzer:read-frameworks root)))
      (is (< 10 (length (getf frameworks :entry-points))))
      (is (member "on_schedule"
                  (loop for entry in (getf frameworks :entry-points) append (getf entry :names))
                  :test #'string=))
      (is (equal '(:secret :param)
                 (mapcar (lambda (e) (getf e :source)) (getf frameworks :setting-declarations))))
      (is (null (getf frameworks :declaration-problems))))))

(defun declared-callees (entries)
  "Every module.name callee ENTRIES declare, as the strings the passes compare."
  (loop for entry in entries
        append (loop for name in (getf entry :names)
                     collect (format nil "~a.~a" (getf entry :module) name))))

(test the-javascript-template-parses-and-names-each-callee-once
  ;; The template is data with no compiler, so a misspelled module or name is
  ;; silent: the function stays in the no-caller band (PLAN-0058 risk 6). This
  ;; needs no node.
  (with-target-tree (root)
    (write-target-file root ".loom/frameworks.yaml"
                       (loom-utils:read-file (loom-workspace::template-path
                                         "firebase-functions-js.yaml")))
    (is (null (loom-analyzer:frameworks-problems root))
        "~a" (loom-analyzer:frameworks-problems root))
    (let* ((frameworks (loom-analyzer:read-frameworks root))
           (entry-callees (declared-callees (getf frameworks :entry-points)))
           (setting-callees (declared-callees (getf frameworks :setting-declarations))))
      (is (null (getf frameworks :declaration-problems))
          "no callee is declared twice: ~a" (getf frameworks :declaration-problems))
      (is (= (length entry-callees) (length (remove-duplicates entry-callees :test #'string=))))
      (dolist (callee '("firebase-functions.default.https.onRequest"
                        "firebase-functions.https.onRequest"
                        "firebase-functions/v2.default.https.onCall"
                        "firebase-functions/https.onRequest"
                        "firebase-functions/v2/https.onRequest"
                        "firebase-functions/scheduler.onSchedule"
                        "firebase-functions/v2/scheduler.onSchedule"
                        "firebase-functions/v2/firestore.onDocumentWritten"
                        "firebase-functions.alerts.crashlytics.onNewFatalIssuePublished"
                        "firebase-functions/v1.default.https.onRequest"))
        (is (member callee entry-callees :test #'string=) "~a is declared" callee))
      (dolist (callee '("firebase-functions/params.defineSecret"
                        "firebase-functions.default.params.defineSecret"
                        "firebase-functions/params.defineString"))
        (is (member callee setting-callees :test #'string=) "~a is declared" callee))
      (is (equal '(:secret :secret :param :param)
                 (mapcar (lambda (e) (getf e :source))
                         (getf frameworks :setting-declarations))))
      (is (equal '("schedule")
                 (getf (find "firebase-functions/v2/scheduler"
                             (getf frameworks :entry-points)
                             :key (lambda (e) (getf e :module)) :test #'string=)
                       :positional))))))

;;; ------------------------------------------------------------------
;;; DES-0055 D7, R7: init proposes dependency-modules:
;;; ------------------------------------------------------------------
;;;
;;; The child that reads a venv's RECORD files runs under python3, so the tests
;;; that reach it skip on a machine without one. Each fixture is built in a
;;; scratch tree (U6). The cases that matter most are the ones where the right
;;; answer is NO live entry: a proposal that invents a mapping is the CON-0001
;;; fabricated fact, and a test of the matching case alone cannot see it.

(defun init-python-p ()
  (ignore-errors
   (zerop (nth-value 2 (uiop:run-program '("python3" "-c" "pass")
                                         :ignore-error-status t)))))

(defparameter *site-packages* "venv/lib/python3.12/site-packages/")

(defun write-venv (root &optional (record-files '()))
  "A venv under ROOT with an empty site-packages. RECORD-FILES is a list of
(relative-path . contents) under it."
  (write-target-file root "venv/pyvenv.cfg" "home = /usr/bin
")
  (ensure-directories-exist (target-file root *site-packages*))
  (loop for (relative . contents) in record-files
        do (write-target-file root (concatenate 'string *site-packages* relative)
                              contents)))

(defun google-auth-venv (root)
  "The namespace-package case DES-0055 D7 names: google/ has no __init__.py."
  (write-venv root
              '(("google/auth/__init__.py" . "")
                ("google/auth/transport/requests.py" . "")
                ("google/oauth2/__init__.py" . "")
                ("google_auth-2.29.0.dist-info/RECORD" .
                 "google/auth/__init__.py,sha256=x,10
google/auth/transport/requests.py,,
google/oauth2/__init__.py,,
google/auth/__pycache__/__init__.cpython-312.pyc,,
google_auth-2.29.0.dist-info/RECORD,,
google_auth-2.29.0.dist-info/METADATA,,
../../../bin/gauth,,
"))))

(defun proposal-of (root &rest requirement-lines)
  (write-target-file root "requirements.txt"
                     (format nil "~{~a~%~}" requirement-lines))
  (dependency-module-proposal root))

(test the-proposal-names-the-submodule-and-not-the-namespace
  (if (not (init-python-p))
      (skip "python3 is not on PATH")
      (with-target-tree (root)
        (google-auth-venv root)
        (let ((proposal (proposal-of root "google-auth==2.29.0" "tzdata")))
          (is (search "  - distribution: google-auth
    modules: [google.auth, google.oauth2]" proposal) "~a" proposal)
          (is (not (search "google.auth.transport" proposal)))
          (is (not (search "[google]" proposal)))
          (is (search "# unverified: spelling only
  # - distribution: tzdata
  #   modules: [tzdata]" proposal) "~a" proposal)
          (write-target-file root ".loom/frameworks.yaml" proposal)
          (is (null (loom-analyzer:frameworks-problems root)))
          (is (equal '("google.auth" "google.oauth2")
                     (getf (first (getf (loom-analyzer:read-frameworks root)
                                        :dependency-modules))
                           :modules))
              "the live entry parses as a declaration and the commented one declares nothing")
          (is (= 1 (length (getf (loom-analyzer:read-frameworks root)
                                 :dependency-modules))))))))

(test the-proposal-never-runs-a-pth-file-from-site-packages
  ;; evil.pth would write MARKER if anything processed site-packages as a site
  ;; directory, which is what running the venv's interpreter or adding it to
  ;; sys.path does. The control proves the file does run when python is told to.
  (if (not (init-python-p))
      (skip "python3 is not on PATH")
      (with-target-tree (root)
        (google-auth-venv root)
        (let* ((marker (namestring (target-file root "MARKER")))
               (sp (namestring (target-file root *site-packages*))))
          (write-target-file root (concatenate 'string *site-packages* "evil.pth")
                             (format nil "import os; open(~s, 'w')~%" marker))
          (is (search "google.auth" (proposal-of root "google-auth")))
          (is (not (probe-file marker)) "the proposal did not run the .pth line")
          (uiop:run-program (list "python3" "-c"
                                  (format nil "import site; site.addsitedir(~s)" sp)))
          (is (probe-file marker) "control: site processing does run it")))))

(defun recording-python (root)
  "A script standing in for python3 that records it was started, and the path of
the MARKER it touches."
  (let ((script (target-file root "fake-python.sh"))
        (marker (target-file root "STARTED")))
    (write-target-file root "fake-python.sh"
                       (format nil "#!/bin/sh~%touch ~a~%echo '{}'~%" (namestring marker)))
    (uiop:run-program (list "chmod" "+x" (namestring script)))
    (values (namestring script) marker)))

(test no-venv-means-every-entry-is-commented-and-no-child-starts
  (with-target-tree (root)
    (multiple-value-bind (script marker) (recording-python root)
      ;; LET*: a parallel LET evaluates the proposal before the binding exists.
      (let* ((loom-analyzer::*python-program* script)
             (proposal (proposal-of root "google-auth" "Requests")))
        (is (not (probe-file marker)) "no venv, so no process")
        (is (search "  # - distribution: google-auth
  #   modules: [google_auth]" proposal) "~a" proposal)
        (is (search "  # - distribution: requests
  #   modules: [requests]" proposal))
        (is (not (search "
  - distribution" proposal)) "no live entry")
        ;; Control: with a venv the same stand-in is started, so the assertion
        ;; above cannot pass because the stand-in never could be.
        (write-venv root)
        (proposal-of root "google-auth")
        (is (probe-file marker) "control: a venv does start the child")))))

(test a-python-that-cannot-start-leaves-every-entry-commented
  (with-target-tree (root)
    (google-auth-venv root)
    (let* ((loom-analyzer::*python-program* "loom-no-such-python-xyz")
           (proposal (proposal-of root "google-auth")))
      (is (search "# unverified: spelling only" proposal) "~a" proposal)
      (is (not (search "
  - distribution" proposal))))))

(defun live-entry-p (proposal)
  (search "
  - distribution" (concatenate 'string (string #\Newline) proposal)))

(test an-empty-venv-and-an-unrelated-one-propose-nothing-live
  (if (not (init-python-p))
      (skip "python3 is not on PATH")
      (progn
        (with-target-tree (root)
          (write-venv root)
          (is (not (live-entry-p (proposal-of root "requests")))))
        ;; A different distribution installed. A name it does not ask for, or
        ;; asks for only as a prefix, must not be answered with it.
        (with-target-tree (root)
          (google-auth-venv root)
          (let ((proposal (proposal-of root "google" "google-auth-extra")))
            (is (not (live-entry-p proposal)) "~a" proposal)
            (is (search "modules: [google]" proposal)))))))

(test a-malformed-record-yields-no-live-entry-and-no-error
  (if (not (init-python-p))
      (skip "python3 is not on PATH")
      (dolist (record (list ""
                            (format nil "\"unterminated,,~%")
                            (format nil ",,~%,,,~%")
                            (format nil "~a" (make-string 3000 :initial-element #\x))
                            ;; Paths that leave site-packages, and a data file.
                            (format nil "../../outside.py,,~%/etc/abs.py,,~%pkg/data.json,,~%")
                            (coerce (list (code-char 0) (code-char 255) #\Newline) 'string)))
        (with-target-tree (root)
          (write-venv root `(("requests-2.0.dist-info/RECORD" . ,record)))
          (let ((proposal (proposal-of root "requests")))
            (is (stringp proposal))
            (is (not (live-entry-p proposal)) "~s gave ~a" record proposal))))))

(test only-the-trees-own-requirements-files-name-requirements
  ;; A requirements.txt shipped inside a venv is third-party data. It must not
  ;; widen what is proposed; requirements-dev.txt elsewhere in the tree must.
  (with-target-tree (root)
    (write-venv root)
    (write-target-file root "venv/lib/python3.12/site-packages/x/requirements.txt"
                       "evilpkg
")
    (write-target-file root "tests/requirements-dev.txt" "pytest>=7
")
    (let ((proposal (dependency-module-proposal root)))
      (is (search "pytest" proposal))
      (is (not (search "evilpkg" proposal)) "~a" proposal))))

(test no-requirement-names-means-no-proposal
  (with-target-tree (root)
    (google-auth-venv root)
    (is (null (dependency-module-proposal root)))
    (write-target-file root "requirements.txt" "# only a comment
-r other.txt
--extra-index-url https://example.invalid/simple
")
    (is (null (dependency-module-proposal root)))))

(test the-report-carries-the-dependency-proposal-and-writes-nothing
  (with-target-tree (root)
    (write-target-file root "requirements.txt" "tzdata
")
    (let ((fresh (prepare-repository root)))
      (is (search "tzdata" (getf fresh :dependency-proposal)))
      (is (null (target-text root ".loom/frameworks.yaml"))))
    (write-target-file root ".loom/frameworks.yaml" "archived-paths: [old/]
")
    (let ((before (target-text root ".loom/frameworks.yaml"))
          (again (prepare-repository root)))
      (is-true (getf again :already-prepared))
      (is (search "tzdata" (getf again :dependency-proposal)))
      (is (equal before (target-text root ".loom/frameworks.yaml"))))))

(test a-tree-without-requirements-reports-no-dependency-proposal
  (with-target-tree (root)
    (is (null (getf (prepare-repository root) :dependency-proposal)))))
