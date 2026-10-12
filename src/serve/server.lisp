;;;; The listener, and the seam that lets two systems share it without either
;;;; knowing about the other.
;;;;
;;;; DES-0006 says start-server "builds one Hunchentoot acceptor carrying both
;;;; loom-rest's routes and loom-mcp's single JSON-RPC endpoint", and also that
;;;; loom-serve depends on exactly the five systems loom-process depends on --
;;;; which excludes loom-rest and loom-mcp. Read literally those are circular:
;;;; a start-server that referenced loom-rest's routes would need #:loom-rest in
;;;; loom-serve.asd, which needs #:loom-serve, and ASDF would report the cycle
;;;; without reporting the sentence that caused it.
;;;;
;;;; The resolution, and the only one that keeps all three systems peers:
;;;; loom-serve owns the acceptor and a registration seam, and loom-rest and
;;;; loom-mcp each push their handlers onto it in a top-level form at load time.
;;;; The acceptor's dispatcher walks whatever is registered. The acceptor
;;;; therefore does carry both, exactly as DES-0006 says, without loom-serve
;;;; naming either -- and an image holding only loom-serve gets a listener that
;;;; answers 404 to everything, which is a coherent state and the one this
;;;; step's tests exercise.

(in-package :loom-serve)

(defclass loom-acceptor (hunchentoot:acceptor) ()
  (:documentation "The one acceptor, dispatching through *HANDLERS*.

A subclass of ACCEPTOR rather than the EASY-ACCEPTOR PLAN-0005 names, for a
reason that only became visible while writing it: easy-acceptor's added value
is HUNCHENTOOT:*DISPATCH-TABLE* and DEFINE-EASY-HANDLER, and *DISPATCH-TABLE*
is process-global. The registration seam below is exactly a per-service
replacement for that table, so using both would mean two dispatch mechanisms
for one listener and one of them shared with anything else in the image that
happened to start an easy-acceptor."))

;;;; ==================================================================
;;;; The registration seam
;;;; ==================================================================

(defstruct (service-handler (:conc-name service-handler-))
  "One registered handler: a name to replace it by, a path prefix to match,
and a function of the request returning the response body."
  (name nil)
  (prefix "/")
  (function nil :type (or null function)))

(defvar *handlers* '()
  "Registered handlers in registration order, which is the order they are
tried. First match wins, so a system registering a prefix that is a prefix of
another's takes both -- the two skins in this tree use disjoint prefixes and
this is stated here rather than enforced, because enforcing it would mean
loom-serve knowing what they are.")

(defun register-handler (name prefix function)
  "Register FUNCTION under NAME for paths beginning with PREFIX.

Replacing any entry of the same name, for DEFINE-COMMAND's reason: a system
reloaded in a live image must not end up with two of its handlers in the
table."
  (setf *handlers*
        (append (remove name *handlers* :key #'service-handler-name)
                (list (make-service-handler :name name :prefix prefix
                                            :function function))))
  name)

(defun find-handler (path)
  (find-if (lambda (handler)
             (let ((prefix (service-handler-prefix handler)))
               (and (<= (length prefix) (length path))
                    (string= prefix path :end2 (length prefix)))))
           *handlers*))

(defparameter *loopback-host-names* '("127.0.0.1" "localhost" "[::1]")
  "The three spellings of this machine that a caller of the listener sends.")

(defun loopback-host-p (host port)
  "True when HOST, a Host header value, names a loopback address on PORT.

DEC-0008. The service has no credential, so the only thing separating it from
a web page in the user's browser is that the page cannot choose the Host it
sends: DNS rebinding points an attacker's name at 127.0.0.1, and the request
then carries that name. The port is compared as well as the name: a Host
that names another port was written for another service.

The port may be left off only when PORT is 80, because that is the port a client
omits from Host (RFC 9110 7.2). Compared without regard to case, since host
names have none. NIL and the empty string are refused: a request with no Host
names nothing."
  (and (stringp host)
       (plusp (length host))
       (some (lambda (name)
               (or (string-equal host (format nil "~a:~d" name port))
                   (and (eql port 80) (string-equal host name))))
             *loopback-host-names*)))

(defun dispatch-request (request)
  "Answer REQUEST from *HANDLERS*, 404 when nothing matches, or 403 when its Host
is not a loopback name for this acceptor's port.

The Host check is first, so it covers REST, MCP and the 404 path alike and no
handler runs for a refused request (DEC-0008). Capability checking, which
comes later, is the wrong place: it resolves a caller's grants, and a request
from a rebound page is not a caller to resolve.

The 404 body is JSON rather than Hunchentoot's own HTML error page: every
caller of this service is a program, and an HTML page arriving where a JSON
object was expected is a decoding failure rather than a message."
  (let ((host (hunchentoot:host request))
        (port (hunchentoot:acceptor-port (hunchentoot:request-acceptor request)))
        (handler (find-handler (hunchentoot:script-name request))))
    (cond ((not (loopback-host-p host port))
           (setf (hunchentoot:return-code*) hunchentoot:+http-forbidden+
                 (hunchentoot:content-type*) "application/json")
           (encode-result
            (list :name "HOST-REFUSED"
                  :message (format nil "Host ~:[(none)~;~:*~s~] is not a loopback name for port ~d. Accepted: ~{~a:~d~^, ~}. See DEC-0008."
                                   host port
                                   (loop for name in *loopback-host-names*
                                         collect name collect port)))))
          (handler (funcall (service-handler-function handler) request))
          (t (setf (hunchentoot:return-code*) hunchentoot:+http-not-found+
                   (hunchentoot:content-type*) "application/json")
             (encode-result
              (list :name "UNKNOWN-OPERATION"
                    :message (format nil "No handler for ~a."
                                     (hunchentoot:script-name request))))))))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor loom-acceptor) request)
  (dispatch-request request))

;;;; ==================================================================
;;;; Lifecycle (R7)
;;;; ==================================================================

(defvar *server* nil
  "The running acceptor, or NIL.")

(defvar *server-started-at* nil)

(defparameter *default-port* 4780)

(defparameter *default-address* "127.0.0.1"
  "A requirement rather than an example, and DES-0006 gives the reason: R6's
credential story is deliberately unfinished, so a service listening on every
interface would be the one unsafe part of this design. A caller who wants it
reachable off-box passes an address explicitly; the default does not decide
that for them.")

(defun processor-count ()
  "How many processors the operating system reports online, or 1 when it cannot
be asked. sysconf's _SC_NPROCESSORS_ONLN, which is 84 on Linux and 58 on macOS.
A container's CPU quota is not seen, so a service limited by one reports the
host's count and takes `LOOM_MAX_THREADS' to correct it."
  (let ((name #+linux 84 #+darwin 58 #-(or linux darwin) nil))
    (or (and name
             (ignore-errors
              (let ((count (sb-alien:alien-funcall
                            (sb-alien:extern-alien "sysconf"
                                                   (function sb-alien:long sb-alien:int))
                            name)))
                (and (plusp count) count))))
        1)))

(defun default-max-thread-count ()
  "How many requests the service handles at once: twice the processors.
A request is CPU work, so more running at once than there are processors only
lengthens each one. On the 8 processor machine of BUG-0078, 24 clients got a
median of 1.28 s from semantic `context' at 18 requests a second, which is the
client count over the rate; a limit of 16 holds the queue to 16 requests and
refuses the rest. A connection holds a worker thread until its request is read
and answered, so a client that connects and sends nothing holds one for the read
timeout. BUG-0078."
  (* 2 (processor-count)))

(defun limit-from-environment (variable default)
  "The positive integer VARIABLE names, or DEFAULT when it is unset or empty.
A value that is not a positive integer is an error at startup rather than a
silent fallback: an operator who set a limit meant it."
  (let ((value (uiop:getenv variable)))
    (if (or (null value) (string= value ""))
        default
        (let ((number (ignore-errors (parse-integer value))))
          (unless (and number (plusp number))
            (error "~a is ~s; it must be a positive integer." variable value))
          number))))

(defun server-running-p ()
  (and *server* (hunchentoot:started-p *server*) t))

(defun start-server (&key (port *default-port*) (address *default-address*)
                       (max-threads (limit-from-environment
                                     "LOOM_MAX_THREADS" (default-max-thread-count)))
                       (max-accepts (limit-from-environment
                                     "LOOM_MAX_ACCEPT" (* 2 max-threads))))
  "Start the one acceptor. Returns SERVER-STATUS.

At most MAX-THREADS requests run at once and at most MAX-ACCEPTS connections are
open; the next connection is answered 503 and closed. MAX-THREADS is twice the
processors and MAX-ACCEPTS twice that. LOOM_MAX_THREADS and LOOM_MAX_ACCEPT set
them for the service. MAX-ACCEPTS must exceed MAX-THREADS."
  (unless (> max-accepts max-threads)
    (error "The accept limit ~d must be larger than the thread limit ~d."
           max-accepts max-threads))
  ;; Before the acceptor is built, not after: a second MAKE-INSTANCE followed
  ;; by a refusal would leave the first acceptor running and unreachable
  ;; through *SERVER*, which is the leak this refusal exists to prevent.
  (when (server-running-p)
    (error "A Loom service is already running on ~a:~d. Stop it first."
           (hunchentoot:acceptor-address *server*)
           (hunchentoot:acceptor-port *server*)))
  ;; REQ-0036 R9, DES-0030 D1. Read once at startup so --headless gets the
  ;; operator's switch too: the console entry point reads it in MAIN, and a
  ;; listener with no console has no MAIN to read it in.
  (configure-context-log-from-environment)
  (let ((acceptor (make-instance 'loom-acceptor
                                 :port port
                                 :address address
                                 :taskmaster (make-instance
                                              'hunchentoot:one-thread-per-connection-taskmaster
                                              :max-thread-count max-threads
                                              :max-accept-count max-accepts)
                                 ;; Hunchentoot's own logs go nowhere: this
                                 ;; system has its own log, and an access line
                                 ;; per request on *ERROR-OUTPUT* would bury it.
                                 :access-log-destination nil
                                 :message-log-destination nil)))
    (hunchentoot:start acceptor)
    (setf *server* acceptor
          *server-started-at* (get-universal-time))
    (server-status)))

(defparameter *stop-drain-timeout* 5
  "Seconds STOP-SERVER gives an in-flight request before it stops regardless.

Five and not ten, because two bounds have to fit inside a third: SERVE-FOREVER
stops every monitor before it calls STOP-SERVER and *MONITOR-STOP-TIMEOUT* is
10s, while tools/loom-serve.sh's `stop' gives up on the pidfile after ~20s. 10 +
5 leaves margin; 10 + 10 does not.

Internal rather than exported, matching WITH-REPOSITORY-LOCK's own precedent:
nothing outside this file has a reason to name it, and a test that wants a
shorter bound can bind it anyway.")

;;;; AWAIT-THREAD was defined here until REV-0002 A7. It is LOOM-UTILS\' now,
;;;; with this implementation rather than loom-workspace\'s polling one: the
;;;; #+SBCL branch below was this file\'s, and joining with a timeout is the
;;;; same answer as spinning on THREAD-ALIVE-P without the wakeups.
;;;;
;;;; BT:MAKE-THREAD on SBCL is SB-THREAD:MAKE-THREAD (bordeaux-threads
;;;; apiv1/impl-sbcl.lisp:19-20), so the thread it returns is one SB-THREAD can
;;;; join, which is what made the merge possible at all.

(defun drain-and-stop (acceptor &optional (timeout *stop-drain-timeout*))
  "Stop ACCEPTOR, giving an in-flight request up to TIMEOUT seconds to finish.

Hunchentoot's own `:soft t' (acceptor.lisp:319-336) is the drain: it sets
ACCEPTOR-SHUTDOWN-P so the accept loop takes no new connection, then waits for
ACCEPTOR-REQUESTS-IN-PROGRESS to reach zero before shutting the taskmaster down
and closing the listening socket. Two properties of that code, read there rather
than assumed, decide the shape of everything below.

It takes no timeout. The wait at 327-328 is a bare CONDITION-VARIABLE-WAIT with
no deadline argument, so the bound DES-0008 R3 requires cannot live inside the
primitive. That is why the soft stop runs on a thread of its own here: a caller
that ran it in-line and trusted it to return would turn every
`tools/loom-serve.sh stop' into an indefinite block the moment one request hung.

It waits once rather than in a loop, guarded by a single WHEN at 326. With two
or more overlapping requests the wait returns when the *first* one finishes
rather than the last, so `:soft t' is \"wait for an in-flight request\" and not
\"wait for all of them\". A residual DES-0008 records as accepted, not closed.

When the bound elapses the drain thread is still blocked on that condition
variable and nothing can wake it but a request completing, so it is left parked
and this thread performs the unconditional stop instead -- the same stop this
function replaced. The parked thread may wake later and run Hunchentoot's stop
tail against an already-closed socket, which is why IGNORE-ERRORS is inside its
body rather than wrapped around the spawn: the condition is raised there, long
after this function has returned."
  (let ((drain (bt:make-thread
                (lambda () (ignore-errors (hunchentoot:stop acceptor :soft t)))
                :name "loom-serve-drain")))
    (unless (await-thread drain timeout)
      (ignore-errors (hunchentoot:stop acceptor)))))

(defun stop-server ()
  "Stop the acceptor if one is running, draining first. Returns SERVER-STATUS."
  (when *server*
    (drain-and-stop *server*)
    (setf *server* nil
          *server-started-at* nil))
  (server-status))

(defun server-status ()
  "(:running :port :address :started-at).

The positive half of \"how a client tells running from nothing listening\": a
successful call to this, over either protocol, is the answer \"running\". The
negative half needs no Lisp-level mechanism, because a refused TCP connection
to the port already says it."
  (list :running (server-running-p)
        :port (and *server* (hunchentoot:acceptor-port *server*))
        :address (and *server* (hunchentoot:acceptor-address *server*))
        :started-at *server-started-at*))

(define-operation :server-status :read ()
    "Whether the service is running, and where."
  (server-status))

;;;; ==================================================================
;;;; Headless mode (R7's second lifecycle)
;;;; ==================================================================

;;;; The service log is LOOM-UTILS' *LOG*, since REV-0002 A1. It used to be its
;;;; own three lines here, and the docstring gave the reason: "That function
;;;; lives in the system this one may not depend on, and reaching for it is the
;;;; first of the three ways PLAN-0005 records that dependency arriving while
;;;; looking reasonable." The dependency the copy was avoiding still may not
;;;; exist -- what changed is that there is now a system below both peers to
;;;; hold it, so neither reaches for the other.
;;;;
;;;; One consequence is worth being plain about, because it is a behaviour
;;;; change rather than a move: the console and the service now share one log.
;;;; In the combined console-plus-listener process, `log' at the console prints
;;;; service events too, where before a request that errored inside Hunchentoot
;;;; was logged where nobody at that console could read it.

(defvar *stopping* nil
  "Set by the signal handler; read by SERVE-FOREVER's loop.")

(defun install-service-debugger-hook ()
  "Make sure no thread can block on a debugger prompt nobody can see.

LOOM-UTILS:INSTALL-DEBUGGER-HOOK with this system's prefix and this system's
unwind, which is the one respect the two callers differ in. loom-process passes
#\'ABORT, which assumes an ABORT restart exists. In a Hunchentoot worker thread
it may not, and a hook that assumed one would turn an unhandled condition into a
second, different error inside the handler for the first -- so the restart is
looked for and used when it is there, and otherwise the hook simply returns."
  (install-debugger-hook
   :prefix "loom-serve"
   :on-unwind (lambda (condition)
                (let ((restart (find-restart 'abort condition)))
                  (when restart (invoke-restart restart))))))

(defun install-signal-handlers ()
  "Ask SIGTERM and SIGINT to stop the service rather than kill the process.

The handler sets a flag and returns. Doing the shutdown here would run
STOP-SERVER and a monitor join inside a signal context, which is a place to do
as little as possible."
  #+sbcl
  (dolist (signal (list sb-unix:sigterm sb-unix:sigint))
    (sb-sys:enable-interrupt signal
                             (lambda (&rest ignored)
                               (declare (ignore ignored))
                               (setf *stopping* t)))))

(defun serve-sleep (seconds)
  "SLEEP for SECONDS, abandoned as soon as a stop is requested.

LOOM-UTILS:SLEEP-UNTIL with this system\'s stop flag. REV-0002 A7: this and
MONITOR-SLEEP were the same slice loop written twice, differing only in the
predicate. A single long SLEEP would make every stop request wait out the
interval for no reason, which for a service under a supervisor is the difference
between a clean stop and a kill."
  (sleep-until seconds (lambda () *stopping*)))

(defun serve-forever (paths &key (port *default-port*) (address *default-address*)
                                 already-started)
  "Watch PATHS, start the listener, and block until asked to stop.

HEADLESS mode. It does not call CONSOLE or MAIN at all, and that is the whole
reason it exists: MAIN's return path depends on CONSOLE reading EOF from
*STANDARD-INPUT*, so under a detached run with stdin closed or redirected from
/dev/null -- a supervisor, a background nohup, a container without a tty --
READ-LINE returns :EOF immediately, CONSOLE returns immediately, and the
process would exit within its first second taking the just-started listener
with it. R7 asks for the lifecycle to be explicit rather than assumed, and
\"something is always attached to stdin\" is exactly the assumption MAIN makes
safely today and would make unsafely here.

ALREADY-STARTED skips the START-SERVER call below, for DES-0007's fifth
PROBLEM finding. A caller that must write a pidfile only once the bind has
actually succeeded needs a seam between START-SERVER returning and the blocking
loop beginning, and this body has none; calling START-SERVER itself to get that
seam would make the call below fail against START-SERVER's own re-entrant guard
-- \"a Loom service is already running\", correct for that guard and exactly
wrong for a caller that started the first acceptor on purpose one line earlier.
NIL is both the default and the meaning of every line here before this keyword
existed, so a caller that omits it gets what it always got. It now also skips
the watch loop below, because it means the caller has already watched PATHS as
well as started the listener -- which is what loom-serve.lisp's HEADLESS branch
has always done -- and WATCH-REPOSITORY on an already-registered root reindexes
it (workspace.lisp:428-431), which stamps :indexed-at with the moment that
second index finished. Done after START-SERVER has recorded :started-at, that
stamp lands past it whenever the index crosses a whole-second boundary, and
tools/loom-serve.sh's `indexed > started' test then reports a brand-new process
as running stale code over a tree nothing has touched. BUG-0007."
  (setf *stopping* nil)
  (install-service-debugger-hook)
  (unless already-started
    (dolist (path paths)
      (handler-case
          (let ((repository (watch-repository path :quiet t)))
            (log-event "watch" "~a" (repository-root repository)))
        (guarded-condition (condition)
          (log-event "error" "watch ~a: ~a" path condition)
          (format *error-output* "~&[loom-serve] cannot watch ~a: ~a~%" path condition)))))
  ;; The log line survives the skip: HEADLESS's own log is the only record of
  ;; which roots this process ended up watching, and the caller that did the
  ;; watching has no log to write it to.
  (when already-started
    (dolist (repository (all-repositories))
      (log-event "watch" "~a" (repository-root repository))))
  (unless already-started
    (start-server :port port :address address))
  (install-signal-handlers)
  (log-event "start" "listening on ~a:~d" address port)
  (format t "~&Loom service on ~a:~d. ~d repositor~:@p watched. SIGTERM to stop.~%"
          address port (length (all-repositories)))
  (finish-output)
  (loop until *stopping* do (serve-sleep 1))
  ;; The same shutdown MAIN performs, minus the console: pause every
  ;; repository, keeping its index, then stop listening. DEC-0004's
  ;; distinction is what makes pausing rather than unwatching right here.
  (dolist (repository (all-repositories)) (stop-monitor repository))
  (stop-server)
  (log-event "stop" "stopped")
  (format t "~&Paused ~d repositor~:@p; stopped listening.~%" (length (all-repositories)))
  (finish-output)
  (values))
