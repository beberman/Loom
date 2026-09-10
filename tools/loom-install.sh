#!/bin/bash
# Put `loom' and `loom-serve' on PATH, as links into this checkout.
#
#   tools/loom-install.sh              link into the best writable directory
#   tools/loom-install.sh --uninstall  remove links that point into this tree
#   tools/loom-install.sh --dir DIR    link into DIR instead
#
# REQ-0072. Links, never copies, and the reason is particular to this program
# rather than a preference. Loom is a source tree an SBCL script loads at
# runtime; `tools/loom-serve.sh update' exists because the running image has to
# track the source, and the tree is itself one of the repositories Loom indexes.
# A copy in a system directory would be a second Loom that is never the one
# under test, reporting `code stale' against a source nobody is editing. A
# symlink always runs what you just edited.
#
# It does not use sudo. /usr/local/bin is not writable by an ordinary user, so
# this prints the one command to run rather than running it -- the same rule
# `tools/loom-serve.sh install' follows about enabling the unit, and for the
# same reason: a script that quietly acquires root is a script nobody reads
# twice.

set -u

# REQ-0072 R1, and this script is the reason the other three now do it too.
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd) || exit 1

# The links, as name -> the script in this tree it points at.
links="loom:tools/loom.sh loom-serve:tools/loom-serve.sh"

system_dir=/usr/local/bin
user_dir="$HOME/.local/bin"

on_path() {
    case ":${PATH-}:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

# Where to link. A directory the caller named wins; otherwise the system one,
# and only if it is writable.
#
# There is deliberately no silent fallback. Falling back to ~/.local/bin when
# /usr/local/bin needs root looks helpful and is not: on this machine
# ~/.local/bin does not exist and is not on PATH, so the quiet fallback links
# two files nothing can reach and reports success -- the install that appears
# to work and changes nothing, which is what R4 is about. Both directories are
# offered by name instead and the caller picks, which is also R3: the sudo
# command is printed, never run.
choose_dir() {
    if [ -n "${want_dir-}" ]; then printf '%s\n' "$want_dir"; return 0; fi
    if [ -w "$system_dir" ]; then printf '%s\n' "$system_dir"; return 0; fi
    return 1
}

# True when PATH is a link this checkout owns. Used by --uninstall so it can
# never remove somebody else's `loom', and by install so a re-run replaces its
# own link rather than refusing.
ours() {
    local link=$1 target=$2
    [ -L "$link" ] || return 1
    [ "$(readlink -f "$link")" = "$(readlink -f "$root/$target")" ]
}

cmd_install() {
    local dir pair name target link made=0 skipped=0
    if ! dir=$(choose_dir); then
        echo "$system_dir is not writable, so this needs a choice rather than a guess."
        echo
        echo "For everyone on this machine -- $system_dir is already on PATH:"
        echo "    sudo $root/tools/loom-install.sh --dir $system_dir"
        echo
        echo "For you alone -- check $user_dir is on your PATH afterwards:"
        echo "    $root/tools/loom-install.sh --dir $user_dir"
        return 1
    fi

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || {
            echo "install: cannot create $dir" >&2
            return 1
        }
    fi
    if [ ! -w "$dir" ]; then
        echo "install: $dir is not writable."
        echo
        echo "Either run this one command:"
        echo "    sudo $root/tools/loom-install.sh --dir $dir"
        echo
        echo "or install for yourself alone:"
        echo "    $root/tools/loom-install.sh --dir $user_dir"
        return 1
    fi

    for pair in $links; do
        name=${pair%%:*}
        target=${pair##*:}
        link="$dir/$name"
        if [ -e "$link" ] && ! [ -L "$link" ]; then
            echo "  skipped $link -- exists and is not a symlink" >&2
            skipped=$((skipped + 1))
            continue
        fi
        if [ -L "$link" ] && ! ours "$link" "$target"; then
            echo "  skipped $link -- a symlink to something outside this checkout" >&2
            skipped=$((skipped + 1))
            continue
        fi
        ln -sfn "$root/$target" "$link" || return 1
        echo "  $link -> $root/$target"
        made=$((made + 1))
    done

    echo "linked $made, skipped $skipped, into $dir"
    if ! on_path "$dir"; then
        echo
        echo "NOTE: $dir is not on your PATH, so nothing above is reachable by name yet."
        echo "      Add it, or re-run with --dir pointing somewhere that is:"
        echo "          export PATH=\"$dir:\$PATH\""
    fi

    # R6. One command prepares both halves -- but only when this process is the
    # one the unit would belong to.
    #
    # Linking into /usr/local/bin needs root and the unit does not: a systemd
    # *user* unit belongs to a login session, and under `sudo' $HOME is /root,
    # which has no user manager here. The first version called through anyway
    # and wrote /root/.config/systemd/user/loom.service, then failed on
    # daemon-reload with "Failed to connect to bus: No medium found" -- so a run
    # that had already linked both commands correctly reported failure and left
    # a file behind for a manager that will never read it.
    echo
    echo "--- the service unit ---"
    if [ "$(id -u)" -eq 0 ]; then
        echo "skipped: a user unit belongs to a login session, not to root."
        if [ -n "${SUDO_USER-}" ]; then
            echo "Run this as $SUDO_USER, without sudo:"
        else
            echo "Run this as the user the service should belong to:"
        fi
        echo "    $root/tools/loom-serve.sh install"
        return 0
    fi
    "$root/tools/loom-serve.sh" install
}

cmd_uninstall() {
    local dir pair name target link removed=0
    for dir in "${want_dir-$system_dir}" "$user_dir"; do
        [ -d "$dir" ] || continue
        for pair in $links; do
            name=${pair%%:*}
            target=${pair##*:}
            link="$dir/$name"
            if ours "$link" "$target"; then
                rm -f "$link" && echo "  removed $link" && removed=$((removed + 1))
            fi
        done
    done
    echo "removed $removed"
    echo
    echo "The systemd unit is untouched; REQ-0064 owns it:"
    echo "    systemctl --user disable --now loom.service"
}

want_dir=""
action=install
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) action=uninstall ;;
        --dir)       shift; want_dir=${1-} ;;
        *)
            echo "usage: tools/loom-install.sh [--uninstall] [--dir DIR]" >&2
            exit 2
            ;;
    esac
    shift
done
[ -n "$want_dir" ] || unset want_dir

case "$action" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
esac
