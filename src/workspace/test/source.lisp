;;;; DEFINITION-SOURCE -- REQ-0031, DES-0027, PLAN-0030 S1.
;;;;
;;;; The fixture's src/alpha.lisp is three lines and the line numbers below
;;;; depend on that shape:
;;;;
;;;;   1  (in-package :kernel)
;;;;   2  (defun alpha (x) (+ x 1))
;;;;   3  (defun alpha-twice (x) (alpha (alpha x)))
;;;;
;;;; so ALPHA is 2-2 and ALPHA-TWICE is 3-3. Asserting the text rather than
;;;; only the status is the point: a reader that returned the wrong lines with
;;;; a confident :CURRENT beside them would pass every status assertion and be
;;;; worse than useless, since REQ-0031 R4 exists so a caller can trust what it
;;;; was handed.

(in-package :loom-workspace-test)

(in-suite all-tests)

(defun named-entity (repository name type)
  "The one entity of TYPE in REPOSITORY whose name is exactly NAME.
Exact rather than FIND-ENTITIES' substring match, because \"alpha\" also names
ALPHA-TWICE and a test that silently probed the wrong entity would still pass."
  (find name (find-entities (repository-graph repository) :entity-type type)
        :key (lambda (e) (and (slot-boundp e 'name) (name e)))
        :test #'string=))

(defun source-of (repository name type &rest args)
  (let ((entity (named-entity repository name type)))
    (and entity (apply #'definition-source repository (id entity) args))))

(test definition-source-returns-the-lines-the-index-named
  (with-workspace-fixture (repository)
    (let ((r (source-of repository "alpha" :function)))
      (is (eq :current (getf r :status)))
      (is (string= "2-2" (getf r :range)))
      (is (string= "(defun alpha (x) (+ x 1))" (string-right-trim '(#\Newline)
                                                                 (getf r :text)))
          "the definition, and not the IN-PACKAGE above it or the defun below")
      (is (null (getf r :truncated)))
      (is (= 0 (getf r :withheld)))
      (is (getf r :indexed-at) "R4: the generation the text was read against"))))

(test definition-source-serves-a-document-whole-from-its-path
  ;; BUG-0059. A document carries a :PATH and no line range. REQ-0007 bounds
  ;; what `describe' prints of one to a summary, so --source is the way to read
  ;; the argument itself -- and before this it had no answer but ":UNLOCATED".
  ;; Served whole, from line 1, under the same contract as a ranged entity.
  ;;
  ;; Both stores, from here to the end of the document tests: a :PATH is an
  ;; address rather than a place to open (DES-0051 N1), and the in-memory run
  ;; is what says so, since nothing under its root is on disk.
  (with-workspace-fixtures (repository)
    (let ((r (source-of repository "DEC-0001" :decision)))
      (is (eq :current (getf r :status)))
      (is (string= "1-7" (getf r :range))
          "the whole file, first line to last")
      (is (null (getf r :definition-range))
          "a whole-file answer reports no entity range")
      (is (search "id: DEC-0001" (getf r :text)))
      (is (search "makes it testable" (getf r :text))
          "the rationale, which the bounded summary would truncate")
      (is (= 0 (getf r :withheld))))))

(test definition-source-declines-an-entity-that-names-no-file
  ;; :UNLOCATED is now the narrow case: not "a document" but an entity with
  ;; neither a :FILE nor a :PATH. Reported rather than guessed at from a type
  ;; list -- BUG-0030 is what enumerating types costs.
  (with-workspace-fixture (repository)
    (add-entity (repository-graph repository)
                (make-instance 'concept-entity :name "floating"
                               :properties (properties-table (list :doc-id "floating"))))
    (let* ((e (named-entity repository "floating" :concept))
           (r (definition-source repository (id e))))
      (is (eq :unlocated (getf r :status)))
      (is (null (getf r :text))))))

(test definition-source-reports-an-unknown-entity-rather-than-erroring
  (with-workspace-fixture (repository)
    (is (eq :unknown (getf (definition-source repository "no-such-id") :status)))))

(test definition-source-caps-its-answer-and-says-how-much-it-withheld
  ;; REQ-0031 R6: bounded, and "silence is not among the options". The cap is
  ;; forced to 1 rather than writing a 400-line fixture -- the parameter is
  ;; what is under test, not the default.
  ;; A multi-line definition, because the fixture's own are one line each and a
  ;; cap of 1 against a 1-line body withholds nothing -- which is what the
  ;; first draft of this test asserted, and it failed for the right reason.
  (with-workspace-fixture (repository)
    (write-file "src/wide.lisp" "(in-package :kernel)
(defun wide (x)
  (let ((y (+ x 1)))
    (* y 2)))
")
    (reindex-repository repository :quiet t)
    (let ((r (source-of repository "wide" :function :limit 2)))
      (is (eq :current (getf r :status)))
      (is (getf r :truncated))
      (is (= 2 (count #\Newline (getf r :text))))
      ;; WIDE spans 2-4, three lines; two served, one withheld.
      (is (= 1 (getf r :withheld)))
      (is (string= "2-3" (getf r :range))
          "the range names what was served, not what the entity spans"))))

(test an-edited-file-is-served-and-flagged-rather-than-refused
  ;; REQ-0031 R5 and DES-0027 D4. The text is the truth about the file, which
  ;; DEC-0001 says is the truth; refusing would leave the caller with a range
  ;; and no way to read it, which is the handoff being removed. What a caller
  ;; must not do is mistake it for what was indexed, so the status is beside
  ;; the text rather than in place of it.
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp"
                "(in-package :kernel)
(defun alpha (x) (+ x 2))
(defun alpha-twice (x) (alpha (alpha x)))
")
    (let ((r (source-of repository "alpha" :function)))
      (is (eq :stale (getf r :status)))
      (is (search "+ x 2" (getf r :text))
          "what the file says now, not what the index remembers"))))

(test a-vanished-file-reports-that-it-is-gone
  (with-workspace-fixture (repository)
    (delete-file (merge-pathnames "src/alpha.lisp" (repository-root repository)))
    (let ((r (source-of repository "alpha" :function)))
      (is (eq :missing (getf r :status)))
      (is (null (getf r :text))))))

(test an-edited-document-is-served-and-flagged-rather-than-refused
  ;; The document half of R5, and it is decided differently from a code file's.
  ;; A file is :STALE when its content hash disagrees with the stamp the index
  ;; took. A document has no stamp: the store hands out a version with the
  ;; text, and :CURRENT means the version read is the version indexed. On the
  ;; file store that is stricter than the hash -- a document saved again with
  ;; the same bytes has a new write date and reads :STALE -- and the text is
  ;; still what the store holds, which is what a caller asked for.
  (with-workspace-fixtures (repository)
    (write-file "docs/decisions/DEC-0001.yaml"
                "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
affects: [alpha]
rationale: |
  Keeping alpha-twice free of side effects makes it testable, and cheap.
")
    (let ((r (source-of repository "DEC-0001" :decision)))
      (is (eq :stale (getf r :status)))
      (is (search "and cheap" (getf r :text))
          "what the store holds now, not what the index remembers"))))

(test a-document-the-store-no-longer-holds-reports-that-it-is-gone
  ;; The document's :MISSING, which arrives as DOCSTORE-MISSING rather than as
  ;; a failed open. Reported and not signalled, as a vanished file is: a caller
  ;; asking for a document wants an answer about it, and "gone" is one.
  (with-workspace-fixtures (repository)
    (remove-fixture-document "docs/decisions/DEC-0001.yaml")
    (let ((r (source-of repository "DEC-0001" :decision)))
      (is (eq :missing (getf r :status)))
      (is (null (getf r :text)))
      (is (null (getf r :range))
          "a whole-file answer has no range to report, gone or not"))))

(test a-file-too-short-for-its-range-says-so-rather-than-returning-less
  ;; The other half of R5, and the one a naive implementation gets wrong by
  ;; returning an empty string or a shorter region -- both of which read as a
  ;; successful answer about a definition that is no longer there.
  (with-workspace-fixture (repository)
    (write-file "src/alpha.lisp" "(in-package :kernel)
")
    (let ((r (source-of repository "alpha-twice" :function)))
      (is (eq :short (getf r :status)))
      (is (null (getf r :text))))))

;;; ------------------------------------------------------------------
;;; A file is read once until it changes (BUG-0083)
;;; ------------------------------------------------------------------

(defun alpha-lines (repository)
  (loom-workspace::served-lines repository "src/alpha.lisp"
                (merge-pathnames "src/alpha.lisp" (repository-root repository))))

(test a-settled-file-is-read-once
  (with-workspace-fixture (repository)
    (let ((loom-workspace::*source-settle-seconds* 0))
      (let ((first (alpha-lines repository)))
        (is (eq first (alpha-lines repository))
            "a second request for an unchanged file read it again")))))

(test a-file-written-just-now-is-never-served-from-memory
  ;; One second of resolution in a modification time means two writes of one
  ;; size within a second look alike. A file that young is read every time.
  (with-workspace-fixture (repository)
    (let ((loom-workspace::*source-settle-seconds* 3600))
      (write-file "src/alpha.lisp"
                  "(in-package :kernel)
(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
      (is (search "+ x 1" (aref (alpha-lines repository) 1)))
      (write-file "src/alpha.lisp"
                  "(in-package :kernel)
(defun alpha (x) (+ x 7))
(defun alpha-twice (x) (alpha (alpha x)))
")
      (is (search "+ x 7" (aref (alpha-lines repository) 1))
          "a same-sized rewrite within the second was served from memory"))))

(test a-changed-file-is-read-again
  (with-workspace-fixture (repository)
    (let ((loom-workspace::*source-settle-seconds* 0))
      (let ((before (alpha-lines repository)))
        (write-file "src/alpha.lisp"
                    "(in-package :kernel)
(defun alpha (x) (+ x 22))
(defun alpha-twice (x) (alpha (alpha x)))
")
        (let ((after (alpha-lines repository)))
          (is (not (eq before after)))
          (is (search "+ x 22" (aref after 1))))))))

(test a-reindex-ends-what-was-kept
  ;; The status compares the file with what the index read, so it moves when
  ;; the index does though the file has not.
  (with-workspace-fixture (repository)
    (let ((loom-workspace::*source-settle-seconds* 0))
      (write-file "src/alpha.lisp"
                  "(in-package :kernel)
(defun alpha (x) (+ x 3))
(defun alpha-twice (x) (alpha (alpha x)))
")
      (is (eq :stale (nth-value 1 (alpha-lines repository))))
      (reindex-repository repository :quiet t)
      (is (eq :current (nth-value 1 (alpha-lines repository)))
          "the status was kept past a reindex"))))
