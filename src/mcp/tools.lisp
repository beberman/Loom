;;;; The tool set, and the schema tools/list answers with.
;;;;
;;;; Each tool is a thin call to the same registry entry loom-rest's equivalent
;;;; route calls. R2's seven read tools are enumerated by REQ-0008 itself; the
;;;; three repl tools are added per R9's explicit instruction that the REPL "is
;;;; reachable through the same REST and MCP surfaces R2 and R4 expose." The
;;;; set has grown by requirement since -- REQ-0034, REQ-0036 R2, REQ-0022 R6
;;;; and BUG-0052. No count is written in this file any more: the one that was
;;;; here read ten while the list held sixteen, and the assertion that fails
;;;; when the set changes lives in src/mcp/test/tools.lisp.
;;;;
;;;; The four lifecycle write tools -- loom_watch, loom_pause, loom_unwatch,
;;;; loom_reindex -- are deliberately absent, and this comment is the record of
;;;; that rather than an oversight to be tidied up later. DES-0006's
;;;; ALTERNATIVES CONSIDERED works through it: R2 enumerates exactly seven read
;;;; tools, R4 uses the open-ended "full console command vocabulary" for REST
;;;; alone, and R9 calls the REPL an *addition* to both surfaces rather than
;;;; something either already implied -- three signals in one requirement's own
;;;; text that MCP's surface is meant to be the narrower of the two by design.
;;;; Reversing it costs four more entries in the list below, calling registry
;;;; entries that already exist and are already tier-checked.
;;;;
;;;; The two transition tools are the exception, and are here because a later
;;;; requirement asked for them by name rather than because the argument above
;;;; was wrong. REQ-0022 R6 puts the transition on REST *and* MCP, and REQ-0021
;;;; R8 says why it is not a preference: an agent installed into a prepared
;;;; worktree reaches Loom through the service and has no tools/loom.sh to shell
;;;; out to, so a transition missing from MCP is a transition that agent cannot
;;;; perform. The narrowness DES-0006 chose was about lifecycle commands a
;;;; service operator runs, not about the workflow an agent is installed to
;;;; follow.

(in-package :loom-mcp)

(defstruct (tool (:conc-name tool-))
  "One MCP tool: the name a client calls and the registry entry behind it."
  (name "")
  (operation nil))

