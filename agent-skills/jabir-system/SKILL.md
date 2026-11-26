---
name: jabir-system
description: Customize, extend and troubleshoot Jabir's existing Arch Linux desktop and dwm-jabir deployment. Use for this system's dwm/X11 windows, Polybar, themes, apps, input, capture, automation, host services, hardware and installer integration. Ordinary application development on unrelated projects does not need this skill.
---

# Jabir System

This is Jabir's custom Arch + dwm/X11 system, with a CachyOS kernel. Omarchy supplies design ideas; its Hyprland/Quickshell commands are not this system's control interface.

## Load only what the task needs

Reuse verified session context. Read one relevant guide, not the whole skill package. Run the read-only helper only for facts that need checking; its default summary is intentionally small:

    python scripts/context.py
    python scripts/context.py --section appearance

Run it relative to this skill directory, or use its absolute path. Multiple --section options are supported. --all is for an explicitly broad inventory, not normal startup. It uses no network or privileged commands; output excludes raw process arguments and credential contents.

| Task | Guide | Helper section |
|---|---|---|
| Windows, tags, hotkeys, control center, cheatsheets, monitors, login/session | [desktop.md](references/desktop.md) | desktop |
| Polybar, typography, palettes, wallpaper, GTK/Qt/icons | [appearance.md](references/appearance.md) | appearance |
| Editor theme extension, browser scheme/frame | [editors-browsers.md](references/editors-browsers.md) | appearance |
| Apps, MIME defaults, terminals, shell, web/TUI launchers | [apps.md](references/apps.md) | apps |
| Keyboard/mouse, clipboard, screenshots, recording, lock | [input-capture.md](references/input-capture.md) | input |
| Packages, kernel, storage, networking, audio, power, security | [services.md](references/services.md) | services |
| Reminders, systemd timers, event-driven features, startup | [automation.md](references/automation.md) | automation |
| Source/deployment sync, build, installer, snapshot, Git | [repo.md](references/repo.md) | repo |

[Current-system.md](references/current-system.md) is a dated orientation snapshot, not a live source of truth.

## Work on the right source

- Repository: ~/dwm-jabir. Live configuration: ~/.config. Deployed helper source: ~/.local/share/dwm-titus/scripts. Resolve symlinks and inspect the target before editing.
- Edit the requested component's source, then synchronize its exact counterpart. Generated palette files are outputs, not durable customization points. The guides identify their generators.
- For a preview request, create disposable artifacts before touching live configuration. Otherwise complete the authorized edit directly. Styling preserves existing functionality and module order unless the user requests a functional change.
- Use the smallest applicable reload. A full theme apply, make install or installer run is not a routine way to apply one font/hotkey change.
- Validate runtime behavior and persistence. For UI work, inspect the live result at native scale as well as code: glyph size, baseline, spacing, clipping and click actions matter. Performance claims need evidence; an event-driven design is not a promise of zero resource usage.
- Preserve current user edits and portable installer fixes. Snapshot export and commit/push are separate tasks, performed when requested; the skill itself grants no extra execution permissions.

For an unlisted subsystem, discover its installed config/unit through the closest guide; add only new architecture facts to that guide after completing the change.

Jabir normally communicates in Bangla. Keep updates concise, explain material differences, and refresh this skill's relevant guide when a completed change alters the system's architecture.
