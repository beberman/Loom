#!/usr/bin/env python3
"""REQ-0016 R9's recall count, on the two trees this work does not commit to.

Loom is deliberately absent. It is one of the indexed trees and every commit to
it changes the corpus a Loom-side clause measures: R6-loom went 1/1 to 0/1 with
no seeder change, because a session's own commits grew the index from 140 items
to 144 and pushed MAKE-MACRO-ENTITY out of eighth place. game-server and
front-end are not written to by this work, so their corpora hold still.

Usage:  python3 tools/acceptance.py            the 32 hand-written cases
        python3 tools/acceptance.py --log     the cases the log recorded

REQ-0036 R10 and R11. The --log mode reads .loom/context/, joins each record
with the used set an agent filed against it, and reports the three populations
R3 names. The hand-written cases stay: they are the only judgements in the
system not shaped by what the current seeder returned, and R11 makes them the
held-out set. Nothing here trains on them and nothing here rewrites them.
"""
import urllib.request, urllib.parse, json, time, sys, os, glob

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

LOG_DIRECTORY = os.environ.get(
    "LOOM_CONTEXT_LOG",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 ".loom", "context"))


def watched_repositories():
    """The repositories the service currently holds, by name."""
    try:
        status = json.load(urllib.request.urlopen(B + "/status", timeout=60))
    except Exception:
        return {}
    return {r["name"]: r for r in status.get("repositories", [])}


def judgements(directory):
    """Every record that has a used set, as (record, used) pairs.

    A record with no used set is a query nobody filed a judgement against. It is
    not a failure and it is not scored -- it is the half of the log that says
    what was asked, and R3's join needs both halves."""
    out = []
    for path in sorted(glob.glob(os.path.join(directory, "ctx-*.json"))):
        if path.endswith(".used.json"):
            continue
        used_path = path[:-len(".json")] + ".used.json"
        if not os.path.exists(used_path):
            continue
        with open(path) as f:
            record = json.load(f)
        with open(used_path) as f:
            used = json.load(f).get("used") or []
        out.append((record, used))
    return out


def fnv1a(text):
    """The 64-bit FNV-1a hash Loom writes into a record, as sixteen hex digits.

    A second implementation of a fixed algorithm rather than a second decision:
    the spec is the spec, and the alternative is for the harness to be unable to
    tell a clean tree from a dirty one."""
    h = 14695981039346656037
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def git(root, *arguments):
    import subprocess
    try:
        out = subprocess.run(["git", "-C", root, *arguments],
                             capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def live_fingerprint(root):
    commit = git(root, "rev-parse", "HEAD")
    diff = git(root, "diff", "HEAD")
    if commit is None or diff is None:
        return None
    return {"commit": commit.strip(), "diffHash": fnv1a(diff)}


def resolves(repository, name):
    """True when NAME still names something in the live index."""
    try:
        found = json.load(urllib.request.urlopen(
            B + "/find?" + urllib.parse.urlencode({"repository": repository,
                                                   "term": name}),
            timeout=60))
    except Exception:
        return False
    return any(e.get("name") == name for e in found.get("entities", []))


def freshness(record, used, watched):
    """R4's four outcomes for one record, against the trees now watched.

    A fingerprint that no longer matches is not itself a verdict. Every commit to
    a searched tree invalidates the equality test against every record that
    predates it, which is most of them, so a mismatch opens a check rather than
    closing one.

      current       the fingerprint matches. Scored.
      checkable     it differs and every entity the judgement names still
                    resolves. Scored, and reported as authored against an older
                    tree.
      unverifiable  it differs and an entity the judgement names does not. Not
                    scored: counting a deleted function as a ranking miss is a
                    failure attributed to the seeder that belongs to the corpus.
      unwatched     nobody is watching that repository, so nothing can be
                    checked at all. Reported rather than assumed to pass, which
                    is the posture `check` already takes toward a prose file
                    reference no watched repository holds."""
    declared = record.get("repository") or {}
    name = declared.get("name")
    if name not in watched:
        return "unwatched"
    live = live_fingerprint(watched[name]["root"])
    if live and (live["commit"] == declared.get("commit")
                 and live["diffHash"] == declared.get("diffHash")):
        return "current"
    for entry in used:
        if entry.get("name") and not resolves(name, entry["name"]):
            return "unverifiable"
    return "checkable"


def log_main():
    directory = LOG_DIRECTORY
    pairs = judgements(directory)
    if not pairs:
        print(f"no judgements in {directory}")
        print("A record is written by a context call and completed by "
              "loom_context_used; both halves are needed before anything scores.")
        return 0
    watched = watched_repositories()
    hits = misses = unused = 0
    for record, used in pairs:
        returned = [i["name"] for i in (record.get("returned") or {}).get("items") or []]
        used_names = [e.get("name") for e in used if e.get("name")]
        in_both = [n for n in used_names if n in returned]
        used_only = [(n, e.get("how")) for n, e in zip(used_names, used)
                     if n not in returned]
        returned_only = [n for n in returned if n not in used_names]
        state = freshness(record, used, watched)
        if state in ("current", "checkable"):
            hits += len(in_both); misses += len(used_only); unused += len(returned_only)
        print(f"[{record['id']}] {state:12} {record['task'][:48]!r}")
        for name in in_both:
            rank = returned.index(name) + 1
            print(f"    hit    {name}  at {rank} of {len(returned)}")
        for name, how in used_only:
            print(f"    miss   {name}  found by: {how}")
        if returned_only:
            print(f"    unused {len(returned_only)} of {len(returned)} returned")
    scored = sum(1 for r, u in pairs
                 if freshness(r, u, watched) in ("current", "checkable"))
    print(f"\n{len(pairs)} judgement(s), {scored} scored: {hits} hit, "
          f"{misses} missed, {unused} returned and not used")
    print("A miss is the only record that raises recall. A hit's rank says how "
          "nearly it was not one.")
    return 0


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
    sys.exit(log_main() if "--log" in sys.argv else main())
