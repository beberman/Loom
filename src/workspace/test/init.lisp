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
                 (merge-pathnames (format nil "loom-init-~a/" (random 100000))
                                  (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun target-file (root relative)
  (merge-pathnames relative root))

(defun target-text (root relative)
  (let ((path (target-file root relative)))
    (and (probe-file path) (loom-analyzer:slurp-file path))))

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
