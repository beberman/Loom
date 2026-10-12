;;;
;;; Tests for src/analyzer/extractor-child.lisp -- the lifecycle two analyzers
;;; share (DES-0053 R14).
;;;
;;; The child here is a few lines of python3 written inline, so these tests
;;; exercise the lifecycle and not either language's extractor. The JavaScript
;;; analyzer's own restart tests, which pass unchanged, are the other half.
;;;

(in-package :loom-analyzer-test)

(def-suite extractor-child
  :in all-tests
  :description "The shared extractor child's lifecycle: reuse, replacement, absence, timeout.")

(in-suite extractor-child)

(defparameter *echo-child*
  ;; Reads frames as extract.js does and answers each with its own pid, so a
  ;; test can tell one process from another. argv[1] is a marker path: while it
  ;; does not exist the child creates it and exits after reading its first
  ;; frame, which is a child that dies mid-tree.
  "import sys, os, json
marker = sys.argv[1]
mode = sys.argv[2]
while True:
    path = sys.stdin.readline()
    if not path:
        break
    n = int(sys.stdin.readline())
    sys.stdin.read(n)
    if mode == 'die-once' and not os.path.exists(marker):
        open(marker, 'w').close()
        sys.exit(0)
    if mode == 'hang':
        import time
        time.sleep(60)
    print(json.dumps({'path': path.strip(), 'pid': os.getpid()}), flush=True)
")

(defun python-available-p ()
  (handler-case
      (progn (uiop:run-program '("python3" "-c" "pass")) t)
    (error () nil)))

(defun call-with-python (thunk)
  "Run THUNK, or skip when python3 cannot be started. PLAN-0056 risk 10: a skip
passes for the wrong reason, so the commit that adds this records that none is
taken on the machine the suite runs on. A function and not a macro, so Loom's
own index gains no definer macro for `check' to report as unreadable."
  (if (python-available-p)
      (funcall thunk)
      (skip "python3 is not on PATH; the extractor child cannot be exercised here")))

(defun marker-path ()
  (namestring (merge-pathnames (format nil "loom-child-marker-~a-~a" (get-universal-time) (random 1000000 (make-random-state t)))
                               (uiop:temporary-directory))))

(defun echo-child (mode &key (marker (marker-path)) (timeout 5) (program "python3"))
  (loom-analyzer::make-extractor-child
   :name "echo"
   :argv-function (lambda () (list program "-I" "-B" "-c" *echo-child* marker mode))
   :timeout-function (lambda () timeout)))

(defun reply-pid (reply) (cdr (assoc :pid reply)))

(test the-child-is-launched-once-and-reused
  (call-with-python
   (lambda ()
     (let ((child (echo-child "echo")))
       (unwind-protect
            (let* ((first (loom-analyzer::exchange-with-child child "a.x" "one"))
                   (second (loom-analyzer::exchange-with-child child "b.x" "two")))
              (is (integerp (reply-pid first)))
              (is (equal (reply-pid first) (reply-pid second))
                  "the second file went to the same process, not a fresh one"))
         (loom-analyzer::stop-extractor-child child))))))

(test a-stopped-child-is-replaced-and-the-next-exchange-answers
  (call-with-python
   (lambda ()
     (let ((child (echo-child "echo")))
       (unwind-protect
            (let ((before (reply-pid (loom-analyzer::exchange-with-child child "a.x" "one"))))
              (loom-analyzer::stop-extractor-child child)
              (is (null (loom-analyzer::child-process child)))
              (let ((after (reply-pid (loom-analyzer::exchange-with-child child "b.x" "two"))))
                (is (integerp after))
                (is (not (equal before after)) "a different process")))
         (loom-analyzer::stop-extractor-child child))))))

(test a-child-that-dies-on-a-frame-gets-exactly-one-retry
  ;; The child exits after reading its first frame, with the process still
  ;; marked alive when the exchange begins. Only the retry reaches the second
  ;; launch, which answers: delete the retry and this returns NIL.
  (call-with-python
   (lambda ()
     (let ((marker (marker-path)))
       (unwind-protect
            (let ((child (echo-child "die-once" :marker marker)))
              (unwind-protect
                   (multiple-value-bind (reply reason)
                       (loom-analyzer::exchange-with-child child "a.x" "one")
                     (is (integerp (reply-pid reply)) "answered by the relaunched child")
                     (is (null reason)))
                (loom-analyzer::stop-extractor-child child)))
         (ignore-errors (delete-file marker)))))))

(test a-child-that-always-dies-is-not-retried-forever
  ;; A program that exits at once: two attempts and then a reason, never a loop
  ;; across the tree.
  (call-with-python
   (lambda ()
     (let ((child (loom-analyzer::make-extractor-child
                   :name "dying"
                   :argv-function (lambda () (list "python3" "-c" "import sys; sys.stdin.readline()"))
                   :timeout-function (lambda () 5))))
       (unwind-protect
            (multiple-value-bind (reply reason) (loom-analyzer::exchange-with-child child "a.x" "one")
              (is (null reply))
              (is (search "dying extractor stopped responding" reason)))
         (loom-analyzer::stop-extractor-child child))))))

(test a-missing-program-records-a-reason-naming-it
  ;; Needs no interpreter: it makes one unfindable on purpose.
  (let ((child (echo-child "echo" :program "loom-no-such-interpreter-should-exist")))
    (multiple-value-bind (reply reason) (loom-analyzer::exchange-with-child child "a.x" "one")
      (is (null reply))
      (is (search "loom-no-such-interpreter-should-exist" reason)
          "the reason names what was missing, so a reader can act on it")
      (is (equal reason (loom-analyzer::child-unavailable-reason child))))))

(test a-child-that-never-replies-yields-nil-after-the-timeout
  (call-with-python
   (lambda ()
     (let ((child (echo-child "hang" :timeout 1))
           (start (get-internal-real-time)))
       (unwind-protect
            (multiple-value-bind (reply reason) (loom-analyzer::exchange-with-child child "a.x" "one")
              (is (null reply))
              (is (search "stopped responding" reason))
              (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second)
                     10)
                  "two one-second waits, not the child's sixty-second sleep"))
         (loom-analyzer::stop-extractor-child child))))))
