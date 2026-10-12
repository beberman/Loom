# Security

Loom runs as a local service, and it has no authentication. This file says what
it trusts, what it refuses, and what it leaves open.

## What the service trusts

The service binds 127.0.0.1 on port 4780 and nowhere else by default. It asks
no caller for a credential. Every caller that reaches it is granted the `:read`
and `:write` tiers and never `:repl`. `RESOLVE-CALLER-GRANTS` in
`src/serve/capability.lisp` is where that is decided, and it returns the same
grants for every request.

The `:write` tier is 11 operations, among them `set-status` and `complete`,
which edit and move files under a repository the service watches. The `:repl`
tier evaluates Lisp and is not reachable over REST or MCP without a grant that
no caller receives.

Binding to an address other than 127.0.0.1 is unsupported. A service reachable
from another machine would let that machine write to your repositories.

## What the Host check stops

A web page open in your browser can send requests to 127.0.0.1. Under DNS
rebinding, an attacker's site name is made to resolve to 127.0.0.1, and the
browser then lets the page read the answers. Such a request carries the
attacker's name in its `Host` header, and the page cannot change that header.

The listener answers 403 to any request whose `Host` is not `127.0.0.1`,
`localhost` or `[::1]` followed by the port the listener is on. The comparison
ignores case. A `Host` with no port is accepted only when the listener is on
port 80. A request with no `Host` is refused. The check runs before any
handler, so it covers the REST routes under `/v1/`, the MCP endpoint at `/mcp`
and unknown paths. The reasoning is DEC-0008 in `docs/decisions/`.

A refused request gets a JSON body named `HOST-REFUSED` that gives the `Host`
it received.

## What it does not stop

- Any process on your machine can call the service. A local process chooses its
  own `Host`, and the header is not a credential.
- A caller that reaches the service through a tunnel, a port mapping or a proxy
  that changes the port or rewrites the `Host` is refused. A tree prepared with
  `init --endpoint` naming another host is refused for the same reason.
- Anything an operation does once a request is accepted. The tiers decide which
  operations a caller reaches, and every local caller reaches all of `:read`
  and `:write`.

## Authentication

Tokens and authentication are deferred. REQ-0071 R4 says where the service will
authenticate. REQ-0076 R1 needs a forge token. Neither is built, and until one
is, the service is safe to run only on a machine whose local users and local
processes you trust with your repositories.

## Reporting a vulnerability

Send a vulnerability report by e-mail to brian@tenfactorgrowth.com. Do not open
a public issue that describes a vulnerability.

Say which commit you found it in (`git rev-parse HEAD` prints it), what you did
to reproduce it, and what happened. A short script or a request that triggers it
is the most useful thing to attach.

Loom has one maintainer. A report is read when the maintainer reads mail. This
file promises no response time, no reward and no disclosure schedule. The same
address takes reports under [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
