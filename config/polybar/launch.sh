#!/usr/bin/env bash
# Preserve the saved layout across hardware changes and virtual machines.
set -u
THEME=minimal
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/polybar"
[[ -f "$CONFIG_DIR/themes/$THEME/config.ini" ]] || CONFIG_DIR="$SCRIPT_DIR"

runtime_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dwm-jabir/polybar"
mkdir -p "$runtime_dir"
display_key="${DISPLAY:-default}"
display_key="${display_key//[^a-zA-Z0-9]/_}"
exec 9>"$runtime_dir/launch-$display_key.lock"
flock -n 9 || exit 0

# A theme refresh must not stop bars belonging to another X session.
bar_pids=()
while IFS= read -r pid; do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fx "DISPLAY=${DISPLAY:-}" >/dev/null; then
        kill "$pid" 2>/dev/null || true
        bar_pids+=("$pid")
    fi
done < <(pgrep -u "$UID" -x polybar || true)
for ((attempt=0; attempt<50; attempt++)); do
    running=0
    for pid in "${bar_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then running=1; break; fi
    done
    ((running != 0)) || break
    sleep 0.1
done
if ((running != 0)); then
    printf '%s\n' 'Previous Polybar did not stop within five seconds; leaving it running.' >&2
    exit 1
fi

DWM_BATTERY=""; DWM_ADAPTER=""; DWM_BACKLIGHT=""
for device in /sys/class/power_supply/*; do
    [[ -r "$device/type" ]] || continue
    case "$(cat "$device/type")" in
        Battery) [[ -n "$DWM_BATTERY" ]] || DWM_BATTERY="${device##*/}" ;;
        Mains|USB|USB_C) [[ -n "$DWM_ADAPTER" ]] || DWM_ADAPTER="${device##*/}" ;;
    esac
done
for device in /sys/class/backlight/*; do
    [[ -d "$device" ]] || continue
    DWM_BACKLIGHT="${device##*/}"
    [[ "$DWM_BACKLIGHT" != intel_backlight ]] || break
done
export DWM_BATTERY DWM_ADAPTER DWM_BACKLIGHT

profile="${DWM_POLYBAR_PROFILE:-}"
if [[ -z "$profile" && -r "$CONFIG_DIR/profile" ]]; then
    read -r profile < "$CONFIG_DIR/profile" || true
fi
profile="${profile:-auto}"
CONFIG_FILE="$CONFIG_DIR/themes/$THEME/config.ini"
if [[ "$profile" == laptop || ( "$profile" == auto && -n "$DWM_BATTERY" ) ]]; then
    CONFIG_FILE="$CONFIG_DIR/themes/$THEME/laptop-config.ini"
fi

# Omit unavailable hardware modules without rearranging the remaining modules
# or replacing the saved date/title alignment, colours, dimensions, and fonts.
RUNTIME_CONFIG="$runtime_dir/config-$display_key.ini"
awk -v battery="$DWM_BATTERY" -v backlight="$DWM_BACKLIGHT" '
    /^[[:space:]]*modules-(left|center|right)[[:space:]]*=/ {
        split($0, parts, "=")
        count = split(parts[2], modules, /[[:space:]]+/)
        printf "%s=", parts[1]
        for (i = 1; i <= count; i++) {
            if (modules[i] == "" || (modules[i] == "battery" && battery == "") ||
                (modules[i] == "brightnessctl" && backlight == "")) continue
            printf " %s", modules[i]
        }
        printf "\n"; next
    }
    { print }
' "$CONFIG_FILE" > "$RUNTIME_CONFIG"

MONITORS=()
PRIMARY_MONITOR=""
if command -v xrandr >/dev/null 2>&1; then
    monitor_info="$(xrandr --query 2>/dev/null)" || monitor_info=""
    mapfile -t MONITORS < <(awk '/ connected/ { print $1 }' <<< "$monitor_info")
    PRIMARY_MONITOR="$(awk '/ connected primary/ { print $1; exit }' <<< "$monitor_info")"
fi
if ((${#MONITORS[@]} == 0)); then
    polybar main -c "$RUNTIME_CONFIG" 9>&- &
else
    PRIMARY_MONITOR="${PRIMARY_MONITOR:-${MONITORS[0]}}"
    for monitor in "${MONITORS[@]}"; do
        bar=secondary
        [[ "$monitor" != "$PRIMARY_MONITOR" ]] || bar=main
        MONITOR="$monitor" polybar "$bar" -c "$RUNTIME_CONFIG" 9>&- &
    done
fi

if command -v xdotool >/dev/null 2>&1; then
    for ((attempt=0; attempt<30; attempt++)); do
        xdotool search --class Polybar >/dev/null 2>&1 && break
        sleep 0.1
    done
fi
