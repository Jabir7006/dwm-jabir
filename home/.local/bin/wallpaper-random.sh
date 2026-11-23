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

exec "$HOME/.local/bin/wallpaper-apply" "$file"
