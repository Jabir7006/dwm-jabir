# Input, clipboard and capture

## Input

Session/input setup is deployed under ~/.local/share/dwm-titus/scripts/. Persistent device configuration may also live under /etc/X11/xorg.conf.d/, /etc/libinput/ and /etc/keyd/. Check the actual device/server and available utilities before applying settings; xinput was not resolved in the observed agent PATH. This system can use XLibre, so do not assume a Wayland/Hyprland input interface.

Mouse and touchpad mappings are distinct. The installer has saved left-handed physical-mouse handling while keeping touchpads conventional, and VM input differs. Preserve that distinction and check the affected device rather than globally remapping every pointer.

~/.xprofile controls repeat/cursor environment. SUPER+K uses the built-in keyboard toggle. Read its helper before disabling devices; preserve a working way to reverse the toggle. WayClick scripts/runner and sound packs live under home/user_scripts and home/contained_apps equivalents; input access depends on the configured group/service rules. Do not start keyboard capture merely to inspect context.

## Clipboard and capture

Clipboard history is clipmenud + clipnotify, limited to explicit clipboard copies. The autostart clears old history; do not rerun it to refresh a launcher. Rofi's clipboard-menu/clipboard-launcher are the user interfaces.

The deployed dwm-screenshot wrapper uses Flameshot with full, gui and clip actions and an XDG pictures directory. Recording helpers and their hotkeys should be discovered in scripts/ and hotkeys.toml; preserve output directory, audio source, stop action and cleanup. Capture only the relevant UI region for inspection. Screenshots/recordings can contain private content and do not belong in the public system skill.

Dunst controls notifications; reminder behavior is in automation.md. Lock/idle functionality must be discovered from current bindings and running processes. DPMS is intentionally disabled in the present autostart; a new idle/lock policy needs an explicit requested behavior, not silent replacement of that setting.
