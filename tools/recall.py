#!/usr/bin/env python3
"""Run the generated known-item cases and report recall per family.

    tools/recall.py cases.json               every case
    tools/recall.py cases.json --limit 60     the first 60 of each family
    tools/recall.py cases.json --json out.json   also write per-case results

A second instrument beside tools/acceptance.py, an order of magnitude larger.
The two measure different things and neither replaces the other. acceptance.py
holds 24 hand-written cases whose answers a human judged, which REQ-0036 R11
makes the held-out set; this holds cases built from the index itself, whose
ground truth is constructed -- see tools/make-cases.py for the three families
and the bias each carries.

Recall is scored on the name, strict and lenient, exactly as acceptance.py's
names_in reads a bundle: strict counts a seed or an item of its own, lenient
also counts a name appearing on a relation line beneath something else.

Every call writes a record to the service's context log. At 450 cases a
comparison run doubles the corpus, which is the probe contamination REQ-0044
asks for a field to mark. Until it has one, these records are identifiable by
their repository and by matching a query in the case file.
"""

import json
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict

B = "http://127.0.0.1:4780/v1"


def names_in(bundle):
    strict = {s["name"] for s in bundle.get("seeds") or []}
    for i in bundle.get("items") or []:
        strict.add(i["entity"]["name"])
    lenient = set(strict)
    for i in bundle.get("items") or []:
        for r in i.get("relations") or []:
            if r.get("name"):
                lenient.add(r["name"])
    return strict, lenient


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("Usage: recall.py <cases.json> [--limit N] [--json out.json]")
    path = args[0]
    limit = None
    out_path = None
    if "--limit" in args:
        limit = int(args[args.index("--limit") + 1])
    if "--json" in args:
        out_path = args[args.index("--json") + 1]

    cases = json.load(open(path))
    if limit:
        seen = defaultdict(int)
        kept = []
        for c in cases:
            if seen[c[3]] < limit:
                kept.append(c)
                seen[c[3]] += 1
        cases = kept

    tally = defaultdict(lambda: {"n": 0, "strict": 0, "lenient": 0})
    results = []
    slowest = 0.0
    started = time.time()

    for repo, query, expected, family in cases:
        t = time.time()
        try:
            b = json.load(urllib.request.urlopen(
                B + "/context?" + urllib.parse.urlencode(
                    {"repository": repo, "task": query}), timeout=240))
        except Exception as exc:
            print("ERROR %s %r: %s" % (repo, query[:40], exc), file=sys.stderr)
            continue
        el = time.time() - t
        slowest = max(slowest, el)
        strict, lenient = names_in(b)
        hit_s = expected in strict
        hit_l = expected in lenient
        row = tally[family]
        row["n"] += 1
        row["strict"] += 1 if hit_s else 0
        row["lenient"] += 1 if hit_l else 0
        results.append({"repository": repo, "query": query, "expected": expected,
                        "family": family, "strict": hit_s, "lenient": hit_l,
                        "seeds": len(b.get("seeds") or []),
                        "items": len(b.get("items") or [])})

    print()
    total = {"n": 0, "strict": 0, "lenient": 0}
    for family in ("name", "inflected", "prose"):
        row = tally[family]
        if not row["n"]:
            continue
        for k in total:
            total[k] += row[k]
        print("%-10s strict %4d/%-4d %5.1f%%   lenient %4d/%-4d %5.1f%%"
              % (family, row["strict"], row["n"], 100.0 * row["strict"] / row["n"],
                 row["lenient"], row["n"], 100.0 * row["lenient"] / row["n"]))
    if total["n"]:
        print("%-10s strict %4d/%-4d %5.1f%%   lenient %4d/%-4d %5.1f%%"
              % ("ALL", total["strict"], total["n"],
                 100.0 * total["strict"] / total["n"],
                 total["lenient"], total["n"],
                 100.0 * total["lenient"] / total["n"]))
    print("%d cases in %.0fs, slowest %.2fs" % (total["n"], time.time() - started, slowest))

    if out_path:
        json.dump(results, open(out_path, "w"), indent=1)


if __name__ == "__main__":
    main()
