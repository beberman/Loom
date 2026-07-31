;;;
;;; Tests for src/process/console.lisp -- the command loop of SS3.2.
;;;
;;; Parsing and dispatch only. What the commands print is exercised by driving
;;; the real thing (level 2); what is worth unit-testing is that a line becomes
;;; the right call, and that a bad line becomes a message rather than a
;;; debugger prompt.
;;;

(in-package :loom-process-test)

(def-suite console
  :in all-tests
  :description "Command-line splitting, the command table, and error containment.")

(in-suite console)

;;; ------------------------------------------------------------------
;;; Splitting (SS3.2: "deliberately not the Lisp reader")
;;; ------------------------------------------------------------------

(test a-plain-line-splits-on-whitespace
  (is (equal '("impact" "resolve-calls")
             (loom-process::split-command-line "impact resolve-calls")))
  (is (equal '("status") (loom-process::split-command-line "  status  ")))
  (is (null (loom-process::split-command-line "   "))))

(test quotes-group-and-nothing-else-does
  ;; The reason quotes exist is Windows paths, so a backslash inside them has
  ;; to be a backslash and not an escape.
  (is (equal '("watch" "C:\\src\\my project")
             (loom-process::split-command-line "watch \"C:\\src\\my project\"")))
  (is (equal '("watch" "/home/b/lisp/Loom")
             (loom-process::split-command-line "watch \"/home/b/lisp/Loom\""))))

(test an-empty-quoted-argument-survives
  ;; Without this an empty string collapses and the argument count shifts,
  ;; which turns a clear error into a wrong call.
  (is (equal '("find" "") (loom-process::split-command-line "find \"\""))))

(test a-trailing-quote-does-not-lose-the-argument
  (is (equal '("context" "make the analyzer emit ops")
             (loom-process::split-command-line "context \"make the analyzer emit ops\""))))

;;; ------------------------------------------------------------------
;;; The command table
;;; ------------------------------------------------------------------

(test every-documented-command-is-registered
  ;; SS3.2's table, minus the two that need the HTTP listener.
  (dolist (name '("watch" "unwatch" "status" "reindex" "impact" "check"
                  "log" "repl" "stop" "help" "find" "describe" "context" "rules"))
    (is (not (null (loom-process::find-command name)))
        "~a must be a command" name)))

(test every-command-documents-itself
  ;; The table is what HELP prints, so a blank usage line is a visible bug.
  (dolist (command *commands*)
    (is (plusp (length (command-usage command)))
        "~a has no usage line" (command-name command))
    (is (plusp (length (command-summary command)))
        "~a has no summary" (command-name command))))

(test defining-a-command-twice-replaces-it
  ;; Redefining a command in a live image is the point of being in Lisp; two
  ;; entries with the same name would make dispatch depend on table order.
  (let ((before (length *commands*)))
    (define-command help (&optional name) "help [command]" "replaced"
      (declare (ignore name)))
    (is (= before (length *commands*)))
    (is (string= "replaced" (command-summary (loom-process::find-command "help"))))))

;;; ------------------------------------------------------------------
;;; Error containment (SS3.3)
;;; ------------------------------------------------------------------

(test an-unknown-command-is-a-message-not-a-condition
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "frobnicate everything"))))
    (is (search "Unknown command" output))))

(test a-command-that-signals-prints-and-continues
  ;; No repository is watched, so this one has nothing to act on. The
  ;; developer should be told, and the loop should still be running.
  (let ((output (with-output-to-string (*standard-output*)
                  (run-command "find alpha"))))
    (is (search "Nothing is being watched" output))))

(test a-blank-line-does-nothing
  (is (string= "" (with-output-to-string (*standard-output*)
                    (run-command "")))))

(test a-failed-command-is-logged
  (let ((*log* '()))
    (with-output-to-string (*standard-output*) (run-command "impact whatever"))
    (is (= 1 (length *log*)))
    (is (string= "error" (second (first *log*))))))

;;; ------------------------------------------------------------------
;;; Logging
;;; ------------------------------------------------------------------

(test the-log-is-bounded
  ;; It is a console convenience, not a durable record -- under files-as-truth
  ;; nothing recovers from it, so it must not grow without limit.
  (let ((*log* '()))
    (dotimes (i (+ loom-process::*log-limit* 50))
      (log-event "test" "event ~d" i))
    (is (= loom-process::*log-limit* (length *log*)))
    (is (search (format nil "event ~d" (+ loom-process::*log-limit* 49))
                (third (first *log*)))
        "and it keeps the newest, not the oldest")))
