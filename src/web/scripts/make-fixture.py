#!/usr/bin/python3
"""Write the prototype's fixture from the YAML documents of one or more trees.

    src/web/scripts/make-fixture.py [name=path ...] [--out file.json]

With no arguments: this tree as `Synoptik`, plus `game-server`, `front-end` and
`utils` from their usual places when those directories exist. The output holds
`repositories` (name, path, commit, document count) and `docs`, one row per
document with the fields the explorer filters and draws on and the summary and
body the editor shows. It stands in for the `documents` operation of DES-0057 D1.

Ids are per repository (REQ-0073), so every row carries its `repo`.
"""
import json, os, re, subprocess, sys, yaml

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, "..", "..", ".."))
home = os.path.expanduser("~")
args = [a for a in sys.argv[1:] if not a.startswith("--")]
out = os.path.join(here, "..", "apps", "standalone", "src", "fixture.json")
if "--out" in sys.argv:
    out = sys.argv[sys.argv.index("--out") + 1]
    args = [a for a in args if a != out]

if args:
    trees = [a.split("=", 1) for a in args]
else:
    trees = [("Synoptik", root)] + [(n, p) for n, p in (
        ("game-server", f"{home}/lisp/game-server"),
        ("front-end", f"{home}/github/front-end"),
        ("utils", f"{home}/lisp/utils")) if os.path.isdir(os.path.join(p, "docs"))]

ID = re.compile(r"^([A-Z]+)-(\d{4})$")

def as_list(v):
    if v is None: return []
    if isinstance(v, (list, tuple)): return [str(x) for x in v]
    return [str(v)]

def commit(path):
    try:
        return subprocess.run(["git", "-C", path, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""

repos, rows = [], []
for name, tree in trees:
    n0 = len(rows)
    for dirpath, _, files in os.walk(os.path.join(tree, "docs")):
        for fname in sorted(files):
            if not fname.endswith((".yaml", ".yml")): continue
            path = os.path.join(dirpath, fname)
            try:
                d = yaml.safe_load(open(path, encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(d, dict) or "id" not in d: continue
            m = ID.match(str(d["id"]))
            if not m: continue
            rows.append({
                "repo": name,
                "id": str(d["id"]),
                "type": m.group(1),
                "title": " ".join(str(d.get("title", "")).split()),
                "status": str(d.get("status", "")),
                "priority": str(d.get("priority", d.get("severity", ""))),
                "date": str(d.get("date", "")),
                "tags": as_list(d.get("tags")),
                "refines": as_list(d.get("refines")),
                "affects": as_list(d.get("affects")),
                "summary": str(d.get("summary", "")).rstrip(),
                "body": str(d.get("body", d.get("decision", ""))).rstrip(),
                "path": os.path.relpath(path, tree),
            })
    repos.append({"name": name, "path": tree.replace(home, "~"), "commit": commit(tree), "documents": len(rows) - n0})

rows.sort(key=lambda r: (r["repo"], r["type"], r["id"]))
with open(out, "w") as f:
    json.dump({"repositories": repos, "docs": rows}, f, indent=1)
print(f"{out}: {len(rows)} documents in {len(repos)} repositories: " +
      ", ".join(f"{r['name']} {r['documents']}" for r in repos))
