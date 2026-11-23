#!/bin/sh
# Weather module — API key lives in ~/.config/dwm-titus/secrets.env (never in git)
[ -f "$HOME/.config/dwm-titus/secrets.env" ] && . "$HOME/.config/dwm-titus/secrets.env"
exec python3 "$HOME/.config/polybar/scripts/weather/main.py" -u metric
