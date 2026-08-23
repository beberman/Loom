;;;; Tests for the embedder protocol.
;;;;
;;;; Nothing here opens a socket. FIXED-EMBEDDER exists so that the suite
;;;; passes on a machine with no ollama installed, which is what makes
;;;; REQ-0048 R6 testable at all -- a suite needing ollama up could not tell
;;;; "the absent-embedder path works" from "ollama happened to be running".

(in-package :loom-embed-test)

(def-suite protocol :in all-tests)
(in-suite protocol)

(defun dot (a b)
  (loop for i from 0 below (length a)
        sum (* (aref a i) (aref b i))))

(defun magnitude (v)
  (sqrt (loop for x across v sum (* x x))))

(test an-id-names-the-model-because-two-models-are-two-stores
  ;; DEC-0006's invariant, and the reason the protocol exists at all. Vectors
  ;; from two embedders are not comparable, a cosine between them is a number
  ;; with no property that marks it wrong, and this string is the only place
  ;; that fact is recoverable. An id that did not move with the model would let
  ;; a sidecar built by one be read by another and report nothing.
  (let ((a (make-ollama-embedder :model "nomic-embed-text"))
        (b (make-ollama-embedder :model "bge-m3")))
    (is (string= "ollama:nomic-embed-text" (embedder-id a)))
    (is (not (string= (embedder-id a) (embedder-id b)))
        "two models must not share a store")
    (is (string= (embedder-id a)
                 (embedder-id (make-ollama-embedder :model "nomic-embed-text")))
        "and the same model must, or every restart rebuilds")))

(test an-id-survives-the-host-moving
  ;; The host is where the vectors were computed, not what computed them.
  ;; Moving ollama to another port must not invalidate a store, because
  ;; nothing about the vectors changed.
  (is (string= (embedder-id (make-ollama-embedder :host "127.0.0.1:11434"))
               (embedder-id (make-ollama-embedder :host "127.0.0.1:9999")))))

