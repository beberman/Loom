#!/bin/bash
# Bring the Loom service up, and keep it honestly current.
#
#   tools/loom-serve.sh status     is it running, is its code current, and
#                                  which trees it is watching
#   tools/loom-serve.sh start      spawn it headless, detached
#   tools/loom-serve.sh stop       SIGTERM it and wait for it to go
#   tools/loom-serve.sh restart    stop, then start
#   tools/loom-serve.sh reload     stop, then start (an alias for restart)
#   tools/loom-serve.sh update     start / restart / nothing, whichever applies
#   tools/loom-serve.sh install    write the systemd user unit (does not enable it)
#
# REQ-0064. Once that unit is enabled, systemd owns the process and this script
# defers to it: start, stop, restart and update each notice an active unit and
# hand the verb to systemctl rather than spawning a second, unsupervised
# service beside the supervised one. There is one control surface either way,
# and which one is in charge is a question the caller does not have to ask.
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

# REQ-0064. The user unit this script can install and, once installed, defers
# to. User rather than system: the service indexes one developer's checkouts
# and runs as them, and a system unit would need a user to run as and a reason
# to outlive them.
unit_name=loom.service
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_file="$unit_dir/$unit_name"

# True when systemd is supervising the service right now. False -- quietly, and
# including when there is no user systemd at all -- when it is not, so every
# caller can ask without first asking whether asking is possible.
unit_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(systemctl --user is-active "$unit_name" 2>/dev/null)" = active ]
}

# Extra repositories to watch alongside this one, one absolute path per line,
# '#' comments and blank lines ignored. Gitignored, because the paths are a
# property of one machine and not of the project.
#
# It exists so dogfooding survives a restart. Loom's recurring defect is a
# mechanism correct on the tree it was developed against and wrong on the next
# one -- REQ-0012, REQ-0015 and REQ-0016 are three in one afternoon, and
# BUG-0030 is a fourth found the moment a third tree was watched. A tree that
# has to be re-watched by hand after every `update` is a tree nobody queries.
# $root/tools rather than $(dirname "$0"): this script has already cd'd to
# $root by the time this line runs, so a relative $0 -- `./loom-serve.sh' from
# inside tools/, which is how a person in that directory types it -- made
# dirname yield `.' and the path resolve to $root/extra-repos, which does not
# exist. `[ -f ]' below then read no extras and said nothing, because a missing
# file is also how a machine with no extra trees is spelled. The symptom was a
# service watching Loom alone that gave no sign of having tried.
extra_repos_file=${LOOM_EXTRA_REPOS:-$root/tools/extra-repos}

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
    # The watched trees, under the line about the process. Two questions get
    # asked of a running service and this verb answered only one of them: `is
    # its code current' says nothing about which trees it holds, and a service
    # watching Loom alone because tools/extra-repos went unread reported
    # "running, code current" while every query over another tree came back
    # empty.
    print_repositories
    return 0
}

