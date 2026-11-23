#!/bin/bash
# Portable copy of the startx entry; the installer deploys scripts/.xinitrc.
[[ ! -r "$HOME/.profile" ]] || . "$HOME/.profile"
[[ ! -r "$HOME/.xprofile" ]] || . "$HOME/.xprofile"
exec dbus-run-session -- dwm
