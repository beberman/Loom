;;;; The leaf utilities, and the three behaviours the merge had to preserve.
;;;;
;;;; REV-0002. Most of what is here is small enough that a test looks like a
;;;; restatement, and those tests are not written. What is tested is where the
;;;; move could have changed an answer -- CON-0003's rule, applied to a
;;;; refactor: a test earns its place by failing against a plausible wrong
;;;; version of the change, not against the absence of the code.
;;;;
;;;; AWAIT-THREAD carries three of them, because three implementations were
;;;; merged into it and they did not agree.

(defpackage #:loom-utils-test
  (:use #:cl #:fiveam #:loom-utils)
  (:export #:test-runner #:all-tests))

(in-package :loom-utils-test)

(def-suite all-tests
  :description "Master suite of all loom-utils tests")

(in-suite all-tests)

(defun test-runner ()
  (run! 'all-tests))


;;;; ==================================================================
;;;; await-thread (REV-0002 A7)
;;;; ==================================================================

(test await-thread-answers-true-for-no-thread
  ;; Both loom-workspace callers read a slot holding a thread or nothing, and
  ;; this is why neither has to guard. Written because the first version of the
  ;; merge dropped the guard and every read operation in loom-serve began
  ;; answering "NIL is not of type SB-THREAD:THREAD" -- 44 failures across two
  ;; systems from one missing clause.
  (is (await-thread nil 0)))

(test await-thread-answers-true-for-a-thread-that-has-finished
  (let ((thread (bordeaux-threads:make-thread (lambda () 1) :name "loom-utils-done")))
    (bordeaux-threads:join-thread thread)
    (is (await-thread thread 1))))

(test an-aborted-thread-has-finished-rather-than-timed-out
  ;; The one behaviour the merge had to choose rather than inherit, and the
  ;; reason it is asserted here. loom-serve's implementation read
  ;; JOIN-THREAD's :TIMED-OUT default as "still running", which is right for its
  ;; own caller -- it then finishes the stop itself. For loom-workspace an index
  ;; thread that aborted has finished: the build is over and there will not be
  ;; another, and reading the abort as "still indexing" would make every
  ;; subsequent request answer `still being indexed' for the life of the
  ;; process. This fails against a version that returns JOIN-THREAD's value.
  ;; SB-THREAD:ABORT-THREAD rather than an unhandled ERROR, which is the
  ;; distinction between ending a thread and ending this process: under
  ;; --script an unhandled condition in any thread reaches
  ;; DEBUGGER-DISABLED-HOOK and quits, so the first version of this test took
  ;; the whole suite down with it after printing one line.
  ;;
  ;; The thread has to still be alive when AWAIT-THREAD is called, or the test
  ;; is vacuous: the early THREAD-ALIVE-P clause answers T for an
  ;; already-finished thread whichever way the join is read, and the first
  ;; version of this test aborted the thread before calling and so passed
  ;; against both implementations. It aborts during the wait instead.
  (let ((thread (bordeaux-threads:make-thread
                 (lambda () (sleep 0.3) (sb-thread:abort-thread))
                 :name "loom-utils-abort")))
    (is (await-thread thread 5)
        "an aborted thread reads as still running")))

(test await-thread-answers-nil-while-a-thread-is-still-running
  ;; The other half: a wait that always answered true would pass every test
  ;; above and report a build in flight as finished.
  (let* ((gate (bordeaux-threads:make-lock "loom-utils-gate"))
         (thread (progn
                   (bordeaux-threads:acquire-lock gate)
                   (bordeaux-threads:make-thread
                    (lambda () (bordeaux-threads:with-lock-held (gate) t))
                    :name "loom-utils-blocked"))))
    (unwind-protect
         (is (not (await-thread thread 0.2))
             "a thread still holding on read as finished")
      (bordeaux-threads:release-lock gate)
      (ignore-errors (bordeaux-threads:join-thread thread)))))

(test sleep-until-returns-early-when-the-predicate-turns-true
  ;; A single long SLEEP passes nothing here: the point of the slice loop is
  ;; that a stop is noticed before the interval is out.
  (let* ((stop nil)
         (started (get-internal-real-time))
         (waiter (bordeaux-threads:make-thread
                  (lambda () (sleep-until 30 (lambda () stop)))
                  :name "loom-utils-sleeper")))
    (sleep 0.2)
    (setf stop t)
    (bordeaux-threads:join-thread waiter)
    (is (< (/ (float (- (get-internal-real-time) started))
              internal-time-units-per-second)
           5)
        "sleep-until waited out the whole interval after the stop was set")))


;;;; ==================================================================
;;;; The refusal vocabulary (REV-0002 A2)
;;;; ==================================================================

(test a-refusal-is-an-error-and-carries-its-sentence
  ;; RULE-0004 as a test rather than as a caution. Every handler around the two
  ;; call sites that forced this condition down here is written as
  ;; (handler-case ... (error ...)), and a condition defined as a direct
  ;; subtype of CONDITION would pass through all of them unnoticed.
  (is (subtypep 'refusal 'error))
  (handler-case (refuse "~a has no vector store." "alpha")
    (refusal (condition)
      (is (string= "alpha has no vector store." (refusal-message condition)))
      (is (string= "alpha has no vector store."
                   (princ-to-string condition))
          "the report function does not print the message"))))


;;;; ==================================================================
;;;; Reading a scalar (REV-0002 C2)
;;;; ==================================================================

(test junk-after-the-digits-is-not-an-integer
  ;; REV-0001 finding 4. `depth 3x' meaning 3 is a guess about intent, and a
  ;; wrong guess about a bound is invisible in the output.
  (is (not (is-integer-p "3x")))
  (is (null (to-integer "3x")))
  (is (= 3 (to-integer "3")))
  (is (= 3 (to-integer 3))))

(test zero-is-an-integer
  ;; Why IS-INTEGER-P can be written as (and (to-integer value) t) at all: the
  ;; one value where a converter returning its answer could be mistaken for a
  ;; converter returning nothing.
  (is (is-integer-p "0"))
  (is (is-integer-p 0))
  (is (eql 0 (to-integer "0"))))

(test an-unreadable-boolean-is-told-apart-from-false
  ;; game-server BUG-0001. Collapsing these two is the silent misread that
  ;; report is about, and the second value is the whole of the answer.
  (is (equal '(t t) (multiple-value-list (to-boolean "yes"))))
  (is (equal '(nil t) (multiple-value-list (to-boolean "off"))))
  (is (equal '(nil nil) (multiple-value-list (to-boolean "yep"))))
  (is (not (is-boolean-p "yep"))))

(test to-cosine-reads-a-decimal-and-refuses-anything-else
  (is (= 0.8 (to-cosine "0.8")))
  (is (= 0.8 (to-cosine 0.8)))
  (is (null (to-cosine "0.8.1")))
  (is (null (to-cosine "#.(cl:+ 1 1)"))
      "to-cosine admitted something a reader would have evaluated"))


;;;; ==================================================================
;;;; paths and plists
;;;; ==================================================================

(test path-segments-keeps-empty-segments
  ;; Kept rather than dropped, because the two callers disagree about what a
  ;; leading slash means and only one of them can be served by a filter here.
  (is (equal '("docs" "reviews" "REV-0002.yaml")
             (path-segments "docs/reviews/REV-0002.yaml")))
  (is (equal '("" "a") (path-segments "/a")))
  (is (equal '("a") (path-segments "a"))))

(test dot-prefixed-p-answers-for-a-non-string
  ;; Every caller reaches this with whatever a pathname component yielded, and
  ;; :ABSOLUTE and NIL both arrive.
  (is (dot-prefixed-p ".git"))
  (is (not (dot-prefixed-p "git")))
  (is (not (dot-prefixed-p "")))
  (is (not (dot-prefixed-p nil)))
  (is (not (dot-prefixed-p :absolute))))

(test filter-plist-keeps-keys-and-values-together
  ;; The reason this is not REMOVE-IF: a plist filtered an element at a time is
  ;; no longer a plist, and the failure is silent -- the result still reads as
  ;; one, with every value shifted onto the wrong key.
  (is (equal '(:a 1 :c 3)
             (filter-plist '(:a 1 :b 2 :c 3) (lambda (key) (not (eq key :b))))))
  (is (equal '(:b 2) (strip-plist '(:a 1 :b 2 :c 3) '(:a :c))))
  (is (equal '() (filter-plist '(:a 1) (constantly nil)))))


;;;; ==================================================================
;;;; the log (REV-0002 A1)
;;;; ==================================================================

(test the-log-is-bounded-and-newest-first
  (let ((*log* '())
        (*log-limit* 3))
    (dotimes (i 5) (log-event "test" "event ~d" i))
    (is (= 3 (length *log*)))
    (is (string= "event 4" (third (first *log*)))
        "the log is not newest-first")
    (is (= 2 (length (recent-log 2))))
    (is (= 3 (length (recent-log 99)))
        "recent-log ran off the end rather than stopping at what it has")))


;;;; ==================================================================
;;;; distribution-name-key (DES-0055 D6, PLAN-0059 step 4)
;;;; ==================================================================

(test distribution-names-that-pip-treats-as-one-share-a-key
  ;; PEP 503: lower case, each run of `-', `_' and `.' one `-'. The three
  ;; spellings below are one distribution to pip.
  (is (string= "google-auth" (distribution-name-key "Google_Auth")))
  (is (string= "google-auth" (distribution-name-key "google.auth")))
  (is (string= "google-auth" (distribution-name-key "google--auth")))
  (is (string= "google-auth" (distribution-name-key "google-_.auth"))))

(test an-import-name-and-a-distribution-name-do-not-share-a-key
  ;; DES-0055 D6: no spelling join. These two differ by more than separators
  ;; and case, so the key must keep them apart.
  (is (string/= (distribution-name-key "googleapiclient")
                (distribution-name-key "google-api-python-client"))))
