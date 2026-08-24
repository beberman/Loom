#!/usr/bin/env python3
"""REQ-0016 R9's recall count, on the two trees this work does not commit to.

Loom is deliberately absent. It is one of the indexed trees and every commit to
it changes the corpus a Loom-side clause measures: R6-loom went 1/1 to 0/1 with
no seeder change, because a session's own commits grew the index from 140 items
to 144 and pushed MAKE-MACRO-ENTITY out of eighth place. game-server and
front-end are not written to by this work, so their corpora hold still.

Usage:  python3 tools/acceptance.py             the hand-written cases
        python3 tools/acceptance.py --log      the judgements the log recorded
        python3 tools/acceptance.py --sessions the log as the sequences it holds

REQ-0036 R10 and R11. The --log mode reads .loom/context/, joins each record
with the used set an agent filed against it, and reports the three populations
R3 names. The hand-written cases stay: they are the only judgements in the
system not shaped by what the current seeder returned, and R11 makes them the
held-out set. Nothing here trains on them and nothing here rewrites them.

REQ-0038 R4 and R6, DES-0031 D7-D11. A judgement is scored against the operation
its record names rather than against `context'; a used entry that is not an
entity name is classified before the freshness gate rather than resolved by it;
and --sessions prints the directory in time order, which is how a recovery --
context, then find, then describe on what find returned -- is read back.
"""
import urllib.request, urllib.parse, json, time, sys, os, glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import service

B = service.BASE

