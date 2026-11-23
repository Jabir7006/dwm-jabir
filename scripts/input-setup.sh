#!/usr/bin/env bash
# Left-handed physical mice; touchpads keep their normal primary button.
set -u
input_marker="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/input-settings-enabled"
[[ -r "$input_marker" && "$(cat "$input_marker")" == yes ]] || exit 0

# A guest receives the host's mapped clicks. Reversing them again swaps the
# touchpad and cancels the physical mouse mapping, so leave virtual input alone.
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet --vm; then
    exit 0
fi
command -v xinput >/dev/null 2>&1 || exit 0

while IFS= read -r device_id; do
    properties="$(xinput list-props "$device_id" 2>/dev/null)" || continue
    grep -q 'libinput Left Handed Enabled (' <<< "$properties" || continue
    if grep -qE 'libinput (Tablet|Calibration)' <<< "$properties"; then
        continue
    elif grep -q 'libinput Tapping Enabled' <<< "$properties"; then
        xinput set-prop "$device_id" 'libinput Left Handed Enabled' 0 || true
    else
        xinput set-prop "$device_id" 'libinput Left Handed Enabled' 1 || true
    fi
done < <(xinput list --short | sed -nE '/slave[[:space:]]+pointer/s/.*id=([0-9]+).*/\1/p')
