;;;; The HTTP surface: one path per registry entry, one shape for all of them.
;;;;
;;;; Every route does exactly the five steps ARCH-0006 commits to and nothing
;;;; else: decode the request into the arguments the entry wants, resolve the
;;;; caller's grants from the Authorization header, invoke the operation (which
;;;; checks the tier and guards the condition), encode the result, and set the
;;;; HTTP status. Because that shape is identical for every entry, the table is
;;;; the registry itself rather than a second list beside it. REQ-0008 excludes
;;;; the exact route table and ARCH-0006 commits only to the shape every route
;;;; shares, so deriving the paths from the registry is within the design and
;;;; removes the failure a hand-maintained table has: an operation added
;;;; without a route.
;;;;
;;;; The method rule is the one piece of HTTP opinion here. Read-tier entries
;;;; answer GET (and POST, for a caller that would rather send a body); write-
;;;; and repl-tier entries require POST. A GET that reindexes a repository is
;;;; the kind of thing a browser prefetch or a cache revalidation can fire
;;;; without a human, and the tier is already declared, so this costs one
;;;; conditional.

(in-package :loom-rest)

(defparameter *route-prefix* "/v1/"
  "Every operation is reachable at <prefix><operation-name>.")

(defun path-operation-name (path)
  "The operation name in PATH, or NIL when the path is not shaped like one."
  (let ((start (length *route-prefix*)))
    (when (and (<= start (length path))
               (string= *route-prefix* path :end2 start))
      (let ((name (subseq path start)))
        (when (plusp (length name)) name)))))

(defun keyword-from-parameter (name)
  (intern (string-upcase name) :keyword))

(defun query-arguments (request)
  (loop for (name . value) in (hunchentoot:get-parameters* request)
        append (list (keyword-from-parameter name) value)))

(defun body-arguments (request)
  "The JSON body of REQUEST as a plist, or NIL when there is no body.

cl-json decodes an object into an alist and lisp-ifies each key, so
{\"entity-type\": \"function\"} arrives as (:ENTITY-TYPE . \"function\") --
the same spelling the encoder produces in the other direction."
  (let ((text (hunchentoot:raw-post-data :request request :force-text t)))
    (when (and text (plusp (length text)))
      (let ((decoded (handler-case (json:decode-json-from-string text)
                       (guarded-condition (condition)
                         (error 'malformed-request
                                :message (format nil "The request body is not JSON: ~a"
                                                 condition))))))
        (unless (and (listp decoded) (every #'consp decoded))
          (error 'malformed-request
                 :message "The request body must be a JSON object."))
        (loop for (key . value) in decoded append (list key value))))))

(defun request-arguments (request)
  "The decoded arguments of REQUEST. A body value wins over a query one."
  (append (body-arguments request) (query-arguments request)))

(defun caller-grants (request)
  ;; The one seam, per request, before dispatch -- which is what makes
  ;; "protocol is not a proxy for trust" a property of loom-serve rather than
  ;; something this file has to remember.
  (resolve-caller-grants (hunchentoot:header-in :authorization request)))

(defun status-for (condition)
  "The HTTP status CONDITION deserves.

Ordered from the specific to the general, because UNKNOWN-ENTITY is a subtype
of MALFORMED-REQUEST: an unknown entity is a 404 and an unknown repository is
a 400, which is the distinction the subtype exists to carry."
  (typecase condition
    (capability-error hunchentoot:+http-forbidden+)
    (unknown-entity hunchentoot:+http-not-found+)
    (unknown-operation hunchentoot:+http-not-found+)
    (malformed-request hunchentoot:+http-bad-request+)
    (t hunchentoot:+http-internal-server-error+)))

(defun respond (status body)
  (setf (hunchentoot:return-code*) status
        (hunchentoot:content-type*) "application/json")
  (encode-result body))

(defun method-allowed-p (operation request)
  (or (eq :post (hunchentoot:request-method request))
      (eq :read (operation-tier operation))))

(defun handle-request (request)
  "One request, start to finish. The five steps and nothing else."
  ;; The outermost guard names GUARDED-CONDITION rather than ERROR, per R8 and
  ;; RULE-0004. Hunchentoot's own net is narrower -- handler-bind on ERROR --
  ;; and under `sbcl --script' a condition that escapes it ends the process
  ;; rather than the worker thread, so this handler is the one that matters.
  (handler-case
      (let ((name (path-operation-name (hunchentoot:script-name request))))
        (let ((operation (and name (find-operation name))))
          (unless operation
            (error 'unknown-operation :name (or name (hunchentoot:script-name request))))
          (unless (method-allowed-p operation request)
            (setf (hunchentoot:header-out :allow) "POST")
            (return-from handle-request
              (respond hunchentoot:+http-method-not-allowed+
                       (list :name "METHOD-NOT-ALLOWED"
                             :message (format nil "~(~a~) changes state and needs POST."
                                              (operation-name operation))))))
          (multiple-value-bind (result failure)
              (invoke-operation operation (caller-grants request)
                                (request-arguments request))
            (if failure
                ;; The operation itself signalled: R8's plist, and a 500,
                ;; because a condition from inside an operation is not a
                ;; statement about the request.
                (respond hunchentoot:+http-internal-server-error+ failure)
                (respond hunchentoot:+http-ok+ result)))))
    (guarded-condition (condition)
      (respond (status-for condition) (operation-error->plist condition)))))

;;;; The registration seam. A top-level form at load time, so that an image
;;;; holding loom-rest gets its routes and an image holding only loom-serve
;;;; gets a listener that answers 404 -- neither system naming the other.
(register-handler :loom-rest *route-prefix* #'handle-request)
