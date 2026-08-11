;;;; A load that never returns -- REQ-0018's "a load that hangs on a DB
;;;; connect" without needing a database. No handler can catch this, which is
;;;; the point: only the clock can, and the parent has to survive the child
;;;; being killed under it with a whole unit still unaccounted for.

(defpackage #:fixture-hang
  (:use #:cl))

(in-package #:fixture-hang)

(loop (sleep 1))
