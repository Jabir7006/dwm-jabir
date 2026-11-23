#!/usr/bin/env bash
# Polybar label for WayClick: keyboard glyph, accent colour when running.
ACCENT="#F38D70"
DIM="#72696A"

if pgrep -u "$USER" -f 'contained_apps/uv/wayclick/runner[.]py' >/dev/null 2>&1; then
    printf '%%{F%s}\xf3\xb0\x8c\x8c on%%{F-}' "$ACCENT"
else
    printf '%%{F%s}\xf3\xb0\x8c\x8c off%%{F-}' "$DIM"
fi
