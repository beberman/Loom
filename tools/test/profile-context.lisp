;;;; Where a `context' query spends its time: a statistical CPU profile, the
;;;; garbage collector's share, and what one query allocates.
;;;;
;;;;   sbcl --script tools/test/profile-context.lisp <repository-root> <cases.json>
;;;;        [--mode lexical|semantic] [--queries N] [--threads T]
;;;;
;;;; BUG-0078 measured a service answering 18 `context' requests a second on 8
;;;; processors and could not say which part of a request was the cost. This runs
;;;; the same call the :context operation makes (BUILD-CONTEXT with the
;;;; repository's graph, store, embedder and source fetch) against a tree it
;;;; indexes itself, with no listener, so the profile holds the query and nothing
;;;; of HTTP. The tasks are the second field of each case in <cases.json>, the
;;;; shape tools/test/cases/loom-mismatch.json has.
;;;;
;;;;   --mode lexical    no vector store and no embedder: the lexical seeder only.
;;;;   --mode semantic   the store at the vector-store directory (LOOM_STATE_DIR
;;;;                     when set) and the Ollama embedder, which must be running.
;;;;   --queries N       how many queries to run, cycling through the cases (200).
;;;;   --threads T       how many threads share them (1). With T above 1 the
;;;;                     wall time against the CPU time says how much waiting
;;;;                     there is: CPU seconds over wall seconds is the
;;;;                     processors kept busy.
;;;;
;;;; One `name value' line per figure, then SB-SPROF's flat report: the self
;;;; time of each function across all threads, in :cpu mode, and the same
;;;; functions again ranked by the time in them and their callees, which is how
;;;; a Loom function is told from the library call at the bottom of it. A function in the
;;;; embedder client or the socket layer is the wait for Ollama and shows as
;;;; its own entry, so the report separates it from Loom's code.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(loom-harness:load-systems "tools/test/profile-context.lisp"
                           :systems '("utils/" "ontology/" "graph/" "analyzer/" "knowledge/"
                                      "docstore/" "workspace/" "embed/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem"
                                        "cl-json" "drakma")
                           :load :loom-workspace)
(require :sb-sprof)

(defpackage #:loom-profile-context
  (:use #:cl #:loom-graph #:loom-workspace))
(in-package #:loom-profile-context)

(defun report (name value)
  (format t "~a ~a~%" name value))

(defun option (arguments name default)
  (let ((flag (member name arguments :test #'string=)))
    (if flag (second flag) default)))

(defun read-tasks (path)
  (mapcar #'second (cl-json:decode-json-from-source (pathname path))))

(defun one-query (repository task semantic)
  (let ((loom-knowledge:*context-vector-store* (and semantic (repository-vectors repository)))
        (loom-knowledge:*context-embedder* (and semantic (current-embedder))))
    (loom-knowledge:build-context (repository-graph repository) task
                                  :provenance (index-provenance repository)
                                  :source-fn (lambda (id) (definition-source repository id)))))

(defun run-queries (repository tasks count threads semantic)
  (let* ((next 0)
         (lock (bordeaux-threads:make-lock))
         (workers (loop repeat threads
                        collect (bordeaux-threads:make-thread
                                 (lambda ()
                                   (loop
                                     (let ((n (bordeaux-threads:with-lock-held (lock)
                                                (when (< next count) (prog1 next (incf next))))))
                                       (unless n (return))
                                       (one-query repository (nth (mod n (length tasks)) tasks)
                                                  semantic))))))))
    (mapc #'bordeaux-threads:join-thread workers)))

(defun measure (root cases arguments)
  (let* ((mode (option arguments "--mode" "lexical"))
         (count (parse-integer (option arguments "--queries" "200")))
         (threads (parse-integer (option arguments "--threads" "1")))
         (semantic (string= mode "semantic"))
         (tasks (read-tasks cases))
         (repository (watch-repository root :monitor nil :quiet t)))
    (when (and semantic (null (repository-vectors repository)))
      (error "--mode semantic needs a vector store for ~a and there is none." root))
    ;; Warm the caches the first query would otherwise charge to itself.
    (one-query repository (first tasks) semantic)
    (sb-ext:gc :full t)
    (let ((gc-before sb-ext:*gc-run-time*)
          (consed-before (sb-ext:get-bytes-consed))
          (real-before (get-internal-real-time))
          (cpu-before (get-internal-run-time)))
      (sb-sprof:with-profiling (:max-samples 100000 :sample-interval 0.002 :mode :cpu
                                :threads :all)
        (run-queries repository tasks count threads semantic))
      (let ((wall (/ (- (get-internal-real-time) real-before) internal-time-units-per-second 1.0))
            (cpu (/ (- (get-internal-run-time) cpu-before) internal-time-units-per-second 1.0)))
        (report "mode" mode)
        (report "queries" count)
        (report "threads" threads)
        (report "wall-seconds" (format nil "~,2f" wall))
        (report "cpu-seconds" (format nil "~,2f" cpu))
        (report "processors-busy" (format nil "~,2f" (/ cpu wall)))
        (report "queries-per-second" (format nil "~,1f" (/ count wall)))
        (report "cpu-ms-per-query" (format nil "~,1f" (/ (* 1000 cpu) count)))
        (report "gc-seconds" (format nil "~,2f" (/ (- sb-ext:*gc-run-time* gc-before)
                                                   internal-time-units-per-second 1.0)))
        (report "bytes-consed-per-query" (round (- (sb-ext:get-bytes-consed) consed-before) count))
        (terpri)
        (sb-sprof:report :type :flat :max 30)
        (format t "~%Sorted by time in the function and what it called:~%")
        (sb-sprof:report :type :flat :max 40 :sort-by :cumulative-samples)))))

(defun main ()
  "A function rather than a top-level form, for index-cost.lisp's reason."
  (let* ((arguments (rest sb-ext:*posix-argv*))
         (root (or (first arguments)
                   (error "Usage: sbcl --script tools/test/profile-context.lisp <repository-root> <cases.json> [--mode lexical|semantic] [--queries N] [--threads T]")))
         (cases (or (second arguments) (error "A cases file is the second argument."))))
    (measure root cases arguments)))

(main)
