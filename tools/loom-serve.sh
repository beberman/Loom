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
    nohup sbcl --script loom-serve.lisp --headless "$root" >>"$logfile" 2>&1 &
    disown
    # ~20s, a generous multiple of the seconds-scale startup PLAN-0005 measured.
    local i
    for i in $(seq 1 40); do
        sleep 0.5
        probe
        if [ "$state" != down ]; then
            echo "started (pid $(live_pid_or_clean))"
            return 0
        fi
    done
    echo "start: nothing answering on $base after ~20s; see $logfile" >&2
    return 1
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
