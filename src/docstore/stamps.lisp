;;;; File stamps: what a poll compares a file against to decide whether it moved.
;;;;
;;;; Moved from src/workspace/workspace.lisp by DES-0051 D5. The file store's
;;;; versions are stamps, and synoptik-workspace's code tier keeps using them from
;;;; here. synoptik-workspace depends on synoptik-docstore, so the shared home is this
;;;; lower system rather than synoptik-utils.

(in-package #:synoptik-docstore)

(defparameter *mtime-settle-seconds* 2
  "How old a write date has to be before an unchanged one is believed.

FILE-WRITE-DATE counts in whole seconds, so a file edited in the same second
the index read it carries the same write date afterwards and the edit is
invisible to any comparison of write dates alone. That is not a rare race: it
is what happens every time a developer saves twice quickly, and every time a
test writes a fixture and immediately polls it. Within this window the poll
stops trusting the clock and compares content instead.")

(defstruct (file-stamp (:constructor make-file-stamp (write-date content-hash)))
  "What a poll compares a file against to decide whether it moved."
  (write-date 0)
  (content-hash 0))

(defun stamp-file (path contents)
  "The stamp of CONTENTS, read from PATH.

The hash is of CONTENTS, not of what PATH holds now. A caller reads a file once
and hands the same text to the analyzer and to this function, so the stamp
describes what was analyzed."
  (make-file-stamp (or (ignore-errors (file-write-date path)) 0) (sxhash contents)))

(defun stamp-changed-p (known path now)
  "True when PATH needs reading again. KNOWN is the stamp of the text last read
from it, or NIL if it has never been read.

Cheap in the common case and correct in the case that matters. An unseen file
or a moved write date is a change and costs one stat. An unchanged write date
older than *MTIME-SETTLE-SECONDS* is believed, so a steady tree costs nothing
but stats. Only inside the settle window -- where the write date cannot answer
the question -- is the file read and hashed."
  (let ((write-date (ignore-errors (file-write-date path))))
    (cond ((null write-date) nil)      ; unreadable now; leave the index alone
          ((null known) t)             ; never read
          ((not (eql write-date (file-stamp-write-date known))) t)
          ((> (- now write-date) *mtime-settle-seconds*) nil)
          (t (not (eql (file-stamp-content-hash known)
                       (sxhash (handler-case (read-file path)
                                 (error () ""))))))))) ; unreadable => reread
