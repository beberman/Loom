;;;; The document-store protocol's own tests: capabilities and stamps.
;;;;
;;;; DES-0051 D9 part A, the conformance tests every store runs, is in
;;;; conformance.lisp once there is a store to run them against. What is here
;;;; tests the protocol machinery itself.

(defpackage #:synoptik-docstore-test
  (:use #:cl #:fiveam #:synoptik-docstore)
  (:export #:test-runner #:all-tests))

(in-package :synoptik-docstore-test)

(def-suite all-tests
  :description "Master suite of all synoptik-docstore tests")

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
                            #p"/nonexistent/synoptik-docstore-test.yaml"
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


;;;; ==================================================================
;;;; Choosing a store (DES-0052)
;;;; ==================================================================

(test both-stores-register-themselves
  ;; A registry with one entry demonstrates nothing. Each store calls
  ;; REGISTER-DOCSTORE-KIND at the bottom of its own file, so the table is
  ;; built by loading and not by a list somebody maintains.
  (is (equal '(:file :memory) (docstore-kinds))
      "the registered kinds are ~s" (docstore-kinds)))

(test a-kind-nothing-registered-is-refused-and-the-refusal-names-what-is
  ;; Falling back to the file store would index a checkout\'s docs/ while the
  ;; caller believed they were reading from somewhere else -- the one failure
  ;; no count reveals (DES-0052 D5).
  (let ((refusal (handler-case (progn (make-docstore :jira) nil)
                   (docstore-refused (c) (docstore-refused-reason c)))))
    (is (stringp refusal) "an unregistered kind built something")
    (is (search "jira" refusal) "the refusal does not name the kind: ~a" refusal)
    (is (search "file" refusal) "the refusal does not name what is registered: ~a"
        refusal)))

(test registering-a-kind-twice-replaces-rather-than-accumulates
  ;; REGISTER-ANALYZER\'s rule, and for the same reason: recompiling a file in
  ;; a live image runs its registration form again, and a second entry would
  ;; make which constructor runs depend on load order.
  (let ((*docstore-kinds* *docstore-kinds*))
    (register-docstore-kind :probe (lambda (config services)
                                     (declare (ignore config services)) :first))
    (register-docstore-kind :probe (lambda (config services)
                                     (declare (ignore config services)) :second))
    (is (eq :second (make-docstore :probe)))
    (is (= 1 (count :probe (docstore-kinds))) "the kind is registered twice")))

(test an-unknown-declaration-key-is-refused-by-name
  ;; DES-0052 D4. The workspace stopped reading the block, so nothing else is
  ;; looking: a key nobody reads has to be refused rather than passed over, or
  ;; a typo is invisible.
  (let ((refusal (handler-case
                     (progn (make-docstore :file
                                           :config '(:kind "file" :extnesion "yaml")
                                           :services (list :root #p"/tmp/"))
                            nil)
                   (docstore-refused (c) (docstore-refused-reason c)))))
    (is (stringp refusal) "a misspelled key was accepted")
    (is (search "extnesion" refusal) "the refusal does not name the key: ~a" refusal)
    (is (search "extension" refusal) "nor what the store does take: ~a" refusal)))

(test a-declaration-reaches-the-store-it-declares
  ;; The whole point of CONFIG: the workspace passed a value it never read and
  ;; the store used it.
  (let ((store (make-docstore :file
                              :config '(:kind "file" :extension "md")
                              :services (list :root #p"/tmp/"))))
    (is (string= "md" (file-docstore-extension store))))
  (let ((store (make-docstore :file :services (list :root #p"/tmp/"))))
    (is (string= "yaml" (file-docstore-extension store))
        "a declaration that says nothing gets the default")))

(test a-file-store-with-no-root-is-refused
  ;; SERVICES is the workspace\'s half and a missing root is its mistake, not
  ;; the declaration\'s -- but it is refused in the same place and with the same
  ;; condition, because a caller printing the reason does not care whose it was.
  (signals docstore-refused (make-docstore :file :config '(:kind "file"))))

(test an-in-memory-store-can-be-declared
  ;; Registered so a tree can be run against it without a Lisp caller, which is
  ;; also what keeps the registry honest: two kinds from the start.
  (let ((store (make-docstore :memory :config '(:kind "memory")
                                      :services (list :root #p"/tmp/"))))
    (is (typep store 'memory-docstore))
    (is (null (docstore-enumerate store)) "a fresh in-memory store holds nothing")))
