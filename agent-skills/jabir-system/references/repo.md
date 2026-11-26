# Source, deployment and reproducibility

Repository: ~/dwm-jabir, public remote Jabir7006/dwm-jabir. Check branch/status before editing and preserve unrelated work.

| Repository source | Live destination |
|---|---|
| config/... | ~/.config/... |
| scripts/... | ~/.local/share/dwm-titus/scripts/... and selected ~/.local/bin symlinks or /usr/local/bin copies |
| home/... | corresponding paths under ~/ |
| fonts/ and config/polybar/fonts/ | installed local fonts |
| wallpapers/ | ~/Pictures/backgrounds/ |
| system-config/usr/local/bin/ | custom installed system helpers |
| system-config/reference/etc/ | reference material; not an automatic restore over /etc |
| agent-skills/jabir-system/ | discoverable ~/.codex/skills and ~/.agents/skills links |

Resolve the actual symlink/executable first; some helpers use deployed sources while others are installed copies. Apply a focused source change to its exact live counterpart. A script may exist in scripts/, ~/.local/share/dwm-titus/scripts/, ~/.local/bin (symlink) and /usr/local/bin; the copies can drift (the current /usr/local/bin/theme-apply.sh is older than the deployed one). Check `readlink -f "$(command -v <helper>)"` and the path the caller actually uses before editing. Do not blindly copy generated palette files or overwrite portable installer fixes with older live files.

Read Makefile before using make install: it builds/deploys dwm, copies the entire repository into ~/.local/share/dwm-titus (helpers such as dwm-keybinds read docs/config from there) and copies every config/*/ directory over ~/.config with --remove-destination. It is therefore not a safe way to apply one config edit. For C changes, inspect the affected code, build, then arrange the authorized binary/session update. TOML or Polybar edits normally need no rebuild or installer run.

setup-secrets.sh writes ~/.config/dwm-titus/secrets.env and secrets.fish with mode 600 for local tokens; keep them out of the repository, snapshot and replies.

install.sh targets Arch/CachyOS; install-arm.sh is a separate path. Read INSTALL.md, SNAPSHOT.md, package/dependency selection and the relevant installer section before changing deployment. Root-only tuning is not implied by a UI change. Tests in debug/ can exercise installers/desktops and may have side effects; inspect their modes before executing on this live host.

scripts/snapshot-desktop.py exports a curated desktop snapshot. Run it only for a requested snapshot refresh. It retains portable overrides and deliberately excludes credentials, browser accounts/profiles, keys, histories, caches, binaries and virtual environments. Review snapshot-manifest.json and the diff; public settings and reference package inventories are not credentials or a blind restore plan.

Skill maintenance: edit its canonical agent-skills directory, run quick_validate.py and test context.py for the changed sections. Keep the entrypoint small and information in one relevant guide. Refresh current-system.md when architecture changes, not every theme switch. Commit/push only when requested; include the final accepted state, not rejected UI experiments.
