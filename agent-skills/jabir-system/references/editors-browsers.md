# Editor and browser theming

Both editors and browsers are outputs of the same palette pipeline. Change the palette source or the generator; never edit an installed theme, extension directory, flag file or managed policy as the durable fix.

## What the generator writes

`scripts/theme-apply.sh` (live: `~/.local/share/dwm-titus/scripts/theme-apply.sh`, symlinked from `~/.local/bin`) regenerates terminals, Rofi, Polybar and tag colours, dunst, btop, the Papirus overlay, GTK2/3/4, Qt, browser flags/policies and the editor theme. It holds a lock and exits if another run is in progress. dwm spawns it when `themes.toml` is saved; it can be run manually.

`theme-audit` recomputes the expected palette and compares the generated files and gsettings (exit 1 on drift). It covers palette layers, browser flags and policies; it does not inspect the editor extension or settings.

`[theme.dynamic]` is generated, not authored: `theme-set-dynamic [wallpaper] [--stage-only] [--no-wallpaper]` runs matugen (`matugen image ... --json hex --dry-run --prefer saturation -m dark|light`), maps it through `matugen-dynamic-map`, and replaces only that TOML section. It needs matugen and Python PIL, aborts before writing on failure, and sets the picture with feh before re-applying colours. When another theme is active, the block is staged for later use. `wallpaper-apply` (used by picker/carousel/random) applies the picture first; palette failure must not undo the selection.

## Editors (VS Code family)

VS Code cannot load a colour-theme JSON directly, so the theme is published as a code-free local extension:

| Item | Value |
|---|---|
| Template | `scripts/templates/vscode-theme.json.tpl` → `~/.local/share/dwm-titus/scripts/templates/` |
| Rendered theme | `~/.local/state/dwm-titus/dwm-jabir-color-theme.json` |
| Extension id / name | `local.dwm-jabir-theme` / `dwm-jabir-theme` |
| Display name | `DWM Jabir` (also the `workbench.colorTheme` value) |
| Version | `1.0.0` |

Per editor, `theme-apply.sh` installs `<ext-root>/dwm-jabir-theme/package.json`, symlinks `themes/dwm-jabir-color-theme.json` to the rendered state file, upserts the extension into `<ext-root>/extensions.json`, and clears a stale `.obsolete` entry for this id if one exists. The symlink is why a regenerated theme reaches every editor without reinstalling.

Editor matrix used by the generator:

| Config dir under `~/.config` | Extension root | Process |
|---|---|---|
| `Code/User` | `~/.vscode/extensions` | `code` |
| `Code - Insiders/User` | `~/.vscode-insiders/extensions` | `code-insiders` |
| `Code - OSS/User` | `~/.vscode-oss/extensions` | `code-oss` |
| `VSCodium/User` | `~/.vscode-oss/extensions` | `codium` |
| `Cursor/User` | `~/.cursor/extensions` | `cursor` |
| `Windsurf/User` | `~/.windsurf/extensions` | `windsurf` |
| `Antigravity IDE/User` | `~/.antigravity-ide/extensions` | `antigravity` |

A row is skipped unless both the settings dir and extension root exist. Code - OSS and VSCodium deliberately share one extension root; do not "fix" that by installing twice.

`settings.json` is JSONC, so it is patched in place with sed: only an uncommented `"workbench.colorTheme"` line is rewritten, otherwise the key is inserted after the first `{`. Comments, trailing commas and unrelated settings must survive. Because a running editor holds both settings and the extension scan in memory, a running editor is only named in the warning; restart it to apply. Generation is guarded: a leftover `{{ token }}` or invalid JSON aborts and keeps the previous theme.

Template colour shaping worth preserving: muted never equals the background (fallback to colour7); orange comes from the theme's `orange` key or red/yellow mix; dark chrome is the background mixed 21% toward black with popups 3.4% toward white (light: 6% and 50%). Those depth steps reproduce the reference theme instead of adding borders.

To change what editors look like, edit the template or the token mapping in `theme-apply.sh`, re-run it, then restart a running editor. Deleting the extension or rewriting `extensions.json` is not a fix; the next apply recreates it.

## Browsers (Brave, Chrome/Chromium, Helium)

Two different mechanisms, often confused:

1. **Web content colour scheme** — the launcher wrapper reads `~/.config/brave-origin-flags.conf`, `~/.config/chrome-flags.conf` and `~/.config/helium-browser-flags.conf` line by line. The generator replaces only `--force-prefers-color-scheme=dark|light`, preserving every other user flag byte-for-byte. It takes effect on the next launch; a running browser keeps its current scheme. A missing file is left missing, not created.
2. **Browser frame/toolbar colour** — managed enterprise policy `color.json` with `{"BrowserThemeColor": "<colour>", "BrowserColorScheme": "device"}` under `/etc/brave/policies/managed`, `/etc/opt/chrome/policies/managed` and `/etc/chromium/policies/managed`. The colour is the per-theme `browser_frame` key, else `polybar_bg`. Missing policy dirs are skipped silently; creating them is a one-time root setup. Running browsers are refreshed with `<binary> --refresh-platform-policy --no-startup-window` (`brave-origin`, `google-chrome-stable`, `helium-browser`), so no restart or tab loss.

The GTK/portal side is separate: `gsettings set org.gnome.desktop.interface color-scheme prefer-dark|default` is what Chromium/Electron apps read through the XDG portal. Setting only the flag or only the policy leaves one layer stale.

Never reset managed policies wholesale (they may contain organization rules) and never strip unrelated launcher flags. Verify with the flags file, the policy JSON and `theme-audit`.
