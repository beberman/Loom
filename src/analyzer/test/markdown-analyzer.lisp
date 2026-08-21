;;;
;;; Tests for src/analyzer/markdown-analyzer.lisp -- REQ-0014 by way of
;;; DES-0016.
;;;
;;; Fixture strings rather than a second repository. REQ-0014's own acceptance
;;; measurement is taken against ~/lisp/game-server, which is not checked out
;;; wherever this suite runs, so the numbers live in PLAN-0016 step 9 and what
;;; is asserted here is the behaviour that produces them. The one exception is
;;; docs/TODO.md, which is in this tree.
;;;

(in-package :loom-analyzer-test)

(def-suite markdown-analyzer
  :in all-tests
  :description "Markdown under a documentation directory (REQ-0014).")

(in-suite markdown-analyzer)

(defun md-ops (path contents)
  (analyze-file (make-instance 'markdown-analyzer) path contents "ws-test"))

(defun md-entity (path contents)
  (let ((g (make-graph)))
    (apply-transaction g (md-ops path contents))
    (first (remove-if-not (lambda (e) (eq :document (entity-type e)))
                          (all-entities g)))))

(defun md-mentions (path contents)
  "The backticked code spans only. Link targets live in :LINK-TARGETS since
BUG-0027, because the two fail differently: an unresolved span is an ordinary
word and is dropped in silence, an unresolved link is a path that is not there."
  (getp (md-entity path contents) :mentions))

(defun md-links (path contents)
  (getp (md-entity path contents) :link-targets))

;;; ------------------------------------------------------------------
;;; Dispatch: which directories count (R1, R2)
;;; ------------------------------------------------------------------

(test prose-is-claimed-wherever-the-repository-keeps-it
  ;; REQ-0028. The old rule claimed markdown only under a directory named docs,
  ;; doc, design or documentation -- which tested where a file lived rather than
  ;; what it said, and missed the most common place architecture lives.
  ;; Measured on ~/github/front-end: src/models/README.md, 541 lines titled
  ;; "Models Directory - Game Object System", invisible because the directory is
  ;; called models.
  (let ((a (make-instance 'markdown-analyzer)))
    (is-true (analyzer-handles-p a "docs/data-layer.md"))
    (is-true (analyzer-handles-p a "src/models/README.md")
             "the file that prompted the change")
    (is-true (analyzer-handles-p a "README.md")
             "R1a: the root README, which DES-0016 excluded by name")
    (is-true (analyzer-handles-p a "notes/adr/0001-why.md")
             "a name nobody put on an allowlist")
    (is-true (analyzer-handles-p a "design.txt")
             "and plain text, which was never claimed at all")))

(test instructions-to-an-assistant-are-not-documentation-of-the-code
  ;; The population a blanket walk would wrongly admit. An agent definition
  ;; describes how an assistant should behave; indexing it puts a prompt into
  ;; the graph wearing the shape of documentation, which is CON-0001's failure
  ;; in a new place.
  (let ((a (make-instance 'markdown-analyzer)))
    (is-false (analyzer-handles-p a ".claude/agents/coder.md"))
    (is-false (analyzer-handles-p a ".windsurf/rules/logging.md"))
    (is-false (analyzer-handles-p a ".claude/skills/loom/SKILL.md")
              "including the skill Loom itself installs")
    (is-false (analyzer-handles-p a "CLAUDE.md")
              "by name: it is not dot-prefixed and no structural rule reaches it")
    (is-false (analyzer-handles-p a "AGENTS.md"))
    (is-false (analyzer-handles-p a "nested/deep/CLAUDE.md")
              "wherever it sits")))

(test text-written-to-be-copied-elsewhere-describes-the-elsewhere
  ;; Loom's own src/workspace/templates/ holds what init writes into other
  ;; people's repositories. Indexing it would describe this codebase with prose
  ;; written about a different one.
  (let ((a (make-instance 'markdown-analyzer)))
    (is-false (analyzer-handles-p a "src/workspace/templates/loom-skill.md"))
    (is-false (analyzer-handles-p a "templates/anything.md"))))

(test the-directory-name-no-longer-decides
  ;; What the retired registration seam was really guarding. A repository that
  ;; keeps its prose under a fifth name used to have to register it; now there
  ;; is nothing to register because the name was never the question.
  (let ((a (make-instance 'markdown-analyzer)))
    (dolist (path '("handbook/onboarding.md" "wiki/design.md" "rfc/0003.md"
                    "architecture/overview.md" "a/b/c/d/notes.md"))
      (is-true (analyzer-handles-p a path)
               "~a is claimed without anybody registering a directory" path))))

(test the-two-document-analyzers-claim-disjoint-extensions
  ;; The 88 YAML documents must be undisturbed by any of this (DES-0016 D9),
  ;; and FIND-ANALYZER takes the first analyzer that claims a path -- so the
  ;; guarantee has to be that no path is claimed twice.
  (let ((markdown (make-instance 'markdown-analyzer))
        (yaml (make-instance 'document-analyzer)))
    (is-false (analyzer-handles-p markdown "docs/decisions/DEC-0001.yaml"))
    (is-false (analyzer-handles-p yaml "docs/TODO.md"))
    (is (typep (find-analyzer "docs/TODO.md") 'markdown-analyzer))
    (is (typep (find-analyzer "docs/decisions/DEC-0001.yaml") 'document-analyzer))))

(test a-plain-text-file-links-only-through-an-identifier
  ;; DES-0023 D2. Markdown gives an author a backtick to mark a name with and
  ;; plain text gives nothing, so matching every token would manufacture edges
  ;; out of ordinary English -- and would make the resolution rate meaningless,
  ;; since a rate only informs when its denominator is what somebody chose to
  ;; mark.
  (let ((mentions (loom-analyzer::markdown-mentions
                   "Directory Structure
 - common: utilities and helpers
 - the dhandler-delete path is in data-api/handler.lisp
"
                   "design.txt")))
    (is (member "dhandler-delete" mentions :test #'string=)
        "an identifier-shaped token is a candidate: ~a" mentions)
    (is (member "data-api/handler.lisp" mentions :test #'string=)
        "and so is a path")
    (is (not (member "utilities" mentions :test #'string=))
        "an ordinary word is not")
    (is (not (member "structure" mentions :test #'string=)))))

;;; ------------------------------------------------------------------
;;; The entity (R1)
;;; ------------------------------------------------------------------

(test the-first-h1-is-the-title
  (let ((e (md-entity "docs/x.md" (format nil "# The two layers~%~%text"))))
    (is (string= "The two layers" (getp e :title)))
    (is (eq :markdown (getp e :format)))
    (is (string= "docs/x.md" (getp e :path)))
    (is (string= "docs/x.md" (name e))
        "named by path: it is what impact prints and what an agent then opens")))

(test a-setext-heading-is-a-title-too
  (let ((e (md-entity "docs/x.md" (format nil "Data layer~%==========~%~%text"))))
    (is (string= "Data layer" (getp e :title)))))

(test a-level-two-heading-is-not-a-title
  ;; `## The two layers' opens a section, not a document.
  (let ((e (md-entity "docs/data-layer.md"
                      (format nil "## The two layers~%~%text"))))
    (is (string= "data-layer" (getp e :title))
        "with no H1 the filename is the title, and says so rather than guessing")))

(test a-markdown-document-declares-no-references-to-resolve
  ;; DES-0016 D9, and the structural half of R3/R6's "unresolved does not
  ;; rise": the fields RESOLVE-DOCUMENT-LINKS reports on are the declared ones,
  ;; and markdown supplies none of them.
  (let ((e (md-entity "docs/x.md" "# T
`something-that-does-not-exist` and [a link](../nowhere/at/all.lisp)")))
    (is (null (getp e :affects)))
    (is (null (getp e :refines)))
    (is (null (getp e :applies-to)))
    (is (null (getp e :unresolved-references)))
    (is (null (getp e :doc-id))
        "a document with no id: field has no id; the path is already the key")))

(test the-system-property-is-the-path-default
  ;; DES-0009 R1: every :DOCUMENT carries one, and a document has no grouping
  ;; construct of its own to read.
  (is (eq :docs (getp (md-entity "docs/x.md" "# T") :system))))

;;; ------------------------------------------------------------------
;;; Code spans (R3)
;;; ------------------------------------------------------------------

(test a-backticked-identifier-is-a-candidate
  ;; The line REQ-0014 R6 names, from game-server's docs/data-layer.md.
  (let ((m (md-mentions "docs/data-layer.md"
                        "  (`dhandler-get`, `dhandler-put`, `dhandler-delete`,")))
    (is (member "dhandler-get" m :test #'string=))
    (is (member "dhandler-delete" m :test #'string=))))

(test a-span-that-is-a-phrase-is-not-a-candidate
  (let ((m (md-mentions "docs/x.md" "the `two layer model` is `id` and `a`")))
    (is (null m)
        "a phrase is not a name, and a two-character span matches half a schema")))

(test a-fenced-block-contributes-nothing
  ;; DES-0016 D5: a fence is the document reproducing something, not naming
  ;; it. game-server's twelve files carry 256 fence delimiters between them.
  (let ((m (md-mentions "docs/x.md"
                        (format nil "prose `real-name` here~%~
                                     ```~%~
                                     (defun fenced-name () nil)~%~
                                     `also-fenced`~%~
                                     ```~%~
                                     more `second-name`"))))
    (is (member "real-name" m :test #'string=))
    (is (member "second-name" m :test #'string=))
    (is (not (member "also-fenced" m :test #'string=)))))

(test an-unterminated-fence-swallows-the-rest-of-the-file
  ;; The correct reading of the text rather than a case to work around: the
  ;; author wrote an opening fence and no closing one.
  (let ((m (md-mentions "docs/x.md"
                        (format nil "`before-fence`~%```~%`after-fence`~%"))))
    (is (member "before-fence" m :test #'string=))
    (is (not (member "after-fence" m :test #'string=)))))

(test a-tilde-fence-is-not-closed-by-a-backtick-one
  (let ((m (md-mentions "docs/x.md"
                        (format nil "~~~~~~~%```~%`inside-still`~%~~~~~~~%`outside-now`"))))
    (is (not (member "inside-still" m :test #'string=)))
    (is (member "outside-now" m :test #'string=))))

(test a-double-backtick-span-holds-a-single-backtick
  (let ((m (md-mentions "docs/x.md" "``a `nested-name` b`` and `plain-name`")))
    (is (member "plain-name" m :test #'string=))))

(test an-unbalanced-backtick-does-not-swallow-the-paragraph
  (let ((m (md-mentions "docs/x.md"
                        (format nil "an ` unclosed tick~%then `real-name` after"))))
    (is (member "real-name" m :test #'string=))))

;;; ------------------------------------------------------------------
;;; Link targets (R3, DES-0016 D6)
;;; ------------------------------------------------------------------

(test a-relative-link-normalizes-against-the-documents-own-directory
  (let ((m (md-links "docs/data-layer.md"
                        "[`media`](../media/media-handler.lisp) and [x](./sibling.md)")))
    (is (member "media/media-handler.lisp" m :test #'string=))
    (is (member "docs/sibling.md" m :test #'string=))))

(test a-directory-target-and-an-external-url-are-dropped
  ;; Loom mints no directory entity, so `../data-api/' would resolve to nothing
  ;; anyway -- and R3 asks that it be dropped rather than reported.
  (let ((m (md-links "docs/x.md"
                        "[a](../data-api/) [b](https://example.com/x.lisp) ~
                         [c](mailto:someone@example.com) [d](#a-section)")))
    (is (null m))))

(test a-fragment-and-a-title-are-stripped-from-a-target
  (let ((m (md-links "docs/x.md"
                        "[a](../src/foo.lisp#the-part \"A title\")")))
    (is (member "src/foo.lisp" m :test #'string=))))

(test a-reference-definition-is-a-link-too
  (let ((m (md-links "docs/x.md" (format nil "see [handler]~%~%[handler]: ../media/h.lisp"))))
    (is (member "media/h.lisp" m :test #'string=))))

(test a-target-reaching-above-the-root-stays-visibly-wrong
  ;; Rather than quietly becoming a sibling. It resolves to nothing and is
  ;; dropped, which is the recorded gap CON-0001 prefers to a fabricated hit.
  (is (member "../elsewhere.lisp"
              (md-links "docs/x.md" "[a](../../elsewhere.lisp)")
              :test #'string=)))

;;; ------------------------------------------------------------------
;;; This tree's own markdown
;;; ------------------------------------------------------------------

(test loom-indexes-its-own-todo-file
  (let* ((path (merge-pathnames "docs/TODO.md" *repo-root*))
         (e (and (probe-file path) (md-entity "docs/TODO.md" (utils:read-file path)))))
    (when e
      (is (string= "docs/TODO.md" (name e)))
      (is (eq :markdown (getp e :format)))
      (is (plusp (length (getp e :body)))))))
