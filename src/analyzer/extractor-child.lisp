;;;; The long-lived extractor child, shared by every analyzer that parses in
;;;; another language's own interpreter -- DES-0053 R14.
;;;;
;;;; REQ-0024 wrote this as js-analyzer.lisp's private machinery: launch, lock,
;;;; one retry, a timeout, a recorded absence. The Python analyzer needs the
;;;; same hundred and twenty lines with a different program and a different
;;;; script, and two copies of a process lifecycle drift (REV-0002 counted 22
;;;; duplications of that kind). So the lifecycle lives here, once, and an
;;;; analyzer builds one instance that says only what is its own: the child's
;;;; name, how to spell its command line, and how long to wait.
;;;;
;;;; The command line and the timeout are functions, called at each launch and
;;;; each exchange, not values captured when the instance is built. The
;;;; JavaScript tests let-bind *NODE-PROGRAM* to a name that cannot be found and
;;;; expect the next launch to fail; a string captured at load time would make
;;;; that binding do nothing.
;;;;
;;;; The protocol is tools/js/extract.js's and tools/py/extract.py's, and is
;;;; the same in both: one request frame, `<path>\n<byte-length>\n<source>`,
;;;; answered by one line of JSON. The process handle is a cache of a resource
;;;; and not per-repository knowledge, so one instance still serves every
;;;; repository -- js-analyzer.lisp's header gives the argument.

(in-package :loom-analyzer)

(defstruct (extractor-child (:conc-name child-))
  "One extractor process and everything needed to launch it again."
  (name "" :type string)
  ;; Called at each launch. NIL elements are not expected.
  (argv-function nil :type (or null function))
  ;; Called at each exchange; returns seconds.
  (timeout-function nil :type (or null function))
  (process nil)
  ;; Serialises both the exchange and the lifecycle. Two threads writing frames
  ;; into one stdin would interleave their bodies, and neither could tell which
  ;; reply was its own.
  (lock (bt:make-lock "loom-extractor"))
  ;; Why the toolchain could not be started, or NIL. A missing toolchain is a
  ;; recorded absence and not a failure (REQ-0018 R2): every file becomes a
  ;; :FILE entity carrying this string.
  (unavailable-reason nil))

(defmacro with-timeout-or-nil ((seconds) &body body)
  "BODY's value, or NIL if it took longer than SECONDS.

SB-EXT:WITH-TIMEOUT signals rather than returning, and the caller wants the
distinction between `no answer' and `an answer' rather than a condition to
re-handle. On an implementation without it the body simply runs unbounded,
which is worse than a timeout and better than not compiling.

Defined above its one caller because a macro used before it is defined is
expanded as a function call, and the timeout would silently not exist."
  #+sbcl `(handler-case (sb-ext:with-timeout ,seconds ,@body)
            (sb-ext:timeout () nil))
  #-sbcl `(progn ,seconds ,@body))

(defun utf8-byte-length (string)
  "How many bytes STRING occupies as UTF-8.

The frame header counts bytes and the stream is character-oriented, so this is
the one number the two ends have to agree on: a file with any non-ASCII in it
makes the character count and the byte count different, and a wrong header
would desynchronise every frame after it rather than just this one."
  #+sbcl (length (sb-ext:string-to-octets string :external-format :utf-8))
  #-sbcl (loop for character across string
               sum (let ((code (char-code character)))
                     (cond ((< code #x80) 1) ((< code #x800) 2)
                           ((< code #x10000) 3) (t 4)))))

(defun write-frame (process path contents)
  "Write one length-prefixed request. See tools/js/extract.js for the frame."
  (let ((stream (uiop:process-info-input process)))
    (format stream "~a~%~d~%" path (utf8-byte-length contents))
    (write-string contents stream)
    (finish-output stream)))

(defun read-reply (process)
  "One line of JSON from the child, decoded. NIL if the stream closed."
  (let ((line (read-line (uiop:process-info-output process) nil nil)))
    (when line
      (json:decode-json-from-string line))))

(defun child-alive-p (child)
  (let ((process (child-process child)))
    (and process (uiop:process-alive-p process))))

(defun start-extractor-child (child)
  "Launch CHILD's extractor, or record why it could not be launched. Returns the
process or NIL."
  (let ((argv nil))
    (handler-case
        (let ((process (uiop:launch-program
                        (setf argv (funcall (child-argv-function child)))
                        :input :stream :output :stream :error-output nil)))
          (setf (child-unavailable-reason child) nil)
          (setf (child-process child) process))
      (error (condition)
        ;; No interpreter on PATH is the ordinary case here and must not
        ;; signal: a developer indexing a mixed tree on a machine without one
        ;; gets their other answers and a note about this language.
        (setf (child-process child) nil)
        (setf (child-unavailable-reason child)
              (format nil "cannot run ~a: ~a" (first argv) condition))
        nil))))

(defun ensure-extractor-child (child)
  "The live process, starting it if necessary. NIL when the toolchain is absent.

Called with CHILD's lock held."
  (unless (child-alive-p child)
    (when (child-process child)
      ;; A child that died mid-tree leaves its stdin buffered and its reply
      ;; stream half-read. Close before relaunching so the next exchange starts
      ;; from a clean pair of streams rather than inheriting a partial frame.
      (ignore-errors (uiop:close-streams (child-process child)))
      (setf (child-process child) nil))
    (start-extractor-child child))
  (child-process child))

(defun stop-extractor-child (child)
  "Shut CHILD's extractor down. Safe to call when none is running.

Nothing in the indexing path calls this -- the child is meant to outlive a
tree pass -- but a test that has just proved the restart behaviour needs to put
the world back, and a long-lived service reindexing a tree that no longer has
any such file in it should not keep an interpreter alive forever."
  (bt:with-lock-held ((child-lock child))
    (when (child-process child)
      (ignore-errors (uiop:close-streams (child-process child)))
      (ignore-errors (uiop:terminate-process (child-process child) :urgent t))
      (setf (child-process child) nil))))

(defun exchange-with-child (child path contents)
  "Two values: the child's decoded reply for PATH, and a reason string when
there is none.

One retry, and only one, and only for a child that was not alive. A parse that
fails is the child's business to report in its reply and is not retried; a
child that has *died* is a different thing, and the next file after it should
not be lost to a process that is already gone. Retrying more than once would
turn an interpreter that cannot start into a loop across every file in the
tree."
  (bt:with-lock-held ((child-lock child))
    (loop for attempt from 0 below 2
          for process = (ensure-extractor-child child)
          do (unless process
               (return (values nil (child-unavailable-reason child))))
             (handler-case
                 (let ((reply (with-timeout-or-nil ((funcall (child-timeout-function child)))
                                (write-frame process path contents)
                                (read-reply process))))
                   (if reply
                       (return (values reply nil))
                       ;; No reply: the child died, or took too long. Drop it so
                       ;; ENSURE-EXTRACTOR-CHILD relaunches on the next pass, and
                       ;; let the loop have its one retry.
                       (progn
                         (ignore-errors (uiop:close-streams process))
                         (ignore-errors (uiop:terminate-process process :urgent t))
                         (setf (child-process child) nil)
                         (when (= attempt 1)
                           (return (values nil (format nil "~a extractor stopped responding"
                                                       (child-name child))))))))
               (error (condition)
                 (ignore-errors (uiop:close-streams process))
                 (setf (child-process child) nil)
                 (when (= attempt 1)
                   (return (values nil (princ-to-string condition)))))))))
