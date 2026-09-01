;;;; Reading a path as segments.
;;;;
;;;; REV-0002 A3 and A4. PATH-SEGMENTS was defined twice, verbatim and under
;;;; the same name, in src/graph/resolve.lisp and src/analyzer/yaml-analyzer.lisp.
;;;; There was no shared home: RULE-0002 forbids loom-analyzer from reaching
;;;; loom-graph, and loom-graph does not depend on loom-analyzer.
;;;;
;;;; A dot-prefix predicate was defined three times -- DOT-PREFIXED-NAME-P in
;;;; lisp-inspector.lisp, DOT-PREFIXED-SEGMENT-P in markdown-analyzer.lisp and
;;;; DOT-PREFIXED-P in workspace.lisp. Two of those three were in one system
;;;; and had no layering excuse at all.

(in-package :loom-utils)

(defun path-segments (path)
  "PATH split on `/', keeping empty segments.

Empty segments are kept because a caller deciding what to do with them is the
point: a leading `/' produces a leading empty segment, and whether that means
`absolute' or `strip it' differs between the two callers this was written for."
  (loop with start = 0
        for slash = (position #\/ path :start start)
        collect (subseq path start (or slash (length path)))
        while slash do (setf start (1+ slash))))

(defun dot-prefixed-p (name)
  "True when NAME is a non-empty string beginning with a dot.

What separates `.git' and `.claude' from an ordinary directory name. NIL rather
than an error for a non-string, because every caller reaches this with whatever
a pathname component yielded."
  (and (stringp name) (plusp (length name)) (char= #\. (char name 0))))
