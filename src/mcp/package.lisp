;;;; Package definition for loom-mcp: MCP's JSON-RPC surface.
;;;;
;;;; There is no official Common Lisp MCP SDK -- checked, not assumed -- and
;;;; the surface this needs is a small, well-specified slice of plain JSON-RPC
;;;; over HTTP: initialize, tools/list, tools/call, answered with a single
;;;; response body rather than a Server-Sent-Events stream. ARCH-0006 argues
;;;; the single-response subset is fully conformant rather than a cut corner,
;;;; because none of Loom's operations is long-running or needs
;;;; server-initiated push: every one is a single graph read, a single write
;;;; already made synchronous by the repository lock, or one REPL eval.

(defpackage #:loom-mcp
  (:use #:cl #:loom-serve)
  (:export
   #:*endpoint*
   #:*protocol-version*
   #:*tools*
   #:tool-name
   #:tool-operation
   #:all-tools
   #:find-tool
   #:handle-jsonrpc))
