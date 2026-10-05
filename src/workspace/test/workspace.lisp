;;;
;;; Tests for src/workspace/workspace.lisp -- the indexing pipeline.
;;;
;;; Level 1 in SS14.1's ordering: this runs the real analyzers over a real
;;; directory, so it is the first test that can tell you the pieces fit
;;; together. The fixture is a temporary repository rather than Loom itself,
;;; because these tests need to edit and delete files.
;;;

(in-package :loom-workspace-test)

(def-suite workspace
  :in all-tests
  :description "Indexing, resolution ordering, and change detection.")

(in-suite workspace)

(defparameter *fixture-root* nil)

(defvar *fixture-store* :file
  "Which document store WITH-WORKSPACE-FIXTURE builds: :FILE or :MEMORY.
DES-0051 D9 part B. WITH-WORKSPACE-FIXTURES runs a body under each.")

(defvar *fixture-docstore* nil
  "The in-memory store the current fixture holds its documents in, or NIL when
they are files.")

(defun fixture-document-p (relative)
  "True when RELATIVE is a path the document store holds: YAML under docs/."
  (and (eql 0 (search "docs/" relative))
       (member (pathname-type relative) '("yaml" "yml") :test #'string-equal)
       t))

(defun put-fixture-document (relative contents)
  "Put CONTENTS into the in-memory store at address RELATIVE, replacing what
is there. The path under docs/ gives the category and the name."
  (let ((existing (find relative (loom-docstore:docstore-enumerate *fixture-docstore*)
                        :key #'loom-docstore:docstore-record-address :test #'string=)))
    (if existing
        (loom-docstore:memory-docstore-replace
         *fixture-docstore* (loom-docstore:docstore-record-ref existing) contents)
        (loom-docstore:memory-docstore-put
         *fixture-docstore*
         (second (loom-utils:path-segments relative))
         (pathname-name relative)
         contents))))

(defun fixture-document-ref (relative)
  "The in-memory store's ref for the document at RELATIVE."
  (let ((record (find relative (loom-docstore:docstore-enumerate *fixture-docstore*)
                      :key #'loom-docstore:docstore-record-address :test #'string=)))
    (and record (loom-docstore:docstore-record-ref record))))

(defun break-fixture-document (relative reason)
  "Make the document at RELATIVE unreadable, however the fixture holds it.

Mode 000 for a file, MEMORY-DOCSTORE-BREAK in memory. Both leave the document
in the store and listed: what fails is the read, which is the case DES-0051 D7
is about."
  (if *fixture-docstore*
      (loom-docstore:memory-docstore-break *fixture-docstore*
                                           (fixture-document-ref relative)
                                           reason)
      (uiop:run-program (list "chmod" "000"
                              (namestring (merge-pathnames relative *fixture-root*)))
                        :output nil :error-output nil)))

(defun remove-fixture-document (relative)
  "Take the document at RELATIVE out of the store, however the fixture holds it."
  (if *fixture-docstore*
      (loom-docstore:memory-docstore-remove *fixture-docstore*
                                            (fixture-document-ref relative))
      (delete-file (merge-pathnames relative *fixture-root*))))

(defun repair-fixture-document (relative)
  "Let reads of the document at RELATIVE succeed again."
  (if *fixture-docstore*
      (loom-docstore:memory-docstore-repair *fixture-docstore*
                                            (fixture-document-ref relative))
      (uiop:run-program (list "chmod" "644"
                              (namestring (merge-pathnames relative *fixture-root*)))
                        :output nil :error-output nil)))

(defun write-file (relative contents)
  "Write CONTENTS at RELATIVE under the fixture root, or into the in-memory
store when the fixture has one and RELATIVE is a document. Returns the path."
  (let ((path (merge-pathnames relative *fixture-root*)))
    (if (and *fixture-docstore* (fixture-document-p relative))
        (put-fixture-document relative contents)
        (progn
          (ensure-directories-exist path)
          (with-open-file (out path :direction :output
                                    :if-exists :supersede :if-does-not-exist :create)
            (write-string contents out))))
    path))

(defun make-fixture-repository ()
  "A small two-file repository with a docs/ tree, in a fresh temp directory."
  (setf *fixture-root*
        (merge-pathnames (format nil "loom-fixture-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *fixture-root*)
  (setf *fixture-docstore* (and (eq *fixture-store* :memory)
                                (loom-docstore:make-memory-docstore
                                 :terminal-p #'terminal-category-status-p)))
  ;; The IN-PACKAGE is load-bearing, not decoration (BUG-0010). RULE-0001 below
  ;; names :KERNEL, and after DES-0009 that is a package name rather than a
  ;; path segment: without this form src/alpha.lisp falls through to
  ;; DEFAULT-SYSTEM-FOR-PATH, which answers NIL for a path with no segment after
  ;; "src/", and the fixture's rule matches nothing whatever the pipeline does.
  ;; It mints no entity of its own, so the exact counts asserted below --
  ;; 3 :FUNCTION entities, 4 files -- are unchanged by its presence.
  (write-file "src/alpha.lisp"
              "(in-package :kernel)
(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
  (write-file "src/beta.lisp"
              "(defun beta (x) (alpha x))
")
  (write-file "docs/decisions/DEC-0001.yaml"
              "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
affects: [alpha]
rationale: |
  Keeping alpha-twice free of side effects makes it testable.
")
  (write-file "docs/rules/RULE-0001.yaml"
              "id: RULE-0001
type: rule
title: Nothing in kernel may call into docs
status: active
severity: error
check:
  kind: no-edge
  from-system: kernel
  to-system: docs
  rel-types: [calls]
")
  (watch-repository *fixture-root* :monitor nil :quiet t :docstore *fixture-docstore*))

(defun cleanup-fixture ()
  (setf *fixture-docstore* nil)
  (when *fixture-root*
    (ignore-errors (uiop:delete-directory-tree *fixture-root* :validate t))
    (setf *fixture-root* nil)))

(defmacro with-workspace-fixture ((repository) &body body)
  `(let ((,repository (make-fixture-repository)))
     (unwind-protect (progn ,@body)
       (unwatch-repository (repository-name ,repository))
       (cleanup-fixture))))

(defmacro with-workspace-fixtures ((repository) &body body)
  "WITH-WORKSPACE-FIXTURE once with the file store and once with the in-memory
store. DES-0051 D9 part B: a test that passes on files and fails in memory has
found a caller that assumes a document is a file.

Every test whose subject is a document, a count over documents, or the whole
index runs here. A test about code alone -- enrichment, call sites, definer
macros, the occurrence bands, `git' -- stays on WITH-WORKSPACE-FIXTURE, where
it would pay twice for a store it never asks about.

A failure names the assertion and not the run, because both runs are one test.
Bind *FIXTURE-STORE* to :FILE or to :MEMORY and run the test again to see which
of the two it was."
  `(dolist (*fixture-store* '(:file :memory))
     (with-workspace-fixture (,repository) ,@body)))

;;; ------------------------------------------------------------------
;;; Indexing (SS3.4)
;;; ------------------------------------------------------------------

(test a-repository-is-found-by-the-path-spelling-a-person-types
  ;; WATCH-REPOSITORY stores its root as NORMALIZE-ROOT left it -- a truename,
  ;; so `~' is already expanded -- while a designator arrives as whatever was
  ;; typed. Comparing the two as strings therefore failed on exactly the
  ;; spelling CLAUDE.md and the console both encourage: `watch "~/lisp/Loom"'
  ;; registered the repository and `unwatch "~/lisp/Loom"' could not find it,
  ;; because the name branch wants "Loom" and the string branch wants the
  ;; expanded path.
  ;;
  ;; No fixture on disk: the home directory is a directory that certainly
  ;; exists, so a synthetic repository rooted there tests the normalisation
  ;; without writing anything anywhere.
  (let* ((home (probe-file (user-homedir-pathname)))
         (repository (loom-workspace::make-repository :root home :name "home-fixture"))
         (*repositories* (list repository)))
    (is (eq repository (find-repository "home-fixture"))
        "by name, as before")
    (is (eq repository (find-repository (namestring home)))
        "by the spelling watch stored, as before")
    (is (eq repository (find-repository "~/"))
        "and by the spelling a person types, which is the fix")))

(test a-repository-with-no-declaration-gets-a-file-store
  ;; The case every repository is in until it says otherwise, and the default
  ;; has to be the one that reads the tree it was pointed at.
  (with-workspace-fixture (repository)
    (is (typep (loom-workspace::repository-document-store repository)
               'loom-docstore:file-docstore))))

(defun rewatch-with-declaration (repository text)
  "Declare TEXT in the fixture's .loom/frameworks.yaml and watch the tree again.

The fixture's repository has already built and memoised a store, so a
declaration written now reaches nothing until the tree is watched fresh. Both
halves are here rather than in each test because forgetting the unwatch leaves
the old repository registered and the new one is never the one under test."
  (unwatch-repository (repository-name repository))
  (write-file ".loom/frameworks.yaml" text)
  (watch-repository *fixture-root* :monitor nil :quiet t))

(test a-declared-store-kind-is-the-one-the-repository-gets
  ;; DES-0052, end to end: .loom/frameworks.yaml names a kind, the factory
  ;; builds it, and the pipeline indexes through it. The in-memory store is
  ;; what makes this observable -- it holds nothing, so the two YAML documents
  ;; sitting on disk are indexed by nobody, which is exactly what declaring a
  ;; store that is not the tree means.
  (with-workspace-fixture (repository)
    (let ((fresh (rewatch-with-declaration repository "document-store:
  kind: memory
")))
      (is (typep (loom-workspace::repository-document-store fresh)
                 'loom-docstore:memory-docstore)
          "the declaration was not read")
      (is (zerop (getf (repository-status fresh) :documents))
          "the store holds no document, so the index must hold none")
      (is-true (probe-file (merge-pathnames "docs/decisions/DEC-0001.yaml"
                                            *fixture-root*))
               "and the file is still on disk, indexed by nobody"))))

(test a-declared-kind-nothing-registered-refuses-when-the-tree-is-watched
  ;; DES-0052 D6. The store is built inside WATCH-REPOSITORY\'s first index, so
  ;; a developer who mistyped a kind hears about it where they are standing
  ;; rather than from a poll two seconds later on a supervised service.
  (with-workspace-fixture (repository)
    (signals loom-docstore:docstore-refused
      (rewatch-with-declaration repository "document-store:
  kind: jira
"))))

(test a-declared-key-the-store-does-not-take-refuses-the-same-way
  ;; The other half of DES-0052 D4, at the level a person meets it: the
  ;; workspace hands the block over without reading it, so a misspelled key is
  ;; refused by the store or by nobody.
  (with-workspace-fixture (repository)
    (signals loom-docstore:docstore-refused
      (rewatch-with-declaration repository "document-store:
  kind: file
  extnesion: yaml
"))))

(test watching-a-repository-indexes-source-and-documents-together
  (with-workspace-fixtures (repository)
    (let ((g (repository-graph repository)))
      (is (= 3 (length (entities-of-type g :function))))
      (is (= 1 (length (entities-of-type g :decision))))
      (is (= 1 (length (entities-of-type g :rule)))
          "one watcher, one pipeline, both kinds of file"))))

(test the-pipeline-resolves-cross-file-calls
  ;; The reason the ordering in RESOLVE-AND-CHECK exists: beta calls alpha,
  ;; and no file-scoped analyzer can see that.
  (with-workspace-fixture (repository)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=))
           (callers (mapcar (lambda (r) (name (get-entity g (from-id r))))
                            (relationships-to g (id alpha) :rel-type :calls))))
      (is (member "beta" callers :test #'string=)
          "resolved across a file boundary")
      (is (member "alpha-twice" callers :test #'string=)
          "and within one"))))

(test the-pipeline-resolves-document-links
  (with-workspace-fixtures (repository)
    (let* ((g (repository-graph repository))
           (decision (first (entities-of-type g :decision)))
           (targets (mapcar (lambda (r) (name (get-entity g (to-id r))))
                            (relationships-from g (id decision) :rel-type :decides))))
      (is (equal '("alpha") targets)))))

(test the-pipeline-runs-the-rule-checks
  (with-workspace-fixtures (repository)
    (let ((g (repository-graph repository)))
      ;; BUG-0010, and CON-0003's question asked of the assertion below: a rule
      ;; whose from-system: matches no entity reports zero exactly the way a
      ;; rule that matched entities and found nothing does. The NULL assertion
      ;; alone cannot tell "checked and clean" from "never checked", so the
      ;; premise gets asserted first -- something has to be in :KERNEL for the
      ;; fixture's RULE-0001 to have had anything to say.
      (is (plusp (length (entities-in-system g :kernel)))
          "nothing landed in the system the fixture's rule names")
      (is (null (entities-of-type g :rule-violation))
          "the fixture is clean, and a clean tree must report nothing"))))

(test status-says-whether-a-repository-has-a-vector-store
  ;; BUG-0067. :STATE reports :READY for a repository whose store is built and
  ;; for one that has none, so a caller waiting on :READY cannot tell whether
  ;; `context' will answer with semantic candidates or without them. A sweep of
  ;; DES-0050's fusion settings was measured against a service whose stores had
  ;; all gone, and the figure it printed was mismatch.md's pre-dense bar --
  ;; reproduced from a document rather than measured.
  ;;
  ;; A keyword and not a boolean, and the membership check is the point: NIL
  ;; encodes to JSON null, which is also what a service too old to carry the
  ;; field returns, so nought and uncomputed would read alike. DES-0002 R10.
  (with-workspace-fixture (repository)
    (let ((status (repository-status repository)))
      (is (member :vector-store status)
          "the key is absent, so a caller cannot ask the question at all")
      (is (member (getf status :vector-store) '(:present :absent))
          ":VECTOR-STORE must say which, not answer NIL")
      (is (eq :absent (getf status :vector-store))
          "the fixture built no store, so the answer is :ABSENT")
      (is (member :vectors status)
          "the count key is absent")
      (is (null (getf status :vectors))
          "nothing has queried this repository, so no store is loaded"))))

(test status-reports-what-a-developer-needs-to-see
  (with-workspace-fixtures (repository)
    (let ((status (repository-status repository)))
      (is (= 4 (getf status :files)))
      (is (plusp (getf status :entities)))
      (is (= 2 (getf status :documents)))
      (is (zerop (getf status :unresolved-references)))
      (is (zerop (getf status :errors)))
      ;; DES-0002 R10. Asserted present *and* zero, not merely zero: the
      ;; fixture has no definer calls, so a key that is absent and a count that
      ;; is genuinely nought both read as NIL through GETF, and only the
      ;; membership check tells them apart. Zero is also what these read at
      ;; every step before the generated definitions land, which is what makes
      ;; them the acceptance instrument on Loom's own tree.
      (dolist (key '(:test-entities :tested-units :unhandled-definer-macros
                     ;; REQ-0053 R7, read the same way. These three are nought
                     ;; on a tree of Lisp for a different reason than the three
                     ;; above -- no analyzer writes :TEST-FILE-P for a language
                     ;; whose test files have no include glob to match -- and
                     ;; the membership check is what separates that from a key
                     ;; nobody computes.
                     :test-files :test-files-without-cases :unnamed-tests))
        (is (member key status) "~s is missing from status" key)
        (is (eql 0 (getf status key))
            "~s must be nought for a fixture with no definer calls" key))
      ;; BUG-0030 F1, read the same way and for the same reason: a dropped edge
      ;; is a relationship the index knows it is missing, and a key that is
      ;; absent reads through GETF exactly like a count that is nought.
      (is (member :dropped-edges status))
      (is (eql 0 (getf status :dropped-edges))))))

(defun ws-file (graph path &rest properties)
  (add-entity graph (make-instance 'file-entity
                                   :name path :origin-file path
                                   :properties (properties-table
                                                (list* :path path properties)))))

(defun ws-case (graph name path)
  (add-entity graph (make-instance 'test-entity
                                   :name name :origin-file path
                                   :properties (properties-table
                                                (list :file path :start-line 1 :end-line 3
                                                      :language :javascript
                                                      :framework :vitest)))))

(test a-test-file-with-no-case-in-it-is-counted-and-a-covered-one-is-not
  ;; REQ-0053 R7. The report that keeps the recognition rule honest: a file the
  ;; runner would run and the analyzer recognised nothing in is a convention it
  ;; does not know about. front-end's one is src/models/test/fixture.js, which
  ;; imports `test' from vitest to write shared assertions and declares no case.
  ;;
  ;; Nought first, and it is not ceremony: a count only ever read when it is
  ;; non-zero cannot be told from a count nobody computes.
  (let ((graph (make-graph)))
    (is (zerop (length (loom-workspace::test-files graph))))
    (ws-file graph "src/a.test.js" :test-file-p t :unnamed-tests 2)
    (ws-file graph "src/fixture.test.js" :test-file-p t)
    (ws-file graph "src/a.js")
    (ws-case graph "alpha > works" "src/a.test.js")
    (is (equal '("src/a.test.js" "src/fixture.test.js")
               (sort (mapcar (lambda (f) (getp f :path)) (loom-workspace::test-files graph)) #'string<))
        "a source file with no flag is not a test file")
    (is (equal '("src/fixture.test.js")
               (mapcar (lambda (f) (getp f :path)) (loom-workspace::test-files-without-cases graph)))
        "and the one the analyzer found nothing in is the one worth reporting")))

(test a-document-that-will-not-parse-is-counted-and-named
  ;; BUG-0033, and the shape is the one that caused it twice: a colon and a
  ;; space inside an unquoted YAML scalar. The analyzer's half has always
  ;; worked -- SS3.3 marks rather than omits, and the entity lands carrying
  ;; :ANALYSIS-ERROR with the parser's own line and column -- and nothing read
  ;; the property, so `status' said nothing and `check' reported a clean tree
  ;; while PLAN-0032 sat unindexed for a day and a half and BUG-0013 for twelve
  ;; days.
  ;;
  ;; The zero is asserted first and is not ceremony: a count that is only ever
  ;; read when it is non-zero cannot be told from a count nobody computes,
  ;; which is the DES-0002 R10 reading the two lines beside it already take.
  (with-workspace-fixtures (repository)
    (is (eql 0 (getf (repository-status repository) :unparsed))
        "the fixture parses, which is what makes the next assertion mean something")
    (write-file "docs/plans/PLAN-0001.yaml"
                "id: PLAN-0001
title: DES-0026 in seven steps: the walk, the tiers, the index, the ranking
status: draft
")
    ;; POLL-ONCE rather than INDEX-FILE, which is the code path and has been
    ;; since DES-0051: a document reaches the index as bytes the store handed
    ;; over, and on the in-memory store there is no file to hand INDEX-FILE.
    (poll-once repository :quiet t)
    (let ((status (repository-status repository))
          (unparsed (unparsed-facts (repository-graph repository))))
      (is (eql 1 (getf status :unparsed)))
      (is (= 1 (length unparsed)))
      (is (search "PLAN-0001.yaml" (getf (first unparsed) :path))
          "named, because a count without a path is a fact nobody can act on")
      (is (search "line 2" (getf (first unparsed) :error))
          "and the parser's own message, which is the distance between
\"a document is missing\" and \"quote the title\""))))

(test a-document-that-parses-again-stops-being-counted
  ;; The count is a function of the tree rather than of history, the same way
  ;; BUG-0030's dropped edges are: RETRACT-FILE clears the marked entity along
  ;; with everything else read from the file, and the re-analysis decides
  ;; again.
  (with-workspace-fixtures (repository)
    (write-file "docs/plans/PLAN-0001.yaml"
                "id: PLAN-0001
title: A title: with a colon
status: draft
")
    (poll-once repository :quiet t)
    (is (eql 1 (getf (repository-status repository) :unparsed)))
    (write-file "docs/plans/PLAN-0001.yaml"
                "id: PLAN-0001
title: \"A title: with a colon\"
status: draft
")
    (poll-once repository :quiet t)
    (is (eql 0 (getf (repository-status repository) :unparsed))
        "quoting the title is the whole repair, and the count says so")))

(test a-document-that-cannot-be-read-is-read-again-and-counts-as-unindexed
  ;; DES-0051 D7, the half the index dump cannot see: it is behaviour over two
  ;; polls rather than a state after one.
  ;;
  ;; A code file whose analysis fails gets no stamp, so FILE-CHANGED-P reports
  ;; it on every poll and COUNT-UNSTAMPED counts it as `unindexed'. A store
  ;; token moves past the bytes it handed out whether or not the analysis
  ;; worked, so keeping that behaviour is the workspace's job: it holds the
  ;; refs that failed, reads them again with DOCSTORE-READ on each poll, and
  ;; counts them.
  ;;
  ;; The two stores fail a read differently and recover differently, which is
  ;; why this runs on both. The file store leaves a failed address out of the
  ;; token, so CHANGED-SINCE offers the document again by itself. The in-memory
  ;; store's sequence number moves past it, so the retry is the only way back
  ;; -- and the repair here does not advance that sequence, so the last
  ;; assertion is about the retry and nothing else.
  (with-workspace-fixtures (repository)
    (is (eql 0 (getf (repository-status repository) :unindexed))
        "the fixture is fully indexed, which is what makes the count below mean
something")
    ;; Broken before its first read, and that is the case D7 is about: a
    ;; document that indexed once and then stopped reading keeps the entity it
    ;; asserted, exactly as a code file keeps the stamp of its last good read.
    ;; `unindexed' counts what the index has never held.
    (write-file "docs/plans/PLAN-0001.yaml"
                "id: PLAN-0001
title: A plan the store will not read
status: draft
")
    (break-fixture-document "docs/plans/PLAN-0001.yaml" "cannot read it")
    (poll-once repository :quiet t)
    (is (eql 1 (getf (repository-status repository) :unindexed))
        "a document the store could not read is not counted as unindexed")
    (is (null (find "PLAN-0001" (entities-of-type (repository-graph repository) :document)
                    :key #'name :test #'equal))
        "and nothing it could not read reached the index")
    (poll-once repository :quiet t)
    (is (eql 1 (getf (repository-status repository) :unindexed))
        "a second poll wrote the failure off instead of keeping it")
    (repair-fixture-document "docs/plans/PLAN-0001.yaml")
    (poll-once repository :quiet t)
    (is (eql 0 (getf (repository-status repository) :unindexed))
        "the document reads again and is still counted as unindexed")
    (is (find "PLAN-0001" (entities-of-type (repository-graph repository) :document)
              :key #'name :test #'equal)
        "a document that failed once was never read again")))

(test re-watching-a-registered-repository-starts-watching-it-again
  ;; The console's lifecycle in a live image: MAIN stops the monitors on its
  ;; way out but leaves *REPOSITORIES* populated, so the next (main) re-watches
  ;; a repository that is already registered and not being watched. That branch
  ;; used to reindex without starting a monitor, which reported `watcher:
  ;; stopped' for a repository the developer had just asked to watch.
  (with-workspace-fixtures (repository)
    (start-monitor repository)
    (is-true (monitor-running-p repository))
    (stop-monitor repository)                    ; what MAIN does on exit
    (is-false (monitor-running-p repository))
    (let ((again (watch-repository *fixture-root* :quiet t)))
      (is (eq repository again) "the same repository, not a second copy")
      (is-true (monitor-running-p again)
               "and watching it means watching it")
      (stop-monitor again))))

(test pause-keeps-the-index-and-unwatch-does-not
  ;; DEC-0004: two named states and three commands between them. The reason
  ;; pause exists at all is that this assertion has to hold -- if pausing cost
  ;; the index there would be no difference from unwatch and no reason for it.
  (with-workspace-fixtures (repository)
    (start-monitor repository)
    (is (eq :watching (getf (repository-status repository) :monitor)))
    (let ((entities (length (all-entities (repository-graph repository)))))
      (pause-repository (repository-name repository))
      (is (eq :paused (getf (repository-status repository) :monitor)))
      (is (= entities (length (all-entities (repository-graph repository))))
          "paused keeps every fact it had")
      (is (find repository (all-repositories))
          "and stays registered, so status still reports it")
      ;; watch is the resume command; there is deliberately no second name.
      (watch-repository *fixture-root* :quiet t)
      (is (eq :watching (getf (repository-status repository) :monitor)))
      (stop-monitor repository))
    (unwatch-repository (repository-name repository))
    (is (null (find repository (all-repositories)))
        "unwatch is the one that discards")))

;;; ------------------------------------------------------------------
;;; Change detection (SS8.3)
;;; ------------------------------------------------------------------

(test a-changed-file-is-reanalyzed
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
(defun alpha-thrice (x) (alpha (alpha-twice x)))
")
    (poll-once repository :quiet t)
    (is (= 4 (length (entities-of-type (repository-graph repository) :function))))))

(test a-deleted-definition-leaves-the-index
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp" "(defun alpha (x) (+ x 1))
")
    (poll-once repository :quiet t)
    (let ((names (mapcar #'name (entities-of-type (repository-graph repository)
                                                  :function))))
      (is (not (member "alpha-twice" names :test #'string=))
          "retract-file plus fresh asserts, driven by the monitor"))))

(test a-deleted-file-leaves-the-index
  (with-workspace-fixtures (repository)
    (delete-file (merge-pathnames "src/beta.lisp" *fixture-root*))
    (poll-once repository :quiet t)
    (let ((g (repository-graph repository)))
      (is (null (find "beta" (entities-of-type g :function)
                      :key #'name :test #'string=)))
      (is (not (member "src/beta.lisp" (origin-files g) :test #'string=))))))

(test cross-file-edges-survive-a-reanalysis
  ;; The TODO that RETRACT-FILE-OP left open: retracting a file drops the
  ;; inbound cross-file edges, and only the pipeline's ordering puts them back.
  ;; This is the test that says the ordering is right.
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(defun alpha (x) (+ x 2))
(defun alpha-twice (x) (alpha (alpha x)))
")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (alpha (find "alpha" (entities-of-type g :function)
                        :key #'name :test #'string=)))
      (is (member "beta" (mapcar (lambda (r) (name (get-entity g (from-id r))))
                                 (relationships-to g (id alpha) :rel-type :calls))
                  :test #'string=)
          "beta -> alpha was destroyed by the retract and rebuilt by resolution"))))

(test poll-once-that-finds-a-change-moves-indexed-at
  ;; DES-0007 R1: staleness is answered by comparing REPOSITORY-INDEXED-AT
  ;; against a process's own start time, and that comparison is a fabricated
  ;; "current" unless the monitor's own path writes the slot too. Before the
  ;; fix INDEX-REPOSITORY was its only writer.
  (with-workspace-fixtures (repository)
    (let ((before (repository-indexed-at repository)))
      ;; GET-UNIVERSAL-TIME counts whole seconds, so a poll in the same second
      ;; as the initial index would move the slot to a value EQL to the old one
      ;; and the first assertion would fail for a reason that is not the code's
      ;; -- the same whole-second fact *MTIME-SETTLE-SECONDS* records one
      ;; system down.
      (loop while (<= (get-universal-time) before) do (sleep 0.2))
      (write-file "src/gamma.lisp" "(defun gamma (x) (beta x))
")
      (let ((written (get-universal-time)))
        (poll-once repository :quiet t)
        (is (> (repository-indexed-at repository) before)
            "a poll that reindexed a file left indexed-at at the last reindex")
        (is (>= (repository-indexed-at repository) written)))
      ;; The pairing CON-0003 asks for. "Just set it every time" passes the
      ;; assertions above and fails this one, and it is the first fix a reader
      ;; reaches for -- it would make every poll of an idle tree report the
      ;; index as having just moved, which is the same fabricated answer in the
      ;; other direction.
      (let ((after (repository-indexed-at repository)))
        (loop while (<= (get-universal-time) after) do (sleep 0.2))
        (poll-once repository :quiet t)
        (is (eql after (repository-indexed-at repository))
            "a poll that found nothing moved indexed-at anyway")))))

(test a-document-only-edit-moves-indexed-at
  ;; DES-0051 D7. Documents come from the store rather than the walk, and a
  ;; poll that read only a document must still set MOVED: INDEXED-AT follows
  ;; it, and so does the vector refresh, which this cannot observe directly.
  (with-workspace-fixtures (repository)
    (let ((before (repository-indexed-at repository)))
      (loop while (<= (get-universal-time) before) do (sleep 0.2))
      (write-file "docs/decisions/DEC-0001.yaml"
                  "id: DEC-0001
type: decision
title: Alpha stays arithmetic, and says so
status: accepted
affects: [alpha]
")
      (is (plusp (poll-once repository :quiet t))
          "the poll read nothing")
      (is (> (repository-indexed-at repository) before)
          "a poll that read only a document left indexed-at where it was")
      (is (search "says so" (getp (first (entities-of-type (repository-graph repository) :decision))
                                  :title))
          "the edit did not reach the index"))))

;;; ------------------------------------------------------------------
;;; Rebuild equivalence (SS14.4)
;;; ------------------------------------------------------------------

(test reindexing-produces-an-identical-index
  ;; SS14.4 wants B and C "identical -- not merely equivalent, since ids are
  ;; derived from natural keys rather than generated".
  (with-workspace-fixtures (repository)
    (let ((before (sort (mapcar #'id (all-entities (repository-graph repository)))
                        #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal before
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<))))))

(test an-incremental-update-matches-a-full-rebuild
  (with-workspace-fixtures (repository)
    (write-file "src/beta.lisp" "(defun beta (x) (alpha-twice x))
")
    (poll-once repository :quiet t)
    (let ((incremental (sort (mapcar #'id (all-entities (repository-graph repository)))
                             #'string<))
          (edges-incremental
            (sort (mapcar #'id (all-relationships (repository-graph repository)))
                  #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal incremental
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<)))
      (is (equal edges-incremental
                 (sort (mapcar #'id (all-relationships (repository-graph repository)))
                       #'string<))
          "the highest-value assertion in the suite: the index agrees with
the files whichever way it got there"))))

(test answer-provenance-says-when-without-paying-for-drift
  ;; REQ-0065 R1 and R2. `find', `impact', `check' and `rules' are the four an
  ;; agent calls while changing the tree they are about, and they carried no
  ;; provenance at all -- the documented answer was "ask `status' when it
  ;; matters", which doubles the call count and needs the caller to know in
  ;; advance that it matters.
  ;;
  ;; R2 is the half a test can hold. :DRIFT must be absent: it is a stat per
  ;; claimed file, measured at 4.7ms to 25.6ms on `describe' when it was tried
  ;; there, and an edit that reached for INDEX-PROVENANCE here because the name
  ;; reads better would put that cost on the four cheapest commands in the
  ;; system. The absence is the requirement, so the absence is what is asserted.
  (with-workspace-fixture (repository)
    (let ((provenance (answer-provenance repository)))
      (is (not (member :drift provenance))
          "no drift -- R2 keeps a per-file stat off these four")
      (is (not (member :file provenance))
          "and no file: these answers are not about one")
      (is (member :diff provenance)
          "the fingerprint a caller compares against its previous answer")
      (is (member :indexed-at provenance)
          "and when the index was built"))))

(test a-rules-severity-is-not-checked-against-a-bugs-vocabulary
  ;; BUG-0066 F2's own defect, caught the moment the report was generalised.
  ;; A :RULE's `severity:' is error/warning/advisory and answers how strictly
  ;; the rule is enforced; a bug's is critical/major/minor and answers impact.
  ;; DEC-0007 separates the two. Checking every genre against one vocabulary
  ;; reported all nine of this tree's rules as mis-spelled -- a report whose
  ;; first run is nine false positives teaches a reader to ignore it.
  (let ((for-rule (loom-analyzer::vocabulary-fields-for :rule))
        (for-doc  (loom-analyzer::vocabulary-fields-for :document)))
    (is (equal '(:error :warning :advisory)
               (cdr (assoc "severity" for-rule :test #'string=)))
        "a rule is checked against the enforcement vocabulary")
    (is (equal '(:critical :major :minor)
               (cdr (assoc "severity" for-doc :test #'string=)))
        "and a document against the impact one")
    (is (= (length for-rule) (length for-doc))
        "the same fields either way -- only severity's vocabulary differs")))

;;; ------------------------------------------------------------------
;;; The :CALL-SITE ceiling (DES-0014 R2)
;;; ------------------------------------------------------------------

(defparameter *call-site-ceiling* 512
  "The most :CALL-SITE entities this tree may hold before something is wrong.

DES-0014 refused a node per call-name occurrence -- 4867 nodes against 1604
entities -- and adopted the sparse form instead. Entity growth is therefore
bounded by a rule rather than by a number, and DES-0014's own RISKS section
says rules drift: the failure mode if some common case starts minting a call
site is a graph that quietly quadruples, with nothing failing. This number is
the guard, and it is meant to fail loudly rather than warn.

162 measured plus 10% headroom. The three generators' populations on this tree,
counted by tools/test/call-site-census.lisp after BUG-0020's keyword fix: 20 initform
pairs, 124 resolving orphaned definer names, 18 ambiguous sites. PLAN-0014 step
5 says to use step 1's sum, which was 170 -- but step 1 predates step 2, and 8
of those 170 were the keyword-head orphans BUG-0020 removed. Using the stale
number would leave 8 counts of slack that stand for nothing, so this is the
post-step-2 sum; the plan's own step 7 verification makes the same substitution
when it says \"as step 2 left it\".

Re-measure with the census rather than adjusting this to whatever the suite
reports. A number edited to match an observation is not a ceiling.

UNCHANGED BY DES-0015, 2026-08-10, and that is the finding rather than an
omission. Package-aware resolution was expected to empty most of the ambiguous
population: DES-0015 states that all four ambiguous names on this tree are
package collisions and that all 18 sites would stop being minted. Measured
after stage C, the tree holds 161 call sites against 162 before, and the
ambiguous population fell from 18 to 16.

Only LOG-EVENT resolved. FIXTURE-INSPECTION, DISCOVER-UNITS and
READ-INSPECTION-FILE are unplaceable, because the packages they are written in
use :FIVEAM, which no declaration in this tree describes, so HOME-PACKAGE
refuses to place them and they fall back to name-only matching -- CON-0001
working exactly as designed. Naming :FIVEAM in
LOOM-ANALYZER:*EXTERNAL-PACKAGE-NAMES* would place them; the default does not,
because that would make the index depend on what the reading image happens to
have loaded.

So the ceiling stayed at 178 through DES-0015. Lowering it to track a fall that
did not happen would be the mistake the paragraph above warns about, in the
other direction.

RE-MEASURED 2026-08-12 AT 189, CEILING 208. DES-0022's structural report adds
one console command and one registry operation, and both are body-swallowing
macros whose call names become orphaned definer pairs. Census composition
before and after, which is what makes this growth rather than a defect:

    define-command      79 -> 85
    define-operation    56 -> 61
    resolving to a callee   141 -> 141
    ambiguous occurrences    16 ->  16

Every one of the eleven is a call name inside the two new macro bodies, the
resolving population is unchanged, and the ambiguous population is unchanged.
189 measured plus 10% headroom is 208, derived the same way 162 gave 178.

This is the second time in one day the ceiling fired, and the two occasions are
worth telling apart because only one was a defect. Earlier the same day it went
to 182 on four ambiguous sites, and the cause was a test helper named K-DOC
colliding with another of a different arity in one package -- a real bug the
ceiling caught before the arity error was traced. This time the census shows
new code and nothing else.

The instrument's cost is now visible: an absolute whole-tree count has to be
re-measured whenever a command or an operation is added, and each
re-measurement is an opportunity to raise it without looking. The census is
what makes that check cheap, and running it is not optional -- a number edited
to match a red suite is not a ceiling.

RE-MEASURED 2026-08-14 AT 215, CEILING 237. REQ-0021's remaining commands --
`structure', `architecture', `drift', `remove', `init' and their registry
entries. Composition, which is what makes this growth rather than a defect:

    define-operation    61 -> 72
    ambiguous occurrences  16 -> 16

Three re-measurements in three days, all from the same cause: this requirement
added six commands and six operations, and every one is a body-swallowing macro
whose call names become orphaned definer pairs. The ambiguous population has
not moved through any of it, which is the number that would have moved if
something had gone wrong.

RE-MEASURED 2026-08-14 AT 267, CEILING 294. REQ-0024's JavaScript analyzer and
its suite. Composition:

    js-test              0 -> 50
    one interface       13 -> 24
    resolve to nothing 182 -> 235
    ambiguous occurrences  16 -> 16

The whole of the growth is JS-TEST, a macro this suite defines for itself so
that a machine without node skips rather than fails. It is body-swallowing like
DEFINE-COMMAND and DEFINE-OPERATION, so its twenty uses orphan fifty definer
pairs by exactly the mechanism the three entries above it did -- a fourth
instance of one cause, not a fourth cause.

Worth stating because it looks like the opposite: none of this growth is
JavaScript. Not one :CALL-SITE in the census comes from a .js file. The
JavaScript analyzer writes :CALL-NAMES on functions and methods only, and
:CALL-SITE is minted by RESOLVE-GENERATED-DEFINITIONS from *Lisp* definer
macros, so a JavaScript tree cannot reach this population at all. Confirmed by
measurement rather than by reading: hiding tools/js/extract.js so that no
JavaScript was indexed anywhere left the count at 267 unchanged.

The ambiguous population is 16 before and 16 after, which is the number that
moves when something has gone wrong.

RE-MEASURED 2026-08-18 AT 296, CEILING 326. Two causes, and only the second is
this session's. Composition against the 2026-08-14 census, both from
tools/test/call-site-census.lisp:

    define-command      85 -> 110
    define-operation    72 ->  81
    js-test             50 ->  58
    ambiguous occurrences  16 -> 16

Most of that is the four days between the measurements, which added commands
and operations and their tests: the tree read 293 with this session's source
stashed. BUG-0030 F1 adds the last three -- one DROPPED-EDGES call in the
`check' command and DROPPED-EDGES plus DROPPED-EDGE-SUMMARY in the :CHECK
operation, all three inside a body-swallowing macro. The fifth instance of one
cause and not a fifth cause: the ambiguous population has not moved through any
of it.

RE-MEASURED 2026-08-23 AT 331, CEILING 364. PLAN-0044 S5 and S6, and the
composition says the whole of it is two console commands:

    define-command     120 -> 132
    define-operation    92 ->  92
    js-test             57 ->  57
    ambiguous occurrences   20 ->  20

Measured both ways in one sitting: the tree reads 319 with this change stashed
and 331 with it applied, and `similar' and `survey' are the twelve. The
ambiguous population did not move, which is the number that does when something
has gone wrong.

It moved once during this work, and how it was found is worth keeping. The new
test file named its fixture helper R-FUNCTION, which already exists in
src/graph/test/resolve.lisp. Different packages, so nothing collided at
runtime and the suite was green -- but Loom cannot place a package for a test
file, falls back to matching on the spelling (DES-0015), and reported all 50
calls as ambiguous. 16 became 70, this ceiling failed, and the census named
R-FUNCTION in one line. Renaming the helper put it back to 20. A test suite
that indexes its own tree caught a defect in itself that no assertion in it
was written to catch.

RE-MEASURED 2026-08-24 AT 352, CEILING UNCHANGED AT 364. REQ-0051 and PLAN-0046,
and the composition is again two macro bodies growing rather than a new cause:

    define-command     132 -> 143
    define-operation    92 -> 101
    js-test             57 ->  57
    ambiguous occurrences   20 ->  20

The federated `find' is more calls inside the same two bodies -- the console
command gained three printers and the registry entry gained a branch -- so the
count moved and the population that matters did not.

It moved once during this work too, and it is the R-FUNCTION trap a second
time, which is the reason for writing it down again. A helper added to
src/serve/operations.lisp was named FIND-ENTITY-TYPE, which already exists in
loom-ontology. Different packages, nothing collided at runtime, the suite was
green -- and Loom cannot place a package for a test file, so it fell back to
matching on the spelling and reported all 15 calls in the ontology tests as
ambiguous. 20 became 35, this ceiling failed at 367, and the census named
FIND-ENTITY-TYPE at the top of its list. Renaming it to REQUESTED-ENTITY-TYPE
put the ambiguous population back to 20 and the total to 352.

Twice now the ceiling has caught a name collision rather than the entity growth
it was written to catch, and both times the census named the colliding symbol
directly. That is worth more than the bound: DES-0015 makes a same-named
definition in a second package a real second callable, so the cost of choosing
an existing name is paid by every call site of the original.

RE-MEASURED 2026-08-27 AT 380, CEILING RAISED TO 418. REQ-0053 and PLAN-0048,
and the composition is one macro body again:

    define-command     143 -> 143
    define-operation   101 -> 102
    js-test             57 ->  84
    ambiguous occurrences   20 ->  20

Eight new JS-TESTs for the runner's forms are 27 of the 28. JS-TEST swallows
its body, so every call inside one is a site by construction -- which is what
this population is and not what it guards against. The ambiguous population did
not move, which is the number that does when a name has collided.

RE-MEASURED 2026-09-10 AT 422, CEILING RAISED TO 464. Counted by the census and
not read off the suite, which is what the paragraph above requires. The
composition, against the 2026-08-27 measurement:

    define-command     143 -> 154
    define-operation   102 -> 126
    js-test             84 ->  91
    let* / register-handler / let / dolist   -> 8
    ambiguous occurrences    20 ->  20

Every one of the three macro populations is a body-swallowing form, so a call
inside one is a site by construction. REQ-0065 is 4 of define-operation's 24:
`find', `impact', `check' and `rules' each gained an ANSWER-PROVENANCE call
inside a DEFINE-OPERATION body.

The ambiguous population is 20 for the third measurement running. That is the
number this ceiling exists to watch -- it moves when a name collides, and the
macro populations move whenever anybody writes a command -- so a rise composed
entirely of the other four is growth rather than drift.

RE-MEASURED 2026-09-11 AT 466, CEILING RAISED TO 512, and this time the
ambiguous population did its job. PLAN-0050 S13 first read 467 with the
ambiguous count at 21, and the census named the twenty-first: DOMAIN-FILTER. It
had been written twice, once in loom-process and once in loom-serve, so every
call to the name was ambiguous between two packages. The repair was to move it
into loom-workspace as DOMAIN-PROPERTY-FILTER, which both peers already depend
on -- the same home SPLIT-DESIGNATOR has, for the same reason. The population
went back to 20.

That is what this ceiling is for. The macro populations grow whenever anybody
writes a command and say nothing; the ambiguous count moved by one and named
the collision.

The composition at 466, against the 2026-09-10 measurement:

    define-command     154 -> 162
    define-operation   126 -> 129
    js-test             91 ->  91
    domain-test          0 ->  33
    let* / register-handler / let / dolist    8 -> 8
    ambiguous occurrences    20 ->  20

domain-test is new and is PLAN-0050 S8's fixture macro. It swallows its body
like js-test does, so every call inside one is a site by construction.

418 is 380 plus 10% headroom, the rule the first measurement used.")

(defparameter *python-call-site-ceiling* 128
  "The most :CALL-SITE entities Python files in this tree may hold.

Measured 2026-10-05 at PLAN-0056 step 8: 116, which is 86 :MODULE sites and 30
:VARIABLE sites from the ten scripts under tools/. They are counted apart from
*CALL-SITE-CEILING* because they are a population DES-0053 D4 defines on
purpose -- a call at a module's top level has no definition to start from, and
`if __name__ == \"__main__\": main()' is how a script's entry function stops
looking dead -- and adding them to the Lisp ceiling would have taken its
headroom to buy them. The Lisp population is 503 against 512 and the ambiguous
count in it is 40. 128 is 116 plus 10% headroom, the rule the first measurement
used.")

(test a-call-site-exists-only-where-a-calls-edge-from-a-definition-is-impossible
  ;; DES-0014 R2, over this tree rather than a fixture, because the ceiling is
  ;; a whole-tree property and the workspace fixture is four synthetic files.
  ;;
  ;; Written before anything mints, which is deliberate rather than premature:
  ;; it passes trivially at zero today, so every generator step lands against a
  ;; guard already in place instead of one written afterwards to fit the number
  ;; it got. That also means this test cannot fail for the right reason yet --
  ;; the population it bounds is empty until PLAN-0014 step 6. What it does
  ;; assert today is that the measurement is real: it indexes the actual tree
  ;; and counts the actual type, so the assertion is wired to something rather
  ;; than vacuous.
  (let* ((root (asdf:system-relative-pathname :loom-workspace "../../"))
         (repository (watch-repository root :monitor nil :quiet t)))
    (unwind-protect
         (let* ((all (entities-of-type (repository-graph repository) :call-site))
                (python (remove-if-not (lambda (site) (eq :python (getp site :language))) all))
                (sites (set-difference all python)))
           (is (<= (length python) *python-call-site-ceiling*)
               "~d Python :CALL-SITE entities against a ceiling of ~d."
               (length python) *python-call-site-ceiling*)
           (is (<= (length sites) *call-site-ceiling*)
               "~d :CALL-SITE entities against a ceiling of ~d. DES-0014: \"A
:CALL-SITE entity is minted exactly when a call name cannot be expressed as a
:CALLS edge from an existing definition entity. Never otherwise.\" A count over
the ceiling means some common case has started minting one, which is the
uniform model this design priced at 4867 entities and refused."
               (length sites) *call-site-ceiling*))
      (unwatch-repository (repository-name repository)))))

;;; ------------------------------------------------------------------
;;; Enrichment (DES-0011): the orchestration
;;; ------------------------------------------------------------------
;;;
;;; A stub inspector rather than the real one throughout. What is under test
;;; here is the ordering ENRICH-REPOSITORY owns -- inspectors, then the merge,
;;; then resolution -- and a real child SBCL would make every assertion below
;;; depend on the fixture tree also being a loadable ASDF system, which it is
;;; not and should not have to be. The child itself is tested in
;;; src/analyzer/test/inspector.lisp.

;;; Qualified rather than imported: LOOM-WORKSPACE uses LOOM-ANALYZER but does
;;; not re-export its protocol, and widening this test package's :USE list to
;;; reach four symbols would pull in the whole analyzer surface.

(defclass stub-inspector (loom-analyzer:inspector)
  ((inspection :initarg :inspection :reader stub-inspector-inspection))
  (:default-initargs :language :lisp))

(defmethod loom-analyzer:inspector-available-p ((inspector stub-inspector) root)
  (declare (ignore root))
  (values t nil))

(defmethod loom-analyzer:inspect-repository ((inspector stub-inspector) root &key)
  (declare (ignore root))
  (stub-inspector-inspection inspector))

(defun fixture-inspection ()
  "What an inspector would report about the fixture repository: BETA, which the
text pass already holds, and GENERATED-THING, which exists nowhere in the
source -- plus the call between them, which is only expressible once both
endpoints resolve."
  (list :loom-inspection 1
        :language :lisp
        :units '((:unit "fixture" :status :loaded))
        :definitions
        (list (list :kind :function :name "beta" :package "fixture"
                    :file "src/beta.lisp" :start-line 1 :end-line 1)
              (list :kind :function :name "generated-thing" :package "fixture"
                    :file "src/alpha.lisp" :start-line 2 :end-line 2
                    :system :kernel))
        :calls
        (list (list :caller (list :function "beta" "fixture")
                    :caller-file "src/beta.lisp"
                    :callee (list :function "generated-thing" "fixture")))))

(defun stub-inspectors (&optional (inspection (fixture-inspection)))
  (list (make-instance 'stub-inspector :inspection inspection)))

(defun named-function (graph name)
  (find name (entities-of-type graph :function) :key #'name :test #'string=))

(test enrichment-adds-what-the-image-saw-and-leaves-the-text-pass-alone
  ;; The step 2 guard re-run one layer up, on a real index built by the real
  ;; analyzers rather than by hand.
  (with-workspace-fixture (repository)
    (let* ((graph (repository-graph repository))
           (alpha (named-function graph "alpha"))
           (before (getp alpha :call-names))
           (beta (named-function graph "beta")))
      (enrich-repository repository :quiet t :inspectors (stub-inspectors))
      (let ((minted (named-function graph "generated-thing")))
        (is (not (null minted)))
        (is (eq :introspected (source minted)))
        (is (equal "src/alpha.lisp" (origin-file minted))
            "so editing alpha.lisp ages it out")
        (is (find (id minted)
                  (relationships-from graph (id beta) :rel-type :calls)
                  :key #'to-id :test #'equal)
            "the edge only the image could see"))
      (is (equal before (getp (named-function graph "alpha") :call-names))
          "and the text pass's resolution input is untouched")
      (is (member "beta" (mapcar (lambda (r) (name (get-entity graph (from-id r))))
                                 (relationships-to graph (id alpha) :rel-type :calls))
                  :test #'string=)
          "as are the edges derived from it"))))

(defun confirming-inspection ()
  "What an inspector would report about a call the text pass already recorded:
BETA calling ALPHA, both definitions already in the index.

Separate from FIXTURE-INSPECTION rather than folded into it because it exists
for one property the other cannot show. FIXTURE-INSPECTION's only edge is
image-only -- BETA to GENERATED-THING -- and RESOLVE-CALLS cannot re-derive
that one, because the image pass writes no :CALL-NAMES. A *confirmed* edge is
the one resolution re-asserts over."
  (list :loom-inspection 1
        :language :lisp
        :units '((:unit "fixture" :status :loaded))
        :definitions
        (list (list :kind :function :name "alpha" :package "kernel"
                    :file "src/alpha.lisp" :start-line 2 :end-line 2)
              (list :kind :function :name "beta" :package "fixture"
                    :file "src/beta.lisp" :start-line 1 :end-line 1))
        :calls
        (list (list :caller (list :function "beta" "fixture")
                    :caller-file "src/beta.lisp"
                    :callee (list :function "alpha" "kernel")))))

(defun beta-calls-alpha (graph)
  "The one :CALLS edge both passes see in the fixture."
  (let ((alpha (id (named-function graph "alpha"))))
    (find alpha (relationships-from graph (id (named-function graph "beta"))
                                    :rel-type :calls)
          :key #'to-id :test #'equal)))

(test a-confirmed-edge-keeps-its-agreement-record-through-the-whole-pass
  ;; BUG-0015, at the layer where it lives. Every other assertion on :SOURCES is
  ;; a loom-graph unit test that stops at APPLY-TRANSACTION -- the near side of
  ;; the seam where the property was destroyed. ENRICH-REPOSITORY then calls
  ;; RESOLVE-AND-CHECK, whose RESOLVE-CALLS re-asserts this very edge with no
  ;; properties and :SOURCE :STRUCTURAL, and ABSORB-PROPERTIES CLRHASHes the
  ;; union away. So the property was written in loom-graph, erased in
  ;; loom-workspace, and no test on either side of the boundary could see both.
  (with-workspace-fixture (repository)
    (let ((graph (repository-graph repository))
          (inspectors (stub-inspectors (confirming-inspection))))
      (enrich-repository repository :quiet t :inspectors inspectors)
      (let ((edge (beta-calls-alpha graph)))
        (is (not (null edge)))
        (is (equal '(:structural :introspected) (getp edge :sources))
            "agreement has to survive the resolution ENRICH-REPOSITORY runs itself")
        (is (eq :introspected (source edge))))
      ;; The second erasure, which has a different trigger and needs its own
      ;; assertion: a poll of an unrelated file re-runs RESOLVE-AND-CHECK over
      ;; the whole index, and RESOLVE-CALLS re-asserts every text-derivable edge
      ;; whether or not its own files moved. src/delta.lisp is a file neither
      ;; endpoint lives in, so nothing here is the aging-out that DES-0011
      ;; intends.
      (write-file "src/delta.lisp" "(defun delta (x) (beta x))
")
      (is (= 1 (poll-once repository :quiet t)))
      (let ((edge (beta-calls-alpha graph)))
        (is (not (null edge)) "the edge itself survives -- it is text-derivable")
        ;; Asserted as it is rather than as R6 would like it. The fix above is
        ;; ENRICH-REPOSITORY re-deriving the merge after its own resolution; it
        ;; cannot reach a poll that happens later, and the alternatives that
        ;; could -- teaching RESOLVE-CALLS about provenance, or keeping every
        ;; inspection resident and re-merging it on the poll path -- trade away
        ;; DEC-0003 or DES-0011 R9 respectively. What is left is a degradation
        ;; rather than a lie, in exactly the sense DES-0011 already promises:
        ;; the edge stands as the text pass's own, and the agreement returns on
        ;; the next enrich. BUG-0015 carries the residue.
        (is (null (getp edge :sources))
            "the union is gone until the next enrich, and this is the record of that")
        (is (eq :structural (source edge))))
      (enrich-repository repository :quiet t :inspectors inspectors)
      (is (equal '(:structural :introspected) (getp (beta-calls-alpha graph) :sources))
          "which is what makes the line above a degradation and not a loss"))))

(test a-language-with-no-inspector-is-a-recorded-absence
  ;; REQ-0018 R2: not an error, not a failure, and above all not silence -- a
  ;; pass that reported nothing would be indistinguishable from one that agreed
  ;; with the tree completely.
  (with-workspace-fixture (repository)
    (let* ((loom-analyzer:*inspectors* '())
           (graph (repository-graph repository))
           (before (length (all-entities graph)))
           (report (enrich-repository repository :quiet t))
           (absence (first (getf report :absences))))
      (is (= 1 (length (getf report :absences))))
      (is (eq :lisp (getf absence :language)))
      (is (search "no inspector" (getf absence :reason)))
      (is (= before (length (all-entities graph)))
          "and the index the text pass built stands unchanged")
      (is (zerop (getf report :added))))))

(test an-image-minted-definition-resolves-a-text-call-in-the-same-run
  ;; The compose property, and the reason RESOLVE-AND-CHECK runs last rather
  ;; than first. GAMMA records a call to a name nothing defines; the moment the
  ;; image mints it, the text pass's own record resolves into a :structural
  ;; edge. Called before the merge, resolution would defer this to the next
  ;; poll, so the assertion fails if the order is reversed.
  (with-workspace-fixture (repository)
    (write-file "src/gamma.lisp" "(defun gamma (x) (generated-thing x))
")
    (poll-once repository :quiet t)
    (let* ((graph (repository-graph repository))
           (gamma (named-function graph "gamma")))
      (is (member "generated-thing" (getp gamma :unresolved-calls) :test #'string=)
          "unresolved before, because nothing defines it")
      (enrich-repository repository :quiet t :inspectors (stub-inspectors))
      (is (null (member "generated-thing" (getp gamma :unresolved-calls)
                        :test #'string=))
          "and resolved after, in the same run")
      (is (find (id (named-function graph "generated-thing"))
                (relationships-from graph (id gamma) :rel-type :calls)
                :key #'to-id :test #'equal)))))

(test an-introspected-fact-ages-out-through-a-real-poll-and-a-real-enrich
  ;; PLAN-0010 step 11's "aging check, by hand", as an automated regression
  ;; instead of a one-time manual measurement. The graph-level tests in
  ;; src/graph/test/enrich.lisp prove the mechanism -- RETRACT-FILE, called
  ;; directly as an op, ages an introspected fact out -- but that is not the
  ;; same claim as "editing a file through the real pipeline does this",
  ;; because what actually calls RETRACT-FILE on an edit is INDEX-FILE's own
  ;; ops, reached through POLL-ONCE, not a hand-built transaction. This is the
  ;; test of the real path.
  (with-workspace-fixture (repository)
    (let ((inspectors (stub-inspectors))
          (graph (repository-graph repository)))
      (enrich-repository repository :quiet t :inspectors inspectors)
      (is (not (null (named-function graph "generated-thing")))
          "the image-minted fact exists after the first enrich")
      ;; Editing alpha.lisp -- GENERATED-THING's own origin-file -- through
      ;; the real pipeline: WRITE-FILE plus POLL-ONCE, not RETRACT-FILE by
      ;; hand. The content changes materially so FILE-CHANGED-P has no
      ;; ambiguity to resolve by way of the settle window (CON-0002).
      (write-file "src/alpha.lisp"
                  "(in-package :kernel)
(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
(defun alpha-thrice (x) (alpha (alpha-twice x)))
")
      (is (= 1 (poll-once repository :quiet t)))
      (is (null (named-function graph "generated-thing"))
          "gone with the file it was minted from -- no enrich involved, and
no code outside the pipeline POLL-ONCE already runs")
      (is (not (null (named-function graph "alpha-thrice")))
          "the text pass's own definitions in the same file are back, which is
what tells this apart from the file simply having vanished")
      (enrich-repository repository :quiet t :inspectors inspectors)
      (is (not (null (named-function graph "generated-thing")))
          "and the next enrich puts it back"))))

(test status-reports-enrichment-as-scalars
  ;; DES-0011 R8. Scalars because loom-serve's :STATUS operation serializes
  ;; this plist to JSON for REST and MCP callers and no rule covers that
  ;; boundary -- a nested plist is the shape most likely to arrive as something
  ;; a client cannot read.
  (with-workspace-fixture (repository)
    (let ((before (repository-status repository)))
      (dolist (key '(:enrichment-runs :enriched-units :enrichment-gaps :enrichment-at))
        (is (member key before) "~s is missing from status" key))
      (is (eql 0 (getf before :enrichment-runs)))
      (is (eql 0 (getf before :enriched-units)))
      (is (null (getf before :enrichment-at))
          "which is what tells \"never run\" from \"run and found nothing\""))
    (enrich-repository repository :quiet t :inspectors (stub-inspectors))
    (let ((after (repository-status repository)))
      (is (eql 1 (getf after :enrichment-runs)))
      (is (eql 1 (getf after :enriched-units)))
      (is (eql 0 (getf after :enrichment-gaps)))
      (is (integerp (getf after :enrichment-at)))
      (dolist (key '(:enrichment-runs :enriched-units :enrichment-gaps :enrichment-at))
        (is (not (consp (getf after key))) "~s must not be a list" key)))))

;;; ------------------------------------------------------------------
;;; The SERIOUS-CONDITION guard (DES-0011, RULE-0004)
;;; ------------------------------------------------------------------
;;;
;;; ENRICH-REPOSITORY guards each inspector with SERIOUS-CONDITION rather than
;;; INDEX-FILE's ERROR, and its own comment names the reason: "a per-language
;;; inspector nobody in this file wrote". RULE-0004's own example is the shape
;;; that reason has to survive -- cl-yaml's conditions are defined as direct
;;; subtypes of CONDITION, not of ERROR, and (measured directly under
;;; /usr/bin/sbcl) not of SERIOUS-CONDITION either: (typep (make-condition
;;; '(define-condition foo () ())) 'serious-condition) is NIL, and a
;;; handler-case naming serious-condition does not catch an instance signalled
;;; with ERROR the function unless the condition class itself descends from
;;; error or storage-condition. So the two tests below are not redundant: the
;;; first is the case the current guard actually catches (an ERROR subtype, by
;;; far the common case and the only one exercised anywhere in this suite
;;; before now); the second is the case its own justifying comment names and
;;; that a SERIOUS-CONDITION guard does not in fact reach.

(defclass erroring-inspector (loom-analyzer:inspector) ()
  (:default-initargs :language :lisp))

(defmethod loom-analyzer:inspector-available-p ((inspector erroring-inspector) root)
  (declare (ignore root))
  (values t nil))

(defmethod loom-analyzer:inspect-repository ((inspector erroring-inspector) root &key)
  (declare (ignore root))
  (error "the toolchain misbehaved"))

(define-condition bare-condition-toolchain-failure (condition)
  ((text :initarg :text :reader bare-condition-toolchain-failure-text))
  (:report (lambda (c s) (format s "~a" (bare-condition-toolchain-failure-text c))))
  (:documentation "cl-yaml's own shape, reproduced: (define-condition foo () ...)
with no ERROR or SERIOUS-CONDITION ancestor. RULE-0004 names this convention as
not unusual for a library to use."))

(defclass bare-condition-inspector (loom-analyzer:inspector) ()
  (:default-initargs :language :lisp))

(defmethod loom-analyzer:inspector-available-p ((inspector bare-condition-inspector) root)
  (declare (ignore root))
  (values t nil))

(defmethod loom-analyzer:inspect-repository ((inspector bare-condition-inspector) root &key)
  (declare (ignore root))
  (error 'bare-condition-toolchain-failure :text "toolchain misbehaved, not an error"))

(test a-recorded-error-is-a-plist-and-status-can-carry-it
  ;; BUG-0030 D2's producer. This recorded `(cons path message)`, which
  ;; REPOSITORY-STATUS puts on :LAST-ERROR and every REST and MCP caller has
  ;; serialized to JSON -- and the walker in loom-serve reaches an improper
  ;; list through its LISTP clause and signals a TYPE-ERROR naming the cdr.
  ;; Nothing here can encode JSON, which is why the assertion is the shape: a
  ;; proper list with the two keys, which is what json.lisp's own test then
  ;; encodes. The entry outlives its request, so the wrong shape took every
  ;; later `status' with it until the process was restarted.
  (with-workspace-fixture (repository)
    (let ((report (enrich-repository repository :quiet t
                                     :inspectors (list (make-instance 'erroring-inspector)))))
      (declare (ignore report))
      (let ((entry (first (repository-errors repository))))
        (is (listp (cdr entry)) "an improper list is what wedged the encoder")
        (is (equal "enrich" (getf entry :path)))
        (is (search "misbehaved" (getf entry :message))))
      (let ((last (getf (repository-status repository) :last-error)))
        (is (listp (cdr last)))
        (is (search "misbehaved" (getf last :message)))))))

(test enrich-repository-survives-an-inspector-that-signals-an-ordinary-error
  (with-workspace-fixture (repository)
    (let ((report (enrich-repository repository :quiet t
                                     :inspectors (list (make-instance 'erroring-inspector)))))
      (is (not (null report)) "the call must return rather than unwind the caller")
      (is (search "misbehaved" (getf (first (repository-errors repository)) :message)))
      (is (= 1 (length (getf report :absences)))))))

(test enrich-repository-survives-an-inspector-that-signals-a-bare-condition
  ;; The case ENRICH-REPOSITORY's own comment names and SERIOUS-CONDITION does
  ;; not reach. If this regresses to naming ERROR or stays at SERIOUS-CONDITION
  ;; without widening, the condition escapes ENRICH-REPOSITORY, escapes
  ;; RUN-COMMAND's own ERROR-only guard (src/process/console.lisp), and takes
  ;; the console down for a toolchain condition that named itself no differently
  ;; than a rule violation report.
  (with-workspace-fixture (repository)
    (let ((report (enrich-repository repository :quiet t
                                     :inspectors (list (make-instance 'bare-condition-inspector)))))
      (is (not (null report)) "the call must return rather than unwind the caller")
      (is (search "misbehaved" (getf (first (repository-errors repository)) :message)))
      (is (= 1 (length (getf report :absences)))))))

(test a-poll-never-enriches-and-can-be-shown-not-to-have
  ;; DES-0011 R9, written so it can fail. "No introspected entity appeared
  ;; after a poll" would pass on a tree where enrichment does nothing at all,
  ;; which proves nothing -- so the poll is shown to have done its own work
  ;; (the file really was reanalyzed) and the counter is shown to be capable of
  ;; moving (an explicit call moves it). Only then does the middle assertion
  ;; mean the poll chose not to.
  ;;
  ;; The trap is BUG-0008's: a heavyweight lifecycle operation wired into a path
  ;; that runs on a timer. Here it would be a whole child SBCL loading the
  ;; target, every two seconds.
  (with-workspace-fixture (repository)
    (let ((inspectors (stub-inspectors)))
      (is (eql 0 (getf (repository-status repository) :enrichment-runs)))
      (write-file "src/alpha.lisp"
                  "(in-package :kernel)
(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
(defun alpha-thrice (x) (alpha (alpha-twice x)))
")
      (is (= 1 (poll-once repository :quiet t)))
      (is (= 4 (length (entities-of-type (repository-graph repository) :function)))
          "the poll really did its own work, so its not enriching is a choice")
      (is (eql 0 (getf (repository-status repository) :enrichment-runs))
          "and nothing on the poll path reaches ENRICH-REPOSITORY")
      (enrich-repository repository :quiet t :inspectors inspectors)
      (is (eql 1 (getf (repository-status repository) :enrichment-runs))
          "the counter can move; the poll declined to move it"))))

;;; ------------------------------------------------------------------
;;; Generated definitions (DES-0002): the lifecycle
;;; ------------------------------------------------------------------

(test a-macro-that-stops-being-a-definer-un-mints-what-it-generated
  ;; PLAN-0001 step 5c, and DES-0002's "dangerous step" -- RESOLVE-GENERATED-
  ;; DEFINITIONS owns a lifecycle no earlier resolution pass has had to carry.
  ;; A macro can stop qualifying as a definer in its own file while the call
  ;; site's file never changes, so no single RETRACT-FILE is guaranteed to
  ;; invalidate the entity the call site used to mint. Both new files are
  ;; written inside the test body rather than into MAKE-FIXTURE-REPOSITORY, per
  ;; PLAN-0001's own warning that the fixture's entity counts are asserted
  ;; exactly elsewhere.
  (with-workspace-fixture (repository)
    (write-file "src/gen.lisp"
                "(defmacro def-widget (name)
  `(defun ,name () :widget))
")
    (write-file "src/call.lisp"
                "(def-widget my-widget)
")
    (let ((reindexed (poll-once repository :quiet t)))
      (is (= 2 reindexed) "both new files were seen and analyzed"))
    (let ((g (repository-graph repository)))
      (is (not (null (find "my-widget" (entities-of-type g :function)
                           :key #'name :test #'string=)))
          "the call site minted an entity that exists nowhere as a defun"))
    ;; The macro edited so its template no longer qualifies as a definer -- a
    ;; PROGN around a SETF, the false-positive shape DES-0002 predicts for
    ;; DEFINE-COMMAND -- while the call site's own file is left untouched.
    (write-file "src/gen.lisp"
                "(defmacro def-widget (name)
  `(progn (setf *last-widget* ',name)))
")
    (let ((reindexed (poll-once repository :quiet t)))
      (is (= 1 reindexed) "only gen.lisp changed; call.lisp is untouched"))
    (let ((g (repository-graph repository)))
      ;; THE ASSERTION THAT MATTERS: the disappearance, not merely the earlier
      ;; appearance. Without the retract half the entity survives, because
      ;; nothing about call.lisp changed for RETRACT-FILE to act on.
      (is (null (find "my-widget" (entities-of-type g :function)
                      :key #'name :test #'string=))
          "the macro no longer produces it, so this pass's own recomputed
output must take it back -- no single file's retraction would have"))
    ;; The drift question PLAN-0001 asks be checked here specifically: a fresh
    ;; rebuild has to land on exactly the incrementally-polled index, or the
    ;; retract half under- or over-corrected and only this comparison shows it.
    (let ((incremental (sort (mapcar #'id (all-entities (repository-graph repository)))
                             #'string<))
          (edges-incremental
            (sort (mapcar #'id (all-relationships (repository-graph repository)))
                  #'string<)))
      (reindex-repository repository :quiet t)
      (is (equal incremental
                 (sort (mapcar #'id (all-entities (repository-graph repository)))
                       #'string<))
          "a rebuild must not still hold the entity the incremental poll took back")
      (is (equal edges-incremental
                 (sort (mapcar #'id (all-relationships (repository-graph repository)))
                       #'string<))))))

;;; ------------------------------------------------------------------
;;; Concurrency (BUG-0004, DES-0004 R8(b) and R8(c))
;;; ------------------------------------------------------------------
;;;
;;; The one test here that runs two threads, and the reason BUG-0004 survived
;;; as long as it did: every other test in this file drives POLL-ONCE directly,
;;; which is the right way to test analysis but means the thread the monitor
;;; would have run it on never exists.
;;;
;;; It drives REINDEX-REPOSITORY and POLL-ONCE from separate threads with no
;;; sleep between calls rather than starting a real monitor, because the
;;; monitor's own two-second cadence would need luck to collide even once
;;; inside a sensible test budget (DES-0004 R8(b)).
;;;
;;; Two traps, both mechanical. fiveam's IS records into thread-local special
;;; variables, so every assertion below runs on the main thread after both
;;; joins -- a test whose checks live in workers passes unconditionally. And
;;; DETECT-DELETIONS calls APPLY-TRANSACTION with no handler of its own, so a
;;; collision can escape POLL-ONCE entirely and kill the worker, which
;;; JOIN-THREAD would then re-signal in the main thread and report as a suite
;;; that fell over rather than a test that failed. Each worker catches
;;; SERIOUS-CONDITION -- RULE-0004's type, and MONITOR-LOOP's -- and returns it.

(defparameter *stress-iterations* 200
  "Rebuilds and polls each worker performs. Chosen by measurement, not by
feel: against the unlocked tree 60 iterations reproduced the collision in
1 run of 5 and 200 in 4 of 5, and a test that fires one time in five is a
coin toss dressed as evidence (CON-0003).")

(defun stress-call (repository n thunk)
  "Call THUNK N times, sampling REPOSITORY's recorded errors after each call.
Returns (condition texts): the SERIOUS-CONDITION this thread caught or NIL,
and every error text seen along the way.

The sampling is what makes this an instrument rather than a formality.
REINDEX-REPOSITORY clears the error list as its third act, so a collision
INDEX-FILE recorded during one iteration is erased by the next one, and a
check made only after both threads have joined sees an empty list however bad
the run was. Reading the list from this thread is safe in the one way that
matters: NOTE-ERROR conses a fresh head or a fresh list and never mutates a
cons this loop is already holding."
  (let ((texts '()))
    (list (handler-case
              (dotimes (i n nil)
                (funcall thunk)
                (dolist (entry (repository-errors repository))
                  (push (getf entry :message) texts)))
            (serious-condition (condition) condition))
          texts)))

(defun concurrency-text-p (text)
  (and (search "Unsafe concurrent operations" text) t))

(defun stress-counts (repository)
  "The three numbers BUG-0004 saw drift: entities, relationships, tested units.
All three, because the failure this plan reproduced had a correct entity count
and the whole of its damage in the other two."
  (let ((status (repository-status repository)))
    (list (getf status :entities)
          (getf status :relationships)
          (getf status :tested-units))))

(test a-reindex-and-a-poll-do-not-corrupt-the-index
  (with-workspace-fixtures (repository)
    (let* ((rebuilder
             (bt:make-thread
              (lambda ()
                (stress-call repository *stress-iterations*
                             (lambda () (reindex-repository repository :quiet t))))
              :name "stress-reindex"))
           (poller
             (bt:make-thread
              (lambda ()
                (stress-call repository *stress-iterations*
                             (lambda () (poll-once repository :quiet t))))
              :name "stress-poll"))
           (from-rebuilder (bt:join-thread rebuilder))
           (from-poller (bt:join-thread poller))
           (after-threads (stress-counts repository)))
      (is (null (first from-rebuilder))
          "the rebuilding thread signaled ~a" (first from-rebuilder))
      (is (null (first from-poller))
          "the polling thread signaled ~a" (first from-poller))
      ;; The recorded errors are where a swallowed collision lands: INDEX-FILE
      ;; and RESOLVE-AND-CHECK's SUBMIT both catch and record rather than
      ;; signal, so a run can end with both threads returning NIL and a third
      ;; of the index missing. That is exactly BUG-0004's console transcript.
      (let ((collisions (remove-if-not #'concurrency-text-p
                                       (append (second from-rebuilder)
                                               (second from-poller)))))
        (is (null collisions)
            "a collision was caught and recorded rather than signaled: ~a"
            (first collisions)))
      ;; DES-0004 R8(c): the direct check that no batch was lost to a torn
      ;; view, not merely that nothing crashed. Compared against a rebuild
      ;; taken with both threads joined, which is the only state that can be
      ;; trusted as a reference.
      (reindex-repository repository :quiet t)
      (is (equal (stress-counts repository) after-threads)
          "the state the threads left differs from a quiet rebuild of the same
files: ~a against ~a" after-threads (stress-counts repository)))))

;;; ------------------------------------------------------------------
;;; Failure containment (SS3.3)
;;; ------------------------------------------------------------------

(test a-file-that-will-not-parse-does-not-stop-the-pass
  ;; The containment property SS3.3 asks for, unchanged: damage in one file
  ;; does not cost the pass. What changed under REQ-0019 R3 is what damage
  ;; costs within its own file -- here the file's only form is the damaged one,
  ;; so the file legitimately contributes no definition, and it is no longer
  ;; marked :ANALYSIS-FAILED-P because the reader did not fail, it repaired and
  ;; the repair was refused (DES-0013 R4). Reporting that refusal on the file
  ;; entity is PLAN-0013 step 5; until then the gap is in READING-RECOVERED and
  ;; not yet on the graph, which is a real if brief silence.
  (with-workspace-fixture (repository)
    (write-file "src/gamma.lisp" "(defun gamma (")
    (poll-once repository :quiet t)
    (let* ((g (repository-graph repository))
           (gamma (find "src/gamma.lisp" (entities-of-type g :file)
                        :key #'name :test #'string=)))
      (is (not (null gamma)) "the file is indexed")
      (is (= 3 (length (entities-of-type g :function)))
          "and the rest of the repository is still there")
      (is (null (relationships-from g (id gamma) :rel-type :contains))
          "the damaged form mints nothing"))))

(test a-rule-violation-is-detected-and-recorded
  (with-workspace-fixtures (repository)
    ;; Make kernel call into docs, which the fixture's RULE-0001 forbids. The
    ;; caller is the real ALPHA the pipeline analyzed, which is what makes this
    ;; the one assertion in the nine suites that spans the whole of DES-0009's
    ;; seam: LISP-ANALYZER reading (in-package :kernel), LOOM-ONTOLOGY having
    ;; declared :system so PROPERTIES-TABLE keeps it, the transaction carrying
    ;; it through the upsert, and ENTITY-SYSTEM handing it to a rule compiled
    ;; out of YAML by AS-KEYWORD. BUG-0010: with both endpoints manufactured
    ;; this tested VIOLATION-OPS and nothing the analyzer or the pipeline does.
    ;; Only the target is built by hand -- no docs/ file in the fixture defines
    ;; a callable for the edge to land on -- and it says its system as a
    ;; property rather than through its path because ENTITY-SYSTEM stopped
    ;; parsing paths (DES-0009 R7).
    (let* ((g (repository-graph repository))
           (caller (find "alpha" (entities-of-type g :function)
                         :key #'name :test #'string=))
           (target (make-instance 'function-entity
                                  :name "doc-helper"
                                  :origin-file "docs/design/helper.lisp"
                                  :properties (properties-table
                                               '(:file "docs/design/helper.lisp"
                                                 :start-line 1 :end-line 2
                                                 :system :docs)))))
      (is (eq :kernel (getp caller :system))
          "ALPHA carries the package its file declares, or the rule below is
comparing against nothing and its silence would mean nothing")
      (add-entity g target)
      (add-relationship g (make-instance 'relationship :rel-type :calls
                                         :from-id (id caller) :to-id (id target)
                                         :origin-file "src/alpha.lisp"))
      (apply-transaction g (violation-ops g))
      (is (= 1 (length (entities-of-type g :rule-violation))))
      (is (string= "RULE-0001" (getp (first (entities-of-type g :rule-violation))
                                     :rule-id))))))

;;; ------------------------------------------------------------------
;;; Link targets against the disk (BUG-0027)
;;; ------------------------------------------------------------------

(test a-link-to-a-file-that-is-not-there-is-reported
  ;; The finding BUG-0027 exists for. Measured on ~/lisp/game-server: 38 broken
  ;; link targets across six files while `status' read `unresolved: 0'.
  (with-workspace-fixtures (repository)
    (write-file "docs/notes.md"
                "see [alpha](../src/alpha.lisp) and [gone](../src/missing.lisp)
")
    (poll-once repository :quiet t)
    (let ((unresolved (mapcar #'cdr (unresolved-references (repository-graph repository)))))
      (is (member "src/missing.lisp" unresolved :test #'string=)
          "the link to nothing is reported: ~a" unresolved)
      (is (not (member "src/alpha.lisp" unresolved :test #'string=))
          "and the one that lands is not"))))

(test a-link-to-a-real-file-loom-does-not-index-is-not-reported
  ;; The false positive the first fix produced, and the reason this check asks
  ;; the disk rather than the index. A document may legitimately link to a
  ;; licence, a .sql fixture, a CLAUDE.md -- things no analyzer claims and Loom
  ;; has no opinion about. What it may not do is link to nothing.
  ;;
  ;; Without this, five of game-server's eight reported findings were files
  ;; sitting right there on disk, which is how a staleness report stops being
  ;; read.
  (with-workspace-fixtures (repository)
    (write-file "schema.sql" "-- no analyzer claims this
")
    (write-file "CLAUDE.md" "# instructions, excluded from indexing by name
")
    (write-file "docs/notes.md"
                "see [schema](../schema.sql) and [guide](../CLAUDE.md)
")
    (poll-once repository :quiet t)
    (let ((unresolved (mapcar #'cdr (unresolved-references (repository-graph repository)))))
      (is (not (member "schema.sql" unresolved :test #'string=))
          "a .sql file no analyzer claims is on disk and is not broken: ~a" unresolved)
      (is (not (member "CLAUDE.md" unresolved :test #'string=))
          "and neither is the file REQ-0028 excludes by name"))))


;;; ------------------------------------------------------------------
;;; A virtual environment is excluded by what it is (DES-0053 D11)
;;; ------------------------------------------------------------------

(test a-virtual-environment-is-excluded-by-its-pyvenv-cfg-and-not-by-git-or-name
  ;; The fixture is not a git repository, so no .gitignore applies, and the
  ;; directory is named env/, which no list of names knows. Only the pyvenv.cfg
  ;; says what it is. The README and the YAML under docs/ are there for the
  ;; second walk: the document store enumerates the same tree, and a rule that
  ;; only REPOSITORY-FILES applied would still index the YAML.
  (with-workspace-fixture (repository)
    (write-file "env/pyvenv.cfg" "home = /usr/bin
")
    (write-file "env/lib/x.lisp" "(defun venv-function () 1)
")
    (write-file "env/lib/README.md" "# vendored
")
    ;; Python from step 8, when .py became claimed: nothing in the path says
    ;; venv, so only the pyvenv.cfg keeps it out.
    (write-file "env/lib/site.py" "def venv_python_function():
    return 1
")
    (write-file "env/lib/docs/notes.yaml" "id: DEC-9999
type: decision
title: Inside a venv
status: accepted
")
    (write-file "docs/ok.yaml" "id: DEC-9998
type: decision
title: Outside the venv
status: accepted
")
    (reindex-repository repository :quiet t)
    (let* ((g (repository-graph repository))
           (files (mapcar #'name (entities-of-type g :file)))
           ;; Every entity's own path, not the document names: a YAML document
           ;; that carries an id is named by it (`DEC-9999'), so a check on the
           ;; names could not fail for the one file this fixture writes to catch
           ;; the second walk (REV-0003 item 8). The README is named by its path,
           ;; which is why that half was sound.
           (documents (loop for e in (all-entities g)
                            when (member (entity-type e)
                                         '(:document :decision :design :requirement
                                           :plan :bug :review :rule :concept :architecture))
                              collect (or (getp e :path) (origin-file e)))))
      (is (member "docs/ok.yaml" documents :test #'equal)
          "control: the same collection sees a YAML decision outside the venv: ~a"
          documents)
      (is (member "src/alpha.lisp" files :test #'string=)
          "the tree's own source is indexed: ~a" files)
      (is (notany (lambda (path) (eql 0 (search "env/" path))) files)
          "nothing under the venv is a file: ~a" files)
      (is (notany (lambda (path) (eql 0 (search "env/" path))) documents)
          "and no document under it is either: ~a" documents)
      (is (null (find "venv-function" (entities-of-type g :function)
                      :key #'name :test #'string=)))
      (is (null (find "venv_python_function" (entities-of-type g :function)
                      :key #'name :test #'string=))))))

(defun python-available-p ()
  "True when a Python child can actually be started. The analyzer suite's
CALL-WITH-PYTHON asks the same question; it lives in LOOM-ANALYZER-TEST, which
this system does not load, for NODE-AVAILABLE-P's reason."
  (bt:with-lock-held ((loom-analyzer::child-lock loom-analyzer::*py-extractor-child*))
    (not (null (loom-analyzer::ensure-extractor-child loom-analyzer::*py-extractor-child*)))))

(test python-files-reach-the-graph-through-the-whole-pipeline
  ;; The analyzer asserts properties and no cross-file edge, so everything below
  ;; is the resolution passes reading what it wrote: a call through an import,
  ;; a :SETTING minted from an environment read, and a :READS edge to it.
  (if (not (python-available-p))
      (skip "python3 is not on PATH")
      (with-workspace-fixture (repository)
        (write-file "functions/config.py" "import os
SHEET = os.environ.get('SPREADSHEET_ID', '')
")
        (write-file "functions/sheets.py" "def read_tab(): pass
")
        (write-file "functions/main.py" "import sheets
from config import SHEET
def run():
    sheets.read_tab()
")
        (reindex-repository repository :quiet t)
        (let* ((g (repository-graph repository))
               (run (find "run" (entities-of-type g :function) :key #'name :test #'string=))
               (read-tab (find "read_tab" (entities-of-type g :function)
                               :key #'name :test #'string=))
               (setting (find "SPREADSHEET_ID" (entities-of-type g :setting)
                              :key #'name :test #'string=))
               (sheet (find "SHEET" (entities-of-type g :variable) :key #'name :test #'string=)))
          (is-true run)
          (is (equal (list (id read-tab))
                     (mapcar #'to-id (relationships-from g (id run) :rel-type :calls)))
              "main.run reaches sheets.read_tab through its import")
          (is-true setting "the environment read became a :SETTING")
          (is (equal (list (id setting))
                     (mapcar #'to-id (relationships-from g (id sheet) :rel-type :reads)))
              "and the variable that holds the read is its reader")))))

(test a-python-case-draws-a-tests-edge-through-the-whole-pipeline
  ;; D8 writes the case and its calls; RESOLVE-CALLS and RESOLVE-TESTS derive the
  ;; edge, and nothing in loom-graph changed for it.
  (if (not (python-available-p))
      (skip "python3 is not on PATH")
      (with-workspace-fixture (repository)
        (write-file "functions/ledger.py" "def post(): pass
")
        (write-file "functions/test_ledger.py" "import ledger
def test_post():
    ledger.post()
")
        (reindex-repository repository :quiet t)
        (let* ((g (repository-graph repository))
               (case (find "test_post" (entities-of-type g :test) :key #'name :test #'string=))
               (post (find "post" (entities-of-type g :function) :key #'name :test #'string=)))
          (is-true case)
          (is (equal (list (id post))
                     (mapcar #'to-id (relationships-from g (id case) :rel-type :tests)))
              "the case tests the function its body calls")))))

(test an-in-place-venv-in-a-subdirectory-excludes-only-what-venv-created
  ;; `python -m venv .' run in functions/ writes functions/pyvenv.cfg beside
  ;; functions/main.py, so excluding the whole prefix drops the program. Only the
  ;; cfg and the directories venv makes are the environment's own.
  (with-workspace-fixture (repository)
    (write-file "functions/pyvenv.cfg" "home = /usr/bin
")
    (write-file "functions/main.py" "def run(): pass
")
    (write-file "functions/ledger/__init__.py" "")
    (write-file "functions/lib/python3.12/site-packages/dep.py" "def dep(): pass
")
    (write-file "functions/bin/activate_this.py" "def activate(): pass
")
    (reindex-repository repository :quiet t)
    (let ((files (mapcar #'name (entities-of-type (repository-graph repository) :file))))
      (is (member "functions/main.py" files :test #'string=)
          "the project's own source beside the cfg is indexed: ~a" files)
      (is (member "functions/ledger/__init__.py" files :test #'string=))
      (is (notany (lambda (path) (or (search "functions/lib/" path)
                                     (search "functions/bin/" path)))
                  files)
          "and what venv created is not: ~a" files))))

(test a-pyvenv-cfg-at-the-root-does-not-exclude-the-repository
  ;; `python -m venv .' writes one beside the project's own source. Excluding
  ;; the empty prefix would index nothing at all.
  (with-workspace-fixture (repository)
    (write-file "pyvenv.cfg" "home = /usr/bin
")
    (reindex-repository repository :quiet t)
    (let ((files (mapcar #'name (entities-of-type (repository-graph repository) :file))))
      (is (member "src/alpha.lisp" files :test #'string=)))))

;;; ------------------------------------------------------------------
;;; What the tree holds that no analyzer claims (REQ-0059)
;;; ------------------------------------------------------------------
;;;
;;; `files', `unindexed' and `unparsed' are three counts about the claimed
;;; set, so a language nobody analyzes appears in none of them. Loom itself
;;; tracks 424 files, claims 376, and nine of the 48 in the gap are the Python
;;; harness that measures Loom -- `find acceptance' returns nothing, and did so
;;; indistinguishably from a name that exists nowhere.

(defun git-init-fixture ()
  "Make the fixture a git repository with everything added.

TRACKED-PATHS asks `git ls-files', so a fixture that is not a repository
answers the reason case rather than the counting one -- which the test below
this asserts deliberately."
  (dolist (arguments '(("init" "-q") ("add" "-A")))
    (uiop:run-program (append (list "git" "-C" (namestring *fixture-root*))
                              arguments)
                      :ignore-error-status t
                      :output nil :error-output nil)))

(test unclaimed-counts-tracked-files-no-analyzer-claims-and-names-the-extensions
  (with-workspace-fixtures (repository)
    ;; Ruby, which no analyzer claims. This test used .py until the Python
    ;; analyzer claimed it (DES-0053): the property is "an extension nobody
    ;; claims is counted", and the extension was only ever an example.
    (write-file "tools/harness.rb" "def helper
  1
end
")
    (write-file "tools/other.rb" "def second
  2
end
")
    (write-file "tools/run.sh" "#!/bin/sh
echo hi
")
    (git-init-fixture)
    (reindex-repository repository :quiet t)
    (let* ((status (repository-status repository))
           (by-extension (getf status :unclaimed-by-extension)))
      (is (null (getf status :unclaimed-reason))
          "a git repository can be counted: ~a" (getf status :unclaimed-reason))
      (is (= 3 (getf status :unclaimed))
          "two .rb and one .sh are tracked and claimed by nobody; got ~a with ~a"
          (getf status :unclaimed) by-extension)
      (flet ((files-of (type)
               (getf (find type by-extension :key (lambda (e) (getf e :type))
                                             :test #'string=)
                     :files)))
        (is (eql 2 (files-of ".rb"))
            "the extensions are named with counts, which is what a reader acts on")
        (is (eql 1 (files-of ".sh")))
        (is (null (files-of ".lisp"))
            "and a claimed language is not in the gap")
        ;; Plists, not dotted pairs: an alist reaches the JSON encoder as
        ;; "(.rb . 2)" and a REST caller cannot read it (BUG-0030's shape).
        (is (every (lambda (e) (and (getf e :type) (getf e :files))) by-extension)
            "every entry is a plist a caller can read: ~a" by-extension)))))

(test a-tree-git-cannot-answer-for-reports-a-reason-rather-than-nought
  ;; IGNORED-PATHS' rule, applied to the same question one field along: a known
  ;; unknown beats a zero that reads like a clean answer. A directory that is
  ;; not a git repository is the ordinary case here -- the fixture is one until
  ;; the test above makes it otherwise.
  (with-workspace-fixtures (repository)
    (let ((status (repository-status repository)))
      (is (null (getf status :unclaimed))
          "no count, because none could be taken")
      (is-true (getf status :unclaimed-reason)
               "and the reason is on the answer rather than left to be guessed"))))


;;; ------------------------------------------------------------------
;;; The text a term occurs in, when no definition carries it (REQ-0054)
;;; ------------------------------------------------------------------
;;;
;;; `find term=osm-import' against front-end answered `{"entities":[],
;;; "total":0}' -- the same answer as for a name that exists nowhere, though
;;; the string is a route the router declares and the mock posts to. Two
;;; absences with opposite next moves, told apart by nothing.

(test occurrences-name-the-lines-a-term-is-written-on
  (with-workspace-fixture (repository)
    (write-file "src/router.lisp" "(defun serve (app)
  ;; POST /osm-import is answered here
  (route app \"/osm-import\" #'handler))
")
    (git-init-fixture)
    (let ((found (textual-occurrences (repository-root repository) "osm-import")))
      (is (null (getf found :reason)) "~a" (getf found :reason))
      (is (= 2 (getf found :total))
          "a comment and a string literal, neither of them a definition: ~a"
          (getf found :lines))
      (is (null (getf found :truncated)))
      (let ((first (first (getf found :lines))))
        (is (equal "src/router.lisp" (getf first :file)))
        (is (= 2 (getf first :line)) "the line is the line, not the file's first")
        (is (search "POST /osm-import" (getf first :text))
            "and the text is carried so a reader can tell a route from a word")))))

(test a-term-in-no-text-at-all-is-an-answer-and-not-a-shrug
  ;; The control that makes the band trustworthy. Without it "no occurrences"
  ;; and "the scan did not run" are one empty list.
  (with-workspace-fixture (repository)
    (git-init-fixture)
    (let ((found (textual-occurrences (repository-root repository) "no-such-token-anywhere")))
      (is (null (getf found :reason)) "git answers exit 1 for no matches, ~
which is not a failure and must not read as one")
      (is (= 0 (getf found :total)))
      (is (null (getf found :lines))))))

(test the-occurrence-band-is-capped-and-says-so
  ;; R3. A common word occurs everywhere, and a list of four hundred lines is a
  ;; different way of answering nothing.
  (with-workspace-fixture (repository)
    (write-file "src/many.lisp"
                (with-output-to-string (out)
                  (dotimes (i 20) (format out ";; widget line ~d~%" i))))
    (git-init-fixture)
    (let ((found (textual-occurrences (repository-root repository) "widget" :limit 5)))
      (is (= 20 (getf found :total)) "the total is what was found")
      (is (= 5 (length (getf found :lines))) "the list is what was shown")
      (is-true (getf found :truncated)
               "and the answer says it was cut, which is what makes the five honest"))))

(test a-line-with-colons-in-it-keeps-its-text
  ;; git grep writes `path:line:text' and source lines are full of colons, so a
  ;; split on every colon truncates exactly the lines worth reading.
  (let ((parsed (loom-workspace::parse-grep-line
                 "src/a.lisp:12:  (format t \"~a: ~a\" key value) ; note: here")))
    (is (equal "src/a.lisp" (getf parsed :file)))
    (is (= 12 (getf parsed :line)))
    (is (search "note: here" (getf parsed :text))
        "the tail survives: ~s" (getf parsed :text)))
  (is (null (loom-workspace::parse-grep-line "not a grep line"))))

;;; ------------------------------------------------------------------
;;; DES-0054 D4 and risk 5: .firebaserc is the one dot-file the walk admits
;;; ------------------------------------------------------------------

(defun file-paths-in-index (repository)
  (sort (mapcar (lambda (e) (getp e :path))
                (entities-of-type (repository-graph repository) :file))
        #'string<))

(test the-firebase-configs-are-indexed-and-the-files-holding-a-value-are-not
  ;; Firebase keeps a secret's value in .env, .env.local, .env.<project>,
  ;; .secret.local and .runtimeconfig.json. The walk skips every dot-prefixed
  ;; file, and *ADMITTED-DOT-FILES* names .firebaserc and nothing else, so none of
  ;; these reaches an analyzer (DES-0054 D7).
  (with-workspace-fixture (repository)
    (write-file "firebase.json" "{\"functions\": [{\"source\": \"functions\"}]}")
    (write-file ".firebaserc" "{\"projects\": {\"default\": \"demo\"}}")
    (write-file "functions/.env" "K=1")
    (write-file "functions/.secret.local" "K=1")
    (write-file ".firebase/.firebaserc" "{\"projects\": {\"default\": \"cache\"}}")
    (reindex-repository repository :quiet t)
    (let ((paths (file-paths-in-index repository)))
      (is (member "firebase.json" paths :test #'equal))
      (is (member ".firebaserc" paths :test #'equal))
      (is (not (member "functions/.env" paths :test #'equal)))
      (is (not (member "functions/.secret.local" paths :test #'equal)))
      (is (not (member ".firebase/.firebaserc" paths :test #'equal))
          "the dot-directory test is unchanged"))))

(test an-admitted-dot-file-is-not-reported-unindexed-or-drifted
  ;; Risk 5. The stamps and UNINDEXED-FILES read the same walk as the index, so
  ;; a name the walk admitted must read as current after a pass and not as a
  ;; file the index never read.
  (with-workspace-fixture (repository)
    (write-file ".firebaserc" "{\"projects\": {\"default\": \"demo\"}}")
    (reindex-repository repository :quiet t)
    (is (eql 0 (index-drift repository)))
    (is (eql 0 (unindexed-files repository)))))

(test editing-firebaserc-is-seen-by-the-monitor
  (with-workspace-fixture (repository)
    (write-file ".firebaserc" "{\"projects\": {\"default\": \"demo\"}}")
    (reindex-repository repository :quiet t)
    (flet ((aliases ()
             (getp (find ".firebaserc" (entities-of-type (repository-graph repository) :file)
                         :key (lambda (e) (getp e :path)) :test #'equal)
                   :project-aliases)))
      (is (equal '(("default" . "demo")) (aliases)))
      (write-file ".firebaserc" "{\"projects\": {\"default\": \"demo\", \"staging\": \"stg\"}}")
      (is (= 1 (poll-once repository :quiet t)))
      (is (equal '(("default" . "demo") ("staging" . "stg")) (aliases))))))

(test a-firebase-json-with-a-comment-is-counted-unparsed
  (with-workspace-fixture (repository)
    (write-file "firebase.json" "{ // a comment
  \"functions\": [{}] }")
    (reindex-repository repository :quiet t)
    (is (eql 1 (getf (repository-status repository) :unparsed)))))

;;; ------------------------------------------------------------------
;;; DES-0054 R8: the index cannot hold a secret's or a param's value
;;; ------------------------------------------------------------------

(defparameter *sentinel-frameworks* "entry-points:
  - trigger: https
    module: firebase_functions.https_fn
    names: [on_request]
    settings: [secrets]
setting-declarations:
  - source: secret
    module: firebase_functions.params
    names: [SecretParam]
  - source: param
    module: firebase_functions.params
    names: [StringParam]
")

(defun write-sentinel-tree ()
  "A Firebase Python tree whose every value-bearing file holds SENTINEL-7f3a, whose
param default is SENTINEL-DEFAULT, and whose main.py docstring holds the control."
  (write-file ".loom/frameworks.yaml" *sentinel-frameworks*)
  (write-file "firebase.json"
              "{\"functions\": [{\"source\": \"functions\", \"runtime\": \"python312\"}]}")
  (write-file ".firebaserc" "{\"projects\": {\"default\": \"demo\"}}")
  (write-file "functions/main.py" "\"\"\"CONTROL-7f3a\"\"\"
from firebase_functions import https_fn
from firebase_functions.params import SecretParam, StringParam
K = SecretParam(\"K\")
P = StringParam(\"P\", \"SENTINEL-DEFAULT\")
@https_fn.on_request(secrets=[K])
def f(req): pass
")
  (dolist (name '(".env" ".env.local" ".env.default" ".secret.local"))
    (write-file (format nil "functions/~a" name) "K=SENTINEL-7f3a
"))
  (write-file "functions/.runtimeconfig.json" "{\"k\": \"SENTINEL-7f3a\"}"))

(defun value-contains-p (value needle)
  "True when NEEDLE occurs in VALUE: a string, or any string inside a list, cons
or vector."
  (typecase value
    (string (search needle value))
    (cons (or (value-contains-p (car value) needle)
              (value-contains-p (cdr value) needle)))
    (vector (some (lambda (v) (value-contains-p v needle)) value))
    (t nil)))

(defun index-contains-p (repository needle)
  "True when NEEDLE is in the name or any property of any entity."
  (some (lambda (entity)
          (or (and (slot-boundp entity 'name) (value-contains-p (name entity) needle))
              (loop for value being the hash-values of (properties entity)
                      thereis (value-contains-p value needle))))
        (all-entities (repository-graph repository))))

(test the-index-holds-no-value-from-the-files-firebase-keeps-one-in
  (if (not (python-available-p))
      (skip "python3 is not on PATH")
      (with-workspace-fixture (repository)
        (write-sentinel-tree)
        (reindex-repository repository :quiet t)
        (is-true (index-contains-p repository "CONTROL-7f3a")
                 "the control: the walk can see a string the index does hold")
        (is (not (index-contains-p repository "SENTINEL-7f3a")))
        (is (not (index-contains-p repository "SENTINEL-DEFAULT")))
        (let ((names (mapcar #'name (entities-of-type (repository-graph repository) :setting))))
          (is (member "K" names :test #'string=) "settings are minted, so the walk ran after them")
          (is (member "P" names :test #'string=))))))

(defclass leaky-env-analyzer (loom-analyzer:analyzer) ()
  (:default-initargs :language nil :file-types '()))

(defmethod loom-analyzer:analyzer-handles-p ((analyzer leaky-env-analyzer) path)
  (string= ".env" (file-namestring path)))

(defmethod loom-analyzer:analyze-file ((analyzer leaky-env-analyzer) path contents workspace-id)
  (list (retract-file path workspace-id)
        (assert-entity (make-instance 'file-entity :name path :origin-file path
                                      :properties (properties-table
                                                   (list :path path :documentation contents)))
                       workspace-id)))

(test the-sentinel-walk-finds-a-leak-when-one-is-let-in
  ;; CON-0003 for the test above, as a test. Admit .env and register an analyzer
  ;; that writes its contents into :DOCUMENTATION: the same walk must now find
  ;; SENTINEL-7f3a. Without this the absence above could mean the walk cannot see.
  (if (not (python-available-p))
      (skip "python3 is not on PATH")
      (let ((saved loom-analyzer:*analyzers*)
            (admitted loom-workspace::*admitted-dot-files*))
        (unwind-protect
             (with-workspace-fixture (repository)
               (loom-analyzer:register-analyzer (make-instance 'leaky-env-analyzer))
               (setf loom-workspace::*admitted-dot-files* '(".firebaserc" ".env"))
               (write-sentinel-tree)
               (reindex-repository repository :quiet t)
               (is-true (index-contains-p repository "SENTINEL-7f3a")))
          (setf loom-analyzer:*analyzers* saved
                loom-workspace::*admitted-dot-files* admitted)))))
