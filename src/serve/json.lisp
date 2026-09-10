;;;; Turning a loom-knowledge plist into JSON.
;;;;
;;;; This lives in loom-serve rather than in loom-rest, against DES-0006's
;;;; sentence placing JSON encoding in loom-rest, for a structural reason:
;;;; loom-mcp needs byte-identical encoding and must not depend on loom-rest.
;;;; The alternatives are duplicating the walker or making the two skins
;;;; non-peers, and both are worse than moving one function one system down.
;;;; DES-0006's own words allow it -- loom-mcp uses "whichever JSON library
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
  '(:impacted :tests :documents :mentions :decisions :possibly-affected :neighbors
    :entities :violations :rules :unresolved :repositories :values :rel-types
    ;; The keys the operations in this system emit that can legitimately be
    ;; empty: a caller iterating them should get [] rather than having to
    ;; treat null as "none".
    :unenforced :collisions :unhandled-definer-macros :items :seeds :relations
    :properties-filters :call-names
    ;; The transition report (REQ-0022). :PROBLEMS empty is the ordinary
    ;; answer and :CHANGED empty is what a dry run and an already-completed
    ;; plan both return, so all three have to encode as [] rather than null --
    ;; a client branching on "did anything happen" reads these directly.
    ;; DES-0020's context bands need nothing added: :DOCUMENTS and :MENTIONS are
    ;; already above, carrying the same meaning for the impact report that they
    ;; now carry for a bundle, which is the point of the two services sharing
    ;; one vocabulary.
    :problems :changed :blocked-by
    ;; The resemblance answers (REQ-0042, registered by BUG-0052). DES-0041 D10
    ;; is why :RESEMBLING and :ROWS cannot encode as null: a repository with no
    ;; store is already refused with a sentence, so an empty list here means
    ;; "nothing resembles this" and must not arrive looking like "this question
    ;; was not answered". The two word lists are a row's reasons, and a pair
    ;; that shares no name word and no prose word is the ordinary case -- the
    ;; whole point of the query is that a duplicate is where the names differ.
    :resembling :rows :shared-name-words :shared-prose-words
    ;; REQ-0059. A tree whose analyzers claim everything has an empty gap, and
    ;; that is the answer rather than the absence of one -- `[]' says the count
    ;; was taken and found nothing, where `null' would read as not taken.
    :by-extension
    ;; REQ-0054. An empty list is the answer that makes the band trustworthy --
    ;; "the text does not contain it either" -- so it must encode as [] rather
    ;; than as the null a caller would read as "not looked for". :LINES and not
    ;; :OCCURRENCES, which is the object holding it: a key named here forces an
    ;; array, and naming the outer one flattened the whole plist.
    :lines
    ;; REQ-0056. Both are ordinarily empty -- a tree with no federated answer
    ;; and no dangling qualified id -- and that emptiness is the answer, so
    ;; they must encode as [] rather than as a null a caller reads as absent.
    :unresolved-elsewhere :unresolved-qualified
    ;; The structural report (DES-0022 S1). Every one of these is a list that is
    ;; legitimately empty -- a tree with no protocols, or one no analyzer
    ;; claimed -- and [] against null is exactly the distinction an init script
    ;; reading this over REST has to make.
    :systems :system-edges :protocols :implementors :entry-points :hubs
    ;; The init report (DES-0022 S2). :CREATED empty is what an
    ;; already-prepared tree returns and :SKIPPED empty is the ordinary answer,
    ;; so both have to be [] -- a caller branching on "did anything happen"
    ;; reads them directly.
    :created :skipped :candidates :deleted :kept
    ;; BUG-0030 F1's drops, which are empty on a healthy tree and are the one
    ;; list here whose ordinary value is the empty one. Follows :VIOLATIONS
    ;; exactly: `check' returns the list under this key and `status' returns
    ;; its length, and a number is a number to the walker either way.
    :dropped-edges
    ;; BUG-0033. Empty on a healthy tree, like :DROPPED-EDGES beside it, and
    ;; for the same reason it must encode as [] rather than null: a client
    ;; branching on "did anything fail to parse" reads it directly.
    :unparsed
    ;; BUG-0062 F2 / BUG-0063 F4. Empty is the healthy answer and is the
    ;; answer, so it must not arrive as the null a caller reads as "not
    ;; checked". :FIELDS is the inner list of names for the same reason.
    :dropped-fields :fields
    ;; REQ-0051, DES-0043 D2. The federated `find''s three lists. :SKIPPED is
    ;; already above for the init report and carries the same meaning here.
    ;; :SEARCHED empty is a `find' issued with nothing watched, and :ELSEWHERE
    ;; empty is the ordinary answer -- a caller branching on "is this name in
    ;; another tree" reads it directly, and null would make "no" and "the key is
    ;; missing" the same JSON value.
    :searched :elsewhere)
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

