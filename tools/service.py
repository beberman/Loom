#!/usr/bin/env python3
"""Bring the Loom service up, and refuse to measure against one that is not there.

    import service
    watched = service.ensure(__file__, repositories=("Loom", "game-server"))

RULE-0008. Every instrument under tools/ that scores an answer -- acceptance.py,
recall.py, seed-sheet.py -- reads it over REST from a service somebody else was
expected to have started. Each one had its own failure mode when nobody had:
acceptance.py raised URLError out of main() and printed a traceback, recall.py
caught the exception per case, continued, and printed `ALL strict 0/450 0.0%',
and seed-sheet.py wrote a CSV of empty rows. Only the first of those is
survivable, and none of them says what actually happened.

The shape of the fix is tools/harness.lisp's, applied to the Python side: a
measurement that did not happen must not read like one that returned nothing to
say. So this exits 1 with a sentence naming the instrument, what could not be
reached, and what is therefore unmeasured -- CON-0001's rule about the graph,
applied to Loom's own instruments.

Why loom-serve.sh and not loom.sh. tools/loom.sh is the console: it watches the
tree, runs the commands, and stops, so every invocation pays a full reindex of
every tree it names and builds no vector store at all. That is the right cost
for one question from a terminal and the wrong one for a harness making 450
calls, which would pay it 450 times over. tools/loom-serve.sh owns the service's
lifecycle (DES-0007 R4), and its `update' verb starts a service that is down,
restarts one whose code is stale, and does nothing at all to one that is already
current -- which on most runs is nothing.

Waiting is this module's job and not the caller's. `update' returns as soon as
the port answers; the trees are still being read behind it, and the vector
stores are built after that. A repository in :embedding answers lexically and
correctly and without the semantic candidates it would have had a minute later
(REPOSITORY-STATE), so a recall number scored against it is a real number
measuring the wrong mechanism. This blocks until every named repository reports
:ready.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:4780/v1"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCHER = os.path.join(ROOT, "tools", "loom-serve.sh")

# ~90s of fasl compilation on a cold cache, then nine trees read, then the
# vector stores: 66s for game-server's 1811 definitions and 183 for front-end's
# 3457. 900 is a generous multiple of the whole sequence and is a ceiling rather
# than a wait -- a service already up and current clears it in one poll.
READY_TIMEOUT = 900


BRING_IT_UP = "Bring the service up with:  tools/loom-serve.sh update"


def refused(instrument, reason, unmeasured="whatever it measures",
            remedy=BRING_IT_UP):
    """Say that INSTRUMENT did not run, and exit non-zero.

    The Python twin of LOOM-HARNESS:REFUSED, worded the same way on purpose:
    the two are read by the same person on the same afternoon, and a reader who
    has learned what one refusal means should not have to learn the other.
    """
    print(
        "\n%s did not run.\n"
        "  %s\n"
        "  Nothing was measured. This is not a result of zero -- it is the\n"
        "  instrument having nothing to ask, and %s is unknown\n"
        "  until that is fixed.\n"
        "  %s\n"
        % (os.path.basename(str(instrument)), reason, unmeasured, remedy),
        file=sys.stderr)
    sys.exit(1)


def get(path, timeout=60):
    """One REST read, or None if the service did not answer it."""
    try:
        with urllib.request.urlopen(BASE + path, timeout=timeout) as response:
            return json.load(response)
    except Exception:
        return None


def watched_repositories():
    """Repository name -> its status plist, for the trees the service holds.

    An empty dict means the service did not answer, which is not the same as a
    service holding no repositories -- callers that need to tell the two apart
    should have gone through ENSURE, which does.
    """
    status = get("/status")
    if not status:
        return {}
    return {r["name"]: r for r in status.get("repositories", [])}


def resolve(watched, name):
    """The service's own spelling of NAME, or None if it holds no such tree.

    Case-insensitively, because FIND-REPOSITORY matches a designator with
    STRING-EQUAL and every caller here writes the name by hand: acceptance.py's
    absence cases say "loom" where /status says "Loom", and both name the same
    tree to every operation that takes a designator.
    """
    if name in watched:
        return name
    lowered = name.lower()
    for held in watched:
        if held.lower() == lowered:
            return held
    return None


def launch(instrument):
    """`tools/loom-serve.sh update', with its own output kept.

    Not silenced: on the path that matters -- a stale service being restarted --
    this is the only thing on the terminal for a minute and a half, and a silent
    minute and a half reads as a hang.
    """
    try:
        done = subprocess.run([LAUNCHER, "update"], cwd=ROOT,
                              capture_output=True, text=True,
                              timeout=READY_TIMEOUT)
    except FileNotFoundError:
        refused(instrument, "%s is not there." % LAUNCHER)
    except subprocess.TimeoutExpired:
        refused(instrument,
                "tools/loom-serve.sh update did not return within %ds."
                % READY_TIMEOUT)
    # Every line, not the last one. `update' on a stale service prints two --
    # "stopped (pid N)" then "started (pid M)" -- and showing only the second
    # reads as a service that was down when it was in fact restarted.
    lines = (done.stdout or "").strip().splitlines() + \
            (done.stderr or "").strip().splitlines()
    for line in (lines or ["no output"]):
        print("service: %s" % line, file=sys.stderr)
    if done.returncode != 0:
        refused(instrument,
                "tools/loom-serve.sh update exited %d: %s"
                % (done.returncode, (done.stderr or "").strip()[:200]))


