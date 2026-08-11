;;;; The markdown analyzer: prose documentation becomes graph entities.
;;;; Implements REQ-0014 by way of ARCH-0016.
;;;;
;;;; A second analyzer beside the YAML one rather than a widening of it, for
;;;; the reason SS8.1 gives the protocol at all (ARCH-0016 D1). The two share
;;;; nothing below the entity they produce: one parses with cl-yaml and reads
;;;; named fields, the other scans text for spans; one has to guard for
;;;; YAML.ERROR:YAML-ERROR (RULE-0004) and the other cannot fail to parse.
;;;;
;;;; What this reads is deliberately shallow. REQ-0014 asks for "indexing what
;;;; is there, with no generation and no inference": the first H1, the inline
;;;; code spans, and the link targets. It does not summarize, does not
;;;; interpret heading structure, and does not turn a markdown file into a REQ
;;;; or an ARCH document -- that is REQ-0017, and it is a separate and much
;;;; riskier proposal.
;;;;
;;;; The one judgement running through the whole file is CON-0001's. A
;;;; backtick is evidence that a file names something; it is not evidence that
;;;; the file governs it. So everything found here leaves as a :MENTIONS
;;;; candidate -- the weak type -- and a candidate that resolves to nothing is
;;;; dropped in silence rather than reported, because prose is full of
;;;; ordinary words in backticks and reporting each as a rotten reference
;;;; would bury the signal that document-staleness detection depends on
;;;; (REQ-0014 R3).

(in-package :loom-analyzer)

;;;; ==================================================================
;;;; Which directories count (REQ-0014 R2, ARCH-0016 D2)
;;;; ==================================================================