# The extra repository roots, into the array named by $1. Read here rather
# than inline in cmd_start because `serve' needs the same list and a second
# copy of this loop would be a watch list that differs by which verb started
# the service. A missing or empty file leaves the array empty, which makes the
# command identical to what it was before this file existed.
read_extra_repos() {
    local -n _out=$1
    _out=()
    [ -f "$extra_repos_file" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && _out+=("$line")
    done < "$extra_repos_file"
}

# REQ-0064 S1. The foreground service, for the systemd unit to supervise.
#
# `exec', so the process systemd tracks is sbcl and not a shell waiting on it:
# a Type=simple unit whose ExecStart forks has lost its service the moment it
# starts, and reports it active while supervising nothing.
#
# Absent from the usage line on purpose. It exists for the unit; a developer
# who wants a foreground service already has `sbcl --script loom-serve.lisp
# --headless', which is what this becomes.
cmd_serve() {
    local extra
    read_extra_repos extra
    echo "watching $root plus ${#extra[@]} from $extra_repos_file"
    exec sbcl --script loom-serve.lisp --headless "$root" \
         ${extra[@]+"${extra[@]}"}
}

cmd_start() {
    if unit_active; then
        echo "supervised by systemd; delegating"
        systemctl --user start "$unit_name"
        return $?
    fi
    # Discarding the pid: the side effect, clearing a pidfile whose process a
    # signal this script never saw already ended, is the point.
    live_pid_or_clean >/dev/null
    probe
    if [ "$state" != down ]; then
        echo "already running ($state)"
        return 0
    fi
    local extra
    read_extra_repos extra
    echo "watching $root plus ${#extra[@]} from $extra_repos_file"
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

# What is actually watched, one indented line per repository: state, name,
# root. Read back from the service rather than from tools/extra-repos, because
# the two disagree exactly when it matters -- a path in the file that could not
# be watched is skipped with a message to the log and never becomes a
# repository, and a tree added over /v1/watch is watched and is in no file.
#
# sed rather than a JSON parser, on the same grounds as JSON_NUMBER above: jq is
# not installed here and these three fields are bare tokens. `tr' puts each
# repository object on its own line first; the substitution on ROOT undoes
# JSON's escaping of `/', which is the only escape a filesystem path produces.
#
# Silence on a body that yields no rows rather than a diagnostic: the caller
# printed the running/not-running line already, and every state in which there
# is nothing to list is one that line has named.
print_repositories() {
    local body
    body=$(curl -sf --max-time 20 "$base/status" 2>/dev/null) || return 0
    printf '%s' "$body" | tr '{' '\n' |
        sed -n 's/.*"name":"\([^"]*\)".*"root":"\([^"]*\)".*"state":"\([^"]*\)".*/\3\t\1\t\2/p' |
        while IFS=$'\t' read -r rstate rname rroot; do
            printf '  %-10s %-22s %s\n' "$rstate" "$rname" "${rroot//\\\//\/}"
        done
}

cmd_stop() {
    if unit_active; then
        echo "supervised by systemd; delegating"
        systemctl --user stop "$unit_name"
        return $?
    fi
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
    # REQ-0064 S3. Delegated as one systemctl call rather than as cmd_stop plus
    # cmd_start, because those two would stop the supervised process and spawn
    # an unsupervised replacement -- leaving systemd reporting the unit
    # inactive while something holds the port, which is the one state that
    # makes `status' lie.
    if unit_active; then
        echo "supervised by systemd; delegating"
        systemctl --user restart "$unit_name"
        return $?
    fi
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

# REQ-0064 S2. Write the unit; do not turn it on.
#
# Enabling is left to the operator because it changes what the machine does
# when nobody is logged in, and a script that decides that silently is a script
# nobody reads twice. The same reasoning covers lingering: without
# `loginctl enable-linger' the user manager stops with the last session and
# takes the service with it, which under WSL is usually the instance going away
# anyway. Both commands are printed; neither is run.
cmd_install() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "install: no systemctl on PATH; this machine has no systemd to install into" >&2
        return 1
    fi
    mkdir -p "$unit_dir" || return 1
    cat > "$unit_file" <<UNIT
[Unit]
Description=Loom engineering knowledge service
Documentation=file://$root/CLAUDE.md
After=default.target

[Service]
Type=simple
WorkingDirectory=$root
ExecStart=$root/tools/loom-serve.sh serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    echo "wrote $unit_file"
    systemctl --user daemon-reload || return 1
    echo "reloaded the user manager"
    echo
    echo "Not enabled and not started -- that is yours to decide:"
    echo "    systemctl --user enable --now $unit_name"
    echo
    echo "To keep it up with no session open (optional):"
    echo "    loginctl enable-linger $USER"
}

cmd_update() {
    if unit_active; then
        # `stale' means the image predates the source. Under supervision the
        # way to a fresh image is a unit restart, which cmd_restart delegates.
        probe
        case "$state" in
            stale) cmd_restart ;;
            *)     echo "supervised by systemd and $state; nothing to do" ;;
        esac
        return $?
    fi
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
    install) cmd_install ;;
    serve)   cmd_serve ;;
    *)
        echo "usage: tools/loom-serve.sh {status|start|stop|restart|reload|update|install}" >&2
        exit 2
        ;;
esac