def await_ready(instrument, repositories):
    """Block until every named repository reports :ready, then return them all.

    A repository the service does not hold at all is refused rather than waited
    for: it is missing from tools/extra-repos, and no amount of waiting adds it.
    """
    started = time.time()
    deadline = started + READY_TIMEOUT
    announced = set()
    while True:
        watched = watched_repositories()
        if watched:
            held = {r: resolve(watched, r) for r in repositories}
            missing = [r for r, name in held.items() if name is None]
            if missing and time.time() - started > 30:
                # 30s of grace: WATCH-REPOSITORY registers a tree before it has
                # finished reading it, but a restart registers all of them
                # within seconds, so a name still absent after half a minute is
                # absent from tools/extra-repos rather than slow.
                refused(instrument,
                        "the service is up but does not hold %s."
                        % ", ".join(missing),
                        unmeasured="every case naming %s" % ", ".join(missing),
                        remedy="Add the tree to tools/extra-repos, then:  "
                               "tools/loom-serve.sh restart")
            waiting = [name for name in held.values()
                       if name and watched[name].get("state") not in (None, "ready")]
            if not missing and not waiting:
                return watched
            for name in waiting:
                key = (name, watched[name]["state"])
                if key not in announced:
                    announced.add(key)
                    print("service: %s is %s; waiting" % key, file=sys.stderr)
        if time.time() > deadline:
            refused(instrument,
                    "the service did not reach ready within %ds." % READY_TIMEOUT)
        time.sleep(2)


def describe(watched, repositories):
    """One line per repository naming the index that is about to answer.

    REQ-0050 R4's question asked before the run rather than after it. The same
    facts acceptance.py's MEASURED_AGAINST prints from the status call and
    recall.py reads off the bundles: which commit, whether the working tree has
    moved past it, and how many claimed files the index is behind on.
    """
    for name in repositories:
        row = watched.get(resolve(watched, name) or name) or {}
        commit = (row.get("commit") or "")[:12] or "commit unknown"
        if row.get("branch"):
            commit += " (%s)" % row["branch"]
        if row.get("dirty"):
            commit += " + uncommitted edits"
        drift = row.get("drift")
        if drift is None:
            tail = "staleness unknown"
        elif drift:
            tail = ("STALE INDEX: %d claimed file%s changed since it was read"
                    % (drift, "" if drift == 1 else "s"))
        else:
            tail = "index current with the tree"
        print("service: %s %s  %s" % (name, commit, tail), file=sys.stderr)


def ensure(instrument, repositories=()):
    """Start or refresh the service, wait for REPOSITORIES, and describe them.

    Returns the same dict WATCHED_REPOSITORIES does, so a caller that needed it
    anyway does not make the call twice. Never returns against a service it
    could not reach -- that path exits.
    """
    repositories = tuple(dict.fromkeys(repositories))
    launch(instrument)
    watched = await_ready(instrument, repositories)
    describe(watched, repositories)
    return watched


if __name__ == "__main__":
    ensure(__file__, repositories=sys.argv[1:] or ("Loom",))
