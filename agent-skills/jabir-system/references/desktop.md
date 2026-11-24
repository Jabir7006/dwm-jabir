# Windows and session

## Configuration and reload

Live files: ~/.config/dwm-titus/hotkeys.toml, window-rules.toml and themes.toml. Their repository counterparts are under config/dwm-titus/. Defaults are also deployed under ~/.local/share/dwm-titus/config/dwm-titus/.

Inspect the requested binding and nearby conflicts before editing. hotkeys.toml uses [vars], keys arrays, tag_keys and buttons; the custom parser accepts its existing layout. Do not restructure it merely to satisfy another tool's preferred schema. Validate TOML syntax, then use the existing hot reload or:

    pkill -USR1 -x dwm

SIGUSR1 reloads configuration; it is not a session restart. Inspect load_hotkeys_toml, load_rules_toml and reload_config in dwm.c when extending supported behavior. Source changes require a build and an appropriate deployment/session plan; make install also copies configuration, so inspect its effects first.

## Rules and geometry

Use xprop to identify WM_CLASS and title. The current load_rules_toml implementation reads class, instance, title, tags, isfloating, isterminal, noswallow and monitor. Matching uses substring checks. tags in rules is a 1-based single tag; tag_keys entries use zero-based indices.

Some saved examples contain width, height and iscentered, but those fields are not read by the current parser. Inspect implementation before relying on them. Prefer application geometry or extend the parser only when the feature requires it. Verify a newly opened matching window; reloading a rule is not proof that existing clients were reclassified.

Dwm exposes EWMH desktop/client properties for Polybar. It does not implement every ABOVE/STICKY/_NET_CLOSE_WINDOW request. The OSK overlay deliberately bypasses WM management; see appearance.md.

## Session and monitors

Use xrandr for X11 monitors and verify offsets, primary status, work-area reservation and pointer mapping. User setup lives in ~/.profile, ~/.xprofile and deployed session-setup.sh/input-setup.sh. autostart.sh is the shared entrypoint and runs dex for XDG autostart files. ~/.xinitrc is the startx path; LightDM uses the installed X session entry.

Autostart currently disables DPMS/blanking and starts clipboard, notifications, tray helpers and Polybar. Do not run it wholesale to reload one component: it can clear clipboard history and start additional applications.
