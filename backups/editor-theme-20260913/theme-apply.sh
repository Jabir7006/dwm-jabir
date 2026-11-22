#!/bin/bash
# theme-apply.sh — Apply the active theme from themes.toml to all apps.
#
# Called automatically by DWM on config reload (SIGUSR1 / file save).
# Can also be run manually: theme-apply.sh
#
# Updates: alacritty · kitty · ghostty · rofi · polybar

set -euo pipefail

# ── Locate themes.toml ────────────────────────────────────────────────────────
THEMES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/themes.toml"
if [[ ! -f "$THEMES_FILE" ]]; then
    echo "theme-apply: themes.toml not found at $THEMES_FILE" >&2
    exit 1
fi

# Serialize concurrent runs (DWM fires on file-save AND wrapper calls apply
# AND manual runs can overlap): a second run would only redo the same work,
# so it exits instantly instead of queueing behind a slow polybar relaunch.
# Queued-up slow runs were the "infinite theme reloading" pile-up.
LOCK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/.theme-apply.lock"
exec 9>"$LOCK_FILE" 2>/dev/null || true
flock -n 9 2>/dev/null || exit 0
# If themes.toml changes while this run is mid-flight (skipped runs exit
# above), re-apply once so no save is ever lost. Bounded to avoid loops.
MTIME_START="$(stat -c %Y "$THEMES_FILE" 2>/dev/null || echo 0)"
REAPPLY_COUNT="${REAPPLY_COUNT:-0}"

# ── Minimal TOML section reader ───────────────────────────────────────────────
# toml_get SECTION KEY FILE — prints the value or empty string
toml_get() {
    local section="$1" key="$2" file="$3"
    awk -v sec="[$section]" -v key="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/"/, "")
            gsub(/[[:space:]]+#.*$/, "")  # strip inline comments (not # in hex colors)
            sub(/[[:space:]]+$/, "")
            print; exit
        }
    ' "$file"
}

# ── Read active theme name ────────────────────────────────────────────────────
THEME_NAME="$(toml_get "active" "theme" "$THEMES_FILE")"
if [[ -z "$THEME_NAME" ]]; then
    echo "theme-apply: no [active] theme set in $THEMES_FILE" >&2
    exit 1
fi

SECTION="theme.$THEME_NAME"

# ── Helper: read a value from the active theme section ───────────────────────
theme_get() {
    toml_get "$SECTION" "$1" "$THEMES_FILE"
}

# ── Read all theme values ─────────────────────────────────────────────────────
TERM_BG="$(theme_get term_bg)"
TERM_FG="$(theme_get term_fg)"
TERM_CURSOR="$(theme_get term_cursor)"
TERM_C0="$(theme_get term_color0)"
TERM_C1="$(theme_get term_color1)"
TERM_C2="$(theme_get term_color2)"
TERM_C3="$(theme_get term_color3)"
TERM_C4="$(theme_get term_color4)"
TERM_C5="$(theme_get term_color5)"
TERM_C6="$(theme_get term_color6)"
TERM_C7="$(theme_get term_color7)"
TERM_C8="$(theme_get term_color8)"
TERM_C9="$(theme_get term_color9)"
TERM_C10="$(theme_get term_color10)"
TERM_C11="$(theme_get term_color11)"
TERM_C12="$(theme_get term_color12)"
TERM_C13="$(theme_get term_color13)"
TERM_C14="$(theme_get term_color14)"
TERM_C15="$(theme_get term_color15)"

GHOSTTY_THEME="$(theme_get ghostty_theme)"
ROFI_THEME="$(theme_get rofi_theme)"
ROFI_BG_SELECTED="${SEL_BGCOLOR:-$(theme_get selbgcolor)}"
ROFI_BORDER_COLOR="${SEL_BORDERCOLOR:-$(theme_get selbordercolor)}"
# App borders follow the rofi/accent color so entries, menus, dialogs and
# the launcher share one border identity. Optional per-theme gtk_border
# key overrides it (macos-dark pins its classic grey).
GTK_BORDER_OVERRIDE="$(theme_get gtk_border)"
GTK_BORDER_COLOR="${GTK_BORDER_OVERRIDE:-$ROFI_BORDER_COLOR}"
GTK_BORDER_COLOR="${GTK_BORDER_COLOR:-#45475a}"
NORM_FG="$(theme_get normfgcolor)"
SEL_BORDER="$(theme_get selbordercolor)"
# Optional per-theme secondary-text color. Falls back to bright-black when a
# theme does not define it (only themes whose color8 is unreadable set this).
GTK_MUTED_CSS="$(theme_get gtk_muted)"
GTK_MUTED_CSS="${GTK_MUTED_CSS:-${TERM_C8:-#7f849c}}"

PB_BG="$(theme_get polybar_bg)"
PB_FG="$(theme_get polybar_fg)"
PB_BG_ALT="$(theme_get polybar_bg_alt)"
PB_FG_ALT="$(theme_get polybar_fg_alt)"
PB_ACCENT="$(theme_get polybar_accent)"
PB_URGENT="$(theme_get polybar_urgent)"

