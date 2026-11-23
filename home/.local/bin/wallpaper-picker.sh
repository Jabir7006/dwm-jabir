#!/bin/sh
# wallpaper-picker — on-demand thumbnail grid, zero background footprint.
# Nothing runs when idle: picker + thumbnailer + feh all exit after applying.
# Default: rofi grid (Enter / double-click applies). Fallback: nsxiv (--nsxiv).

WALL_DIR="$HOME/Pictures/backgrounds"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-picker/thumbs"
THEME="$HOME/.config/rofi/wallpaper-grid.rasi"

err() {
    msg="$1"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "Wallpaper picker" "$msg" --urgency=critical 2>/dev/null &
    fi
    echo "wallpaper-picker: $msg" >&2
    exit 1
}

apply() {
    exec "$HOME/.local/bin/wallpaper-apply" "$1"
}

command -v feh >/dev/null 2>&1 || err "feh not installed"
[ -d "$WALL_DIR" ] || err "$WALL_DIR not found"

# ── nsxiv fallback: m = mark, q = apply+quit, Q = apply current ───────────────
if [ "${1:-}" = "--nsxiv" ]; then
    command -v nsxiv >/dev/null 2>&1 || err "nsxiv not installed"
    command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper picker" "m = select · q = apply · Q = apply current" 2>/dev/null &
    pick="$(nsxiv -t -o "$WALL_DIR" 2>/dev/null | head -n 1)"
    [ -z "${pick:-}" ] && exit 0
    apply "$pick"
fi

# ── Default: rofi thumbnail grid ──────────────────────────────────────────────
command -v rofi >/dev/null 2>&1 || err "rofi not installed"
mkdir -p "$CACHE_DIR" 2>/dev/null || err "cannot create $CACHE_DIR"

# NOTE: rofi's per-row "icon" option requires a literal NUL byte
# (text\0icon\x1fpath). NUL bytes cannot pass through shell $() variables,
# so entries are written to a temp file with printf redirection instead.
tmp="$(mktemp)" || err "cannot create temp file"
trap 'rm -f "$tmp"' EXIT INT TERM

count=0
for img in "$WALL_DIR"/*; do
    [ -f "$img" ] || continue
    case "$img" in
        *.jpg|*.jpeg|*.png|*.webp|*.bmp) ;;
        *) continue ;;
    esac
    base="$(basename "$img")"
    thumb="$CACHE_DIR/${base%.*}.jpg"
    if [ ! -f "$thumb" ] || [ "$img" -nt "$thumb" ]; then
        if command -v magick >/dev/null 2>&1; then
            magick "$img" -thumbnail '320x180^' -gravity center -extent 320x180 "$thumb" 2>/dev/null || thumb="$img"
        elif command -v convert >/dev/null 2>&1; then
            convert "$img" -thumbnail '320x180^' -gravity center -extent 320x180 "$thumb" 2>/dev/null || thumb="$img"
        else
            thumb="$img"
        fi
    fi
    printf '%s\0icon\x1f%s\n' "$base" "$thumb" >> "$tmp"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { rm -f "$tmp"; trap - EXIT INT TERM; err "no images in $WALL_DIR"; }

pick="$(rofi -dmenu -i -p "Wallpaper" -show-icons -theme "$THEME" < "$tmp" 2>/dev/null)"
status=$?
rm -f "$tmp"
trap - EXIT INT TERM
# Status 10 = the "⊞ Filmstrip" button in wallpaper-grid.rasi was clicked
# (kb-custom-1). Hand over to the carousel view; it can hand back.
if [ "$status" -eq 10 ]; then
    exec "$HOME/.local/bin/wallpaper-carousel"
fi
[ "$status" -ne 0 ] && exit 0
[ -z "${pick:-}" ] && exit 0
# Rofi returns the visible entry text (basename); resolve to full path.
case "$pick" in
    /*) apply "$pick" ;;
    *) apply "$WALL_DIR/$pick" ;;
esac
