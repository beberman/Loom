;;;
;;; Tests for src/mcp/jsonrpc.lisp and tools.lisp, over drakma against a
;;; running acceptor.
;;;

(in-package :loom-mcp-test)

(def-suite tools
  :in all-tests
  :description "The three methods, the ten tools, and one listener for both skins.")

(in-suite tools)

(defun rpc (method &key params (id 1))
  "One JSON-RPC call. Returns (values decoded-body http-status)."
  (multiple-value-bind (body status)
      (http-call *endpoint*
                 :method :post
                 :content-type "application/json"
                 :content (encode-result
                           (append (list :jsonrpc "2.0" :id id :method method)
                                   (when params (list :params params)))))
    (values (and (plusp (length body)) (json:decode-json-from-string body))
            status)))

(defun result-of (response) (cdr (assoc :result response)))
(defun error-of (response) (cdr (assoc :error response)))
(defun structured (response)
  (cdr (assoc :structured-content (result-of response))))

;;; ------------------------------------------------------------------

(test initialize-answers-with-a-protocol-version-and-capabilities
  (with-test-server ()
    (multiple-value-bind (response status) (rpc "initialize")
      (is (= 200 status))
      (let ((result (result-of response)))
        (is (equal *protocol-version* (cdr (assoc :protocol-version result))))
        (is (not (null (assoc :capabilities result))))
        (is (equal "loom" (cdr (assoc :name (cdr (assoc :server-info result))))))))))

(test tools-list-returns-exactly-fourteen-and-no-lifecycle-write-tool
  ;; The negative is the witness for DES-0006's deliberate asymmetry. Without
  ;; it, a later well-meaning restoration of symmetry between the two skins is
  ;; invisible -- the count would simply be fourteen and every other test would
  ;; still pass.
  ;;
  ;; Twelve rather than ten since REQ-0022: the two transition tools are on this
  ;; surface because R6 puts them there and REQ-0021 R8 says why -- an agent
  ;; installed into a prepared worktree reaches Loom through the service and has
  ;; no tools/loom.sh to shell out to. The four names below stay absent, which
  ;; is the part of DES-0006's asymmetry that was actually argued for.
  (with-test-server ()
    (let* ((tools (cdr (assoc :tools (result-of (rpc "tools/list")))))
           (names (mapcar (lambda (tool) (cdr (assoc :name tool))) tools)))
      (is (= 14 (length tools)) "the tool set is ~a" names)
      (dolist (present '("loom_set_status" "loom_complete"
                         "loom_structure" "loom_drift"))
        (is-true (member present names :test #'string=)
                 "~a is missing; REQ-0022 R6 puts the transition on MCP as well
as REST, and an agent in a prepared worktree has no other way to reach it"
                 present))
      ;; The lifecycle four, plus the three that prepare, describe or dismantle
      ;; a repository -- driven by tools/loom-init.sh where a terminal can ask
      ;; REQ-0021 R16's consent, and carried by REST for that script.
      (dolist (absent '("loom_watch" "loom_pause" "loom_unwatch" "loom_reindex"
                        "loom_init" "loom_remove" "loom_architecture"))
        (is-false (member absent names :test #'string=)
                  "~a is exposed; DES-0006 rejects the write tools under
ALTERNATIVES CONSIDERED, and reversing that is a decision rather than a tidy-up"
                  absent))
      ;; And every tool describes the arguments its entry actually takes,
      ;; because the schema is derived from the entry rather than written out.
      (let ((describe (find "loom_describe" tools
                            :key (lambda (tool) (cdr (assoc :name tool)))
                            :test #'string=)))
        (is (equal "object" (cdr (assoc :type (cdr (assoc :input-schema describe))))))
        (is (equal '("repository" "term")
                   (cdr (assoc :required (cdr (assoc :input-schema describe))))))))))

(test an-unknown-method-is-a-json-rpc-error-with-the-right-code
  (with-test-server ()
    (let ((response (rpc "frobnicate")))
      (is (null (result-of response)))
      (is (= -32601 (cdr (assoc :code (error-of response))))))))

(test a-body-that-is-not-json-is-a-parse-error
  ;; A malformed envelope never became a call, so it is a JSON-RPC error and
  ;; not a tool result. This is the near half of the distinction jsonrpc.lisp
  ;; exists to keep.
  (with-test-server ()
    (multiple-value-bind (body status)
        (http-call *endpoint* :method :post :content-type "application/json"
                              :content "{not json")
      (is (= 200 status))
      (is (= -32700 (cdr (assoc :code (cdr (assoc :error (json:decode-json-from-string body))))))))))

(test tools-call-returns-the-same-data-the-rest-route-does
  ;; "One registry, two skins" as an assertion rather than an intention, and
  ;; the strongest single test in this plan: the same question asked over both
  ;; protocols, against one resident graph, with no reindex between them.
  (with-operations-fixture (repository)
    (with-test-server ()
      (let* ((name (repository-name repository))
             (over-mcp (structured
                        (rpc "tools/call"
                             :params (list :name "loom_describe"
                                           :arguments (list :repository name
                                                            :term "alpha-twice")))))
             (over-rest (json:decode-json-from-string
                         (http-call (format nil "~adescribe" loom-rest:*route-prefix*)
                                    :parameters (list (cons "repository" name)
                                                      (cons "term" "alpha-twice"))))))
        (is (not (null over-mcp)) "the MCP call returned no structured content")
        (is (equal over-mcp over-rest)
            "the two skins disagree:~%  mcp:  ~a~%  rest: ~a" over-mcp over-rest)))))

(test an-mcp-caller-with-only-read-cannot-open-a-repl
  ;; isError inside a *successful* tools/call, carrying R8's plist -- not a
  ;; JSON-RPC transport error. The call happened; the tool said no.
  (with-test-server ()
    (let* ((response (rpc "tools/call"
                          :params (list :name "loom_repl_open" :arguments nil)))
           (result (result-of response)))
      (is (null (error-of response))
          "a refused tier arrived as a transport error rather than as a result")
      (is-true (cdr (assoc :is-error result)))
      (is (equal "CAPABILITY-ERROR" (cdr (assoc :name (structured response))))))))

(test an-unknown-tool-is-an-envelope-error
  ;; The other side of the same line: there is no tool, so there was no call.
  (with-test-server ()
    (let ((response (rpc "tools/call" :params (list :name "loom_frobnicate"))))
      (is (= -32602 (cdr (assoc :code (error-of response))))))))

(test one-listener-serves-both
  ;; DES-0006's WHY ONE LISTENER as a fact rather than an intention: the REST
  ;; route and the MCP endpoint answer on the same port, in one image, over one
  ;; graph.
  (with-operations-fixture (repository)
    (with-test-server ()
      (is (= 200 (nth-value 1 (http-call (format nil "~astatus" loom-rest:*route-prefix*)
                                         :parameters (list (cons "repository"
                                                                 (repository-name repository)))))))
      (is (= 200 (nth-value 1 (rpc "tools/list")))))))
