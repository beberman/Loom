;;;; The Lisp analyzer's reader, and the only file in the tree that names
;;;; Eclector. DES-0013.
;;;;
;;;; The whole design is one decision: the parse result Synoptik asks Eclector to
;;;; build IS the ordinary s-expression. MAKE-EXPRESSION-RESULT returns its
;;;; RESULT argument unchanged, so what reaches ANALYZE-FILE's walk is conses,
;;;; symbols, numbers and strings exactly as CL:READ would have produced --
;;;; every SYMBOLP, KEYWORDP and TOKEN-NAME decision in lisp-analyzer.lisp
;;;; keeps working, natural keys do not move, and parity is the default rather
;;;; than something to be re-established by argument.
;;;;
;;;; Everything the s-expression cannot carry is recorded beside it in tables
;;;; keyed by EQ on the conses of that same tree. That is sound because
;;;; Eclector conses each form fresh, so every form in a file is a distinct
;;;; object. It is deliberately not offered for atoms: a symbol or a fixnum is
;;;; not unique, and a span table keyed on one would attribute the last
;;;; occurrence's range to all of them. Only conses get ranges, which is what
;;;; the walk needs -- a range is wanted for a form, never for a token.
;;;;
;;;; Nothing here knows what an entity is. It emits no ontology operation and
;;;; reads nothing from the graph. The library's spelling is confined here on
;;;; the DES-0011 precedent that nothing outside lisp-inspector.lisp knows
;;;; what SBCL is: DES-0013 R1 asserts that no ECLECTOR symbol appears in any
;;;; other file.

(in-package :synoptik-analyzer)

;;;; ------------------------------------------------------------------
;;;; What a read produces
;;;; ------------------------------------------------------------------

