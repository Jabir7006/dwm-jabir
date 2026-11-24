#!/usr/bin/env bash
# On-screen keyboard toggle (Onboard).
#
# No daemon, no polling: if onboard runs it is killed, otherwise it is
# launched. Closed = zero processes, zero CPU, zero RAM.
#
# The colour scheme is regenerated from the polybar palette on every launch,
# so the keyboard always matches the active dwm theme.

set -u

OB_THEME="dwm-theme"
OB_THEME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/onboard/themes"
OB_LAYOUT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/onboard/layouts"
COLORS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/polybar/themes/minimal/colors.ini"

# ── toggle ───────────────────────────────────────────────────────────────────
# Anchored so the pattern only matches onboard's own command line, never a
# shell that merely mentions the path.
ONBOARD_RE='^/usr/bin/python[0-9.]* /usr/bin/onboard'

if pgrep -u "$USER" -f "$ONBOARD_RE" >/dev/null 2>&1; then
    pkill -u "$USER" -f "$ONBOARD_RE"
    exit 0
fi

# SUPER+Q closes the overlay first because Onboard deliberately keeps input
# focus on the typing app. With no overlay, preserve normal window closing:
# request WM_DELETE_WINDOW when supported, otherwise terminate its X client.
if [[ ${1:-} == --close-window ]]; then
    ACTIVE_WINDOW="$(xdotool getactivewindow 2>/dev/null)" || exit 0
    # xdotool windowquit sends _NET_CLOSE_WINDOW, which this dwm ignores.
    # Send WM_DELETE_WINDOW directly, matching dwm's killclient behavior.
    python - "$ACTIVE_WINDOW" <<'PY'
import ctypes as C
import sys

class ClientMessage(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", C.c_ulong),
                ("send_event", C.c_int), ("display", C.c_void_p),
                ("window", C.c_ulong), ("message_type", C.c_ulong),
                ("format", C.c_int), ("data", C.c_long * 5)]

class XEvent(C.Union):
    _fields_ = [("client", ClientMessage), ("padding", C.c_long * 24)]

x11 = C.CDLL("libX11.so.6")
x11.XOpenDisplay.argtypes = [C.c_char_p]
x11.XOpenDisplay.restype = C.c_void_p
x11.XInternAtom.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
x11.XInternAtom.restype = C.c_ulong
x11.XGetWMProtocols.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.POINTER(C.c_ulong)), C.POINTER(C.c_int)]
x11.XSendEvent.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_long, C.POINTER(XEvent)]
x11.XKillClient.argtypes = [C.c_void_p, C.c_ulong]
x11.XFree.argtypes = [C.c_void_p]
x11.XCloseDisplay.argtypes = [C.c_void_p]
display = x11.XOpenDisplay(None)
if display:
    window = int(sys.argv[1])
    delete = x11.XInternAtom(display, b"WM_DELETE_WINDOW", False)
    protocols = C.POINTER(C.c_ulong)()
    count = C.c_int()
    supports_delete = False
    if x11.XGetWMProtocols(display, window, C.byref(protocols), C.byref(count)):
        supports_delete = delete in [protocols[i] for i in range(count.value)]
        x11.XFree(protocols)
    if supports_delete:
        event = XEvent()
        event.client.type = 33  # ClientMessage
        event.client.window = window
        event.client.message_type = x11.XInternAtom(display, b"WM_PROTOCOLS", False)
        event.client.format = 32
        event.client.data[0] = delete
        event.client.data[1] = 0  # CurrentTime
        x11.XSendEvent(display, window, False, 0, C.byref(event))
    else:
        x11.XKillClient(display, window)
    x11.XCloseDisplay(display)
PY
    exit 0
fi

