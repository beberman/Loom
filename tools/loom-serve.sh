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
#   sudo tools/loom-serve.sh install --system
#                                  write one system unit for a machine with several users
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

# REQ-0072 R1. The checkout this script lives in, resolved through any symlink,
# so a `loom' on PATH that points here reaches the tree it points into rather
# than whatever directory the caller happened to be standing in. `readlink -f'
# because the link is the whole point: $0 is /usr/local/bin/loom, and its
# dirname is /usr/local/bin, which contains no Loom.
#
# Hardcoded until 2026-09-10, on all three of loom.sh, loom-test.sh and
# loom-serve.sh, which made the tree unmovable and the scripts unlinkable.
# next-doc-id.sh had derived its own root correctly since it was written.
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd) || exit 1
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
    [ "$(systemctl is-active "$unit_name" 2>/dev/null)" = active ] ||
        [ "$(systemctl --user is-active "$unit_name" 2>/dev/null)" = active ]
}

# BUG-0074. A machine with several users runs one service, as a system unit
# that `install --system' writes. A user unit cannot do that job: each user's
# copy binds port 4780, and only one can. The system unit is asked first, so a
# machine that has one never reaches the per-user answer below.
system_unit_file=/etc/systemd/system/$unit_name
service_user=loom

# True when the unit systemd owns here is the system one.
unit_is_system() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(systemctl is-enabled "$unit_name" 2>/dev/null)" = enabled ] ||
        [ "$(systemctl is-active "$unit_name" 2>/dev/null)" = active ]
}

# Hand one verb to systemd, to whichever unit owns the service. Changing a
# system unit needs root, and without it systemctl asks polkit for a password
# on a terminal or fails with "Interactive authentication required" on none, so
# say what to run instead.
delegate() {
    if unit_is_system; then
        if [ "$(id -u)" -ne 0 ]; then
            echo "$1: the service is a system unit, and changing it needs root:" >&2
            echo "    sudo $root/tools/loom-serve.sh $1" >&2
            return 1
        fi
        systemctl "$1" "$unit_name"
    else
        systemctl --user "$1" "$unit_name"
    fi
}

# True when systemd OWNS the service, running or not.
#
# This and not unit_active is what the verbs below delegate on, and the
# difference is a defect that shipped: with the unit enabled but stopped, an
# unsupervised process holding the port made `is-active' false, so `start'
# spawned a second one instead of asking systemd to start the first. Worse
# silently -- loom-serve.lisp exits 0 when another service is already
# listening, so the unit that lost the race reported success and
# Restart=on-failure correctly declined to retry. `enabled', `inactive',
# MainPID=0, and a stray process serving every query.
unit_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(systemctl is-enabled "$unit_name" 2>/dev/null)" = enabled ] ||
        [ "$(systemctl --user is-enabled "$unit_name" 2>/dev/null)" = enabled ]
}

# The one question every verb asks: is this service systemd's to run?
unit_owns() {
    unit_enabled || unit_active
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
    #
    # Two questions, and the filesystem answers the one that matters. BUG-0067:
    # :indexed-at only moves once the watcher has reindexed this tree, which is
    # asynchronous and takes seconds, so between an edit and that reindex the
    # index test says `current' about an image that predates the edit. `update'
    # believed it and did nothing, `status' printed "code current", and a
    # harness run in that window measured the old code and looked successful.
    # The mtime test asks the source directly and has no watcher in it.
    if [ "$indexed" -gt "$started" ] || source_newer_than "$started"; then
        state=stale
    else
        state=current
    fi
}

# Universal time (seconds from 1900) to Unix time (seconds from 1970). What
# :started-at and :indexed-at are in, and what `find -newermt @' wants.
UNIVERSAL_TO_UNIX=2208988800

