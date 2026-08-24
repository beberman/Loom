;;;; `find' across every watched repository.
;;;;
;;;; REQ-0051 and DES-0043. `find' took a repository designator and refused
;;;; without one, which is right for a call whose answer is a location and
;;;; wrong for the question nine watched trees generate constantly: which of
;;;; them owns this name. The measured cost of the refusal was four `grep'
;;;; calls where the answer was one search.
;;;;
;;;; This file is in loom-workspace because it is the only system that can hold
;;;; both halves. loom-knowledge is handed a graph and never learns which
;;;; repository it belongs to -- the same constraint DES-0027 D1 recorded for
;;;; DEFINITION-SOURCE. loom-serve holds REQUIRE-REPOSITORY, but loom-process
;;;; does not depend on it and DES-0006 R5 forbids acquiring the dependency, so
;;;; a search written there would be unreachable from the console, which is the
;;;; surface that answers with no service running. loom-workspace holds
;;;; *REPOSITORIES* and has depended on loom-knowledge since DES-0022 S3.
;;;;
;;;; Nothing here mutates. SEARCH-ENTITIES is a read, and the registry is
;;;; walked by ALL-REPOSITORIES without a lock, for the reason DES-0043 D5
;;;; states: a federated `find' that waited for one of nine trees would make
;;;; the cheapest command in Loom block on the slowest.

(in-package :loom-workspace)

(defun searchable-p (repository)
  "Whether REPOSITORY's graph can answer a lexical query now.

REPOSITORY-STATE's three values split two ways rather than three. :INDEXING is
a tree being read, whose graph would answer `nothing matches' with the same
words it uses when a name genuinely is absent. :EMBEDDING is a graph that is
built and answerable and whose vector store is not, and `find' is lexical, so
it is searched exactly as :READY is."
  (not (eq :indexing (repository-state repository))))

(defun repository-hits (repository term &key type limit)
  "SEARCH-ENTITIES against REPOSITORY, each row tagged with its tree.

Two values, as SEARCH-ENTITIES has since BUG-0002: the rows, and how many
matched before LIMIT cut the list. The tag is REQ-0051 R2 -- a row that does
not name its tree reads as a claim about one system, which is REQ-0027 R5's
rule applied to a band it did not cover."
  (multiple-value-bind (rows total)
      (search-entities (repository-graph repository)
                       :name term :type type :limit limit)
    (values (mapcar (lambda (row)
                      (list* :repository (repository-name repository) row))
                    rows)
            total)))

(defun search-repositories (term &key type limit repositories)
  "Every watched repository's answer to TERM, merged and ranked once.

Returns a plist:

    :entities   summaries, best match first, each carrying :REPOSITORY
    :total      matches before the limit, summed over what was searched
    :truncated  T when :TOTAL exceeds the rows returned
    :searched   ((:repository name :total n) ...), one per tree asked
    :skipped    ((:repository name :reason \"indexing\") ...), one per tree not
    :seconds    wall time for the whole search

Three lists rather than one, because they answer three different questions and
collapsing them loses the one REQ-0051 R4 is about: a repository with no match
is on :SEARCHED with a total of zero, and a repository that could not be asked
is on :SKIPPED. Without the second, a caller cannot tell `this name is in no
tree' from `this name is in no tree I looked at', and the first is a claim
strong enough that CON-0001 refuses to let a partial search make it.

Each tree is searched at the caller's own LIMIT rather than unlimited and cut
after the merge. SEARCH-ENTITIES summarizes only the slice it returns and takes
its total before truncating, so this costs one summarize of at most LIMIT rows
per tree and still yields each tree's true count. The merge stays correct
because NAME-SEARCH-RANK reads only a name and a type: a row in the merged
top-N is necessarily in its own repository's top-N, and a row its repository's
limit cut could not have survived the merged one.

Ties across repositories break by registration order, which is what
ALL-REPOSITORIES returns and STABLE-SORT preserves. Nothing here claims one
tree's definition is better than another's at equal rank."
  (let ((started (get-internal-real-time))
        (rows '())
        (searched '())
        (skipped '())
        (total 0))
    (dolist (repository (or repositories (all-repositories)))
      (if (searchable-p repository)
          (multiple-value-bind (hits count)
              (repository-hits repository term :type type :limit limit)
            (setf rows (append rows hits))
            (incf total count)
            (push (list :repository (repository-name repository) :total count)
                  searched))
          (push (list :repository (repository-name repository)
                      :reason (string-downcase (repository-state repository)))
                skipped)))
    (let* ((ranked (stable-sort rows #'<
                                :key (lambda (row)
                                       (name-search-rank (getf row :name)
                                                         (getf row :type)
                                                         term))))
           (shown (if limit (subseq ranked 0 (min limit (length ranked))) ranked)))
      (list :entities shown
            :total total
            :truncated (> total (length shown))
            :searched (nreverse searched)
            :skipped (nreverse skipped)
            :seconds (/ (float (- (get-internal-real-time) started))
                        internal-time-units-per-second)))))

(defun repositories-holding (term &key type exclude)
  "Which other watched trees hold TERM, as counts and nothing else.

REQ-0051 R3, and the clause the whole requirement is for: a search that named a
repository and found nothing there says what the others hold, in the same
answer, because the first answer is where the reader decides to reach for grep
instead.

A count and no rows. `:limit 0' makes SEARCH-ENTITIES' SUBSEQ return the empty
list, so SUMMARIZE-ENTITIES runs over nothing while the second value is still
the full count -- one FIND-ENTITIES walk per tree with no summarization. This
runs only when the named search found nothing, so the cost is paid on the miss
rather than on every `find'.

EXCLUDE names the repository already searched. A tree that is :INDEXING is left
out for SEARCHABLE-P's reason: a count read from a graph still being built
would be a smaller number reported as a fact."
  (loop for repository in (all-repositories)
        unless (or (and exclude
                        (string-equal exclude (repository-name repository)))
                   (not (searchable-p repository)))
          append (let ((count (nth-value 1 (search-entities
                                            (repository-graph repository)
                                            :name term :type type :limit 0))))
                   (when (plusp count)
                     (list (list :repository (repository-name repository)
                                 :total count))))))