CASES = [
    # game-server -- REQ-0016's own acceptance clauses
    ("game-server", "data-handler",
     ["data-handler","db-handler","null-handler","table-handler","model-handler",
      "game-handler","dhandler-get","dhandler-put","dhandler-delete","dhandler-update"], "R6"),
    ("game-server", "data-api handler database connection acquire and test connectivity",
     ["connection-connect-database"], "R8"),
    # config-get is gone from this list and BUG-0043 is why: it was renamed to
    # config-search and moved to the standalone utils library, so it is not a
    # game-server entity under either spelling and no ranking, expansion or
    # embedding could ever have returned it. R7 was scored 6 of 7 for as long
    # as it existed, and the seventh was unreachable rather than missed. The
    # judgement it carried -- that configuration belongs to the startup
    # sequence -- is kept by read-config, which is a game-server entity and is
    # found. The key lookup is judged as a utils case below.
    ("game-server", "start-server startup sequence and database handler health check",
     ["start-server","read-config","set-cors-handler","initialize-game-api",
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
    # loom -- the four misses the context log recorded against Loom's own tree on
    # 2026-08-18, turned into cases by REQ-0039. Each was recovered by the agent
    # with `find` after `context` returned lexical matches, and each names the
    # entity the judgement says was the answer. They are expected to fail until
    # REQ-0039 lands: a case that fails is what a target looks like, and the
    # summary line counts them separately from the ones that guard a behaviour.
    # The first two moved: PLAN-0036 S1 deleted Loom's SLURP-FILE and SPLIT-LINES
    # for the library's, so the tree that now holds the answer is `utils' and a
    # case naming `loom' would fail for a reason that is not the ranking's.
    #
    # Retargeted they PASS, and that is worth reading carefully rather than as
    # good news: they pass because READ-FILE and STRING-LINES contain the task's
    # own words, where SLURP-FILE and SPLIT-LINES did not and were missed. So
    # these two are regression guards on a name match, not targets for REQ-0039.
    # r39-3 is the target: DOT-PREFIXED-P shares no token with "starts with a
    # prefix" except through its docstring, and it is the one that still misses.
    ("utils", "read a whole file into a string", ["read-file"], "r39-1"),
    ("utils", "split a string on a delimiter character", ["string-lines"], "r39-2"),
    # BUG-0043's other half. A fresh judgement rather than R7's retargeted: the
    # query was written once, before it was run, and whatever it scores is what
    # it scores. It inherits no standing from the expectation it replaces.
    ("utils", "look up a configuration value by its key", ["config-search"], "cfg-1"),
    ("loom", "test whether a string starts with a prefix", ["dot-prefixed-p"], "r39-3"),
    # PLAN-0036 S4 deleted PLIST-SHAPED-P: the encoder now calls UTILS:PLISTP,
    # so no mechanism can return the old name however good retrieval gets. This
    # is BUG-0043's shape for the second time -- an expectation naming an entity
    # a migration moved -- and the fix is the same, trim the expectation to what
    # the tree still holds rather than let a standing miss read as a ranking
    # defect. ALIST-PLIST is untouched and is what the query was really about.
    ("loom", "look up a value in an alist or plist by key",
     ["alist-plist"], "r39-4"),

    # ---------------------------------------------------------------------
    # Loaded from the judged records in .loom/context, 2026-08-21. These are
    # queries somebody asked and answers somebody used, which is the corpus
    # REQ-0036 exists to build and REQ-0016 is measured against; promoting them
    # here makes them regression guards rather than a set re-read from disk on
    # every run.
    #
    # Loaded by hand, and that is the finding rather than a shortcut. Of the 15
    # judged records, an automatic import produces garbage three ways:
    #
    #   * 12 of the 41 `used' entries are not entity names at all -- "(overflow)",
    #     "the bundle itself", "cross-repository comparison", a file path, a
    #     slash-joined list of three names.
    #   * 9 name entities that no longer resolve, because PLAN-0002 and PLAN-0036
    #     moved them: slurp-file, split-lines, alist-object-p, dict-value,
    #     config-get, make-dict. The corpus decays as the trees move, which is
    #     what REQ-0036 R4's unverifiable state is about.
    #   * and the verdict lives in prose. DES-0001 was returned and the agent
    #     wrote "not relevant -- it is the dhandler health-check design"; an
    #     importer reading `name' alone would make noise into an expectation and
    #     the harness would then defend it. Every entry below was read.
    #
    # REQ-0044 asks for the probe flag. This is the same defect one level up:
    # a judgement's verdict is as unreadable to a program as its exclusion is.
    # ---------------------------------------------------------------------
    ("loom", "trim whitespace from a string",
     ["js-trim", "whitespace-char-p"], "log-1"),
    ("loom", "encode a value as JSON",
     ["json-value", "json-array"], "log-2"),
    # The judged answer was SPLIT-LINES and it is gone; SPLIT-COMMAND-LINE was
    # the seed that was used, so that is what this guards.
    ("loom", "split a string on a delimiter character",
     ["split-command-line"], "log-3"),
    # The half of the question that survived PLAN-0036: the file reader moved to
    # the library (r39-1), the range slicer did not.
    ("loom", "read a source file from disk and slice a line range out of it",
     ["definition-source"], "log-4"),
    # ARCH-0001 is the one document band hit anybody recorded as good. DES-0001
    # came back on the same call and is deliberately absent here.
    ("game-server",
     "split the utils system into a residual gs-utils and the standalone utils "
     "library: rename the package, repoint config-get dict-value read-config "
     "make-dict call sites, and set the JSON key policy",
     ["read-config", "ARCH-0001"], "log-5"),
]

# REQ-0037: the queries whose right answer is that nothing here does that. They
# are not in CASES because CASES asks "is this name present" and the assertion
# here is the opposite one. Since DES-0032 there is something to assert against:
# a bundle reports each of the caller's words as answered, weak or unmatched,
# and these cases pass when the word carrying the subject is not answered.
#
# The subject word is named per case rather than inferred. "parse a number out
# of a string" has three reportable terms and two of them -- parse, string --
# are answered by names that exist and are not what the task asked for; the
# claim being tested is about `number' specifically. Inferring it would make the
# case pass on any word going unanswered, which every real query also does.
#
# Re-checked on 2026-08-22 against a tree that had moved under them: `find join'
# now returns 2 and `find encoding' 2, where the judged record for the first
# read "confirmed with find term=join returning nothing". Both hits in each are
# unrelated -- "disjoint extensions" and "joins a test package"; two tests about
# JSON integer encodings -- so all three remain true negatives. The counts
# drifted, the verdicts did not.
ABSENCE_CASES = [
    ("loom", "join a list of strings with a separator", ["join", "separator"], "r37-1"),
    ("loom", "parse a number out of a string", ["number"], "r37-2"),
    ("loom", "reading a file with an encoding fallback when it is not UTF-8",
     ["encoding", "fallback"], "r37-3"),
]


def term_states(bundle):
    """Reported term -> state, from the bundle's DES-0032 D3 field."""
    return {r["term"]: str(r.get("state", "")).lower()
            for r in (bundle.get("terms") or [])}


def run_absence_cases():
    """REQ-0037's acceptance: the subject word must not come back answered.

    Returns the number of failures. A case fails two ways and they are worth
    telling apart: the subject word reported `answered', which is the defect
    REQ-0037 exists to remove, and the subject word not reported at all, which
    means the term never reached the report and the case is measuring nothing.
    """
    failures = 0
    print()
    for repo, q, subjects, label in ABSENCE_CASES:
        t = time.time()
        b = json.load(urllib.request.urlopen(
            B + "/context?" + urllib.parse.urlencode({"repository": repo, "task": q}),
            timeout=240))
        el = time.time() - t
        states = term_states(b)
        bad = []
        for w in subjects:
            if w not in states:
                bad.append("%s not reported" % w)
            elif states[w] == "answered":
                bad.append("%s answered" % w)
        failures += 1 if bad else 0
        shown = ", ".join("%s=%s" % (w, states.get(w, "-")) for w in subjects)
        print("[%-7s] %s  seeds %d  %.2fs  %s"
              % (label, "absent " if not bad else "FAIL   ", len(b.get("seeds") or []),
                 el, shown if not bad else "; ".join(bad)))
    return failures

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
    return service.watched_repositories()


def measured_against(repository="Loom"):
    """One line naming what produced the score, and whether it is current.

    REQ-0050 R4. This harness drives a running service, so the service's build
    is what answered and nothing here said which. On 2026-08-23 it reported 43
    of 45 four times against a service started before any of that day's work,
    and three of those runs were quoted as verification of changes they could
    not have seen.

    `drift' rather than a diff hash. The first version compared the service's
    `git diff HEAD' against this tree's, which moves when any file moves --
    including the ones no analyzer claims. Editing this very file made it
    report a stale service whose index was current, within an hour. The service
    now answers from REPOSITORY-STAMPS, its own record of the bytes each
    claimed file had when it read them, so drift counts exactly the files the
    index is behind on and nothing else.
    """
    row = watched_repositories().get(repository, {})
    commit, drift = row.get("commit"), row.get("drift")
    if not commit:
        return ("measured against: the service reports no commit, so which "
                "build answered is unknown")
    line = f"measured against: service at {str(commit)[:12]}"
    if drift is None:
        return line + "  (the service reports no drift; staleness unknown)"
    if drift:
        return line + (f"  <-- STALE INDEX: {drift} claimed file"
                       f"{'' if drift == 1 else 's'} changed since it was read")
    return line + "  (index current with the tree)"


def records(directory):
    """Every record in DIRECTORY, in the order it was written."""
    out = []
    for path in sorted(glob.glob(os.path.join(directory, "ctx-*.json"))):
        if path.endswith(".used.json"):
            continue
        with open(path) as f:
            out.append(json.load(f))
    return out


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


# REQ-0038 R1's ten read operations, in the spellings a judgement uses. The MCP
# skin prefixes them, so `loom_structure' credits `structure'.
OPERATIONS = {"context", "find", "describe", "impact", "structure", "check",
              "rules", "status", "drift", "check-document"}

# The markers the agent invented in the `name' slot when the entry was not a
# name. Recognised here rather than parsed out of `how': REQ-0044 asks for a
# field that would make this unnecessary and this does not preempt it -- these
# are three literal strings in a slot the scorer already reads, not a reading of
# the prose beside them.
MARKERS = {
    "(nothing)": "absent",     # the correct answer was that nothing exists (REQ-0037)
    "(overflow)": "unread",    # the bundle was right and could not be read (REQ-0040)
    "(probe)": "probe",        # not a real question; exclude from measurement (REQ-0044)
}


def classify_used(entry):
    """One used entry as the claims it actually makes.

    DES-0031 D7. A used entry is not always an entity name, and reading it as one
    is what dropped 12 of the 15 judged records: FRESHNESS resolves every name
    and discards the record when one fails, so an agent that named the readability
    failure or flagged its own probe deleted its record from the measurement.

    Returns a list because a slash-joined list of names is several claims. The
    kinds are:

      entity  a bare name, and the only kind that is a claim about ranking. Only
              this kind is asked to resolve.
      credit  the entry names another operation as where the answer came from,
              recognised by its first token. D9: a label, never a score.
      marker  one of MARKERS.
      note    prose. Reported, not scored, and not evidence against anything."""
    name = (entry.get("name") or "").strip()
    if not name:
        return []
    if name in MARKERS:
        return [(MARKERS[name], name)]
    parts = [p.strip() for p in name.split(" / ")]
    if len(parts) > 1 and all(p and " " not in p for p in parts):
        # Several names under one verdict, and the verdict is in `how'. Splitting
        # them into separate claims was tried and is wrong: the entry reading
        # "game / ensure-game-row / encode-response / outcome-unchanged /
        # grid-version" is judged NOISE -- returned and deliberately not used --
        # and five independent claims read it as five hits, which is the exact
        # inversion this step exists to repair. Under-counting a miss is a stated
        # limitation; manufacturing a hit is a corrupted number. REQ-0044's field
        # is what would let these be read.
        return [("note", name)]
    first = name.split()[0].lower()
    if first.startswith("loom_"):
        first = first[len("loom_"):].replace("_", "-")
    if first in OPERATIONS:
        return [("credit", first)]
    if " " not in name:
        return [("entity", name)]
    return [("note", name)]


def attribution(record):
    """Which operation this record is about, and how that was decided.

    DES-0031 D8. `declared' reads the :OPERATION field. `inferred' reads the
    schema that predates it -- `task' with `returned.seeds' and `returned.items'
    is a context record and nothing else in this directory has that shape -- and
    is reported as an inference so anybody who doubts it can check it. `unknown'
    is neither, and is the only one that goes unscored."""
    declared = record.get("operation")
    if declared:
        return declared, "declared"
    returned = record.get("returned") or {}
    if "task" in record and "seeds" in returned and "items" in returned:
        return "context", "inferred"
    return None, "unknown"


def returned_names(record):
    """The names a context record says came back, in rank order.

    Empty for every other operation, and that is D10 rather than a gap: R2
    records a `find''s count and not its list, so a judgement against one cannot
    be resolved into a rank and is scored on whether the answer was empty."""
    return [i["name"] for i in (record.get("returned") or {}).get("items") or []]


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


_RESOLVED = {}


def resolves(repository, name):
    """True when NAME still names something in a live index.

    Every watched repository, not only the one the query ran against, and a
    package-qualified spelling falls back to the bare name.

    Both are the same defect met once. A judgement records what an agent used,
    and REQ-0036 R2 is explicit that this is "deliberately not restricted to
    what the bundle returned" -- so the names in it come from wherever the
    agent looked, which since `similar' and `survey' is routinely a second
    repository. Asking only the record's own repository marks such a record
    unverifiable and throws the whole thing away.

    Measured on the record that found it, ctx-20260824T002130: four hits at
    ranks 1, 2, 4 and 6, discarded because the fifth name was `utils:json-decode'
    -- the answer, one repository away, written the way a person writes a
    cross-package reference. docs/TODO.md carries the same gap twice already,
    for `find' and for a completed plan's `affects:'.

    Memoised: each miss is an HTTP round trip and on this corpus that was the
    whole of the harness's runtime.
    """
    key = (repository, name)
    if key in _RESOLVED:
        return _RESOLVED[key]
    bare = name.split(":")[-1] if ":" in name else name
    candidates = [repository] + [r for r in watched_repositories() if r != repository]
    answer = False
    for where in candidates:
        for spelling in ({name, bare} if bare != name else {name}):
            try:
                found = json.load(urllib.request.urlopen(
                    B + "/find?" + urllib.parse.urlencode({"repository": where,
                                                           "term": spelling}),
                    timeout=60))
                if any(e.get("name") == spelling for e in found.get("entities", [])):
                    answer = True
                    break
            except Exception:
                pass
        if answer:
            break
    _RESOLVED[key] = answer
    return answer


def freshness(record, entity_names, watched):
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
                    reference no watched repository holds.

    ENTITY_NAMES is what CLASSIFY_USED kept, not every `used' name. That is the
    whole of D7: a marker or a sentence resolves to nothing because it is not a
    name, and letting it reach this test discards the record it was explaining."""
    declared = record.get("repository") or {}
    if not isinstance(declared, dict):
        return "unwatched"
    name = declared.get("name")
    if name not in watched:
        return "unwatched"
    live = live_fingerprint(watched[name]["root"])
    if live and (live["commit"] == declared.get("commit")
                 and live["diffHash"] == declared.get("diffHash")):
        return "current"
    for entity in entity_names:
        if not resolves(name, entity):
            return "unverifiable"
    return "checkable"


SESSION_GAP_SECONDS = 30 * 60


def parse_at(record):
    try:
        return time.mktime(time.strptime(record["at"], "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None


def sessions(all_records, gap=SESSION_GAP_SECONDS):
    """The directory cut into runs of calls, by the gap between consecutive ones.

    DES-0031 D11, and the whole of R6 rather than a stand-in for it. No field, no
    caller declaration and no concept MCP does not have: the records are already
    time-ordered in one directory, and where they stop for half an hour the
    session stopped. The caller identity an earlier draft of R6 asked for was
    dropped -- a field every caller must remember to declare is empty in exactly
    the long sessions worth reading.

    A heuristic, and named as one -- it merges two sessions that abut and splits
    one that paused. Both failures are visible in the printed sequence, which is
    why the sequence is printed rather than a statistic taken over it."""
    out, current, previous = [], [], None
    for record in sorted(all_records, key=lambda r: r.get("at") or ""):
        at = parse_at(record)
        if previous is not None and at is not None and at - previous > gap:
            out.append(current); current = []
        current.append(record)
        if at is not None:
            previous = at
    if current:
        out.append(current)
    return out


def one_line(record):
    """A record as the one line a session listing shows it as."""
    operation, how = attribution(record)
    label = f"{operation or '?'}{'*' if how == 'inferred' else ''}"
    if operation == "context":
        subject = repr(record.get("task", "")[:52])
        answer = f"{len(returned_names(record))} items"
    else:
        arguments = record.get("arguments") or {}
        subject = " ".join(f"{k}={v}" for k, v in arguments.items()
                           if k not in ("repository",))[:52] or "-"
        shape = record.get("answer") or {}
        answer = ("none" if shape.get("none") is True
                  else f"{shape.get('count', '?')} {shape.get('kind', '')}".strip())
    repository = (record.get("repository") or {})
    repository = repository.get("name", "-") if isinstance(repository, dict) else "-"
    return f"  {record['at'][11:19]}  {label:10} {repository:12} {subject:54} -> {answer}"


def sessions_main():
    """R6: print the log as the sequences it recorded."""
    all_records = records(LOG_DIRECTORY)
    if not all_records:
        print(f"no records in {LOG_DIRECTORY}")
        return 0
    runs = sessions(all_records)
    for run in runs:
        print(f"\n=== {run[0]['at'][:10]} {run[0]['at'][11:19]}"
              f"-{run[-1]['at'][11:19]}  {len(run)} calls")
        for record in run:
            print(one_line(record))
        kinds = [attribution(r)[0] for r in run]
        recoveries = sum(1 for i, k in enumerate(kinds[:-1])
                         if k == "context" and kinds[i + 1] in ("find", "describe"))
        if recoveries:
            print(f"  -- {recoveries} context call(s) followed directly by "
                  f"find or describe")
    print(f"\n{len(all_records)} record(s) in {len(runs)} session(s), "
          f"cut on a {SESSION_GAP_SECONDS // 60}-minute gap")
    print("A session is the directory in time order, which is the whole "
          "mechanism: there is nothing in MCP to identify a caller by, so R6 "
          "asks for the ordering and not for an identity.")
    return 0


def log_main():
    directory = LOG_DIRECTORY
    pairs = judgements(directory)
    if not pairs:
        print(f"no judgements in {directory}")
        print("A record is written by a context call and completed by "
              "loom_context_used; both halves are needed before anything scores.")
        return 0
    # RULE-0008, and here it decides an answer rather than a traceback. RESOLVES
    # asks the service whether a judged name still exists, and against a service
    # that is down every ask fails, every name reads as gone, and every record
    # is reported `unverifiable' -- a verdict about the corpus produced by an
    # absent instrument.
    watched = service.ensure(__file__)
    hits = misses = unused = 0
    per_operation = {}
    populations = {"absent": 0, "unread": 0, "note": 0, "credit": 0}
    scored = probes = unattributed = 0

    for record, used in pairs:
        operation, how = attribution(record)
        claims = [c for entry in used for c in classify_used(entry)]
        by_name = {}
        for entry in used:
            for kind, value in classify_used(entry):
                by_name.setdefault((kind, value), entry)

        label = f"{operation or 'unattributed'}{'*' if how == 'inferred' else ''}"
        if any(kind == "probe" for kind, _ in claims):
            state = "probe"
        elif operation is None:
            state = "unattributed"
        else:
            state = freshness(record,
                              [v for k, v in claims if k == "entity"], watched)
        subject = record.get("task") or " ".join(
            f"{k}={v}" for k, v in (record.get("arguments") or {}).items())
        print(f"[{record['id']}] {label:11} {state:12} {subject[:44]!r}")

        counting = state in ("current", "checkable")
        if state == "probe":
            probes += 1
        elif state == "unattributed":
            unattributed += 1
        if counting:
            scored += 1

        returned = returned_names(record)
        shape = record.get("answer") or {}
        for kind, value in claims:
            entry = by_name[(kind, value)]
            how_found = (entry.get("how") or "")
            if kind == "entity" and operation == "context":
                if value in returned:
                    if counting:
                        hits += 1
                    print(f"    hit    {value}  at {returned.index(value) + 1} "
                          f"of {len(returned)}")
                else:
                    if counting:
                        misses += 1
                    print(f"    miss   {value}  found by: {how_found[:100]}")
            elif kind == "entity":
                # D10: the record holds a count and not a list, so the question a
                # judgement against it can answer is whether the answer was empty.
                verdict = "empty" if shape.get("none") is True else "answered"
                if counting:
                    hits += 1
                print(f"    {verdict:6} {value}  ({operation} returned "
                      f"{shape.get('count', '?')})")
            elif kind == "credit":
                populations["credit"] += 1
                per_operation[value] = per_operation.get(value, 0) + 1
                print(f"    credit {value}  {entry.get('name')!r}")
            elif kind == "absent":
                populations["absent"] += 1
                print(f"    absent correct negative: {how_found[:88]}")
            elif kind == "unread":
                populations["unread"] += 1
                print(f"    unread the answer could not be read: {how_found[:70]}")
            elif kind == "probe":
                print(f"    probe  excluded: {how_found[:88]}")
            else:
                populations["note"] += 1
                print(f"    note   {value[:60]!r}")

        if operation == "context":
            named = {v for k, v in claims if k == "entity"}
            leftover = [n for n in returned if n not in named]
            if leftover and counting:
                unused += len(leftover)
            if leftover:
                print(f"    unused {len(leftover)} of {len(returned)} returned")

    print(f"\n{len(pairs)} judgement(s): {scored} scored, {probes} probe, "
          f"{unattributed} unattributed")
    print(f"ranking: {hits} hit, {misses} missed, {unused} returned and not used")
    if per_operation:
        credits = ", ".join(f"{k} {v}" for k, v in sorted(per_operation.items()))
        print(f"credited to another operation: {credits}")
    print(f"not a ranking claim: {populations['absent']} correct negative, "
          f"{populations['unread']} unreadable, {populations['note']} note(s)")
    print("A miss is the only record that raises recall. A hit's rank says how "
          "nearly it was not one. A credit is a label and adds to no recall "
          "figure: a record holding a count and no names cannot support one.")
    return 0


def main():
    # RULE-0008. The cases below name four trees, and every one of them is a
    # question this harness cannot ask of a service that is down, and cannot
    # score against one still embedding: a repository in :embedding answers
    # lexically, so its recall is a real number measuring half the seeder.
    service.ensure(__file__,
                   repositories=sorted({c[0] for c in CASES}
                                       | {c[0] for c in ABSENCE_CASES},
                                       key=str.lower))
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
    print()
    print(measured_against())
    print(f"strict  {total-missing_strict}/{total} present, {missing_strict} missing")
    print(f"lenient {total-missing_lenient}/{total} present, {missing_lenient} missing")
    print(f"slowest {slowest:.2f}s")
    # REQ-0037's clause: the negatives must not be bought by refusing to answer
    # the positives, so these run after the recall count and both must hold.
    absent_failures = run_absence_cases()
    if absent_failures:
        print(f"{absent_failures} of {len(ABSENCE_CASES)} absence cases failed")
    return 1 if (missing_lenient or absent_failures) else 0

if __name__ == "__main__":
    if "--sessions" in sys.argv:
        sys.exit(sessions_main())
    sys.exit(log_main() if "--log" in sys.argv else main())
