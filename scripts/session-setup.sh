#!/usr/bin/env bash
# Shared session environment and saved appearance for LightDM and startx.
set -u

# shellcheck disable=SC1091 # Installed per-user configuration.
[[ ! -r "$HOME/.profile" ]] || . "$HOME/.profile"
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
# shellcheck disable=SC1091 # Generated per-user theme environment.
[[ ! -r "$config_root/dwm-titus/theme-env.sh" ]] || . "$config_root/dwm-titus/theme-env.sh"

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user import-environment PATH DISPLAY XAUTHORITY QT_QPA_PLATFORMTHEME 2>/dev/null || true
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --systemd PATH DISPLAY XAUTHORITY QT_QPA_PLATFORMTHEME 2>/dev/null || true
fi
if command -v dconf >/dev/null 2>&1 && [[ -r "$config_root/dconf/interface.ini" ]]; then
    dconf load /org/gnome/desktop/interface/ < "$config_root/dconf/interface.ini" || \
        printf '%s\n' 'Could not load saved interface settings; check the session D-Bus service.' >&2
fi
if command -v systemctl >/dev/null 2>&1 && command -v pipewire >/dev/null 2>&1; then
    systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service || \
        printf '%s\n' 'Audio services could not start; see journalctl --user -u pipewire -u wireplumber.' >&2
fi
