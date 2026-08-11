;;;; Package definition for loom-rest: the HTTP/JSON skin.
;;;;
;;;; DES-0006: "No route's handler body contains logic beyond this five-step
;;;; shape" -- decode, resolve grants, invoke, encode, set the status. Every
;;;; name this system needs comes from loom-serve, and that is the check on
;;;; whether a piece of logic has drifted into the wrong system: a route
;;;; reaching for loom-graph or loom-knowledge would be a route doing work the
;;;; registry is supposed to have done.

(defpackage #:loom-rest
  (:use #:cl #:loom-serve)
  (:export
   #:*route-prefix*
   #:handle-request
   #:status-for
   #:request-arguments))
