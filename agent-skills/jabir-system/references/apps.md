# Applications and defaults

Check the executable, launcher and applicable configuration before changing defaults. A saved Ghostty/Picom directory does not prove the program exists in the active PATH. Graphical and agent-shell environments can differ; inspect ~/.profile, session setup and launcher Exec fields without dumping credential-bearing environment values.

| Area | Entry points |
|---|---|
| Terminals | ~/.config/alacritty/, kitty/, ghostty/; hotkeys [vars].terminal |
| Fish | ~/.config/fish/config.fish, conf.d/, functions/; inspect scripts before sourcing them |
| Launchers | Rofi config.rasi, desktop files in ~/.local/share/applications/, deployed webapp-create/webapp-launch |
| TUI tools | btop, fastfetch and their ~/.config directories |
| Editors | Code/User, Code - OSS/User, VSCodium/User and editor-specific ~/.config roots; theme template in appearance.md |
| MIME/defaults | ~/.config/mimeapps.list, xdg-mime, xdg-settings |
| Packaging | pacman, installed AUR helper, repository install-apps.sh/packages/ |

Use xdg-mime query default for the specific type, and xdg-settings get default-web-browser for the browser. Check the target desktop entry supports the actual file arguments; do not confuse a displayed launcher name with its desktop ID. Wine extension mappings can unexpectedly claim PDFs or other types.

Webapp/TUI helpers are custom dwm scripts, even when some filenames resemble Omarchy. Read their command syntax and dependencies before executing; do not substitute upstream Omarchy launch commands. Preserve desktop IDs, icons, classes and WM rules when changing a launcher.

Package installation/removal follows the user's requested scope. Arch/CachyOS repo compatibility and full upgrades are installer concerns; do not initiate a system upgrade while editing one app's config. Package inventories are references, not a list to blindly reinstall. Preserve app profiles, logins and data when hiding/removing a launcher unless deletion was requested.

Deploy custom helpers from repository scripts/ to ~/.local/share/dwm-titus/scripts and the actual PATH symlink/copy. Home tools belong in the matching repository home/ path. See repo.md for avoiding broad installation/snapshot side effects.
