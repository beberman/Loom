#!/usr/bin/python3
"""Write mcp-manifest.json from the running service's own MCP answers.

    tools/mcp-manifest.py [--url http://127.0.0.1:4780/mcp] [--out mcp-manifest.json]

The manifest is derived, never hand-edited: server info and protocol version come
from `initialize', the tools from `tools/list'. tools/list answers with the tools
the caller's grants allow, so run it against a service whose default grants are the
ones you want published. Run `tools/synoptik-serve.sh update' first when the source
changed.
"""
import argparse, json, os, sys, urllib.request

def rpc(url, method, ident):
    body = json.dumps({"jsonrpc": "2.0", "id": ident, "method": method}).encode()
    req = urllib.request.Request(url, body, {
        "content-type": "application/json",
        "accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=10) as r:
        reply = json.load(r)
    if "error" in reply:
        sys.exit(f"{method}: {reply['error']}")
    return reply["result"]

def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:4780/mcp")
    ap.add_argument("--out", default=os.path.join(here, "mcp-manifest.json"))
    a = ap.parse_args()
    try:
        init = rpc(a.url, "initialize", 1)
        tools = rpc(a.url, "tools/list", 2)["tools"]
    except OSError as e:
        sys.exit(f"no service at {a.url}: {e}. Start it with tools/synoptik-serve.sh start.")
    manifest = {
        "name": init["serverInfo"]["name"],
        "version": init["serverInfo"]["version"],
        "protocolVersion": init["protocolVersion"],
        "transport": {"type": "http", "url": a.url},
        "capabilities": init["capabilities"],
        "tools": sorted(tools, key=lambda t: t["name"]),
    }
    with open(a.out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"{a.out}: {len(tools)} tools")

main()
