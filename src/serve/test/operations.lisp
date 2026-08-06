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
        (merge-pathnames (format nil "loom-serve-~36r/" (random (expt 2 48)))
                         (uiop:temporary-directory)))
  (ensure-directories-exist *operations-fixture-root*)
  (write-operations-fixture-file "src/code.lisp" "(defun alpha (x) (+ x 1))
(defun alpha-twice (x) (alpha (alpha x)))
")
  (write-operations-fixture-file "docs/design/DEC-0001.yaml"
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
;;; No guessing (R2, and ARCH-0006's repository-selection paragraph)
;;; ------------------------------------------------------------------

(test every-operation-names-its-repository
  ;; The witness for "a program either knows which repository it means or
  ;; should ask first". It fails against any implementation that reached for
  ;; CURRENT-REPOSITORY, which would answer happily here because the fixture
  ;; is the only watched repository -- which is exactly how the convenience
  ;; that is right for a human becomes a wrong answer for a program.
  (with-operations-fixture (repository)
    (dolist (name '(:find :describe :impact :context :check :rules
                    :watch :pause :unwatch :reindex))
      (signals malformed-request
        (call-operation name '(:read :write) :term "alpha" :task "alpha")))
    ;; :status is the exception, and the reason it is: with no designator it
    ;; is the discovery call, and it must answer rather than refuse.
    (let ((all (call-operation :status '(:read))))
      (is (member (repository-name repository)
                  (mapcar (lambda (status) (getf status :name))
                          (getf all :repositories))
                  :test #'string=)))))

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
  ;; The only guard on the duplication ARCH-0006 accepts under CONSEQUENCES,
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
             (length (getf report :unenforced)))))
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
