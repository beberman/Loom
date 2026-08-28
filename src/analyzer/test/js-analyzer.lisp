;;;
;;; Tests for src/analyzer/js-analyzer.lisp -- REQ-0024 R8.
;;;
;;; Fixture strings rather than the acceptance tree. REQ-0024 R7's measurement
;;; is taken against ~/github/front-end, which is not checked out wherever this
;;; suite runs; R8 exists precisely so that the acceptance run is a measurement
;;; and not the test. What is asserted here is the behaviour that produces
;;; those numbers.
;;;
;;; Every test in this file needs a live node. That is a real dependency and it
;;; is checked once, in JS-AVAILABLE-P: on a machine without node the tests
;;; skip rather than fail, for the same reason REQ-0024 R2 makes an absent
;;; toolchain a recorded absence rather than an error. A red suite on a machine
;;; that was never going to be able to run the analyzer teaches nobody
;;; anything. THE-TOOLCHAIN-BEING-ABSENT-IS-RECORDED-NOT-FATAL covers the
;;; absence path itself and does not need node to do it.
;;;

(in-package :loom-analyzer-test)

(def-suite js-analyzer
  :in all-tests
  :description "JavaScript and JSX through acorn in a child process (REQ-0024).")

(in-suite js-analyzer)

;;; ------------------------------------------------------------------
;;; Harness
;;; ------------------------------------------------------------------

(defun js-available-p ()
  "True when a child can actually be started."
  (bt:with-lock-held (loom-analyzer::*js-child-lock*)
    (not (null (loom-analyzer::ensure-js-child)))))

(defmacro js-test (name &body body)
  "A test that needs a live node, and skips rather than fails without one.

The skip is a branch rather than an early return because FiveAM's TEST
establishes no block to return from: an early-return guard compiles to `return
for unknown block' and is dead code that reads as though it works. It never
fired here, since node is present on the machine this was written on -- which
is exactly the machine where a skip guard proves nothing."
  `(test ,name
     (if (js-available-p)
         (progn ,@body)
         (skip "node is not on PATH; the JavaScript analyzer cannot run here"))))

