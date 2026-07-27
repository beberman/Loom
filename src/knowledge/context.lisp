;;;; Context building -- SS11's loom_context.
;;;;
;;;; "loom_context is the tool that directly attacks the original problem
;;;; statement -- tokens wasted re-reading the same code."
;;;;
;;;; SS11 specifies both the algorithm and the discipline. The algorithm: "seed
;;;; entities from the task text via name matching, expand one hop, include
;;;; non-stale decisions touching those entities, truncate to budget." The
;;;; discipline: "it should be instrumented from day one: logging what agents
;;;; asked for and what they got is exactly the feedback that tells us whether
;;;; the graph is earning its keep." Both are here, and the second is the more
;;;; important of the two -- a context tool nobody can measure is a context
;;;; tool nobody can improve.

(in-package :loom-knowledge)

;;;; ==================================================================
;;;; Budget
;;;; ==================================================================

(defparameter *context-token-budget* 2000
  "Default size of a context bundle, in tokens.")

(defun estimate-tokens (string)
  "A rough token count for STRING: four characters to the token.

Deliberately crude. Loom has no tokenizer and should not grow one to spend a
budget approximately -- the number exists to stop a bundle running away, not
to fill it exactly. Swap this for a real count when a caller needs the budget
honoured to the token."
  (ceiling (length string) 4))

;;;; ==================================================================
;;;; Seeding from task text
;;;; ==================================================================

(defparameter *context-stopwords*
  '("the" "and" "for" "with" "that" "this" "from" "into" "when" "what" "which"
    "add" "new" "use" "using" "make" "get" "set" "fix" "change" "update" "code"
    "function" "class" "file" "test" "tests" "should" "would" "need" "needs"
    "want" "please" "can" "does" "how" "why" "where" "are" "was" "will" "not"
    "its" "have" "has" "had" "them" "they" "then" "than")
  "Words too common to be worth matching an entity name against.
Not a language model -- just enough that \"how does the drawing tool work\"
seeds on \"drawing\" and \"tool\" rather than on \"does\" and \"work\".")