(defparameter *documentation-directories*
  '("docs" "doc" "design" "documentation")
  "Directory names that mark a tree as documentation.

Convention with a registration seam, deliberately, and not configuration:
ARCH-0016 D2 records the reasoning and the rejected alternative. Loom keeps its
own documents in docs/; ~/lisp/game-server keeps requirements in design/ and
reference material in docs/; a repository that uses a fifth name registers it
rather than editing this file.

The repository root is not on this list and is not meant to be. A root
README.md is as often a build instruction or a badge wall as it is engineering
knowledge, and it is what makes game-server's twelve documentation files twelve
rather than fifteen.")

(defun register-documentation-directory (name)
  "Add NAME to the directories markdown is indexed from. Idempotent."
  (pushnew (string-downcase name) *documentation-directories* :test #'string=)
  *documentation-directories*)

(defun documentation-relative-p (path)
  "True when some *directory* segment of PATH is a documentation directory.

The filename is excluded from the comparison: a file called docs.md at the
repository root is not a documentation tree, and the question this asks is
which directory the file sits in."
  (let ((segments (path-segments (substitute #\/ #\\ (namestring path)))))
    (and (some (lambda (segment)
                 (member segment *documentation-directories* :test #'string-equal))
               (butlast segments))
         t)))

;;;; ==================================================================
;;;; Reading the text: fences, headings, spans, links (ARCH-0016 D5)
;;;; ==================================================================

(defun text-lines (string)
  "STRING split on newlines, with any carriage returns stripped."
  (let ((lines '()) (start 0))
    (loop for pos = (position #\Newline string :start start)
          do (push (string-right-trim '(#\Return) (subseq string start (or pos (length string))))
                   lines)
             (if pos (setf start (1+ pos)) (return)))
    (nreverse lines)))

(defun fence-delimiter-p (line)
  "The fence marker LINE opens or closes with, or NIL.
Three or more backticks or tildes, per CommonMark. The marker is returned so a
``` fence is not closed by a ~~~ one."
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (loop for char in '(#\` #\~)
          when (and (>= (length trimmed) 3)
                    (every (lambda (c) (char= c char)) (subseq trimmed 0 3)))
            return char)))

(defun unfenced-lines (lines)
  "LINES with every fenced code block, delimiters included, removed.

A fence is a transcript or a specimen -- a shell session, a SQL schema, an
ASCII diagram -- and its tokens are the document reproducing something rather
than naming it (ARCH-0016 D5). An unterminated fence swallows the rest of the
file, which is the correct reading of the text rather than a case to work
around: the author wrote an opening fence and no closing one, and everything
after it is inside a code block."
  (let ((open nil)
        (kept '()))
    (dolist (line lines (nreverse kept))
      (let ((delimiter (fence-delimiter-p line)))
        (cond (open (when (eql delimiter open) (setf open nil)))
              (delimiter (setf open delimiter))
              (t (push line kept)))))))

(defun first-heading (lines)
  "The first level-1 heading in LINES, or NIL.

Both markdown spellings, because both are in live use: ATX (`# Title') and
setext (a title underlined with `='). A level-2 heading is not a title -- the
`## The two layers' that opens a section is a section, and REQ-0014 R1 asks
for the first H1 and nothing cleverer."
  (loop for (line next) on lines
        for trimmed = (string-trim '(#\Space #\Tab) line)
        do (cond ((and (> (length trimmed) 1)
                       (char= #\# (char trimmed 0))
                       (not (char= #\# (char trimmed 1))))
                  (return (let ((title (string-trim '(#\Space #\Tab #\#)
                                                    (subseq trimmed 1))))
                            (if (zerop (length title)) nil title))))
                 ((and next
                       (plusp (length trimmed))
                       (let ((u (string-trim '(#\Space #\Tab) next)))
                         (and (plusp (length u))
                              (every (lambda (c) (char= c #\=)) u))))
                  (return trimmed)))))

(defun title-from-path (path)
  "PATH's filename without its extension -- what a document with no H1 is called."
  (let ((name (pathname-name (pathname path))))
    (or name path)))

(defun code-span-contents (text)
  "The contents of every inline code span in TEXT.

A run of N backticks opens a span and the next run of exactly N closes it,
which is CommonMark's rule and the one that makes ``a `b` c`` read correctly. A
span is not allowed to cross a line: an unbalanced backtick in prose would
otherwise swallow paragraphs, and a code span spanning lines is rare enough
that missing it costs less than that."
  (let ((found '())
        (length (length text))
        (position 0))
    (flet ((run-length (start)
             (loop for i from start below length
                   while (char= #\` (char text i))
                   count 1)))
      (loop while (< position length)
            do (let ((tick (position #\` text :start position)))
                 (unless tick (return))
                 (let* ((open (run-length tick))
                        (body-start (+ tick open))
                        (close body-start))
                   (loop
                     (let ((next (position #\` text :start close)))
                       (cond ((or (null next)
                                  (find #\Newline text :start body-start :end next))
                              ;; No closer on this line: this run was not an
                              ;; opener after all. Step past it and carry on.
                              (setf position body-start)
                              (return))
                             ((= open (run-length next))
                              (push (subseq text body-start next) found)
                              (setf position (+ next open))
                              (return))
                             (t (setf close (+ next (run-length next))))))))))
      (nreverse found))))

(defun link-targets (text)
  "Every inline link or image target in TEXT: the (...) half of [text](...).

Reference definitions -- `[label]: ../media/' on a line of its own -- are read
by LINE-LINK-TARGETS below rather than here, because they are a line shape
rather than an inline one."
  (let ((found '())
        (position 0))
    (loop for open = (search "](" text :start2 position)
          while open
          do (let ((close (position #\) text :start (+ open 2))))
               (if close
                   (progn (push (subseq text (+ open 2) close) found)
                          (setf position (1+ close)))
                   (return))))
    (nreverse found)))

(defun line-link-targets (lines)
  "Targets of reference definitions: a line of the form `[label]: target'."
  (loop for line in lines
        for trimmed = (string-trim '(#\Space #\Tab) line)
        for close = (and (plusp (length trimmed))
                         (char= #\[ (char trimmed 0))
                         (position #\] trimmed))
        when (and close
                  (< (1+ close) (length trimmed))
                  (char= #\: (char trimmed (1+ close))))
          collect (string-trim '(#\Space #\Tab) (subseq trimmed (+ close 2)))))

;;;; ==================================================================
;;;; Turning a link target into a workspace-relative path (ARCH-0016 D6)
;;;;
;;;; The analyzer normalizes and stops. It does not check whether the result
;;;; exists: an analyzer has no index and must not acquire one (SS8.1), and the
;;;; filesystem is equally off limits. RESOLVE-DOCUMENT-LINKS matches the
;;;; string against the :NAME of a :FILE entity, which is the same
;;;; workspace-relative, forward-slashed path this produces.
;;;; ==================================================================

(defun external-target-p (target)
  "True for a target that names something outside the repository."
  (or (search "://" target)
      (let ((colon (position #\: target))
            (slash (position #\/ target)))
        ;; A scheme is a colon before any slash: mailto:, tel:, file:. A
        ;; Windows-style ../foo:bar has no colon before its slash.
        (and colon (or (null slash) (< colon slash))))))

(defun collapse-path-segments (segments)
  "SEGMENTS with `.' dropped and `..' popping what precedes it.
A `..' with nothing to pop is kept, so a target reaching above the workspace
root stays visibly wrong rather than quietly becoming a sibling."
  (let ((out '()))
    (dolist (segment segments (nreverse out))
      (cond ((string= segment ".") nil)
            ((string= segment "..")
             (if (and out (not (string= (first out) "..")))
                 (pop out)
                 (push segment out)))
            ((zerop (length segment)) nil)
            (t (push segment out))))))

(defun normalize-link-target (target document-path)
  "TARGET as a workspace-relative path, or NIL when it names no file.

NIL for an external URL, a bare `#anchor', and a directory -- Loom mints no
directory entity, so `../data-api/' would resolve to nothing anyway and R3 asks
that it be dropped rather than reported."
  (let ((text (string-trim '(#\Space #\Tab #\< #\>) target)))
    ;; `[a](b "title")' and `[a](b 'title')': the target is the first word.
    (let ((space (position-if (lambda (c) (member c '(#\Space #\Tab))) text)))
      (when space (setf text (subseq text 0 space))))
    ;; Fragments and queries address a place inside the target, not a
    ;; different file.
    (let ((cut (position-if (lambda (c) (member c '(#\# #\?))) text)))
      (when cut (setf text (subseq text 0 cut))))
    (setf text (substitute #\/ #\\ text))
    (cond ((zerop (length text)) nil)
          ((external-target-p text) nil)
          ((char= #\/ (char text (1- (length text)))) nil)
          (t
           (let* ((absolute (char= #\/ (char text 0)))
                  (base (if absolute
                            '()
                            (butlast (path-segments
                                      (substitute #\/ #\\ (namestring document-path))))))
                  (segments (collapse-path-segments
                             (append base (path-segments text)))))
             (when segments
               (format nil "~{~a~^/~}" segments)))))))

;;;; ==================================================================
;;;; Candidates (REQ-0014 R3)
;;;; ==================================================================

(defun mention-candidate-p (token)
  "True when TOKEN is worth offering to the resolver.

Deliberately looser than PROSE-MENTIONS' test, and for a reason that inverts
it. That function reads unmarked prose, where the author gave no signal at all,
so it demands a hyphen or an interior capital before it will believe a word is
an identifier. Here the author typed backticks, which is the signal. What is
left to exclude is a span that is plainly not a name: a phrase, an empty span,
or something too short for a match to mean anything (`id' matches half a
schema)."
  (and (>= (length token) *mention-minimum-length*)
       (alpha-char-p (char token 0))
       (notany (lambda (c) (member c '(#\Space #\Tab #\Newline))) token)))

(defun markdown-mentions (contents path)
  "Every candidate name CONTENTS offers, from its code spans and its links.

The union of two readings of the same text, deduplicated and downcased --
LINKABLE-INDEX keys on a downcased name, so the case a document wrote a name in
is not a fact worth carrying past here.

PROSE-MENTIONS is deliberately not applied. It was tuned against Loom's own
document bodies, which are prose about Loom in Loom's vocabulary; turned loose
on arbitrary markdown it would offer every hyphenated English compound in the
file. REQ-0014 R3 asks for backticks and links, which is what this reads."
  (let* ((lines (unfenced-lines (text-lines contents)))
         (text (format nil "~{~a~^~%~}" lines))
         (found '()))
    (dolist (span (code-span-contents text))
      (let ((token (string-trim '(#\Space #\Tab) span)))
        (when (mention-candidate-p token)
          (pushnew (string-downcase token) found :test #'string=))))
    (dolist (target (append (link-targets text) (line-link-targets lines)))
      (let ((normalized (normalize-link-target target path)))
        (when normalized
          (pushnew (string-downcase normalized) found :test #'string=))))
    (nreverse found)))

;;;; ==================================================================
;;;; The analyzer
;;;; ==================================================================

(defclass markdown-analyzer (analyzer)
  ()
  (:default-initargs :language nil :file-types '("md" "markdown"))
  (:documentation "Reads markdown under a documentation directory (REQ-0014)."))

(defmethod analyzer-handles-p ((analyzer markdown-analyzer) path)
  "Markdown, and under a documentation directory. The extension alone is not
enough for the same reason DOCUMENT-ANALYZER gives about a CI config: a
CHANGELOG.md or a node_modules README is markdown too, and indexing it as
engineering knowledge would be worse than ignoring it."
  (and (call-next-method) (documentation-relative-p path)))

(defmethod analyze-file ((analyzer markdown-analyzer) path contents workspace-id)
  "Ontology operations for one markdown document.

One :DOCUMENT entity, named and keyed by its path. Always :DOCUMENT, never the
type its directory would name under *DOCUMENT-TYPE-DIRECTORIES*: game-server
keeps design/pieces.md and design/rules.md, and neither is a Loom decision
record or a Loom rule. That registry is a convention of CON-0004's own
workflow, and reading a foreign repository's design/ as a directory of DEC
documents would be the generality failure REQ-0014 was raised about, committed
one level down (ARCH-0016 D3).

No :DOC-ID, and none of the declared link fields -- affects:, applies-to:,
supersedes:, refines:. A markdown file declares none of them, and that absence
is what keeps `unresolved' at zero: RESOLVE-DOCUMENT-LINKS only reports a name
that a *declared* field promised would resolve."
  (declare (ignore analyzer))
  (let* ((lines (text-lines contents))
         (title (or (first-heading (unfenced-lines lines))
                    (title-from-path path)))
         (entity (make-instance 'document-entity
                                :name path
                                :origin-file path
                                :source :human-validated
                                :properties
                                (properties-table
                                 (list :path path
                                       :title title
                                       :body contents
                                       :system (default-system-for-path path)
                                       :format :markdown
                                       :mentions (markdown-mentions contents path)
                                       :unresolved-references '())))))
    (list (retract-file path workspace-id)
          (assert-entity entity workspace-id))))

;;;; The one registered instance -- stateless, so one serves every document.
(register-analyzer (make-instance 'markdown-analyzer))