DARK_MODE="$(theme_get dark_mode)"
[[ "$DARK_MODE" != "false" ]] && DARK_MODE="true"  # default to dark if unset

# ── Color math helpers (defined once, used by polybar/GTK/dunst blocks) ───────
# darken HEX by FACTOR (keeps 0-1 of each channel); prints original on failure
darken() {
    python3 -c "
import sys
h = '$1'.lstrip('#')
try:
    f = float('$2')
    c = [int(h[i:i+2], 16) for i in (0, 2, 4)]
    print('#' + ''.join(f'{round(v * f):02X}' for v in c))
except Exception:
    print('$1')
" 2>/dev/null || printf '%s' "$1"
}
# mix HEX1 toward HEX2 by T (0-1); soft in-between tones. Failsafe: HEX1.
mix() {
    python3 -c "
h1 = '$1'.lstrip('#')
h2 = '$2'.lstrip('#')
try:
    t = float('$3')
    a = [int(h1[i:i+2], 16) for i in (0, 2, 4)]
    b = [int(h2[i:i+2], 16) for i in (0, 2, 4)]
    print('#' + ''.join(f'{round(x * t + y * (1 - t)):02X}' for x, y in zip(a, b)))
except Exception:
    print('$1')
" 2>/dev/null || printf '%s' "$1"
}


# ══════════════════════════════════════════════════════════════════════════════
# ALACRITTY — write ~/.config/alacritty/active-theme.toml
# ══════════════════════════════════════════════════════════════════════════════
ALACRITTY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/alacritty"
if [[ -d "$ALACRITTY_DIR" ]]; then
    cat > "$ALACRITTY_DIR/active-theme.toml" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
# Change the theme in ~/.config/dwm-titus/themes.toml instead.

[colors.primary]
background = '$TERM_BG'
foreground = '$TERM_FG'

[colors.cursor]
text   = '$TERM_BG'
cursor = '$TERM_CURSOR'

[colors.normal]
black   = '$TERM_C0'
red     = '$TERM_C1'
green   = '$TERM_C2'
yellow  = '$TERM_C3'
blue    = '$TERM_C4'
magenta = '$TERM_C5'
cyan    = '$TERM_C6'
white   = '$TERM_C7'

[colors.bright]
black   = '$TERM_C8'
red     = '$TERM_C9'
green   = '$TERM_C10'
yellow  = '$TERM_C11'
blue    = '$TERM_C12'
magenta = '$TERM_C13'
cyan    = '$TERM_C14'
white   = '$TERM_C15'
EOF

    # Ensure alacritty.toml imports active-theme.toml (add if missing)
    if [[ -f "$ALACRITTY_DIR/alacritty.toml" ]]; then
        if ! grep -q "active-theme.toml" "$ALACRITTY_DIR/alacritty.toml"; then
            # Insert active-theme.toml as first import entry
            sed -i 's|^\(import = \[\s*\)|\1\n  "~/.config/alacritty/active-theme.toml",|' \
                "$ALACRITTY_DIR/alacritty.toml"
        fi
        # Replace any existing theme import line to point to active-theme.toml
        # (removes old theme-specific imports, keeps keybinds import)
        sed -i 's|"~/.config/alacritty/[^k][^"]*\.toml"|"~/.config/alacritty/active-theme.toml"|g' \
            "$ALACRITTY_DIR/alacritty.toml"
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# KITTY — write ~/.config/kitty/active-theme.conf
# ══════════════════════════════════════════════════════════════════════════════
KITTY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kitty"
if [[ -d "$KITTY_DIR" ]]; then
    cat > "$KITTY_DIR/active-theme.conf" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
# Change the theme in ~/.config/dwm-titus/themes.toml instead.

background  $TERM_BG
foreground  $TERM_FG
cursor      $TERM_CURSOR

color0  $TERM_C0
color1  $TERM_C1
color2  $TERM_C2
color3  $TERM_C3
color4  $TERM_C4
color5  $TERM_C5
color6  $TERM_C6
color7  $TERM_C7
color8  $TERM_C8
color9  $TERM_C9
color10 $TERM_C10
color11 $TERM_C11
color12 $TERM_C12
color13 $TERM_C13
color14 $TERM_C14
color15 $TERM_C15
EOF

    # Ensure kitty.conf has 'include active-theme.conf' at the top
    if [[ -f "$KITTY_DIR/kitty.conf" ]]; then
        if ! grep -q "include active-theme.conf" "$KITTY_DIR/kitty.conf"; then
            sed -i '1s|^|include active-theme.conf\n|' "$KITTY_DIR/kitty.conf"
        fi
    fi

    # Signal kitty to reload (no restart needed)
    if command -v kitty &>/dev/null; then
        kill -SIGUSR1 "$(pgrep -x kitty)" 2>/dev/null || true
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# GHOSTTY — update ~/.config/ghostty/config
# ══════════════════════════════════════════════════════════════════════════════
GHOSTTY_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config"
# Ensure custom themes shipped with dwm-titus are present
GHOSTTY_THEMES_SRC="$HOME/.local/share/dwm-titus/ghostty/themes"
GHOSTTY_THEMES_DST="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/themes"
if [[ -d "$GHOSTTY_THEMES_SRC" ]]; then
    mkdir -p "$GHOSTTY_THEMES_DST"
    cp -r "$GHOSTTY_THEMES_SRC/"* "$GHOSTTY_THEMES_DST/" 2>/dev/null || true
