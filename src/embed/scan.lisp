;;;; Finding the nearest vectors in a store.
;;;;
;;;; PLAN-0043 S4. Every vector in a store is unit length -- EMBED-TEXTS
;;;; normalises before anything else sees one -- so a cosine is a dot product
;;;; and this file contains no division and no square root.
;;;;
;;;; The cost is worth stating because it decides where the work goes. A scan
;;;; of Synoptik's own store is 1655 by 768, about 1.27 million multiply-adds.
;;;; Measured on that store: 21.76 ms with no declarations and 0.87 ms declared,
;;;; against a 31 ms median for the one embedding call that has to precede it.
;;;; So the scan is a fifteenth of the query's added cost and the arithmetic
;;;; here is not where a latency problem would come from.

(in-package :synoptik-embed)

(deftype float-vector ()
  "The array type every vector in a store and every query vector has."
  '(simple-array single-float (*)))

(declaim (ftype (function (float-vector float-vector fixnum fixnum) single-float)
                dot-at))

(defun dot-at (flat query row dimensions)
  "The dot product of QUERY with the vector at ROW of the flat array FLAT.

The OPTIMIZE is local rather than a file-level DECLAIM. At safety 0 an index
out of range corrupts memory instead of signalling, and confining that to one
function keeps the property where the bounds have already been established --
LOAD-VECTOR-STORE has checked that the file holds exactly COUNT * DIMENSIONS
floats, and NEAREST checks the query's width against the store's. A DECLAIM
would extend the same licence to every function compiled after it, including
ones whose inputs came straight off a disk."
  (declare (type float-vector flat query)
           (type fixnum row dimensions)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (let ((sum 0.0)
        (base (the fixnum (* row dimensions))))
    (declare (type single-float sum) (type fixnum base))
    (dotimes (i dimensions sum)
      (declare (type fixnum i))
      (incf sum (* (aref flat (the fixnum (+ base i))) (aref query i))))))

(defun nearest (store query limit)
  "The LIMIT nearest entities in STORE to QUERY, best first.

An alist of (entity-id . cosine). Fewer than LIMIT when the store holds fewer,
and NIL when the store is empty or the query is the wrong width -- a query of
the wrong width is a caller pairing an embedder with a store some other
embedder wrote, which LOAD-VECTOR-STORE is supposed to have refused, so
returning nothing is the second guard on the same mistake.

The result is small and allocating it is the only consing here: the scan
touches the store in place and keeps LIMIT candidates. An insertion into a list
of eight is cheaper than a heap and cheaper than sorting 1655 scores, and the
whole of it is 0.87 ms."
  (let ((flat (vector-store-vectors store))
        (count (vector-store-count store))
        (dimensions (vector-store-dimensions store)))
    (when (and (plusp count)
               (plusp limit)
               (= (length query) dimensions)
               (typep query 'float-vector))
      (let ((best '()))                 ; (score . row), best first, at most LIMIT
        (dotimes (row count)
          (let ((score (dot-at flat query row dimensions)))
            (when (or (< (length best) limit)
                      (> score (car (car (last best)))))
              (setf best (merge 'list best (list (cons score row))
                                #'> :key #'car))
              (when (> (length best) limit)
                (setf best (subseq best 0 limit))))))
        (loop for (score . row) in best
              collect (cons (vector-store-entity-id store row) score))))))
