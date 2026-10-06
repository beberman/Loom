;;;; Preparing a repository Loom did not write.
;;;;
;;;; REQ-0021, DES-0022 S2, PLAN-0023. Everything here writes into somebody
;;;; else's tree, which is the only reason this file is shaped the way it is.
;;;;
;;;; Three rules follow from that and each shows up as structure below rather
;;;; than as a comment on a line.
;;;;
;;;; It plans before it applies. A preparation is a directory tree, several
;;;; documents and up to two appends, and a filesystem is not transactional. So
;;;; PLAN-PREPARATION resolves every path, reads every file it will touch and
;;;; collects every problem before APPLY-PREPARATION writes a byte -- the same
;;;; split APPLY-TRANSACTION uses for the graph and the transition command uses
;;;; for documents, applied to a wider set of writes.
;;;;
;;;; It creates rather than edits, with one bounded exception. Every file it
;;;; writes is new, and a name already taken is refused rather than overwritten.
;;;; CLAUDE.md is the exception REQ-0021 R3 now carries: appended to, between
;;;; markers, only with consent, and only when our markers are not already
;;;; there. That exception exists because CLAUDE.md is the only channel a
;;;; session receives unprompted -- a skill is advertised by name and its
;;;; content arrives only if the model invokes it -- so forbidding this one edit
;;;; would forbid the workflow being found at all (DES-0022 D2a).
;;;;
;;;; It records what it did before doing it. The manifest is written first, not
;;;; last, because a run that dies halfway is exactly when removal needs to know
;;;; what was intended, and a manifest written at the end does not exist at the
;;;; moment it is wanted.
;;;;
;;;; It does not prompt. R16 puts the asking in the script, where a terminal is;
;;;; the answers arrive here as arguments. A command that prompted could not be
;;;; called by a script, a test, or the service.

(in-package :loom-workspace)

