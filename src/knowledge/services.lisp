;;;; Knowledge Services: the read side of the graph.
;;;; Implements the SS2 Knowledge Services box and the read-only tools of SS11.
;;;;
;;;; The queries themselves live in the Graph Manager (SS5.3, SS9). What this
;;;; layer adds is the shape an agent can use: locations it can open, paths it
;;;; can read, and plain data both LOOM-REST and LOOM-MCP can serve without
;;;; touching the graph again.
;;;;
;;;; The design test for everything here is the one the vision document sets:
;;;; tokens spent re-reading the same code. An answer that makes an agent open
;;;; a file to understand it has not earned its place -- which is why every
;;;; summary carries file and line range, and why impact paths name the
;;;; entities they ran through rather than just counting hops.

(in-package :loom-knowledge)

;;;; ==================================================================
;;;; Summaries -- the shared vocabulary of every answer
;;;; ==================================================================

(defun entity-location (entity)
  "ENTITY's source location as \"path:start-line-end-line\", or NIL.
The single most useful thing the graph can hand an agent: the exact region to
open, instead of a filename and a search."
  (let ((file  (or (getp entity :file) (getp entity :path)))
        (start (getp entity :start-line))
        (end   (getp entity :end-line)))
    (cond ((and file start end) (format nil "~a:~a-~a" file start end))
          ((and file start)     (format nil "~a:~a" file start))
          (file                 (format nil "~a" file))
          (t nil))))

(defun entity-summary (entity)
  "ENTITY as plain data: what it is, where it is, and how far to trust it.
Deliberately not the whole property table -- a summary an agent reads in bulk
should carry what is true of every entity, and DESCRIBE-ENTITY is where the
type-specific detail lives."
  (list :id        (id entity)
        :type      (entity-type entity)
        :name      (and (slot-boundp entity 'name) (name entity))
        :location  (entity-location entity)
        :language  (getp entity :language)
        :source    (source entity)
        :confidence (confidence entity)
        :stale     (and (stale-p entity) t)))

(defun summarize-entities (entities)
  (mapcar #'entity-summary entities))

;;;; ==================================================================
;;;; search-entities -- SS11 loom_find, "where is X defined"
;;;; ==================================================================

(defun significant-name (entity)
  "The part of ENTITY's name worth matching a task word against.

For most entities that is the whole name. For a :FILE, whose name is a path,
it is the basename without its extension -- \"graph/transaction.lisp\" matches
on \"transaction\", not on \"graph\". Without this, every word that happens to
name a directory prefix-matches every file beneath it, which outranks the
definitions the word was actually about."
  (let ((name (and (slot-boundp entity 'name) (name entity))))
    (when name
      (if (member (entity-type entity) '(:file :document))
          (let* ((slash (position #\/ name :from-end t))
                 (base  (if slash (subseq name (1+ slash)) name))
                 (dot   (position #\. base :from-end t)))
            (if (and dot (plusp dot)) (subseq base 0 dot) base))
          name))))

(defun match-rank (entity pattern)
  "How well ENTITY's name matches PATTERN: 0 exact, 1 prefix, 2 substring,
3 no match.
Ranking rather than filtering, because an agent asking for \"impact-set\" wants
IMPACT-SET first and IMPACT-SET-TRUNCATED-P second, not both in hash order."
  (let ((name (significant-name entity)))
    (cond ((null name) 3)
          ((string-equal name pattern) 0)
          ((and (<= (length pattern) (length name))
                (string-equal pattern name :end2 (length pattern))) 1)
          ((search pattern name :test #'char-equal) 2)
          (t 3))))

(defun search-entities (view &key name type limit property-filters)
  "Entities matching NAME (substring, case-insensitive) and TYPE, best match
first. Returns summaries."
  (let ((hits (find-entities view :entity-type type :name-like name
                                  :property-filters property-filters)))
    (when name
      (setf hits (stable-sort hits #'< :key (lambda (e) (match-rank e name)))))
    (summarize-entities (if limit (subseq hits 0 (min limit (length hits))) hits))))

;;;; ==================================================================
;;;; describe-entity -- SS11 loom_describe
;;;; ==================================================================

(defun neighbor-summary (n)
  (list :direction (neighbor-direction n)
        :rel-type  (rel-type (neighbor-relationship n))
        :stale     (and (stale-p (neighbor-relationship n)) t)
        :entity    (entity-summary (neighbor-entity n))))

(defun group-neighbors (neighbors)
  "Neighbours grouped by relationship type and direction, so an answer reads
as \"calls: these; called-by: those\" rather than as a flat edge dump."
  (let ((groups '()))
    (dolist (n neighbors)
      (let* ((key  (list (neighbor-direction n) (rel-type (neighbor-relationship n))))
             (cell (or (assoc key groups :test #'equal)
                       (car (push (cons key '()) groups)))))
        (push (entity-summary (neighbor-entity n)) (cdr cell))))
    (loop for (key . entities) in (reverse groups)
          collect (list :direction (first key)
                        :rel-type  (second key)
                        :entities  (reverse entities)))))

(defun describe-entity (view id)
  "Full detail for one entity: its own properties plus its neighbours grouped
by edge type -- the \"tell me about this function\" call. NIL when ID is
unknown."
  (let ((entity (get-entity view id)))
    (when entity
      (list :entity     (entity-summary entity)
            :properties (loop for key being the hash-keys of (properties entity)
                                using (hash-value value)
                              unless (null value) append (list key value))
            :neighbors  (group-neighbors (neighbors view id))))))

;;;; ==================================================================
;;;; impact-report -- SS11 loom_impact
;;;; ==================================================================

(defun render-path (view path)
  "An impact path as the names it ran through: \"calls>apply-op calls>plan-op\".
SS9 requires the path be carried; a chain of entity names is what makes it
usable, because an agent can see *why* something is impacted and judge whether
that reason matters."
  (format nil "~{~a~^ ~}"
          (loop for hop in path
                for entity = (get-entity view (hop-entity-id hop))
                collect (format nil "~(~a~)>~a" (hop-rel-type hop)
                                (if (and entity (slot-boundp entity 'name))
                                    (name entity)
                                    (hop-entity-id hop))))))

(defun impact-entry-summary (view entry)
  (append (entity-summary (impact-entry-entity entry))
          (list :depth (impact-entry-depth entry)
                :via   (render-path view (impact-entry-path entry)))))

(defun impact-report (view id &key (max-depth *default-impact-depth*)
                                   (include-tests t) (include-docs t))
  "What changing the entity ID may require attention to, as plain data.
NIL when ID is unknown."
  (let ((result (impact-set view id :max-depth max-depth
                                    :include-tests include-tests
                                    :include-docs include-docs)))
    (when result
      (list :seed      (entity-summary (impact-result-seed result))
            :count     (length (impact-result-impacted result))
            :truncated (and (impact-result-truncated-p result) t)
            :impacted  (loop for entry in (impact-result-impacted result)
                             collect (impact-entry-summary view entry))
            :tests     (summarize-entities (impact-result-tests result))
            :documents (summarize-entities (impact-result-documents result))
            :decisions (summarize-entities (impact-result-decisions result))
            :possibly-affected
            (summarize-entities (impact-result-possibly-affected result))))))
