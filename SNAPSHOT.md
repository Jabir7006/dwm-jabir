# Saved desktop reference

This repository contains shareable settings, custom scripts, Python tools,
launchers, fonts, icons, sound packs, wallpapers, and a package inventory from
Jabir's desktop. `snapshot-manifest.json` records each source/destination and
lists excluded private or generated data. Source files on the desktop are read
only during export.

| Saved files | Installation destination |
| --- | --- |
| `config/` directories and top-level files | `~/.config/` |
| `home/` dotfiles and standalone Python/shell tools | `~/` |
| `home/.local/bin/` | `~/.local/bin/` |
| `home/custom-scripts/`, `home/user_scripts/` | corresponding home directories |
| `home/contained_apps/` | contained application source; Python environments rebuilt locally |
| `home/.local/share/icons/` | saved icon overrides and launcher icons |
| `fonts/`, `wallpapers/` | local fonts and `~/Pictures/backgrounds/` |
| `system-config/usr/local/bin/` | custom `/usr/local/bin` helpers |
| `system-config/reference/etc/` | reference copies of public system configuration |

The saved `.fehbg` initially selects Ristretto industrial moon; installer reruns
keep the user's later selection. The wallpaper bundle contains five small images
(about 523 KiB total), including that Ristretto wallpaper. Snapshot refreshes keep
this curated bundle. Existing images in an installation are left in place.

Picker, carousel, and random selection use `wallpaper-apply`: it applies and saves
the image before optional palette generation, so missing or failing palette tools
cannot undo the selection. Palette errors are recorded in
`~/.cache/wallpaper-picker/apply.log`. The carousel stays open if applying fails.
Text files default to l3afpad, which is installed with the core packages. Image
files use `nsxiv -b %f`, with its status bar hidden and each file passed once.

Polybar uses the saved laptop
layout on both laptops and VMs; missing battery/backlight modules are omitted
without switching the remaining modules to another layout. Fastfetch keeps the
saved configuration. Machine readings, available hardware, and OS-specific logo
selection naturally reflect the target machine.

Installer compatibility changes are recorded as portable overrides. They include
session PATH setup, optional Fish integrations, mouse/touchpad separation,
virtual input handling, an MPV window/GPU fallback, and optional PipeWire network
modules. The four unwanted Cineo/DeepAI Code/OpenCode/Warp launchers are hidden
with `NoDisplay`, while their application data is not deleted.

Root configuration is retained for reference rather than transplanted over a
new machine. The installer applies only its existing prompted system settings
and saved browser **colour** policies. It never imports browser accounts,
enterprise restrictions, disk layouts, machine identity, or SSH host keys.

## Data deliberately excluded

Credentials, private keys, OAuth/login/session databases, browser profiles,
histories, cookies, caches, logs, backups, dependency directories, compiled
application binaries, and Python virtual environments are excluded. Credential
fields in otherwise useful editor JSON preferences are cleared; existing safe
shell templates retain environment-based secret loading. Public settings can be
restored, but accounts still need a new login or `setup-secrets.sh`.

The `packages/reference-*.txt` files are inventories, not an instruction to
blindly reinstall all packages. Core dependencies include the tools needed by
the bundled launchers and wallpaper/Python scripts. Optional applications still
use `./install.sh --with-apps`.

WayClick's runner and sound packs are included. A normal installation prepares
its Python environment. Reading keyboard devices requires the optional input
access prompt and a new login; the installer does not start keyboard capture.

## Refreshing the snapshot

From this repository, when you explicitly want to update the saved reference:

```bash
python3 scripts/snapshot-desktop.py --home /home/jabir
```

Review `snapshot-manifest.json` and the diff before publishing. Portable
installer fixes are retained so exporting the original live files cannot undo
those fixes. Login/authentication data must remain private.