(defparameter *loom-state-directory* ".loom"
  "Where a prepared repository keeps Loom's own bookkeeping.

Dot-prefixed so REPOSITORY-FILES skips it: the manifest is Loom's record of
what it wrote, not one of the team's documents, and indexing it would put
Loom's bookkeeping into the graph the team asks questions of.")

(defparameter *manifest-name* "manifest.yaml"
  "One file, holding both the choices R2 records and the output R13b records.
Two files could disagree, and removal would have to decide which to believe.")

(defparameter *marker-begin* "<!-- loom:begin -->")
(defparameter *marker-end* "<!-- loom:end -->")

(defparameter *marker-yours* "<!-- loom:yours -->"
  "Where Loom's half of the region ends and the reader's begins. DES-0044 D2.

Loom replaces what is above this line on every refresh and never reads what is
below it. A region without this marker is one Loom cannot take apart, and a
refresh says so rather than guessing -- REQ-0052 R4, whose argument is that the
author's text is the half no template can regenerate.")

(defparameter *default-endpoint* "127.0.0.1:4780"
  "Where a prepared tree is told the service is.

A parameter rather than a literal because a team runs one Loom on a shared
host, and a hard-coded localhost is the kind of thing discovered by the team
rather than by us.")

(defparameter *document-kinds*
  '(("requirements" . t) ("design" . t) ("plans" . t) ("reviews" . t) ("bugs" . t)
    ("decisions" . nil) ("arch" . nil) ("concepts" . nil) ("rules" . nil))
  "Document directory -> whether it gets a completed/ subdirectory.

The five with one are the kinds that finish: a requirement is implemented, a
plan reaches final, a bug closes. The four without are in force rather than
finished -- an accepted decision, an active rule, a named concept and a current
architecture document -- and filing them under a name meaning \"done with
these\" would bury exactly the documents `impact' exists to surface.
RULE-0007's convention, and the same table the transition command reads its
terminal statuses from.")

;;;; ==================================================================
;;;; The manifest
;;;; ==================================================================

(defun manifest-path (root)
  (merge-pathnames (format nil "~a/~a" *loom-state-directory* *manifest-name*)
                   (pathname-as-directory root)))

(defun read-manifest (root)
  "The manifest of a prepared repository, as a plist, or NIL.

Read as text and scanned rather than parsed as YAML: loom-workspace does not
depend on a YAML parser -- the analyzer does -- and the manifest's shape is
Loom's own, so a line scan is honest here in a way it would not be for a
document somebody wrote."
  (let ((path (manifest-path root)))
    (when (probe-file path)
      (let ((contents (handler-case (read-file path) (error () nil))))
        (when contents
          (let ((values '()))
            (loop with start = 0
                  with length = (length contents)
                  while (< start length)
                  do (multiple-value-bind (end next) (line-end contents start)
                       (let* ((line (subseq contents start end))
                              (colon (position #\: line)))
                         (when (and colon (plusp colon)
                                    (not (whitespace-char-p (char line 0))))
                           (push (intern (string-upcase (subseq line 0 colon)) :keyword)
                                 values)
                           (push (string-trim '(#\Space #\Tab #\Return #\")
                                              (subseq line (1+ colon)))
                                 values)))
                       (setf start next)))
            (nreverse values)))))))

(defun prepared-p (root)
  "True when this repository already carries a Loom manifest."
  (and (read-manifest root) t))

(defun record-created-path (root relative)
  "Add RELATIVE to the manifest's created list. Returns true when it did.

Init is not the only thing that writes into a prepared tree -- `architecture'
writes a document later, once there is an index to derive one from -- and R13b
is explicit that inferring init's output after the fact is not acceptable. So
anything Loom writes records itself here, or full removal meets a document it
cannot account for and refuses on it.

Found by exactly that: removal refused to complete because ARCH-0001.yaml was
not in the manifest, which is R13a protecting the tree from Loom's own output."
  (let ((manifest (read-manifest root))
        (sections (manifest-sections root)))
    (when (and manifest (not (member relative (cdr (assoc "created" sections :test #'string=))
                                     :test #'string=)))
      (write-manifest root (manifest-scalars manifest)
                      (loop for (header . entries) in sections
                            collect (if (string= "created" header)
                                        (cons header (append entries (list relative)))
                                        (cons header entries))))
      t)))

(defparameter *manifest-sections* '("created" "rendered" "templates")
  "The manifest's list-valued keys, in the order RENDER-MANIFEST emits them.

Three since DES-0044 D4, and the order is fixed so that a manifest rewritten by
RECORD-CREATED-PATH does not reorder its own sections and show up as a diff
nobody made.

`created' is REQ-0021 R13b's record of what to remove. `rendered' and
`templates' are the digests a refresh reads: what Loom wrote, and what it
rendered from.")

(defun manifest-scalars (plist)
  "PLIST without the list headers, which the line scan reads as valueless keys.

By membership in *MANIFEST-SECTIONS* rather than by an EQ test per header. The
filter used to name :CREATED alone, and adding a second list without widening
it writes `rendered: \"\"' into somebody else's manifest as a scalar beside the
real one."
  (filter-plist plist
                (lambda (key)
                  (not (member (string-downcase (symbol-name key))
                               *manifest-sections* :test #'string=)))))

(defun render-manifest (plist sections)
  "The manifest text: scalars, then each list in *MANIFEST-SECTIONS* order.

SECTIONS is an alist of header string to entries. A section with no entries is
emitted with its header and nothing under it, so a reader can tell `Loom
recorded none' from `this manifest predates the section'."
  (with-output-to-string (out)
    (format out "# Written by `loom init'. Records what Loom chose and what it~%")
    (format out "# wrote, so that removing Loom does not have to guess.~%")
    (loop for (key value) on plist by #'cddr
          do (format out "~(~a~): ~s~%" key (princ-to-string value)))
    (dolist (header *manifest-sections*)
      (let ((entry (assoc header sections :test #'string=)))
        (when entry
          (format out "~a:~%" header)
          (dolist (line (cdr entry)) (format out "  - ~s~%" line)))))))

(defun write-manifest (root plist sections)
  "Replace ROOT's manifest with PLIST and SECTIONS."
  (let ((path (manifest-path root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string (render-manifest plist sections) out))))

;;;; ==================================================================
;;;; Templates
;;;; ==================================================================

(defun template-path (name)
  (merge-pathnames (format nil "templates/~a" name)
                   (asdf:system-relative-pathname :loom-workspace "")))

(defun render-template (name substitutions)
  "The template NAME with each {{KEY}} replaced.

Templates are files in this tree rather than strings in this source, so a human
can read what a prepared workspace will be told without reading Lisp. That is
worth one path lookup: the text travels into other people's repositories and
should be reviewable as text."
  (let ((contents (read-file (template-path name))))
    (loop for (key value) on substitutions by #'cddr
          do (let ((token (format nil "{{~a}}" key)))
               (loop for at = (search token contents)
                     while at
                     do (setf contents
                              (concatenate 'string
                                           (subseq contents 0 at)
                                           value
                                           (subseq contents (+ at (length token))))))))
    contents))

(defparameter *templates*
  '("claude-md-pointer.md" "loom-skill.md" "mcp.json" "workflow-concept.yaml")
  "Every template this file renders, for the digests R6 asks be recorded.

Named rather than globbed. A directory listing would record whatever happens to
be in templates/, and the manifest's claim is about what this code rendered
from, which is a different set the moment somebody leaves a file there.")

(defun template-digests ()
  "Each template's name and the digest of its unrendered text.

REQ-0052 R6: what template version a tree was prepared from, recorded rather
than reconstructed. A refresh compares these with today's to say which
templates moved -- which is a weaker answer than naming what changed inside
them, and the honest one, since nothing keeps the old text."
  (loop for name in *templates*
        collect (manifest-entry
                 name (fnv-1a (handler-case (read-file (template-path name))
                                (error () ""))))))

(defun prep-digests (prep)
  "Each file this preparation writes, and the digest of the bytes it writes.

DES-0044 D4. An appended CLAUDE.md is recorded under `CLAUDE.md (region)' --
the spelling REMOVE-PREPARATION already prints -- and the digest is of Loom's
*half* of the region rather than of the whole of it, because that is what
UPDATE-STATE compares against later.

The two used to disagree, and the failure is the one this design is least able
to make visible: init recorded the whole region, a refresh compared Loom's half,
they never matched, and every CLAUDE.md refresh was refused with `differs from
what Loom last wrote' on a file nobody had touched. A refusal that looks exactly
like the protection working."
  (let ((root (prep-root prep)))
    (flet ((entry (path contents)
             (let ((relative (workspace-relative-path path root)))
               ;; CLAUDE.md is recorded as a region whether Loom appended it to
               ;; somebody's file or wrote the whole file, because a refresh
               ;; asks the same question of both: is Loom's half still Loom's.
               ;; A whole-file digest here would make a CLAUDE.md Loom created
               ;; unproven on its own first refresh.
               (if (string= "CLAUDE.md" relative)
                   (manifest-entry (format nil "~a (region)" relative)
                                   (fnv-1a (or (loom-half contents) contents)))
                   (manifest-entry relative (fnv-1a contents))))))
      (append (loop for (path . contents) in (prep-files prep)
                    collect (entry path contents))
              (loop for (path . contents) in (prep-appends prep)
                    collect (entry path contents))))))

;;;; ------------------------------------------------------------------
;;;; The author's half of the region (DES-0044 D2)
;;;; ------------------------------------------------------------------
;;;;
;;;; One pair of markers said "Loom wrote everything in here", and on a tree
;;;; anybody has worked in that stopped being true: game-server's region is 192
;;;; lines against a 106-line template. A third marker makes the split declared
;;;; rather than inferred, and inference is what this design refuses -- a
;;;; heading match landing inside somebody's paragraph puts a marker in the
;;;; wrong place, and the *next* refresh replaces prose Loom never wrote.

(defun split-marked-region (contents)
  "Four values: the text before the region, Loom's half, the author's half, and
whether an author marker was found.

Loom's half runs from the begin marker to the line before `loom:yours'. The
author's half runs from after that line to the end marker. Without the marker
the third value is NIL and the fourth is false, which is every tree prepared
before DES-0044 and is what a refresh reports rather than guesses at."
  (let ((begin (search *marker-begin* contents)))
    (if (null begin)
        (values contents nil nil nil)
        (let ((end (search *marker-end* contents :start2 begin)))
          (if (null end)
              ;; A begin with no end is damage somebody else caused. Refused by
              ;; reporting no region, exactly as CUT-MARKED-REGION refuses it.
              (values contents nil nil nil)
              (let ((yours (search *marker-yours* contents :start2 begin :end2 end)))
                (if (null yours)
                    (values (subseq contents 0 begin)
                            (subseq contents begin end)
                            nil nil)
                    (let ((after-yours (line-after contents yours)))
                      (values (subseq contents 0 begin)
                              (subseq contents begin yours)
                              (subseq contents after-yours end)
                              t)))))))))

(defun line-after (contents at)
  "The index just past the line AT falls on."
  (let ((newline (position #\Newline contents :start at)))
    (if newline (1+ newline) (length contents))))

;;;; ==================================================================
;;;; Ids, allocated the one way this tree allocates them
;;;; ==================================================================

;;;; ==================================================================
;;;; Plan, then apply
;;;; ==================================================================

(defun claude-md-disposition (prep)
  "What happened to CLAUDE.md: created, appended, or skipped.

Three values rather than a boolean, because removal needs to know which. A
CLAUDE.md Loom created is deleted whole; one Loom appended to has a marked
region cut out of it; one Loom skipped is not touched at all. A yes/no could
not tell the first two apart, and getting that wrong deletes somebody's file."
  (cond ((find "CLAUDE.md" (prep-appends prep)
               :key (lambda (pair) (file-namestring (car pair))) :test #'string=)
         "appended")
        ((find "CLAUDE.md" (prep-files prep)
               :key (lambda (pair) (file-namestring (car pair))) :test #'string=)
         "created")
        (t "skipped")))

(defstruct (preparation (:conc-name prep-))
  "Everything a run will do, computed before it does any of it."
  (root nil)
  (name "")
  (document-directory "docs")
  (endpoint *default-endpoint*)
  (concept-id "CON-0001")
  (directories '())     ; absolute pathnames to create
  (files '())           ; (absolute-path . contents), create-only
  (appends '())         ; (absolute-path . contents), between markers
  ;; DES-0044 D1. What an update mode rewrites: (absolute-path . contents),
  ;; written with :SUPERSEDE where FILES is written with :ERROR. A third list
  ;; rather than a flag on FILES, because the two carry opposite guarantees --
  ;; FILES may not exist and REPLACES must.
  (replaces '())
  (update nil)          ; this run refreshes rather than creates
  (skipped '())         ; (relative-path . why) -- declined or already there
  ;; PLAN-0050 S14. Domains this repository's own configuration suggests, and
  ;; what could not be read from it. Shown rather than written: every value is
  ;; a guess from a file kept for another toolchain, and the one fact that
  ;; usually matters most -- which directories resolve under node rules -- is
  ;; in neither signal. The author confirms.
  (domain-proposals '())
  (domain-notes '())
  ;; DES-0054 R10. Which frameworks.yaml template fits each Firebase codebase,
  ;; shown for the same reason as the domains and never written.
  (template-proposals '())
  (problems '()))

(defun update-state (root relative rendered-now &key region)
  "What a refresh may do to RELATIVE, and why. DES-0044 D5.

Four states, tested in this order:

    :current   the file on disk is what today's template renders -- nothing
               to do, and tested first so an up-to-date tree says so rather
               than rewriting identical bytes
    :replace   the file on disk is what Loom recorded writing, and the render
               has moved. R3's byte-identical test, passing
    :unproven  the manifest records no digest for this path, so the test
               cannot run. Every tree prepared before DES-0044
    :refused   the file differs from what Loom recorded writing (R3), or a
               CLAUDE.md region has no author marker (R4)

REGION is Loom's half of a marked region, for CLAUDE.md: the digest compared is
of that half rather than of the file, because the author's half is expected to
differ and must not make the file look modified."
  (let* ((path (merge-pathnames relative (pathname-as-directory root)))
         (contents (and (probe-file path)
                        (handler-case (read-file path) (error () nil))))
         (subject (or region contents))
         (recorded (manifest-digest root "rendered"
                                    (if region (format nil "~a (region)" relative) relative))))
    (cond ((null contents) (values :unproven "the file is not there"))
          ((string= (fnv-1a subject) (fnv-1a rendered-now))
           (values :current "already current"))
          ((null recorded)
           (values :unproven
                   "no digest recorded -- this tree was prepared before Loom kept one, \
so it cannot be shown to be unmodified"))
          ((string= (fnv-1a subject) recorded)
           (values :replace "matches what Loom last wrote"))
          (t (values :refused
                     "differs from what Loom last wrote, so replacing it would \
discard somebody's edit")))))

(defun marked-region-p (contents)
  (and contents (search *marker-begin* contents) t))

(defun loom-half (contents)
  "The part of CONTENTS' region Loom owns, or NIL when it cannot be told.

Two values, the half and whether an author marker was found, so that a caller
can distinguish `there is no region' from `there is one and it has no author
marker' -- the second is REQ-0052 R4's refusal and the first is not a refresh's
business at all."
  (multiple-value-bind (before mine yours found) (split-marked-region contents)
    (declare (ignore before yours))
    (values mine found)))

(defun replace-loom-half (contents new-half)
  "CONTENTS with Loom's half of the region replaced by NEW-HALF.

Byte for byte everywhere else, which is the whole promise: the author's half is
copied rather than rewritten, and the text outside the region is not read.

A region with no author marker keeps everything from the end marker on and gains
the marker, so a tree prepared before DES-0044 acquires it by being refreshed
once rather than by hand (BUG-0051). Reaching this at all means the digest
proved the region was Loom's, or the caller consented to replacing it whole.

NEW-HALF already ends with whatever whitespace preceded the marker in the
template, because LOOM-HALF cuts at the marker's own character and not at the
start of its line. So the marker is written bare and lands correctly indented
wherever the template put it -- at column zero in a CLAUDE.md region, and at the
body's indentation inside a document, where a line at column zero would end the
block scalar. An attempt to compute and prepend that indentation here produced
`    <!-- loom:yours -->' on the first document refreshed: four spaces, being
the template's two plus two added again."
  (let* ((begin (search *marker-begin* contents))
         (end (search *marker-end* contents :start2 begin))
         (yours (search *marker-yours* contents :start2 begin :end2 end))
         (tail (if yours (line-after contents yours) end)))
    (concatenate 'string
                 (subseq contents 0 begin)
                 new-half
                 *marker-yours* (string #\Newline)
                 (subseq contents tail))))

(defun plan-refresh (root &key replace-unproven name)
  "What refreshing an already-prepared ROOT would do. REQ-0052 R2, DES-0044 D1.

A planner of its own rather than a mode inside PLAN-PREPARATION, because the
two share almost nothing: a refresh makes no directory, allocates no id, writes
no document, and rewrites three files that must already exist where the other
writes files that must not. R7 is then structural -- there is no code path here
that names the document directory -- rather than a conditional somebody could
delete.

The substitutions come from the manifest, not from arguments. A refresh must
render what this tree was prepared with, and a caller passing a different
endpoint would silently rewrite the tree to point somewhere else."
  (let* ((root (pathname-as-directory (or (probe-file root) root)))
         (manifest (read-manifest root))
         (name (or name (getf manifest :repository)
                   (car (last (pathname-directory root))) "repository"))
         (document-directory (or (getf manifest :document-directory) "docs"))
         (endpoint (or (getf manifest :endpoint) *default-endpoint*))
         (concept-id (or (getf manifest :workflow-concept) "CON-0001"))
         (substitutions (list "DOCUMENT-DIRECTORY" document-directory
                              "ENDPOINT" endpoint
                              "ENDPOINT_URL" (format nil "http://~a" endpoint)
                              "REPOSITORY-NAME" name
                              "CONCEPT-ID" concept-id))
         (prep (make-preparation :root root :name name :update t
                                 :document-directory document-directory
                                 :endpoint endpoint :concept-id concept-id)))
    (flet ((skip (path why) (push (cons path why) (prep-skipped prep)))
           (replace-file (path contents) (push (cons path contents) (prep-replaces prep))))
      ;; --- the two whole files ------------------------------------
      (dolist (entry '((".claude/skills/loom/SKILL.md" . "loom-skill.md")
                       (".mcp.json" . "mcp.json")))
        (let* ((relative (car entry))
               (path (merge-pathnames relative root))
               (rendered (render-template (cdr entry) substitutions)))
          (multiple-value-bind (state why) (update-state root relative rendered)
            (case state
              (:current (skip relative "already current"))
              (:replace (replace-file path rendered))
              (:unproven (if replace-unproven
                             (replace-file path rendered)
                             (skip relative why)))
              (t (skip relative why))))))
      ;; --- the CLAUDE.md region -----------------------------------
      ;; The only one of the three that is shared with an author, and the only
      ;; one where a refresh can be refused for a reason other than an edit.
      (let* ((relative "CLAUDE.md")
             (path (merge-pathnames relative root))
             (existing (and (probe-file path)
                            (handler-case (read-file path) (error () nil))))
             (rendered (render-template "claude-md-pointer.md" substitutions)))
        ;; MULTIPLE-VALUE-BIND over an AND would drop the second value -- AND
        ;; returns only its last form's primary -- so the absent-file case is
        ;; tested before the split rather than folded into it.
        (multiple-value-bind (mine found)
            (if existing (loom-half existing) (values nil nil))
          (cond
            ((null existing) (skip relative "there is no CLAUDE.md to refresh"))
            ((null mine)
             (skip relative "carries no complete Loom region"))
            (t
             ;; BUG-0051. A missing author marker used to be a terminal refusal.
             ;; It is not evidence of anything on its own: the region may hold
             ;; the author's text, and it may equally hold nothing but Loom's --
             ;; which is what game-server's does now that its five sections were
             ;; moved below `loom:end' rather than below a marker inside it.
             ;; Refusing both cases meant the tree REQ-0052 was measured on could
             ;; never be refreshed by the code REQ-0052 produced.
             ;;
             ;; So the digest decides here as it does everywhere else, and the
             ;; marker's absence becomes a warning carried on the :UNPROVEN
             ;; message rather than a verdict of its own. The protection moves to
             ;; the consent, which is where DES-0044 D5 already put it for a file
             ;; Loom cannot verify.
             (multiple-value-bind (state why)
                 (update-state root relative (loom-half rendered) :region mine)
               (case state
                 (:current (skip relative "already current"))
                 (:unproven
                  (let ((why (if found
                                 why
                                 (format nil "~a, and the region has no ~a marker, ~
so all ~d lines of it would be replaced -- move anything you wrote below ~a, or ~
below a ~a marker inside the region, first"
                                         why *marker-yours* (count #\Newline mine)
                                         *marker-end* *marker-yours*))))
                    (if replace-unproven
                        (replace-file
                         path (replace-loom-half existing (loom-half rendered)))
                        (skip relative why))))
                 (:replace (replace-file
                            path (replace-loom-half existing (loom-half rendered))))
                 (t (skip relative why)))))))
      ;; --- the workflow concept -----------------------------------
      ;; BUG-0062 F3, and a reversal of DES-0044 D7 with its reason answered
      ;; rather than ignored. D7 refused to refresh this file because "it is a
      ;; document the team owns and may have edited", and that was true of a
      ;; file with no way to say which half is whose. The `loom:yours' split
      ;; D2 built for the CLAUDE.md region is that way, and it applies here
      ;; unchanged: Loom's half is regenerated, the author's is copied, and a
      ;; document carrying no marker is refused rather than guessed at.
      ;;
      ;; What D7 got right is kept. Loom still never rewrites a document it did
      ;; not write, and still never touches the front matter -- SPLIT-MARKED-
      ;; REGION's `before' is everything above `body: |', so a status, an
      ;; importance and a priority the team set survive a refresh untouched.
      (let* ((relative (format nil "~a/concepts/~a.yaml" document-directory concept-id))
             (path (merge-pathnames relative root))
             (existing (and (probe-file path)
                            (handler-case (read-file path) (error () nil))))
             (rendered (render-template "workflow-concept.yaml" substitutions)))
        (multiple-value-bind (mine found)
            (if existing (loom-half existing) (values nil nil))
          (cond
            ((null existing) (skip relative "there is no workflow concept to refresh"))
            ((null mine)
             ;; Every tree prepared before today, including the two this was
             ;; built for. Refused with the repair named, because the file is a
             ;; document and replacing it whole would take the team's own
             ;; conventions with it -- front-end's are twenty-two lines
             ;; defining what Critical means for that codebase.
             (skip relative
                   (format nil "carries no ~a marker -- it predates the split, ~
so a refresh cannot tell Loom's half from yours. Put ~a and ~a around Loom's ~
text, with anything you wrote below ~a, and refreshes will work from then on"
                           *marker-begin* *marker-begin* *marker-end*
                           *marker-yours*)))
            (t
             (multiple-value-bind (state why)
                 (update-state root relative (loom-half rendered) :region mine)
               (case state
                 (:current (skip relative "already current"))
                 (:unproven (if replace-unproven
                                (replace-file
                                 path (replace-loom-half existing (loom-half rendered)))
                                (skip relative why)))
                 (:replace (replace-file
                            path (replace-loom-half existing (loom-half rendered))))
                 (t (skip relative why)))))))))
      (setf (prep-replaces prep) (nreverse (prep-replaces prep))
            (prep-skipped prep) (nreverse (prep-skipped prep)))
      prep)))

(defparameter *firebase-python-template* "firebase-functions-python.yaml"
  "The entry-points and setting-declarations a Python Firebase codebase copies
into .loom/frameworks.yaml. Proposed by TEMPLATE-PROPOSALS, never written.")

(defparameter *firebase-js-template* "firebase-functions-js.yaml"
  "The JavaScript counterpart of *FIREBASE-PYTHON-TEMPLATE*, for an ES-module
functions tree (DES-0054 D3, R12).")

(defun template-proposals (root)
  "One plist per Firebase codebase in ROOT's firebase.json: :CODEBASE, :SOURCE,
:LANGUAGE, and either :TEMPLATE with the :TEMPLATE-PATH to copy from, or :NOTE
saying why there is none. DES-0054 R10.

A Python codebase gets the Python template and a Node one the JavaScript
template. A codebase whose language cannot be told says so rather than being given a
guess. Nothing is written, so an author reads the template and decides."
  (loop for codebase in (loom-analyzer:firebase-codebase-languages root)
        collect (append
                 (list :codebase (getf codebase :codebase)
                       :source (getf codebase :source)
                       :language (getf codebase :language))
                 (case (getf codebase :language)
                   (:python (list :template *firebase-python-template*
                                  :template-path (namestring
                                                  (template-path *firebase-python-template*))))
                   (:nodejs (list :template *firebase-js-template*
                                  :template-path (namestring
                                                  (template-path *firebase-js-template*))))
                   (t (list :note "language not recognised: no runtime, and no main.py or package.json in the source directory"))))))

(defun domain-proposal-summaries (proposals)
  "PROPOSALS, as PROPOSE-DOMAINS returns them, as the plists a report carries."
  (mapcar (lambda (proposal)
            (list :name (getf proposal :name)
                  :root (getf proposal :root)
                  :resolution (getf proposal :resolution)
                  :aliases (length (getf proposal :aliases))
                  :from (getf proposal :from)))
          proposals))

(defun plan-preparation (root &key (document-directory "docs")
                                   (endpoint *default-endpoint*)
                                   (append-claude-md nil)
                                   name)
  "What preparing ROOT would do, and every reason it could not.

Nothing here writes. Every path is resolved, every file that will be touched is
read, and every problem is collected -- so a refusal names all of them at once
and leaves the tree exactly as it was."
  (let* ((root (pathname-as-directory (or (probe-file root) root)))
         (name (or name (car (last (pathname-directory root))) "repository"))
         (docs (merge-pathnames (format nil "~a/" document-directory) root))
         (prep (make-preparation :root root :name name
                                 :document-directory document-directory
                                 :endpoint endpoint)))
    (flet ((refuse (format &rest arguments)
             (push (apply #'format nil format arguments) (prep-problems prep)))
           (skip (path why) (push (cons path why) (prep-skipped prep))))
      ;; --- directories --------------------------------------------
      ;; Every directory the preparation needs is listed; which of them did not
      ;; already exist is decided at apply time and recorded separately, because
      ;; removal may only delete the ones Loom made. game-server has a docs/
      ;; long predating any of this, and deleting it because init used it would
      ;; be the worst kind of tidy-up.
      (push (merge-pathnames (format nil "~a/" *loom-state-directory*) root)
            (prep-directories prep))
      (dolist (kind *document-kinds*)
        (let ((dir (merge-pathnames (format nil "~a/" (car kind)) docs)))
          (push dir (prep-directories prep))
          (when (cdr kind)
            (push (merge-pathnames "completed/" dir) (prep-directories prep)))))
      (setf (prep-directories prep) (nreverse (prep-directories prep)))
      ;; --- the workflow concept -----------------------------------
      (let* ((concepts (merge-pathnames "concepts/" docs))
             (concept-id (next-document-id concepts "CON"))
             (path (merge-pathnames (format nil "~a.yaml" concept-id) concepts)))
        (setf (prep-concept-id prep) concept-id)
        (if (probe-file path)
            (refuse "~a already exists." path)
            (push (cons path (render-template
                              "workflow-concept.yaml"
                              (list "CONCEPT-ID" concept-id
                                    "DOCUMENT-DIRECTORY" document-directory
                                    "DATE" (multiple-value-bind (s m h d mo y)
                                               (decode-universal-time (get-universal-time))
                                             (declare (ignore s m h))
                                             (format nil "~d-~2,'0d-~2,'0d" y mo d)))))
                  (prep-files prep))))
      ;; --- the skill ----------------------------------------------
      (let ((path (merge-pathnames ".claude/skills/loom/SKILL.md" root)))
        (if (probe-file path)
            ;; R3: a name already taken is refused, never overwritten. A
            ;; repository with a loom skill has already met Loom.
            (skip ".claude/skills/loom/SKILL.md" "already exists")
            (push (cons path (render-template
                              "loom-skill.md"
                              (list "DOCUMENT-DIRECTORY" document-directory
                                    "ENDPOINT" endpoint
                                    "ENDPOINT_URL" (format nil "http://~a" endpoint)
                                    "REPOSITORY-NAME" name
                                    "CONCEPT-ID" (prep-concept-id prep))))
                  (prep-files prep))))
      ;; --- the MCP registration -----------------------------------
      ;; Create-only, and deliberately not appended to. JSON has no comment
      ;; syntax, so there is no marker that survives a parse -- and merging
      ;; into somebody's existing server list is exactly the merge R3 forbids.
      ;; Present, it is reported and the fragment printed for a human.
      (let ((path (merge-pathnames ".mcp.json" root)))
        (if (probe-file path)
            (skip ".mcp.json" "already exists; JSON cannot carry our markers, so add the loom server by hand")
            (push (cons path (render-template "mcp.json" (list "ENDPOINT" endpoint)))
                  (prep-files prep))))
      ;; --- the CLAUDE.md pointer ----------------------------------
      (let* ((path (merge-pathnames "CLAUDE.md" root))
             (existing (and (probe-file path)
                            (handler-case (read-file path) (error () nil))))
             (text (render-template
                    "claude-md-pointer.md"
                    (list "DOCUMENT-DIRECTORY" document-directory
                          "ENDPOINT" endpoint
                          "REPOSITORY-NAME" name
                          "CONCEPT-ID" (prep-concept-id prep)))))
        (cond
          ((and existing (marked-region-p existing))
           (skip "CLAUDE.md" "already carries a Loom section"))
          ((null existing)
           ;; No CLAUDE.md at all: a new file, so R3 does not bear on it and no
           ;; consent is needed for an edit that is not one.
           (push (cons path text) (prep-files prep)))
          ((not append-claude-md)
           (skip "CLAUDE.md" "not appended -- consent was not given"))
          (t (push (cons path text) (prep-appends prep)))))
      ;; --- can any of it actually be written? ----------------------
      ;; The checks that make the plan-then-apply split worth having. A plain
      ;; file where a directory has to go, or a directory where a file has to
      ;; go, refuses the whole run rather than leaving half a tree.
      ;;
      ;; Every earlier branch above allocates around what exists -- the concept
      ;; takes the next free id, an occupied skill is skipped -- so without
      ;; these there is no reachable refusal at all, and a split that can never
      ;; refuse is a split that has never been tested.
      (dolist (dir (prep-directories prep))
        (let ((blocking (probe-file (make-pathname
                                     :name (car (last (pathname-directory dir)))
                                     :type nil
                                     :directory (butlast (pathname-directory dir))
                                     :defaults dir))))
          (when (and blocking (pathname-name blocking))
            (refuse "~a is a file, so the directory ~a cannot be created."
                    blocking dir))))
      (dolist (pair (prep-files prep))
        (when (probe-file (car pair))
          (refuse "~a already exists." (car pair)))
        (let ((parent (make-pathname :name nil :type nil :defaults (car pair))))
          (when (and (probe-file parent) (pathname-name (probe-file parent)))
            (refuse "~a is a file, so ~a cannot be written." parent (car pair)))))
      ;; PLAN-0050 S14. Read last, because it writes nothing and a failure to
      ;; read a repository's jsconfig.json must not stop it being prepared.
      (multiple-value-bind (proposals notes) (propose-domains root)
        (setf (prep-domain-proposals prep) proposals
              (prep-domain-notes prep) notes))
      (setf (prep-template-proposals prep) (template-proposals root))
      (setf (prep-files prep) (nreverse (prep-files prep))
            (prep-appends prep) (nreverse (prep-appends prep))
            (prep-skipped prep) (nreverse (prep-skipped prep))
            (prep-problems prep) (nreverse (prep-problems prep)))
      prep)))

(defun apply-refresh (prep)
  "Write what PLAN-REFRESH planned. Returns the relative paths it rewrote.

The manifest is written LAST here, and first on the create path, and the
inversion is deliberate rather than an oversight -- this file's header says the
manifest goes first so a run that dies halfway leaves removal something to work
from, and that argument is about paths, which a refresh does not change. What a
refresh writes into the manifest is digests, and a digest recorded before the
bytes it describes is a claim that the file on disk is current when it is not.
UPDATE-STATE would then read it, answer :CURRENT, and never fix the file. So the
create path records intent before acting and the refresh path records fact after
it. Do not \"correct\" this back."
  (let ((root (prep-root prep)))
    (dolist (pair (prep-replaces prep))
      (with-open-file (out (car pair) :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
        (write-string (cdr pair) out)))
    (when (prep-replaces prep)
      (let ((manifest (read-manifest root))
            (sections (manifest-sections root)))
        (write-manifest
         root (manifest-scalars manifest)
         (list (cons "created" (cdr (assoc "created" sections :test #'string=)))
               (cons "rendered" (refreshed-digests prep sections))
               (cons "templates" (template-digests))))))
    (mapcar (lambda (pair) (workspace-relative-path (car pair) root))
            (prep-replaces prep))))

(defun refreshed-digests (prep sections)
  "The `rendered:' list with this refresh's entries replacing their old ones.

Entries for paths this run did not touch are carried forward unchanged. A
refresh that rewrote two of three files must not drop the third's digest, or
the next run reads it as unproven and asks a question it already has the answer
to."
  (let* ((root (prep-root prep))
         (new (loop for (path . contents) in (prep-replaces prep)
                    collect (let ((relative (workspace-relative-path path root)))
                              (if (string= "CLAUDE.md" relative)
                                  ;; The region's digest, not the file's: the
                                  ;; author's half is expected to differ.
                                  (manifest-entry (format nil "~a (region)" relative)
                                                  (fnv-1a (loom-half contents)))
                                  (manifest-entry relative (fnv-1a contents))))))
         (names (mapcar (lambda (entry)
                          (subseq entry 0 (position #\Space entry :from-end t)))
                        new)))
    (append (remove-if (lambda (entry)
                         (let ((space (position #\Space entry :from-end t)))
                           (and space (member (subseq entry 0 space) names
                                              :test #'string=))))
                       (cdr (assoc "rendered" sections :test #'string=)))
            new)))

(defun apply-preparation (prep)
  "Write what PREP planned. Returns the relative paths it created or changed.

The manifest goes first and lists what is about to be written rather than what
was: a run that dies halfway is exactly when removal needs to know what was
intended, and a manifest written last does not exist at the moment it is
wanted."
  (let* ((root (prep-root prep))
         ;; LET* and later SETF: the directory list is appended after the
         ;; existence check below, which has to happen before they are made.
         (planned (append (mapcar (lambda (pair) (workspace-relative-path (car pair) root))
                                  (prep-files prep))
                          (mapcar (lambda (pair) (workspace-relative-path (car pair) root))
                                  (prep-appends prep)))))
    ;; Which directories did not exist is decided here, before they are made,
    ;; and recorded so removal can tell Loom's from the team's. R13b names
    ;; directories in as many words, and an empty one leaves no trace in git or
    ;; in any document's provenance -- so if it is not written down it cannot be
    ;; undone.
    (let ((made (remove-if #'probe-file
                           (append (prep-directories prep)
                                   ;; The parents of the files, which
                                   ;; ENSURE-DIRECTORIES-EXIST creates silently
                                   ;; below. .claude/skills/loom/ is the case
                                   ;; that found this: game-server already had
                                   ;; .claude/, so the skill's two intermediate
                                   ;; directories were made without appearing in
                                   ;; the plan, and full removal left them behind
                                   ;; a `git status' that looked clean.
                                   (missing-ancestors
                                    (mapcar #'car (prep-files prep)) root)))))
      (dolist (dir (prep-directories prep)) (ensure-directories-exist dir))
      (setf planned (append planned
                            (mapcar (lambda (dir)
                                      (format nil "~a/"
                                              (string-right-trim
                                               "/" (workspace-relative-path dir root))))
                                    made))))
    (write-manifest root
                    (list :repository (prep-name prep)
                          :document-directory (prep-document-directory prep)
                          :endpoint (prep-endpoint prep)
                          :workflow-concept (prep-concept-id prep)
                          :claude-md (claude-md-disposition prep))
                    (list (cons "created" planned)
                          ;; DES-0044 D4 and R6. What was written, and what it
                          ;; was rendered from, so a later refresh can ask
                          ;; whether the file on disk is still Loom's rather
                          ;; than assume it.
                          (cons "rendered" (prep-digests prep))
                          (cons "templates" (template-digests))))
    (dolist (pair (prep-files prep))
      (ensure-directories-exist (car pair))
      (with-open-file (out (car pair) :direction :output :if-exists :error
                                      :if-does-not-exist :create)
        (write-string (cdr pair) out)))
    (dolist (pair (prep-appends prep))
      (with-open-file (out (car pair) :direction :output :if-exists :append
                                      :if-does-not-exist :create)
        (format out "~%~a" (cdr pair))))
    planned))

(defun refresh-repository (root &key replace-unproven apply-changes name)
  "Refresh an already-prepared ROOT. REQ-0052 R1, DES-0044 D1. Returns a report.

Dry run unless APPLY, which is REQ-0052 R2 read literally: a refresh reports
what it would change and writes nothing until told to. The default is the safe
one for the reason R2 gives -- this run's writes are over text that already
exists -- and it is the convention `complete' already set in this tree, where a
transition with no verdicts has done nothing.

:WOULD-REPLACE is what a dry run answers with and :REPLACED is what an applied
run answers with. Two keys rather than one plus a flag, so a caller cannot read
a plan as an outcome."
  (let ((root (pathname-as-directory (or (probe-file root) root))))
    (if (not (prepared-p root))
        (list :repository (or name (car (last (pathname-directory root))))
              :root (namestring root) :update t
              :problems (list (format nil "~a carries no Loom manifest, so there is ~
nothing to refresh. Run init without --update to prepare it." root))
              :replaced '() :would-replace '() :skipped '())
        (let* ((prep (plan-refresh root :replace-unproven replace-unproven :name name))
               (planned (mapcar (lambda (pair)
                                  (workspace-relative-path (car pair) (prep-root prep)))
                                (prep-replaces prep))))
          (list :repository (prep-name prep)
                :root (namestring (prep-root prep))
                :update t
                :problems '()
                :dry-run (not apply-changes)
                :replaced (if apply-changes (apply-refresh prep) '())
                :would-replace (if apply-changes '() planned)
                :skipped (prep-skipped prep))))))

(defun prepare-repository (root &key (document-directory "docs")
                                     (endpoint *default-endpoint*)
                                     (append-claude-md nil)
                                     update replace-unproven apply-changes
                                     name)
  "Prepare ROOT for the Loom workflow. Returns a report plist.

:PROBLEMS non-empty means nothing was written. A run against an
already-prepared tree changes nothing and says so, which is REQ-0021 R11 and
R17 -- and is decided by the manifest rather than by inspecting the tree, so a
half-removed preparation is still recognised as one.

UPDATE is REQ-0052 R1: refresh a tree already prepared, rather than report that
it is. One operation with a mode rather than a second verb, because two commands
writing the same four files can disagree (DES-0044 D1). Without it the behaviour
is exactly what it was, because refusing to overwrite is right for a first run.

APPEND-CLAUDE-MD is R16's second consent and arrives as an argument because
this function must be callable from a script, a test and the service.
REPLACE-UNPROVEN is R16's third, for a file whose digest the manifest never
recorded (DES-0044 D5). The asking belongs where a terminal is.

APPLY-CHANGES turns an update from a dry run into a write. REQ-0052 R2, and the
same default `complete' uses: a refresh with nothing said about applying has
done nothing. Named in full rather than APPLY, which is an external symbol of
COMMON-LISP and cannot be bound as a variable under SBCL's package lock -- the
compile-time failure ENTITY-TYPE carries the same note about one file over."
  (cond
    (update (refresh-repository root :replace-unproven replace-unproven
                                     :apply-changes apply-changes :name name))
    ((prepared-p root)
     (multiple-value-bind (proposals notes) (propose-domains root)
       (list :repository (or name (car (last (pathname-directory (pathname-as-directory root)))))
             :root (namestring (pathname-as-directory root))
             :already-prepared t :problems '() :created '()
             :manifest (read-manifest root)
             ;; DES-0054 R10. A prepared tree is the common case for a repository
             ;; that adopts Firebase later, and used to return only its manifest.
             ;; The proposals are read from the tree as it is now, and nothing is
             ;; written.
             :domain-proposals (domain-proposal-summaries proposals)
             :domain-notes notes
             :template-proposals (template-proposals root))))
    (t
      (let ((prep (plan-preparation root
                                    :document-directory document-directory
                                    :endpoint endpoint
                                    :append-claude-md append-claude-md
                                    :name name)))
        (if (prep-problems prep)
            (list :repository (prep-name prep)
                  :root (namestring (prep-root prep))
                  :already-prepared nil
                  :problems (prep-problems prep) :created '()
                  :skipped (prep-skipped prep))
            (list :repository (prep-name prep)
                  :root (namestring (prep-root prep))
                  :already-prepared nil
                  :problems '()
                  :document-directory (prep-document-directory prep)
                  :workflow-concept (prep-concept-id prep)
                  :endpoint (prep-endpoint prep)
                  :created (apply-preparation prep)
                  :skipped (prep-skipped prep)
                  ;; PLAN-0050 S14. Carried on the report rather than written
                  ;; into the tree: these are guesses read from a file kept for
                  ;; another toolchain, and the fact that usually matters most
                  ;; -- which directories resolve under node rules -- is in
                  ;; neither signal. The author writes the declaration.
                  :domain-proposals (domain-proposal-summaries
                                     (prep-domain-proposals prep))
                  :domain-notes (prep-domain-notes prep)
                  :template-proposals (prep-template-proposals prep)))))))

;;;; ==================================================================
;;;; Taking Loom back out (REQ-0021 R13, DES-0022 S4)
;;;; ==================================================================
;;;;
;;;; Removal deletes files from a repository Loom does not own, which makes the
;;;; direction to fail in the only interesting design question. It fails toward
;;;; leaving things: the manifest is the sole authority for what init created,
;;;; nothing is inferred, and a file init *would* have written but which the
;;;; manifest does not name is left alone.
;;;;
;;;; Two modes, because "remove Loom" is two different requests. A team that
;;;; keeps its knowledge and drops the tool wants its documents untouched --
;;;; they are the point of the exercise, they are plain YAML readable with no
;;;; tool at all, and deleting them because the thing that suggested the
;;;; directory layout is going away would be the worst outcome available.

(defparameter *removal-modes* '(:tooling :all)
  ":TOOLING removes what makes Loom work here and keeps every document.
:ALL additionally removes the documents init itself wrote -- the workflow
concept and the generated architecture documents -- and nothing else.")

(defun manifest-sections (root)
  "Every list-valued section of ROOT's manifest, as (header . entries).

One scan for all of them rather than one scan per header, because a rewrite has
to carry forward the sections it is not changing and re-reading the file per
section would let two of them disagree about what it said.

A header absent from the file is absent from this alist, which is how a
manifest written before DES-0044 is told from one whose `rendered:' list is
genuinely empty. The refresh reads that difference: no section at all means no
digest was ever recorded, and that is `unproven' rather than `modified'."
  (let ((path (manifest-path root)))
    (when (probe-file path)
      (let ((contents (handler-case (read-file path) (error () nil)))
            (sections '())
            (current nil))
        (when contents
          (loop with start = 0
                with length = (length contents)
                while (< start length)
                do (multiple-value-bind (end next) (line-end contents start)
                     (let* ((line (subseq contents start end))
                            (header (and (plusp (length line))
                                         (not (whitespace-char-p (char line 0)))
                                         (let ((colon (position #\: line)))
                                           (and colon
                                                (= colon (1- (length (string-right-trim
                                                                      '(#\Return) line))))
                                                (subseq line 0 colon))))))
                       (cond (header
                              ;; A key with a colon and nothing after it is a
                              ;; list header. A scalar line has a value, so the
                              ;; colon is not last, which is what tells the two
                              ;; apart without a list of known names.
                              (setf current (cons header '()))
                              (push current sections))
                             ((and current (>= (length line) 4)
                                   (string= "  - " line :end2 4))
                              (push (string-trim '(#\" #\Space #\Return)
                                                 (subseq line 4))
                                    (cdr current)))
                             ((and (plusp (length line))
                                   (not (whitespace-char-p (char line 0))))
                              (setf current nil))))
                     (setf start next)))
          (loop for (header . entries) in (nreverse sections)
                collect (cons header (nreverse entries))))))))

(defun manifest-created-paths (root)
  "The relative paths the manifest records init as having created.
Read from the `created:' list, which APPLY-PREPARATION writes before it writes
the files, so a run that died halfway still has something to work from."
  (cdr (assoc "created" (manifest-sections root) :test #'string=)))

(defun manifest-digest (root header name)
  "The digest the manifest records for NAME under HEADER, or NIL.

Each entry is one string: the name, a space, and sixteen hex digits. One string
rather than a nested map because MANIFEST-SECTIONS reads a list of strings and
teaching the manifest reader nested YAML is more machinery than a digest is
worth (DES-0044 D4)."
  (loop for entry in (cdr (assoc header (manifest-sections root) :test #'string=))
        for space = (position #\Space entry :from-end t)
        when (and space (string= name (subseq entry 0 space)))
          return (subseq entry (1+ space))))

(defun manifest-entry (name digest)
  (format nil "~a ~a" name digest))

(defun cut-marked-region (contents)
  "Two values: CONTENTS with the Loom region removed, and whether one was found.

Byte for byte outside the region, which is the same discipline the transition
command applies to a status line and for the same reason: this is somebody
else's file and the diff should show exactly what Loom put there leaving.

The blank line the append introduced goes with it, so removing a pointer from a
file that never had one is a no-op on the bytes rather than a stray newline.

DES-0044 D6. Since the region gained a `loom:yours' marker, what lies between
that marker and the end marker is the author's and outlives removal. The cut
takes the begin marker through the end of the `loom:yours' line and the end
marker's line, and keeps everything in between. A region with no `loom:yours'
-- every tree prepared before DES-0044 -- is cut exactly as it was cut before,
which is what makes this safe to ship at those trees."
  (let ((begin (search *marker-begin* contents)))
    (if (null begin)
        (values contents nil)
        (let ((end (search *marker-end* contents :start2 begin)))
          (if (null end)
              ;; A begin with no end is damage somebody else caused, and
              ;; guessing where the region ends could delete the rest of their
              ;; file. Refused by reporting no region.
              (values contents nil)
              (let* ((after (+ end (length *marker-end*)))
                     (after (if (and (< after (length contents))
                                     (char= #\Newline (char contents after)))
                                (1+ after)
                                after))
                     ;; The blank line APPLY-PREPARATION wrote before the region.
                     (before (if (and (plusp begin)
                                      (char= #\Newline (char contents (1- begin))))
                                 (1- begin)
                                 begin))
                     (yours (search *marker-yours* contents :start2 begin :end2 end))
                     ;; The author's half, or "" where there is no marker to have
                     ;; written it below. Taken before the cut so the two cases
                     ;; differ in this value alone.
                     (kept (if yours
                               (subseq contents (line-after contents yours) end)
                               "")))
                (values (concatenate 'string (subseq contents 0 before)
                                     kept
                                     (subseq contents after))
                        t)))))))

(defun missing-ancestors (paths root)
  "Every directory under ROOT that PATHS need and that does not exist yet.

Shallowest first, so a caller creating them in order never makes a child before
its parent -- and so removal, which walks the recorded list deepest first, takes
them back in the reverse order it made them."
  (let ((root (pathname-as-directory root))
        (found '()))
    (dolist (path paths)
      (let ((directory (pathname-directory path))
            (base (pathname-directory (pathname-as-directory root))))
        (loop for n from (1+ (length base)) to (length directory)
              for candidate = (make-pathname :directory (subseq directory 0 n)
                                             :name nil :type nil :defaults path)
              unless (or (probe-file candidate)
                         (member candidate found :test #'equal))
                do (push candidate found))))
    (sort (nreverse found) #'< :key (lambda (p) (length (pathname-directory p))))))

(defun directory-entry-p (relative)
  "True when a manifest entry names a directory rather than a file.
The trailing slash is the whole distinction, and it is written by
APPLY-PREPARATION so the two never have to be told apart by probing a
filesystem that removal is in the middle of changing."
  (and (plusp (length relative))
       (char= #\/ (char relative (1- (length relative))))))

(defun document-path-p (root relative document-directory)
  "True when RELATIVE is a document under the prepared document directory."
  (declare (ignore root))
  (let ((prefix (format nil "~a/" document-directory)))
    (and (>= (length relative) (length prefix))
         (string= prefix relative :end2 (length prefix))
         (let ((type (pathname-type (pathname relative))))
           (and type (member type '("yaml" "yml") :test #'string-equal))))))

(defun unmanaged-documents (root document-directory created)
  "Documents under the document directory that the manifest does not name.

R13a's refusal. A tree whose documents were all written by hand after init is
one where full removal is nearly a no-op, and that is the correct behaviour --
so this is the list full mode stops on rather than a warning it prints."
  (let ((docs (merge-pathnames (format nil "~a/" document-directory)
                               (pathname-as-directory root)))
        (found '()))
    (dolist (path (directory (merge-pathnames "**/*.*" docs)))
      (when (pathname-name path)
        (let ((relative (workspace-relative-path path (pathname-as-directory root))))
          (when (and (document-path-p root relative document-directory)
                     (not (member relative created :test #'string=)))
            (push relative found)))))
    (nreverse found)))

(defun remove-preparation (root &key (mode :tooling))
  "Take Loom out of ROOT. Returns a report plist; :PROBLEMS non-empty means
nothing was deleted.

MODE is :TOOLING -- the skill, the MCP registration, the CLAUDE.md pointer and
the manifest, leaving every document -- or :ALL, which additionally removes the
documents init wrote and nothing else.

R13c: this writes to the working tree and does not commit, exactly as
installation did. Carrying a removal across branches is the dev team's business."
  (let* ((root (pathname-as-directory (or (probe-file root) root)))
         (manifest (read-manifest root))
         (created (manifest-created-paths root))
         (document-directory (or (getf manifest :document-directory) "docs"))
         (problems '())
         (deleted '())
         (kept '()))
    (cond
      ((null manifest)
       (list :root (namestring root) :mode mode
             :problems (list (format nil "~a carries no Loom manifest, so there is ~
nothing recorded to remove. Removal never infers what init wrote."
                                     (namestring root)))
             :deleted '()))
      ((not (member mode *removal-modes*))
       (list :root (namestring root) :mode mode
             :problems (list (format nil "~(~a~) is not a removal mode. Try: ~{~(~a~)~^, ~}"
                                     mode *removal-modes*))
             :deleted '()))
      (t
       (let ((unmanaged (and (eq :all mode)
                             (unmanaged-documents root document-directory created))))
         (when unmanaged
           (push (format nil "~d document~:p under ~a/ ~:[was~;were~] not written by ~
init, and full removal would orphan ~:*~:[it~;them~]. Remove the tooling instead, ~
or move ~:*~:[it~;them~] first:~{~%    ~a~}"
                         (length unmanaged) document-directory (rest unmanaged)
                         unmanaged)
                 problems))
         (if problems
             (list :root (namestring root) :mode mode
                   :problems (nreverse problems) :deleted '())
             ;; --- plan, then apply, as everything else here does ------
             (let ((targets
                     (loop for relative in created
                           ;; Three kinds of entry live in one list and each is
                           ;; handled somewhere else: a directory ends in a
                           ;; slash and is removed after the files, deepest
                           ;; first; CLAUDE.md is cut or deleted per the
                           ;; manifest's three-valued disposition; everything
                           ;; else is a file this loop collects.
                           for directoryp = (directory-entry-p relative)
                           for documentp = (document-path-p root relative
                                                            document-directory)
                           for path = (merge-pathnames relative root)
                           unless (or directoryp (string-equal "CLAUDE.md" relative))
                             append (cond ((and documentp (eq :tooling mode))
                                           (push relative kept) nil)
                                          ((probe-file path) (list (cons relative path)))
                                          (t (push relative kept) nil)))))
               (dolist (pair targets) (delete-file (cdr pair)) (push (car pair) deleted))
               ;; Directories Loom made, deepest first, and only when empty.
               ;; Recorded rather than derived: game-server's docs/ long
               ;; predates any of this, and removing it because init used it
               ;; would be the worst kind of tidy-up. An empty directory leaves
               ;; no trace in git either, which is why the manifest is the only
               ;; thing that can undo one.
               (when (eq :all mode)
                 (dolist (relative (sort (remove-if-not #'directory-entry-p created)
                                         #'> :key #'length))
                   (let ((dir (merge-pathnames relative root)))
                     (when (and (probe-file dir)
                                (ignore-errors (uiop:delete-empty-directory dir)))
                       (push relative deleted)))))
               ;; --- CLAUDE.md ----------------------------------------
               (let ((claude (merge-pathnames "CLAUDE.md" root))
                     (disposition (getf manifest :claude-md)))
                 (cond
                   ((not (probe-file claude)))
                   ((string-equal "created" disposition)
                    ;; Loom wrote the whole file, so the whole file goes.
                    (delete-file claude)
                    (push "CLAUDE.md" deleted))
                   ((string-equal "appended" disposition)
                    (let ((contents (read-file claude)))
                      (multiple-value-bind (without found) (cut-marked-region contents)
                        (cond (found
                               (with-open-file (out claude :direction :output
                                                           :if-exists :supersede)
                                 (write-string without out))
                               (push "CLAUDE.md (region)" deleted))
                              (t (push (format nil "CLAUDE.md carries no complete Loom ~
region, so it was left alone.")
                                       problems))))))))
               ;; --- the state directory, last ------------------------
               (let ((state (merge-pathnames (format nil "~a/" *loom-state-directory*) root)))
                 (when (probe-file (manifest-path root))
                   (delete-file (manifest-path root))
                   (push ".loom/manifest.yaml" deleted))
                 (ignore-errors (uiop:delete-empty-directory state)))
               (list :root (namestring root)
                     :mode mode
                     :problems (nreverse problems)
                     :deleted (nreverse deleted)
                     :kept (nreverse kept)))))))))
