;;;; Turning a loom-knowledge plist into JSON.
;;;;
;;;; This lives in loom-serve rather than in loom-rest, against ARCH-0006's
;;;; sentence placing JSON encoding in loom-rest, for a structural reason:
;;;; loom-mcp needs byte-identical encoding and must not depend on loom-rest.
;;;; The alternatives are duplicating the walker or making the two skins
;;;; non-peers, and both are worse than moving one function one system down.
;;;; ARCH-0006's own words allow it -- loom-mcp uses "whichever JSON library
;;;; loom-rest uses" -- and the substance it commits to, that neither protocol
;;;; system contains business logic, is untouched: a data-shape translation
;;;; shared by both skins is exactly what loom-serve is for.
;;;;
;;;; Three things cl-json does on its own that this file exists to correct, all
;;;; measured rather than assumed:
;;;;
;;;;   (json:encode-json-plist-to-string '(:outer (:inner 1) :n 2))
;;;;       => {"outer":["inner",1],"n":2}
;;;;   (json:encode-json-to-string :rule-violation)   => "ruleViolation"
;;;;   (json:encode-json-to-string nil)               => null
;;;;
;;;; The first is why the walker exists at all: the plist encoder is one level
;;;; deep, and DESCRIBE-ENTITY's result has a plist under :entity, a plist
;;;; under :properties, a plist under :document and a list of plists under
;;;; :neighbors, every one of which would reach a client as an array of
;;;; alternating keys and values. The second is why key naming is pinned here:
;;;; :full-tokens would arrive as "fullTokens" and :rel-type as "relType",
;;;; which is a vocabulary nobody wrote down and nobody can predict from the
;;;; console. The third is why *ARRAY-VALUED-KEYS* exists: an empty impact set
;;;; and an absent one are the same Lisp value and must not be the same JSON
;;;; one.
;;;;
;;;; The emitter writes its own braces and brackets rather than handing cl-json
;;;; a hash table. cl-json encodes a hash table as an object, but in MAPHASH
;;;; order, and hash-table iteration order is implementation-defined -- the
;;;; class of detail this codebase has already been bitten by once
;;;; (FILE-POSITION on a bounded string stream). Key order in an answer a human
;;;; reads should be the order the plist was written in. cl-json still encodes
;;;; every scalar, which is where the escaping lives and where a hand-rolled
;;;; version would actually go wrong.

(in-package :loom-serve)

(defparameter *array-valued-keys*
  '(:impacted :tests :documents :decisions :possibly-affected :neighbors
    :entities :violations :rules :unresolved :repositories :values :rel-types
    ;; The keys the operations in this system emit that can legitimately be
    ;; empty: a caller iterating them should get [] rather than having to
    ;; treat null as "none".
    :unenforced :collisions :unhandled-definer-macros :items :seeds :relations
    :properties-filters :call-names)
  "Keys whose value is a sequence even when it is empty.

Two jobs. NIL under one of these encodes as [] rather than null, so an empty
impact set and an absent one are different JSON values. And a list under one of
these is an array whatever its shape, which is the escape hatch for
PLIST-SHAPED-P's known hole -- :rel-types is here for exactly that reason
rather than for an empty-list case.")

(defun default-json-key-name (name)
  "NAME downcased, unless it was written in mixed case on purpose.

The reader upcases an unescaped keyword, so :full-tokens arrives here as
\"FULL-TOKENS\" and must be downcased -- otherwise every key in every answer
shouts. A keyword written with escapes, :|inputSchema|, keeps the case its
author typed, and the only reason to type it that way is that some protocol
requires that exact spelling: MCP's tool schema keys are camelCase and are not
this system's to rename. So: all-uppercase means the reader chose the case and
this function may change it; anything else means a human chose it and this
function may not."
  (if (every (lambda (character)
               (or (not (alpha-char-p character)) (upper-case-p character)))
             name)
      (string-downcase name)
      name))

(defparameter *json-key-name* #'default-json-key-name
  "How a keyword becomes a JSON key.

A variable rather than an inlined call so the vocabulary a client sees is
pinned in one visible place. It is deliberately not cl-json's
*LISP-IDENTIFIER-NAME-TO-JSON*: nothing here ever hands cl-json a symbol, so no
special variable of its is load-bearing and no caller can change the spelling
of :full-tokens by rebinding one.")

(defun json-key-name (key)
  (funcall *json-key-name* (symbol-name key)))

(defstruct (json-object (:constructor make-json-object (members)))
  "An object with its members in the order the plist wrote them.
A struct rather than an alist because an alist is indistinguishable from data
the walker is supposed to encode as an array."
  (members '()))

(defun plist-shaped-p (list)
  "True when LIST should be read as a plist rather than as a sequence.

A Lisp list is either a plist or a sequence and nothing in the value says
which, so this is a guess and is written to be an inspectable one: non-empty,
even length, every even-indexed element a keyword. Measured against the real
data it holds -- a rule's :check property is (:kind :no-edge :from-system
:loom-ontology :to-system :outside :rel-types (:calls :imports :depends-on)),
whose outer form is an object and whose :rel-types is a three-element array.

It has one known hole, recorded here rather than discovered later: a two-element
list of keywords, such as a future rule with rel-types [calls, contains],
satisfies this and encodes as {\"calls\":\"contains\"}. No such value exists in
the tree today. *ARRAY-VALUED-KEYS* is the escape hatch when one does, and
test/json.lisp asserts the misencoding on purpose -- CON-0001's posture, which
is to record the ambiguity and name the instance rather than pretend the
heuristic is sound."
  (and (consp list)
       (evenp (length list))
       (loop for rest on list by #'cddr always (keywordp (car rest)))))

(defun json-array (sequence)
  "SEQUENCE as a vector of encoded elements.

A vector rather than a list because cl-json encodes NIL as null, so an empty
list would vanish into the very ambiguity *ARRAY-VALUED-KEYS* exists to
prevent. Elements are walked without a key: an element has no name, and passing
the parent's name down would make a NIL element of :impacted encode as []."
  (map 'vector (lambda (element) (json-value element)) sequence))

(defun json-object-from-plist (plist)
  (make-json-object
   (loop for (key value) on plist by #'cddr
         collect (cons (json-key-name key) (json-value value key)))))

(defun json-value (x &optional key)
  "X as something ENCODE-RESULT can write. KEY is the plist key X arrived under."
  (cond ((keywordp x) (string-downcase (symbol-name x)))
        ((stringp x) x)
        ((numberp x) x)
        ((eq x t) t)
        ((null x) (if (member key *array-valued-keys*) #() nil))
        ((hash-table-p x)
         ;; Sorted by key, because a hash table has no order of its own and an
         ;; arbitrary one would change between runs of the same request.
         (make-json-object
          (let ((members '()))
            (maphash (lambda (k v)
                       (push (cons (if (keywordp k) (json-key-name k) (princ-to-string k))
                                   (json-value v (and (keywordp k) k)))
                             members))
                     x)
            (sort members #'string< :key #'car))))
        ((and (listp x) (member key *array-valued-keys*)) (json-array x))
        ((plist-shaped-p x) (json-object-from-plist x))
        ((listp x) (json-array x))
        ((vectorp x) (json-array x))
        ;; Anything else -- a pathname, a struct, a closure. A value reaching
        ;; here is a shape loom-knowledge was not supposed to return, and
        ;; PRINC-TO-STRING makes that visible in the answer rather than
        ;; signalling from inside an encoder.
        (t (princ-to-string x))))

(defun write-json-value (value stream)
  (cond ((json-object-p value)
         (write-char #\{ stream)
         (loop for member in (json-object-members value)
               for first = t then nil
               do (unless first (write-char #\, stream))
                  ;; The name is already a string, so cl-json quotes and
                  ;; escapes it without any naming rule of its own applying.
                  (json:encode-json (car member) stream)
                  (write-char #\: stream)
                  (write-json-value (cdr member) stream))
         (write-char #\} stream))
        ((and (vectorp value) (not (stringp value)))
         (write-char #\[ stream)
         (loop for element across value
               for first = t then nil
               do (unless first (write-char #\, stream))
                  (write-json-value element stream))
         (write-char #\] stream))
        (t (json:encode-json value stream))))

(defun encode-result (value)
  "VALUE as a JSON string. The one encoder both skins call."
  (with-output-to-string (stream)
    (write-json-value (json-value value) stream)))
