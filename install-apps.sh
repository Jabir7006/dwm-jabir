#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  install-apps.sh — optional apps (core-এর বাইরে)
#  চালান:  ./install-apps.sh
#  ব্যর্থ প্যাকেজগুলো শেষে তালিকা করে দেবে।
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; NC=$'\e[0m'
info() { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; }

[[ $EUID -eq 0 ]] && { err "root হিসেবে চালাবেন না"; exit 1; }
command -v pacman >/dev/null 2>&1 || { err "pacman নেই — Arch/CachyOS লাগবে"; exit 1; }

read_list() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

SKIP_FILE="$REPO_DIR/packages/skip.txt"
is_skipped() { [[ -f "$SKIP_FILE" ]] && grep -qxF -- "$1" <(read_list "$SKIP_FILE"); }

filter_skips() {
  local p
  for p in "$@"; do
    is_skipped "$p" && { info "skip: $p"; continue; }
    printf '%s\n' "$p"
  done
}

find_helper() {
  command -v paru 2>/dev/null || command -v yay 2>/dev/null || true
}

FAILED=()

# ── official ────────────────────────────────────────────────────────────
mapfile -t OFF < <(filter_skips $(read_list "$REPO_DIR/packages/apps-official.txt"))
if ((${#OFF[@]})); then
  info "official apps (${#OFF[@]})..."
  if ! sudo pacman -S --needed --noconfirm "${OFF[@]}"; then
    warn "batch install ব্যর্থ — একটা একটা করে চেষ্টা করছি"
    for p in "${OFF[@]}"; do
      sudo pacman -S --needed --noconfirm "$p" || FAILED+=("$p")
    done
  fi
fi

# ── AUR ─────────────────────────────────────────────────────────────────
mapfile -t AUR < <(filter_skips $(read_list "$REPO_DIR/packages/apps-aur.txt"))
if ((${#AUR[@]})); then
  HELPER="$(find_helper)"
  if [[ -z "$HELPER" ]]; then
    err "paru/yay নেই — আগে ./install.sh চালান (helper install হবে)"
    exit 1
  fi
  info "AUR apps (${#AUR[@]}) via $HELPER..."
  if ! "$HELPER" -S --needed --noconfirm "${AUR[@]}"; then
    warn "batch install ব্যর্থ — একটা একটা করে চেষ্টা করছি"
    for p in "${AUR[@]}"; do
      "$HELPER" -S --needed --noconfirm "$p" || FAILED+=("$p")
    done
  fi
fi

echo ""
if ((${#FAILED[@]})); then
  warn "এই প্যাকেজগুলো install হয়নি:"
  printf '  - %s\n' "${FAILED[@]}"
  echo ""
  echo "কারণ হতে পারে: প্যাকেজ নাম বদলেছে, repo নেই, বা build dependency missing।"
  exit 1
fi
ok "সব optional app install হয়েছে।"
