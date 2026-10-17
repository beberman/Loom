;;;; Package definition for the Synoptik process: command loop and lifecycle.
;;;;
;;;; SS3.1: "The process presents three interfaces onto the same live image.
;;;; Standard input and output belong to the command loop, the developer's
;;;; console. An HTTP listener on localhost serves the REST API and the MCP
;;;; endpoint. And the Lisp REPL sits one command away behind the console, for
;;;; when the other two are not enough."
;;;;
;;;; Two of the three are here. The HTTP listener belongs to synoptik-rest and
;;;; synoptik-mcp, which do not exist yet; the console and the REPL escape do, and
;;;; between them they are enough to use the knowledge engine.

(defpackage #:synoptik-process
  (:use #:cl #:synoptik-utils #:synoptik-ontology #:synoptik-graph #:synoptik-analyzer #:synoptik-workspace
        #:synoptik-knowledge)
  (:export
   ;; entry points
   #:main
   #:console
   #:run-command

   ;; the command table
   #:*commands*
   #:define-command
   #:command
   #:command-name
   #:command-usage
   #:command-summary

   ;; supervision (SS3.3)
   #:install-debugger-hook
   #:*log*
   #:log-event))