(test every-vector-comes-back-unit-length
  ;; EMBED-TEXTS promises normalised vectors so a cosine is a dot product.
  ;; Normalising at the protocol rather than at each call site is what stops an
  ;; unnormalised vector reaching a dot-product loop, where it is not an error
  ;; but a silently wrong ordering.
  (let* ((e (make-fixed-embedder
             :dimensions 3
             :vectors '(("a" . #(3.0 0.0 0.0))
                        ("b" . #(0.0 4.0 0.0)))))
         (vectors (embed-texts e '("a" "b" "unseeded"))))
    (is (= 3 (length vectors)))
    (loop for v across vectors
          do (is (< (abs (- 1.0 (magnitude v))) 1e-5)
                 "~a is not unit length" v))
    (is (< (abs (dot (aref vectors 0) (aref vectors 1))) 1e-5)
        "orthogonal inputs stay orthogonal")))

(test a-zero-vector-is-returned-rather-than-divided-by
  ;; An embedder returning zeros has failed in a way this layer cannot
  ;; diagnose. Dividing would put NaNs in the store, and a NaN cosine does not
  ;; error -- it stops ordering, somewhere else, later.
  (let* ((e (make-fixed-embedder :dimensions 3
                                 :vectors '(("dead" . #(0.0 0.0 0.0)))))
         (v (aref (embed-texts e '("dead")) 0)))
    (is (= 3 (length v)))
    (is (every (lambda (x) (= x 0.0)) v)
        "zeros stay zeros rather than becoming NaN")))

(test texts-come-back-in-the-order-they-went-in
  ;; Positional pairing is the contract every caller relies on: the sidecar
  ;; builder against the definitions it enumerated, the seeder against its one
  ;; query. An embedder that reordered would corrupt a store rather than fail
  ;; it, and nothing downstream could detect that.
  (let* ((e (make-fixed-embedder
             :dimensions 3
             :vectors '(("first"  . #(1.0 0.0 0.0))
                        ("second" . #(0.0 1.0 0.0))
                        ("third"  . #(0.0 0.0 1.0)))))
         (vectors (embed-texts e '("first" "second" "third"))))
    (is (< 0.99 (aref (aref vectors 0) 0)))
    (is (< 0.99 (aref (aref vectors 1) 1)))
    (is (< 0.99 (aref (aref vectors 2) 2)))))

(test embedding-nothing-asks-nothing-and-returns-nothing
  ;; The sidecar builder's last batch is empty whenever the definition count
  ;; divides evenly by the batch size, and a round trip for a known answer is
  ;; latency nobody asked for.
  (let ((e (make-fixed-embedder)))
    (is (= 0 (length (embed-texts e '()))))))

(test an-unseeded-text-still-embeds
  ;; A fixture supplies the few vectors its test reasons about. Everything else
  ;; has to embed to something, or every test would have to enumerate a whole
  ;; corpus to ask about two entries of it.
  (let ((e (make-fixed-embedder :dimensions 4)))
    (let ((v (aref (embed-texts e '("never seeded")) 0)))
      (is (= 4 (length v)))
      (is (< (abs (- 1.0 (magnitude v))) 1e-5)))
    (is (< 0.999 (dot (aref (embed-texts e '("same")) 0)
                      (aref (embed-texts e '("same")) 0)))
        "and it embeds the same way twice, or a store could not be rebuilt")))

(test the-empty-string-does-not-embed-to-zeros
  ;; It would otherwise sit at cosine 0 from everything, which reads downstream
  ;; as a bug in whatever produced it rather than as an empty document.
  (let* ((e (make-fixed-embedder :dimensions 4))
         (v (aref (embed-texts e '("")) 0)))
    (is (< (abs (- 1.0 (magnitude v))) 1e-5))))

(test the-unavailable-condition-is-an-error-subtype
  ;; RULE-0004, restated as a test because it is the rule this tree has been
  ;; bitten by. A caller guarding with HANDLER-CASE over ERROR -- which is what
  ;; REQ-0048 R6's absent-embedder path will be -- does not catch a condition
  ;; defined as a direct subtype of CONDITION.
  (is (subtypep 'embedder-unavailable 'error))
  (is (eq :caught
          (handler-case (error 'embedder-unavailable :detail "nothing listening")
            (error () :caught))))
  (let ((condition (make-condition 'embedder-unavailable :detail "port refused")))
    (is (search "port refused" (embedder-unavailable-detail condition)))
    (is (search "port refused" (princ-to-string condition))
        "the report has to name the detail, or a log line says nothing")))

;;; ------------------------------------------------------------------
;;; Not asking again -- REQ-0048 R6
;;; ------------------------------------------------------------------

(defclass failing-embedder ()
  ((calls :initform 0 :accessor failing-embedder-calls)
   (fail :initarg :fail :initform t :accessor failing-embedder-fail))
  (:documentation "Fails on demand and counts how often it was reached."))

(defmethod embedder-id ((e failing-embedder)) "fixed:failing")
(defmethod embedder-dimensions ((e failing-embedder)) 3)
(defmethod embed-texts ((e failing-embedder) texts)
  (incf (failing-embedder-calls e))
  (if (failing-embedder-fail e)
      (error 'embedder-unavailable :detail "nothing listening")
      (map 'simple-vector (lambda (text) (declare (ignore text))
                            (loom-embed::normalise #(1.0 0.0 0.0)))
           (coerce texts 'list))))

(test a-remembered-failure-is-not-asked-again
  ;; The measurement this exists for: a call to an absent ollama costs 2001 ms
  ;; against a query that costs 0.01-0.09 s, so a bounded failure repeated per
  ;; query is still twenty times today's behaviour. R6 asks for today's.
  (let* ((inner (make-instance 'failing-embedder))
         (embedder (make-memoing-embedder inner)))
    (dotimes (i 5)
      (handler-case (embed-texts embedder '("anything"))
        (embedder-unavailable () nil)))
    (is (= 1 (failing-embedder-calls inner))
        "five queries must reach an absent embedder once, not five times")
    (is (= 4 (memoing-embedder-suppressed embedder))
        "and the other four are suppressed rather than merely fast")))

(test a-suppressed-call-still-signals
  ;; The caller's handling must not depend on whether the memo was warm. A
  ;; suppressed call that returned NIL would make the absent path two paths.
  (let ((embedder (make-memoing-embedder (make-instance 'failing-embedder))))
    (handler-case (embed-texts embedder '("first")) (embedder-unavailable () nil))
    (is (eq :signalled
            (handler-case (progn (embed-texts embedder '("second")) :returned)
              (embedder-unavailable () :signalled))))))

(test the-memo-expires-so-starting-ollama-later-works
  ;; A process-lifetime memo is simpler and never retries, so somebody who
  ;; starts ollama after Loom gets nothing until they restart the service --
  ;; which reads as Loom being broken rather than as a cache being cold.
  (let* ((inner (make-instance 'failing-embedder))
         (embedder (make-memoing-embedder inner :retry-after 0)))
    (handler-case (embed-texts embedder '("first")) (embedder-unavailable () nil))
    (setf (failing-embedder-fail inner) nil)
    (is (= 1 (length (embed-texts embedder '("second"))))
        "a window that has passed lets the next call through")
    (is (= 2 (failing-embedder-calls inner)))))

(test a-success-clears-the-memo
  (let* ((inner (make-instance 'failing-embedder))
         (embedder (make-memoing-embedder inner :retry-after 0)))
    (handler-case (embed-texts embedder '("a")) (embedder-unavailable () nil))
    (setf (failing-embedder-fail inner) nil)
    (embed-texts embedder '("b"))
    (setf (failing-embedder-fail inner) t)
    (handler-case (embed-texts embedder '("c")) (embedder-unavailable () nil))
    (is (= 3 (failing-embedder-calls inner))
        "each of the three reached the inner embedder, so nothing was stale")))

(test the-memo-passes-identity-through
  ;; A decorated embedder must key the same store as an undecorated one, or
  ;; wrapping it would invalidate every sidecar ever built.
  (let ((inner (make-ollama-embedder :model "nomic-embed-text")))
    (is (string= (embedder-id inner)
                 (embedder-id (make-memoing-embedder inner))))))
