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
  (getp (md-entity path contents) :mentions))

;;; ------------------------------------------------------------------
;;; Dispatch: which directories count (R1, R2)
;;; ------------------------------------------------------------------

(test markdown-is-claimed-under-a-documentation-directory
  (let ((a (make-instance 'markdown-analyzer)))
    (is-true (analyzer-handles-p a "docs/data-layer.md"))
    (is-true (analyzer-handles-p a "design/HexGridRequirements.md"))
    (is-true (analyzer-handles-p a "docs/notes.markdown"))
    (is-true (analyzer-handles-p a "some/nested/doc/thing.md")
             "R2: the directory may sit anywhere in the path, not only at the root")))

(test the-repository-root-is-not-a-documentation-directory
  ;; What makes game-server's twelve documentation files twelve rather than
  ;; fifteen: Bugs.md, CLAUDE.md and README.md sit at the root and are not
  ;; engineering knowledge by virtue of being markdown. REQ-0014 R6.
  (let ((a (make-instance 'markdown-analyzer)))
    (is-false (analyzer-handles-p a "README.md"))
    (is-false (analyzer-handles-p a "CLAUDE.md"))
    (is-false (analyzer-handles-p a "src/analyzer/notes.md"))
    (is-false (analyzer-handles-p a "docs.md")
              "a file called docs.md is not a docs directory")))

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

(test a-registered-directory-is-claimed-from-then-on
  (let ((*documentation-directories* (copy-list *documentation-directories*))
        (a (make-instance 'markdown-analyzer)))
    (is-false (analyzer-handles-p a "handbook/onboarding.md"))
    (register-documentation-directory "handbook")
    (is-true (analyzer-handles-p a "handbook/onboarding.md"))))

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
  (let ((m (md-mentions "docs/data-layer.md"
                        "[`media`](../media/media-handler.lisp) and [x](./sibling.md)")))
    (is (member "media/media-handler.lisp" m :test #'string=))
    (is (member "docs/sibling.md" m :test #'string=))))

(test a-directory-target-and-an-external-url-are-dropped
  ;; Loom mints no directory entity, so `../data-api/' would resolve to nothing
  ;; anyway -- and R3 asks that it be dropped rather than reported.
  (let ((m (md-mentions "docs/x.md"
                        "[a](../data-api/) [b](https://example.com/x.lisp) ~
                         [c](mailto:someone@example.com) [d](#a-section)")))
    (is (null m))))

(test a-fragment-and-a-title-are-stripped-from-a-target
  (let ((m (md-mentions "docs/x.md"
                        "[a](../src/foo.lisp#the-part \"A title\")")))
    (is (member "src/foo.lisp" m :test #'string=))))

(test a-reference-definition-is-a-link-too
  (let ((m (md-mentions "docs/x.md" (format nil "see [handler]~%~%[handler]: ../media/h.lisp"))))
    (is (member "media/h.lisp" m :test #'string=))))

(test a-target-reaching-above-the-root-stays-visibly-wrong
  ;; Rather than quietly becoming a sibling. It resolves to nothing and is
  ;; dropped, which is the recorded gap CON-0001 prefers to a fabricated hit.
  (is (member "../elsewhere.lisp"
              (md-mentions "docs/x.md" "[a](../../elsewhere.lisp)")
              :test #'string=)))

;;; ------------------------------------------------------------------
;;; This tree's own markdown
;;; ------------------------------------------------------------------

(test loom-indexes-its-own-todo-file
  (let* ((path (merge-pathnames "docs/TODO.md" *repo-root*))
         (e (and (probe-file path) (md-entity "docs/TODO.md" (slurp-file path)))))
    (when e
      (is (string= "docs/TODO.md" (name e)))
      (is (eq :markdown (getp e :format)))
      (is (plusp (length (getp e :body)))))))