fi
if [[ -n "$GHOSTTY_THEME" && -f "$GHOSTTY_CFG" ]]; then
    if grep -q "^theme[[:space:]]*=" "$GHOSTTY_CFG"; then
        sed -i "s|^theme[[:space:]]*=.*|theme = $GHOSTTY_THEME|" "$GHOSTTY_CFG"
    else
        echo "theme = $GHOSTTY_THEME" >> "$GHOSTTY_CFG"
    fi
    # Remove any manually set background/foreground so the named theme controls colors
    sed -i '/^background[[:space:]]*=[^=]/d' "$GHOSTTY_CFG"
    sed -i '/^foreground[[:space:]]*=[^=]/d' "$GHOSTTY_CFG"
fi


# ══════════════════════════════════════════════════════════════════════════════
# ROFI — write ~/.config/rofi/active-colors.rasi (imported by config.rasi)
# ══════════════════════════════════════════════════════════════════════════════
ROFI_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rofi"
ROFI_COLORS="$ROFI_CFG_DIR/active-colors.rasi"
if [[ -n "$TERM_BG" ]]; then
    mkdir -p "$ROFI_CFG_DIR"
    # Remove any legacy "@theme" line from older theme-apply.sh versions —
    # it pointed to a nonexistent themes/*.rasi and broke rofi.
    if [[ -f "$ROFI_CFG_DIR/config.rasi" ]]; then
        sed -i '/^[[:space:]]*@theme[[:space:]]*"/d' "$ROFI_CFG_DIR/config.rasi"
    fi
    cat > "$ROFI_COLORS" <<EOF
