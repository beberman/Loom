;;;
;;; Tests for src/workspace/federate.lisp -- cross-repository edges (DES-0025,
;;; REQ-0027).
;;;
;;; This file exists because BUG-0034 found that nothing tested this pass at
;;; all, and the defect it found is one only a *second* invocation can show:
;;; FEDERATE-REPOSITORIES retracts every federated edge it holds before
;;; re-deriving them, and the first pass holds none. A suite that ran the pass
;;; once would have passed on a mechanism that was rejected whole every time it
;;; ran for real.
;;;
;;; Synthetic repositories rather than trees on disk. The pass reads route
;;; claims off :FUNCTION entities and nothing else, so a graph built by hand
;;; exercises exactly what a filesystem fixture would and costs no I/O.
;;; SHORT-COMMIT asks git about the root and answers NIL where it cannot,
;;; which is the same answer it gives for a checkout without git.
;;;

(in-package :loom-workspace-test)

(def-suite federate
  :in all-tests
  :description "Cross-repository :SERVES edges, and the retraction that keeps
them derivable rather than accumulated.")

(in-suite federate)

(defun fed-endpoint (name file route role)
  (make-instance 'function-entity :name name :origin-file file
                 :properties (properties-table
                              (list :file file :start-line 1 :end-line 5
                                    :language :lisp
                                    :routes (list route)
                                    :route-role role))))

(defun fed-repository (name endpoint)
  "A repository whose graph holds one route-claiming function."
  (let ((repository (loom-workspace::make-repository
                     :root (user-homedir-pathname) :name name)))
    (add-entity (repository-graph repository) endpoint)
    repository))

(defun federated-edges (repository)
  (remove-if-not #'federated-edge-p
                 (all-relationships (repository-graph repository))))

(defmacro with-federation ((server client) &body body)
  "Two repositories claiming one route, as the only ones federation can see."
  `(let* ((,server (fed-repository "fed-server"
                                   (fed-endpoint "get-game" "server/api.lisp"
                                                 "/api/game" :publishes)))
          (,client (fed-repository "fed-client"
                                   (fed-endpoint "fetchGame" "src/api.js"
                                                 "/api/game" :consumes)))
          (*repositories* (list ,server ,client)))
     ,@body))

(test one-pass-draws-the-edge-the-two-claims-agree-on
  (with-federation (server client)
    (declare (ignore client))
    (federate-repositories :quiet t)
    (is (= 1 (length (federated-edges server)))
        "the edge is stored in the publisher's graph and runs publisher ->
consumer, which is REQ-0027 R6's traversal")
    (is (null (repository-errors server)))))

(test a-second-pass-retracts-and-re-derives-rather-than-being-rejected
  ;; BUG-0034, and the only shape that shows it. The first pass has nothing to
  ;; retract; the second builds a RETRACT-OP per federated edge, and until
  ;; RETRACT-OP could name a relationship every one of them reported "cannot
  ;; retract unknown entity" and took the whole transaction -- so the
  ;; cross-repository edges froze at whatever the first pass happened to draw
  ;; and every later index reported the rejection.
  (with-federation (server client)
    (declare (ignore client))
    (federate-repositories :quiet t)
    (let ((after-first (length (federated-edges server))))
      (federate-repositories :quiet t)
      (is (null (repository-errors server))
          "the pass that retracts is the pass that used to fail")
      (is (= after-first (length (federated-edges server)))
          "and it holds the same edges rather than accumulating or losing them"))))

(test many-passes-neither-accumulate-nor-erode
  ;; DEC-0003's derive-never-consume, measured. The pass rebuilds its whole
  ;; output every run, so the count is a function of the two trees and not of
  ;; how many times anything has been indexed.
  (with-federation (server client)
    (declare (ignore client))
    (dotimes (i 4) (federate-repositories :quiet t))
    (is (= 1 (length (federated-edges server))))
    (is (null (repository-errors server)))))

(test a-claim-that-goes-away-takes-its-edge-with-it
  ;; What the retraction is *for*, and what was inert while it was rejected:
  ;; REQ-0027 R2 says a retraction here cannot leave a dangling edge there.
  (with-federation (server client)
    (federate-repositories :quiet t)
    (is (= 1 (length (federated-edges server))))
    (let ((graph (repository-graph client)))
      (dolist (e (entities-of-type graph :function))
        (remove-entity graph (id e))))
    (federate-repositories :quiet t)
    (is (null (federated-edges server))
        "the client no longer claims the route, so the edge is gone")
    (is (null (repository-errors server)))))

(defun fed-claims (repository role &rest routes)
  "Add one route-claiming function to REPOSITORY per route in ROUTES."
  (loop for route in routes
        for n from 0
        do (add-entity (repository-graph repository)
                       (fed-endpoint (format nil "~a-~d" role n)
                                     (format nil "api/~(~a~)-~d.lisp" role n)
                                     route role))))

(test the-unmatched-sets-agree-with-the-lists-the-report-returns
  ;; BUG-0038, and the same destructive-sort defect BUG-0037 fixed in
  ;; SEED-ENTITIES. FEDERATION-REPORT built its plist in one LIST form, whose
  ;; arguments are evaluated left to right: CL:SORT consumed PUBLISHED and
  ;; MATCHED in the first three slots, leaving each naming the sorted list from
  ;; its old head onwards, and the SET-DIFFERENCE in the last two then worked
  ;; over a suffix of the claims against a suffix of the matches. REQ-0027 R3's
  ;; dropped claim, produced by the function whose docstring says it exists to
  ;; prevent one.
  ;;
  ;; Six published routes because the loss needs a list whose head sorts away
  ;; from the front, and WITH-FEDERATION's one route each cannot show it: SORT
  ;; returns a one-element list unchanged and the variable still names all of
  ;; it. MAPHASH over the server's claims yields "/api/deck" last, so PUSHNEW
  ;; makes it the head and the sort moves it to second; without the fix
  ;; PUBLISHED then names five of the six and "/api/board" -- which no client
  ;; consumes -- goes missing from `unmatched-published'. The route matched at
  ;; both ends is deliberately not the one that sorts first, because a lost
  ;; route that is in MATCHED anyway is subtracted either way and the report
  ;; comes out right by accident.
  ;;
  ;; The assertions compare the report against itself rather than against a
  ;; literal, so a change to the fixture cannot make them vacuous -- the same
  ;; reason THE-COUNTS-AGREE-WITH-THE-LIST-THEY-COUNT does in loom-knowledge.
  (let* ((server (fed-repository "fed-many-server"
                                 (fed-endpoint "get-game" "server/api.lisp"
                                               "/api/game" :publishes)))
         (client (fed-repository "fed-many-client"
                                 (fed-endpoint "fetchGame" "src/api.js"
                                               "/api/game" :consumes)))
         (*repositories* (list server client)))
    (fed-claims server :publishes "/api/zone" "/api/board" "/api/player"
                       "/api/match" "/api/deck")
    (fed-claims client :consumes "/api/ghost")
    (federate-repositories :quiet t)
    (let* ((report (federation-report))
           (published (getf report :published))
           (consumed (getf report :consumed))
           (matched (getf report :matched)))
      (is (= 6 (length published))
          "every published claim survives into the report, not a suffix of them")
      (is (= 2 (length consumed)))
      (is (= 1 (length matched))
          "/api/game is the one route claimed at both ends")
      ;; COPY-LIST for the same reason the fix has one: SET-DIFFERENCE may
      ;; share structure with PUBLISHED, and sorting the difference in place
      ;; would damage the list the assertion below reads.
      (let ((expected-published
              (sort (copy-list (set-difference published matched :test #'string=))
                    #'string<))
            (expected-consumed
              (sort (copy-list (set-difference consumed matched :test #'string=))
                    #'string<)))
        (is (equal expected-published (getf report :unmatched-published))
            "unmatched-published ~a against ~a"
            (getf report :unmatched-published) expected-published)
        (is (equal expected-consumed (getf report :unmatched-consumed))
            "unmatched-consumed ~a against ~a"
            (getf report :unmatched-consumed) expected-consumed)))))

(test a-repository-does-not-federate-with-itself
  ;; One repository claiming both ends is an ordinary edge's business, not this
  ;; pass's, and the guard is worth a test because the loop that skips it also
  ;; drives the retraction above.
  (let* ((repository (fed-repository "fed-alone"
                                     (fed-endpoint "get-game" "server/api.lisp"
                                                   "/api/game" :publishes)))
         (*repositories* (list repository)))
    (add-entity (repository-graph repository)
                (fed-endpoint "fetch-game" "server/client.lisp"
                              "/api/game" :consumes))
    (federate-repositories :quiet t)
    (is (null (federated-edges repository)))
    (is (null (repository-errors repository)))))
