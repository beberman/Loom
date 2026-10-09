;;;
;;; Tests for src/rest/routes.lisp.
;;;
;;; Every one of these goes over TCP through drakma against a running acceptor.
;;; The whole claim of this system is that a request arriving over TCP produces
;;; the plist, and a test that called INVOKE-OPERATION and then encoded the
;;; result would verify loom-serve twice and loom-rest not at all.
;;;

(in-package :loom-rest-test)

(def-suite routes
  :in all-tests
  :description "The fourteen operations over HTTP, and how a refusal arrives.")

(in-suite routes)

(defun route (name) (format nil "~a~(~a~)" *route-prefix* name))

(defun decode (body) (json:decode-json-from-string body))

(defmacro with-grants ((grants) &body body)
  "Run BODY with the static grant set SETF to GRANTS, restored afterwards.

SETF and not LET: grants are resolved in a Hunchentoot worker thread, and a
special bound in this thread is invisible there. This is the same trap
WITH-SAVED-HANDLERS documents, and it is worth stating twice because a test
that got it wrong would pass while testing nothing."
  (let ((saved (gensym "GRANTS")))
    `(let ((,saved *static-grants*))
       (unwind-protect (progn (setf *static-grants* ,grants) ,@body)
         (setf *static-grants* ,saved)))))

;;; ------------------------------------------------------------------

(test a-read-route-returns-the-operations-plist-as-json
  (with-operations-fixture (repository)
    (with-test-server ()
      (multiple-value-bind (body status)
          (http-call (route :describe)
                     :parameters (list (cons "repository" (repository-name repository))
                                       (cons "term" "DEC-0001")))
        (is (= 200 status))
        (let ((decoded (decode body)))
          (dolist (key '(:entity :properties :neighbors :document))
            (is (not (null (assoc key decoded)))
                "~a is missing from the response: ~a" key body)))
        ;; The key vocabulary crossing the wire intact. cl-json would have
        ;; spelled this "fullTokens" of its own accord, and a decode
        ;; round-trip would have agreed with itself either way.
        (is (search "full-tokens" body)
            "the document summary lost its key names: ~a" body)))))

(defun rest-python-available-p ()
  (handler-case (progn (uiop:run-program '("python3" "-c" "pass")) t)
    (error () nil)))

(test describe-over-rest-carries-a-decorators-encoded-arguments-as-json
  ;; DES-0054 risk 3: :DECORATORS' arguments changed from a list of names to a
  ;; tagged plist, and nothing over REST asserted on decorators before. The body
  ;; must still parse and still say which secret and which memory the decorator
  ;; names.
  (if (not (rest-python-available-p))
      (skip "python3 is not on PATH")
      (with-operations-fixture (repository)
        (loom-serve-test::write-operations-fixture-file "functions/main.py" "from firebase_functions import https_fn, options
@https_fn.on_request(secrets=[ZEFFY_API_KEY], memory=options.MemoryOption.MB_512)
def sync_zeffy(req): pass
")
        (with-test-server ()
          (http-call (route :reindex)
                     :method :post :content-type "application/json"
                     :content (format nil "{\"repository\":\"~a\"}"
                                      (repository-name repository)))
          (multiple-value-bind (body status)
              (http-call (route :describe)
                         :parameters (list (cons "repository" (repository-name repository))
                                           (cons "term" "sync_zeffy")))
            (is (= 200 status))
            (finishes (decode body))
            (is (search "ZEFFY_API_KEY" body))
            (is (search "options.MemoryOption.MB_512" body)))))))

(defun rest-node-available-p ()
  (handler-case (progn (uiop:run-program '("node" "--version")) t)
    (error () nil)))

(test describe-over-rest-carries-a-javascript-registration-as-json
  ;; PLAN-0058 risk 3: a JavaScript :VARIABLE gains :REGISTRATION, a nested plist
  ;; that must still encode and parse, and name the callee the entry-points
  ;; declaration is matched against.
  (if (not (rest-node-available-p))
      (skip "node is not on PATH")
      (with-operations-fixture (repository)
        (loom-serve-test::write-operations-fixture-file "functions/index.js" "import functions from \"firebase-functions\";
export const api = functions.https.onRequest((req, res) => {});
")
        (with-test-server ()
          (http-call (route :reindex)
                     :method :post :content-type "application/json"
                     :content (format nil "{\"repository\":\"~a\"}"
                                      (repository-name repository)))
          (multiple-value-bind (body status)
              (http-call (route :describe)
                         :parameters (list (cons "repository" (repository-name repository))
                                           (cons "term" "api")))
            (is (= 200 status))
            (finishes (decode body))
            (is (search "functions.https.onRequest" body)))))))

(test a-write-route-changes-what-status-reports
  ;; Two requests, because a write whose effect is only visible to the same
  ;; request has not been tested.
  (with-operations-fixture (repository)
    (with-test-server ()
      (let ((before (repository-indexed-at repository)))
        ;; GET-UNIVERSAL-TIME counts in whole seconds, so a rebuild inside the
        ;; same second carries the same stamp and "moved" would be a coin
        ;; toss. Waiting for the clock to tick makes the assertion mean what
        ;; it says -- the same whole-second lesson *MTIME-SETTLE-SECONDS*
        ;; records one system down.
        (loop while (<= (get-universal-time) before) do (sleep 0.05))
        (multiple-value-bind (body status)
            (http-call (route :reindex)
                       :method :post
                       :content-type "application/json"
                       :content (format nil "{\"repository\":\"~a\"}"
                                        (repository-name repository)))
          (declare (ignore body))
          (is (= 200 status)))
        (multiple-value-bind (body status)
            (http-call (route :status)
                       :parameters (list (cons "repository" (repository-name repository))))
          (is (= 200 status))
          (let ((after (cdr (assoc :indexed-at (decode body)))))
            (is (> after before)
                "the write is not visible to a later request: ~a then ~a"
                before after)))))))

(test a-read-only-caller-gets-403-not-500
  ;; R8 crossing the protocol boundary intact: the tier refusal arrives as a
  ;; status a client can branch on, with the error plist's own :name and
  ;; :message in the body.
  (with-operations-fixture (repository)
    (with-test-server ()
      (with-grants ('(:read))
        (multiple-value-bind (body status)
            (http-call (route :reindex)
                       :method :post
                       :content-type "application/json"
                       :content (format nil "{\"repository\":\"~a\"}"
                                        (repository-name repository)))
          (is (= 403 status))
          (let ((decoded (decode body)))
            (is (equal "CAPABILITY-ERROR" (cdr (assoc :name decoded))))
            (is (search "write" (cdr (assoc :message decoded))))))))))

(test an-unknown-repository-is-400-with-a-message-naming-it
  ;; Not a stack trace, and not Hunchentoot's own HTML error page.
  (with-test-server ()
    (multiple-value-bind (body status)
        (http-call (route :check) :parameters '(("repository" . "no-such-repo")))
      (is (= 400 status))
      (let ((decoded (decode body)))
        (is (equal "MALFORMED-REQUEST" (cdr (assoc :name decoded))))
        (is (search "no-such-repo" (cdr (assoc :message decoded)))
            "the message does not name what was asked for: ~a" body)))))

(test an-unknown-entity-is-404-and-an-unknown-operation-is-too
  (with-operations-fixture (repository)
    (with-test-server ()
      (is (= 404 (nth-value 1 (http-call (route :describe)
                                         :parameters
                                         (list (cons "repository" (repository-name repository))
                                               (cons "term" "zarquon"))))))
      (is (= 404 (nth-value 1 (http-call (route :frobnicate))))))))

(test every-operation-is-routed
  ;; It fails the day someone adds an operation the HTTP surface cannot reach.
  ;; Asserted by issuing a real request for each rather than by inspecting a
  ;; table: what matters is that the path resolves, and a table can agree with
  ;; itself while the dispatcher disagrees with both.
  (with-test-server ()
    (dolist (operation (all-operations))
      (let* ((write-tier (not (eq :read (operation-tier operation))))
             (status (nth-value 1
                                (if write-tier
                                    (http-call (route (operation-name operation))
                                               :method :post
                                               :content-type "application/json"
                                               :content "{}")
                                    (http-call (route (operation-name operation)))))))
        (is (/= 404 status)
            "~(~a~) has no route" (operation-name operation))
        (is (/= 405 status)
            "~(~a~) refused the method its tier implies" (operation-name operation))))))

(test a-write-operation-refuses-a-get
  ;; The one piece of HTTP opinion in routes.lisp, asserted so that it is a
  ;; decision rather than an accident: a GET that reindexes a repository is
  ;; something a prefetch can fire without a human.
  (with-test-server ()
    (is (= 405 (nth-value 1 (http-call (route :reindex)))))))

(test the-repl-is-routed-but-not-granted
  ;; R9 asks that the REPL be reachable through the same REST surface, and R6
  ;; keeps :repl out of the static grant set while the credential story is
  ;; unfinished. Both are true at once, and this is what that looks like: the
  ;; route exists and answers 403 rather than 404.
  (with-test-server ()
    (is (= 403 (nth-value 1 (http-call (route :repl-open)
                                       :method :post
                                       :content-type "application/json"
                                       :content "{}"))))))

(test status-and-describe-over-rest-carry-the-dependency-fields-as-json
  ;; DES-0055 R8 through the HTTP boundary.
  (with-operations-fixture (repository)
    (loom-serve-test::add-dependency-entities repository)
    (with-test-server ()
      (multiple-value-bind (body status)
          (http-call (route :status)
                     :parameters (list (cons "repository" (repository-name repository))))
        (is (= 200 status))
        (let ((dependencies (cdr (assoc :dependencies (decode body)))))
          (is (equal "pypi" (cdr (assoc :ecosystem (first dependencies)))) "~a" body)))
      (multiple-value-bind (body status)
          (http-call (route :describe)
                     :parameters (list (cons "repository" (repository-name repository))
                                       (cons "term" "tzdata")))
        (is (= 200 status))
        (is (equal "requirements.txt"
                   (cdr (assoc :manifest (cdr (assoc :dependency (decode body))))))
            "~a" body)))))
