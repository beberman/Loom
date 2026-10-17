;;;; Package definition for synoptik-rest: the HTTP/JSON skin.
;;;;
;;;; DES-0006: "No route's handler body contains logic beyond this five-step
;;;; shape" -- decode, resolve grants, invoke, encode, set the status. Every
;;;; name this system needs comes from synoptik-serve, and that is the check on
;;;; whether a piece of logic has drifted into the wrong system: a route
;;;; reaching for synoptik-graph or synoptik-knowledge would be a route doing work the
;;;; registry is supposed to have done.

(defpackage #:synoptik-rest
  (:use #:cl #:synoptik-serve)
  (:export
   #:*route-prefix*
   #:handle-request
   #:status-for
   #:request-arguments))