# True when any file the image was built from is newer than the image.
#
# The question `update' has to answer is "does the running process predate my
# edit", and the only reliable witness is the edit itself. Every other signal
# available here is derived from something that runs later: the index from the
# watcher, the pidfile from a restart that has not happened yet.
source_newer_than() {
    local started unix_started
    started=$1
    [ -n "$started" ] || return 1
    unix_started=$((started - UNIVERSAL_TO_UNIX))
    [ -n "$(find "$root/src" "$root/loom.lisp" "$root/loom-serve.lisp" \
                 -name '*.lisp' -newermt "@$unix_started" -print -quit 2>/dev/null)" ]
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
    # /proc and not `kill -0': that fails with "Operation not permitted" for a
    # live process another account owns, which read as dead and sent rm after
    # that account's pidfile. BUG-0074.
    if [ ! -d "/proc/$pid" ]; then rm -f "$pidfile"; return 0; fi
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
    if unit_owns; then
        echo "supervised by systemd; delegating"
        delegate start
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
    if unit_owns; then
        echo "supervised by systemd; delegating"
        delegate stop
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
    if unit_owns; then
        echo "supervised by systemd; delegating"
        delegate restart
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
#
# BUG-0074. `install --system' writes the one unit a machine with several users
# needs: it runs as a dedicated account, starts at boot with nobody logged in,
# and holds port 4780 for all of them. It checks what a second account needs
# before writing anything, because each of these failed on the 2026-10-12
# virtual machine and a unit that starts and then stops serves nobody. It
# creates no account and changes no git or system setting; it prints the line
# that does. The unit gives the service a state directory of its own, because the
# clone is root's and the vector store cannot be written there. BUG-0077. SECURITY.md, "A machine with more than one user", says what the
# account's reach becomes.
install_system() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "install --system: this writes $system_unit_file and needs root:" >&2
        echo "    sudo $root/tools/loom-serve.sh install --system" >&2
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "install: no systemctl on PATH; this machine has no systemd to install into" >&2
        return 1
    fi
    if ! id "$service_user" >/dev/null 2>&1; then
        echo "install --system: no account named $service_user. Create one that owns nothing else:" >&2
        echo "    useradd --system --create-home --home-dir /var/lib/$service_user --shell /usr/sbin/nologin $service_user" >&2
        return 1
    fi
    local problems=0
    # runuser rather than sudo: root is running this, and it needs no password.
    if ! runuser -u "$service_user" -- test -x "$root/tools/loom-serve.sh" 2>/dev/null; then
        echo "install --system: $service_user cannot run $root/tools/loom-serve.sh." >&2
        echo "    A clone under a home directory cannot be read by another account;" >&2
        echo "    Ubuntu makes those 0750. Clone to /opt/loom or move this tree." >&2
        problems=1
    fi
    local home
    home=$(getent passwd "$service_user" | cut -d: -f6)
    if ! [ -f /usr/local/lib/quicklisp/setup.lisp ] && ! [ -f "$home/quicklisp/setup.lisp" ]; then
        echo "install --system: no Quicklisp for $service_user. Install one it can read:" >&2
        echo "    /usr/local/lib/quicklisp, shared, or $home/quicklisp (INSTALL.md, \"Quicklisp\")" >&2
        problems=1
    fi
    if [ "$problems" -ne 0 ]; then
        return 1
    fi
    cat > "$system_unit_file" <<UNIT
[Unit]
Description=Loom engineering knowledge service
Documentation=file://$root/CLAUDE.md
After=network.target

[Service]
Type=simple
User=$service_user
WorkingDirectory=$root
StateDirectory=$service_user
Environment=LOOM_STATE_DIR=/var/lib/$service_user
ExecStart=$root/tools/loom-serve.sh serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    echo "wrote $system_unit_file"
    systemctl daemon-reload || return 1
    echo "reloaded systemd"
    # Not a failure: Loom runs without git, and says so in `status'. But a tree
    # git refuses reports `built from: commit unknown' and ignores nothing.
    if ! runuser -u "$service_user" -- git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
        echo
        echo "NOTE: git refuses $root for $service_user (the tree is owned by someone else)."
        echo "      Without this, status reports \`built from : commit unknown' and .gitignore is not read:"
        echo "          git config --system --add safe.directory $root"
    fi
    echo
    echo "Not enabled and not started -- that is yours to decide:"
    echo "    systemctl enable --now $unit_name"
    echo
    echo "$service_user answers every local user's queries and runs their write operations on any tree"
    echo "it can write. Watch only trees every user of this machine may read and change (SECURITY.md)."
}

