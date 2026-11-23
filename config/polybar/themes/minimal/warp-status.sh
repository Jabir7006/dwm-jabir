#!/usr/bin/env bash
# Polybar WARP indicator — icon only, no text.
# State comes from the file maintained by ~/custom-scripts/warp_toggle.py
# Colors are read from the active theme so they follow theme changes.

STATE_FILE="$HOME/.config/dusky/settings/warp_state"
COLORS_FILE="$HOME/.config/polybar/themes/minimal/colors.ini"

read_color() {
    awk -F= -v key="$1" '
        /^[[:space:]]*[#;]/ { next }
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }
    ' "$COLORS_FILE" 2>/dev/null
}

COLOR_ON="$(read_color green)";   COLOR_ON="${COLOR_ON:-#F38D70}"
COLOR_OFF="$(read_color fg-alt)"; COLOR_OFF="${COLOR_OFF:-#72696A}"

state="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)"

if [[ "$state" == "True" ]]; then
    # 󰕥 = nf-md-shield-check (connected)
    printf '%%{F%s}󰕥%%{F-}\n' "$COLOR_ON"
else
    # 󰦞 = nf-md-shield-off (disconnected)
    printf '%%{F%s}󰦞%%{F-}\n' "$COLOR_OFF"
fi
