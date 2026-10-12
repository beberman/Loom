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

(defun free-port ()
  "A port nothing is listening on, found by asking the kernel for one.

Bind to port 0, read back the port it assigned, and close. The port can be taken
between the close and the test that wants it; that window is microseconds, where
a literal port was taken for the whole of any run that overlapped another."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defparameter *test-port* (free-port)
  "Not 4780, which a developer's own running service holds, and not a literal
either: two suites running at once, or one beside a stale image, shared 47180
and the second failed four tests with ADDRESS-IN-USE-ERROR. Chosen when this
file loads, so every test in one run uses the same port.")

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
  ;; DES-0008 R1 asks for this by name. Its job is not to describe today's
  ;; registry but to make a future re-addition a deliberate act that turns a
  ;; test red, rather than a silent return of the mechanism BUG-0008 closed:
  ;; nothing else in this tree would notice, because loom-rest derives its
  ;; routes from the registry and would route it again without an edit.
  (is (null (find-operation :reload-code)))
  (is (notany (lambda (operation) (eq :reload-code (operation-name operation)))
              (all-operations))))

;;; ------------------------------------------------------------------
;;; The Host check (DEC-0008)
;;;
;;; DRAKMA writes its own Host header, so HTTP-CALL cannot send a wrong one or
;;; none. RAW-STATUS speaks HTTP/1.1 over a socket and writes exactly the Host
;;; it is given. HTTP-CALL's own requests carry `Host: 127.0.0.1:<*test-port*>', which
;;; the check accepts, and that is why the rest of this system's tests and the
;;; loom-rest and loom-mcp suites need no edit.

