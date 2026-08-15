;;;; The JSON-RPC 2.0 endpoint.
;;;;
;;;; One POST endpoint, registered on loom-serve's seam at load time, answering
;;;; every call with a single JSON response body and never an SSE stream. The
;;;; three methods a conformant server implements at minimum are the three it
;;;; implements: initialize, tools/list, tools/call.
;;;;
;;;; The distinction this file has to keep straight, and states rather than
;;;; implies: a JSON-RPC error and an R8 operation error are different things.
;;;; A malformed envelope -- unparseable JSON, a missing method, a method
;;;; nobody implements -- is a JSON-RPC error object, because the request never
;;;; became a call. An operation that ran and refused, or that signalled, is a
;;;; successful tools/call whose *result* carries isError with the R8 plist as
;;;; its content, because the call happened and this is what it returned. A
;;;; client distinguishes "I spoke the protocol wrongly" from "the tool said
;;;; no", and collapsing the two would take that away.

(in-package :loom-mcp)

(defparameter *endpoint* "/mcp"
  "The single path this system registers on loom-serve's seam.")

(defparameter *protocol-version* "2025-06-18")

(defparameter *server-info* (list :|name| "loom" :|version| "0.1.0"))

;;;; JSON-RPC 2.0's own codes. Named rather than written at the call sites,
;;;; because a wrong number here is a client-visible protocol defect that no
;;;; test of ours would notice.
(defparameter *parse-error* -32700)
(defparameter *invalid-request* -32600)
(defparameter *method-not-found* -32601)
(defparameter *invalid-params* -32602)
(defparameter *internal-error* -32603)

