;;;
;;; Tests for src/serve/server.lisp -- the acceptor and the registration seam.
;;;
;;; The fixture macro and the drakma helpers below are written here and reused
;;; by loom-rest's and loom-mcp's own suites, which depend on this system for
;;; exactly that reason. Port discipline is the reason it is worth sharing: a
;;; leaked acceptor makes the *next* run fail in a way that looks like a code
;;; defect and is not, so every test that starts one uses a port well away from
;;; 4780, stops it in an UNWIND-PROTECT, and does not assume the previous test's
;;; acceptor is gone.
;;;
;;; Requests go over TCP through drakma rather than by calling the handler
;;; directly. A direct call does not run in a Hunchentoot worker thread and
;;; therefore does not test the thing any of this is about.
;;;

(in-package :loom-serve-test)

(def-suite server
  :in all-tests
  :description "The listener, the seam, and starting twice.")

(in-suite server)

(defparameter *test-port* 47180
  "Not 4780. A test that bound the real port would fail against a developer's
own running service and pass everywhere else.")

(defun test-url (path &optional (port *test-port*))
  (format nil "http://127.0.0.1:~d~a" port path))

(defun http-call (path &rest arguments)
  "DRAKMA:HTTP-REQUEST against the test server. Returns (values body status).

*TEXT-CONTENT-TYPES* is widened because drakma hands back a byte vector for
any type it does not consider text, and application/json is not on its default
list -- every assertion about a body would otherwise be an assertion about
octets."
  (let ((drakma:*text-content-types*
          (cons '("application" . "json") drakma:*text-content-types*)))
    (multiple-value-bind (body status)
        (apply #'drakma:http-request (test-url path) arguments)
      (values body status))))

(defmacro with-test-server ((&key (port '*test-port*)) &body body)
  `(progn
     ;; Not an assumption that nothing is running: a previous test that failed
     ;; between START-SERVER and its own UNWIND-PROTECT would otherwise make
     ;; every test after it fail on a port collision.
     (stop-server)
     (start-server :port ,port)
     (unwind-protect (progn ,@body)
       (stop-server))))

(defmacro with-saved-handlers (&body body)
  "Run BODY with *HANDLERS* restored afterwards.

SETF and not a LET binding, and that distinction is load-bearing: a special
variable's binding is thread-local, and the thread that reads *HANDLERS* is a
Hunchentoot worker rather than this one. A LET here would change nothing the
server can see."
  (let ((saved (gensym "HANDLERS")))
    `(let ((,saved *handlers*))
       (unwind-protect (progn ,@body)
         (setf *handlers* ,saved)))))

;;; ------------------------------------------------------------------

(test an-acceptor-with-nothing-registered-answers-404
  ;; The step's real content: the listener runs with no loom-rest in the image
  ;; at all, which is the tripwire for the circular dependency the registration
  ;; seam exists to avoid. If START-SERVER had reached for loom-rest's routes,
  ;; loom-serve.asd would need #:loom-rest and this system would not build.
  (with-saved-handlers
    (setf *handlers* '())
    (with-test-server ()
      (multiple-value-bind (body status) (http-call "/anything")
        (is (= 404 status))
        (is (search "UNKNOWN-OPERATION" body)
            "the 404 body is not the JSON a program can read: ~a" body)))))

(test a-registered-handler-answers
  (with-saved-handlers
    (setf *handlers* '())
    (register-handler :fixture "/fixture"
                      (lambda (request)
                        (declare (ignore request))
                        (setf (hunchentoot:content-type*) "application/json")
                        (encode-result '(:answered t))))
    (with-test-server ()
      (multiple-value-bind (body status) (http-call "/fixture/anything")
        (is (= 200 status))
        (is (equal "{\"answered\":true}" body)))
      ;; And a path outside the prefix still falls through to the 404.
      (is (= 404 (nth-value 1 (http-call "/elsewhere")))))))

(test registering-a-handler-twice-replaces-it
  (with-saved-handlers
    (setf *handlers* '())
    (register-handler :fixture "/fixture" (lambda (request) (declare (ignore request)) "first"))
    (register-handler :fixture "/fixture" (lambda (request) (declare (ignore request)) "second"))
    (is (= 1 (length *handlers*)))))

(test server-status-tells-running-from-not
  (with-test-server ()
    (let ((status (server-status)))
      (is-true (getf status :running))
      (is (= *test-port* (getf status :port)))
      (is (equal "127.0.0.1" (getf status :address)))
      (is (not (null (getf status :started-at)))))
    ;; And the same answer is reachable as a registry entry at the read tier,
    ;; which is what makes it available over both protocols.
    (is-true (getf (invoke-operation (find-operation :server-status) '(:read) '())
                   :running)))
  (is-false (getf (server-status) :running))
  ;; The negative half of R7 is deliberately not a Lisp-level answer: a refused
  ;; TCP connection is how a client learns nothing is listening, and this is
  ;; the one place in this suite where a signalled condition is the expected
  ;; result rather than a failure.
  (signals error (http-call "/anything")))

(test starting-twice-is-refused-rather-than-leaked
  (with-test-server ()
    (let ((condition (handler-case (progn (start-server :port *test-port*) nil)
                       (error (c) c))))
      (is-true condition "a second acceptor started on a port already bound")
      (when condition
        (is (search (princ-to-string *test-port*) (princ-to-string condition))
            "the refusal does not name the running port: ~a" condition)))
    ;; The half that says "refused" rather than "leaked": the first acceptor is
    ;; still the one in *SERVER* and is still answering.
    (is (= 404 (nth-value 1 (http-call "/anything"))))))

(test serve-forever-does-not-reindex-what-the-caller-already-watched
  ;; BUG-0007, whose measured mechanism is here rather than in POLL-ONCE:
  ;; loom-serve.lisp's HEADLESS branch watches every path, starts the server,
  ;; and then hands the same paths to SERVE-FOREVER, which used to watch them
  ;; again -- and a second watch is a reindex, whose :indexed-at stamp lands
  ;; after the :started-at the staleness check compares it against.
  ;;
  ;; The clock tick is what makes the assertion mean anything: GET-UNIVERSAL-TIME
  ;; counts in whole seconds, so a reindex inside the same second writes an equal
  ;; value and EQL would hold either way. The same discipline
  ;; A-WRITE-ROUTE-CHANGES-WHAT-STATUS-REPORTS uses one system up.
  ;;
  ;; No port is bound anywhere here -- ALREADY-STARTED skips START-SERVER -- so
  ;; this cannot collide with a developer's own service or another test's
  ;; acceptor. *STOPPING* by SETF and not LET, for WITH-SAVED-HANDLERS' own
  ;; documented reason: the thread that reads it is not this one.
  (with-operations-fixture (repository)
    (let ((before (repository-indexed-at repository)))
      (loop while (<= (get-universal-time) before) do (sleep 0.05))
      (setf loom-serve::*stopping* nil)
      (let ((thread (bt:make-thread
                     (lambda ()
                       (serve-forever (list (namestring (repository-root repository)))
                                      :already-started t))
                     :name "serve-forever-test")))
        (sleep 1)
        (setf loom-serve::*stopping* t)
        (bt:join-thread thread))
      (is (eql before (repository-indexed-at repository))
          "serve-forever reindexed a repository its caller had already watched: ~a then ~a"
          before (repository-indexed-at repository)))))

(test stop-server-waits-for-an-in-flight-request-before-it-returns
  ;; The assertion is on the *ordering*, not on the response arriving, and the
  ;; difference is the whole value of this test. A hard stop does not kill
  ;; worker threads -- Hunchentoot's ONE-THREAD-PER-CONNECTION taskmaster only
  ;; joins the acceptor thread (taskmaster.lisp:349-352) and STOP closes only
  ;; the listening socket -- so "the slow request was answered" is true against
  ;; the undrained STOP-SERVER this replaces, and a test asserting that would
  ;; pass while testing nothing (CON-0003). What was false before the drain, and
  ;; is what a caller that exits the process next actually needs, is that the
  ;; handler had already finished by the time STOP-SERVER *returned*.
  ;;
  ;; Two flags rather than one: STARTED is what makes the stop concurrent with
  ;; the request at all. Without it the test can reach STOP-SERVER before the
  ;; worker has incremented ACCEPTOR-REQUESTS-IN-PROGRESS, leaving nothing to
  ;; drain and passing vacuously. Lexical variables and not specials, because
  ;; the thread that writes them is a Hunchentoot worker and a special bound
  ;; here would be invisible to it.
  (let ((started nil) (finished nil) (answer nil))
    (with-saved-handlers
      (setf *handlers* '())
      (register-handler :slow "/slow"
                        (lambda (request)
                          (declare (ignore request))
                          (setf (hunchentoot:content-type*) "application/json")
                          (setf started t)
                          (sleep 1.5)
                          (setf finished t)
                          (encode-result '(:slow t))))
      (stop-server)
      (start-server :port *test-port*)
      (unwind-protect
           (let ((caller (bt:make-thread (lambda () (setf answer (http-call "/slow")))
                                         :name "slow-request")))
             (loop until started do (sleep 0.01))
             (stop-server)
             (is-true finished
                      "stop-server returned while /slow was still in its handler")
             (bt:join-thread caller)
             (is (equal "{\"slow\":true}" answer)
                 "the drained request did not get its answer: ~a" answer))
        (stop-server)))))

(test a-drain-that-cannot-finish-is-bounded-rather-than-forever
  ;; This one does not fail against the code it replaces; it fails against the
  ;; wrong version of the drain -- the one that calls `:soft t' on the calling
  ;; thread and trusts it to return. Hunchentoot's soft stop waits on a bare
  ;; condition variable with no timeout (acceptor.lisp:319-336), so such an
  ;; implementation blocks for the handler's whole ten seconds and every
  ;; `tools/loom-serve.sh stop' inherits that. Its job is to hold the bound in
  ;; place, and its failure mode is a ten-second hang in this suite rather than
  ;; a red assertion -- stated so that is recognised rather than diagnosed.
  ;;
  ;; LET and not SETF, unlike the flags above: *STOP-DRAIN-TIMEOUT* is read by
  ;; DRAIN-AND-STOP on the thread that calls STOP-SERVER, which is this one.
  (let ((started nil))
    (with-saved-handlers
      (setf *handlers* '())
      (register-handler :stuck "/stuck"
                        (lambda (request)
                          (declare (ignore request))
                          (setf (hunchentoot:content-type*) "application/json")
                          (setf started t)
                          (sleep 10)
                          (encode-result '(:stuck t))))
      (stop-server)
      (start-server :port *test-port*)
      (unwind-protect
           (let ((loom-serve::*stop-drain-timeout* 0.5))
             (bt:make-thread (lambda () (ignore-errors (http-call "/stuck")))
                             :name "stuck-request")
             (loop until started do (sleep 0.01))
             (let* ((began (get-internal-real-time))
                    (status (stop-server))
                    (elapsed (/ (- (get-internal-real-time) began)
                                internal-time-units-per-second)))
               ;; Three seconds is generous against a 0.5s bound and still fails
               ;; an unbounded implementation by seven.
               (is (< elapsed 3)
                   "stop-server took ~,2fs, so the drain is not bounded" elapsed)
               (is-false (getf status :running))))
        (stop-server)))))

(test reload-code-is-not-an-operation-any-more
  ;; ARCH-0008 R1 asks for this by name. Its job is not to describe today's
  ;; registry but to make a future re-addition a deliberate act that turns a
  ;; test red, rather than a silent return of the mechanism BUG-0008 closed:
  ;; nothing else in this tree would notice, because loom-rest derives its
  ;; routes from the registry and would route it again without an edit.
  (is (null (find-operation :reload-code)))
  (is (notany (lambda (operation) (eq :reload-code (operation-name operation)))
              (all-operations))))
