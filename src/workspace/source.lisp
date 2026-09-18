;;;; Serving the source text of a definition -- REQ-0031, DES-0027.
;;;;
;;;; REQ-0031 measured the gap this closes: one small change on game-server
;;;; cost eleven shell commands, of which five existed only to print regions of
;;;; files Loom had already named. `describe database-alert' returned
;;;; server/server.lisp:49-57 and the caller then ran `sed -n 49,57p' on the
;;;; same file.
;;;;
;;;; It lives here rather than in loom-knowledge beside DESCRIBE-ENTITY, and
;;;; DES-0027 D1 shows that is forced rather than preferred. An entity's :FILE
;;;; is repository-relative -- "src/knowledge/context.lisp" -- REPOSITORY-ROOT
;;;; is a slot on the struct in this system, and loom-workspace depends on
;;;; loom-knowledge since DES-0022 S3. So the layer holding the range cannot
;;;; reach the layer holding the root, and inverting that would be a cycle.
;;;;
;;;; This system is also the right owner on merit rather than by elimination:
;;;; it already owns every read of a watched file. INDEX-FILE slurps it,
;;;; STAMP-FILE records what was read, FILE-CHANGED-P decides when to read
;;;; again -- and the staleness answer below falls straight out of the stamp
;;;; table those maintain.

(in-package :loom-workspace)

