;;;
;;; Tests for src/serve/operations.lisp -- the eleven read- and write-tier
;;; entries, over a real temp repository.
;;;
;;; Level 1 in SS14.1's ordering, like src/workspace/test/workspace.lisp: these
;;; run the real analyzers over a real directory, because what is worth testing
;;; about an entry that is one call deep is whether it returns the data the
;;; console would have formatted, and a mock graph cannot answer that.
;;;
;;; The fixture is built the way src/process/test/console.lisp builds one, and
;;; torn down in an UNWIND-PROTECT that unwatches by name -- a leaked
;;; registration would make the next test's :status listing wrong rather than
;;; this one's.
;;;

(in-package :loom-serve-test)

(def-suite operations
  :in all-tests
  :description "The read and write operations, and how they refuse.")

(in-suite operations)

(defvar *operations-fixture-root* nil)

(defun write-operations-fixture-file (relative contents)
  (let ((path (merge-pathnames relative *operations-fixture-root*)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    path))

(defun make-operations-fixture-repository ()
  "One source file and two documents, in a fresh temp directory."
  (setf *operations-fixture-root*
        (merge-pathnames (format nil "loom-serve-~36r/" (random (expt 2 48) (make-random-state t)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *operations-fixture-root*)
  (write-operations-fixture-file "src/code.lisp" "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
  (write-operations-fixture-file "docs/decisions/DEC-0001.yaml"
                                 "id: DEC-0001
type: decision
title: Alpha stays arithmetic
status: accepted
affects: [alpha]
rationale: |
  Keeping alpha free of side effects makes it testable.
")
  (write-operations-fixture-file "docs/rules/RULE-0001.yaml"
                                 "id: RULE-0001
type: rule
title: Nothing in src may call into docs
status: active
severity: error
check:
  kind: no-edge
  from-system: src
  to-system: docs
  rel-types: [calls]
")
  (watch-repository *operations-fixture-root* :monitor nil :quiet t))

(defmacro with-operations-fixture ((repository) &body body)
  `(let ((,repository (make-operations-fixture-repository)))
     (unwind-protect (progn ,@body)
       (unwatch-repository (repository-name ,repository))
       (ignore-errors (uiop:delete-directory-tree *operations-fixture-root*
                                                  :validate t))
       (setf *operations-fixture-root* nil))))

(defun call-operation (name grants &rest arguments)
  "INVOKE-OPERATION by name, the way a route handler reaches it."
  (invoke-operation (find-operation name) grants arguments))

;;; ------------------------------------------------------------------
;;; No guessing (R2, and DES-0006's repository-selection paragraph)
;;; ------------------------------------------------------------------

(test every-operation-names-its-repository
  ;; The witness for "a program either knows which repository it means or
  ;; should ask first". It fails against any implementation that reached for
  ;; CURRENT-REPOSITORY, which would answer happily here because the fixture
  ;; is the only watched repository -- which is exactly how the convenience
  ;; that is right for a human becomes a wrong answer for a program.
  (with-operations-fixture (repository)
    (dolist (name '(:describe :impact :context :check :rules
                    :watch :pause :unwatch :reindex))
      (signals malformed-request
        (call-operation name '(:read :write) :term "alpha" :task "alpha")))
    ;; :status is the first exception, and the reason it is: with no designator
    ;; it is the discovery call, and it must answer rather than refuse.
    (let ((all (call-operation :status '(:read))))
      (is (member (repository-name repository)
                  (mapcar (lambda (status) (getf status :name))
                          (getf all :repositories))
                  :test #'string=)))
    ;; :find is the second, since REQ-0051 R1. The question it answers without
    ;; a designator is not "tell me about this repository" but "which of the
    ;; watched trees owns this name", and a refusal is what sent the caller to
    ;; grep. The rest of this test is what stops that becoming a general
    ;; licence: nine operations above still refuse.
    (let ((found (call-operation :find '(:read) :term "alpha")))
      (is (member (repository-name repository)
                  (mapcar (lambda (row) (getf row :repository))
                          (getf found :searched))
                  :test #'string=)
          "the federated find names the tree it searched")
      (is (every (lambda (row) (getf row :repository)) (getf found :entities))
          "and every row says which tree it came from"))))

(test an-unknown-repository-says-so-and-names-it
  (let ((condition (handler-case (progn (call-operation :check '(:read)
                                                        :repository "no-such-repo")
                                        nil)
                     (malformed-request (c) c))))
    (is-true condition)
    (when condition
      (is (search "no-such-repo" (princ-to-string condition))))))

(test an-unknown-entity-is-its-own-kind-of-malformed-request
  ;; A subtype, so step 2's "an unresolvable term is a malformed request" and
  ;; step 6's "an unknown repository is 400 and an unknown entity is 404" are
  ;; both true of one condition family.
  (with-operations-fixture (repository)
    (signals unknown-entity
      (call-operation :describe '(:read)
                      :repository (repository-name repository)
                      :term "zarquon"))
    (signals malformed-request
      (call-operation :describe '(:read)
                      :repository (repository-name repository)
                      :term "zarquon"))))

;;; ------------------------------------------------------------------
;;; The data the console would have formatted
;;; ------------------------------------------------------------------

(test a-read-operation-returns-the-plist-the-console-would-have-formatted
  (with-operations-fixture (repository)
    (let ((detail (call-operation :describe '(:read)
                                  :repository (repository-name repository)
                                  :term "alpha-twice")))
      (is (not (null (getf detail :entity))))
      (is (not (null (getf detail :properties))))
      (is (not (null (getf detail :neighbors))))
      ;; :DOCUMENT is NIL for a code entity, which is a shape rather than an
      ;; omission -- GETF cannot tell them apart, so the key is asserted to be
      ;; present on a document instead, below.
      (is (equal "src/code.lisp" (getf (getf detail :properties) :file))
          "a property value reached the caller untruncated"))
    (let ((decision (call-operation :describe '(:read)
                                    :repository (repository-name repository)
                                    :term "DEC-0001")))
      (is (not (null (getf decision :document))))
      (is (search "side effects" (getf (getf decision :document) :text))))))

(test impact-and-context-answer-as-data-rather-than-as-prose
  (with-operations-fixture (repository)
    (let ((report (call-operation :impact '(:read)
                                  :repository (repository-name repository)
                                  :term "alpha" :depth 3)))
      (is (integerp (getf report :count)))
      (is (member "alpha-twice" (mapcar (lambda (e) (getf e :name))
                                        (getf report :impacted))
                  :test #'string=)))
    (let ((bundle (call-operation :context '(:read)
                                  :repository (repository-name repository)
                                  :task "alpha arithmetic")))
      ;; RENDER-CONTEXT's text is deliberately not produced here: the bundle is
      ;; what a program wants and the rendering is what a console wants.
      (is (equal "alpha arithmetic" (getf bundle :task)))
      (is (listp (getf bundle :items))))))

(test check-reports-the-same-counts-the-console-prints
  ;; The only guard on the duplication DES-0006 accepts under CONSEQUENCES,
  ;; and worth having precisely because the duplication is accepted: the
  ;; assembly here and console.lisp's `check` must not drift.
  (with-operations-fixture (repository)
    (let ((graph (repository-graph repository))
          (report (call-operation :check '(:read)
                                  :repository (repository-name repository))))
      (is (= (length (entities-of-type graph :rule-violation))
             (length (getf report :violations))))
      (is (= (length (unresolved-references graph))
             (length (getf report :unresolved))))
      (is (= (length (unenforced-rules graph))
             (length (getf report :unenforced))))
      ;; DES-0053 D6. The key is present and empty on a tree with no Python:
      ;; GETF alone cannot tell an absent key from an empty one.
      (is-true (get-properties report '(:missing-imported-calls))
               "the operation carries the key")
      (is (null (getf report :missing-imported-calls))))
    (let ((rules (call-operation :rules '(:read)
                                 :repository (repository-name repository))))
      (is (= 1 (length (getf rules :rules))))
      (is (equal "RULE-0001" (getf (first (getf rules :rules)) :doc-id)))
      (is-true (getf (first (getf rules :rules)) :enforceable)))))

;;; ------------------------------------------------------------------
;;; The write tier
;;; ------------------------------------------------------------------

(test a-write-operation-is-refused-to-a-read-only-caller
  (with-operations-fixture (repository)
    (let ((before (repository-indexed-at repository)))
      (signals capability-error
        (call-operation :reindex '(:read) :repository (repository-name repository)))
      ;; The half that matters. A tier check that signals after doing the work
      ;; is not a tier check, and nothing else here would notice.
      (is (eql before (repository-indexed-at repository))))))

(test a-write-operation-does-the-work-for-a-caller-that-was-granted-it
  (with-operations-fixture (repository)
    (let ((before (repository-indexed-at repository)))
      ;; FILE-WRITE-DATE and GET-UNIVERSAL-TIME both count in whole seconds, so
      ;; a rebuild inside the same second carries the same stamp. The entity
      ;; count is what says the rebuild happened.
      (let ((status (call-operation :reindex '(:write)
                                    :repository (repository-name repository))))
        (is (plusp (getf status :entities)))
        (is (not (null (getf status :indexed-at))))
        (is (>= (getf status :indexed-at) before))))))

;;; ------------------------------------------------------------------
;;; REQ-0031: source on :DESCRIBE (DES-0027, PLAN-0030 S3)
;;; ------------------------------------------------------------------

(test describe-returns-source-only-when-it-is-asked-for
  ;; REQ-0031 R2: off by default. The absence matters as much as the presence
  ;; -- `describe' surveying an entity is the behaviour that already existed
  ;; and is right for deciding whether you wanted it at all.
  (with-operations-fixture (repository)
    (let ((plain (call-operation :describe '(:read)
                                 :repository (repository-name repository)
                                 :term "alpha-twice"))
          (with (call-operation :describe '(:read)
                                :repository (repository-name repository)
                                :term "alpha-twice" :source "true")))
      (is (null (getf plain :source)) "absent unless requested")
      (is (not (null (getf with :source))))
      (is (eq :current (getf (getf with :source) :status)))
      (is (search "alpha-twice" (getf (getf with :source) :text))
          "the definition's own text, read now rather than asserted at index time")
      (is (not (null (getf with :neighbors)))
          "added to the answer rather than replacing it"))))

(test the-source-flag-refuses-junk-rather-than-reading-it-as-false
  ;; REQUEST-BOOLEAN's asymmetry. A caller who sent source=yep asked for
  ;; something; answering as though they asked for nothing returns a body-less
  ;; answer that reads exactly like a definition with no body.
  (with-operations-fixture (repository)
    (signals malformed-request
      (call-operation :describe '(:read)
                      :repository (repository-name repository)
                      :term "alpha-twice" :source "yep"))
    (is (null (getf (call-operation :describe '(:read)
                                    :repository (repository-name repository)
                                    :term "alpha-twice" :source "false")
                    :source))
        "an explicit false is not junk and is not a request")))

;;; ------------------------------------------------------------------
;;; Reading a wire value (BUG-0031's siblings; game-server BUG-0001)
;;; ------------------------------------------------------------------

(test an-integer-is-recognised-in-both-encodings-and-not-half-parsed
  (is (is-integer-p 3))
  (is (is-integer-p "3"))
  (is (is-integer-p "-3") "the predicate is about integers, not about bounds")
  (is (not (is-integer-p "3x")) "REV-0001 finding 4: a partial parse is not a number")
  (is (not (is-integer-p "")))
  (is (not (is-integer-p nil)))
  (is (not (is-integer-p :three)))
  (is (= 3 (to-integer "3")))
  (is (= 3 (to-integer 3)))
  (is (null (to-integer "3x"))))

(test a-boolean-is-recognised-in-both-encodings-and-in-both-cases
  ;; game-server BUG-0001: `debug: True' there reads as false, because the test
  ;; is (equal val "true") and nothing is case-folded. A configuration dialect
  ;; that accepts True, true and TRUE for one value makes that wrong two times
  ;; in three.
  (is (is-boolean-p t))
  (is (is-boolean-p "true"))
  (is (is-boolean-p "True") "the spelling a YAML author writes")
  (is (is-boolean-p "FALSE"))
  (is (is-boolean-p "0"))
  (is (not (is-boolean-p "yep")))
  (is (not (is-boolean-p nil)) "absent is not false; every caller tests NIL first"))

(test to-boolean-separates-a-false-from-an-unreadable-value
  ;; The two-value return is the whole defence. NIL is both a legitimate false
  ;; and the only thing an unreadable value could return, and collapsing them
  ;; is the silent misread game-server BUG-0001 records.
  (multiple-value-bind (result readable) (to-boolean "false")
    (is (null result))
    (is-true readable "an explicit false was read, and read as false"))
  (multiple-value-bind (result readable) (to-boolean "yep")
    (is (null result))
    (is (not readable) "and junk is distinguishable from it")))

(test a-cosine-is-parsed-without-a-reader-and-refused-outside-its-range
  ;; TO-COSINE reaches no reader, which is the difference between this and
  ;; console.lisp's READ-FROM-STRING: a query parameter is not typed by a human
  ;; at a terminal, and the reader interns whatever it is handed.
  (is (= 0.8 (to-cosine "0.8")))
  (is (= 1.0 (to-cosine "1")))
  (is (= 0.0 (to-cosine "0.0")))
  (is (null (to-cosine "0.8x")) "a partial parse is not a number")
  (is (null (to-cosine "1.2.3")) "and neither is a second point")
  (is (null (to-cosine "-0.5")) "a sign is not in the character set")
  (is (null (to-cosine "#.(list 1)")) "nor is anything the reader would act on")
  (is (null (request-cosine nil "cut")) "absent is absent, as for the other two")
  (is (= 0.7 (request-cosine "0.7" "cut")))
  ;; The range, which the console does not check. A survey answering an
  ;; out-of-range cut returns an empty rows array, which is the one thing
  ;; DES-0041 D10 forbids these two operations to be ambiguous about.
  (signals malformed-request (request-cosine "5" "cut"))
  (signals malformed-request (request-cosine "high" "cut")))

(test the-two-coercers-agree-about-junk
  ;; The defect this shape exists to prevent: game-server's CONFIG-GET signals
  ;; on an unreadable integer and returns false for an unreadable boolean,
  ;; three lines apart in one COND. Whatever the policy is, both types get it.
  (signals malformed-request (request-integer "3x" "depth"))
  (signals malformed-request (request-boolean "yep" "source"))
  (is (null (request-integer nil "depth")) "absent is absent for both")
  (is (null (request-boolean nil "source")))
  (is (= 3 (request-integer "3" "depth")))
  (is (eq t (request-boolean "TRUE" "source")))
  (signals malformed-request (request-integer "-1" "depth")
           "the bound is REQUEST-INTEGER's, not IS-INTEGER-P's"))


;;; ------------------------------------------------------------------
;;; A cut answer says it was cut (BUG-0002)
;;; ------------------------------------------------------------------
;;;
;;; :ENTITIES and nothing else let a caller that asked for twenty and received
;;; twenty conclude there were twenty. On Loom `find "" test' answered 20 where
;;; the tree holds 798, and an agent asking how many of a type exist had no way
;;; to find out it had been handed a page.

(test find-reports-the-total-and-whether-it-cut-the-list
  (with-operations-fixture (repository)
    (let ((cut (call-operation :find '(:read)
                               :repository (repository-name repository)
                               :term "alpha" :limit "1")))
      (is (= 1 (length (getf cut :entities))) "the limit is honoured")
      (is (= 2 (getf cut :total)) "and the caller is told what it did not see")
      (is-true (getf cut :truncated)))
    (let ((whole (call-operation :find '(:read)
                                 :repository (repository-name repository)
                                 :term "alpha")))
      (is (= 2 (length (getf whole :entities))))
      (is (= 2 (getf whole :total)))
      (is-false (getf whole :truncated)
                "an uncut answer must not claim to be one, or the flag is noise
in every response and stops being read"))))

;;; ------------------------------------------------------------------
;;; REQ-0038: every read query is recorded, not only context
;;; ------------------------------------------------------------------

(defun records-in (directory)
  "Every record file in DIRECTORY, decoded."
  (mapcar (lambda (p) (with-open-file (in p) (json:decode-json in)))
          (directory (merge-pathnames "ctx-*.json" directory))))

(defmacro with-recorded-log ((directory) &body body)
  "Run BODY with the query log on in a fresh DIRECTORY, which stays bound
throughout BODY so the assertions can read it.

BODY drains before it reads: the write is on another thread precisely so that a
caller never waits for it, and DRAIN-CONTEXT-LOG is how a test says it needs the
file now."
  `(let* ((,directory (merge-pathnames (format nil "loom-req-0038-~36r/"
                                               (random (expt 2 48) (make-random-state t)))
                                       (uiop:temporary-directory)))
          (loom-workspace:*context-log-directory* ,directory))
     (ensure-directories-exist ,directory)
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,directory :validate t)))))

(defun drained-records (directory)
  "Every record written so far, after waiting for the writer threads."
  (loom-workspace:drain-context-log)
  (records-in directory))

(test a-read-operation-writes-a-record-naming-itself
  ;; R1 and R2. The point of the hook living in INVOKE-OPERATION is that FIND is
  ;; recorded without FIND knowing anything about it.
  (with-operations-fixture (repository)
    (with-recorded-log (directory)
      (call-operation :find '(:read)
                      :repository (repository-name repository) :term "alpha")
      (let ((records (drained-records directory)))
      (is (= 1 (length records)) "one read, one record")
      (when records
        (let ((r (first records)))
          (is (string= "find" (cdr (assoc :operation r)))
              "the record says which operation it was")
          (is (string= "alpha" (cdr (assoc :term (cdr (assoc :arguments r)))))
              "and what was asked")))))))

(test an-empty-answer-is-recorded-as-an-answer
  ;; R3, and the reason this requirement exists: a find that returns nothing is
  ;; the cheapest true answer the service gives and left no trace at all.
  (with-operations-fixture (repository)
    (with-recorded-log (directory)
      (call-operation :find '(:read)
                      :repository (repository-name repository)
                      :term "no-such-name-anywhere-in-this-fixture")
      (let* ((r (first (drained-records directory)))
             (answer (and r (cdr (assoc :answer r)))))
        (is-true answer "the empty answer was recorded at all")
        (when answer
          (is (eq t (cdr (assoc :none answer)))
              "an empty answer records none: true"))))))

(test a-write-operation-is-not-recorded
  ;; The excluded tier. An audit trail is a different requirement with different
  ;; retention, and this is a retrieval corpus.
  (with-operations-fixture (repository)
    (with-recorded-log (directory)
      (call-operation :set-status '(:read :write)
                      :repository (repository-name repository)
                      :document "DEC-0001" :status "accepted")
      (is (zerop (length (drained-records directory))) "a write adds no record"))))

(test a-large-argument-is-recorded-as-its-size
  ;; A record says what was asked, not what was sent. CHECK-DOCUMENT carries a
  ;; whole document, and a log holding those is a second copy of docs/.
  (with-operations-fixture (repository)
    (with-recorded-log (directory)
      (ignore-errors
       (call-operation :check-document '(:read)
                       :repository (repository-name repository)
                       :path "docs/decisions/DEC-0002.yaml"
                       :contents (format nil "id: DEC-0002~%title: ~a~%"
                                         (make-string 500 :initial-element #\x))))
      (let* ((r (first (drained-records directory)))
             (contents (and r (cdr (assoc :contents (cdr (assoc :arguments r)))))))
        (is-true contents "check-document was recorded")
        (when contents
          (is (search "characters" contents)
              "the length is recorded and the payload is not"))))))

(test the-log-is-off-unless-a-directory-is-set
  ;; The default, and the whole of the tier argument: NIL writes nothing and the
  ;; read is unaffected.
  (with-operations-fixture (repository)
    (let ((loom-workspace:*context-log-directory* nil))
      (is-true (call-operation :find '(:read)
                               :repository (repository-name repository)
                               :term "alpha")
               "a read with the log off answers normally"))))


;;; ------------------------------------------------------------------
;;; Resemblance (BUG-0052)
;;; ------------------------------------------------------------------
;;;
;;; Nothing here reaches ollama. The store is built by hand over the fixture's
;;; own entity ids, the way src/knowledge/test/similar.lisp builds one, so the
;;; ordering is decided by the fixture rather than by nomic-embed-text and the
;;; assertions are about the two entries rather than about the model.

(defun fixture-vector-store (repository vectors)
  "Install a store over VECTORS -- an alist of entity id to unit vector.

REPOSITORY-CACHED-VECTORS rather than a sidecar on disk: LOAD-VECTOR-STORE is
what checks an embedder identity, and the cache is read straight through when
it holds anything but :UNLOADED. The internal accessor is the point of contact,
because installing a store is not something a caller of loom-workspace does."
  (let* ((dimensions (length (cdr (first vectors))))
         (count (length vectors))
         (flat (make-array (* count dimensions) :element-type 'single-float
                                                :initial-element 0.0)))
    (loop for (nil . v) in vectors
          for i from 0
          do (replace flat v :start1 (* i dimensions)))
    (setf (loom-workspace::repository-cached-vectors repository)
          (loom-embed:make-vector-store
           :embedder-id "fixed:test" :dimensions dimensions :count count
           :ids (map 'simple-vector #'car vectors)
           :digests (make-array count :initial-element 0)
           :vectors flat))))

(defun fixture-function-id (repository name)
  (getf (first (loom-knowledge:search-entities (repository-graph repository)
                                               :name name :type :function))
        :id))

(defmacro with-embedded-fixture ((repository) &body body)
  "The operations fixture with a two-dimensional store over its two functions.

ALPHA and ALPHA-TWICE at cosine 0.96, which is one number doing two jobs: above
*SURVEY-CUT* so a survey with no cut returns both rows, and below a cut of 0.99
so a survey given one returns none."
  `(with-operations-fixture (,repository)
     (fixture-vector-store
      ,repository
      (list (cons (fixture-function-id ,repository "alpha")
                  (make-array 2 :element-type 'single-float
                                :initial-contents '(1.0 0.0)))
            (cons (fixture-function-id ,repository "alpha-twice")
                  (make-array 2 :element-type 'single-float
                                :initial-contents '(0.96 0.28)))))
     ,@body))

(test similar-and-survey-are-registered-read-operations
  ;; BUG-0052's first half, and the assertion that fails without the entries:
  ;; REQ-0042 and DES-0041 both read `implemented' while FIND-OPERATION
  ;; answered NIL for each of these, so every REST and MCP caller got
  ;; UNKNOWN-OPERATION for a query the console has had since 2026-08-23.
  (dolist (name '(:similar :survey))
    (let ((operation (find-operation name)))
      (is-true operation "~(~a~) is not registered" name)
      (when operation
        (is (eq :read (operation-tier operation))
            "~(~a~) reads an index and a sidecar and writes neither" name))))
  ;; The shape, because both skins read it: VALIDATE-ARGUMENTS refuses on it and
  ;; TOOL-INPUT-SCHEMA builds MCP's `required' vector from it.
  (is (equal '((:repository t) (:term t) (:against nil) (:limit nil))
             (operation-arg-shape (find-operation :similar))))
  (is (equal '((:repository t) (:against t) (:cut nil))
             (operation-arg-shape (find-operation :survey)))
      "a survey names two repositories; that is the question it is"))

(test similar-returns-the-resembling-definition-with-the-subject-it-resolved
  (with-embedded-fixture (repository)
    (let ((answer (call-operation :similar '(:read)
                                  :repository (repository-name repository)
                                  :term "alpha")))
      (is (equal (repository-name repository) (getf answer :repository)))
      (is (equal (repository-name repository) (getf answer :against))
          "no `against' searches the subject's own repository, as on the console")
      (is (equal "alpha" (getf (getf answer :subject) :name))
          "the subject travels with the answer; TERM is what the caller typed")
      (let ((rows (getf answer :resembling)))
        (is (= 1 (length rows)) "the subject is not its own nearest neighbour")
        (is (equal "alpha-twice" (getf (first rows) :name)))
        (is (> (getf (first rows) :similarity) 0.9))))))

(test survey-reports-the-cut-it-used-and-honours-one-it-was-given
  (with-embedded-fixture (repository)
    (let* ((name (repository-name repository))
           (default (call-operation :survey '(:read) :repository name :against name)))
      (is (= *survey-cut* (getf default :cut)) "the cut used is on the answer")
      (is (= 2 (length (getf default :rows)))
          "each function's best match is the other one")
      (is (= 2 (getf default :total)))
      (is (null (getf default :truncated)))
      ;; The cut is read rather than ignored, which is what a survey answering
      ;; the same table at every cut would look like.
      (let ((strict (call-operation :survey '(:read) :repository name
                                                     :against name :cut "0.99")))
        (is (= 0.99 (getf strict :cut)))
        (is (null (getf strict :rows)) "no pair reaches it")))))

(test a-repository-with-no-vectors-is-refused-by-name-rather-than-answered-empty
  ;; DES-0041 D10. There is no lexical resemblance query to fall back to, so an
  ;; empty list would mean `nothing resembles this' and `nothing could have' at
  ;; once. The fixture has no store until WITH-EMBEDDED-FIXTURE installs one.
  (with-operations-fixture (repository)
    (let ((name (repository-name repository)))
      (dolist (call (list (list :similar :repository name :term "alpha")
                          (list :survey :repository name :against name)))
        (handler-case
            (progn (apply #'call-operation (first call) '(:read) (rest call))
                   (is-true nil "~(~a~) answered without a store" (first call)))
          (malformed-request (condition)
            (let ((message (request-message condition)))
              (is-true (search name message)
                       "the refusal names the repository: ~a" message)
              (is-true (search "embed" message)
                       "and the command that fixes it: ~a" message))))))))

(test an-unknown-operation-names-the-ones-that-exist
  ;; BUG-0052 F4. "No operation named similar." is true of a typo, of a verb
  ;; this build does not carry, and of one that was renamed, and a caller
  ;; cannot act until it knows which.
  (let ((message (princ-to-string (make-condition 'unknown-operation :name "similer"))))
    (is-true (search "similer" message) "the refusal repeats what was asked for")
    (is-true (search "similar" message)
             "and names what exists, which is what tells a typo from a gap: ~a"
             message))
  ;; The empty table is a state DES-0006 describes -- a skin loaded without
  ;; loom-serve's entries answers 404 -- so the report has to survive it.
  (let ((*operations* '()))
    (is (equal "No operation named nothing."
               (princ-to-string (make-condition 'unknown-operation :name "nothing"))))))


;;; ------------------------------------------------------------------
;;; What the budget buys, and in whose currency (BUG-0054)
;;; ------------------------------------------------------------------

(test the-lean-item-drops-the-scoring-fields-and-keeps-everything-else
  ;; The six exist for judging the ranking. The console reads them off the
  ;; plist and RECORD-CONTEXT-CALL is handed the bundle before anything is
  ;; encoded, so neither loses anything by their absence from the wire.
  (let* ((item (list :entity (list :id "function:src/x.lisp:alpha" :name "alpha")
                     :band :seed :summary "Adds one."
                     :cost 3 :via :calls :direction :out :convergence 2
                     :effective-cost 2 :relation-count 7
                     :relations (list (list :name "beta"))))
         (lean (loom-serve::lean-context-item item)))
    (dolist (dropped '(:cost :via :direction :convergence :effective-cost :relation-count))
      (is (eq :absent (getf lean dropped :absent))
          "~(~a~) is scoring metadata and should not be on the wire" dropped))
    (dolist (kept '(:entity :band :summary :relations))
      (is-true (getf lean kept) "~(~a~) is what the caller asked for" kept))
    (is (equal "alpha" (getf (getf lean :entity) :name))
        "the entity travels whole; only the item's own scoring keys go")))

(test a-bundle-is-thinned-in-its-items-and-nowhere-else
  ;; The totals are the caller's own arithmetic about what it asked for and
  ;; what it got. Thinning them would answer the budget question by deleting it.
  (let* ((bundle (list :task "t" :budget 400 :tokens 120 :truncated t
                       :items (list (list :entity (list :name "alpha") :cost 3)
                                    (list :entity (list :name "beta") :cost 9))
                       :bands (list :neighbour (list :found 5 :sent 2))))
         (leaned (loom-serve::leaned-bundle bundle)))
    (is (= 400 (getf leaned :budget)))
    (is (= 120 (getf leaned :tokens)))
    (is-true (getf leaned :truncated))
    (is (equal '(:neighbour (:found 5 :sent 2)) (getf leaned :bands))
        "DES-0046: the per-band count is bundle-wide accounting, not thinned")
    (is (= 2 (length (getf leaned :items))))
    (is (every (lambda (i) (eq :absent (getf i :cost :absent))) (getf leaned :items))
        "and the items are the part that was thinned")))

(test an-item-is-priced-as-the-json-the-caller-receives
  ;; BUG-0054's whole content. The console price and the JSON price of one item
  ;; are different numbers, and the budget was charged the first while the
  ;; caller was sent the second.
  (let* ((item (list :entity (list :id "method:src/domain/partition/PartitionArc.js:PartitionArc.otherNode::"
                                   :type :method :name "PartitionArc.otherNode"
                                   :location "src/domain/partition/PartitionArc.js:92-96"
                                   :language :javascript :source :structural
                                   :confidence 1.0 :referrer-kind nil :stale nil)
                     :band :seed :summary "The node at the far end."
                     :cost nil :via nil :direction nil :convergence nil
                     :effective-cost nil :relation-count 4
                     :relations nil))
         (json-price (loom-serve::context-item-tokens item))
         (console-price (loom-knowledge::estimate-tokens
                         (loom-knowledge::render-item item))))
    (is (> json-price console-price)
        "the JSON of this item is ~d tokens against the console's ~d; charging \
the second for the first is the defect" json-price console-price)
    ;; And the price is of the shape actually sent, not of the fat one.
    (is (= json-price
           (loom-knowledge::estimate-tokens (encode-result (loom-serve::lean-context-item item))))
        "priced and emitted by the same function, so they cannot disagree")))

(test the-context-operation-answers-within-the-budget-it-was-given
  ;; End to end over the fixture. The assertion is on the ratio rather than on
  ;; a byte count: before this change the encoded items ran to several times
  ;; the tokens reported, and no fixture-sized number would have caught that.
  (with-operations-fixture (repository)
    (let* ((answer (call-operation :context '(:read)
                                   :repository (repository-name repository)
                                   :task "alpha arithmetic" :budget "400"))
           (items (getf answer :items))
           (charged (getf answer :tokens))
           (actual (loom-knowledge::estimate-tokens (encode-result items))))
      (is-true items "the fixture yields a bundle")
      (is (<= actual (max 8 (round (* 1.1 charged))))
          "the items encode to ~d tokens against ~d charged" actual charged)
      (is (every (lambda (i) (eq :absent (getf i :effective-cost :absent))) items)
          "and they arrive in the shape they were priced in"))))


;;; ------------------------------------------------------------------
;;; Whether the feedback channel is open (BUG-0053)
;;; ------------------------------------------------------------------
;;;
;;; The prepared guidance devotes a section to this channel and tells the agent
;;; to quote the `record' id the answer carried. *CONTEXT-LOG-DIRECTORY* is NIL
;;; by default, so on an ordinary deployment no answer carried one and an agent
;;; following the guidance exactly recorded nothing, having no way to learn
;;; that it could not have.

(test a-bundle-says-feedback-is-off-rather-than-omitting-the-record
  (with-operations-fixture (repository)
    (let ((loom-workspace:*context-log-directory* nil))
      (let ((answer (call-operation :context '(:read)
                                    :repository (repository-name repository)
                                    :task "alpha arithmetic")))
        (is (eq :off (getf answer :feedback))
            "the state is on the answer, not inferred from a missing key")
        (is (null (getf answer :record))
            "and there is no record, which is what :OFF means")))))

(test a-bundle-with-logging-on-says-so-and-carries-the-id
  (with-operations-fixture (repository)
    (with-recorded-log (ignored-directory)
      (let ((answer (call-operation :context '(:read)
                                    :repository (repository-name repository)
                                    :task "alpha arithmetic")))
        (is (eq :on (getf answer :feedback)))
        (is-true (getf answer :record)
                 "and :ON is the state in which quoting the id can work")))))

(test feedback-being-off-is-refused-as-itself-and-not-as-a-bad-id
  ;; The two refusals were one sentence -- "No context record <id>" -- which is
  ;; true of a wrong id and false of a deployment that keeps no log. An agent
  ;; told its id was bad retries with a different id forever.
  (let ((loom-workspace:*context-log-directory* nil))
    (handler-case
        (progn (record-context-use "ctx-20260828T000000" '((:name "alpha" :how "read it")))
               (is-true nil "a call with no log directory must be refused"))
      (context-record-error (condition)
        (let ((message (princ-to-string condition)))
          (is (eq :feedback-off (loom-workspace::context-record-error-reason condition)))
          (is-true (search "off for this deployment" message)
                   "the refusal names the cause: ~a" message)
          (is-false (search "No context record" message)
                    "and does not blame the id: ~a" message)))))
  ;; The control: with a log directory, an id naming no record is still the
  ;; other refusal, unchanged.
  (with-operations-fixture (repository)
    (with-recorded-log (ignored-directory)
      (handler-case
          (progn (record-context-use "ctx-nothing-wrote-this" '((:name "a" :how "b")))
                 (is-true nil "an unknown id must still be refused"))
        (context-record-error (condition)
          (is (eq :unknown-id (loom-workspace::context-record-error-reason condition)))
          (is-true (search "No context record" (princ-to-string condition))))))))

(test a-dry-run-field-that-is-false-encodes-as-false-and-not-as-null
  ;; BUG-0065 D2. NIL is this encoder's overloaded value -- false, empty and
  ;; absent at once -- so :DRY-RUN arrived as `null' on every run that was not
  ;; a preview. Measured on PLAN-0006: "dry-run": null with every row
  ;; already-finished. The field was therefore `true' or missing and never
  ;; `false', which is not a boolean a client can branch on.
  (let ((converted (loom-serve::boolean-fields '(:dry-run nil :changed nil) '(:dry-run))))
    (is (eq loom-serve::*json-false* (getf converted :dry-run))
        "a NIL dry-run becomes the JSON false")
    (is (null (getf converted :changed))
        "and a NIL under a key nobody named is left alone"))
  (let ((untouched (loom-serve::boolean-fields '(:dry-run t) '(:dry-run))))
    (is (eq t (getf untouched :dry-run)) "a true dry-run is not rewritten")))

;;; ------------------------------------------------------------------
;;; Every read operation says what it does with a domain (PLAN-0050 S13)
;;; ------------------------------------------------------------------

(defparameter *whole-repository-reads*
  '(:check :rules :structure :drift :survey :check-document :status
    :server-status)
  "Read operations that answer about a whole repository by construction.

R-i is the one silent wrong answer DES-0047 leaves reachable: scoping is
opt-in, so a read operation that never looks at the domain answers about the
whole repository and the caller who named part of it cannot tell.

A test cannot prove an operation honours a domain without a two-domain fixture
per operation. What it can do is force the question to be answered in writing.
Every read operation is either scoped or named here with a reason:

  check, rules        report on the whole index; a rule is a query over all of
                      it and a violation is not located in a domain
  structure, drift    describe the repository as a whole, which is what they
                      are for
  survey              compares two repositories, so a domain of one is not the
                      unit
  check-document      answers about one document by path
  status              reports the repository's state; the import split it
                      carries is already per repository
  server-status       answers about the service and takes no repository at
                      all, so there is no designator for a domain to ride on

An operation added later fails the test below until somebody decides which it
is. That converts a silent wrong answer into a decision that has to be written
down. It does not make the wrong answer impossible, and the list can be
extended by anyone -- which is the honest residual and is worth stating.")

(defparameter *domain-scoped-reads*
  '(:find :describe :impact :context :similar :sites)
  "Read operations that narrow their selection to a named domain.")

(test every-read-operation-either-scopes-to-a-domain-or-says-why-not
  (let ((unclassified '()))
    (dolist (operation (loom-serve:all-operations))
      (let ((name (loom-serve:operation-name operation)))
        (when (and (eq :read (loom-serve:operation-tier operation))
                   (not (member name *domain-scoped-reads*))
                   (not (member name *whole-repository-reads*)))
          (push name unclassified))))
    (is (null unclassified)
        "~{~a~^, ~} is a read operation that neither scopes to a domain nor is ~
listed as answering about a whole repository. Decide which it is and say so in ~
*WHOLE-REPOSITORY-READS* or *DOMAIN-SCOPED-READS*."
        unclassified)))

(test the-two-read-lists-name-no-operation-twice-and-none-that-is-gone
  ;; A list that drifts from the registry stops being a decision and becomes a
  ;; comment.
  (let ((registered (mapcar #'loom-serve:operation-name (loom-serve:all-operations))))
    (dolist (name (append *domain-scoped-reads* *whole-repository-reads*))
      (is-true (member name registered)
               "~a is listed but no longer registered" name))
    (dolist (name *domain-scoped-reads*)
      (is (not (member name *whole-repository-reads*))
          "~a is in both lists" name))))

;;; ------------------------------------------------------------------
;;; DES-0054 D8: find by trigger
;;; ------------------------------------------------------------------

(defun add-triggered-function (repository name trigger)
  (loom-graph:add-entity
   (repository-graph repository)
   (make-instance 'loom-ontology:function-entity :name name :origin-file "functions/main.py"
                  :properties (loom-ontology:properties-table
                               (list :file "functions/main.py" :start-line 1 :end-line 4
                                     :language :python :trigger trigger)))))

(test find-with-a-trigger-lists-what-carries-it-with-no-term
  (with-operations-fixture (repository)
    (add-triggered-function repository "sync_zeffy" :schedule)
    (add-triggered-function repository "serve_api" :https)
    (let ((rows (getf (call-operation :find '(:read) :repository (repository-name repository)
                                                      :term "" :trigger "schedule")
                      :entities)))
      (is (equal '("sync_zeffy") (mapcar (lambda (row) (getf row :name)) rows))))
    (is (null (getf (call-operation :find '(:read) :repository (repository-name repository)
                                                   :term "" :trigger "nosuchtriggerzz")
                    :entities)))
    (is (null (find-symbol "NOSUCHTRIGGERZZ" :keyword)) "and interns nothing")
    (is (equal '("serve_api")
               (mapcar (lambda (row) (getf row :name))
                       (getf (call-operation :find '(:read)
                                             :repository (repository-name repository)
                                             :term "serve" :trigger "https")
                             :entities))))))

(test find-with-a-trigger-and-no-repository-is-refused
  (signals malformed-request
    (call-operation :find '(:read) :term "" :trigger "schedule")))

(test status-passes-the-unnamed-registration-count-through-as-an-integer
  ;; PLAN-0058 step 5. An integer needs no *ARRAY-VALUED-KEYS* entry.
  (with-operations-fixture (repository)
    (dolist (spec '(("firebase.json" (:path "firebase.json"
                                      :codebases ((:source "functions" :codebase "default"
                                                   :runtime nil :ignore nil :defaulted nil))))
                    ("functions/hello.js" (:path "functions/hello.js" :unnamed-registrations 2))))
      (loom-graph:add-entity
       (repository-graph repository)
       (make-instance 'loom-ontology:file-entity :name (first spec)
                      :origin-file (first spec)
                      :properties (loom-ontology:properties-table (second spec)))))
    (let ((status (call-operation :status '(:read) :repository (repository-name repository))))
      (is (eql 2 (getf (getf status :deploys) :unnamed-registrations)))
      (is (search "\"unnamed-registrations\":2" (loom-serve:encode-result status))))))

(test status-carries-deploys-and-encodes-as-json
  ;; DES-0054 D8. :DEPLOYS is the one nested plist :STATUS returns, and this
  ;; plist is serialized for REST and MCP callers.
  (with-operations-fixture (repository)
    (loom-graph:add-entity
     (repository-graph repository)
     (make-instance 'loom-ontology:file-entity :name "firebase.json"
                    :origin-file "firebase.json"
                    :properties (loom-ontology:properties-table
                                 '(:path "firebase.json"
                                   :codebases ((:source "functions" :codebase "default"
                                                :runtime "python312" :ignore nil
                                                :defaulted nil))))))
    (let* ((status (call-operation :status '(:read) :repository (repository-name repository)))
           (deploys (getf status :deploys)))
      (is (equal "default" (getf (first (getf deploys :codebases)) :codebase)))
      (is (null (getf deploys :declared)))
      (let ((json (loom-serve:encode-result status)))
        (is (search "\"deploys\"" json))
        (is (search "python312" json))))))

(defun add-dependency-entities (repository)
  "An unmapped pypi :MODULE with no specs, and a python :FILE with one undeclared import."
  (let ((graph (repository-graph repository)))
    (loom-graph:add-entity
     graph
     (make-instance 'loom-ontology:module-entity :name "tzdata"
                    :origin-file "requirements.txt"
                    :properties (loom-ontology:properties-table
                                 '(:qualified-name "tzdata" :file "requirements.txt"
                                   :ecosystem :pypi))))
    (loom-graph:add-entity
     graph
     (make-instance 'loom-ontology:file-entity :name "app/main.py"
                    :origin-file "app/main.py"
                    :properties (loom-ontology:properties-table
                                 '(:path "app/main.py" :language :python
                                   :import-sources ("foo")
                                   :unresolved-imports ((:specifier "foo" :cause :external))
                                   :import-modules ((:source "foo" :module "foo" :stdlib nil))
                                   :undeclared-imports ((:specifier "foo"))))))))

(test status-carries-dependencies-and-encodes-them-as-json
  ;; DES-0055 R8. :DEPENDENCIES is a list of plists, which is a shape the encoder
  ;; walks by whether its first element is a keyword.
  (with-operations-fixture (repository)
    (add-dependency-entities repository)
    (let* ((status (call-operation :status '(:read) :repository (repository-name repository)))
           (pypi (first (getf status :dependencies))))
      (is (eq :pypi (getf pypi :ecosystem)))
      (is (= 1 (getf pypi :undeclared)))
      (let* ((json (loom-serve:encode-result status))
             (parsed (json:decode-json-from-string json))
             (dependencies (cdr (assoc :dependencies parsed))))
        (is (listp dependencies))
        (is (equal "pypi" (cdr (assoc :ecosystem (first dependencies)))) "~a" json)
        (is (eql 1 (cdr (assoc :undeclared (first dependencies)))))))))

(test describe-of-a-module-encodes-its-empty-specs-as-an-array
  (with-operations-fixture (repository)
    (add-dependency-entities repository)
    (let* ((detail (call-operation :describe '(:read)
                                   :repository (repository-name repository)
                                   :term "tzdata"))
           (json (loom-serve:encode-result detail))
           (dependency (cdr (assoc :dependency (json:decode-json-from-string json)))))
      (is (equal "requirements.txt" (cdr (assoc :manifest dependency))))
      (is (search "\"specs\":[]" json) "an empty list must not arrive as null: ~a" json)
      (is (search "\"provides\":[]" json)))))

;;; ------------------------------------------------------------------
;;; DES-0055 D12: `sites'
;;; ------------------------------------------------------------------
;;;
;;; The fixture's ALPHA-TWICE calls (alpha (alpha x)) on line 2, and the Lisp
;;; analyzer records the two forms' signatures: the outer takes a call, `1:c',
;;; and the inner a variable, `1:y'. So `alpha' has two sites of one each.

(test sites-is-a-registered-read-operation
  (let ((operation (find-operation :sites)))
    (is-true operation)
    (when operation (is (eq :read (operation-tier operation)))))
  (is (equal '((:repository t) (:term t) (:limit nil))
             (operation-arg-shape (find-operation :sites)))))

(test sites-answers-the-groups-and-the-entity-it-resolved-as-json-that-parses
  (with-operations-fixture (repository)
    (let* ((answer (call-operation :sites '(:read)
                                   :repository (repository-name repository)
                                   :term "alpha"))
           (groups (getf answer :groups))
           (json (loom-serve:encode-result answer))
           (parsed (json:decode-json-from-string json)))
      (is (equal "alpha" (getf (getf answer :entity) :name)))
      (is (equal '("1:c" "1:y") (mapcar (lambda (g) (getf g :signature)) groups))
          "~s" groups)
      (is (equal '("src/code.lisp" 2 "alpha-twice")
                 (first (getf (first groups) :sites))))
      (is (= 2 (length (cdr (assoc :groups parsed)))) "~a" json)
      (is (equal "1:c" (cdr (assoc :signature (first (cdr (assoc :groups parsed))))))))))

(test sites-of-an-entity-nothing-calls-encodes-an-empty-array-and-not-null
  (with-operations-fixture (repository)
    (let ((json (loom-serve:encode-result
                 (call-operation :sites '(:read)
                                 :repository (repository-name repository)
                                 :term "alpha-twice"))))
      (is (search "\"groups\":[]" json) "~a" json)
      (finishes (json:decode-json-from-string json)))))

(test sites-limit-bounds-the-rows-a-group-shows
  (with-operations-fixture (repository)
    (let* ((answer (call-operation :sites '(:read)
                                   :repository (repository-name repository)
                                   :term "alpha" :limit "0"))
           (group (first (getf answer :groups))))
      (is (null (getf group :sites)))
      (is (= 1 (getf group :more)))
      (is (search "\"sites\":[]" (loom-serve:encode-result answer))))
    (signals malformed-request
      (call-operation :sites '(:read)
                      :repository (repository-name repository)
                      :term "alpha" :limit "many"))))

(test sites-names-its-repository-and-refuses-an-unknown-entity
  (with-operations-fixture (repository)
    (signals malformed-request (call-operation :sites '(:read) :term "alpha"))
    (signals unknown-entity
      (call-operation :sites '(:read)
                      :repository (repository-name repository)
                      :term "zarquon"))))

(test describe-over-the-operation-carries-the-distribution-as-json
  (with-operations-fixture (repository)
    (let* ((detail (call-operation :describe '(:read)
                                   :repository (repository-name repository)
                                   :term "alpha"))
           (json (loom-serve:encode-result detail))
           (shapes (cdr (assoc :call-shapes (json:decode-json-from-string json)))))
      (is (eql 2 (cdr (assoc :sites shapes))) "~a" json)
      (is (equal '(("1:c" 1) ("1:y" 1))
                 (cdr (assoc :signatures shapes)))
          "~a" json))))

;;; BUG-0079. A read is admitted to a repository for as long as it runs, and a
;;; reindex neither starts nor lets a new read in until the admitted ones end.

(test a-read-operation-is-refused-while-its-repository-is-rebuilt
  (with-operations-fixture (repository)
    (let ((name (repository-name repository)))
      (loom-workspace::begin-rebuild repository)
      (unwind-protect
           (let ((condition (handler-case (invoke-operation (find-operation :find)
                                                            (list :read) (list :repository name :term "alpha"))
                              (repository-indexing (c) c))))
             (is (typep condition 'repository-indexing)
                 "a find answered while the repository was rebuilt: ~a" condition))
        (loom-workspace::end-rebuild repository))
      (is (consp (invoke-operation (find-operation :find) (list :read)
                                   (list :repository name :term "alpha")))
          "the same find was refused after the rebuild ended"))))

(test a-read-releases-its-hold-whether-it-answers-or-fails
  (with-operations-fixture (repository)
    (let ((name (repository-name repository)))
      (invoke-operation (find-operation :describe) (list :read)
                        (list :repository name :term "alpha"))
      (is (zerop (loom-workspace::repository-readers repository))
          "a describe that answered left its hold in place")
      (ignore-errors (invoke-operation (find-operation :describe) (list :read)
                                       (list :repository name :term "no-such-entity-anywhere")))
      (is (zerop (loom-workspace::repository-readers repository))
          "a describe that failed left its hold in place"))))
