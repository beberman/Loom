;;;; Package definition for synoptik-serve: the substance both protocol skins share.
;;;;
;;;; DES-0006: "synoptik-serve depends on exactly the same five systems
;;;; synoptik-process.asd already depends on -- synoptik-ontology, synoptik-graph,
;;;; synoptik-analyzer, synoptik-workspace, synoptik-knowledge -- and nothing in synoptik-serve,
;;;; synoptik-rest, or synoptik-mcp depends on synoptik-process." The use list below is
;;;; synoptik-process's own, which is known conflict-free because synoptik-process
;;;; compiles with it, and deliberately without #:synoptik-process itself.
;;;;
;;;; What lives here is what neither synoptik-rest nor synoptik-mcp may own alone: the
;;;; operation registry both call, the one capability seam both check, the
;;;; error contract both translate, the REPL sessions both continue, and the
;;;; JSON shape both must produce identically. Neither protocol system contains
;;;; business logic; both contain protocol translation over this.

(defpackage #:synoptik-serve
  (:use #:cl #:synoptik-utils #:synoptik-ontology #:synoptik-graph #:synoptik-analyzer #:synoptik-workspace
        #:synoptik-knowledge)

(:export
   ;; the operation registry
   #:operation
   #:operation-name
   #:operation-tier
   #:operation-function
   #:operation-arg-shape
   #:operation-summary
   #:*operations*
   #:define-operation
   #:register-operation
   #:find-operation
   #:all-operations
   #:invoke-operation

   ;; capability (R6): a set of granted tiers, never an ordered level
   #:resolve-caller-grants
   #:*static-grants*
   #:check-capability
   #:capability-error
   #:capability-error-operation
   #:capability-error-tier

   ;; the error contract (R8)
   #:operation-error->plist
   #:guarded-condition
   #:request-error
   #:malformed-request
   #:repository-indexing
   #:unknown-entity
   #:unknown-operation
   #:request-message

   ;; the operations, and what selecting a repository costs a program
   #:require-repository
   #:resolve-entity
   #:*workspace-registry-lock*
   #:*find-limit*

   ;; Reading a wire value: one predicate, one converter and one coercer per
   ;; type. The coercers are what an operation entry wants; the other four are
   ;; exported because the policy they encode should have exactly one home.
   ;; game-server BUG-0001 is what three of them scattered across three files
   ;; costs.
   #:is-integer-p
   #:to-integer
   #:is-boolean-p
   #:to-boolean
   #:request-integer
   #:request-boolean
   ;; The third type, and it has no predicate: TO-COSINE returns NIL for what
   ;; it cannot read, which is unambiguous where TO-BOOLEAN's NIL is not.
   #:to-cosine
   #:request-cosine
   #:*true-tokens*
   #:*false-tokens*

   ;; the REPL tier (R9)
   #:repl-open
   #:repl-eval
   #:repl-close
   #:sweep-repl-sessions
   #:repl-session-count
   #:*max-repl-sessions*
   #:*repl-session-idle-timeout*

   ;; JSON, shared by both skins so the two answer byte-identically
   #:json-value
   #:encode-result
   #:*array-valued-keys*
   #:*json-false*
   #:*json-key-name*

   ;; the listener and its registration seam (R7)
   #:register-handler
   #:*handlers*
   #:dispatch-request
   #:start-server
   #:stop-server
   #:server-status
   #:server-running-p
   #:*server*
   #:*default-port*
   #:*default-address*

   ;; headless mode, and this system's own supervision (R7)
   #:serve-forever
   #:install-service-debugger-hook
   #:log-event
   #:*log*))
