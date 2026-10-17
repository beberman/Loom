;;;; Package definition for synoptik-mcp: MCP's JSON-RPC surface.
;;;;
;;;; There is no official Common Lisp MCP SDK -- checked, not assumed -- and
;;;; the surface this needs is a small, well-specified slice of plain JSON-RPC
;;;; over HTTP: initialize, tools/list, tools/call, answered with a single
;;;; response body rather than a Server-Sent-Events stream. DES-0006 argues
;;;; the single-response subset is fully conformant rather than a cut corner,
;;;; because none of Synoptik's operations is long-running or needs
;;;; server-initiated push: every one is a single graph read, a single write
;;;; already made synchronous by the repository lock, or one REPL eval.

(defpackage #:synoptik-mcp
  (:use #:cl #:synoptik-serve)
  (:export
   #:*endpoint*
   #:*protocol-version*
   #:*tools*
   #:tool-name
   #:tool-operation
   #:all-tools
   #:tool-permitted-p
   #:find-tool
   #:handle-jsonrpc))
