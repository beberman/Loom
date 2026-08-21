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
        (created (manifest-created-paths root)))
    (when (and manifest (not (member relative created :test #'string=)))
      (with-open-file (out (manifest-path root) :direction :output
                                                :if-exists :supersede
                                                :if-does-not-exist :create)
        (write-string (render-manifest
                       ;; :CREATED is the list header the line scan reads as a
                       ;; valueless key; it is re-emitted by RENDER-MANIFEST and
                       ;; must not also appear as a scalar.
                       (loop for (key value) on manifest by #'cddr
                             unless (eq key :created)
                               append (list key value))
                       (append created (list relative)))
                      out))
      t)))

(defun render-manifest (plist created)
  (with-output-to-string (out)
    (format out "# Written by `loom init'. Records what Loom chose and what it~%")
    (format out "# wrote, so that removing Loom does not have to guess.~%")
    (loop for (key value) on plist by #'cddr
          do (format out "~(~a~): ~s~%" key (princ-to-string value)))
    (format out "created:~%")
    (dolist (path created) (format out "  - ~s~%" path))))

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

;;;; ==================================================================
;;;; Ids, allocated the one way this tree allocates them
;;;; ==================================================================

(defun next-document-id (directory prefix)
  "The next free PREFIX id in DIRECTORY, as PREFIX-nnnn.

REQ-0021 R14 as amended: init allocates through whatever allocator the tree
has, and where none is reachable it uses REQ-0025 R6's own fallback -- the
highest id in this checkout plus one. What it may not do is invent a third
rule, because two allocation rules in one tree is how a counter stops being
trustworthy. When REQ-0025's operation exists this function calls it instead."
  (let ((highest 0))
    (dolist (path (append (directory (merge-pathnames "*.yaml" directory))
                          (directory (merge-pathnames "completed/*.yaml" directory))))
      (let* ((name (pathname-name path))
             (dash (position #\- name :from-end t)))
        (when (and dash (string-equal prefix (subseq name 0 dash)))
          (let ((n (parse-integer name :start (1+ dash) :junk-allowed t)))
            (when (and n (> n highest)) (setf highest n))))))
    (format nil "~a-~4,'0d" prefix (1+ highest))))

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
  (skipped '())         ; (relative-path . why) -- declined or already there
  (problems '()))

(defun marked-region-p (contents)
  (and contents (search *marker-begin* contents) t))

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
      (setf (prep-files prep) (nreverse (prep-files prep))
            (prep-appends prep) (nreverse (prep-appends prep))
            (prep-skipped prep) (nreverse (prep-skipped prep))
            (prep-problems prep) (nreverse (prep-problems prep)))
      prep)))

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
    (let ((manifest (manifest-path root)))
      (ensure-directories-exist manifest)
      (with-open-file (out manifest :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
        (write-string (render-manifest
                       (list :repository (prep-name prep)
                             :document-directory (prep-document-directory prep)
                             :endpoint (prep-endpoint prep)
                             :workflow-concept (prep-concept-id prep)
                             :claude-md (claude-md-disposition prep))
                       planned)
                      out)))
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

(defun prepare-repository (root &key (document-directory "docs")
                                     (endpoint *default-endpoint*)
                                     (append-claude-md nil)
                                     name)
  "Prepare ROOT for the Loom workflow. Returns a report plist.

:PROBLEMS non-empty means nothing was written. A run against an
already-prepared tree changes nothing and says so, which is REQ-0021 R11 and
R17 -- and is decided by the manifest rather than by inspecting the tree, so a
half-removed preparation is still recognised as one.

APPEND-CLAUDE-MD is R16's second consent and arrives as an argument because
this function must be callable from a script, a test and the service. The
asking belongs where a terminal is."
  (if (prepared-p root)
      (list :repository (or name (car (last (pathname-directory (pathname-as-directory root)))))
            :root (namestring (pathname-as-directory root))
            :already-prepared t :problems '() :created '()
            :manifest (read-manifest root))
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
                  :skipped (prep-skipped prep))))))

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

(defun manifest-created-paths (root)
  "The relative paths the manifest records init as having created.
Read from the `created:' list, which APPLY-PREPARATION writes before it writes
the files, so a run that died halfway still has something to work from."
  (let ((path (manifest-path root)))
    (when (probe-file path)
      (let ((contents (handler-case (read-file path) (error () nil)))
            (paths '())
            (in-list nil))
        (when contents
          (loop with start = 0
                with length = (length contents)
                while (< start length)
                do (multiple-value-bind (end next) (line-end contents start)
                     (let ((line (subseq contents start end)))
                       (cond ((and (>= (length line) 8)
                                   (string= "created:" line :end2 8))
                              (setf in-list t))
                             ((and in-list (>= (length line) 4)
                                   (string= "  - " line :end2 4))
                              (push (string-trim '(#\" #\Space #\Return)
                                                 (subseq line 4))
                                    paths))
                             ((and in-list (plusp (length line))
                                   (not (whitespace-char-p (char line 0))))
                              (setf in-list nil))))
                     (setf start next)))
          (nreverse paths))))))

(defun cut-marked-region (contents)
  "Two values: CONTENTS with the Loom region removed, and whether one was found.

Byte for byte outside the region, which is the same discipline the transition
command applies to a status line and for the same reason: this is somebody
else's file and the diff should show exactly what Loom put there leaving.

The blank line the append introduced goes with it, so removing a pointer from a
file that never had one is a no-op on the bytes rather than a stray newline."
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
                                 begin)))
                (values (concatenate 'string (subseq contents 0 before)
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