* {
    bg:            ${TERM_BG:-#1e1e2e};
    fg:            ${TERM_FG:-#ffffff};
    bg-selected:   ${ROFI_BG_SELECTED:-#313244};
    fg-alt:        ${TERM_C8:-#9e9e9e};
    border-color:  ${ROFI_BORDER_COLOR:-#89b4fa};
}
EOF
fi


# ══════════════════════════════════════════════════════════════════════════════
# POLYBAR TAGS — update dwm-tags.ini env colors so workspace indicators stay
# readable on both dark and light bars. Only the three color lines are touched;
# fonts, padding and everything else in the file are preserved.
# (Must run BEFORE the polybar relaunch below so the new bar picks them up.)
#   dark:  active = bright terminal fg, occupied = dimmer DWM fg
#   light: active = accent (blue),       occupied = dark DWM fg
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DARK_MODE" == "true" ]]; then
    TAG_ACTIVE="${TERM_FG:-#ffffff}"
    TAG_OCCUPIED="${NORM_FG:-#aaaaaa}"
else
    TAG_ACTIVE="${SEL_BORDER:-#007AFF}"
    TAG_OCCUPIED="${NORM_FG:-#515154}"
fi
TAG_URGENT="${PB_URGENT:-#FF3B30}"
TAGS_INI="${XDG_CONFIG_HOME:-$HOME/.config}/polybar/themes/minimal/modules/dwm-tags.ini"
if [[ -f "$TAGS_INI" ]]; then
    sed -i "s|^env-DWM_TAG_ACTIVE_COLOR .*|env-DWM_TAG_ACTIVE_COLOR = $TAG_ACTIVE|" "$TAGS_INI"
    sed -i "s|^env-DWM_TAG_OCCUPIED_COLOR .*|env-DWM_TAG_OCCUPIED_COLOR = $TAG_OCCUPIED|" "$TAGS_INI"
    sed -i "s|^env-DWM_TAG_URGENT_COLOR .*|env-DWM_TAG_URGENT_COLOR = $TAG_URGENT|" "$TAGS_INI"
fi


# ══════════════════════════════════════════════════════════════════════════════
# POLYBAR — fully replace ~/.config/polybar/themes/minimal/colors.ini
# ══════════════════════════════════════════════════════════════════════════════
PB_COLORS="${XDG_CONFIG_HOME:-$HOME/.config}/polybar/themes/minimal/colors.ini"
# soft: halfway between bar bg and bg-alt — a minimal, non-sharp edge tone
# for the bottom border (bg-alt at full strength looked too harsh).
PB_SOFT="$(mix "${PB_BG:-#1e1e2e}" "${PB_BG_ALT:-#313244}" 0.5)"
if [[ -n "$PB_BG" ]]; then
    mkdir -p "$(dirname "$PB_COLORS")"
    # Overwrite the entire file — guarantees consistency across all installs.
    cat > "$PB_COLORS" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
# Change the theme in ~/.config/dwm-titus/themes.toml instead.

[colors]
bg               = $PB_BG
fg               = $PB_FG
bg-alt           = $PB_BG_ALT
fg-alt           = $PB_FG_ALT

blue             = $PB_ACCENT
red              = $PB_URGENT

; These values are computed from the theme's terminal palette.
; Polybar modules that reference \${colors.cyan}, \${colors.green} etc. will
; fall back to the accent/urgent colours above if a theme doesn't define them.
cyan             = $PB_ACCENT
green            = $PB_ACCENT
orange           = $PB_URGENT
pink             = $PB_ACCENT
purple           = $PB_ACCENT
yellow           = $PB_ACCENT

black            = $PB_BG
white            = $PB_FG

soft             = $PB_SOFT

trans            = #00000000
semi-trans-black = #aa000000
EOF

    # Restart polybar to pick up the new colors
    if command -v polybar &>/dev/null; then
        POLYBAR_LAUNCH="${XDG_CONFIG_HOME:-$HOME/.config}/polybar/launch.sh"
        if [[ -x "$POLYBAR_LAUNCH" ]]; then
            "$POLYBAR_LAUNCH" 9>&- &
        fi
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# DUNST — write ~/.config/dunst/dunstrc urgency colors from the active theme.
# Only colors are set; every other dunst setting keeps its built-in default.
# ══════════════════════════════════════════════════════════════════════════════
DUNST_BG="$TERM_BG"
DUNST_FG="$TERM_FG"
DUNST_FRAME="${GTK_BORDER_COLOR:-#45475a}"
DUNST_CRIT_FRAME="$PB_URGENT"
DUNST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dunst"
mkdir -p "$DUNST_DIR"
cat > "$DUNST_DIR/dunstrc" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
# Change the theme in ~/.config/dwm-titus/themes.toml instead.
[urgency_low]
    background = "$DUNST_BG"
    foreground = "$DUNST_FG"
    frame_color = "$DUNST_FRAME"

[urgency_normal]
    background = "$DUNST_BG"
    foreground = "$DUNST_FG"
    frame_color = "$DUNST_FRAME"

[urgency_critical]
    background = "$DUNST_BG"
    foreground = "$DUNST_FG"
    frame_color = "$DUNST_CRIT_FRAME"
EOF
# Restart dunst so the new colors apply to future notifications
if pgrep -x dunst &>/dev/null; then
    pkill -x dunst 2>/dev/null || true
    sleep 0.3
    dunst 9>&- &
fi


# ══════════════════════════════════════════════════════════════════════════════
# BTOP — write ~/.config/btop/themes/dwm-titus.theme from the active theme
# (same keys Omarchy's btop.theme uses) and select it. btop reads the file
# at launch, so no restart handling is needed (it is not running as a daemon).
# ══════════════════════════════════════════════════════════════════════════════
BTOP_THEMES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/btop/themes"
if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/btop" ]]; then
    mkdir -p "$BTOP_THEMES_DIR"
    cat > "$BTOP_THEMES_DIR/dwm-titus.theme" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
# Change the theme in ~/.config/dwm-titus/themes.toml instead.
theme[main_bg]="${TERM_BG:-#1e1e2e}"
theme[main_fg]="${TERM_FG:-#cdd6f4}"
theme[title]="${TERM_FG:-#cdd6f4}"
theme[hi_fg]="${ROFI_BORDER_COLOR:-#89b4fa}"
theme[selected_bg]="${ROFI_BG_SELECTED:-#313244}"
theme[selected_fg]="${TERM_FG:-#cdd6f4}"
theme[inactive_fg]="$GTK_MUTED_CSS"
theme[proc_misc]="${ROFI_BORDER_COLOR:-#89b4fa}"
theme[cpu_box]="$GTK_MUTED_CSS"
theme[mem_box]="$GTK_MUTED_CSS"
theme[net_box]="$GTK_MUTED_CSS"
theme[proc_box]="$GTK_MUTED_CSS"
theme[div_line]="$GTK_MUTED_CSS"
theme[temp_start]="${TERM_C2:-#a6e3a1}"
theme[temp_mid]="${TERM_C3:-#f9e2af}"
theme[temp_end]="${TERM_C1:-#f38ba8}"
theme[cpu_start]="${TERM_C2:-#a6e3a1}"
theme[cpu_mid]="${TERM_C3:-#f9e2af}"
theme[cpu_end]="${TERM_C1:-#f38ba8}"
theme[free_start]="${TERM_C2:-#a6e3a1}"
theme[free_mid]="${TERM_C3:-#f9e2af}"
theme[free_end]="${TERM_C1:-#f38ba8}"
theme[cached_start]="${TERM_C2:-#a6e3a1}"
theme[cached_mid]="${TERM_C3:-#f9e2af}"
theme[cached_end]="${TERM_C1:-#f38ba8}"
theme[available_start]="${TERM_C2:-#a6e3a1}"
theme[available_mid]="${TERM_C3:-#f9e2af}"
theme[available_end]="${TERM_C1:-#f38ba8}"
theme[used_start]="${TERM_C2:-#a6e3a1}"
theme[used_mid]="${TERM_C3:-#f9e2af}"
theme[used_end]="${TERM_C1:-#f38ba8}"
theme[download_start]="${TERM_C2:-#a6e3a1}"
theme[download_mid]="${TERM_C3:-#f9e2af}"
theme[download_end]="${TERM_C1:-#f38ba8}"
theme[upload_start]="${TERM_C2:-#a6e3a1}"
theme[upload_mid]="${TERM_C3:-#f9e2af}"
theme[upload_end]="${TERM_C1:-#f38ba8}"
theme[graph_text]="${TERM_FG:-#cdd6f4}"
theme[meter_bg]="${ROFI_BG_SELECTED:-#313244}"
theme[process_start]="${TERM_C2:-#a6e3a1}"
theme[process_mid]="${TERM_C6:-#94e2d5}"
theme[process_end]="$GTK_MUTED_CSS"
EOF
    BTOP_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/btop/btop.conf"
    if [[ -f "$BTOP_CONF" ]] && grep -q '^color_theme' "$BTOP_CONF"; then
        sed -i 's|^color_theme.*|color_theme = "dwm-titus"|' "$BTOP_CONF"
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# GTK DARK / LIGHT MODE
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DARK_MODE" == "true" ]]; then
    GTK_COLOR_SCHEME="prefer-dark"
    # Use "Adwaita" + prefer-dark flag: on this GTK build the literal
    # "Adwaita-dark" theme name is not resolved and falls back to LIGHT.
    GTK_THEME_NAME="Adwaita"
    GTK_DARK_PREF=1
    GTK_ICON_NAME="Papirus-Dark"
else
    GTK_COLOR_SCHEME="default"
    GTK_THEME_NAME="Adwaita"
    GTK_DARK_PREF=0
    GTK_ICON_NAME="Papirus-Light"
fi

# ══════════════════════════════════════════════════════════════════════════════
# GTK3 COLORS — write ~/.config/gtk-3.0/active-gtk.css (imported by gtk.css)
# Mapping rule (same relationship on every theme):
#   dark:  sidebar/chrome = theme bg darkened 25%, body/canvas = theme bg
#          (e.g. tokyonight #1A1B26 → sidebar #13141C, body #1A1B26)
#   light: airy canvas (terminal bg) with slightly grey chrome (bar bg-alt)
# Optional per-theme gtk_bg / gtk_base keys override either value
# (macos-dark pins its classic elevated-neutral canvas).
# ══════════════════════════════════════════════════════════════════════════════
GTK3_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0"
GTK3_COLORS="$GTK3_DIR/active-gtk.css"
GTK_BG_OVERRIDE="$(theme_get gtk_bg)"
GTK_BASE_OVERRIDE="$(theme_get gtk_base)"
if [[ "$DARK_MODE" == "true" ]]; then
    GTK_BG_CSS="${GTK_BG_OVERRIDE:-$(darken "${TERM_BG:-#1e1e2e}" 0.75)}"
    GTK_BASE_CSS="${GTK_BASE_OVERRIDE:-${TERM_BG:-#1e1e2e}}"
else
    GTK_BG_CSS="${GTK_BG_OVERRIDE:-${PB_BG_ALT:-#E5E5EA}}"
    GTK_BASE_CSS="${GTK_BASE_OVERRIDE:-${TERM_BG:-#F5F5F7}}"
fi
# Selected-row pairing (M3 container style where provided): deep harmonious
# fill + its matching text. Defaults to accent + dark text (unchanged look
# for every theme that doesn't define select_bg/select_fg).
SELECT_BG_OVERRIDE="$(theme_get select_bg)"
SELECT_FG_OVERRIDE="$(theme_get select_fg)"
SELECT_BG_CSS="${SELECT_BG_OVERRIDE:-${ROFI_BORDER_COLOR:-#89b4fa}}"
SELECT_FG_CSS="${SELECT_FG_OVERRIDE:-$GTK_BG_CSS}"
if [[ -n "$TERM_BG" ]]; then
    mkdir -p "$GTK3_DIR"
    # gtk_entry: resting text-field border — same hue as the rofi/accent
    # border but softened toward the chrome so it doesn't shout; focus
    # ring stays full accent (see gtk.css entry:focus).
    GTK_ENTRY_CSS="$(mix "${ROFI_BORDER_COLOR:-#89b4fa}" "$GTK_BG_CSS" 0.4)"
    cat > "$GTK3_COLORS" <<EOF
/* Auto-generated by theme-apply.sh — do not edit manually. */
@define-color gtk_bg     $GTK_BG_CSS;
@define-color gtk_fg     ${TERM_FG:-#cdd6f4};
@define-color gtk_base   $GTK_BASE_CSS;
@define-color gtk_border ${GTK_BORDER_COLOR:-#45475a};
@define-color gtk_entry  $GTK_ENTRY_CSS;
@define-color gtk_accent ${ROFI_BORDER_COLOR:-#89b4fa};
@define-color gtk_muted  $GTK_MUTED_CSS;
@define-color gtk_select_bg  $SELECT_BG_CSS;
@define-color gtk_select_fg  $SELECT_FG_CSS;
EOF
fi

# Helper: set or add a key in a [Settings] ini file without destroying other settings
gtk_ini_set() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")"
    if [[ ! -f "$file" ]]; then
        printf '[Settings]\n%s=%s\n' "$key" "$value" > "$file"
        return
    fi
    if grep -q "^${key}" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    elif grep -q '^\[Settings\]' "$file"; then
        sed -i "/^\[Settings\]/a ${key}=${value}" "$file"
    else
        printf '\n[Settings]\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# GTK3
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/settings.ini" \
    "gtk-application-prefer-dark-theme" "$GTK_DARK_PREF"
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/settings.ini" \
    "gtk-theme-name" "$GTK_THEME_NAME"
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/settings.ini" \
    "gtk-icon-theme-name" "$GTK_ICON_NAME"

# GTK4
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-4.0/settings.ini" \
    "gtk-application-prefer-dark-theme" "$GTK_DARK_PREF"
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-4.0/settings.ini" \
    "gtk-theme-name" "$GTK_THEME_NAME"
gtk_ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/gtk-4.0/settings.ini" \
    "gtk-icon-theme-name" "$GTK_ICON_NAME"

# GTK2
printf 'gtk-theme-name="%s"\n' "$GTK_THEME_NAME" > "$HOME/.gtkrc-2.0"

# Live D-Bus update — affects running GTK4 apps, Flatpaks, and XDG portals
# (Brave/Chrome/Electron like VS Code follow color-scheme via portal)
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme "$GTK_COLOR_SCHEME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme    "$GTK_THEME_NAME"   2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme   "$GTK_ICON_NAME"  2>/dev/null || true
fi

# xsettingsd — keeps X11/XFCE apps (Thunar, file dialogs) in sync.
# Only touches ThemeName/IconThemeName lines, preserves everything else.
XSETTINGSD_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/xsettingsd/xsettingsd.conf"
if [[ -f "$XSETTINGSD_CONF" ]]; then
    sed -i "s|^Net/ThemeName .*|Net/ThemeName \"$GTK_THEME_NAME\"|" "$XSETTINGSD_CONF"
    if grep -q '^Net/IconThemeName' "$XSETTINGSD_CONF"; then
        sed -i "s|^Net/IconThemeName .*|Net/IconThemeName \"$GTK_ICON_NAME\"|" "$XSETTINGSD_CONF"
    else
        echo "Net/IconThemeName \"$GTK_ICON_NAME\"" >> "$XSETTINGSD_CONF"
    fi
    # Reload live daemon if running (HUP); autostart launches it otherwise
    if pgrep -x xsettingsd &>/dev/null; then
        pkill -HUP -x xsettingsd 2>/dev/null || true
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# QT DARK / LIGHT MODE
# ══════════════════════════════════════════════════════════════════════════════
# Prefer qt6ct > qt5ct; fall back to gtk3 (inherits GTK theme set above)
if command -v qt6ct &>/dev/null; then
    QT_PLATFORM_THEME="qt6ct"
elif command -v qt5ct &>/dev/null; then
    QT_PLATFORM_THEME="qt5ct"
else
    QT_PLATFORM_THEME="gtk3"
fi

# Write persistent env file — sourced by autostart.sh so tray apps inherit it
THEME_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/theme-env.sh"
cat > "$THEME_ENV_FILE" <<EOF
# Auto-generated by theme-apply.sh — do not edit manually.
export QT_QPA_PLATFORMTHEME=$QT_PLATFORM_THEME
EOF

# Update qt5ct / qt6ct color scheme config if that tool is the active theme.
# If no conf exists yet, create a minimal one so light/dark is explicit
# instead of leaving Qt appearance undefined. Never overwrites existing keys
# except color_scheme_path.
if [[ "$QT_PLATFORM_THEME" == "qt5ct" || "$QT_PLATFORM_THEME" == "qt6ct" ]]; then
    QT_CT_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/${QT_PLATFORM_THEME}/${QT_PLATFORM_THEME}.conf"
    if [[ "$DARK_MODE" == "true" ]]; then
        QT_CT_SCHEME="/usr/share/${QT_PLATFORM_THEME}/colors/darker.conf"
    else
        QT_CT_SCHEME=""
    fi
    if [[ ! -f "$QT_CT_CONF" ]]; then
        mkdir -p "$(dirname "$QT_CT_CONF")"
        printf '[Appearance]\nstyle=Fusion\ncolor_scheme_path=%s\n' "$QT_CT_SCHEME" > "$QT_CT_CONF"
    elif grep -q '^color_scheme_path' "$QT_CT_CONF"; then
        sed -i "s|^color_scheme_path=.*|color_scheme_path=$QT_CT_SCHEME|" "$QT_CT_CONF"
    else
        sed -i "/^\[Appearance\]/a color_scheme_path=${QT_CT_SCHEME}" "$QT_CT_CONF"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# BROWSERS — force Chromium prefers-color-scheme from the selected theme.
# Brave / Chrome / Helium wrappers read these confs line-by-line at launch,
# so web content (Google results, etc.) follows the OS theme automatically.
# Only the managed --force-prefers-color-scheme line is replaced; every other
# user flag (e.g. Vulkan) is preserved byte-for-byte. Takes effect on next
# browser launch (running browsers keep their current scheme until restart).
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DARK_MODE" == "true" ]]; then
    BROWSER_SCHEME="dark"
else
    BROWSER_SCHEME="light"
fi
for BROWSER_FLAGS in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/brave-origin-flags.conf" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/chrome-flags.conf" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/helium-browser-flags.conf"; do
    if [[ -f "$BROWSER_FLAGS" ]]; then
        # Unique temp file: DWM can spawn concurrent theme-apply runs
        # (inotify + SIGUSR1), and a shared tmp name corrupts the conf.
        FLAGS_TMP="$(mktemp "$(dirname "$BROWSER_FLAGS")/.flags.XXXXXX")"
        grep -v '^--force-prefers-color-scheme=' "$BROWSER_FLAGS" > "$FLAGS_TMP" || true
        printf '%s\n' "--force-prefers-color-scheme=$BROWSER_SCHEME" >> "$FLAGS_TMP"
        mv "$FLAGS_TMP" "$BROWSER_FLAGS"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# BROWSER FRAME — tint Chromium frame/toolbar with the theme color via
# managed enterprise policy (same mechanism Omarchy uses). Per-theme
# `browser_frame` key wins, otherwise the bar color is used so the frame
# matches polybar + terminal. Content scheme follows the OS (device).
# Running browsers refresh live (no restart, no tab loss). Policy dirs need
# a one-time root setup; missing dirs are skipped silently (never an error).
# ══════════════════════════════════════════════════════════════════════════════
BROWSER_FRAME="$(theme_get browser_frame)"
BROWSER_FRAME="${BROWSER_FRAME:-$PB_BG}"
write_browser_policy() {
    local policy_dir="$1" refresh_bin="$2" proc_name="$3"
    [[ -d "$policy_dir" ]] || return 0
    printf '{"BrowserThemeColor": "%s", "BrowserColorScheme": "device"}' \
        "$BROWSER_FRAME" > "$policy_dir/color.json"
    if command -v "$refresh_bin" &>/dev/null && pgrep -x "$proc_name" &>/dev/null; then
        "$refresh_bin" --refresh-platform-policy --no-startup-window 9>&- &>/dev/null &
    fi
}
write_browser_policy "/etc/brave/policies/managed" "brave-origin" "brave"
write_browser_policy "/etc/opt/chrome/policies/managed" "google-chrome-stable" "chrome"

# Propagate to D-Bus-activated services already running in this session
if command -v dbus-update-activation-environment &>/dev/null; then
    dbus-update-activation-environment QT_QPA_PLATFORMTHEME="$QT_PLATFORM_THEME" 2>/dev/null || true
fi

# Restart flameshot so its tray icon picks up the new theme
if pgrep -x flameshot &>/dev/null; then
    pkill -x flameshot 2>/dev/null || true
    sleep 0.3
    QT_QPA_PLATFORMTHEME="$QT_PLATFORM_THEME" flameshot 9>&- &
fi

# Restart nm-applet so its tray/wifi icons reload the new icon theme
# (safe: only the indicator UI restarts, the network connection is untouched)
if pgrep -x nm-applet &>/dev/null; then
    pkill -x nm-applet 2>/dev/null || true
    sleep 0.3
    nm-applet 9>&- &
fi

# Refresh Thunar so GTK apps pick up the new stylesheet. Thunar caches CSS
# per-process, so quit and relaunch it after every theme change. This closes
# open Thunar windows intentionally; the new daemon inherits the new theme.
# Autostart is untouched: it launches the same `thunar --daemon` on login.
if pgrep -x thunar &>/dev/null; then
    thunar -q 2>/dev/null || true
    for _ in $(seq 1 10); do
        pgrep -x thunar &>/dev/null || break
        sleep 0.3
    done
    thunar --daemon 9>&- &
fi


# Repaint DWM borders on existing windows. DWM only paints borders on
# focus/manage events, so windows open during a switch keep stale colors
# until refocused (new windows are always correct). Cycle Super+j until
# focus returns to origin; focusstack never restacks, so layout is kept.
# Works regardless of focus style (click/hover/super+j) — it drives DWM's
# own keybind, not the user's habits.
if command -v xdotool &>/dev/null && pgrep -x dwm &>/dev/null; then
    # Make sure DWM reloaded the theme into memory first (manual runs
    # don't touch themes.toml, so inotify may not have fired). Guarded by
    # timestamp: DWM's reload spawns another theme-apply, which must NOT
    # re-signal, or the two ping-pong forever ("infinite reloading").
    USR1_STAMP="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus/.last-usr1"
    USR1_NOW="$(date +%s)"
    USR1_LAST="$(cat "$USR1_STAMP" 2>/dev/null || echo 0)"
    if (( USR1_NOW - USR1_LAST > 60 )); then
        echo "$USR1_NOW" > "$USR1_STAMP" 2>/dev/null || true
        pkill -USR1 -x dwm 2>/dev/null || true
        sleep 0.3
    fi
    ORIG_FOCUS="$(xdotool getwindowfocus 2>/dev/null || true)"
    if [[ -n "$ORIG_FOCUS" ]]; then
        # Guard scales with window count (early-break on return is the
        # normal exit; the cap only stops runaways). Overshooting is
        # harmless: extra presses just keep rotating through clients.
        NWIN="$(xdotool search --onlyvisible "" 2>/dev/null | wc -l)"
        GUARD=$((NWIN * 2 + 5))
        if ((GUARD < 20)); then GUARD=20; fi
        if ((GUARD > 60)); then GUARD=60; fi
        for _ in $(seq 1 "$GUARD"); do
            xdotool key --clearmodifiers Super+j 2>/dev/null || break
            sleep 0.08
            CUR_FOCUS="$(xdotool getwindowfocus 2>/dev/null || true)"
            [[ "$CUR_FOCUS" == "$ORIG_FOCUS" ]] && break
        done
        xdotool windowfocus "$ORIG_FOCUS" 2>/dev/null || true
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# STARSHIP — rewrite the marked palette block in ~/.config/starship.toml from
# the active theme. Only the region between the two markers is replaced; the
# prompt layout above them is user-owned and never touched. If the markers are
# absent the block is appended once, so a hand-written config gains them safely.
# Starship re-reads its config on every prompt, so no restart is needed.
# ══════════════════════════════════════════════════════════════════════════════
STARSHIP_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
STARSHIP_BEGIN="# >>> starship theme palette (generated by theme-apply.sh - do not edit) >>>"
STARSHIP_END="# <<< starship theme palette <<<"
if [[ -f "$STARSHIP_CFG" ]]; then
    # Ink for solid-background segments: a dark theme's background reads as
    # text on top of a bright accent; a light theme's background is near-white
    # and would vanish, so those fall back to pure black.
    if [[ "$DARK_MODE" == "true" ]]; then
        SS_PILL_FG="${TERM_BG:-#000000}"
    else
        SS_PILL_FG="#000000"
    fi

    SS_PALETTE="$(mktemp)"
    cat > "$SS_PALETTE" <<EOF
$STARSHIP_BEGIN
[palettes.theme]
bg            = "${TERM_BG:-#1e1e2e}"
fg            = "${TERM_FG:-#cdd6f4}"
muted         = "${GTK_MUTED_CSS:-#7f849c}"
accent        = "${SEL_BORDER:-#89b4fa}"
red           = "${TERM_C1:-#f38ba8}"
green         = "${TERM_C2:-#a6e3a1}"
yellow        = "${TERM_C3:-#f9e2af}"
blue          = "${TERM_C4:-#89b4fa}"
purple        = "${TERM_C5:-#f5c2e7}"
cyan          = "${TERM_C6:-#94e2d5}"
bright_red    = "${TERM_C9:-#f38ba8}"
bright_green  = "${TERM_C10:-#a6e3a1}"
bright_yellow = "${TERM_C11:-#f9e2af}"
bright_blue   = "${TERM_C12:-#89b4fa}"
bright_purple = "${TERM_C13:-#f5c2e7}"
bright_cyan   = "${TERM_C14:-#94e2d5}"
pill_fg       = "$SS_PILL_FG"
$STARSHIP_END
EOF

    SS_TMP="$(mktemp "${STARSHIP_CFG}.XXXXXX")"
    if grep -qF "$STARSHIP_BEGIN" "$STARSHIP_CFG" \
       && grep -qF "$STARSHIP_END" "$STARSHIP_CFG"; then
        # Replace the existing marked region in place.
        awk -v begin="$STARSHIP_BEGIN" -v end="$STARSHIP_END" -v pal="$SS_PALETTE" '
            $0 == begin {
                while ((getline line < pal) > 0) print line
                close(pal)
                skipping = 1
                next
            }
            skipping && $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$STARSHIP_CFG" > "$SS_TMP"
    else
        # No markers yet: keep the file and append the block.
        cp "$STARSHIP_CFG" "$SS_TMP"
        printf '\n' >> "$SS_TMP"
        cat "$SS_PALETTE" >> "$SS_TMP"
    fi
    cat "$SS_TMP" > "$STARSHIP_CFG"
    chmod 644 "$STARSHIP_CFG" 2>/dev/null || true
    rm -f "$SS_TMP" "$SS_PALETTE"
fi


echo "theme-apply: applied theme '$THEME_NAME'"
