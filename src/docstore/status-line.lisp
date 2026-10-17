;;;; The top-level status line: finding it, reading it, replacing it.
;;;;
;;;; DES-0051 N3 and PLAN-0055 step 7. These were transition.lisp's and moved
;;;; down when the stores took over the write. Both stores need them: setting a
;;;; status is an edit to one line of a document's text, and text is what every
;;;; store holds. Nothing here opens a file or knows what a repository is.
;;;;
;;;; The rule the whole file rests on is STATUS-KEY-LINE-P's: a top-level key
;;;; of a YAML mapping is at column zero, and a block scalar's content must be
;;;; indented past the key that introduces it. So `status:' at column zero is
;;;; the document's own field, and every `status:' a document writes in prose
;;;; is invisible here by construction.

(in-package #:synoptik-docstore)

(defun whitespace-char-p (character)
  (member character '(#\Space #\Tab #\Return #\Newline #\Page)))

(defun line-end (contents start)
  "Two values: the index just past the last character of the line beginning at
START, and the index the next line begins at."
  (let ((newline (position #\Newline contents :start start)))
    (if newline
        (values newline (1+ newline))
        (values (length contents) (length contents)))))

(defun status-key-line-p (line)
  "True when LINE is a top-level `status:' key.

Column zero is the whole test, and it is not a heuristic. A block scalar's
content must be indented more than the key that introduces it, and every
top-level key of a YAML mapping sits at column zero, so a line whose first
character is not whitespace is not inside a block scalar. `status:' at column
zero is therefore the document's own status field, and the ones this file's
sibling documents write in prose -- indented under a summary: or a body: -- are
invisible here by construction.

Case-sensitive, because YAML keys are: `Status:' is a different key and
silently treating it as this one would edit a field nothing reads."
  (let ((key "status:"))
    (and (>= (length line) (length key))
         (string= key line :end2 (length key))
         (not (whitespace-char-p (char line 0))))))

(defun status-line-value (line)
  "The status LINE declares, as a keyword, or NIL when it declares none.

The trailing comment is dropped rather than parsed: YAML starts one at a `#'
preceded by whitespace, and CON-0004's own bug template writes
`status: open              # closed once fixed'. Reading the comment as part of
the value would make every such document's status unrecognisable."
  (let* ((rest (subseq line (length "status:")))
         (comment (loop for i from 0 below (length rest)
                        when (and (char= #\# (char rest i))
                                  (or (zerop i) (whitespace-char-p (char rest (1- i)))))
                          return i))
         (text (string-trim '(#\Space #\Tab #\Return)
                            (subseq rest 0 (or comment (length rest))))))
    (when (plusp (length text))
      (intern (string-upcase text) :keyword))))

(defun top-level-status-line (contents)
  "Three values for CONTENTS: the character range of its top-level status line
and the status that line declares. NIL when there is none.

The first such line and not the only one: a well-formed YAML mapping cannot
have two, and a document that somehow does is one where editing the first is
the same choice a parser makes."
  (loop with length = (length contents)
        with start = 0
        while (< start length)
        do (multiple-value-bind (end next) (line-end contents start)
             (let ((line (subseq contents start end)))
               (when (status-key-line-p line)
                 (return (values start end (status-line-value line)))))
             (setf start next))
        finally (return nil)))

(defun replace-status-line (contents start end status)
  "CONTENTS with the line between START and END replaced by one declaring STATUS.

Everything outside the range is copied through untouched, which is what makes a
completed plan's diff one changed line. A carriage return at the end of the old
line is carried onto the new one, so a CRLF file does not acquire one mixed
ending where the edit landed."
  (let ((crlf (and (> end start) (char= #\Return (char contents (1- end))))))
    (concatenate 'string
                 (subseq contents 0 start)
                 (format nil "status: ~(~a~)" status)
                 (if crlf (string #\Return) "")
                 (subseq contents end))))
