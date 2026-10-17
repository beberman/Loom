;;;
;;; Tests for src/mcp/jsonrpc.lisp and tools.lisp, over drakma against a
;;; running acceptor.
;;;

(in-package :synoptik-mcp-test)

(def-suite tools
  :in all-tests
  :description "The three methods, the ten tools, and one listener for both skins.")

(in-suite tools)

(defun rpc-raw (method &key params (id 1))
  "One JSON-RPC call, as the text on the wire.

Wanted because cl-json decodes JSON `false' and JSON `null' to the same NIL, so
a decoded response cannot tell a typed boolean from a missing one. BUG-0028 is
exactly that distinction, and a test that went through the decoder would have
passed against the defect."
  (http-call *endpoint*
             :method :post
             :content-type "application/json"
             :content (encode-result
                       (append (list :jsonrpc "2.0" :id id :method method)
                               (when params (list :params params))))))

(defun rpc (method &key params (id 1))
  "One JSON-RPC call. Returns (values decoded-body http-status)."
  (multiple-value-bind (body status) (rpc-raw method :params params :id id)
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
        (is (equal "synoptik" (cdr (assoc :name (cdr (assoc :server-info result))))))))))

(defmacro with-grants ((grants) &body body)
  "Run BODY with *STATIC-GRANTS* set to GRANTS, restoring it after.

SETF and not LET, for the reason synoptik-rest's copy of this macro states at
length: grants are resolved in a Hunchentoot worker thread, and a special bound
in this thread is invisible there. A test that got it wrong would pass while
testing nothing."
  (let ((saved (gensym "GRANTS")))
    `(let ((,saved synoptik-serve:*static-grants*))
       (unwind-protect (progn (setf synoptik-serve:*static-grants* ,grants) ,@body)
         (setf synoptik-serve:*static-grants* ,saved)))))

(test tools-list-returns-what-the-caller-may-call-and-no-lifecycle-write-tool
  ;; The negative is the witness for DES-0006's deliberate asymmetry. Without
  ;; it, a later well-meaning restoration of symmetry between the two skins is
  ;; invisible -- the count would simply be the count and every other test would
  ;; still pass.
  ;;
  ;; Three fewer than *TOOLS* holds, since REQ-0032: RESOLVE-CALLER-GRANTS
  ;; answers :read and :write and deliberately not :repl, so the three repl
  ;; tools were advertised to every caller and callable by none. An agent on
  ;; game-server planned around them, spent five `sbcl --load' launches doing by
  ;; shell what a session does in one, and was refused at the end of the task.
  (with-test-server ()
    (let* ((tools (cdr (assoc :tools (result-of (rpc "tools/list")))))
           (names (mapcar (lambda (tool) (cdr (assoc :name tool))) tools)))
      (is (= 16 (length tools)) "the tool set is ~a" names)
      (dolist (repl '("synoptik_repl_open" "synoptik_repl_eval" "synoptik_repl_close"))
        (is-false (member repl names :test #'string=)
                  "~a is advertised to a caller that cannot call it" repl))
      (dolist (present '("synoptik_set_status" "synoptik_complete"
                         "synoptik_structure" "synoptik_drift"
                         ;; REQ-0034. The workflow tool an agent asks before
                         ;; the file exists.
                         "synoptik_check_document"
                         ;; BUG-0052. Read-tier queries, advertised for the
                         ;; reason synoptik_structure and synoptik_drift are: an agent
                         ;; in a prepared worktree has no console, and
                         ;; `similar' is the one question `find' cannot answer.
                         "synoptik_similar" "synoptik_survey"
                         ;; PLAN-0060 step 7. REST finds an operation by name;
                         ;; MCP lists its tools by hand.
                         "synoptik_sites"))
        (is-true (member present names :test #'string=)
                 "~a is missing; REQ-0022 R6 puts the transition on MCP as well
as REST, and an agent in a prepared worktree has no other way to reach it"
                 present))
      ;; The lifecycle four, plus the three that prepare, describe or dismantle
      ;; a repository -- driven by tools/synoptik-init.sh where a terminal can ask
      ;; REQ-0021 R16's consent, and carried by REST for that script.
      (dolist (absent '("synoptik_watch" "synoptik_pause" "synoptik_unwatch" "synoptik_reindex"
                        "synoptik_init" "synoptik_remove" "synoptik_architecture"))
        (is-false (member absent names :test #'string=)
                  "~a is exposed; DES-0006 rejects the write tools under
ALTERNATIVES CONSIDERED, and reversing that is a decision rather than a tidy-up"
                  absent))
      ;; And every tool describes the arguments its entry actually takes,
      ;; because the schema is derived from the entry rather than written out.
      (let ((describe (find "synoptik_describe" tools
                            :key (lambda (tool) (cdr (assoc :name tool)))
                            :test #'string=)))
        (is (equal "object" (cdr (assoc :type (cdr (assoc :input-schema describe))))))
        (is (equal '("repository" "term")
                   (cdr (assoc :required (cdr (assoc :input-schema describe))))))))))

(test granting-repl-adds-the-three-tools-and-nothing-else
  ;; REQ-0032 R4's second assertion, and the one that says the filter reads the
  ;; grant rather than a list of names it was told to hide. On the day
  ;; RESOLVE-CALLER-GRANTS answers :repl for some callers, those callers' lists
  ;; grow by exactly three and nothing else changes.
  (with-test-server ()
    (let ((without (cdr (assoc :tools (result-of (rpc "tools/list"))))))
      (with-grants ('(:read :write :repl))
        (let* ((with (cdr (assoc :tools (result-of (rpc "tools/list")))))
               (names (mapcar (lambda (tool) (cdr (assoc :name tool))) with)))
          (is (= 19 (length with)))
          (is (= 3 (- (length with) (length without))))
          (dolist (repl '("synoptik_repl_open" "synoptik_repl_eval" "synoptik_repl_close"))
            (is-true (member repl names :test #'string=)
                     "~a is callable now and must be advertised" repl)))))))

(test a-read-only-caller-is-shown-only-read-tools
  ;; The other direction, and the one that shows the filter is per-tier rather
  ;; than per-name: with :write withdrawn, the two transition tools go too.
  (with-test-server ()
    (with-grants ('(:read))
      (let* ((tools (cdr (assoc :tools (result-of (rpc "tools/list")))))
             (names (mapcar (lambda (tool) (cdr (assoc :name tool))) tools)))
        (is-true (member "synoptik_find" names :test #'string=))
        (dolist (write '("synoptik_set_status" "synoptik_complete" "synoptik_context_used"))
          (is-false (member write names :test #'string=)
                    "~a is a :write tool and this caller has no :write" write))))))

(test a-tool-that-was-never-shown-is-still-refused-at-the-call
  ;; REQ-0032 R3. Filtering the advertisement removes a misleading claim and
  ;; removes no enforcement: a client may call a tool it was never shown, and
  ;; CHECK-CAPABILITY must refuse it exactly as it did. The answer is a tool
  ;; result carrying isError, not "no such tool" -- the server has the tool,
  ;; and telling a caller otherwise would be a different and false thing.
  (with-test-server ()
    (let* ((response (rpc "tools/call"
                          :params (list :name "synoptik_repl_open"
                                        :arguments (list :repository "nope"))))
           (result (result-of response)))
      (is (not (null result)) "the envelope was well formed, so this is a result")
      (is-true (cdr (assoc :is-error result))
               "and the refusal is inside it: ~a" result)
      ;; The reason, not merely a failure. A missing repository would also set
      ;; isError, so asserting the flag alone would pass against a server that
      ;; had stopped checking the tier entirely.
      (let ((structured (cdr (assoc :structured-content result))))
        (is (equal "CAPABILITY-ERROR" (cdr (assoc :name structured)))
            "the refusal is the tier check and not some other failure: ~a"
            structured)))))

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
                             :params (list :name "synoptik_describe"
                                           :arguments (list :repository name
                                                            :term "alpha-twice")))))
             (over-rest (json:decode-json-from-string
                         (http-call (format nil "~adescribe" synoptik-rest:*route-prefix*)
                                    :parameters (list (cons "repository" name)
                                                      (cons "term" "alpha-twice"))))))
        (is (not (null over-mcp)) "the MCP call returned no structured content")
        (is (equal over-mcp over-rest)
            "the two skins disagree:~%  mcp:  ~a~%  rest: ~a" over-mcp over-rest)))))

(test synoptik-sites-over-mcp-answers-what-the-rest-route-does
  ;; PLAN-0060 step 7. The tool list is written by hand, so the registry entry
  ;; alone does not reach MCP: this fails without the MAKE-TOOL line, with an
  ;; unknown tool.
  (with-operations-fixture (repository)
    (with-test-server ()
      (let* ((name (repository-name repository))
             (over-mcp (structured
                        (rpc "tools/call"
                             :params (list :name "synoptik_sites"
                                           :arguments (list :repository name
                                                            :term "alpha")))))
             (over-rest (json:decode-json-from-string
                         (http-call (format nil "~asites" synoptik-rest:*route-prefix*)
                                    :parameters (list (cons "repository" name)
                                                      (cons "term" "alpha"))))))
        (is (= 2 (length (cdr (assoc :groups over-mcp)))) "~s" over-mcp)
        (is (equal over-mcp over-rest)
            "the two skins disagree:~%  mcp:  ~a~%  rest: ~a" over-mcp over-rest)))))

(test an-mcp-caller-with-only-read-cannot-open-a-repl
  ;; isError inside a *successful* tools/call, carrying R8's plist -- not a
  ;; JSON-RPC transport error. The call happened; the tool said no.
  (with-test-server ()
    (let* ((response (rpc "tools/call"
                          :params (list :name "synoptik_repl_open" :arguments nil)))
           (result (result-of response)))
      (is (null (error-of response))
          "a refused tier arrived as a transport error rather than as a result")
      (is-true (cdr (assoc :is-error result)))
      (is (equal "CAPABILITY-ERROR" (cdr (assoc :name (structured response))))))))

(test a-successful-call-reports-is-error-as-the-boolean-false
  ;; BUG-0028. isError is typed boolean in the MCP result schema, and NIL
  ;; encodes as null, so every *successful* tools/call carried
  ;; "isError":null. A client that validates the result before reading it --
  ;; Claude Code does -- rejected the answer, which meant every working tool
  ;; failed and only the refusals got through.
  ;;
  ;; Asserted against the wire text rather than the decoded body on purpose:
  ;; cl-json reads `false' and `null' both as NIL, so the obvious decoded
  ;; assertion passes against the defect. The test that would have caught this
  ;; is the one nobody wrote -- the existing coverage asserted isError on a
  ;; refusal, where the value was T and encoded correctly all along.
  (with-test-server ()
    (let ((body (rpc-raw "tools/call"
                         :params (list :name "synoptik_status" :arguments nil))))
      (is (search "\"isError\":false" body)
          "a successful call must carry the boolean false, not null:~%  ~a" body)
      (is-false (search "\"isError\":null" body)))))

(test a-refused-call-still-reports-is-error-as-true
  ;; The other half, so the fix cannot be "always write false".
  (with-test-server ()
    (let ((body (rpc-raw "tools/call"
                         :params (list :name "synoptik_repl_open" :arguments nil))))
      (is (search "\"isError\":true" body)
          "a refusal must still say true:~%  ~a" body))))

(test an-unknown-tool-is-an-envelope-error
  ;; The other side of the same line: there is no tool, so there was no call.
  (with-test-server ()
    (let ((response (rpc "tools/call" :params (list :name "synoptik_frobnicate"))))
      (is (= -32602 (cdr (assoc :code (error-of response))))))))

(test one-listener-serves-both
  ;; DES-0006's WHY ONE LISTENER as a fact rather than an intention: the REST
  ;; route and the MCP endpoint answer on the same port, in one image, over one
  ;; graph.
  (with-operations-fixture (repository)
    (with-test-server ()
      (is (= 200 (nth-value 1 (http-call (format nil "~astatus" synoptik-rest:*route-prefix*)
                                         :parameters (list (cons "repository"
                                                                 (repository-name repository)))))))
      (is (= 200 (nth-value 1 (rpc "tools/list")))))))

(test find-by-trigger-answers-the-same-over-mcp-and-rest-and-keeps-its-schema
  ;; DES-0054 R9. The optional `trigger' is added to the shape, and `required'
  ;; stays what it was, since a client may cache the schema.
  (with-operations-fixture (repository)
    (synoptik-graph:add-entity
     (repository-graph repository)
     (make-instance 'synoptik-ontology:function-entity :name "sync_zeffy"
                    :origin-file "functions/main.py"
                    :properties (synoptik-ontology:properties-table
                                 '(:file "functions/main.py" :start-line 1 :end-line 4
                                   :language :python :trigger :schedule))))
    (with-test-server ()
      (let* ((name (repository-name repository))
             (over-mcp (structured
                        (rpc "tools/call"
                             :params (list :name "synoptik_find"
                                           :arguments (list :repository name :term ""
                                                            :trigger "schedule")))))
             (over-rest (json:decode-json-from-string
                         (http-call (format nil "~afind" synoptik-rest:*route-prefix*)
                                    :parameters (list (cons "repository" name)
                                                      (cons "term" "")
                                                      (cons "trigger" "schedule")))))
             (tools (cdr (assoc :tools (result-of (rpc "tools/list")))))
             (find-tool (find "synoptik_find" tools :key (lambda (tool) (cdr (assoc :name tool)))
                                                :test #'string=)))
        (is (equal "sync_zeffy"
                   (cdr (assoc :name (first (cdr (assoc :entities over-mcp)))))))
        (is (equal (cdr (assoc :entities over-mcp)) (cdr (assoc :entities over-rest))))
        (is (equal '("term") (cdr (assoc :required (cdr (assoc :input-schema find-tool)))))
            "term stays required and repository stays optional")
        (is (assoc :trigger (cdr (assoc :properties (cdr (assoc :input-schema find-tool)))))
            "the new argument is advertised")))))
