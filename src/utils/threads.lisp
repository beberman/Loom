;;;; Waiting: for a thread to finish, and for an interval that a stop can cut short.
;;;;
;;;; REV-0002 A7. AWAIT-VECTOR-BUILD and AWAIT-REPOSITORY-INDEX were identical
;;;; bodies of 69 tokens each, differing only in which accessor produced the
;;;; thread. SERVE-SLEEP and MONITOR-SLEEP were the identical slice loop
;;;; differing only in the stop predicate, one in synoptik-serve and one in
;;;; synoptik-workspace.

(in-package :synoptik-utils)

(defparameter *slice* 0.1
  "How long either wait below sleeps between checks.

One tenth of a second, and the same value in both because the two waits are
charged against the same thing: a stop request a human is waiting on. A longer
slice makes a stop take longer to notice and a shorter one spends more wakeups
to learn nothing.")

(defun await-thread (thread &optional (seconds 10))
  "Wait for THREAD, up to SECONDS. True when it is not running.

True for NIL and for a thread that has already finished, so a caller need not
distinguish `no build in flight\' from `a build that ended while we asked\'. The
NIL case is not a convenience: both synoptik-workspace callers read a slot that
holds a thread or nothing, and guarding at each of them was two chances to
forget.

THREE implementations were merged here, and the merge is why this joins rather
than polls. synoptik-workspace\'s two spun on THREAD-ALIVE-P every 100ms;
synoptik-serve\'s waited on SB-THREAD:JOIN-THREAD with a timeout, which is the same
answer without the wakeups. REV-0002 A7 found the first two and missed the
third: the survey scores names and docstrings, and `await a drain\' and `await a
build\' share neither.

The answer comes from THREAD-ALIVE-P after the join and not from the join\'s own
return value, which is the one behaviour that had to be preserved rather than
chosen. synoptik-serve read a :TIMED-OUT default as `still running\', correct for its
own caller, which then finishes the stop itself. For synoptik-workspace an index
thread that aborted has finished -- the build is over and there will not be
another -- and reading its abort as `still indexing\' would make every subsequent
request answer `still being indexed\' forever. Asking whether it is alive answers
both."
  (or (null thread)
      (not (bordeaux-threads:thread-alive-p thread))
      (progn
        ;; JOIN-THREAD's :TIMEOUT is a positive number or NIL, so a wait of
        ;; zero is no join at all. The callers that pass zero mean `do not
        ;; wait', and the polling loops this replaced answered that at once.
        ;; BUG-0076.
        #+sbcl (when (plusp seconds)
                 (sb-thread:join-thread thread :timeout seconds :default nil))
        #-sbcl (loop repeat (round (/ seconds *slice*))
                     do (sleep *slice*)
                     until (not (bordeaux-threads:thread-alive-p thread)))
        (not (bordeaux-threads:thread-alive-p thread)))))

(defun sleep-until (seconds stop-p)
  "SLEEP for SECONDS, in slices, abandoned as soon as STOP-P answers true.

A single long SLEEP would make every stop request wait out the interval for no
reason, which for a service under a supervisor is the difference between a clean
stop and a kill."
  (loop for remaining = seconds then (- remaining *slice*)
        while (and (plusp remaining) (not (funcall stop-p)))
        do (sleep (min *slice* remaining))))