(defun alist-plist (alist)
  "A decoded JSON object as a plist. NIL for anything that is not one."
  (when (and (listp alist) (every #'consp alist))
    (loop for (key . value) in alist append (list key value))))

(defun field (object key)
  (cdr (assoc key object)))

(defun rpc-result (id result)
  (list :jsonrpc "2.0" :id id :result result))

(defun rpc-error (id code message)
  (list :jsonrpc "2.0" :id id :error (list :code code :message message)))

(defun tool-result (content &key error)
  "A tools/call result. CONTENT is the plist the operation produced or refused
with."
  (list :|content| (vector (list :|type| "text" :|text| (encode-result content)))
        ;; Both, deliberately: the text block is what a model reads and
        ;; structuredContent is what a program reads, and they are the same
        ;; answer rather than two renderings of it.
        :|structuredContent| content
        ;; *JSON-FALSE* rather than NIL, which encodes as null. isError is typed
        ;; boolean in the MCP schema, and a client that validates the result
        ;; before reading it rejects null -- so every *successful* call was
        ;; refused by the client while every failing one passed, which is
        ;; BUG-0028 and is why this reads oddly at first glance. The spec allows
        ;; omitting the field entirely and defaulting it to false; it is written
        ;; explicitly instead because a caller reading result.isError directly
        ;; should not have to know the default.
        :|isError| (if error t *json-false*)))

(defun call-tool (parameters grants)
  "Dispatch a tools/call. Returns (values result code message).

A code means the *envelope* was wrong -- no tool by that name, arguments that
are not an object -- and becomes a JSON-RPC error. Everything the operation
itself decides comes back as a result with isError."
  (let* ((name (field parameters :name))
         (tool (and (stringp name) (find-tool name)))
         (arguments (field parameters :arguments)))
    (cond ((null tool)
           (values nil *invalid-params* (format nil "No tool named ~a." name)))
          ((and arguments (null (alist-plist arguments)))
           (values nil *invalid-params* "arguments must be an object."))
          (t
           (handler-case
               (multiple-value-bind (result failure)
                   (invoke-operation (find-operation (tool-operation tool))
                                     grants (alist-plist arguments))
                 (if failure
                     (values (tool-result failure :error t) nil nil)
                     (values (tool-result result) nil nil)))
             ;; A refused tier or a malformed argument is what the tool
             ;; answered, not a transport failure, so it stays inside the
             ;; result. RULE-0004's type list, because a condition escaping
             ;; here would end the process under `sbcl --script'.
             (guarded-condition (condition)
               (values (tool-result (operation-error->plist condition) :error t)
                       nil nil)))))))

(defun dispatch-method (method parameters id grants)
  (cond ((string= method "initialize")
         (rpc-result id (list :|protocolVersion| *protocol-version*
                              ;; An empty object rather than NIL, which would
                              ;; encode as null: a capabilities field that is
                              ;; null does not declare "no options", it fails
                              ;; to parse as an object.
                              :|capabilities| (list :|tools| (make-hash-table))
                              :|serverInfo| *server-info*)))
        ((string= method "tools/list")
         (rpc-result id (list :|tools| (map 'vector #'tool-descriptor (all-tools)))))
        ((string= method "tools/call")
         (multiple-value-bind (result code message) (call-tool parameters grants)
           (if code (rpc-error id code message) (rpc-result id result))))
        (t (rpc-error id *method-not-found*
                      (format nil "No method ~a." method)))))

(defun respond-json (body)
  (setf (hunchentoot:return-code*) hunchentoot:+http-ok+
        (hunchentoot:content-type*) "application/json")
  (encode-result body))

(defun handle-jsonrpc (request)
  "One JSON-RPC request, answered with one JSON body.

The HTTP status is 200 for every well-formed transport exchange, including one
carrying a JSON-RPC error object: the error is in the body, which is what
JSON-RPC says and what a client parses. The exceptions are the two that are not
JSON-RPC at all -- a method other than POST, which this endpoint does not
implement because SSE is out of scope, and a body that is not JSON."
  (handler-case
      (cond
        ((not (eq :post (hunchentoot:request-method request)))
         (setf (hunchentoot:return-code*) hunchentoot:+http-method-not-allowed+
               (hunchentoot:header-out :allow) "POST"
               (hunchentoot:content-type*) "application/json")
         (encode-result (list :name "METHOD-NOT-ALLOWED"
                              :message "The MCP endpoint answers POST. SSE is not implemented.")))
        (t
         (let* ((text (hunchentoot:raw-post-data :request request :force-text t))
                (envelope (handler-case (and text (json:decode-json-from-string text))
                            (guarded-condition () :unparseable))))
           (cond
             ((eq envelope :unparseable)
              (respond-json (rpc-error nil *parse-error* "The request body is not JSON.")))
             ((not (and (listp envelope) (every #'consp envelope)))
              (respond-json (rpc-error nil *invalid-request*
                                       "A JSON-RPC request is an object.")))
             (t
              (let ((id (field envelope :id))
                    (method (field envelope :method)))
                (cond
                  ((not (equal "2.0" (field envelope :jsonrpc)))
                   (respond-json (rpc-error id *invalid-request*
                                            "jsonrpc must be \"2.0\".")))
                  ((not (stringp method))
                   (respond-json (rpc-error id *invalid-request*
                                            "A JSON-RPC request names a method.")))
                  ;; A notification carries no id and gets no response body at
                  ;; all -- notifications/initialized is the one every MCP
                  ;; client sends, and answering it would be a protocol error
                  ;; of ours rather than of theirs.
                  ((null id)
                   (setf (hunchentoot:return-code*) hunchentoot:+http-accepted+)
                   "")
                  (t
                   (respond-json
                    (dispatch-method method (field envelope :params) id
                                     (resolve-caller-grants
                                      (hunchentoot:header-in :authorization request))))))))))))
    ;; The outermost net. Nothing below it may reach Hunchentoot, whose own
    ;; handler names ERROR and therefore misses exactly the conditions
    ;; RULE-0004 is about.
    (guarded-condition (condition)
      (respond-json (rpc-error nil *internal-error* (princ-to-string condition))))))

;;;; The registration seam, at load time, so neither skin names the other.
(register-handler :loom-mcp *endpoint* #'handle-jsonrpc)
