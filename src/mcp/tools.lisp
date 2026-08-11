;;;; The tool set, and the schema tools/list answers with.
;;;;
;;;; Exactly ten tools, each a thin call to the same registry entry loom-rest's
;;;; equivalent route calls. R2's seven read tools are enumerated by REQ-0008
;;;; itself; the three repl tools are added per R9's explicit instruction that
;;;; the REPL "is reachable through the same REST and MCP surfaces R2 and R4
;;;; expose."
;;;;
;;;; The four write tools -- loom_watch, loom_pause, loom_unwatch,
;;;; loom_reindex -- are deliberately absent, and this comment is the record of
;;;; that rather than an oversight to be tidied up later. DES-0006's
;;;; ALTERNATIVES CONSIDERED works through it: R2 enumerates exactly seven read
;;;; tools, R4 uses the open-ended "full console command vocabulary" for REST
;;;; alone, and R9 calls the REPL an *addition* to both surfaces rather than
;;;; something either already implied -- three signals in one requirement's own
;;;; text that MCP's surface is meant to be the narrower of the two by design.
;;;; Reversing it costs four more entries in the list below, calling registry
;;;; entries that already exist and are already tier-checked.

(in-package :loom-mcp)

(defstruct (tool (:conc-name tool-))
  "One MCP tool: the name a client calls and the registry entry behind it."
  (name "")
  (operation nil))

(defparameter *tools*
  (list (make-tool :name "loom_find" :operation :find)
        (make-tool :name "loom_describe" :operation :describe)
        (make-tool :name "loom_impact" :operation :impact)
        (make-tool :name "loom_context" :operation :context)
        (make-tool :name "loom_status" :operation :status)
        (make-tool :name "loom_check" :operation :check)
        (make-tool :name "loom_rules" :operation :rules)
        (make-tool :name "loom_repl_open" :operation :repl-open)
        (make-tool :name "loom_repl_eval" :operation :repl-eval)
        (make-tool :name "loom_repl_close" :operation :repl-close))
  "The ten tools, in the order tools/list returns them.")

(defun all-tools () *tools*)

(defun find-tool (name)
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
