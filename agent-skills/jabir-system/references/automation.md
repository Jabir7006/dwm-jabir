# Features, startup and automation

Prefer the existing mechanism that fits the feature:

- Static bar control: custom/text plus a click action; no polling script.
- Event-backed state: existing custom/ipc hooks or an event-driven custom/script tail.
- Scheduled work: systemd user services/timers, with a defined stop/cancel path.
- Session startup: deployed autostart.sh or a single XDG autostart desktop entry, after checking existing service ownership.
- Theme-dependent output: the relevant generator in theme-apply.sh, rather than editing its generated file.

Read the current helper before copying a pattern; a --help or status action is not necessarily read-only in a custom script. The Onboard toggle owns its theme/layout generation and exact process matching; avoid broad pkill patterns that can match their own shell. Generated artifacts should survive app/module reloads and follow the selected theme.

Reminders live in Polybar themes/minimal/reminder.sh, with state under XDG_STATE_HOME/polybar-reminders. It uses systemd timers for wakeups and a 30-second UI refresh. status can heal timers/fire overdue entries; the context helper never invokes it. status --compact changes only icon presentation. Preserve add/manage/cancel behavior, delayed timer cleanup and the cheap no-reminder path.

User units live in ~/.config/systemd/user (repository source config/systemd/user). Check systemctl --user list-timers before adding one. The existing portproton-patch.timer runs on boot after 5 min and every 6 h with a randomized delay; its service runs ~/.local/share/portproton-patch/install.sh, while the PortProton desktop entry is the event-driven launch path. Do not replace that hook with a daemon.

Theme apply has an inherited lock descriptor. Background children must not retain it; the existing script closes fd 9 for relevant children. Test an added theme hook against that locking model and avoid recursive theme-trigger loops.

For a new feature, define trigger, state owner, live control, persistence, dependencies and shutdown behavior. Test the user-visible path and cleanup; reuse current programs instead of adding duplicate background loops. Do not publish/send data externally or schedule future work merely because a helper is available.
