#!/bin/bash
# Bring the Loom service up, and keep it honestly current.
#
#   tools/loom-serve.sh status     is it running, and is its code current
#   tools/loom-serve.sh start      spawn it headless, detached
#   tools/loom-serve.sh stop       SIGTERM it and wait for it to go
#   tools/loom-serve.sh restart    stop, then start
#   tools/loom-serve.sh reload     stop, then start (an alias for restart)
#   tools/loom-serve.sh update     start / restart / nothing, whichever applies
#
# DES-0007 R4. `update' is the one verb meant to be called before relying on
# MCP or REST: it pays a restart's cost only when something actually changed,
# which on most sessions is nothing.
#
# It contains no Lisp of its own. Every check against a running process goes
# over the REST surface loom-rest already derives from the operation registry,
# so no hand-written route was ever needed here.
#
# What it does not do. It never writes the pidfile -- loom-serve.lisp writes
# its own, and only once its start-server call has actually won the port, so
# two concurrent `start' calls leave exactly one pidfile naming exactly the
# process that is listening. It never guesses a pid: a service it did not start
# is reported and left alone rather than killed. And it no longer decides which
# source changes are safe to load into a live image: after DES-0008 there is no
# in-place reload to decide about, and every path that brings code up to date is
# a fresh process.

set -u

root=/home/beberman/lisp/Loom
cd "$root" || exit 1