(defstruct (reading (:conc-name reading-))
  "One file's read, as plain data.

FORMS keeps the four-element tuple (FORM START-LINE END-LINE START-OFFSET)
that READ-FORMS-WITH-SPANS returned before this file existed. START-OFFSET no
longer has a consumer -- ELEMENT-SPANS was its only one and ELEMENT-SPANS is
gone -- but DES-0010 R1 named the widened tuple as a requirement and removing
an element to save one cons per top-level form would break it for no gain. It
is vestigial and says so.

SPANS maps a cons to (START-LINE . END-LINE). PACKAGES maps a symbol to the
package designator written at the site, as a string, and holds an entry only
where a prefix was actually written. READER-MACROS maps a cons to :FUNCTION or
:QUOTE when the reader built it from #' or ' rather than the program writing
the list out. SKIPS and RECOVERED are ordered oldest-first. FATAL is the
condition when the file could not be read at all, which is the only case
MAKE-UNPARSABLE-FILE-ENTITY still answers."
  (forms '())
  (spans (make-hash-table :test #'eq))
  (packages (make-hash-table :test #'eq))
  (reader-macros (make-hash-table :test #'eq))
  (skips '())
  (recovered '())
  (fatal nil))

(defun form-range (reading form)
  "FORM's line range as (VALUES START-LINE END-LINE FOUNDP).

FOUNDP is NIL for an atom, which has no range because it is not a form, and
for a cons the reader did not record -- which after this design can happen only
through reader-level structure sharing, where #1=(...) referenced by #1# makes
one cons appear twice and the table keeps whichever range was written last.
Zero occurrences in either indexed tree. The caller's declared fallback stays
what DES-0010 R4 chose, the containing form's range: a wider truth rather than
a fabricated one (CON-0001)."
  (let ((range (and (consp form) (gethash form (reading-spans reading)))))
    (if range
        (values (first range) (second range) t)
        (values nil nil nil))))

(defun form-package (reading symbol)
  "The package designator written at SYMBOL's site, as a lowercase string, or
NIL when the site wrote no prefix.

The fact INTERN-FOREIGN-SYMBOL-LOCALLY used to destroy. `utils:parse-config'
and a local PARSE-CONFIG were indistinguishable by the time the walk saw them,
because TOKEN-NAME reads SYMBOL-NAME and nothing else; the prefix is evidence
about which definition a call means and REQ-0019 R2 is that it stops being
thrown away. What resolution does with it is REQ-0015's question, not this
file's -- nothing here resolves anything."
  (and (symbolp symbol) (gethash symbol (reading-packages reading))))

(defun form-reader-macro (reading form)
  "The reader macro that produced FORM -- :FUNCTION for #'x, :QUOTE for 'x --
or NIL when the program wrote the list out itself.

The one class of form kind a reader is entitled to know, because reader macros
really are syntax where DEFUN is not (DES-0013, WHY DEFINITION-P SURVIVES).
It exists so COLLECT-CALL-NAMES can stop guessing from a name: a one-argument
(some-pkg:function g) matches its quotation test today and contributes \"g\",
and (some-pkg:quote x) is taken for quoted data so its contents go unwalked."
  (and (consp form) (gethash form (reading-reader-macros reading))))

(defun form-backquote-p (form)
  "True when FORM is what the reader built from a backquote: a one-element
template headed by Eclector's own QUASIQUOTE.

Asked of the symbol rather than of its name because the walk uninterns every
other symbol it reads, so a program that wrote (quasiquote x) out itself has a
head that is not this one. A backquoted form is data (DES-0055 D10), and
without this its expansion would read as a call. It lives here because this is
the one file that names the library (DES-0013 R1)."
  (and (consp form) (eq (car form) 'eclector.reader:quasiquote)))

(defun skip-reason-name (reason)
  "REASON as a stable lowercase string, or NIL for a reason with no name.

Eclector spells a reason three ways: a bare keyword (:BLOCK-COMMENT,
:READ-EVAL), a cons of marker and detail for a feature expression
\((:SHARPSIGN-PLUS . :SBCL)), and a cons of marker and a count for a line
comment ((:LINE-COMMENT . 2), the 2 being the number of semicolons). Only the
marker is stable enough to record: the detail of a feature expression is an
uninterned symbol under the symbol policy above unless the site wrote a
keyword, and an uninterned symbol is a different object on every read, so
storing it would put a value in the graph that no two indexings agree on."
  (let ((marker (if (consp reason) (car reason) reason)))
    (and (symbolp marker) marker (string-downcase (symbol-name marker)))))

(defun skip-suppresses-source-p (skip)
  "True when SKIP is source the reader passed over, rather than commentary.

The discrimination step 5 of PLAN-0013 needs, and it is not optional: measured
on this tree, READING-SKIPS is 4513 line comments against 2 feature-suppressed
sites, so recording skips undifferentiated would put four and a half thousand
entries describing ordinary comments into the index and bury the two that say
a definition is missing. A comment is not a gap in what Synoptik knows -- it is
what a source file is made of. A #+ or #- branch not taken, and a #. refused,
are text that would have defined something and did not.

Stated as what it excludes rather than what it includes, deliberately: a
reason this function has never met is reported rather than silently dropped,
which is the direction CON-0001 wants a default to fall."
  (let ((name (skip-reason-name (getf skip :reason))))
    (and name (not (member name '("line-comment" "block-comment" "semicolon-comment")
                           :test #'string=)))))

(defun reading-suppressed-regions (reading)
  "READING's skips that suppressed source, oldest first. See
SKIP-SUPPRESSES-SOURCE-P for why this is not just READING-SKIPS."
  (remove-if-not #'skip-suppresses-source-p (reading-skips reading)))

;;;; ------------------------------------------------------------------
;;;; The client
;;;; ------------------------------------------------------------------

(defun build-newline-index (contents)
  "A sorted vector of the offset just past each newline in CONTENTS.

Exists because OFFSET-LINE is (1+ (count #\\Newline string :end offset)) --
linear in the offset, which was free when the only caller asked once per
top-level form and is not free now. Eclector reports a position for every cons
at every depth: 21411 of them on this tree against 1521 top-level forms, so
the same function called the same way turned reading into an O(n^2) pass and
cost 5.25 seconds against the host reader's 0.23.

Measured, then fixed, rather than assumed either way -- and worth recording
because the obvious conclusion from the first measurement was that Eclector is
slow. It is not: Eclector reading this whole tree and recording nothing takes
0.09 seconds, less than half what the host reader takes. The cost was entirely
in how this file asked for line numbers."
  (let ((index (make-array 64 :adjustable t :fill-pointer 0 :element-type 'fixnum)))
    (loop for i from 0 below (length contents)
          when (char= #\Newline (char contents i))
            do (vector-push-extend (1+ i) index))
    index))

(defun line-at (index offset)
  "The 1-based line OFFSET falls on, by binary search over INDEX.
Agrees with OFFSET-LINE by construction: both count the newlines strictly
before OFFSET and add one."
  (let ((low 0) (high (fill-pointer index)))
    (loop while (< low high)
          do (let ((mid (floor (+ low high) 2)))
               (if (<= (aref index mid) offset)
                   (setf low (1+ mid))
                   (setf high mid))))
    (1+ low)))

(defclass lisp-reader-client (eclector.parse-result:parse-result-client)
  ((lines    :initarg :lines    :reader client-lines
             :documentation "NEWLINE-INDEX over the file, because Eclector
reports positions as character offsets and the analyzer works in lines.")
   (reading  :initarg :reading  :reader client-reading)
   (stream   :initarg :stream   :reader client-stream
             :documentation "The stream being read, so a method the protocol
hands no position -- EVALUATE-EXPRESSION is the only one -- can still record
where it was. A gap with a line someone can open is worth more than a gap
without one (CON-0001).")
   (features :initarg :features :reader client-features
             :documentation "The feature list #+ and #- are evaluated against.
See EVALUATE-FEATURE-EXPRESSION below for why it is a slot rather than a
binding of CL:*FEATURES*."))
  (:documentation "Synoptik's Eclector client: builds nothing, records everything.

Deliberately holds the accumulating READING rather than returning values
through the parse-result protocol, because the protocol's return value is the
expression tree and this design's whole point is that the expression tree stays
an ordinary s-expression."))

(defmethod eclector.reader:evaluate-feature-expression
    ((client lisp-reader-client) expression)
  "Decide a #+ or #- against the client's own feature list. REQ-0019 R5.

The policy is explicit and it belongs to the client, which is the whole of
this requirement. Before it, the index silently depended on the *analyzing
implementation's* CL:*FEATURES* -- so the same repository read by SBCL and by
CCL would yield different entities, and nothing anywhere recorded which
reading it was. That gap was disclosed in no document and filed as no bug,
which is why DES-0013 makes the mechanism a requirement.

The default stays the host's *FEATURES*, deliberately, so this step moves no
entity count. Changing it is a separate decision with an entity-count
consequence, and DES-0013 R6 leaves it to whoever takes it: a policy that
read both branches of every #+/#- would index definitions that do not exist
on any one platform, and a policy that read neither would lose the ones that
do. Neither is obviously right, and picking one silently would be worse than
either.

A slot rather than a rebinding of CL:*FEATURES*, on the same argument
EVALUATE-EXPRESSION's method makes: a client that carries its own policy
cannot be talked out of it by a dynamic binding somewhere up the stack, and
rebinding a standard special variable to read a file would be visible to
anything else running in this image."
  (let ((*features* (client-features client)))
    (call-next-method)))

(defmethod eclector.parse-result:make-expression-result
    ((client lisp-reader-client) result children source)
  "Return RESULT unchanged -- the load-bearing method of the whole design --
and record its range on the way past.

CHILDREN is ignored precisely because RESULT already contains them: Eclector
built the cons, and its car and cdr are the children's own results. Consuming
CHILDREN to build something else is what the CST system does and what this
deliberately does not."
  (declare (ignore children))
  (when (consp result)
    (let ((lines (client-lines client)))
      (setf (gethash result (reading-spans (client-reading client)))
            ;; Lines for every consumer, plus the raw start offset, which only
            ;; FORMS' vestigial fourth element wants. Carrying it here rather
            ;; than in a second table keeps one entry per cons.
            (list (line-at lines (car source))
                  (line-at lines (cdr source))
                  (car source)))))
  result)

(defmethod eclector.parse-result:make-skipped-input-result
    ((client lisp-reader-client) stream reason children source)
  "Record a region the reader passed over, and contribute nothing to the tree.

REASON discriminates a comment from a feature-suppressed form from a read-eval
refusal, which is the difference CON-0001 wants: a gap Synoptik can name beats a
hole in the output.

CL:*READ-SUPPRESS* is filtered out rather than recorded. A suppressed form
produces one of these for itself and one for every subform inside it, so
keeping them would report a #+sbcl over a five-line function as six gaps. The
outer result -- whose reason is the feature expression itself -- is the one
that describes what happened."
  (declare (ignore stream children))
  (unless (eq reason 'cl:*read-suppress*)
    (let ((lines (client-lines client))
          (reading (client-reading client)))
      (push (list :reason reason
                  :start-line (and source (line-at lines (car source)))
                  :end-line (and source (line-at lines (cdr source))))
            (reading-skips reading))))
  nil)

(defmethod eclector.reader:interpret-symbol
    ((client lisp-reader-client) input-stream package-indicator symbol-name
     internp)
  "A keyword interns in KEYWORD; everything else is uninterned.

This is REQ-0019 R2 and R6 in one method. Nothing is interned into any Synoptik
package and no package is created or deleted per file, so
READ-FORMS-WITH-SPANS' gensym'd scratch package and its DELETE-PACKAGE in an
UNWIND-PROTECT both go, and so does INTERN-FOREIGN-SYMBOL-LOCALLY -- a package
the workspace has never loaded is no longer an error to recover from but simply
a string to record.

The KEYWORD exception is not a compromise. A keyword has no home-package
identity to confuse, CL:READ would intern it there too, and the walk tests
KEYWORDP in five places -- an uninterned symbol named \"method\" would make
(:method ...) clause detection and the quotation clauses' keyword guards both
wrong. What the walk sees is otherwise unchanged: SYMBOLP is true of an
uninterned symbol, and SYMBOL-NAME returns the name after readtable-case
folding, so TOKEN-NAME's STRING-DOWNCASE produces the identical string.

MAKE-SYMBOL returns a fresh object per occurrence, which is what lets two call
sites writing the same qualified name each keep their own prefix."
  (declare (ignore input-stream internp))
  (if (or (eq package-indicator :keyword)
          ;; A feature expression. #+sbcl reads its feature name with
          ;; *PACKAGE* bound to KEYWORD and the indicator :CURRENT rather than
          ;; :KEYWORD, so uninterning it here made every #+ false and every #-
          ;; true -- the reader silently took the non-host branch of all five
          ;; reader-conditional sites in this tree, and the only symptom was
          ;; different call names inside three functions. A feature name has
          ;; to be EQ to the keyword in *FEATURES* or the comparison cannot
          ;; work, so :CURRENT is honoured whenever *PACKAGE* is KEYWORD, which
          ;; is that context and no other: READ-SOURCE binds *PACKAGE* nowhere.
          (and (eq package-indicator :current)
               (eq *package* (find-package '#:keyword))))
      (intern symbol-name '#:keyword)
      (let ((symbol (make-symbol symbol-name)))
        (when (stringp package-indicator)
          (setf (gethash symbol (reading-packages (client-reading client)))
                (string-downcase package-indicator)))
        symbol)))

(defmethod eclector.reader:evaluate-expression
    ((client lisp-reader-client) expression)
  "Refuse, and record the refusal. REQ-0019 R4.

Synoptik's own image never evaluates a form of target code. That was true before
via (*READ-EVAL* NIL) and is true here via a method, which is strictly stronger
-- a client that cannot evaluate cannot be talked into it by a dynamic
rebinding somewhere up the stack. What changes is the cost: the host reader
signals a READER-ERROR on #. under *READ-EVAL* NIL, which reached ANALYZE-FILE's
HANDLER-CASE and lost every definition in the file. Refusing the form is the
requirement; losing the file for it never was."
  (declare (ignore expression))
  (let ((line (line-at (client-lines client)
                       (file-position (client-stream client)))))
    (push (list :reason :read-eval :start-line line :end-line line)
          (reading-skips (client-reading client))))
  nil)

(defmethod eclector.reader:wrap-in-function ((client lisp-reader-client) name)
  (let ((form (list (make-symbol "FUNCTION") name)))
    (setf (gethash form (reading-reader-macros (client-reading client))) :function)
    form))

(defmethod eclector.reader:wrap-in-quote ((client lisp-reader-client) material)
  (let ((form (list (make-symbol "QUOTE") material)))
    (setf (gethash form (reading-reader-macros (client-reading client))) :quote)
    form))

;;;; ------------------------------------------------------------------
;;;; Reading a file
;;;; ------------------------------------------------------------------

(defun read-source (contents &key (features *features*))
  "Every top-level form in CONTENTS, with the ranges, prefixes and gaps the
reader saw. Returns a READING.

FEATURES is the list #+ and #- are decided against, defaulting to the host's
CL:*FEATURES* so that this is parity rather than a policy (REQ-0019 R5,
DES-0013 R6). Explicit because the alternative is what it replaced: an index
that silently depended on which implementation happened to be doing the
analyzing, recorded nowhere. Material a policy suppresses is a recorded gap --
READING-SUPPRESSED-REGIONS -- rather than a silent absence.

Two things about the handler structure are load-bearing and neither is
obvious.

The HANDLER-BIND that invokes ECLECTOR.READER:RECOVER must be established
INSIDE the HANDLER-CASE, not outside it. Handlers run innermost first, so with
the nesting the other way the HANDLER-CASE unwinds before the restart is ever
looked for -- and the symptom is not an error but the rest of the file silently
not being read. This was got wrong twice while spiking DES-0013 and diagnosed
only by comparison against a working case.

A form whose read invoked RECOVER is recorded in RECOVERED and is NOT placed in
FORMS. Recovery advances the reader to the next top-level form; it never makes
the damaged form trustworthy. Measured, not assumed: recovering from an
unterminated list in

    (defun a () 1)
    (defun b () (oops
    (defun c () 3)

yields (defun b () (oops (defun c () 3))) -- c's definition swallowed whole into
b's body. Offered to pass 1 that mints a function named b whose range covers
text defining c, and c disappears from the index with no count moving to say so.
That is the fabricated fact CON-0001 forbids, and dropping the recovered form is
what prevents it. The stray-close-paren case by contrast recovers perfectly,
which is why recovery is worth having at all."
  (let* ((reading (make-reading))
         (lines (build-newline-index contents))
         (stream (make-string-input-stream contents))
         (client (make-instance 'lisp-reader-client
                                :lines lines :reading reading :stream stream
                                :features features))
         (forms '())
         ;; Conditions repaired while reading the form currently in flight.
         ;; Reset per iteration, so a non-empty list after a read is exactly
         ;; "this form was repaired" -- which is what R4 keys on.
         (repairs '()))
    (handler-case
        (handler-bind
            ((error
               (lambda (condition)
                 (let ((restart (find-restart 'eclector.reader:recover)))
                   (when restart
                     ;; The offset matters as much as the condition. Recovery
                     ;; happens both for damage inside the form being built --
                     ;; an unterminated list, which corrupts it -- and for junk
                     ;; sitting between forms, a stray close paren, which does
                     ;; not. Comparing where the reader was against where the
                     ;; form it eventually returns began is what tells them
                     ;; apart, and getting it wrong in the safe direction would
                     ;; silently drop every definition after a stray paren.
                     (push (list (type-of condition) (princ-to-string condition)
                                 (file-position stream))
                           repairs)
                     (invoke-restart restart))))))
          (loop
            (setf repairs '())
            (let ((before (file-position stream)))
              (let ((form (eclector.parse-result:read client stream nil :eof)))
                (when (eq form :eof) (return))
                (multiple-value-bind (start end foundp) (form-range reading form)
                  ;; The span table is authoritative where it has an answer,
                  ;; which is every cons. A top-level atom has none, and there
                  ;; FILE-POSITION is the only source -- it brackets the token
                  ;; plus whatever whitespace preceded it, which is a wider
                  ;; truth rather than a wrong one.
                  (unless foundp
                    (setf start (line-at lines before)
                          end (line-at lines (file-position stream))))
                  (let ((form-start (or (third (gethash form (reading-spans reading)))
                                        before))
                        (corrupted nil))
                    ;; Damage at or after the form's first character was damage
                    ;; to this form. Damage before it was junk the reader
                    ;; stepped over on the way in, and the form itself is
                    ;; intact. Getting that backwards in the safe direction
                    ;; would silently drop every definition after a stray
                    ;; paren, which is why the offset is recorded alongside the
                    ;; condition at all.
                    ;;
                    ;; Asked of each repair rather than once for the form, and
                    ;; that is not a detail: one unterminated list signals
                    ;; twice at end of input -- once for the inner list and
                    ;; once for the outer -- and a single FIND-IF marks
                    ;; whichever it happened to return, leaving the other
                    ;; recorded as having cost nothing. Both damaged the same
                    ;; form. :COST is what a reader of the property uses to
                    ;; tell "a definition is missing here" from "the reader
                    ;; stepped over some junk", so a repair mislabelled
                    ;; :NOTHING is a gap that reads as harmless.
                    (dolist (repair (reverse repairs))
                      (let ((cost (if (>= (third repair) form-start) :form :nothing)))
                        (when (eq cost :form) (setf corrupted t))
                        (push (list :condition (first repair) :text (second repair)
                                    :start-line (line-at lines (third repair))
                                    :end-line (line-at lines (third repair))
                                    :cost cost)
                              (reading-recovered reading))))
                    (unless corrupted
                      (push (list form start end form-start) forms))))))))
      (end-of-file () nil)
      (error (condition) (setf (reading-fatal reading) condition)))
    (setf (reading-forms reading) (nreverse forms)
          (reading-skips reading) (nreverse (reading-skips reading))
          (reading-recovered reading) (nreverse (reading-recovered reading)))
    reading))