# ── build the colour scheme from the live polybar palette ────────────────────
read_color() {
    awk -F= -v key="$1" '
        /^[[:space:]]*[#;]/ { next }
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" { gsub(/[[:space:]]/, "", $2); print $2; exit }
    ' "$COLORS_FILE" 2>/dev/null
}

BG="$(read_color bg)";      BG="${BG:-#2C2525}"
FG="$(read_color fg)";      FG="${FG:-#E6D9DB}"
ALT="$(read_color bg-alt)"; ALT="${ALT:-#403E41}"
MUTED="$(read_color fg-alt)"; MUTED="${MUTED:-#72696A}"
ACCENT="$(read_color blue)"; ACCENT="${ACCENT:-#F38D70}"
URGENT="$(read_color red)";  URGENT="${URGENT:-#FD6883}"

mkdir -p "$OB_THEME_DIR"

cat > "$OB_THEME_DIR/$OB_THEME.colors" <<EOF
<?xml version="1.0"?>
<color_scheme name="$OB_THEME" format="2.1">
    <window type="key-popup">
        <color element="border" rgb="$ACCENT" opacity="1.0"/>
    </window>

    <layer> <color element="background" rgb="$BG" opacity="1.0"/> </layer>
    <layer> <color element="background" rgb="$BG" opacity="1.0"/> </layer>
    <layer> <color element="background" rgb="$BG" opacity="1.0"/> </layer>

    <key_group>
        <color element="fill"   rgb="$ALT"/>
        <color element="stroke" rgb="$BG"/>
        <color element="label"  rgb="$FG"/>

        <key_group>
            <color element="label" rgb="$FG"/>
            icon1, icon2
        </key_group>

        <key_group>
            <color element="fill"  rgb="$BG"/>
            <color element="label" rgb="$MUTED"/>
            icon0, icon3,
            RCTL, LCTL, RALT, LALT, LWIN, CAPS, LFSH, RTSH, NMLK,
            MENU, RWIN, BKSP, TAB, RTRN, ESC,
            KPDL, KPEN, KP0, KP1, KP2, KP3, KP4, KP5, KP6, KP7, KP8, KP9,
            LEFT, RGHT, UP, DOWN, INS, DELE, HOME, END, PGUP, PGDN,
            F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
            Prnt, Pause, Scroll,
            KPSU, KPDV, KPAD, KPMU,
            secondaryclick, middleclick, doubleclick, dragclick, hoverclick,
            hide, showclick, move, layer
        </key_group>

        <key_group>
            <color element="fill"  rgb="$URGENT"/>
            <color element="label" rgb="$BG"/>
            quit
        </key_group>

        <key_group>
            <color element="fill"  rgb="$ACCENT"/>
            <color element="label" rgb="$BG"/>
            settings
        </key_group>

        <key_group>
            <color element="fill"  rgb="$BG"/>
            <color element="label" rgb="$MUTED"/>
            wordlist, prediction
        </key_group>
    </key_group>
</color_scheme>
EOF

cat > "$OB_THEME_DIR/$OB_THEME.theme" <<EOF
<?xml version="1.0" ?>
<theme format="1.3" name="$OB_THEME">
  <color_scheme>$OB_THEME</color_scheme>
  <background_gradient>0.0</background_gradient>
  <key_style>flat</key_style>
  <roundrect_radius>22.0</roundrect_radius>
  <key_size>96.0</key_size>
  <key_fill_gradient>0.0</key_fill_gradient>
  <key_stroke_gradient>0.0</key_stroke_gradient>
  <key_gradient_direction>0.0</key_gradient_direction>
  <key_label_font></key_label_font>
  <key_label_overrides/>
  <key_shadow_strength>0.0</key_shadow_strength>
  <key_shadow_size>0.0</key_shadow_size>
</theme>
EOF

# Add a full-width drag strip above Compact's keys. It uses Onboard's native
# move action, so any point on the strip moves the overlay without typing.
mkdir -p "$OB_LAYOUT_DIR"
python - "$OB_LAYOUT_DIR" <<'PY'
from pathlib import Path
import re
import sys
from xml.sax.saxutils import quoteattr

layouts = Path(sys.argv[1])
system_layouts = Path("/usr/share/onboard/layouts")
source = (system_layouts / "Compact.onboard").read_text()
# Keep the packaged layout and its license; resolve its assets from there.
source = re.sub(r"\b(filename|file)=([\"'])([^\"']+)\2",
                lambda m: f"{m[1]}={quoteattr(str(system_layouts / m[3]))}", source)
source = source.replace('id="Compact"', 'id="Dwm-Compact"', 1)
# The right-side X must exit Onboard, rather than hide it in the background.
source = source.replace("<key group='bottomrow' id='hide'/>",
                        "<key group='bottomrow' id='quit.close' svg_id='hide' "
                        "image='close.svg' label='' tooltip='Close keyboard'/>")
strip_file = layouts / "Dwm-Drag.svg"
strip_file.write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="330" height="12">
  <rect id="drag-strip" x="0" y="0" width="330" height="12"/>
</svg>
''')
box = '<box border="0.5" spacing="1.5" orientation="vertical">'
strip = f'''
        <!-- Full-width empty space for dragging, available on every layer. -->
        <panel filename={quoteattr(str(strip_file))} expand="false">
            <key id="move" svg_id="drag-strip" group="dragbar"
                 image="" label="⋯" show_face="false" show_border="false"
                 tooltip="Drag to move keyboard"/>
        </panel>
'''
source = source.replace(box, box + strip, 1)
(layouts / "Dwm-Compact.onboard").write_text(source)
PY

# ── launch ───────────────────────────────────────────────────────────────────
# dwm does not implement Onboard's ABOVE/STICKY EWMH requests. Force-to-top
# uses Onboard's own floating overlay, which stays visible across tag and
# window changes and keeps keyboard focus on the app receiving input.
gsettings set org.onboard.window docking-enabled false
gsettings set org.onboard.window window-state-sticky true
gsettings set org.onboard.window force-to-top true

# Compact and centered on the primary monitor (or the first active monitor).
# Account for monitor offsets; xrandr may have no monitor marked primary.
SCREEN_GEOMETRY="$(xrandr --listmonitors 2>/dev/null | awk '
    $1 ~ /^[0-9]+:$/ {
        geometry = $3
        gsub(/\/[0-9]+/, "", geometry)
        if (!fallback) fallback = geometry
        if ($2 ~ /\*/) { print geometry; found = 1; exit }
    }
    END { if (!found && fallback) print fallback }
')"
SCREEN_W=1366; SCREEN_H=768; SCREEN_X=0; SCREEN_Y=0
if [[ $SCREEN_GEOMETRY =~ ^([0-9]+)x([0-9]+)([+-][0-9]+)([+-][0-9]+)$ ]]; then
    SCREEN_W="${BASH_REMATCH[1]}"; SCREEN_H="${BASH_REMATCH[2]}"
    SCREEN_X="${BASH_REMATCH[3]}"; SCREEN_Y="${BASH_REMATCH[4]}"
fi
KB_W=820; KB_H=268
(( KB_W > SCREEN_W * 9 / 10 )) && KB_W=$((SCREEN_W * 9 / 10))
(( KB_H > SCREEN_H * 2 / 5 )) && KB_H=$((SCREEN_H * 2 / 5))
KB_X=$((SCREEN_X + (SCREEN_W - KB_W) / 2))
KB_Y=$((SCREEN_Y + (SCREEN_H - KB_H) / 2))

setsid onboard \
    --theme "$OB_THEME" \
    --layout "$OB_LAYOUT_DIR/Dwm-Compact.onboard" \
    --size "${KB_W}x${KB_H}" \
    -x "$KB_X" \
    -y "$KB_Y" \
    >/dev/null 2>&1 < /dev/null &
ONBOARD_PID=$!

# The overlay is outside dwm's managed clients, so give it the same native
# X11 border using dwm's live theme and border width. Wait only at startup;
# this helper exits immediately after applying the border, with no daemon.
if OSK_WINDOW="$(timeout 5s xdotool search --sync --onlyvisible --all \
    --pid "$ONBOARD_PID" --limit 1 --class '^Onboard$' 2>/dev/null)"; then
    python - "$OSK_WINDOW" "$ACCENT" <<'PY'
import ctypes as C
import os
from pathlib import Path
import sys
import tomllib

border_width, border_color = 1, sys.argv[2]
theme_file = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dwm-titus/themes.toml"
try:
    with theme_file.open("rb") as stream:
        settings = tomllib.load(stream)
    border_width = max(0, int(settings.get("appearance", {}).get("borderpx", 1)))
    active = settings.get("active", {}).get("theme")
    palette = settings.get("theme", {}).get(active, {}) if active else settings.get("colors", {})
    border_color = palette.get("selbordercolor", border_color)
except (OSError, ValueError, TypeError):
    pass

class XColor(C.Structure):
    _fields_ = [("pixel", C.c_ulong), ("red", C.c_ushort),
                ("green", C.c_ushort), ("blue", C.c_ushort),
                ("flags", C.c_char), ("pad", C.c_char)]

x11 = C.CDLL("libX11.so.6")
x11.XOpenDisplay.argtypes = [C.c_char_p]
x11.XOpenDisplay.restype = C.c_void_p
x11.XDefaultScreen.argtypes = [C.c_void_p]
x11.XDefaultColormap.argtypes = [C.c_void_p, C.c_int]
x11.XDefaultColormap.restype = C.c_ulong
x11.XAllocNamedColor.argtypes = [C.c_void_p, C.c_ulong, C.c_char_p, C.POINTER(XColor), C.POINTER(XColor)]
x11.XSetWindowBorder.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong]
x11.XSetWindowBorderWidth.argtypes = [C.c_void_p, C.c_ulong, C.c_uint]
x11.XCloseDisplay.argtypes = [C.c_void_p]
display = x11.XOpenDisplay(None)
if display:
    colormap = x11.XDefaultColormap(display, x11.XDefaultScreen(display))
    screen_color, exact_color = XColor(), XColor()
    if x11.XAllocNamedColor(display, colormap, border_color.encode(), C.byref(screen_color), C.byref(exact_color)):
        window = int(sys.argv[1])
        x11.XSetWindowBorder(display, window, screen_color.pixel)
        x11.XSetWindowBorderWidth(display, window, border_width)
    x11.XCloseDisplay(display)
PY
fi