(defparameter *source-line-limit* 400
  "Most lines DEFINITION-SOURCE will return for one entity.

REQ-0031 R6 forbids an unbounded payload and forbids silence at the limit, so
this is paired with :TRUNCATED and :WITHHELD rather than applied quietly.

400 is set by the third watched tree and could not have been chosen from the
first two. Against Lisp the cap was hypothetical -- RESOLVE-ONE is 23 lines and
DATABASE-ALERT is 9, so any plausible number was unreachable and R6 was written
about a pathological 900-line generated file. ~/github/front-end's components
are ordinary and large: LAYEREDITOR is 251 lines and MAPELEMENTTYPEEDITOR 249,
so 200 would truncate routine React work and 100 would make the operation
useless there.

A limit nothing normally reaches is the right shape for a limit whose purpose
is to stop one payload running away rather than to ration a budget. Rationing
among many entities is `context''s problem and DES-0026 D2 gives it tiers.")

(defun source-status (repository relative path contents)
  "Whether CONTENTS is what the index was built from: :CURRENT or :STALE.

The comparison is the one FILE-CHANGED-P already makes, asked after the fact
rather than before. REPOSITORY-STAMPS maps a relative path to the write date
and content hash of the bytes that were analyzed, so re-stamping what was just
read and comparing answers exactly the question REQ-0031 R4 asks a caller to be
able to settle: is the text I am holding the text Loom described?

A path with no stamp is :STALE rather than :CURRENT. Loom has no record of
having analyzed it, and claiming currency on the strength of no evidence is the
fabricated fact CON-0001 forbids -- the honest answer is that this text cannot
be vouched for."
  (let ((known (gethash relative (repository-stamps repository)))
        (now   (stamp-file path contents)))
    (if (and known
             (= (file-stamp-content-hash known) (file-stamp-content-hash now)))
        :current
        :stale)))

(defun served-text (repository relative path)
  "The text to serve for RELATIVE, and :CURRENT or :STALE. Signals when it
cannot be read, DOCSTORE-MISSING for a document the store no longer holds.

A document the index read from the store is read through the store again
(DES-0051). Its address is not a path Loom opens, and on an in-memory store it
is nowhere on disk. It is :CURRENT when the version read is the version indexed.
That is stricter than the content hash a code file is compared by: on the file
store a document saved again with the same text reads :STALE."
  (let ((entry (indexed-document repository relative)))
    (if entry
        (multiple-value-bind (text version)
            (docstore-read (repository-document-store repository) (car entry))
          (values text (if (equalp version (cdr entry)) :current :stale)))
        (let ((contents (read-file path)))
          (values contents (source-status repository relative path contents))))))

(defparameter *source-trailing-pad* 0
  "Lines served after an entity's :END-LINE.

Zero, and the zero is argued rather than lazy. REQ-0031 R9 asks for \"a small
number of lines after\", and the reason padding exists at all is that the prose
above a definition is frequently the most valuable thing about it. Nothing
symmetrical is true below: the next lines are the next definition, which the
reader can ask for by name, and DES-0027 D3's downward margin carries no claim
about what those lines mean.

Left as a parameter rather than removed, because R9 asks for it and the right
value is a measurement nobody has made. A tree where definitions end in a
closing brace on its own line might want one.")

(defun padded-start (repository relative lines start-line)
  "Where a served range should begin: the attached comment block, or START-LINE.

The analyzer decides where the block is, per DES-0027 D3a; this decides whether
to use it. :ADJACENT and :SEPARATED are taken, :SECTION is not.

D3a first said serving should take everything, on the argument that
over-including costs a reader a few tokens and CON-0006 calls that the cheap
error. Measurement moved it. A :SECTION on these trees is a box --

    ;;;; ==================================================================
    ;;;; Running the rule set
    ;;;; ==================================================================

-- and there are 124 of them above a definition on Loom and 99 on game-server.
That is not a few tokens of harmless context; prepended to a five-line function
it reads as *that function's* documentation, which is the fabricated fact
CON-0001 forbids rather than the over-inclusion CON-0006 excuses. The cheap
error stays cheap only while what is over-included is still about the subject.

So the two consumers still differ, and differ by one band rather than two:
serving takes :ADJACENT and :SEPARATED, REQ-0035 will take only :ADJACENT.

A language whose analyzer has not answered returns START-LINE unchanged: an
unpadded body is a smaller answer, where a guessed one is a wrong claim."
  (declare (ignore repository))
  (let ((analyzer (find-analyzer relative)))
    (if (null analyzer)
        start-line
        (multiple-value-bind (first attachment) (comment-extent analyzer lines start-line)
          (if (and first (member attachment '(:adjacent :separated)))
              first
              start-line)))))

(defun definition-source (repository id &key (limit *source-line-limit*) (pad t))
  "The source text of the entity ID names in REPOSITORY, as a plist.

  :status        :current :stale :missing :short :unlocated :unknown
  :text          the lines, or NIL
  :range         \"start-end\" as served
  :file          the repository-relative path
  :truncated     T when LIMIT cut the answer
  :withheld      how many lines were cut
  :indexed-at    REPOSITORY-INDEXED-AT, the generation R4 names

The four failure statuses are REQ-0031 R5, which requires that a range no
longer there be reported plainly rather than answered with a shorter region or
an empty string:

  :unknown     no such entity.
  :unlocated   the entity names no file at all -- neither a :FILE with a line
               range nor a document's :PATH. Reported rather than guessed at
               from a type list; BUG-0030 is what enumerating types costs.
  :missing     the file is gone.
  :short       the file no longer reaches :START-LINE.

A document carries a :PATH and no line range. It is served whole, from line 1,
under the same contract as a ranged entity -- :CURRENT/:STALE beside the text,
the LIMIT cap, :TRUNCATED and :WITHHELD. BUG-0059: REQ-0007 bounds what
`describe' prints of a document to a summary, and before this `describe
DES-0011 --source' had no answer but \"no line range\", so a design's argument
was unreadable through Loom. Padding is a source-analyzer notion and does not
apply, so :DEFINITION-RANGE is absent for a whole-file answer.

:STALE still returns the text, and that is deliberate. Refusing would leave the
caller holding a line range and no way to read it, which is the handoff this
whole requirement exists to remove, and DEC-0001 says the file is the truth.
What a caller must not do is mistake it for what was indexed, which is why the
status is beside the text rather than in place of it.

Nothing here re-indexes. A read operation that triggered a write would be a
surprise in the :READ tier, and the monitor already owns that job."
  (let ((entity (get-entity (repository-graph repository) id)))
    (cond
      ((null entity) (list :status :unknown))
      (t
       (let* ((relative (or (getp entity :file) (getp entity :path)))
              (start     (getp entity :start-line))
              (end       (getp entity :end-line))
              ;; A document has a :PATH and no range (BUG-0059). Serve it whole
              ;; rather than refuse; padding does not apply to a whole file.
              (whole     (and relative (not (and start end)))))
         (cond
           ((null relative) (list :status :unlocated))
           (t
            (let ((path (merge-pathnames relative (repository-root repository))))
              (handler-case
                  (multiple-value-bind (contents status)
                      (served-text repository relative path)
                    (let* ((lines (string-lines contents))
                           (total (length lines)))
                      (when whole (setf start 1 end total pad nil))
                      (if (> start total)
                          (list :status :short :file relative
                                :range (format nil "~d-~d" start end)
                                :indexed-at (repository-indexed-at repository))
                          ;; END may outrun a file that shrank without dropping
                          ;; below START; clamping serves what is there and the
                          ;; range reports what was served.
                          (let* ((from      (if pad
                                                (padded-start repository relative lines start)
                                                start))
                                 (last      (min (+ end *source-trailing-pad*) total))
                                 (available (1+ (- last from)))
                                 (shown     (min available limit))
                                 (served    (+ from shown -1)))
                            (list :status status
                                  :file relative
                                  ;; R9: the padded range, because it is what was
                                  ;; actually returned. A caller told 29-36 and
                                  ;; handed 22-38 cannot otherwise tell what it
                                  ;; read, and R4 exists so that it can.
                                  :range (format nil "~d-~d" from served)
                                  ;; The entity's own range, unchanged and beside
                                  ;; it. Padding is a property of the answer and
                                  ;; never of the entity -- nothing that reads
                                  ;; :START-LINE sees a different number. Absent
                                  ;; for a whole-file document answer, which has
                                  ;; no entity range to report.
                                  :definition-range (unless whole
                                                      (format nil "~d-~d" start end))
                                  :text (with-output-to-string (out)
                                          (loop for i from (1- from) below served
                                                do (write-line (aref lines i) out)))
                                  :truncated (< shown available)
                                  :withheld (- available shown)
                                  :indexed-at (repository-indexed-at repository))))))
                (error ()
                  ;; The file was named by the index and cannot be read now,
                  ;; or the store no longer holds the document. Reported rather
                  ;; than signalled: a caller asking for source wants an answer
                  ;; about the file, and "gone" is one.
                  ;;
                  ;; No :RANGE for a document. WHOLE means the entity carries
                  ;; none, and the range a whole-file answer reports is the one
                  ;; the read worked out -- which is what just failed.
                  (list* :status :missing :file relative
                         :indexed-at (repository-indexed-at repository)
                         (unless whole
                           (list :range (format nil "~d-~d" start end))))))))))))))