# The same rule loom-serve.lisp's own PIDFILE-PATH states in Lisp, written
# again here in shell rather than passed between the two: the root's absolute
# path, leading and trailing `/' trimmed, every remaining `/' turned into `-'.
# Restated rather than shared so a reader can compare the two directly. If they
# ever disagree the symptom is `stop' and `restart' reporting nothing to stop
# against a process that is plainly running.
sanitized=${root#/}
sanitized=${sanitized%/}
sanitized=${sanitized//\//-}

pidfile=/tmp/loom-serve-${sanitized}.pid
logfile=/tmp/loom-serve-${sanitized}.log

base=http://127.0.0.1:4780/v1
repository=${root##*/}

# Extra repositories to watch alongside this one, one absolute path per line,
# '#' comments and blank lines ignored. Gitignored, because the paths are a
# property of one machine and not of the project.
#
# It exists so dogfooding survives a restart. Loom's recurring defect is a
# mechanism correct on the tree it was developed against and wrong on the next
# one -- REQ-0012, REQ-0015 and REQ-0016 are three in one afternoon, and
# BUG-0030 is a fourth found the moment a third tree was watched. A tree that
# has to be re-watched by hand after every `update` is a tree nobody queries.
extra_repos_file=${LOOM_EXTRA_REPOS:-$(dirname "$0")/extra-repos}

# Context logging, DES-0030 D1. CONFIGURE-CONTEXT-LOG-FROM-ENVIRONMENT reads
# LOOM_CONTEXT_LOG once, at startup, and writes nothing when it is unset. This
# line used to default it to `1', which turned the log on for every service on
# this machine including the ones being restarted a dozen times an afternoon
# while Loom itself was being worked on.
#
# Off by default since 2026-08-22, and the reason is measured rather than
# tidiness. The log is a corpus REQ-0036 built so a ranking change could be
# measured; a session developing the ranking fills it with that session's own
# probes. On 2026-08-22 it held 2032 records, of which 15 carried a judgement:
# two runs of the 450-case known-item harness contributed 900 by themselves,
# and 39 distinct tasks accounted for 1100 records. Records that nobody judged
# and that answer a query nobody asked are not evidence, and they are what
# REQ-0044 asks for a field to mark.
#
# Turn it on for a session meant to produce judgements, which is what it is for:
#
#     LOOM_CONTEXT_LOG=1 tools/loom-serve.sh restart          the default directory
#     LOOM_CONTEXT_LOG=/tmp/probe tools/loom-serve.sh restart  somewhere else
#
# A value already in the environment still wins, so neither line above needs
# this file edited. `1' means <loom>/.loom/context/ -- inside a dot-directory,
# where REPOSITORY-FILES skips it, so the log cannot enter the index it judges.
export LOOM_CONTEXT_LOG=${LOOM_CONTEXT_LOG:-}

# ------------------------------------------------------------------
# Reading the answers back
# ------------------------------------------------------------------

# grep for the one key rather than a JSON parser: jq is not installed here, and
# the only shape this script reads is a number, which cannot contain the quoting
# a real parser exists to handle. A json_bool sat beside this until DES-0008
# R4; nothing reads a boolean out of a response any more.
json_number() { printf '%s' "${2-}" | grep -o "\"$1\":[0-9][0-9]*" | head -1 | sed 's/.*://'; }

# down | current | stale | unknown, set by probe and read by every verb.
state=down

probe() {
    local server_body status_body started indexed
    server_body=$(curl -sf --max-time 2 "$base/server-status" 2>/dev/null) || {
        state=down
        return
    }
    started=$(json_number started-at "$server_body")
    # A 400 here is the service running against some other tree, or something
    # having unwatched this one. DES-0007 R1: report that as unknown rather
    # than guessing current, which is CON-0001's fabricated fact in
    # operational clothing.
    status_body=$(curl -sf --max-time 15 "$base/status?repository=$repository" 2>/dev/null) || {
        state=unknown
        return
    }
    indexed=$(json_number indexed-at "$status_body")
    if [ -z "$indexed" ] || [ -z "$started" ]; then
        state=unknown
        return
    fi
    # :started-at directly, with nothing layered on top of it. DES-0007's third
    # PROBLEM finding -- that a successful in-place reload leaves :started-at
    # naming an earlier moment than the code actually running -- stops applying
    # under DES-0008 R1 and R2: the only mechanism left that changes running
    # code is a fresh process, so :started-at is always the moment the running
    # code was loaded.
    if [ "$indexed" -gt "$started" ]; then state=stale; else state=current; fi
}

# ------------------------------------------------------------------
# The one pidfile check
# ------------------------------------------------------------------

# Prints a pid only when the file names a process that is both alive and
# actually loom-serve; deletes the file otherwise. `kill -0' alone is not
# enough: a pidfile outlives its process whenever something ends it without its
# cooperation -- kill -9, an OOM kill, a crash -- and the OS is free to recycle
# that pid to something unrelated before anyone runs this script again.
#
# /proc is Linux-specific, matching this environment's stated platform, and
# DES-0007's CONSEQUENCES names that as a boundary rather than a portability
# promise. cmdline is NUL-separated, which grep handles without help.
#
# status, start, stop and restart all route through this rather than reading
# the pidfile themselves, so the stale-file cleanup happens once wherever it is
# first noticed instead of four times from memory.
live_pid_or_clean() {
    local pid
    [ -f "$pidfile" ] || return 0
    pid=$(tr -dc '0-9' < "$pidfile")
    if [ -z "$pid" ]; then rm -f "$pidfile"; return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$pidfile"; return 0; fi
    if grep -q loom-serve.lisp "/proc/$pid/cmdline" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi
    rm -f "$pidfile"
    return 0
}

# ------------------------------------------------------------------
# The verbs
# ------------------------------------------------------------------

cmd_status() {
    live_pid_or_clean >/dev/null
    probe
    case "$state" in
        down)    echo "not running"; return 1 ;;
        current) echo "running, code current" ;;
        stale)   echo "running, code stale (source changed since it was loaded)" ;;
        unknown) echo "running, self-watch not registered; staleness unknown" ;;
    esac
    return 0
}

