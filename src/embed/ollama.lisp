;;;; The local implementation: ollama's embedding endpoint over HTTP.
;;;;
;;;; DEC-0006's measured configuration. nomic-embed-text is 274 MB, answers a
;;;; single query in 31 ms median over twenty calls, and embedded 6976
;;;; definitions in 622 seconds at about 12 a second.

(in-package :loom-embed)

(defparameter *ollama-default-host* "127.0.0.1:11434"
  "Where ollama listens by default.

Loopback rather than a hostname, and not configurable through the environment
here. An embedder reachable over a network is a different decision from an
embedder running beside the process -- it changes what leaves the machine, and
DEC-0006 chose local partly on that. A hosted embedder gets its own class.")

(defparameter *ollama-default-model* "nomic-embed-text"
  "The model DEC-0006 measured. Changing it changes EMBEDDER-ID, which
invalidates every sidecar built with the old one -- which is the intended
behaviour and not a hazard to work around.")

;; Without this drakma hands back octets for an application/json body and every
;; caller decodes them itself. Pushed once, at load, because it is a property of
;; what this file talks to rather than of any one request.
(eval-when (:load-toplevel :execute)
  (pushnew '("application" . "json") drakma:*text-content-types* :test #'equal))

(defparameter *ollama-connect-timeout* 2
  "Seconds to wait for a preflight TCP connect, and for that only.

Two, not the thirty this was written as first. A loopback connection either
completes in a millisecond or is never going to, and the number here is paid in
full on every query when ollama is not installed -- which REQ-0048 R6 says must
cost what it costs today. Measured before the split: a request to a port
nothing listens on took 30007 ms, so `context\' on a machine without ollama
would have taken thirty seconds a call rather than the 0.09 s it takes now.

The reasoning that produced thirty was about a different failure. An embedder
that is installed, listening and slow is a read problem; an embedder that is
absent is a connect problem.

Passing this to drakma is what the first attempt did, and it is wrong for a
reason the batch build found: drakma hands CONNECTION-TIMEOUT to usocket, which
applies it to reads as well, so a two-second connect bound is also a two-second
read bound. Three texts embed in 250 ms and pass; sixty-four take longer than
that and the request died with an I/O timeout on a perfectly healthy ollama.

So the short number is spent on REACHABLE-P below, against a socket that is
opened and closed, and the request itself is given the deadline. Each number
now bounds one thing.")

(defparameter *ollama-deadline* 60
  "Seconds for the whole call, connect and read together.

drakma\'s CONNECTION-TIMEOUT bounds the connect and nothing bounds the read, so
an ollama that accepts a socket and then says nothing would hang the caller for
as long as it stayed quiet. SB-SYS:WITH-DEADLINE is what bounds it, and this is
its argument.

Sixty because it covers a batch. The sidecar builder sends 64 texts at a time
and 6976 definitions took 622 seconds in total, so a batch is seconds rather
than milliseconds; a single query is 31 ms median and nowhere near this. Passed
per call rather than read from here by the seeder, which wants a much smaller
number than the builder does.

SB-SYS is SBCL\'s. DES-0007\'s CONSEQUENCES already names this implementation
and this platform as a boundary rather than a portability promise, and reading
/proc in loom-serve.sh is the same call made once before.")

(defclass ollama-embedder ()
  ((host  :initarg :host  :reader ollama-host  :initform *ollama-default-host*)
   (model :initarg :model :reader ollama-model :initform *ollama-default-model*)
   (dimensions :initarg :dimensions :initform nil :accessor ollama-dimensions))
  (:documentation
   "An embedder backed by a local ollama process.

DIMENSIONS starts NIL and is filled from the first reply rather than declared.
The width is a property of whichever model was pulled, and a number written
here from the documentation would be a claim about a file nobody checked."))

(defun make-ollama-embedder (&key (host *ollama-default-host*)
                                  (model *ollama-default-model*))
  (make-instance 'ollama-embedder :host host :model model))

(defmethod embedder-id ((embedder ollama-embedder))
  (concatenate 'string "ollama:" (ollama-model embedder)))

(defmethod embedder-dimensions ((embedder ollama-embedder))
  (ollama-dimensions embedder))

(defun ollama-url (embedder)
  (concatenate 'string "http://" (ollama-host embedder) "/api/embed"))

(defun reachable-p (host-and-port timeout)
  "True when a TCP connect to HOST-AND-PORT completes within TIMEOUT seconds.

The whole of the absent-embedder check, and separate from the request because
the two failures want opposite numbers. A loopback connect completes in under a
millisecond or is never going to, so this is cheap when ollama is up and fast
when it is not -- and it leaves the request free to take as long as embedding
sixty-four texts actually takes.

The socket is closed immediately. What is being asked is whether anything is
listening, not anything about what it would say."
  (let* ((colon (position #\: host-and-port :from-end t))
         (host (if colon (subseq host-and-port 0 colon) host-and-port))
         (port (if colon (parse-integer (subseq host-and-port (1+ colon))
                                        :junk-allowed t)
                   80)))
    (handler-case
        (let ((socket (usocket:socket-connect host port :timeout timeout)))
          (usocket:socket-close socket)
          t)
      (serious-condition () nil))))

(defun post-json (url payload deadline)
  "POST PAYLOAD as JSON to URL and return the decoded reply.

Every failure this can have becomes EMBEDDER-UNAVAILABLE. A refused
connection, a timeout, a 404 from an ollama too old for /api/embed, a body that
is not JSON -- the caller's response to all of them is the same, and REQ-0048
R6 says what it is."
  (handler-case
      (multiple-value-bind (body status)
          (sb-sys:with-deadline (:seconds deadline)
            (drakma:http-request url
                                 :method :post
                                 :content-type "application/json"
                                 :content payload
                                 ;; The deadline, not the connect bound: usocket
                                 ;; applies this to reads too, and a batch of
                                 ;; sixty-four takes longer than a connect ever
                                 ;; should. REACHABLE-P is what fails fast.
                                 :connection-timeout deadline
                                 :want-stream nil))
        (let ((text (if (stringp body)
                        body
                        (babel:octets-to-string body :encoding :utf-8))))
          (unless (and (integerp status) (<= 200 status 299))
            (error 'embedder-unavailable
                   :detail (format nil "HTTP ~a from ~a" status url)))
          (handler-case (json:decode-json-from-string text)
            (error (condition)
              (error 'embedder-unavailable
                     :detail (format nil "reply from ~a was not JSON: ~a"
                                     url condition))))))
    (embedder-unavailable (condition) (error condition))
    ;; SERIOUS-CONDITION rather than ERROR: usocket and drakma both signal
    ;; conditions that are not ERROR subtypes on some failures, which is
    ;; RULE-0004's whole subject, and SB-SYS:DEADLINE-TIMEOUT is a third. The
    ;; smoke run against a dead port arrived here as USOCKET:TIMEOUT.
    (serious-condition (condition)
      (error 'embedder-unavailable
             :detail (format nil "~a: ~a" url condition)))))

(defun reply-embeddings (reply url)
  "The :EMBEDDINGS list of a decoded ollama reply.

Checked rather than assumed. An ollama that answered with an error object, or
an endpoint that is not ollama at all, decodes to a perfectly good alist with
no embeddings in it, and a caller that took NIL for `no vectors' would write an
empty sidecar and report success."
  (let ((embeddings (cdr (assoc :embeddings reply))))
    (unless (and (listp embeddings) embeddings)
      (error 'embedder-unavailable
             :detail (format nil "no embeddings in the reply from ~a" url)))
    embeddings))

(defmethod embed-texts ((embedder ollama-embedder) texts)
  (let ((texts (coerce texts 'list)))
    (if (null texts)
        ;; An empty request is answered without a call. Asking ollama to embed
        ;; nothing is a round trip for a result already known, and the sidecar
        ;; builder's last batch is empty whenever the count divides evenly.
        (make-array 0)
        (progn
          (unless (reachable-p (ollama-host embedder) *ollama-connect-timeout*)
            (error 'embedder-unavailable
                   :detail (format nil "nothing listening on ~a" (ollama-host embedder))))
          (let* ((url (ollama-url embedder))
               (payload (json:encode-json-to-string
                         `(("model" . ,(ollama-model embedder))
                           ("input" . ,texts))))
               (reply (post-json url payload *ollama-deadline*))
               (embeddings (reply-embeddings reply url)))
          (unless (= (length embeddings) (length texts))
            (error 'embedder-unavailable
                   :detail (format nil "asked ~a for ~d texts and got ~d vectors"
                                   url (length texts) (length embeddings))))
          (let ((vectors (map 'simple-vector #'normalise embeddings)))
            ;; Recorded from the first reply rather than declared. See the
            ;; class docstring.
            (when (and (plusp (length vectors))
                       (null (ollama-dimensions embedder)))
              (setf (ollama-dimensions embedder) (length (aref vectors 0))))
            vectors))))))
