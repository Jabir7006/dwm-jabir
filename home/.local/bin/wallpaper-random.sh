#!/bin/sh
# wallpaper-random — pick a random wallpaper, theme-aware.
# When the dynamic theme is active, colors regenerate from the new picture
# (via theme-set-dynamic); otherwise just sets the picture like before.
# Zero footprint when idle.

WALL_DIR="$HOME/Pictures/backgrounds"

[ -d "$WALL_DIR" ] || exit 1
file="$(find "$WALL_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \) \
    2>/dev/null | shuf -n 1)"
[ -n "${file:-}" ] || exit 1

active="$(awk -F'"' '/^\[active\]/{f=1} f&&/theme =/{print $2; exit}' \
    "${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/themes.toml" 2>/dev/null)"
if [ -x "$HOME/.local/bin/theme-set-dynamic" ]; then
    if [ "$active" = "dynamic" ]; then
        out="$("$HOME/.local/bin/theme-set-dynamic" "$file" 2>&1 | tail -n 1)"
        command -v notify-send >/dev/null 2>&1 && notify-send "Dynamic theme" "${out:-applied}" 2>/dev/null &
    else
        # Static theme active: refresh [theme.dynamic] for later use and set the
        # picture, but leave the running theme alone.
        "$HOME/.local/bin/theme-set-dynamic" --stage-only "$file" >/dev/null 2>&1
        command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper" "$(basename "$file")" 2>/dev/null &
    fi
    exit 0
fi

feh --randomize --bg-fill "$WALL_DIR"/*
command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper" "shuffled" 2>/dev/null &
