;;;; Remembering that the embedder is not there.
;;;;
;;;; REQ-0048 R6 asks that Loom with no embedder behave exactly as Loom does
;;;; today. A timeout does not deliver that, only a bounded departure from it:
;;;; measured, a request to a port nothing listens on costs 30007 ms with one
;;;; conflated timeout and 2001 ms once the connect is separated from the read,
;;;; against a query that costs 0.01-0.09 s. Twenty times is not "exactly".
;;;;
;;;; So the first failure is remembered and the next call does not happen.

(in-package :loom-embed)

(defparameter *embedder-retry-after* 60
  "Seconds a remembered failure suppresses further calls.

A window rather than the process lifetime, and the choice is between two
inconveniences. The lifetime is simpler and never retries, so somebody who
starts ollama after Loom gets nothing until they restart the service -- which
they will read as Loom being broken. A window costs one connect probe a minute
while the embedder is genuinely absent, which against a 450-case run lasting
twelve seconds is one probe for the whole run.

Sixty because it is short enough that starting ollama feels like it worked and
long enough that the probe is not the query's cost.")

(defclass memoing-embedder ()
  ((inner :initarg :inner :reader memoing-embedder-inner)
   (failed-at :initform nil :accessor memoing-embedder-failed-at)
   (retry-after :initarg :retry-after :initform *embedder-retry-after*
                :reader memoing-embedder-retry-after)
   (suppressed :initform 0 :accessor memoing-embedder-suppressed))
  (:documentation
   "An embedder that stops asking once the one underneath has failed.

A decorator rather than a slot on OLLAMA-EMBEDDER, so that the behaviour can be
tested against a stand-in that fails on demand. A memo tested only against a
real absent ollama would be a test of the machine's configuration.

SUPPRESSED counts calls that never reached the inner embedder, which is what a
test asserts on: the point of a memo is the work it does not do, and a caller
comparing only results could not tell a memo from a fast failure."))

(defun make-memoing-embedder (inner &key (retry-after *embedder-retry-after*))
  (make-instance 'memoing-embedder :inner inner :retry-after retry-after))

(defmethod embedder-id ((embedder memoing-embedder))
  (embedder-id (memoing-embedder-inner embedder)))

(defmethod embedder-dimensions ((embedder memoing-embedder))
  (embedder-dimensions (memoing-embedder-inner embedder)))

(defun memo-fresh-p (embedder)
  "True when a remembered failure is still inside its window."
  (let ((failed-at (memoing-embedder-failed-at embedder)))
    (and failed-at
         (< (- (get-universal-time) failed-at)
            (memoing-embedder-retry-after embedder)))))

(defmethod embed-texts ((embedder memoing-embedder) texts)
  (when (memo-fresh-p embedder)
    (incf (memoing-embedder-suppressed embedder))
    (error 'embedder-unavailable
           :detail (format nil "~a was unavailable ~d seconds ago and is not being asked again"
                           (embedder-id embedder)
                           (- (get-universal-time)
                              (memoing-embedder-failed-at embedder)))))
  (handler-case
      (let ((vectors (embed-texts (memoing-embedder-inner embedder) texts)))
        ;; A success clears the memo. Somebody who starts ollama gets it back
        ;; on the first call after the window rather than on a restart.
        (setf (memoing-embedder-failed-at embedder) nil)
        vectors)
    (embedder-unavailable (condition)
      (setf (memoing-embedder-failed-at embedder) (get-universal-time))
      (error condition))))