(defstruct (json-false (:constructor %make-json-false))
  "The JSON literal `false', which no Lisp value in this system can express.

NIL is this encoder's third overloaded value, beside the two the file header
already names: it is false, it is the empty list, and it is absent, and until
now it always encoded as null. *ARRAY-VALUED-KEYS* separates the empty list
from the other two by asking which key the value arrived under. This separates
false, and it cannot use the same instrument -- an empty list is still a list
whatever key it came under, so a key is enough to identify it, while a false is
indistinguishable from an absent NIL by anything except what the producer meant.
So the producer says, by handing over this value instead of NIL.

Wanted because a protocol can require a boolean where this system would
naturally write NIL. MCP's tools/call result is exactly that: isError is typed
boolean, a client validates the shape before reading it, and null fails that
validation for every call including the successful ones. BUG-0028.

Deliberately not a general boolean type. `(eq x t)' already encodes true, and a
second way to spell true would let two producers disagree about which one the
encoder honours.")

(defparameter *json-false* (%make-json-false)
  "The singleton JSON-FALSE. A producer that means the literal `false' writes
this where it would otherwise write NIL.")

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
        ;; Before the NIL clause in intent though not in necessity -- a struct
        ;; is not NIL -- and before the PRINC-TO-STRING fallback, which would
        ;; otherwise render it as "#S(JSON-FALSE)".
        ((json-false-p x) x)
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
        ;; A dotted pair before anything that walks a list. BUG-0030 D2: the
        ;; three clauses below each assume a proper list -- PLIST-SHAPED-P
        ;; calls LENGTH, JSON-ARRAY calls MAP -- and both signal a TYPE-ERROR
        ;; naming the cdr on an improper one. That is a shape this encoder was
        ;; not supposed to receive, and the PRINC-TO-STRING clause at the
        ;; bottom already says what to do with those: make it visible in the
        ;; answer "rather than signalling from inside an encoder". The one
        ;; producer was NOTE-ERROR and it now writes a plist; this is what
        ;; stops the next one from taking the service down with it.
        ((improper-list-p x) (princ-to-string x))
        ((and (listp x) (member key *array-valued-keys*)) (json-array x))
        ;; PLAN-0036 S4. Was PLIST-SHAPED-P, whose docstring carried the
        ;; reasoning below; UTILS:PLISTP is the same predicate with two
        ;; differences that both have to be answered here rather than assumed.
        ;;
        ;; PLAN-0036 S4 prescribed `(and x (plistp x ...))' and never the bare
        ;; call, because PLISTP answers T for the empty list where
        ;; PLIST-SHAPED-P required a CONSP -- and NIL must encode as null
        ;; rather than as {}. The guard is not here because it cannot fire: the
        ;; (NULL X) clause above returns before this one is reached, and it has
        ;; done since BUG-0028 gave NIL three meanings to separate.
        ;;
        ;; Verified rather than reasoned. Removing the guard and running the
        ;; suite leaves LOOM-SERVE green, and the test that would catch it --
        ;; `an-empty-impact-set-is-an-empty-array', asserting (:stale nil)
        ;; encodes as null -- passes either way. A guard no test can fail
        ;; without is untested code carrying a false claim about why it exists.
        ;;
        ;; :KEY-TEST #'KEYWORDP because PLISTP defaults to SYMBOLP, and a list
        ;; of ordinary symbols is not what this encoder means by an object.
        ;;
        ;; The guess and its known hole, moved here from the deleted docstring
        ;; because an inspectable guess that has lost its record of being a
        ;; guess is worse than the duplicate it replaced. A Lisp list is either
        ;; a plist or a sequence and nothing in the value says which. Measured
        ;; against the real data it holds -- a rule's :check property, whose
        ;; outer form is an object and whose :rel-types is a three-element
        ;; array. The hole: a two-element list of keywords, such as a future
        ;; rule with rel-types [calls, contains], satisfies this and encodes as
        ;; {"calls":"contains"}. No such value exists in the tree today,
        ;; *ARRAY-VALUED-KEYS* is the escape hatch when one does, and
        ;; test/json.lisp asserts that misencoding on purpose -- CON-0001's
        ;; posture, which is to record the ambiguity and name the instance
        ;; rather than pretend the heuristic is sound.
        ((plistp x :key-test #'keywordp) (json-object-from-plist x))
        ((listp x) (json-array x))
        ((vectorp x) (json-array x))
        ;; Anything else -- a pathname, a struct, a closure. A value reaching
        ;; here is a shape loom-knowledge was not supposed to return, and
        ;; PRINC-TO-STRING makes that visible in the answer rather than
        ;; signalling from inside an encoder.
        (t (princ-to-string x))))

(defun write-json-value (value stream)
  (cond ((json-false-p value) (write-string "false" stream))
        ((json-object-p value)
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