cmd_start() {
    # Discarding the pid: the side effect, clearing a pidfile whose process a
    # signal this script never saw already ended, is the point.
    live_pid_or_clean >/dev/null
    probe
    if [ "$state" != down ]; then
        echo "already running ($state)"
        return 0
    fi
    # loom-serve.lisp takes any number of repository roots. A missing or empty
    # file leaves the array empty and the command identical to what it was.
    local extra=()
    if [ -f "$extra_repos_file" ]; then
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%%#*}
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [ -n "$line" ] && extra+=("$line")
        done < "$extra_repos_file"
    fi
    nohup sbcl --script loom-serve.lisp --headless "$root" \
          ${extra[@]+"${extra[@]}"} >>"$logfile" 2>&1 &
    disown
    # ~150s. It was 20, described as "a generous multiple of the seconds-scale
    # startup PLAN-0005 measured", and that stopped being true: a start whose
    # fasl cache is cold recompiles every system first, which on this machine is
    # 40 to 90 seconds. The symptom was a `start' that printed a failure and
    # returned 1 while the service came up fine ten seconds later -- survivable
    # when nothing depended on the success path, and not survivable now that
    # START_VECTOR_BUILDS hangs off it.
    local i
    for i in $(seq 1 300); do
        sleep 0.5
        probe
        if [ "$state" != down ]; then
            echo "started (pid $(live_pid_or_clean))"
            start_vector_builds
            return 0
        fi
    done
    echo "start: nothing answering on $base after ~150s; see $logfile" >&2
    return 1
}

# Ask the service to build every repository's vector store, and do not wait for
# any of them. DEC-0006's dependency is optional, and a launcher that blocked on
# it would make "start Loom" cost three minutes -- 66 seconds for game-server's
# 1811 definitions and 183 for front-end's 3457 -- for something a tree without
# ollama does not use at all.
#
# The wait belongs to whoever queries first, not to whoever starts the service:
# REPOSITORY-VECTORS blocks on a build in flight, so a bundle is never answered
# from half a store, and on the normal path the build has finished before anyone
# has typed a question.
#
# Failure is silence on purpose. No ollama, no model, a refused connection --
# all of them leave the lexical seeder answering exactly as it did before any of
# this existed (REQ-0048 R6), and a launcher that complained about an absent
# optional dependency would be reporting the normal state of most trees.
start_vector_builds() {
    local names name
    names=$(curl -sf --max-time 10 "$base/status" 2>/dev/null |
                grep -o '"name":"[^"]*"' | sed 's/.*:"//;s/"//') || return 0
    for name in $names; do
        curl -sf --max-time 10 -X POST "$base/embed?repository=$name" \
             >/dev/null 2>&1 &
    done
    disown -a 2>/dev/null || true
}

cmd_stop() {
    local pid i
    pid=$(live_pid_or_clean)
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null
        # ~20s: SERVE-FOREVER's own *MONITOR-STOP-TIMEOUT* is 10s, plus margin
        # for STOP-SERVER itself.
        for i in $(seq 1 40); do
            if [ ! -f "$pidfile" ]; then
                echo "stopped (pid $pid)"
                return 0
            fi
            sleep 0.5
        done
        echo "stop: pid $pid has not removed $pidfile after ~20s" >&2
        return 1
    fi
    probe
    if [ "$state" = down ]; then
        echo "not running; nothing to stop"
        return 0
    fi
    echo "a Loom service is running but this script did not start it, or lost track of it" >&2
    return 1
}

cmd_restart() {
    cmd_stop || return 1
    cmd_start
}

# A name for cmd_restart, kept as a verb rather than deleted so a script, a
# memory or a habit that types `reload' keeps working instead of hitting a usage
# error. There is nothing left for it to mean of its own: DES-0008 R1 removed
# the reload-code operation this used to POST to.
cmd_reload() {
    cmd_restart
}

cmd_update() {
    probe
    case "$state" in
        down)  cmd_start ;;
        stale) cmd_restart ;;
        *)     echo "running and $state; nothing to do" ;;
    esac
}

case "${1-}" in
    status)  cmd_status ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    reload)  cmd_reload ;;
    update)  cmd_update ;;
    *)
        echo "usage: tools/loom-serve.sh {status|start|stop|restart|reload|update}" >&2
        exit 2
        ;;
esac
