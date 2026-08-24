#!/usr/bin/env python3
"""Build known-item retrieval cases from a repository's own definitions.

    sbcl --script tools/test/entity-dump.lisp /path/to/repo > repo.json
    tools/test/make-cases.py repo.json ... > cases.json

The 24 hand-written cases in tools/test/acceptance.py are the held-out set REQ-0036
R11 protects, and nothing here touches them. These are a second instrument, an
order of magnitude larger, whose ground truth is constructed rather than judged:
a case is built *from* an entity, so the entity is by construction an answer to
it.

Three families, reported separately because they measure different things and
each is biased in a direction worth naming.

  prose     the query is the definition's own docstring, with every word of its
            name removed so it cannot win on a literal name match. Measures
            whether a definition is findable from a description of what it does,
            which is REQ-0039's subject. Biased towards a ranker that reads
            prose -- that is what it is for, and it is why the number is
            reported apart from the others rather than summed with them.

  inflected the query is the definition's name as words, with one word replaced
            by an inflection of it (plural, or -ing). Measures exactly what a
            stemmer buys: whether an inflected query still reaches the thing.
            This is the family the Porter-versus-hybrid question turns on.

  name      the query is the definition's name as plain words. A floor: if this
            fails the matching is broken in a way no ranking change explains.
            Biased towards exact matching, and it is the guard that a change
            made for the other two families has not broken the ordinary case.

A case is (repository, query, expected-name, family). Recall is scored on the
name, so a name several entities share is satisfied by any of them -- which is
the same reading tools/test/acceptance.py's names_in uses.
"""

import json
import random
import re
import sys

STOP = set("""a an the of to in on at by for from with and or is are be it its
this that as into over under after before when where which what how not no do
does done use used using return returns returning value values""".split())

# Deterministic. A case set that changes between runs cannot measure a change.
SEED = 20260822
PER_FAMILY = 150


def words(text):
    return [w for w in re.split(r"[^A-Za-z0-9]+", text or "") if w]


def name_words(name):
    """NAME split on separators and on a lower-to-upper case change, lowercased."""
    out = []
    for chunk in re.split(r"[^A-Za-z0-9]+", name or ""):
        for part in re.findall(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+", chunk):
            if part:
                out.append(part.lower())
    return out


def inflect(word):
    """A plausible inflection of WORD, or None.

    Deliberately naive and deliberately not a stemmer's inverse: a query writer
    types "splitting lines" or "configs", not a morphologically ideal form. The
    point is that the ranker should reach the target from either.
    """
    if len(word) < 4 or not word.isalpha():
        return None
    if word.endswith("y"):
        return word[:-1] + "ies"
    if word.endswith(("s", "x", "z", "ch", "sh")):
        return word + "es"
    if word.endswith("e"):
        return word[:-1] + "ing"
    return word + "s"


def build(rows, repo):
    prose, inflected, plain = [], [], []
    for e in rows:
        name = e["name"]
        nw = name_words(name)
        if len(name) < 4 or not nw:
            continue
        own = set(nw)

        # name: the name as plain words
        if len(nw) >= 2:
            plain.append((repo, " ".join(nw), name, "name"))

        # inflected: one word of the name replaced by an inflection
        if len(nw) >= 2:
            for i, w in enumerate(nw):
                bent = inflect(w)
                if bent:
                    q = list(nw)
                    q[i] = bent
                    inflected.append((repo, " ".join(q), name, "inflected"))
                    break

        # prose: the docstring minus the name's own words
        doc = e.get("doc") or ""
        if doc:
            keep = [w for w in words(doc)
                    if w.lower() not in own and w.lower() not in STOP and len(w) > 2]
            if len(keep) >= 4:
                prose.append((repo, " ".join(keep[:12]).lower(), name, "prose"))
    return prose, inflected, plain


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: make-cases.py <repo>=<dump.json> ...")
    families = {"prose": [], "inflected": [], "name": []}
    for arg in sys.argv[1:]:
        repo, _, path = arg.partition("=")
        rows = json.load(open(path))
        p, i, n = build(rows, repo)
        families["prose"] += p
        families["inflected"] += i
        families["name"] += n

    rng = random.Random(SEED)
    out = []
    for family, cases in families.items():
        cases.sort()                      # stable before sampling
        rng.shuffle(cases)
        out += cases[:PER_FAMILY]
    json.dump(out, sys.stdout, indent=1)
    print(file=sys.stdout)
    for family, cases in families.items():
        print("%-10s %d available, %d sampled"
              % (family, len(cases), min(PER_FAMILY, len(cases))), file=sys.stderr)
    print("total sampled: %d" % len(out), file=sys.stderr)


if __name__ == "__main__":
    main()