(defparameter *tools*
  (list (make-tool :name "loom_find" :operation :find)
        (make-tool :name "loom_describe" :operation :describe)
        (make-tool :name "loom_impact" :operation :impact)
        ;; DES-0055 D12, PLAN-0060 step 7. REST finds :SITES by name; this list is
        ;; written out, so the operation reaches MCP only with this line
        ;; (BUG-0052 was the same omission for `similar').
        (make-tool :name "loom_sites" :operation :sites)
        (make-tool :name "loom_context" :operation :context)
        (make-tool :name "loom_status" :operation :status)
        (make-tool :name "loom_check" :operation :check)
        (make-tool :name "loom_rules" :operation :rules)
        ;; REQ-0034. The workflow tool: an agent writing a document asks this
        ;; before the file exists, instead of writing it, waiting for the
        ;; monitor, running loom_check and subtracting the repository's own
        ;; baseline from the answer.
        (make-tool :name "loom_check_document" :operation :check-document)
        ;; REQ-0036 R2. The other half of a retrieval judgement, and the half
        ;; no offline scorer can supply: what the agent went on to use, from
        ;; any source, including what it found by grep. A :WRITE tool, so a
        ;; read-only caller is not shown it.
        (make-tool :name "loom_context_used" :operation :context-used)
        ;; Two more read tools, and the line they sit on the right side of.
        ;; :STRUCTURE and :DRIFT answer questions an agent working in a prepared
        ;; worktree asks -- what is the shape of this tree, and where does its
        ;; prose disagree with its code -- and change nothing.
        ;;
        ;; :ARCHITECTURE, :INIT and :REMOVE are deliberately absent, which is
        ;; the same judgement that keeps the four lifecycle write tools off this
        ;; surface. Those three prepare, describe or dismantle a repository, and
        ;; they are driven by tools/loom-init.sh where a terminal can ask the
        ;; consent REQ-0021 R16 requires. An agent mid-task has no business
        ;; running any of them, and REST carries them for the script that does.
        (make-tool :name "loom_structure" :operation :structure)
        (make-tool :name "loom_drift" :operation :drift)
        ;; BUG-0052. REQ-0042's two verbs, on the same side of that line and for
        ;; the same reason: both are read-tier queries over the index and a
        ;; vector sidecar, and neither prepares, describes or dismantles a
        ;; repository. The narrowness argued above is about lifecycle commands a
        ;; service operator runs.
        ;;
        ;; `similar' is the question `find' structurally cannot answer -- a
        ;; duplicate is precisely the case where the two names differ -- so an
        ;; agent that has only `find' has no way to ask it at all. front-end
        ;; holds four copies of ringIsCCW, two of which share a name.
        (make-tool :name "loom_similar" :operation :similar)
        (make-tool :name "loom_survey" :operation :survey)
        (make-tool :name "loom_set_status" :operation :set-status)
        (make-tool :name "loom_complete" :operation :complete)
        (make-tool :name "loom_repl_open" :operation :repl-open)
        (make-tool :name "loom_repl_eval" :operation :repl-eval)
        (make-tool :name "loom_repl_close" :operation :repl-close))
  "Every tool, in the order tools/list returns them.")

(defun tool-permitted-p (tool grants)
  "True when GRANTS reach the tier TOOL's operation declares.

The same question CHECK-CAPABILITY asks at dispatch, asked of the same grants
and the same registry entry. REQ-0032 R2: two places deciding what a caller may
reach is how they drift, and a tool whose operation is not registered at all is
not permitted rather than assumed harmless."
  (let ((operation (find-operation (tool-operation tool))))
    (and operation (member (operation-tier operation) grants) t)))

(defun all-tools (&optional (grants nil grants-supplied-p))
  "The tools GRANTS may call, or every tool when no grants are given.

REQ-0032. *TOOLS* was returned whole to every client, and RESOLVE-CALLER-GRANTS
answers :read and :write and deliberately not :repl -- so the three repl tools
were advertised to every caller and callable by none, in every deployment.

A tool list is an interface description read by a machine that plans with it.
The cost measured on game-server was both halves of that at once: the agent
spent five `sbcl --load' launches doing by shell what a persistent session does
in one, and then discovered at the end of the task that the tool it had been
ignoring would have refused it anyway.

The grants are the caller's resolved ones, passed down from the request rather
than resolved again here. On the day RESOLVE-CALLER-GRANTS starts answering
:repl for some callers, those callers' lists grow and nothing else changes.

No grants at all is the whole list, which is what a caller enumerating the tool
set for its own sake wants -- loom-rest's route coverage check, and the tests
that assert what the set contains."
  (if grants-supplied-p
      (remove-if-not (lambda (tool) (tool-permitted-p tool grants)) *tools*)
      *tools*))

(defun find-tool (name)
  "The tool called NAME, whatever the caller may reach.

Unfiltered on purpose. REQ-0032 R3: filtering the advertisement removes a
misleading claim and removes no enforcement, so a client calling a tool it was
never shown finds it here and is refused by CHECK-CAPABILITY at dispatch,
exactly as it is today. A NIL here would answer \"no such tool\", which is a
different and false thing to tell a caller about a tool this server has."
  (find name *tools* :key #'tool-name :test #'string=))

(defun schema-property-name (key)
  "A JSON Schema property name for the argument KEY.
The same spelling loom-rest's query parameters use, because both decode into
the same registry entry and a client should not have to learn two."
  (string-downcase (symbol-name key)))

(defun tool-input-schema (operation)
  "The tool's inputSchema, derived from the entry's declared argument shape.

Derived rather than written out, so a tool cannot describe arguments its entry
does not take. Every property is a string: an HTTP query parameter is a string
whatever it means, and REQUEST-INTEGER is what turns the two numeric ones into
numbers at the entry rather than at the protocol.

The keys are escaped keywords because MCP spells them in camelCase and they
are not this system's to rename; DEFAULT-JSON-KEY-NAME carries the rule."
  (let ((properties (loop for (key nil) in (operation-arg-shape operation)
                          append (list (intern (schema-property-name key) :keyword)
                                       (list :|type| "string"))))
        (required (loop for (key required) in (operation-arg-shape operation)
                        when required collect (schema-property-name key))))
    (list :|type| "object"
          ;; An empty hash table and a vector rather than NIL for the empty
          ;; cases: NIL encodes as null, and a schema whose "properties" is
          ;; null rather than {} or whose "required" is null rather than [] is
          ;; not a schema. An operation with no arguments -- loom_repl_open --
          ;; is exactly that case.
          :|properties| (if properties properties (make-hash-table))
          :|required| (coerce required 'vector))))

(defun tool-descriptor (tool)
  (let ((operation (find-operation (tool-operation tool))))
    (list :|name| (tool-name tool)
          :|description| (operation-summary operation)
          :|inputSchema| (tool-input-schema operation))))
