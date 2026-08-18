#!/usr/bin/env python3
"""REQ-0016 R9's recall count, on the two trees this work does not commit to.

Loom is deliberately absent. It is one of the indexed trees and every commit to
it changes the corpus a Loom-side clause measures: R6-loom went 1/1 to 0/1 with
no seeder change, because a session's own commits grew the index from 140 items
to 144 and pushed MAKE-MACRO-ENTITY out of eighth place. game-server and
front-end are not written to by this work, so their corpora hold still.

Usage:  python3 tools/acceptance.py
"""
import urllib.request, urllib.parse, json, time, sys

B = "http://127.0.0.1:4780/v1"

CASES = [
    # game-server -- REQ-0016's own acceptance clauses
    ("game-server", "data-handler",
     ["data-handler","db-handler","null-handler","table-handler","model-handler",
      "game-handler","dhandler-get","dhandler-put","dhandler-delete","dhandler-update"], "R6"),
    ("game-server", "data-api handler database connection acquire and test connectivity",
     ["connection-connect-database"], "R8"),
    ("game-server", "start-server startup sequence and database handler health check",
     ["start-server","read-config","config-get","set-cors-handler","initialize-game-api",
      "initialize-media","configure-log"], "R7"),
    ("game-server", "restructure data handler protocol encode decode",
     ["base-encoder","base-decoder","set-encoder-decoder"], "R4"),
    # game-server -- REQ-0035's prose clause, replacing the Loom one. The query is
    # the first sentence of CLIENT-OP's own (:documentation ...), chosen
    # mechanically as the longest on any class in that tree.
    ("game-server", "operator whose expression serialized json client-side evaluation",
     ["client-op"], "prose"),
    # front-end -- the discriminating set, judged 2026-08-17. Two expectations
    # were dropped as wrong: LayerEditor for the working-set query, isAdminFlag
    # for the admin query.
    ("front-end", "how does the working set track edited layers", ["WorkingSet"], "fe-1"),
    ("front-end", "flatten a partition to an interchange document", ["emitPartition"], "fe-2"),
    ("front-end", "rewrite bare import specifiers through an alias", ["resolve"], "fe-3"),
    ("front-end", "editing colours in the graphics editor", ["ColorEditor"], "fe-4"),
    ("front-end", "changing the type of a map element", ["MapElementTypeEditor"], "fe-5"),
    ("front-end", "the terrain design surface", ["DesignTerrain"], "fe-6"),
    ("front-end", "admin permission to edit media", ["MediaEditorState.adminMode"], "fe-7"),
    ("front-end", "segment terrain into region polygons", ["polygonsToPartition"], "fe-8"),
    ("front-end", "switching between editor modes", ["EditorModeToggle"], "fe-9"),
    ("front-end", "saving a piece design and reporting rejections", ["SaveDesign"], "fe-10"),
]

def names_in(bundle):
    """Two readings of what a bundle returned: strict and lenient.

    Strict counts an entity that is a seed or an item of its own. Lenient also
    counts one named on a relation line under something else.

    Both are reported because the difference decides real cases and arguing it
    per query wastes the measurement. DESIGNTERRAIN on "the terrain design
    surface" is lenient-only: DESIGNTERRAININTERNAL and DESIGNTERRAINLOADED seed
    and it appears beneath them. Under CON-0006 a named entity is one `describe`
    away and so is reached; it is still not the same as being returned, and a
    ranking claim should be judged on the strict number."""
    strict = {s['name'] for s in bundle['seeds']}
    for i in bundle['items']:
        strict.add(i['entity']['name'])
    lenient = set(strict)
    for i in bundle['items']:
        for r in i.get('relations') or []:
            if r.get('name'):
                lenient.add(r['name'])
    return strict, lenient

def main():
    total = 0
    missing_strict = missing_lenient = 0
    slowest = 0.0
    for repo, q, expected, label in CASES:
        t = time.time()
        b = json.load(urllib.request.urlopen(
            B + "/context?" + urllib.parse.urlencode({"repository": repo, "task": q}),
            timeout=240))
        el = time.time() - t
        slowest = max(slowest, el)
        strict, lenient = names_in(b)
        ms = [e for e in expected if e not in strict]
        ml = [e for e in expected if e not in lenient]
        total += len(expected)
        missing_strict += len(ms); missing_lenient += len(ml)
        note = ""
        if ml:
            note = f"  MISS {ml}"
        elif ms:
            note = f"  relation-only {ms}"
        print(f"[{label:7}] strict {len(expected)-len(ms)}/{len(expected)}  "
              f"lenient {len(expected)-len(ml)}/{len(expected)}  "
              f"items {len(b['items']):3}  {el:.2f}s" + note)
    print(f"\nstrict  {total-missing_strict}/{total} present, {missing_strict} missing")
    print(f"lenient {total-missing_lenient}/{total} present, {missing_lenient} missing")
    print(f"slowest {slowest:.2f}s")
    return 1 if missing_lenient else 0

if __name__ == "__main__":
    sys.exit(main())
