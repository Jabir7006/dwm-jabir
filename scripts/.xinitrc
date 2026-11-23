#!/bin/bash

# .xinitrc — only used when starting dwm via startx (not SDDM)
# All setup (DPMS, dbus env, services) is handled by autostart.sh

[[ ! -r "$HOME/.profile" ]] || . "$HOME/.profile"
[[ ! -r "$HOME/.xprofile" ]] || . "$HOME/.xprofile"
dbus-run-session -- sh -c 'exec dwm'
