;;;; The document-store protocol's own tests: capabilities and stamps.
;;;;
;;;; DES-0051 D9 part A, the conformance tests every store runs, is in
;;;; conformance.lisp once there is a store to run them against. What is here
;;;; tests the protocol machinery itself.

(defpackage #:loom-docstore-test
  (:use #:cl #:fiveam #:loom-docstore)
  (:export #:test-runner #:all-tests))

(in-package :loom-docstore-test)

(def-suite all-tests
  :description "Master suite of all loom-docstore tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))


;;;; ==================================================================
;;;; Capabilities (DES-0051 D3)
;;;; ==================================================================

(defclass bare-store () ()
  (:documentation "A store with no methods at all."))

(defclass reading-store () ()
  (:documentation "A store that answers read and nothing else."))

(defmethod docstore-read ((store reading-store) ref)
  (declare (ignore ref))
  (values "" 0))

(test a-store-with-no-methods-declares-every-operation-absent
  ;; D3: a missing capability is declared rather than discovered on the first
  ;; call. A capabilities method that answered :NATIVE for everything would
  ;; pass every test that only asks about a store with methods.
  (let ((capabilities (docstore-capabilities (make-instance 'bare-store))))
    (loop for (operation) in *docstore-operations*
          do (is (eq :absent (getf capabilities operation))
                 "~s reads ~s on a store with no methods"
                 operation (getf capabilities operation)))
    (is (eq :absent (getf capabilities :batch)))))

(test a-method-makes-its-operation-native-and-no-other
  (let ((capabilities (docstore-capabilities (make-instance 'reading-store))))
    (is (eq :native (getf capabilities :read)))
    (is (eq :absent (getf capabilities :enumerate)))
    (is (eq :absent (getf capabilities :write)))))

(test every-operation-is-a-generic-function
  ;; *DOCSTORE-OPERATIONS* names functions by symbol, and a misspelled one
  ;; would make ANSWERS-P signal on every store.
  (loop for (operation . function) in *docstore-operations*
        do (is (typep (fdefinition function) 'generic-function)
               "~s names ~s, which is not a generic function" operation function)))


;;;; ==================================================================
;;;; Stamps
;;;; ==================================================================

(defun write-text (path text)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string text out)))

(test a-path-never-read-has-changed
  (uiop:with-temporary-file (:pathname path :type "yaml")
    (write-text path "alpha")
    (is (stamp-changed-p nil path (get-universal-time)))))

(test an-unreadable-path-has-not-changed
  ;; A file that vanished between the walk and the stat leaves the index alone.
  ;; The deletion is somebody else's to notice.
  (is (not (stamp-changed-p (make-file-stamp 0 0)
                            #p"/nonexistent/loom-docstore-test.yaml"
                            (get-universal-time)))))

(test inside-the-settle-window-the-content-decides
  ;; CON-0002. The write date matches and is recent, so the clock cannot
  ;; answer, and the hash has to. Each stamp is built with the file's own write
  ;; date, so the test does not depend on when the second ticks over.
  (uiop:with-temporary-file (:pathname path :type "yaml")
    (write-text path "bravo")
    (let ((write-date (file-write-date path)))
      (is (stamp-changed-p (make-file-stamp write-date (sxhash "alpha")) path write-date)
          "a same-second edit was not seen")
      (is (not (stamp-changed-p (make-file-stamp write-date (sxhash "bravo")) path write-date))
          "an untouched file inside the window read as changed"))))

(test outside-the-settle-window-the-write-date-is-believed
  ;; The other half. Past the window a matching write date is trusted and the
  ;; file is not read, so a stale hash goes unnoticed on purpose.
  (uiop:with-temporary-file (:pathname path :type "yaml")
    (write-text path "bravo")
    (let ((write-date (file-write-date path)))
      (is (not (stamp-changed-p (make-file-stamp write-date (sxhash "alpha"))
                                path (+ write-date *mtime-settle-seconds* 1))))
      (is (stamp-changed-p (make-file-stamp (1- write-date) (sxhash "bravo"))
                           path (+ write-date *mtime-settle-seconds* 1))
          "a moved write date was not a change"))))
