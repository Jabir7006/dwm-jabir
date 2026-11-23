#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  install-apps.sh — optional apps (beyond the core desktop)
#  Run:  ./install-apps.sh
#  Failed packages are listed at the end.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; NC=$'\e[0m'
info() { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; }

[[ $EUID -eq 0 ]] && { err "Do not run as root"; exit 1; }
command -v pacman >/dev/null 2>&1 || { err "pacman is missing; Arch/CachyOS is required."; exit 1; }
command -v sudo >/dev/null 2>&1 || { err "sudo is missing."; exit 1; }
sudo -v || { err "sudo authentication failed"; exit 1; }

read_list() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '{ sub(/\r$/, ""); sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") } NF' "$f"
}

SKIP_FILE="$REPO_DIR/packages/skip.txt"
is_skipped() { [[ -f "$SKIP_FILE" ]] && grep -qxF -- "$1" <(read_list "$SKIP_FILE"); }

filter_skips() {
  local p
  for p in "$@"; do
    is_skipped "$p" && { info "skip: $p" >&2; continue; }
    printf '%s\n' "$p"
  done
}

find_helper() {
  command -v paru 2>/dev/null || command -v yay 2>/dev/null || true
}

FAILED=()

# ── official ────────────────────────────────────────────────────────────
mapfile -t OFF < <(read_list "$REPO_DIR/packages/apps-official.txt")
mapfile -t OFF < <(filter_skips "${OFF[@]}")
if ((${#OFF[@]})); then
  info "official apps (${#OFF[@]})..."
  if ! sudo pacman -S --needed --noconfirm "${OFF[@]}"; then
    warn "Batch installation failed; retrying packages individually."
    for p in "${OFF[@]}"; do
      sudo pacman -S --needed --noconfirm "$p" || FAILED+=("$p")
    done
  fi
fi

# ── AUR ─────────────────────────────────────────────────────────────────
mapfile -t AUR < <(read_list "$REPO_DIR/packages/apps-aur.txt")
mapfile -t AUR < <(filter_skips "${AUR[@]}")
if ((${#AUR[@]})); then
  HELPER="$(find_helper)"
  if [[ -z "$HELPER" ]]; then
    err "paru/yay is missing; run ./install.sh first to install an AUR helper."
    exit 1
  fi
  info "AUR apps (${#AUR[@]}) via $HELPER..."
  if ! "$HELPER" -S --needed --noconfirm "${AUR[@]}"; then
    warn "Batch installation failed; retrying packages individually."
    for p in "${AUR[@]}"; do
      "$HELPER" -S --needed --noconfirm "$p" || FAILED+=("$p")
    done
  fi
fi

echo ""
if ((${#FAILED[@]})); then
  warn "These packages were not installed:"
  printf '  - %s\n' "${FAILED[@]}"
  echo ""
  echo "Possible causes: renamed packages, missing repositories, or missing build dependencies."
  exit 1
fi
ok "All optional apps are installed."