(defun task-tokens (task)
  "The candidate identifiers in TASK: words and hyphenated or underscored
compounds, lowercased, three characters or more, stopwords dropped.

Compounds are kept whole *and* split, so \"impact-set\" seeds on the exact
name and, failing that, on \"impact\"."
  (let ((tokens '())
        (current (make-string-output-stream)))
    (flet ((finish ()
             (let ((word (string-downcase (get-output-stream-string current))))
               (when (and (>= (length word) 3)
                          (not (member word *context-stopwords* :test #'string=)))
                 (pushnew word tokens :test #'string=)
                 ;; a compound also seeds on its parts
                 (let ((start 0))
                   (dotimes (i (1+ (length word)))
                     (when (or (= i (length word))
                               (member (char word i) '(#\- #\_)))
                       (let ((part (subseq word start i)))
                         (when (and (>= (length part) 3)
                                    (not (member part *context-stopwords* :test #'string=)))
                           (pushnew part tokens :test #'string=)))
                       (setf start (1+ i)))))))))
      (loop for char across task
            do (if (or (alphanumericp char) (member char '(#\- #\_ #\* #\%)))
                   (write-char char current)
                   (finish))
            finally (finish)))
    (nreverse tokens)))

(defparameter *seed-type-preference*
  '(:function :method :class :interface :concept :decision :rule
    :variable :test :module :package :document :file)
  "Entity types in the order a seed match is worth having.

Definitions first, containers last, and this ordering earns its keep: a task
mentioning \"the graph manager\" matches the *file* graph-manager.lisp on the
word \"graph\" as readily as it matches any function in it, and a file's
neighbourhood is every definition it holds. Seeded on the file, a bundle
spends its whole budget listing a directory back at the agent. Seeded on the
definitions, it spends it on code.")

(defun seed-type-rank (entity)
  (or (position (entity-type entity) *seed-type-preference*)
      (length *seed-type-preference*)))

(defun seed-entities (view task &key (limit 8) types)
  "Entities whose names the words of TASK point at, best match first.

The naive half of SS11's \"first implementation is simple\", and the half most
obviously worth replacing: name matching finds RESOLVE-OVERLAY from the word
\"overlay\" and finds nothing at all from \"the bit that merges edits\".
Semantic seeding is what Qdrant is for in the target architecture."
  (let ((tokens (task-tokens task))
        (found '()))
    (dolist (token tokens)
      (dolist (entity (find-entities view :name-like token))
        (when (or (null types) (member (entity-type entity) types))
          (pushnew entity found))))
    ;; Type preference dominates, match quality breaks its ties -- the reverse
    ;; of what SEARCH-ENTITIES does, and deliberately so. loom_find answers
    ;; "where is this thing", where an exactly-named file is the right answer.
    ;; A context bundle answers "what should I know before editing", where a
    ;; function matched loosely is worth more than a file matched exactly: the
    ;; file's neighbourhood is a directory listing, the function's is the code
    ;; that will break.
    (let ((scored (loop for entity in found
                        for match = (reduce #'min tokens
                                            :key (lambda (token) (match-rank entity token))
                                            :initial-value 3)
                        unless (= match 3)   ; matched only on a path component
                          collect (cons entity (+ (* 100 (seed-type-rank entity)) match)))))
      (let ((ranked (mapcar #'car (stable-sort scored #'< :key #'cdr))))
        (subseq ranked 0 (min limit (length ranked)))))))

;;;; ==================================================================
;;;; Instrumentation (SS11)
;;;; ==================================================================

(defstruct (context-log-entry (:conc-name context-log-))
  "One answered context request: what was asked, and what came back."
  (at (get-universal-time))
  (task "")
  (seeds 0)
  (entities 0)
  (budget 0)
  (tokens 0))

(defvar *context-log* '()
  "Answered context requests, most recent first.

SS11 asks for this from day one. It is the only evidence that will settle
whether the graph is earning its keep: a log full of requests that seeded on
nothing says name matching is not enough, and a log of bundles that never
approach their budget says the expansion is too timid.")

(defun clear-context-log ()
  (setf *context-log* '())
  (values))

(defun context-log-summary ()
  "The log as plain data: how many requests, how many found nothing, and how
much of the budget a bundle typically used."
  (let ((n (length *context-log*)))
    (list :requests n
          :seeded-nothing (count 0 *context-log* :key #'context-log-seeds)
          :mean-entities (if (zerop n) 0
                             (round (reduce #'+ *context-log* :key #'context-log-entities)
                                    n))
          :mean-budget-used
          (if (zerop n) 0
              (round (* 100 (/ (reduce #'+ *context-log* :key #'context-log-tokens)
                               (max 1 (reduce #'+ *context-log* :key #'context-log-budget)))))))))

;;;; ==================================================================
;;;; The bundle
;;;; ==================================================================

(defun decisions-touching (view entities)
  "Non-stale architecture decisions bearing on ENTITIES.
The part of a bundle that cannot be recovered by reading the source, and so
the part most worth the tokens: why the code is the way it is."
  (let ((found '()))
    (dolist (entity entities)
      (dolist (n (neighbors view (id entity)
                            :rel-types '(:decides :applies-to :documents)
                            :direction :in))
        (let ((other (neighbor-entity n)))
          (when (and (member (entity-type other) '(:decision :rule :concept))
                     (not (stale-p other)))
            (pushnew other found)))))
    (nreverse found)))

(defparameter *context-relation-limit* 12
  "Most relationships to list for one entity in a bundle.

A cap, not a preference. Entities are not uniformly connected -- a function
has a handful of neighbours and a file has one per definition it holds -- and
without a cap a single well-connected entity consumes a bundle that was meant
to describe eight.")

(defun context-item (view entity &key (relations t))
  "One entity as a context line plus, optionally, its immediate relationships."
  (let* ((all (when relations (neighbors view (id entity))))
         (shown (if (> (length all) *context-relation-limit*)
                    (subseq all 0 *context-relation-limit*)
                    all)))
    (list :entity (entity-summary entity)
          :relation-count (length all)
          :relations
          (loop for n in shown
                collect (list :direction (neighbor-direction n)
                              :rel-type (rel-type (neighbor-relationship n))
                              :name (let ((e (neighbor-entity n)))
                                      (and (slot-boundp e 'name) (name e))))))))

(defun build-context (view task &key (budget *context-token-budget*)
                                     (seed-limit 8) types)
  "A budgeted context bundle for TASK: the entities its words point at, their
immediate relationships, and the decisions bearing on them.

SS11's algorithm, in order -- seed by name, expand one hop, add non-stale
decisions, truncate to budget. Items are added cheapest-first within each
band, so a bundle that runs out of room loses distant neighbours rather than
the entities the task actually named.

Every call is logged to *CONTEXT-LOG*."
  (let* ((seeds     (seed-entities view task :limit seed-limit :types types))
         (expanded  (let ((out '()))
                      (dolist (entity seeds)
                        (dolist (n (neighbors view (id entity)))
                          (let ((other (neighbor-entity n)))
                            (unless (or (member other seeds) (stale-p other))
                              (pushnew other out)))))
                      (nreverse out)))
         (decisions (decisions-touching view (append seeds expanded)))
         (items     '())
         (used      0)
         (truncated nil))
    (flet ((admit (entity relations)
             (let* ((item (context-item view entity :relations relations))
                    (cost (estimate-tokens (princ-to-string item))))
               (cond ((<= (+ used cost) budget)
                      (incf used cost)
                      (push item items)
                      t)
                     (t (setf truncated t) nil)))))
      (dolist (entity seeds)     (admit entity t))
      (dolist (entity decisions) (admit entity nil))
      (dolist (entity expanded)  (admit entity nil)))
    (let ((bundle (list :task task
                        :seeds (summarize-entities seeds)
                        :items (reverse items)
                        :decisions (summarize-entities decisions)
                        :budget budget
                        :tokens used
                        :truncated truncated)))
      (push (make-context-log-entry :task task
                                    :seeds (length seeds)
                                    :entities (length items)
                                    :budget budget
                                    :tokens used)
            *context-log*)
      bundle)))

;;;; ==================================================================
;;;; Rendering -- what an agent actually reads
;;;; ==================================================================

(defun render-context (bundle)
  "BUNDLE as the text block an agent receives.

Kept next to the builder rather than in LOOM-MCP because the rendering is
where the token budget is really spent, and a bundle whose data is compact but
whose text is not has not saved anybody anything."
  (with-output-to-string (out)
    (format out "~&# Context for: ~a~%" (getf bundle :task))
    (format out "~&# ~d entities, ~~~d/~d tokens~@[ (truncated)~]~2%"
            (length (getf bundle :items)) (getf bundle :tokens)
            (getf bundle :budget) (getf bundle :truncated))
    (when (null (getf bundle :items))
      (format out "No indexed entity matched this task.~%"))
    (dolist (item (getf bundle :items))
      (let ((entity (getf item :entity)))
        (format out "~&~(~a~) ~a~@[  [~a]~]~@[  (stale)~]~%"
                (getf entity :type) (getf entity :name)
                (getf entity :location) (getf entity :stale))
        (dolist (rel (getf item :relations))
          (format out "    ~a ~(~a~) ~a~%"
                  (if (eq :out (getf rel :direction)) "->" "<-")
                  (getf rel :rel-type) (getf rel :name)))
        (let ((hidden (- (or (getf item :relation-count) 0)
                         (length (getf item :relations)))))
          (when (plusp hidden)
            (format out "    ... ~d more~%" hidden)))))))