cmd_install() {
    if [ "${1-}" = --system ]; then
        install_system
        return $?
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "install: no systemctl on PATH; this machine has no systemd to install into" >&2
        return 1
    fi
    # Checked BEFORE writing anything, because the first version wrote the unit
    # and then failed on daemon-reload -- which under `sudo' meant a file left in
    # /root/.config/systemd/user for a user manager that does not exist, and a
    # nonzero exit from a command whose real work had already succeeded.
    #
    # A user unit belongs to a login session's own manager. Root has none here,
    # so this is the check that catches being run as the wrong user rather than
    # the wrong machine.
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "install: no user systemd manager is reachable for $(id -un)." >&2
        if [ -n "${SUDO_USER-}" ]; then
            echo "         You are running under sudo. The unit belongs to $SUDO_USER, not root:" >&2
            echo "             $root/tools/loom-serve.sh install" >&2
            echo "         -- run that without sudo." >&2
        fi
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
    # An unsupervised service already on the port would make the unit exit 0 on
    # its first start -- "another Loom service is already listening" -- and stay
    # inactive with nothing reporting a failure, because that exit is a success.
    # Say so here, where the reader is about to enable it.
    probe
    if [ "$state" != down ] && ! unit_active; then
        echo
        echo "NOTE: a Loom service is already listening and systemd is not running it."
        echo "      Stop it first, or the unit will exit at once and stay inactive:"
        echo "          tools/loom-serve.sh stop"
    fi
    echo
    # Re-running install on a live unit is the ordinary case after a source
    # change, and telling the operator to enable something already running is
    # the kind of wrong instruction that teaches people to stop reading output.
    if unit_enabled; then
        echo "Already enabled. The new unit file takes effect on the next restart:"
        echo "    systemctl --user restart $unit_name"
    else
        echo "Not enabled and not started -- that is yours to decide:"
        echo "    systemctl --user enable --now $unit_name"
    fi
    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
        echo
        echo "To keep it up with no session open (optional):"
        echo "    loginctl enable-linger $(id -un)"
    fi
}

# Poll until the running image is no longer stale, or give up saying so.
#
# BUG-0067 R3. `cmd_restart' hands the verb to systemd and returns; loading
# eleven systems takes most of a minute, and the OLD process answers every
# query in that window. A caller that measured as soon as `update' returned
# measured the code it had just replaced, and nothing said so -- the run looked
# successful because it was, against the wrong image.
#
# PROBE is the right predicate to wait on because it now asks the filesystem:
# while the old process answers, its :started-at predates the edit and
# SOURCE_NEWER_THAN fires, so `stale' persists until the new image is up.
await_fresh_image() {
    local waited=0 limit=${LOOM_UPDATE_TIMEOUT:-180}
    while [ "$waited" -lt "$limit" ]; do
        probe
        [ "$state" = current ] && return 0
        sleep 3
        waited=$((waited + 3))
    done
    echo "update: the image is still $state after ${limit}s." >&2
    echo "update: whatever you measure now may be the code you replaced." >&2
    return 1
}

cmd_update() {
    if unit_owns; then
        # `stale' means the image predates the source. Under supervision the
        # way to a fresh image is a unit restart, which cmd_restart delegates.
        probe
        case "$state" in
            stale) cmd_restart && await_fresh_image ;;
            *)     echo "supervised by systemd and $state; nothing to do" ;;
        esac
        return $?
    fi
    probe
    case "$state" in
        down)  cmd_start ;;
        stale) cmd_restart && await_fresh_image ;;
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
    install) shift; cmd_install "$@" ;;
    serve)   cmd_serve ;;
    *)
        echo "usage: tools/loom-serve.sh {status|start|stop|restart|reload|update|install [--system]}" >&2
        exit 2
        ;;
esac
