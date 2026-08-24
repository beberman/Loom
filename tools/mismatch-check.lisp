;;;; Reject any candidate case whose query can reach its answer lexically.
;;;;
;;;;   sbcl --script tools/mismatch-check.lisp candidates.json kept.json \
;;;;        game-server=game-server.json front-end=front-end.json
;;;;
;;;; REQ-0047 R1 and R2, DES-0039 D1 and D2. A vocabulary-mismatch case is one
;;;; whose query shares no searchable token with the entity it names, and
;;;; "searchable" is a property of Loom's matcher rather than of English. So
;;;; this loads loom-knowledge and calls TASK-TOKENS, rather than reimplementing
;;;; it in the language the rest of the harness is written in: the tokenizer
;;;; changed twice on 2026-08-22 alone, and a copy of it would have been wrong
;;;; by the afternoon.
;;;;
;;;; The two sides are compared differently because SEED-MATCHES compares them
;;;; differently. A token reaches a *name* by substring, case-insensitively --
;;;; FIND-ENTITIES :NAME-LIKE is NAME-MATCHES-P is SEARCH. It reaches *prose*
;;;; as a whole word, which is DES-0028 D4's decision and the reason "latest"
;;;; does not answer "test". Checking both by token equality was this tool's
;;;; first draft and certified PIECETYPEEDITORSTATE as disjoint from "editor".
;;;;
;;;; Candidates and output are both tools/recall.py's four-tuple:
;;;; [repository, query, expected-name, family]. Nothing here writes a second
;;;; harness or a second format.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(loom-harness:load-systems "tools/mismatch-check.lisp"
                           :systems '("embed/" "ontology/" "graph/" "analyzer/" "knowledge/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :loom-knowledge)

(defpackage #:loom-mismatch-check
  (:use #:cl))
(in-package #:loom-mismatch-check)

(defun read-json (path)
  (with-open-file (in path :external-format :utf-8)
    (json:decode-json in)))

(defun field (row key)
  "ROW's KEY as a string. CL-JSON decodes an object to an alist of keywords."
  (let ((pair (assoc key row)))
    (if (and pair (stringp (cdr pair))) (cdr pair) "")))

(defun index-dump (rows)
  "The dump keyed by name: name -> list of (name . documentation).

A list and not one entry, because recall.py scores a name and several entities
may carry it. DES-0039 D2: a query sharing a word with any of them is
answerable lexically, whichever one it was written from."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row rows table)
      (let ((name (field row :name)))
        (when (plusp (length name))
          (push (cons name (field row :documentation)) (gethash name table)))))))

(defun reaches-name-p (token name)
  "True when TOKEN reaches NAME the way FIND-ENTITIES :NAME-LIKE does.
NAME-MATCHES-P, restated here rather than called, because it takes an entity
and this has a string from a dump."
  (and (search token name :test #'char-equal) t))

(defun reaches-prose-p (token documentation)
  "True when TOKEN reaches DOCUMENTATION the way SEED-MATCHES' prose pass does:
a whole word of PLAIN-WORDS, never a substring."
  (and (member token (loom-knowledge::plain-words documentation) :test #'string=)
       t))

(defun overlap (query entries)
  "The first reason QUERY is not disjoint from ENTRIES, or NIL.

A list of (token place name), where place is :NAME or :PROSE. First and not
all: the case is rejected either way, and one reason is what a person rewriting
the query needs."
  (dolist (token (loom-knowledge::task-tokens query))
    (dolist (entry entries)
      (destructuring-bind (name . documentation) entry
        (when (reaches-name-p token name)
          (return-from overlap (list token :name name)))
        (when (and (plusp (length documentation))
                   (reaches-prose-p token documentation))
          (return-from overlap (list token :prose name)))))))

(defun check (candidates-path output-path dumps)
  (let ((candidates (read-json candidates-path))
        (indexes (make-hash-table :test #'equal))
        (kept '())
        (rejected 0)
        (unknown 0))
    (loop for (repository . path) in dumps
          do (setf (gethash repository indexes) (index-dump (read-json path))))
    (dolist (case candidates)
      (destructuring-bind (repository query expected family) case
        (let* ((index (gethash repository indexes))
               (entries (and index (gethash expected index))))
          (cond
            ((null index)
             (incf unknown)
             (format t "~&UNKNOWN REPOSITORY  ~a  ~a~%" repository expected))
            ;; A name no entity carries is rejected loudly. It is trivially
            ;; disjoint from everything, can never hit, and would sit in the
            ;; family looking like a hard question forever. PLAN-0042 S2.
            ((null entries)
             (incf unknown)
             (format t "~&NO SUCH NAME        ~a  ~a~%" repository expected))
            (t
             (let ((reason (overlap query entries)))
               (if reason
                   (progn
                     (incf rejected)
                     (format t "~&REJECT ~(~a~) via ~a   ~a~%           ~a~%"
                             (second reason) (first reason) expected query))
                   (push (list repository query expected family) kept))))))))
    (setf kept (nreverse kept))
    (with-open-file (out output-path :direction :output :if-exists :supersede
                                     :external-format :utf-8)
      (json:encode-json kept out)
      (terpri out))
    (format t "~&~%kept ~d   rejected ~d   unresolvable ~d   of ~d candidates~%"
            (length kept) rejected unknown (length candidates))
    (format t "~&wrote ~a~%" output-path)))

(let ((args (rest sb-ext:*posix-argv*)))
  (when (< (length args) 3)
    (error "Usage: mismatch-check.lisp <candidates.json> <kept.json> <repo>=<dump.json> ..."))
  (check (first args)
         (second args)
         (loop for spec in (cddr args)
               for equals = (position #\= spec)
               unless equals do (error "expected <repo>=<dump.json>, got ~a" spec)
                 collect (cons (subseq spec 0 equals) (subseq spec (1+ equals))))))
