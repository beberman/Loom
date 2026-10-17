;;;; files.lisp --- whole-file reads.
;;;;
;;;; PLAN-0061 D1. READ-FILE had three callers in three systems: synoptik-analyzer
;;;; reads source with it, synoptik-workspace reads documents and templates, and
;;;; synoptik-docstore hashes what it returns into a file stamp. synoptik-analyzer and
;;;; synoptik-docstore may not depend on each other (RULE-0011), which is this
;;;; system's entry condition, so the function lives here. It was copied from
;;;; the standalone utils library, which Synoptik no longer depends on.

(in-package #:synoptik-utils)

(defun read-file (path &key (if-does-not-exist :error))
  "The complete contents of the file at PATH as a string.

Exactly the characters read, and no more. The buffer is sized from FILE-LENGTH,
which counts bytes, so on a file with CRLF endings or any non-ASCII UTF-8 the
character count is smaller and the tail of the buffer is never written to.
Returning the whole buffer appends NULs to the contents, silently, on exactly
the files where it matters most. REQ-0001 R3.

IF-DOES-NOT-EXIST takes the values OPEN takes; :ERROR is the default so that a
missing file is not mistaken for an empty one."
  (with-open-file (in path :direction :input
                           :if-does-not-exist if-does-not-exist)
    ;; NIL when the caller passed :IF-DOES-NOT-EXIST NIL and the file is
    ;; absent; WITH-OPEN-FILE still binds the variable and still runs the body.
    (when in
      (let* ((buffer (make-string (file-length in)))
             (count (read-sequence buffer in)))
        (subseq buffer 0 count)))))
