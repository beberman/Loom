;;;; Filtering a property list.
;;;;
;;;; REV-0002 A6. Four functions in four systems walked a plist by CDDR and kept
;;;; or dropped entries by a predicate: STRIP-PLIST in loom-graph,
;;;; LEAN-CONTEXT-ITEM in loom-serve, MANIFEST-SCALARS in loom-workspace and
;;;; DECLARED-PROPERTIES-ONLY in loom-graph. Three of the four differ only in
;;;; the predicate.

(in-package :loom-utils)

(defun filter-plist (plist predicate)
  "PLIST reduced to the entries whose key satisfies PREDICATE.

Keys and values travel together, which is the whole reason this is not
REMOVE-IF: a plist filtered an element at a time is no longer a plist."
  (loop for (key value) on plist by #'cddr
        when (funcall predicate key)
          append (list key value)))

(defun strip-plist (plist keys)
  "PLIST without the entries named in KEYS."
  (filter-plist plist (lambda (key) (not (member key keys)))))
