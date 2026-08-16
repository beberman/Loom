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

(defun split-lines (contents)
  "CONTENTS as a vector of lines, newline-separated, trailing return stripped.

A vector rather than a list because every caller here indexes by line number,
and a file is read once per request. Carriage returns are stripped so a range
served from a CRLF checkout matches one served from the same file on Linux --
the analyzer's line numbers count newlines either way."
  (let ((lines (make-array 0 :adjustable t :fill-pointer t))
        (start 0))
    (flet ((emit (end)
             (let ((line (subseq contents start end)))
               (vector-push-extend
                (if (and (plusp (length line))
                         (char= #\Return (char line (1- (length line)))))
                    (subseq line 0 (1- (length line)))
                    line)
                lines))))
      (dotimes (i (length contents))
        (when (char= #\Newline (char contents i))
          (emit i)
          (setf start (1+ i))))
      ;; A file not ending in a newline still has a last line; one that does
      ;; must not gain an empty one.
      (when (< start (length contents))
        (emit (length contents))))
    lines))

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

(defun definition-source (repository id &key (limit *source-line-limit*))
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
  :unlocated   the entity carries no line range. A :DOCUMENT is the ordinary
               case -- REQ-0007 governs what `describe' returns for one and
               R3 leaves that untouched -- and the caller reports the absence
               rather than this function guessing at a type list. BUG-0030 is
               what enumerating types costs.
  :missing     the file is gone.
  :short       the file no longer reaches :START-LINE.

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
       (let ((relative (getp entity :file))
             (start    (getp entity :start-line))
             (end      (getp entity :end-line)))
         (cond
           ((not (and relative start end)) (list :status :unlocated))
           (t
            (let ((path (merge-pathnames relative (repository-root repository))))
              (handler-case
                  (let* ((contents (slurp-file path))
                         (lines    (split-lines contents))
                         (total    (length lines)))
                    (if (> start total)
                        (list :status :short :file relative
                              :range (format nil "~d-~d" start end)
                              :indexed-at (repository-indexed-at repository))
                        ;; END may outrun a file that shrank without dropping
                        ;; below START; clamping serves what is there and the
                        ;; range reports what was served.
                        (let* ((last      (min end total))
                               (available (1+ (- last start)))
                               (shown     (min available limit))
                               (served    (+ start shown -1)))
                          (list :status (source-status repository relative path contents)
                                :file relative
                                :range (format nil "~d-~d" start served)
                                :text (with-output-to-string (out)
                                        (loop for i from (1- start) below served
                                              do (write-line (aref lines i) out)))
                                :truncated (< shown available)
                                :withheld (- available shown)
                                :indexed-at (repository-indexed-at repository)))))
                (error ()
                  ;; The file was named by the index and cannot be read now.
                  ;; Reported rather than signalled: a caller asking for source
                  ;; wants an answer about the file, and "gone" is one.
                  (list :status :missing :file relative
                        :range (format nil "~d-~d" start end)
                        :indexed-at (repository-indexed-at repository))))))))))))
