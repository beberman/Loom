#!/usr/bin/env python3
"""One row per case: the query, every seed with its score, and the expected name.

    LOOM_CONTEXT_LOG=1 tools/loom-serve.sh restart
    tools/test/seed-sheet.py tools/test/cases/known-item.json > seeds.csv

Needs the context log ON, which tools/loom-serve.sh no longer defaults to. A
REST bundle carries no seed scores -- the seeder's evidence goes to the record
writer and not to the caller (DES-0032 D3) -- and since DES-0046 its `seeds`
list holds only the seeds the budget refused, the rest being `items` with
`band == "seed"`. `service.seed_names` unions the two. The score lives only in
.loom/context, so this runs each case, then reads the record it just wrote back
by matching on the task string; the live-bundle fallback is names without
scores.

Columns: repository, family, expected, hit_strict, hit_lenient, seeds, query,
then seed_1..seed_N and score_1..score_N, and terms_1..terms_N when --terms is
given. N is the widest seed set seen, so the header is stable across a file.

Purge the probe records afterwards -- they are one session's queries, which is
the contamination REQ-0038's rule and docs/TODO.md both describe.
"""

import csv
import glob
import json
import os
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import service

B = service.BASE
LOG = os.environ.get("LOOM_CONTEXT_LOG_DIR", ".loom/context")


def names_in(bundle):
    strict = set(service.seed_names(bundle))
    for i in bundle.get("items") or []:
        strict.add(i["entity"]["name"])
    lenient = set(strict)
    for i in bundle.get("items") or []:
        for r in i.get("relations") or []:
            if r.get("name"):
                lenient.add(r["name"])
    return strict, lenient


def records_by_task(since):
    """Task string -> the newest record written for it since SINCE."""
    out = {}
    for f in glob.glob(os.path.join(LOG, "*.json")):
        try:
            if os.path.getmtime(f) < since:
                continue
            r = json.load(open(f))
        except Exception:
            continue
        task = r.get("task")
        seeds = (r.get("returned") or {}).get("seeds")
        if isinstance(task, str) and seeds is not None:
            prev = out.get(task)
            if prev is None or os.path.getmtime(f) >= prev[0]:
                out[task] = (os.path.getmtime(f), r)
    return {k: v[1] for k, v in out.items()}


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("Usage: seed-sheet.py <cases.json> [--terms] > out.csv")
    want_terms = "--terms" in args
    cases = json.load(open(args[0]))

    # RULE-0008. Same skip-and-continue as recall.py, and the same silent
    # result: a service that is down writes a CSV with a header and no rows,
    # which reads as a case file that produced nothing.
    service.ensure(__file__, repositories=sorted({c[0] for c in cases},
                                                 key=str.lower))

    started = time.time() - 1
    rows = []
    for repo, query, expected, family in cases:
        try:
            b = json.load(urllib.request.urlopen(
                B + "/context?" + urllib.parse.urlencode(
                    {"repository": repo, "task": query}), timeout=240))
        except Exception as exc:
            print("ERROR %s %r: %s" % (repo, query[:40], exc), file=sys.stderr)
            continue
        strict, lenient = names_in(b)
        rows.append({"repository": repo, "family": family, "query": query,
                     "expected": expected,
                     "hit_strict": expected in strict,
                     "hit_lenient": expected in lenient,
                     "bundle": b})

    time.sleep(2)                      # the record is written on another thread
    records = records_by_task(started)
    missing = 0
    width = 0
    for row in rows:
        r = records.get(row["query"])
        seeds = (r.get("returned") or {}).get("seeds") if r else None
        if seeds is None:
            missing += 1
            seeds = [{"name": n, "score": None, "terms": None}
                     for n in service.seed_names(row["bundle"])]
        row["seedrows"] = seeds
        width = max(width, len(seeds))
    if missing:
        print("%d of %d cases had no record; their scores are blank. Is the "
              "context log on?" % (missing, len(rows)), file=sys.stderr)

    header = ["repository", "family", "expected", "hit_strict", "hit_lenient",
              "seeds", "query"]
    for i in range(1, width + 1):
        header.append("seed_%d" % i)
    for i in range(1, width + 1):
        header.append("score_%d" % i)
    if want_terms:
        for i in range(1, width + 1):
            header.append("terms_%d" % i)

    out = csv.writer(sys.stdout)
    out.writerow(header)
    for row in rows:
        seeds = row["seedrows"]
        line = [row["repository"], row["family"], row["expected"],
                row["hit_strict"], row["hit_lenient"], len(seeds), row["query"]]
        line += [(seeds[i]["name"] if i < len(seeds) else "") for i in range(width)]
        line += [(seeds[i].get("score") if i < len(seeds) else "") for i in range(width)]
        if want_terms:
            for i in range(width):
                t = seeds[i].get("terms") if i < len(seeds) else None
                line.append(" ".join("%s/%s" % (x.get("term"), x.get("weight"))
                                     for x in (t or [])))
        out.writerow(line)

    print("%d rows, widest seed set %d, %d without scores"
          % (len(rows), width, missing), file=sys.stderr)


if __name__ == "__main__":
    main()
