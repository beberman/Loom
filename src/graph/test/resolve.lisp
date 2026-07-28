;;;
;;; Tests for src/graph/resolve.lisp -- cross-file call resolution (SS8.3).
;;;

(in-package :loom-graph-test)

(def-suite resolve
  :in all-tests
  :description "RESOLVE-CALLS turning recorded unresolved names into edges.")

(in-suite resolve)

(defun r-function (graph name file &key unresolved)
  ;; UNRESOLVED names the analyzer's output, which is :CALL-NAMES: the names
  ;; this file does not define. Whether they resolve is what RESOLVE-CALLS
  ;; decides, and it writes that verdict to :UNRESOLVED-CALLS.
  (let ((e (make-instance 'function-entity :name name :origin-file file
                          :properties (properties-table
                                       (list :file file :start-line 1 :end-line 5
                                             :language :lisp
                                             :call-names unresolved)))))
    (add-entity graph e)
    e))

(test resolve-links-a-call-to-a-definition-in-another-file
  (let* ((g (make-graph))
         (caller (r-function g "analyze-tree" "a.lisp" :unresolved '("analyze-path")))
         (callee (r-function g "analyze-path" "b.lisp")))
    (apply-transaction g (resolve-calls g))
    (is (equal (list (id callee))
               (mapcar #'to-id (relationships-from g (id caller) :rel-type :calls)))
        "the edge the analyzer could not see across a file boundary")))

(test resolve-records-what-did-not-link-without-consuming-what-did
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee" "external-thing"))))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (is (equal '("external-thing") (getp caller :unresolved-calls))
        "what resolved becomes an edge; what did not stays an honest record")
    (is (equal '("callee" "external-thing") (getp caller :call-names))
        "and what the analyzer saw is left intact, because the next pass has
to be able to ask the same question again")))

(test a-resolved-edge-is-rebuilt-after-its-callee-is-retracted
  ;; The cross-file half of SS5.4's reanalysis, at the smallest possible scale.
  ;; Retracting b.lisp destroys the edge into it; a.lisp is not reanalyzed, so
  ;; nothing but a's own record can put the edge back. RESOLVE-CALLS used to
  ;; consume that record on the first pass, which made this unrecoverable.
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee"))))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (is (= 1 (length (relationships-from g (id caller) :rel-type :calls)))
        "resolved once")
    (apply-transaction g (list (retract-file "b.lisp" nil)))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "and the retract takes the edge with it")
    (let ((callee (r-function g "callee" "b.lisp")))
      (declare (ignore callee))
      (apply-transaction g (resolve-calls g))
      (is (= 1 (length (relationships-from g (id caller) :rel-type :calls)))
          "resolution rebuilds it, which it can only do because a.lisp still
records that it calls something named callee"))))

(test resolve-leaves-a-genuinely-external-call-alone
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("hunchentoot-start"))))
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls)))
    (is (equal '("hunchentoot-start") (getp caller :unresolved-calls)))))

(test resolve-refuses-to-guess-between-two-definitions-of-a-name
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("run"))))
    (r-function g "run" "b.lisp")
    (r-function g "run" "c.lisp")
    (apply-transaction g (resolve-calls g))
    (is (null (relationships-from g (id caller) :rel-type :calls))
        "picking one would be a fabricated edge; asserting both would be worse")
    (is (equal '("run") (getp caller :unresolved-calls)))))

(test resolve-does-not-link-a-function-to-itself
  (let ((g (make-graph)))
    (let ((f (r-function g "recurse" "a.lisp" :unresolved '("recurse"))))
      (apply-transaction g (resolve-calls g))
      (is (null (relationships-from g (id f) :rel-type :calls))))))

(test resolve-is-idempotent
  (let ((g (make-graph)))
    (r-function g "caller" "a.lisp" :unresolved '("callee"))
    (r-function g "callee" "b.lisp")
    (apply-transaction g (resolve-calls g))
    (let ((edges (length (all-relationships g))))
      (apply-transaction g (resolve-calls g))
      (is (= edges (length (all-relationships g)))
          "safe to run after every analysis pass")
      (is (= 1 edges)))))

(test resolution-is-what-makes-impact-cross-a-file-boundary
  (let* ((g (make-graph))
         (caller (r-function g "caller" "a.lisp" :unresolved '("callee")))
         (callee (r-function g "callee" "b.lisp")))
    (is (null (impact-result-impacted (impact-set g (id callee))))
        "before resolution, changing callee looks like it affects nothing")
    (apply-transaction g (resolve-calls g))
    (is (equal (list (name caller))
               (mapcar (lambda (e) (name (impact-entry-entity e)))
                       (impact-result-impacted (impact-set g (id callee)))))
        "after it, the question has an answer")))
