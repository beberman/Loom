#!/usr/bin/python3
"""Write the prototype's fixture from the YAML documents under a docs/ tree.

    src/web/scripts/make-fixture.py [docs-dir] [out.json]

One row per document: the fields the explorer filters and draws on, plus the
summary and body the editor shows. A reference that names no document in the
tree is left in `refines`/`affects` and resolved by the UI, which marks it
unresolved. This stands in for the `documents` operation of DES-0057 D1.
"""
import json, os, re, sys, yaml

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, "..", "..", ".."))
docs = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "docs")
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "apps", "standalone", "src", "fixture.json")

ID = re.compile(r"^([A-Z]+)-(\d{4})$")

def as_list(v):
    if v is None: return []
    if isinstance(v, (list, tuple)): return [str(x) for x in v]
    return [str(v)]

rows = []
for dirpath, _, files in os.walk(docs):
    for name in sorted(files):
        if not name.endswith((".yaml", ".yml")): continue
        path = os.path.join(dirpath, name)
        try:
            d = yaml.safe_load(open(path, encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(d, dict) or "id" not in d: continue
        m = ID.match(str(d["id"]))
        if not m: continue
        rows.append({
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
            "path": os.path.relpath(path, root),
        })

rows.sort(key=lambda r: (r["type"], r["id"]))
with open(out, "w") as f:
    json.dump(rows, f, indent=1)
print(f"{out}: {len(rows)} documents")
