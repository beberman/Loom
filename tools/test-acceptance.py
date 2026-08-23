#!/usr/bin/env python3
"""Check how tools/acceptance.py reads a judgement, on cases rather than on the corpus.

REQ-0038 R4 and R6, DES-0031 D7-D11. The scorer's job is to say what a judgement
claims, and every defect it has had was a claim it read as a different one: a
sentence read as an entity name, a context record read as unattributed, a list of
five names under one NOISE verdict read as five hits. Those are the cases here,
and each is a case because it was once wrong.

Nothing here touches the live service or .loom/context. `--log' against the real
corpus asks the index whether a name still resolves, and every one of those asks
is itself a logged read -- so the corpus grows when it is measured, and a test
that ran the real thing would be a test that changed its own subject.

    tools/test-acceptance.py

Exit status is 0 when every case holds. Not part of the FiveAM suite: it tests a
Python harness, not Loom, so tools/loom-test.sh does not run it.
"""

import os
import sys
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "acceptance", os.path.join(HERE, "acceptance.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n     got  {got!r}\n     want {want!r}")


# ---------------------------------------------------------------- classify_used
#
# D7. 18 of the 41 entries in the real corpus are not entity names, and resolving
# them against the index is what dropped 12 of its 15 records.

check("a bare name is a claim about ranking",
      acceptance.classify_used({"name": "dot-prefixed-p"}),
      [("entity", "dot-prefixed-p")])

check("a qualified name is still a bare name",
      acceptance.classify_used({"name": "utils:encode"}),
      [("entity", "utils:encode")])

check("a file path is still a bare name",
      acceptance.classify_used({"name": "src/serve/json.lisp"}),
      [("entity", "src/serve/json.lisp")])

for marker, kind in (("(nothing)", "absent"), ("(overflow)", "unread"),
                     ("(probe)", "probe")):
    check(f"{marker} is the {kind} marker",
          acceptance.classify_used({"name": marker}), [(kind, marker)])

# D9. The four judgements REQ-0038 quotes, verbatim from the corpus.
check("a describe credit is recognised by its first token",
      acceptance.classify_used({"name": "describe inbound-calls edges"}),
      [("credit", "describe")])

check("a structure credit is recognised by its first token",
      acceptance.classify_used({"name": "structure system-edges"}),
      [("credit", "structure")])

check("a credit survives a parenthesised tail",
      acceptance.classify_used(
          {"name": "describe per exported symbol (103 calls over REST)"}),
      [("credit", "describe")])

check("the MCP spelling credits the same operation",
      acceptance.classify_used({"name": "loom_structure commit field"}),
      [("credit", "structure")])

# The one that was implemented the other way first and was wrong for it.
check("a slash-joined list is one note, not several claims",
      acceptance.classify_used(
          {"name": "game / ensure-game-row / encode-response / "
                   "outcome-unchanged / grid-version",
           "how": "NOISE, five of eight seeds."}),
      [("note", "game / ensure-game-row / encode-response / "
                "outcome-unchanged / grid-version")])

check("prose is a note",
      acceptance.classify_used({"name": "the bundle itself"}),
      [("note", "the bundle itself")])

check("prose that is not an operation is a note, not a credit",
      acceptance.classify_used({"name": "cross-repository comparison"}),
      [("note", "cross-repository comparison")])

check("an empty name claims nothing",
      acceptance.classify_used({"name": ""}), [])


# ----------------------------------------------------------------- attribution
#
# D8. Every judged record in the corpus predates the :OPERATION field, so a rule
# that reported them as unattributed would score nothing at all.

check("a declared operation is read from the field",
      acceptance.attribution({"operation": "find", "arguments": {}}),
      ("find", "declared"))

check("a context record predating the field is inferred from its schema",
      acceptance.attribution({"task": "x",
                              "returned": {"seeds": [], "items": []}}),
      ("context", "inferred"))

check("a declared operation wins over the schema",
      acceptance.attribution({"operation": "context", "task": "x",
                              "returned": {"seeds": [], "items": []}}),
      ("context", "declared"))

check("neither is unknown, and unknown is not assumed to be context",
      acceptance.attribution({"id": "ctx-1", "at": "..."}),
      (None, "unknown"))

check("a record with a task but no bundle is not a context record",
      acceptance.attribution({"task": "x"}), (None, "unknown"))


# --------------------------------------------------------------- returned_names
#
# D10. A find record holds a count and no list, so no rank can be taken from it.

check("a context record's items are its returned names in rank order",
      acceptance.returned_names(
          {"returned": {"items": [{"name": "a"}, {"name": "b"}]}}),
      ["a", "b"])

check("a find record names nothing, which is D10 and not a gap",
      acceptance.returned_names(
          {"operation": "find", "answer": {"kind": "entities", "count": 0,
                                           "none": True}}),
      [])


# -------------------------------------------------------------------- sessions
#
# D11. R6 for one agent: the directory in time order, cut on the gap.

run = [{"at": "2026-08-21T10:00:00Z"}, {"at": "2026-08-21T10:00:05Z"},
       {"at": "2026-08-21T10:00:09Z"}]
check("calls close together are one session",
      [len(s) for s in acceptance.sessions(run)], [3])

gapped = run + [{"at": "2026-08-21T14:00:00Z"}, {"at": "2026-08-21T14:00:02Z"}]
check("a gap wider than the threshold cuts a session",
      [len(s) for s in acceptance.sessions(gapped)], [3, 2])

check("records out of order are sorted before they are cut",
      [len(s) for s in acceptance.sessions(list(reversed(gapped)))], [3, 2])

check("the recovery R6 describes survives the round trip",
      [acceptance.attribution(r)[0] for r in acceptance.sessions([
          {"at": "2026-08-21T10:00:00Z", "task": "x",
           "returned": {"seeds": [], "items": []}},
          {"at": "2026-08-21T10:00:04Z", "operation": "find",
           "arguments": {"term": "x"}},
          {"at": "2026-08-21T10:00:07Z", "operation": "describe",
           "arguments": {"term": "x"}}])[0]],
      ["context", "find", "describe"])


if failures:
    print(f"{len(failures)} case(s) failed:\n")
    for failure in failures:
        print(" ", failure)
    sys.exit(1)
print("tools/acceptance.py: every case holds")
sys.exit(0)
