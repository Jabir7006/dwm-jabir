#!/usr/bin/env bash
# reminder.sh — clickable reminder module for polybar.
#
#   reminder.sh status        polybar label (also heals/reschedules timers)
#   reminder.sh add           rofi prompt: duration + message
#   reminder.sh add 10m "tea" non-interactive
#   reminder.sh manage        rofi menu: add / cancel reminders
#   reminder.sh list          plain-text list
#   reminder.sh fire UNIT     executed by the systemd timer
#
# Reminders are stored in $XDG_STATE_HOME/polybar-reminders/reminders.tsv and
# scheduled as transient systemd user timers. If a timer disappears (reboot,
# logout) the next `status` call reschedules it; reminders that came due while
# the machine was off fire as soon as polybar asks for status again.
#
# Performance notes: with no reminders the status path only does bash builtins,
# so a polybar tick costs a few ms. With reminders it adds no polling process —
# systemd wakes us at the due time. Timer liveness is re-checked at most once
# per minute (and immediately after a reboot), never on every tick.

set -uo pipefail

case ${BASH_SOURCE[0]} in
  /*) SELF=${BASH_SOURCE[0]} ;;
  *) SELF=$PWD/${BASH_SOURCE[0]} ;;
esac

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/polybar-reminders"
STORE="$STATE_DIR/reminders.tsv"
LOCK="$STATE_DIR/.lock"
HEAL_FILE="$STATE_DIR/.healed"
COLORS="${XDG_CONFIG_HOME:-$HOME/.config}/polybar/themes/minimal/colors.ini"
ICON_IDLE=$'\ue7f4'   # Material Icons: notifications
ICON_ACTIVE=$'\ue7f6' # Material Icons: notifications_active
ICON_FONT=10
if [[ ${1:-status} == status && ${2:-} == --compact ]]; then
  ICON_IDLE=$'\U000f009a'   # Nerd Font: bell
  ICON_ACTIVE=$'\U000f009e' # Nerd Font: bell-ring
  ICON_FONT=19             # Optically matched center bell
fi
ACCENT=""

# ── state locking ──────────────────────────────────────────────────────────
# The lock is only held around the state file, never while rofi is open,
# a notification is shown or a systemd unit is created.

lock_state() {
  [[ -d $STATE_DIR ]] || mkdir -p "$STATE_DIR"
  [[ -e $STORE ]] || : > "$STORE"
  exec 9>"$LOCK"
  flock -w 5 9 || exit 1
}

unlock_state() {
  exec 9>&-
}

# ── helpers ────────────────────────────────────────────────────────────────

clean_text() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//'
}

human_seconds() {
  local s=$1
  if (( s < 60 )); then
    printf '<1m'
  elif (( s < 3600 )); then
    printf '%dm' $(( s / 60 ))
  elif (( s < 86400 )); then
    printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  else
    printf '%dd %02dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
  fi
}

accent_color() {
  local key val
  ACCENT=""
  [[ -r $COLORS ]] || return 0
  while IFS='=' read -r key val; do
    key=${key//[[:space:]]/}
    [[ $key == blue ]] || continue
    ACCENT=${val//[[:space:]]/}
    return 0
  done < "$COLORS"
}

# Accepts: 45, 10m, 2h, 1.5h, 1h30m, 90 minutes, 1 day ...
# A bare number means minutes. Prints total seconds, or fails.
parse_duration() {
  local raw rest num unit mult total=0 matched=0
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  raw=$(printf '%s' "$raw" | sed -E \
    -e 's/(minutes|minute|mins|min)/m/g' \
    -e 's/(hours|hour|hrs|hr)/h/g' \
    -e 's/(seconds|second|secs|sec)/s/g' \
    -e 's/(days|day)/d/g')
  raw=${raw//[[:space:],]/}
  [[ -n $raw ]] || return 1

  rest=$raw
  while [[ -n $rest ]]; do
    if [[ $rest =~ ^([0-9]+([.][0-9]+)?)([smhd]?) ]]; then
      num=${BASH_REMATCH[1]}
      unit=${BASH_REMATCH[3]:-m}
      rest=${rest:${#BASH_REMATCH[0]}}
      case $unit in
        s) mult=1 ;;
        m) mult=60 ;;
        h) mult=3600 ;;
        d) mult=86400 ;;
      esac
      total=$(awk -v t="$total" -v n="$num" -v m="$mult" 'BEGIN { printf "%d", t + n * m }')
      matched=1
    else
      return 1
    fi
  done

  (( matched == 1 && total > 0 && total <= 31536000 )) || return 1
  printf '%d' "$total"
}

notify() {
  local urgency=$1 title=$2 body=$3
  if command -v dunstify >/dev/null 2>&1; then
    if [[ $urgency == critical ]]; then
      # timeout 0 = stays on screen until dismissed
      dunstify -a Reminder -u critical -t 0 -i appointment-soon "$title" "$body" >/dev/null 2>&1 && return 0
    else
      dunstify -a Reminder -u "$urgency" -t 4000 -i appointment-soon "$title" "$body" >/dev/null 2>&1 && return 0
    fi
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" -i appointment-soon "$title" "$body" >/dev/null 2>&1
  fi
  return 0
}

play_alert() {
  local sound=/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga
  if command -v paplay >/dev/null 2>&1 && [[ -f $sound ]]; then
    ( exec 9>&-; paplay "$sound" >/dev/null 2>&1 & )
  elif command -v canberra-gtk-play >/dev/null 2>&1; then
    ( exec 9>&-; canberra-gtk-play -i alarm-clock-elapsed >/dev/null 2>&1 & )
  fi
}

remove_unit() {
  local unit=$1
  awk -F'\t' -v u="$unit" '$1 != u' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
}

schedule_unit() {
  local unit=$1 secs=$2
  local display=${DISPLAY:-:0}
  local bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}
  local xauth=${XAUTHORITY:-$HOME/.Xauthority}

  if ! systemd-run --user --collect --quiet \
    --unit="$unit" \
    --on-active="${secs}s" \
    --timer-property=AccuracySec=1s \
    --setenv="DISPLAY=$display" \
    --setenv="DBUS_SESSION_BUS_ADDRESS=$bus" \
    --setenv="XAUTHORITY=$xauth" \
    -- "$SELF" fire "$unit" >/dev/null 2>&1; then
    # No user systemd manager: fall back to a detached sleep process.
    ( exec 9>&-; sleep "$secs"; "$SELF" fire "$unit" ) >/dev/null 2>&1 &
  fi
}

# Caller must hold the state lock.
fire_unit() {
  local unit=$1 line msg
  line=$(awk -F'\t' -v u="$unit" '$1 == u { print; exit }' "$STORE")
  [[ -n $line ]] || return 0 # already fired (status + timer raced)
  remove_unit "$unit"
  unlock_state
  msg=$(printf '%s' "$line" | cut -f3-)
  notify critical "⏰ Reminder" "${msg:-Time is up!}"
  play_alert
  lock_state
}

add_reminder() {
  local secs=$1 msg=${2:-} now epoch unit at
  msg=$(clean_text "$msg")

  lock_state
  printf -v now '%(%s)T' -1
  epoch=$(( now + secs ))
  unit="reminder-${epoch}-$RANDOM"
  printf '%s\t%s\t%s\n' "$unit" "$epoch" "$msg" >> "$STORE"
  unlock_state

  schedule_unit "$unit" "$secs"

  at=$(date -d "@$epoch" '+%H:%M')
  if [[ -n $msg ]]; then
    notify low "Reminder set" "In $(human_seconds "$secs") at $at — $msg"
  else
    notify low "Reminder set" "In $(human_seconds "$secs") at $at"
  fi
}

rofi_input() {
  local prompt=$1 placeholder=${2:-}
  # Compact single-line dmenu: no list, hint as the entry placeholder.
  rofi -dmenu -p "$prompt" </dev/null \
    -theme-str "entry { placeholder: \"$placeholder\"; } window { width: 520px; } listview { lines: 0; fixed-height: false; padding: 0px; }"
}

# ── commands ───────────────────────────────────────────────────────────────

cmd_add() {
  local input secs msg

  if (( $# >= 1 )); then
    input=$1
    if ! secs=$(parse_duration "$input"); then
      notify low "Reminder" "Could not understand “$input”. Try 10m, 2h or 1h30m."
      return 1
    fi
    msg=${2:-}
    add_reminder "$secs" "$msg"
    return 0
  fi

  while :; do
    input=$(rofi_input "⏰ Remind in" "10m · 2h · 1h30m · 45 = minutes") || return 1
    [[ -z $input ]] && return 1
    if secs=$(parse_duration "$input"); then
      break
    fi
    notify low "Reminder" "Could not understand “$input”. Try 10m, 2h or 1h30m."
  done

  msg=$(rofi_input "Message" "Optional — press Enter to skip") || return 1
  add_reminder "$secs" "$msg"
}

cmd_manage() {
  local -a units=() items=()
  local u e m now item idx confirm

  printf -v now '%(%s)T' -1

  lock_state
  while IFS=$'\t' read -r u e m; do
    [[ -n $u ]] || continue
    if (( e <= now )); then
      fire_unit "$u"
      continue
    fi
    units+=("$u")
    items+=("in $(human_seconds $(( e - now ))) — ${m:-Time is up!}")
  done < "$STORE"
  unlock_state

  items=("New reminder" "${items[@]}")
  (( ${#units[@]} > 1 )) && items+=("Cancel all reminders")

  item=$(printf '%s\n' "${items[@]}" | rofi -dmenu -format i -p "Reminders" \
    -theme-str "window { width: 560px; } listview { lines: ${#items[@]}; fixed-height: false; }") || return 1
  [[ -z $item ]] && return 1

  if (( item == 0 )); then
    cmd_add
    return
  fi
  if (( item == ${#units[@]} + 1 )); then
    cmd_cancel_all
    return
  fi

  idx=$(( item - 1 ))
  confirm=$(printf 'Keep it\nCancel it\n' | rofi -dmenu -p "Cancel reminder?" \
    -theme-str "window { width: 560px; } listview { lines: 2; fixed-height: false; }") || return 0
  if [[ $confirm == "Cancel it" ]]; then
    lock_state
    systemctl --user stop "${units[$idx]}.timer" >/dev/null 2>&1
    remove_unit "${units[$idx]}"
    unlock_state
    notify low "Reminder cancelled" "The reminder was removed."
  fi
}

cmd_cancel_all() {
  local u e m n=0
  lock_state
  while IFS=$'\t' read -r u e m; do
    [[ -n $u ]] || continue
    systemctl --user stop "$u.timer" >/dev/null 2>&1
    n=$(( n + 1 ))
  done < "$STORE"
  : > "$STORE"
  unlock_state
  notify low "Reminders cancelled" "$n reminder(s) removed."
}

cmd_list() {
  local u e m now any=0
  printf -v now '%(%s)T' -1
  lock_state
  while IFS=$'\t' read -r u e m; do
    [[ -n $u ]] || continue
    printf 'in %-8s  (%s)  %s\n' \
      "$(human_seconds $(( e - now )))" \
      "$(date -d "@$e" '+%Y-%m-%d %H:%M')" \
      "${m:-Time is up!}"
    any=1
  done < "$STORE"
  unlock_state
  (( any )) || echo "No reminders."
}

cmd_status() {
  # Fast path: no reminders → one builtin read + one printf, no forks at all.
  if [[ ! -s $STORE ]]; then
    printf '%%{T%d}%s%%{T-}' "$ICON_FONT" "$ICON_IDLE"
    return
  fi

  local u e m now soonest=0 count=0 out
  local boot_id="" last_boot="" last_heal=0 heal=0
  printf -v now '%(%s)T' -1

  lock_state
  if [[ ! -s $STORE ]]; then
    unlock_state
    printf '%%{T%d}%s%%{T-}' "$ICON_FONT" "$ICON_IDLE"
    return
  fi

  # Verify timers at most once a minute, and right after a reboot.
  read -r boot_id < /proc/sys/kernel/random/boot_id 2>/dev/null || boot_id=""
  if [[ -r $HEAL_FILE ]]; then
    read -r last_boot last_heal < "$HEAL_FILE" 2>/dev/null || true
  fi
  last_heal=${last_heal:-0}
  if [[ -z $last_boot || $boot_id != "$last_boot" ]] || (( now - last_heal >= 60 )); then
    heal=1
  fi

  while IFS=$'\t' read -r u e m; do
    [[ -n $u ]] || continue
    if (( e <= now )); then
      fire_unit "$u"
      continue
    fi
    if (( heal )) && ! systemctl --user is-active --quiet "$u.timer" 2>/dev/null; then
      schedule_unit "$u" $(( e - now ))
    fi
    count=$(( count + 1 ))
    (( soonest == 0 || e < soonest )) && soonest=$e
  done < "$STORE"

  (( heal && count > 0 )) && printf '%s %s\n' "$boot_id" "$now" > "$HEAL_FILE"
  unlock_state

  if (( count == 0 )); then
    printf '%%{T%d}%s%%{T-}' "$ICON_FONT" "$ICON_IDLE"
    return
  fi

  out="%{T${ICON_FONT}}${ICON_ACTIVE}%{T-} $(human_seconds $(( soonest - now )))"
  (( count > 1 )) && out+=" ·$count"
  accent_color
  if [[ -n $ACCENT ]]; then
    printf '%%{F%s}%s%%{F-}' "$ACCENT" "$out"
  else
    printf '%s' "$out"
  fi
}

case ${1:-status} in
  status)            cmd_status ;;
  add|new)           shift; cmd_add "$@" ;;
  manage|menu)       cmd_manage ;;
  list|ls)           cmd_list ;;
  cancel)
    shift
    lock_state
    systemctl --user stop "${1}.timer" >/dev/null 2>&1
    remove_unit "$1"
    unlock_state
    ;;
  clear|cancel-all)  cmd_cancel_all ;;
  fire)
    shift
    lock_state
    fire_unit "${1:?unit required}"
    unlock_state
    ;;
  *)
    echo "usage: $0 {status|add [duration] [message]|manage|list|cancel UNIT|clear}" >&2
    exit 2
    ;;
esac
