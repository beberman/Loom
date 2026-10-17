;;;; What indexing one repository costs: wall time, and heap with the index live.
;;;;
;;;;   sbcl --script tools/test/index-cost.lisp /path/to/repo [--ballast <MB>]
;;;;
;;;; DES-0055 D13's instrument, for PLAN-0060 steps 1, 2 and 6. D13 budgets the
;;;; cost of storing call shapes on front-end at +10% index time and +15% heap.
;;;; A budget needs a base measured the same way, so this runs before any
;;;; extractor changes and again after.
;;;;
;;;; One `name value' line per figure:
;;;;
;;;;   seconds               WATCH-REPOSITORY's wall time, from GET-INTERNAL-REAL-TIME.
;;;;                         The systems are loaded before the clock starts.
;;;;   heap-before-bytes     SB-KERNEL:DYNAMIC-USAGE after a full GC with the
;;;;                         systems loaded and nothing indexed. Not gated. It
;;;;                         is the image's own share, so the index's share is
;;;;                         heap-bytes less this.
;;;;   heap-bytes            the same reading with the index live: what D13 gates.
;;;;   entities, relationships, calls-edges
;;;;                         what the index holds. PLAN-0060 step 2 compares
;;;;                         calls-edges before and after :VIA.
;;;;   shape-occurrences     the line entries in every :CALL-SHAPES, which is
;;;;                         0 until PLAN-0060 step 3 writes the first one.
;;;;
;;;; --ballast allocates and retains that many megabytes before the heap
;;;; readings. It exists only as the positive control: a heap figure that does
;;;; not rise by the ballast is not measuring the heap (CON-0003). It indexes
;;;; the tree directly, with no monitor, no service and no vector store.

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil :defaults *load-truename*)))

(synoptik-harness:load-systems "tools/test/index-cost.lisp"
                           :systems '("utils/" "ontology/" "graph/" "analyzer/" "knowledge/"
                                      "docstore/" "workspace/" "embed/")
                           :libraries '("cl-yaml" "bordeaux-threads" "random-uuid" "eclector" "stem" "cl-json" "drakma")
                           :load :synoptik-workspace)

(defpackage #:synoptik-index-cost
  (:use #:cl #:synoptik-ontology #:synoptik-graph #:synoptik-workspace))
(in-package #:synoptik-index-cost)

(defvar *ballast* nil
  "The retained vector --ballast allocates. A special, so the GC cannot prove it dead.")

(defun shape-line-count (call-shapes)
  "The line entries in CALL-SHAPES, DES-0055 D11's ((key (signature line ...) ...) ...)."
  (loop for (nil . groups) in call-shapes
        sum (loop for (nil . lines) in groups sum (length lines))))

(defun calls-edge-count (graph)
  (count :calls (all-relationships graph) :key #'rel-type))

(defun shape-occurrence-count (graph)
  (loop for entity in (all-entities graph)
        sum (shape-line-count (gethash :call-shapes (properties entity)))))

(defun heap-bytes ()
  "Dynamic usage after a full collection. Twice, because a first pass can leave
objects only a finalizer or weak table had kept reachable."
  (sb-ext:gc :full t)
  (sb-ext:gc :full t)
  (sb-kernel:dynamic-usage))

(defun report (name value)
  (format t "~a ~a~%" name value))

(defun allocate-ballast (megabytes)
  (setf *ballast* (make-array (* megabytes 1024 1024) :element-type '(unsigned-byte 8)
                                                      :initial-element 1)))

(defun measure (root megabytes)
  (when megabytes (allocate-ballast megabytes))
  (let ((before (heap-bytes))
        (start (get-internal-real-time))
        (repository (watch-repository root :monitor nil :quiet t)))
    (let ((seconds (/ (- (get-internal-real-time) start)
                      (float internal-time-units-per-second))))
      (let ((after (heap-bytes))
            (graph (repository-graph repository)))
        (report "seconds" (format nil "~,3f" seconds))
        (report "heap-before-bytes" before)
        (report "heap-bytes" after)
        (report "entities" (length (all-entities graph)))
        (report "relationships" (length (all-relationships graph)))
        (report "calls-edges" (calls-edge-count graph))
        (report "shape-occurrences" (shape-occurrence-count graph))
        (finish-output)))))

(defun main ()
  "Read the command line and measure. A function rather than a top-level LET*,
because a call under a top-level LET* mints a :CALL-SITE (DES-0014) and
*CALL-SITE-CEILING* counts this script's."
  (let* ((arguments (rest sb-ext:*posix-argv*))
         (root (or (first arguments)
                   (error "Usage: sbcl --script tools/test/index-cost.lisp <repository-root> [--ballast <MB>]")))
         (flag (member "--ballast" arguments :test #'string=)))
    (measure root (and flag (parse-integer (or (second flag)
                                               (error "--ballast takes a number of megabytes")))))))

(main)