(defun js-ops (path contents)
  (analyze-file (make-instance 'loom-analyzer::js-analyzer) path contents "ws-test"))

(defun js-graph (path contents)
  (let ((g (make-graph)))
    (apply-transaction g (js-ops path contents))
    g))

(defun js-entities (path contents &optional type)
  (let ((entities (all-entities (js-graph path contents))))
    (if type
        (remove-if-not (lambda (e) (eq type (entity-type e))) entities)
        entities)))

(defun js-named (path contents name)
  "The one entity called NAME, or NIL."
  (find name (js-entities path contents) :key #'name :test #'string=))

(defun js-file-entity (path contents)
  (first (js-entities path contents :file)))

;;; ------------------------------------------------------------------
;;; Dispatch (R1)
;;; ------------------------------------------------------------------

(test the-analyzer-claims-js-jsx-mjs-and-cjs
  (let ((analyzer (make-instance 'loom-analyzer::js-analyzer)))
    (dolist (path '("src/a.js" "src/a.jsx" "src/a.mjs" "src/a.cjs"))
      (is-true (analyzer-handles-p analyzer path)
               "~a should be claimed" path))))

(test the-analyzer-refuses-typescript
  ;; REQ-0024's WHAT THIS IS NOT. acorn's ecosystem can be made to accept TS,
  ;; and a parser that did would mint entities whose properties -- types,
  ;; interfaces, generics -- nothing in the ontology models.
  (let ((analyzer (make-instance 'loom-analyzer::js-analyzer)))
    (dolist (path '("src/a.ts" "src/a.tsx" "vite.config.ts"))
      (is-false (analyzer-handles-p analyzer path)
                "~a must not be claimed" path))))

;;; ------------------------------------------------------------------
;;; Definitions (R1)
;;; ------------------------------------------------------------------

(js-test function-declarations-and-arrow-bindings-both-become-functions
  ;; The arrow half is not a nicety: it is how most of a modern React tree
  ;; spells a function, and an analyzer that only saw FunctionDeclaration would
  ;; miss the majority of front-end's callables.
  (let* ((source "export function alpha(a, b) { return a + b; }
const beta = (x) => x * 2;
export const gamma = async () => { await beta(1); };
")
         (functions (js-entities "src/m.js" source :function)))
    (is (= 3 (length functions)))
    (is (equal '("alpha" "beta" "gamma")
               (sort (mapcar #'name functions) #'string<)))))

(js-test a-class-yields-the-class-its-superclass-name-and-a-method-each
  (let* ((source "export class Widget extends Base {
  render() { return draw(this); }
  static make() { return new Widget(); }
}
")
         (class (js-named "src/w.js" source "Widget"))
         (methods (js-entities "src/w.js" source :method)))
    (is (eq :class (entity-type class)))
    ;; A name, not an edge. The superclass can be defined in another file, so
    ;; the analyzer records what it read and LOOM-GRAPH derives the edge on
    ;; every pass -- DEC-0003, the same discipline the Lisp analyzer keeps.
    (is (equal '("Base") (getp class :superclass-names)))
    (is (equal '("Widget.make" "Widget.render")
               (sort (mapcar #'name methods) #'string<))
        "methods are keyed Class.method so two classes with a render() do not collide")))

(js-test the-natural-key-of-a-method-keeps-two-renders-apart
  ;; CON-0005: one assert per natural key per file. Two classes each with a
  ;; render() in one file is the ordinary case in a component tree, and an
  ;; analyzer naming both entities "render" would assert one key twice.
  (let ((methods (js-entities "src/two.js"
                              "class A { render() { return one(); } }
class B { render() { return two(); } }
"
                              :method)))
    (is (= 2 (length methods)))
    (is (equal '("A.render" "B.render") (sort (mapcar #'name methods) #'string<)))))

;;; ------------------------------------------------------------------
;;; Calls, and JSX as a call (R4)
;;; ------------------------------------------------------------------

(js-test a-call-inside-a-function-becomes-a-call-name
  (let ((entity (js-named "src/m.js" "function outer() { return helper(1); }" "outer")))
    (is (member "helper" (getp entity :call-names) :test #'string=))))

(js-test a-call-in-a-nested-callback-belongs-to-the-enclosing-named-function
  ;; An inline callback is not something another file can name, so it gets no
  ;; entity of its own. Its calls have to land on the enclosing definition or
  ;; they are lost -- and in a React tree almost everything interesting happens
  ;; inside a useEffect or a map callback.
  (let ((entity (js-named "src/m.js"
                          "function outer() { items.map((i) => transform(i)); }"
                          "outer")))
    (is (member "transform" (getp entity :call-names) :test #'string=))))

(js-test jsx-usage-is-a-call-name-and-is-also-recorded-as-jsx
  ;; R4. A component is invoked by being rendered. If <Thing /> produced no
  ;; call name, RESOLVE-CALLS would draw no edge and `impact' would answer
  ;; nothing useful about the majority of a front-end.
  (let ((entity (js-named "src/App.jsx"
                          "function App() { return <Panel><Row /></Panel>; }"
                          "App")))
    (is (member "Panel" (getp entity :call-names) :test #'string=))
    (is (member "Row" (getp entity :call-names) :test #'string=))
    (is (equal '("Panel" "Row") (sort (copy-list (getp entity :jsx-names)) #'string<))
        ":JSX-NAMES keeps rendering distinguishable from calling")))

(js-test a-host-element-is-not-a-call-name
  ;; <div> resolves to nothing in any tree, so carrying it would put noise in
  ;; every component's call list.
  (let ((entity (js-named "src/App.jsx"
                          "function App() { return <div><span>hi</span></div>; }"
                          "App")))
    (is-false (member "div" (getp entity :call-names) :test #'string-equal))
    (is-false (getp entity :jsx-names))))

(js-test a-language-global-is-not-a-call-name
  ;; BUG-0029's first half, and the one an analyzer can fix. Without this,
  ;; `new Error(...)' records a call to ERROR, and a repository defining a
  ;; component called Error collects an edge from every throw site: measured at
  ;; 315 inbound edges each on front-end, which put three error-display
  ;; components at the top of `structure's hub list ahead of everything real.
  (let ((entity (js-named "src/m.js"
                          "function f() {
  if (!ok) throw new Error('no');
  return JSON.stringify(Array.isArray(x) ? Math.max(1, 2) : real(x));
}"
                          "f")))
    (let ((calls (getp entity :call-names)))
      (is (member "real" calls :test #'string=)
          "a genuine call survives the filter")
      (dolist (global '("Error" "stringify" "isArray" "max"))
        (is-false (member global calls :test #'string=)
                  "~a is a language builtin, not a definition in this tree" global)))))

(js-test a-member-call-records-the-receiver-the-source-wrote
  ;; BUG-0036. `log.commit()' contributed COMMIT alone, which matched every
  ;; plain function of that name and no method at all, since a method entity is
  ;; named Class.method. The receiver is the one piece of evidence the source
  ;; actually wrote, and recording it is what lets LOOM-GRAPH place the call.
  (let ((entity (js-named "src/m.js"
                          "function f() {
  log.commit();
  helper();
  obj.a.b();
  JSON.stringify(x);
}"
                          "f")))
    (let ((calls (getp entity :call-names)))
      (is (member "log.commit" calls :test #'string=)
          "the receiver travels with the property")
      (is-false (member "commit" calls :test #'string=)
                "and replaces the bare property rather than joining it: two
names would be two lookups and two fan-outs for one call")
      (is (member "helper" calls :test #'string=)
          "a bare call is unchanged")
      (is (member "b" calls :test #'string=)
          "a receiver that is an expression has nothing to qualify with, and
the property alone is the answer it had before")
      (is-false (member "stringify" calls :test #'string=)
                "a language global still contributes nothing"))))

(js-test a-this-call-is-qualified-by-the-class-it-is-written-in
  ;; The one member call whose receiver's type is not a guess: `this' inside a
  ;; class body is that class, so GestureLog.commit resolves to exactly one
  ;; method instead of fanning out over every `commit' in the repository.
  (let ((entity (js-named "src/m.js"
                          "class GestureLog {
  record(g) { this.commit(g); }
  commit(g) { return g; }
}"
                          "GestureLog.record")))
    (is (member "GestureLog.commit" (getp entity :call-names) :test #'string=))
    (is-false (member "this.commit" (getp entity :call-names) :test #'string=))))

(js-test a-call-in-a-variable-initialiser-is-dropped-rather-than-mis-attributed
  ;; The :CALLS relationship's :FROM is (:function :method :test :call-site),
  ;; so a :VARIABLE is not a legal source and writing call names onto one would
  ;; ask RESOLVE-CALLS for an edge the ontology forbids. DES-0014's :CALL-SITE
  ;; is the designed answer for this position (BUG-0017) and is not yet minted
  ;; here, so the names are dropped. A recorded gap, not a fabrication --
  ;; CON-0001. This test pins the choice so that minting them later is a
  ;; deliberate change rather than an accident.
  (let ((entity (js-named "src/m.js" "const emitter = makeEmitter();" "emitter")))
    (is (eq :variable (entity-type entity)))
    (is-false (getp entity :call-names))))

;;; ------------------------------------------------------------------
;;; Exports and the anonymous default (R1, and REQ-0024's fourth question)
;;; ------------------------------------------------------------------

(js-test an-exported-function-is-marked-exported
  (let ((source "export function shown() {}
function hidden() {}
"))
    (is-true (getp (js-named "src/m.js" source "shown") :exported-p))
    (is-false (getp (js-named "src/m.js" source "hidden") :exported-p))))

(js-test an-anonymous-default-export-is-keyed-on-the-module-basename
  ;; REQ-0024's fourth open question. The definition site has no name and the
  ;; importing module names it whatever it likes, so the exported name cannot
  ;; be the key. The basename is stable and is what importers call it by
  ;; convention. The requirement's own suggestion, the full path, is rejected:
  ;; `find' and `context' tokenise names to rank them, so a path-named entity
  ;; would rank against queries by its directories as much as by itself.
  (let ((entity (js-named "src/components/Card.jsx"
                          "export default function () { return <div />; }"
                          "Card")))
    (is-true entity "the anonymous default should be named for its module")
    (is (eq :function (entity-type entity)))))

(js-test a-named-default-export-keeps-its-own-name
  (let ((entity (js-named "src/components/Card.jsx"
                          "export default function Panel() { return <div />; }"
                          "Panel")))
    (is-true entity "a default export that has a name uses it, not the basename")))

;;; ------------------------------------------------------------------
;;; The file entity, imports, and :SYSTEM (R5)
;;; ------------------------------------------------------------------

(js-test the-file-entity-records-its-language-and-line-count
  (let ((file (js-file-entity "src/core/m.js" "const a = 1;
const b = 2;
")))
    (is (eq :javascript (getp file :language)))
    (is (= 3 (getp file :line-count)))))

(js-test import-specifiers-are-recorded-and-not-resolved
  ;; REQ-0024's WHAT THIS IS NOT rules out following an import to the file it
  ;; names -- that needs node resolution, extension probing and the alias table
  ;; a project configures for itself. Recording the specifier is what lets a
  ;; later pass derive :IMPORTS edges without reanalysing the tree (DEC-0003).
  (let ((file (js-file-entity "src/m.js"
                              "import React from 'react';
import { thing } from './local';
export * from '../other';
")))
    (is (equal '("../other" "./local" "react")
               (sort (copy-list (getp file :import-sources)) #'string<)))))

(js-test the-system-comes-from-the-path-convention
  ;; R5, decided rather than inherited. The language's own grouping construct
  ;; is the module, and the module is the file -- keying :SYSTEM on it would
  ;; make each of front-end's 468 files its own system, which is not a grouping
  ;; at all. This is the first language where the strongest construct the
  ;; language offers is weaker than the path convention.
  (is (eq :domain (getp (js-file-entity "src/domain/game.js" "const a = 1;") :system)))
  (is (eq :domain (getp (js-named "src/domain/game.js" "export function go() {}" "go")
                        :system)))
  (is-false (getp (js-file-entity "src/App.jsx" "const a = 1;") :system)
            "a file directly under src/ names no system"))

;;; ------------------------------------------------------------------
;;; Damage (R3) and absence (R2)
;;; ------------------------------------------------------------------

(js-test a-file-that-will-not-parse-is-still-indexed-with-its-damage-recorded
  ;; R3. An unparseable file vanishing from the index would be a silent gap,
  ;; and CON-0001's whole argument is that a recorded gap beats a silence.
  (let* ((source "function fine() { return 1; }
function broken( { !!!
")
         (file (js-file-entity "src/bad.js" source)))
    (is-true file "the file entity is asserted anyway")
    (is-true (getp file :analysis-failed-p))
    (is-true (getp file :analysis-error))
    (let ((region (first (getp file :suppressed-regions))))
      (is-true region "the damage carries a line range")
      (is (integerp (getf region :start-line)))
      (is (integerp (getf region :end-line))))))

(test the-toolchain-being-absent-is-recorded-not-fatal
  ;; R2, on REQ-0018 R2's precedent. Needs no node -- it makes node
  ;; unfindable on purpose. A developer indexing a mixed tree on a machine
  ;; without node gets their Lisp answers and a note about the JavaScript,
  ;; rather than an error or an empty result they cannot explain.
  (loom-analyzer::stop-js-child)
  (unwind-protect
       (let* ((loom-analyzer::*node-program*
                "loom-no-such-node-binary-should-exist")
              (file (js-file-entity "src/m.js" "const a = 1;")))
         (is-true file "the file is indexed even with no toolchain")
         (is (eq :javascript (getp file :language)))
         (is-true (getp file :analysis-failed-p))
         (is-true (search "loom-no-such-node-binary-should-exist"
                          (or (getp file :analysis-error) ""))
                  "the reason names what was missing, so a reader can act on it"))
    ;; The failed probe left *JS-CHILD* nil and a reason set; clear both so a
    ;; later test in this image is not told the toolchain is missing.
    (loom-analyzer::stop-js-child)
    (setf loom-analyzer::*js-unavailable-reason* nil)))

;;; ------------------------------------------------------------------
;;; Reconciliation (R6, CON-0005)
;;; ------------------------------------------------------------------

(js-test two-functions-of-one-name-in-one-file-reconcile-to-the-last
  ;; CON-0005 and R6. JavaScript replaces rather than merges: the second
  ;; `function dup' is what `dup' means once the module has loaded, and the
  ;; first is dead code. TypeScript would have to MERGE the same shape, which
  ;; is one of the reasons REQ-0024 refuses to claim it.
  (let* ((source "function dup() { return first(); }
function dup() { return second(); }
")
         (functions (js-entities "src/m.js" source :function)))
    (is (= 1 (length functions))
        "one natural key, asserted once -- the writer cannot reconcile two")
    (let ((entity (first functions)))
      (is (member "second" (getp entity :call-names) :test #'string=)
          "the surviving definition is the last one in source order")
      (is-false (member "first" (getp entity :call-names) :test #'string=))
      (is-true (getp entity :shadowed-definitions)
               "the superseded definition is recorded as a line range, not dropped in silence"))))

;;; ------------------------------------------------------------------
;;; The child process
;;; ------------------------------------------------------------------

(js-test the-child-is-reused-across-files-rather-than-restarted
  ;; The whole reason ANALYZE-FILE's per-file interface survived REQ-0024's
  ;; predicted batching change. One process per file would cost ~23ms of node
  ;; startup 468 times over on front-end; reuse makes the measured whole-tree
  ;; parse 0.65s.
  (js-ops "src/one.js" "const a = 1;")
  (let ((first-process loom-analyzer::*js-child*))
    (js-ops "src/two.js" "const b = 2;")
    (is (eq first-process loom-analyzer::*js-child*))))

(js-test a-child-that-dies-is-replaced-and-the-next-file-still-indexes
  (js-ops "src/one.js" "const a = 1;")
  (let ((doomed loom-analyzer::*js-child*))
    (loom-analyzer::stop-js-child)
    (let ((entity (js-named "src/two.js" "export function after() { return go(); }" "after")))
      (is-true entity "the file after a dead child still produces entities")
      (is-false (eq doomed loom-analyzer::*js-child*)
                "and it is a different process"))))

(js-test non-ascii-source-does-not-desynchronise-the-frame
  ;; The frame header counts bytes and the stream is character-oriented. A
  ;; wrong count would not corrupt one file -- it would shift every frame after
  ;; it, so the failure would appear in an unrelated file later in the tree.
  ;; The second file is what actually proves the count was right.
  ;;
  ;; The characters below must be literal non-ASCII rather than \u escapes: an
  ;; escape sequence is ASCII on the wire, so a test written that way would
  ;; pass against a byte count that was wrong.
  (js-ops "src/accented.js"
          (format nil "const greeting = 'caf~c ~c na~cve ~c~c';~%~
                       export function first() { return one(); }~%"
                  (code-char #xE9)     ; é, two bytes
                  (code-char #x2014)   ; em dash, three bytes
                  (code-char #xEF)     ; ï
                  (code-char #x1F600)  ; emoji, four bytes and a surrogate pair in JS
                  (code-char #x00A0))) ; non-breaking space
  (let ((entity (js-named "src/plain.js" "export function second() { return two(); }" "second")))
    (is-true entity "the file after a non-ASCII one is still read correctly")
    (is (member "two" (getp entity :call-names) :test #'string=))))

;;; ------------------------------------------------------------------
;;; COMMENT-EXTENT for JavaScript -- REQ-0031 R9, PLAN-0030 S5
;;; ------------------------------------------------------------------

(defun js-extent-of (lines start-line)
  (comment-extent (make-instance 'loom-analyzer::js-analyzer) (coerce lines 'vector) start-line))

(test a-jsdoc-block-is-found-though-none-of-its-lines-is-a-comment-line
  ;; The case that corrected DES-0027 D3. A shared blank-or-comment line rule
  ;; recognises none of " */", " * @param" or "/**", and returns nothing on the
  ;; 249 of front-end's 461 source files that carry JSDoc -- silently.
  (multiple-value-bind (first attachment)
      (js-extent-of '("const a = 1;"
                      ""
                      "/**"
                      " * Emit a partition."
                      " * @param {Object} p"
                      " */"
                      "export function emitPartition(p) {")
                    7)
    (is (= 3 first) "the opening /**, not the line just above")
    (is (eq :adjacent attachment))))

(test a-run-of-slash-slash-lines-behaves-like-a-lisp-comment-block
  (multiple-value-bind (first attachment)
      (js-extent-of '("const a = 1;"
                      "// why this component exists"
                      "// and the second line"
                      "export function C() {}")
                    4)
    (is (= 2 first))
    (is (eq :adjacent attachment))))

(test a-file-banner-is-a-section-because-nothing-precedes-it
  ;; JavaScript has no fourth-semicolon convention, so position is the evidence
  ;; where depth is the evidence in Lisp. A comment at the top of a file is
  ;; about the file, not about whichever export happens to be first.
  (multiple-value-bind (first attachment)
      (js-extent-of '("/**"
                      " * Partition interchange helpers."
                      " */"
                      "export function first() {}")
                    4)
    (is (= 1 first))
    (is (eq :section attachment))))

(test an-inline-remark-is-not-a-block-opener
  ;; `foo(); /* note */' is about that statement. Treating it as a block would
  ;; serve the statement above a definition as though it documented it.
  (multiple-value-bind (first attachment)
      (js-extent-of '("const a = 1;"
                      "foo(); /* note */"
                      "export function C() {}")
                    3)
    (is (null first))
    (is (null attachment))))

(test an-unterminated-block-costs-a-form-and-not-the-file
  (multiple-value-bind (first attachment)
      (js-extent-of '("const a = 1;"
                      " * a block nothing ever opened"
                      " */"
                      "export function C() {}")
                    4)
    (is (null first) "no opener found, so nothing is claimed")
    (is (null attachment))))

(test a-blank-line-separates-a-js-block-without-hiding-it
  (multiple-value-bind (first attachment)
      (js-extent-of '("const a = 1;"
                      "/** a remark */"
                      ""
                      "export function C() {}")
                    4)
    (is (= 2 first))
    (is (eq :separated attachment) "one line opening and closing a block")))

;;; ------------------------------------------------------------------
;;; JSDoc as prose -- REQ-0035, DES-0028 D9, PLAN-0031 (JavaScript)
;;; ------------------------------------------------------------------

(test js-comment-line-text-strips-delimiters-and-keeps-tags
  ;; DES-0028 D9, measured before deciding: 979 blocks on front-end, only 377
  ;; carrying any @tag, and 44 KB of tag lines against 199 KB of prose. A tag
  ;; line is mostly description anyway, and what is not worth matching --
  ;; "param", "Object" -- is frequent enough that IDF weighs it to nothing
  ;; without being told.
  (let ((a (make-instance 'loom-analyzer::js-analyzer)))
    (is (string= "Emit a partition." (comment-line-text a " * Emit a partition.")))
    (is (string= "Emit a partition." (comment-line-text a "/** Emit a partition. */")))
    (is (string= "" (comment-line-text a " */")))
    (is (string= "why this exists" (comment-line-text a "// why this exists")))
    (is (string= "@param {Object} p - the partition"
                 (comment-line-text a " * @param {Object} p - the partition"))
        "the tag stays: the description after the dash is the prose")))

(js-test a-jsdoc-block-becomes-the-definitions-prose
    ;; The import matters. A block with no code above it is a file banner, not
    ;; documentation of whichever export happens to be first, so COMMENT-EXTENT
    ;; reports :SECTION and indexing declines it -- which is what the first
    ;; draft of this test tripped over. Real React files open with imports, so
    ;; the block above the export is :ADJACENT there; BANNER below asserts the
    ;; other half.
    (let* ((g (js-graph "src/x.js"
                        "import { z } from './z.js';

/**
 * Flatten a partition to an interchange document.
 * @param {Object} p - the partition
 */
export function emitP(p) { return p; }

export function undocumented(p) { return p; }"))
           (fns (entities-of-type g :function)))
      (flet ((doc-for (name)
               (let ((e (find name fns :key (lambda (x) (and (slot-boundp x 'name) (name x)))
                              :test #'equal)))
                 (and e (gethash :documentation (properties e))))))
        (is (search "Flatten a partition" (doc-for "emitP")))
        (is (search "@param" (doc-for "emitP")) "tags kept, per D9")
        (is (not (search "/**" (doc-for "emitP"))) "delimiters gone")
        (is (null (doc-for "undocumented"))
            "REQ-0035 R7: absence costs the entity nothing"))))

(js-test a-file-banner-is-not-the-first-exports-documentation
  ;; The other half of the rule above. JavaScript has no fourth-semicolon
  ;; convention marking a heading, so position is the evidence: nothing precedes
  ;; the block, therefore it is about the file. Attaching it to whichever export
  ;; happens to come first would be CON-0001's fabricated fact.
    (let* ((g (js-graph "src/y.js"
                        "/**
 * Partition interchange helpers.
 */
export function first(p) { return p; }"))
           (e (find "first" (entities-of-type g :function)
                    :key (lambda (x) (and (slot-boundp x 'name) (name x)))
                    :test #'equal)))
      (is (not (null e)) "the definition is still indexed")
      (is (null (gethash :documentation (properties e)))
          "the banner describes the module, not this function")))

;;; ------------------------------------------------------------------
;;; The runner's forms (REQ-0053)
;;; ------------------------------------------------------------------
;;;
;;; What produced front-end's 2,325 :TEST entities and 145 test files. The
;;; numbers are REQ-0053's acceptance and are measured against the tree; what
;;; is asserted here is the behaviour behind them.

(defparameter +vitest-suite+
  "import { describe, it, expect } from 'vitest';
import { stitch, span } from '../make-image.mjs';

describe('stitch', () => {
  beforeEach(() => { reset(); });

  it('crops after compositing', async () => {
    expect(await stitch(span(1))).toBe(1);
  });

  describe('when the bbox is small', () => {
    it('still returns a buffer', () => { expect(stitch(0)).toBeDefined(); });
  });
});
"
  "One suite, one nested suite, a hook and two cases.")

(js-test a-vitest-case-becomes-a-test-entity-and-the-suite-becomes-none
  ;; A suite mints nothing for the reason DEF-SUITE mints nothing: the ontology
  ;; declares no :SUITE type, and a suite is not a test.
  (let ((tests (js-entities "server/trials/test/makeImage.test.js" +vitest-suite+ :test)))
    (is (= 2 (length tests)))
    (is (equal '("stitch > crops after compositing"
                 "stitch > when the bbox is small > still returns a buffer")
               (sort (mapcar #'name tests) #'string<))
        "the name is the path a reader would speak: every enclosing title, then its own")
    (is (equal '("stitch" "stitch > when the bbox is small")
               (sort (mapcar (lambda (e) (getp e :suite)) tests) #'string<))
        "the suite half is also its own property")
    (is (null (js-named "server/trials/test/makeImage.test.js" +vitest-suite+ "stitch"))
        "the describe itself is not an entity")))

(js-test a-case-carries-what-it-calls-and-what-the-hooks-around-it-call
  ;; The coverage half. RESOLVE-TESTS reads the :CALLS edges these names
  ;; become, so a name missing here is a :TESTS edge that never exists.
  (let* ((tests (js-entities "server/trials/test/makeImage.test.js" +vitest-suite+ :test))
         (outer (find "stitch > crops after compositing" tests :key #'name :test #'equal))
         (inner (find "stitch > when the bbox is small > still returns a buffer" tests
                      :key #'name :test #'equal)))
    (is (member "stitch" (getp outer :call-names) :test #'equal)
        "the subject the case calls")
    (is (member "reset" (getp outer :call-names) :test #'equal)
        "the beforeEach runs for this case, so what it calls is this case's too")
    (is (member "reset" (getp inner :call-names) :test #'equal)
        "and for a case in a nested suite, which the runner also runs it for")))

(js-test a-hook-in-a-sibling-suite-is-not-attributed-to-this-suites-cases
  ;; The other side of the rule above, and the one that makes it a rule rather
  ;; than a fan-out: a beforeEach belongs to the cases the runner would run it
  ;; for and to no others.
  (let* ((source "import { describe, it } from 'vitest';
describe('alpha', () => {
  beforeEach(() => { setUpAlpha(); });
  it('one', () => { alpha(); });
});
describe('beta', () => {
  beforeEach(() => { setUpBeta(); });
  it('two', () => { beta(); });
});
")
         (tests (js-entities "src/x.test.js" source :test))
         (one (find "alpha > one" tests :key #'name :test #'equal)))
    (is (= 2 (length tests)))
    (is (member "setUpAlpha" (getp one :call-names) :test #'equal))
    (is (not (member "setUpBeta" (getp one :call-names) :test #'equal))
        "beta's setup runs for beta's cases")))

(js-test a-bare-top-level-test-call-is-a-case-with-no-suite
  ;; 635 of front-end's 2,325 cases are written this way, with no describe at
  ;; all -- so a recognition rule that required one would miss a quarter of the
  ;; tree.
  (let* ((source "import { test, expect } from 'vitest';
test('reads a get-defn message', () => { expect(createDefn()).toBeDefined(); });
")
         (tests (js-entities "src/models/test/message.test.js" source :test)))
    (is (= 1 (length tests)))
    (is (equal "reads a get-defn message" (name (first tests))))
    (is (null (getp (first tests) :suite)))
    (is (member "createDefn" (getp (first tests) :call-names) :test #'equal))))

(js-test the-import-alone-names-a-test-file-whatever-its-path-is-called
  ;; The second of REQ-0053 R2's two signals, and the one that does not depend
  ;; on a naming convention. `import { describe, it } from 'vitest'' is the
  ;; author saying what the file is.
  (let* ((source "import { describe, it } from 'vitest';
describe('widget', () => { it('renders', () => { render(); }); });
")
         (tests (js-entities "src/widget-checks.js" source :test)))
    (is (= 1 (length tests)))
    (is (eq :vitest (getp (first tests) :framework))
        "the module the runner was imported from names the framework")))

(js-test a-file-that-is-neither-named-nor-imports-a-runner-indexes-as-it-did
  ;; REQ-0053 A4, and the reason the child reports these forms rather than
  ;; deciding about them: `test' and `describe' are ordinary function names,
  ;; and a tree that defines its own must index exactly as it did before any of
  ;; this existed.
  (let* ((source "export function describe(x) { return String(x); }
function run() { describe(1); test(2); }
")
         (entities (js-entities "src/util.js" source)))
    (is (null (js-entities "src/util.js" source :test))
        "no case is minted from a call to this tree's own function")
    (is (equal '("describe" "run")
               (sort (mapcar #'name (remove :file entities :key #'entity-type))
                     #'string<))
        "and the definitions that were there are still there")
    (is (null (getp (js-file-entity "src/util.js" source) :test-file-p)))))

(js-test a-case-titled-by-a-template-is-counted-and-not-named
  ;; CON-0001 in the one place no total would reveal it. `it(`fails for
  ;; ${name}`)' is one title at collection and N at run time; naming the entity
  ;; after the literal parts would put a name in the index that appears nowhere
  ;; in the run output.
  (let* ((source "import { describe, it } from 'vitest';
describe('shapes', () => {
  it('names the first', () => { first(); });
  it(`sends error on shape with ${kind}`, () => { second(); });
});
")
         (tests (js-entities "src/s.test.js" source :test))
         (file (js-file-entity "src/s.test.js" source)))
    (is (= 1 (length tests)))
    (is (equal "shapes > names the first" (name (first tests))))
    (is (= 1 (getp file :unnamed-tests))
        "the count is the whole record that the other case exists")
    (is (eq t (getp file :test-file-p)))))

(js-test the-modifier-chain-and-the-each-table-are-both-transparent
  ;; `it.skip', `describe.only' and `it.each(table)(title, fn)' are all the
  ;; runner's own vocabulary for the same form. A recognition rule keyed on a
  ;; bare Identifier callee would see none of them.
  (let* ((source "import { describe, it, test } from 'vitest';
describe.only('chain', () => {
  it.skip('skipped but declared', () => { alpha(); });
  it.each([[1], [2]])('parameterised %i', (n) => { beta(n); });
  it.todo('written down and not written');
});
")
         (tests (js-entities "src/c.test.js" source :test))
         (todo (find "chain > written down and not written" tests :key #'name :test #'equal)))
    (is (= 3 (length tests)))
    (is (not (null todo)) "a todo is a declared test and the index says so")
    (is (null (getp todo :call-names))
        "with no body it reaches nothing, so it claims no coverage")))


;;; ------------------------------------------------------------------
;;; A default export that only re-exports defines nothing (BUG-0056)
;;; ------------------------------------------------------------------

(js-test a-default-export-of-existing-names-mints-no-second-entity
  ;; The reported symptom was `check-document' refusing `affects: [simplifyArcs]'
  ;; as ambiguous between the function and a `variable:' at the same path, with
  ;; nothing in the file that looked ambiguous. `export default { simplifyArcs }'
  ;; re-exports what the module already defined, and the entity minted for it is
  ;; named after the module's base name (JS-DEFINITION-NAME) -- so a file named
  ;; after the function it exports, which is the convention, collided with
  ;; itself.
  (let* ((source "export function simplifyArcs(arcs) { return arcs; }

export default { simplifyArcs };
")
         (entities (js-entities "src/import/simplifyArcs.js" source)))
    (is (= 1 (count :function entities :key #'entity-type))
        "the function is indexed exactly once")
    (is (zerop (count :variable entities :key #'entity-type))
        "and the re-export adds nothing: ~a"
        (mapcar (lambda (e) (list (entity-type e) (name e))) entities))
    (is (= 1 (count "simplifyArcs" entities
                    :key (lambda (e) (and (slot-boundp e 'name) (name e)))
                    :test #'equal))
        "so the bare name resolves to one definition")))

(js-test the-collision-needed-the-module-to-be-named-after-its-export
  ;; The control that shows what was actually going on, and why the sibling
  ;; module behaved differently for what looked like identical source. Under the
  ;; old rule sharedArcs.js got a `variable' named SHAREDARCS -- no collision --
  ;; while simplifyArcs.js got one named SIMPLIFYARCS. Neither has one now.
  (let ((entities (js-entities "src/import/sharedArcs.js"
                               "export function extractSharedArcs(a) { return a; }

export default { extractSharedArcs };
")))
    (is (zerop (count :variable entities :key #'entity-type)))
    (is (= 1 (count :function entities :key #'entity-type)))))

(js-test an-anonymous-default-export-still-becomes-an-entity-named-for-its-module
  ;; REQ-0024's fourth open question, unchanged. These three introduce a value
  ;; that exists nowhere else in the module, so dropping them would lose the
  ;; only record of the module's default export.
  (dolist (case '(("src/m/anon.js" "export default function (x) { return x + 1; }
" :function)
                  ("src/m/inline.js" "export default { render: (x) => x, label: 'thing' };
" :variable)
                  ("src/m/klass.js" "export default class { go() { return 1; } }
" :variable)
                  ("src/m/empty.js" "export default {};
" :variable)))
    (destructuring-bind (path source type) case
      (let ((entities (js-entities path source type)))
        (is (= 1 (length entities))
            "~a should yield one ~(~a~), got ~a" path type (length entities))
        (when entities
          (is (equal (pathname-name (pathname path)) (name (first entities)))
              "and it is named after its module"))))))
