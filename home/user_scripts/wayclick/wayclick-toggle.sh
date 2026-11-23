#!/usr/bin/env bash
# ==============================================================================
# WAYCLICK TOGGLE — manual on/off with notifications, zero leftover processes
# ==============================================================================
#   wayclick on       start (detached, survives terminal close)
#   wayclick off      stop everything: runner, launcher, audio stream
#   wayclick status   ON / OFF
#   wayclick toggle   flip current state  (default)
#   wayclick reload   restart the running instance (applies config edits live)
#
# Nothing is auto-started at boot/login — this script is the only entry point.
# ==============================================================================
set -uo pipefail

LAUNCHER="$HOME/user_scripts/wayclick/dusky_wayclick.sh"
BASE="$HOME/contained_apps/uv/wayclick"
BUILT="$BASE/.build_marker_v10"
RUNNER_RE='contained_apps/uv/wayclick/runner[.]py'
STATE="$HOME/.config/dusky/settings/wayclick"
RUNDIR="${XDG_RUNTIME_DIR:-$HOME/.cache}"
LOG="$RUNDIR/wayclick.log"
PIDFILE="$RUNDIR/wayclick.launcher.pid"
APP="WayClick"

# Set to 1 to suppress notifications for one operation (used by reload).
QUIET=0

notify() { # $1 = body, $2 = icon
    (( QUIET )) && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "$APP" -i "${2:-audio-volume-high}" -t 1500 "$APP" "$1" >/dev/null 2>&1 || true
}

runner_pid() { pgrep -u "$USER" -f "$RUNNER_RE" 2>/dev/null | head -1; }
is_on()      { [[ -n "$(runner_pid)" ]]; }
in_input_grp() { id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx input; }

stop_wc() {
    local rp lp i
    rp="$(runner_pid)"
    if [[ -z "$rp" ]]; then
        rm -f "$PIDFILE"
        echo "WayClick: already OFF"
        notify "Already off" audio-volume-muted
        return 0
    fi
    lp="$(cat "$PIDFILE" 2>/dev/null || true)"

    kill -TERM "$rp" 2>/dev/null || true
    for i in $(seq 1 30); do is_on || break; sleep 0.1; done

    if is_on; then
        kill -KILL "$rp" 2>/dev/null || true
        # KILL skips the launcher's cleanup trap → keep the saved state honest.
        mkdir -p "${STATE%/*}" 2>/dev/null
        printf 'False\n' > "$STATE" 2>/dev/null
        sleep 0.1
    fi

    # The launcher bash exits on its own once python dies; nudge it if it lingers.
    if [[ -n "$lp" ]] && kill -0 "$lp" 2>/dev/null; then
        kill -TERM "$lp" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"

    if is_on; then
        echo "WayClick: stop FAILED"
        notify "Stop failed" dialog-error
        return 1
    fi
    echo "WayClick: OFF"
    notify "Keyboard sounds off" audio-volume-muted
}

start_wc() {
    local i
    if is_on; then
        echo "WayClick: already ON"
        notify "Already on" audio-volume-high
        return 0
    fi
    if [[ ! -f "$BUILT" ]]; then
        echo "WayClick: not built yet. Run: $LAUNCHER --setup"
        notify "Not built — run --setup once" dialog-warning
        return 1
    fi
    if ! in_input_grp; then
        echo "WayClick: user not in 'input' group (sudo usermod -aG input $USER, then logout/login)"
        notify "No input permission — logout/login needed" dialog-warning
        return 1
    fi

    mkdir -p "$RUNDIR"
    : > "$LOG"
    setsid "$LAUNCHER" >>"$LOG" 2>&1 </dev/null &
    echo $! > "$PIDFILE"

    for i in $(seq 1 60); do is_on && break; sleep 0.1; done
    if is_on; then
        echo "WayClick: ON  (log: $LOG)"
    else
        echo "WayClick: start failed — tail -n 30 $LOG"
        notify "Start failed — check $LOG" dialog-error
        return 1
    fi
}

reload_wc() {
    if ! is_on; then
        echo "WayClick: OFF (nothing to reload)"
        return 0
    fi
    QUIET=1
    if ! stop_wc >/dev/null; then
        echo "WayClick: reload FAILED (stop)"
        return 1
    fi
    if ! start_wc >/dev/null; then
        echo "WayClick: reload FAILED (start)"
        return 1
    fi
    QUIET=0
    echo "WayClick: reloaded (pid $(runner_pid))"
    return 0
}

case "${1:-toggle}" in
    on|start) start_wc ;;
    reload|restart) reload_wc ;;
    off|stop) stop_wc ;;
    status)
        if is_on; then echo "WayClick: ON (pid $(runner_pid))"; else echo "WayClick: OFF"; fi ;;
    toggle)
        if is_on; then stop_wc; else start_wc; fi ;;
    *)
        echo "Usage: $(basename "$0") {on|off|status|toggle|reload}"; exit 1 ;;
esac
