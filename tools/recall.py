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


def measured_against(seen):
    """One line per repository naming what produced the score.

    REQ-0050 R4. This harness drives a running service and reported 450 case
    results with nothing saying which build answered them. Its sibling
    tools/acceptance.py asks the service for its status; this reads the
    provenance the bundles themselves now carry (REQ-0050 R1), which is the
    same fact from the answer rather than from a second call -- and it is
    per repository, because the cases span four trees and each has its own
    index.

    A repository whose bundles carried no provenance is named as such. The
    service that answered was older than the field, which is exactly the
    situation this line exists to make visible."""
    lines = []
    for repo in sorted(seen):
        p = seen[repo]
        if not p:
            lines.append(f"  {repo}: the service sent no provenance, so which "
                         f"build answered is unknown")
            continue
        commit = p.get("commit")
        head = (str(commit)[:12] if commit
                else f"commit unknown -- {p.get('commit-reason') or 'no reason recorded'}")
        if p.get("branch"):
            head += f" ({p['branch']})"
        if p.get("dirty"):
            head += " + uncommitted edits"
        drift = p.get("drift")
        if drift is None:
            tail = "staleness unknown"
        elif drift:
            tail = (f"<-- STALE INDEX: {drift} claimed file"
                    f"{'' if drift == 1 else 's'} changed since it was read")
        else:
            tail = "index current with the tree"
        lines.append(f"  {repo}: {head}  {tail}")
    return lines


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
    # REQ-0050 R4, read off the first bundle each repository returns. Every
    # bundle carries it and they cannot disagree within a run unless the
    # service reindexed mid-run, which is worth seeing rather than hiding: the
    # last one wins and the line then names the tree most of the cases ran
    # against.
    provenance = {}
    results = []
    slowest = 0.0
    started = time.time()

    for repo, query, expected, family in cases:
        provenance.setdefault(repo, None)
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
        if b.get("provenance"):
            provenance[repo] = b["provenance"]
        strict, lenient = names_in(b)
        hit_s = expected in strict
        hit_l = expected in lenient
        row = tally[family]
        row["n"] += 1
        row["strict"] += 1 if hit_s else 0
        row["lenient"] += 1 if hit_l else 0
        seeds = b.get("seeds") or []
        results.append({"repository": repo, "query": query, "expected": expected,
                        "family": family, "strict": hit_s, "lenient": hit_l,
                        "seeds": len(seeds),
                        # The names, not just how many. BUG-0041 is a defect
                        # recall cannot see -- eight seeds carrying one name
                        # still score a hit when the target is one of them --
                        # so the count of *distinct* names in a seed set is the
                        # number that moves, and it is only in the names.
                        "seed_names": [s.get("name") for s in seeds],
                        "items": len(b.get("items") or [])})

    print()
    print("measured against:")
    for line in measured_against(provenance):
        print(line)
    print()
    total = {"n": 0, "strict": 0, "lenient": 0}
    # The three generated families first, in the order tools/make-cases.py
    # builds them, then anything else the case file happens to hold. Hardcoding
    # the triple printed nothing at all for tools/cases/mismatch.json, whose
    # family is `mismatch' and which no amount of reading the ALL line would
    # have revealed as absent rather than as zero.
    known = ("name", "inflected", "prose")
    families = list(known) + sorted(f for f in tally if f not in known)
    for family in families:
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