(defun raw-status (path host &key (method "GET") body)
  "Send one HTTP/1.1 request to the test server with exactly HOST as its Host
header, or no Host header when HOST is NIL. Returns (values status body), or
NIL for both when nothing answers within five seconds."
  (let ((socket (usocket:socket-connect "127.0.0.1" *test-port*
                                        :element-type 'character)))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket)))
           (format stream "~a ~a HTTP/1.1~c~c" method path #\Return #\Newline)
           (when host (format stream "Host: ~a~c~c" host #\Return #\Newline))
           (when body
             (format stream "Content-Type: application/json~c~c" #\Return #\Newline)
             (format stream "Content-Length: ~d~c~c" (length body) #\Return #\Newline))
           (format stream "Connection: close~c~c~c~c" #\Return #\Newline #\Return #\Newline)
           (when body (write-string body stream))
           (finish-output stream)
           (when (usocket:wait-for-input socket :timeout 5 :ready-only t)
             (let* ((text (with-output-to-string (out)
                            (loop for char = (read-char stream nil nil)
                                  while char do (write-char char out))))
                    (status-end (position #\Space text :start 9))
                    (body-start (search (format nil "~c~c~c~c" #\Return #\Newline
                                                #\Return #\Newline)
                                        text)))
               (values (parse-integer text :start 9 :end status-end)
                       (if body-start (subseq text (+ body-start 4)) "")))))
      (usocket:socket-close socket))))

(defmacro with-fixture-routes ((ran) &body body)
  "Register the two paths the real routes occupy, /v1/status and /mcp, as
fixtures that count their calls in RAN, and run BODY in a test server.

loom-serve's own suite has no loom-rest or loom-mcp in the image, so the paths
are stood in for here. That a refused request reaches neither handler is the
property under test; the real handlers are reached by the curl in PLAN-0061
step 4's exit. RAN is a cons cell mutated with INCF, for
WITH-SAVED-HANDLERS' reason: the handler runs on another thread."
  `(with-saved-handlers
     (setf *handlers* '())
     (register-handler :fixture-status "/v1/status"
                       (lambda (request)
                         (declare (ignore request))
                         (incf (car ,ran))
                         (setf (hunchentoot:content-type*) "application/json")
                         (encode-result '(:status "ok"))))
     (register-handler :fixture-mcp "/mcp"
                       (lambda (request)
                         (declare (ignore request))
                         (incf (car ,ran))
                         (setf (hunchentoot:content-type*) "application/json")
                         (encode-result '(:jsonrpc "2.0" :id 1 :result ()))))
     (with-test-server () ,@body)))

(defun host-on-test-port (name)
  (format nil "~a:~d" name *test-port*))

(test loopback-host-p-accepts-the-three-names-on-the-listeners-port
  (dolist (name '("127.0.0.1" "localhost" "LOCALHOST" "Localhost" "[::1]"))
    (is-true (loom-serve::loopback-host-p (format nil "~a:4780" name) 4780)
             "~a:4780 refused on port 4780" name))
  (is-false (loom-serve::loopback-host-p "127.0.0.1:9999" 4780) "wrong port")
  (is-false (loom-serve::loopback-host-p "evil.example:4780" 4780) "right port, wrong name")
  (is-false (loom-serve::loopback-host-p "127.0.0.1.evil.example:4780" 4780)
            "a loopback name as the front of another name")
  (is-false (loom-serve::loopback-host-p "evil.example" 80))
  (is-false (loom-serve::loopback-host-p "[::1" 4780))
  (is-false (loom-serve::loopback-host-p nil 4780) "no Host header")
  (is-false (loom-serve::loopback-host-p "" 4780) "empty Host header"))

(test loopback-host-p-leaves-the-port-off-only-for-port-80
  (is-true (loom-serve::loopback-host-p "localhost" 80))
  (is-true (loom-serve::loopback-host-p "127.0.0.1" 80))
  (is-true (loom-serve::loopback-host-p "[::1]" 80))
  (is-true (loom-serve::loopback-host-p "localhost:80" 80))
  (is-false (loom-serve::loopback-host-p "localhost" 4780)
            "a bare name was accepted on a listener that is not on port 80")
  (is-false (loom-serve::loopback-host-p "localhost" 8080)))

(test a-host-that-is-not-loopback-is-refused-before-any-handler-runs
  (let ((ran (list 0)))
    (with-fixture-routes (ran)
      (multiple-value-bind (status body) (raw-status "/v1/status" "evil.example")
        (is (eql 403 status))
        (is (search "HOST-REFUSED" body) "403 without the HOST-REFUSED name: ~a" body)
        (is (search "evil.example" body) "the refusal does not name the Host received: ~a" body)
        (is (search "DEC-0008" body) "the refusal does not cite its decision: ~a" body)
        (is (search (host-on-test-port "localhost") body)
            "the refusal does not list the names accepted: ~a" body))
      ;; The rebinding shape: the attacker's name on the listener's own port.
      (is (eql 403 (raw-status "/v1/status" (host-on-test-port "evil.example"))))
      (is (eql 403 (raw-status "/nothing-registered" (host-on-test-port "evil.example")))
          "the 404 path answered a rebound Host with 404 rather than 403")
      (is (eql 403 (raw-status "/v1/status" "127.0.0.1:9999")) "wrong port")
      (is (eql 0 (car ran)) "a handler ran for a refused request ~d times" (car ran)))))

(test a-rebound-host-on-the-mcp-endpoint-never-reaches-the-json-rpc-handler
  (let ((ran (list 0)))
    (with-fixture-routes (ran)
      (multiple-value-bind (status body)
          (raw-status "/mcp" (host-on-test-port "evil.example") :method "POST"
                      :body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")
        (is (eql 403 status))
        (is (null (search "jsonrpc" body)) "the MCP handler's answer came back: ~a" body))
      (is (eql 0 (car ran))))))

(test a-request-with-no-host-header-reaches-no-handler
  (let ((ran (list 0)))
    (with-fixture-routes (ran)
      (is (member (raw-status "/v1/status" nil) '(400 403)))
      (is (eql 0 (car ran))))))

(test the-loopback-spellings-of-the-listener-are-answered
  (let ((ran (list 0)))
    (with-fixture-routes (ran)
      (dolist (name '("127.0.0.1" "localhost" "LOCALHOST" "[::1]"))
        (multiple-value-bind (status body)
            (raw-status "/v1/status" (host-on-test-port name))
          (is (eql 200 status) "~a answered ~a" name status)
          (is (search "ok" body))))
      (is (eql 4 (car ran))))))

;;;; BUG-0078: the service named no connection limit. Hunchentoot's defaults
;;;; applied without a line of Loom saying so, and nothing showed what a client
;;;; that holds connections open does to the others.

(defmacro with-limited-test-server ((threads accepts) &body body)
  `(progn
     (stop-server)
     (start-server :port *test-port* :max-threads ,threads :max-accepts ,accepts)
     (unwind-protect (progn ,@body)
       (stop-server))))

(test the-limits-reach-the-taskmaster
  (with-limited-test-server (3 5)
    (let ((taskmaster (hunchentoot::acceptor-taskmaster *server*)))
      (is (eql 3 (hunchentoot:taskmaster-max-thread-count taskmaster)))
      (is (eql 5 (hunchentoot:taskmaster-max-accept-count taskmaster))))))

(test an-accept-limit-no-larger-than-the-thread-limit-is-refused
  (stop-server)
  (signals error (start-server :port *test-port* :max-threads 4 :max-accepts 4))
  (is-false (server-running-p)))

(test a-limit-the-environment-names-must-be-a-positive-integer
  ;; PATH is set in every environment this suite runs in, and is not a number.
  (signals error (loom-serve::limit-from-environment "PATH" 7))
  (is (eql 7 (loom-serve::limit-from-environment "LOOM_NO_SUCH_LIMIT_VARIABLE" 7))))

(test connections-past-the-accept-limit-are-answered-503-and-served-again-after
  (with-limited-test-server (2 3)
    (let ((held (loop repeat 3
                      collect (usocket:socket-connect "127.0.0.1" *test-port*
                                                      :element-type 'character))))
      (unwind-protect
           (progn
             ;; Headers never finished, so each holds its worker thread.
             (dolist (socket held)
               (format (usocket:socket-stream socket) "GET /v1/status HTTP/1.1~c~c"
                       #\Return #\Newline)
               (finish-output (usocket:socket-stream socket)))
             (sleep 0.5)
             (is (eql 503 (nth-value 1 (http-call "/anything")))
                 "a fourth connection past an accept limit of three was not refused"))
        (dolist (socket held) (usocket:socket-close socket)))
      (sleep 0.5)
      (is (eql 404 (nth-value 1 (http-call "/anything")))
          "the service did not answer again after the held connections closed"))))

(test the-default-limits-follow-the-processor-count
  ;; BUG-0078. A fixed 100 let 100 CPU-bound requests queue behind each other;
  ;; the limit is twice the processors and nothing waits for a thread.
  (let ((processors (loom-serve::processor-count)))
    (is (plusp processors))
    (is (eql (* 2 processors) (loom-serve::default-max-thread-count)))
    (stop-server)
    (start-server :port *test-port*)
    (unwind-protect
         (let ((taskmaster (hunchentoot::acceptor-taskmaster *server*)))
           (is (eql (* 2 processors) (hunchentoot:taskmaster-max-thread-count taskmaster)))
           (is (null (hunchentoot:taskmaster-max-accept-count taskmaster))
               "the default left a queue for connections that find no free thread"))
      (stop-server))))

(test with-no-accept-limit-a-connection-past-the-thread-limit-is-refused-at-once
  (stop-server)
  (start-server :port *test-port* :max-threads 2)
  (let ((held (loop repeat 2
                    collect (usocket:socket-connect "127.0.0.1" *test-port*
                                                    :element-type 'character))))
    (unwind-protect
         (progn
           (dolist (socket held)
             (format (usocket:socket-stream socket) "GET /v1/status HTTP/1.1~c~c"
                     #\Return #\Newline)
             (finish-output (usocket:socket-stream socket)))
           (sleep 0.5)
           (let ((started (get-internal-real-time)))
             (is (eql 503 (nth-value 1 (http-call "/anything")))
                 "a third connection against two threads was not refused")
             (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 2)
                 "the refusal waited for a thread")))
      (dolist (socket held) (usocket:socket-close socket))
      (sleep 0.5)
      (is (eql 404 (nth-value 1 (http-call "/anything"))))
      (stop-server))))

(test an-idle-keep-alive-connection-does-not-hold-a-thread
  ;; BUG-0078. Hunchentoot keeps a worker thread on a persistent connection while
  ;; the client is idle. With 16 threads, 16 clients that each made one request
  ;; and went quiet refused every other request, for longer than the read
  ;; timeout. A thread limit must count requests in flight, so the service
  ;; answers Connection: close.
  (stop-server)
  (start-server :port *test-port* :max-threads 2)
  (let ((held '()))
    (unwind-protect
         (progn
           (dotimes (i 2)
             (let ((socket (usocket:socket-connect "127.0.0.1" *test-port*
                                                   :element-type 'character)))
               (push socket held)
               (let ((stream (usocket:socket-stream socket)))
                 (format stream "GET /anything HTTP/1.1~c~cHost: 127.0.0.1:~d~c~cConnection: keep-alive~c~c~c~c"
                         #\Return #\Newline *test-port* #\Return #\Newline
                         #\Return #\Newline #\Return #\Newline)
                 (finish-output stream)
                 (usocket:wait-for-input socket :timeout 5)
                 (loop while (listen stream) do (read-char stream)))))
           (sleep 0.5)
           (is (eql 404 (nth-value 1 (http-call "/anything")))
               "two idle keep-alive connections took both threads"))
      (dolist (socket held) (usocket:socket-close socket))
      (stop-server))))
