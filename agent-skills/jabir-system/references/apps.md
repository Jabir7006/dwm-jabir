# Applications and defaults

Check the executable, launcher and applicable configuration before changing defaults. A saved Ghostty/Picom directory does not prove the program exists in the active PATH. Graphical and agent-shell environments can differ; inspect ~/.profile, session setup and launcher Exec fields without dumping credential-bearing environment values.

| Area | Entry points |
|---|---|
| Terminals | ~/.config/alacritty/, kitty/, ghostty/; hotkeys [vars].terminal |
| Fish | ~/.config/fish/config.fish, conf.d/, functions/; bash/zsh/fish source ~/.config/dwm-titus/secrets.{env,fish} — never dump the environment |
| Launchers | Rofi config.rasi, desktop files in ~/.local/share/applications/, deployed webapp-create/webapp-launch |
| TUI tools | btop, fastfetch and their ~/.config directories |
| Editors | Code/User, Code - OSS/User, VSCodium/User and editor-specific ~/.config roots; theme template in appearance.md |
| MIME/defaults | ~/.config/mimeapps.list, xdg-mime, xdg-settings |
| Packaging | pacman, installed AUR helper, repository install-apps.sh/packages/ |

Use xdg-mime query default for the specific type, and xdg-settings get default-web-browser for the browser. Check the target desktop entry supports the actual file arguments; do not confuse a displayed launcher name with its desktop ID. Wine extension mappings can unexpectedly claim PDFs or other types.

Webapp/TUI helpers are custom dwm scripts, even when some filenames resemble Omarchy. Read their command syntax and dependencies before executing; do not substitute upstream Omarchy launch commands. Preserve desktop IDs, icons, classes and WM rules when changing a launcher.

Custom user tools are launched from hotkeys but owned outside the shell:

| Helper | Owns |
|---|---|
| app-manager (SUPER+N) | Create/remove/launch webapps and TUI launchers; writes ~/.local/share/applications |
| om-install, pkg-installer | Package install/remove menus; privileged actions stay explicit |
| pkg-scan.py | Lists installed packages; read-only inventory, not an installer |
| localsend-toggle + Polybar localsend module | hostapd AP `ap0` and dnsmasq; needs sudo, config in /etc/hostapd |
| vmtoggle | libvirt daemon and default network; `off` refuses while a VM runs without -f |
| wayclick (SUPER+CTRL+K) | Keyboard click sound engine; nothing starts at boot, group/input permissions apply |
| music_recognition.py, minitop.py, protonrestart, xzoom | On-demand tools; no resident service |

Do not start hostapd, libvirt or the input capture path just to inspect their configuration.

Package installation/removal follows the user's requested scope. Arch/CachyOS repo compatibility and full upgrades are installer concerns; do not initiate a system upgrade while editing one app's config. Package inventories are references, not a list to blindly reinstall. Preserve app profiles, logins and data when hiding/removing a launcher unless deletion was requested.

Deploy custom helpers from repository scripts/ to ~/.local/share/dwm-titus/scripts and the actual PATH symlink/copy. Home tools belong in the matching repository home/ path. See repo.md for avoiding broad installation/snapshot side effects.
