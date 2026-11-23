#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  dwm-jabir installer
#  minimal Arch / CachyOS → preconfigured DWM desktop
#
#  ব্যবহার:
#    ./install.sh                 # core install (prompt সহ)
#    ./install.sh --with-apps     # core + আপনার সব অ্যাপ
#    ./install.sh --no-deps       # package install বাদ, শুধু config/dwm
#    ./install.sh -y              # সব prompt-এ default উত্তর
# ═══════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
  RED=; GREEN=; YELLOW=; CYAN=; BOLD=; NC=
fi
info() { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 's=$?; err "ব্যর্থ (line $LINENO, exit $s): $BASH_COMMAND"; exit $s' ERR

WITH_APPS=0
NO_DEPS=0
ASSUME_YES=0
DEPLOY_ONLY=0
USER_NAME="$(id -un)"

usage() {
  cat <<'EOF'
dwm-jabir installer

  ./install.sh                core install (prompt সহ)
  ./install.sh --with-apps    core + optional apps (install-apps.sh)
  ./install.sh --no-deps      package install বাদ, শুধু config + dwm
  ./install.sh --deploy-only  শুধু config/script deploy (build/system বাদ)
  ./install.sh -y             সব prompt-এ default উত্তর
  ./install.sh -h             এই help

Core package list:  packages/core-official.txt + packages/core-aur.txt
Optional apps:      packages/apps-official.txt + packages/apps-aur.txt
বাদ দিতে:           packages/skip.txt
EOF
}

while (($#)); do
  case "$1" in
    --with-apps) WITH_APPS=1 ;;
    --no-deps)   NO_DEPS=1 ;;
    --deploy-only) DEPLOY_ONLY=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "অজানা option: $1 (--help দেখুন)" ;;
  esac
  shift
done

# ── basic checks ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "root হিসেবে চালাবেন না। আপনার নিজের user দিয়ে চালান — স্ক্রিপ্ট নিজেই sudo ব্যবহার করবে।"
command -v pacman >/dev/null 2>&1 || die "pacman পাওয়া যায়নি — এটা Arch/CachyOS-এর জন্য।"
command -v sudo   >/dev/null 2>&1 || die "sudo নেই। আগে root হয়ে 'pacman -S sudo' + 'visudo' করুন।"

DISTRO_ID="arch"
DISTRO_NAME="Arch Linux"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-arch}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
fi

info "System: $DISTRO_NAME"
info "User:   $USER_NAME"
info "Repo:   $REPO_DIR"

# sudo একবার prompt করুক
sudo -v || die "sudo ব্যর্থ"

ask_yes_no() {
  local prompt="$1" default="${2:-n}" ans hint
  if ((ASSUME_YES)); then
    [[ "$default" == "y" ]]
    return
  fi
  hint="[y/N]"; [[ "$default" == "y" ]] && hint="[Y/n]"
  read -rp "$prompt $hint " ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

read_list() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

SKIP_FILE="$REPO_DIR/packages/skip.txt"
is_skipped() {
  [[ -f "$SKIP_FILE" ]] && grep -qxF -- "$1" <(read_list "$SKIP_FILE")
}

PAC_FAILED=()
AUR_FAILED=()

pac_install() {
  local -a pkgs=()
  local p
  for p in "$@"; do
    if is_skipped "$p"; then info "skip: $p"; continue; fi
    pkgs+=("$p")
  done
  ((${#pkgs[@]})) || return 0
  info "pacman: ${pkgs[*]}"
  if sudo pacman -S --needed --noconfirm "${pkgs[@]}"; then
    return 0
  fi
  warn "batch install ব্যর্থ — একটা একটা করে চেষ্টা করছি"
  for p in "${pkgs[@]}"; do
    sudo pacman -S --needed --noconfirm "$p" || PAC_FAILED+=("$p")
  done
  return 0
}

# ── AUR helper ──────────────────────────────────────────────────────────
HELPER=""

build_aur_pkg() {
  local pkg="$1" bin="$2" tmp
  tmp="$(mktemp -d)"
  info "AUR build: $pkg"
  git clone --depth=1 "https://aur.archlinux.org/${pkg}.git" "$tmp/$pkg" >/dev/null
  ( cd "$tmp/$pkg" && makepkg -si --noconfirm )
  rm -rf "$tmp"
  command -v "$bin" >/dev/null 2>&1 || die "$bin build ব্যর্থ"
}

ensure_helper() {
  HELPER=""
  if command -v paru >/dev/null 2>&1; then HELPER=paru; return 0; fi
  if command -v yay  >/dev/null 2>&1; then HELPER=yay;  return 0; fi

  local choice="paru"
  if ((!ASSUME_YES)); then
    echo ""
    echo "AUR helper পাওয়া যায়নি — কোনটা install করবেন?"
    echo "  1) paru      (recommended)"
    echo "  2) yay-bin"
    local ans
    read -rp "Choose [1/2, default 1]: " ans || true
    [[ "$ans" == "2" ]] && choice="yay-bin"
  fi
  if [[ "$choice" == "yay-bin" ]]; then
    build_aur_pkg yay-bin yay
    HELPER=yay
  else
    build_aur_pkg paru-bin paru
    HELPER=paru
  fi
  command -v "$HELPER" >/dev/null 2>&1 || die "AUR helper install ব্যর্থ"
}

aur_install() {
  local helper="$1"; shift
  local -a pkgs=()
  local p
  for p in "$@"; do
    if is_skipped "$p"; then info "skip: $p"; continue; fi
    pkgs+=("$p")
  done
  ((${#pkgs[@]})) || return 0
  info "$helper: ${pkgs[*]}"
  if "$helper" -S --needed --noconfirm "${pkgs[@]}"; then
    return 0
  fi
  warn "batch install ব্যর্থ — একটা একটা করে চেষ্টা করছি"
  for p in "${pkgs[@]}"; do
    "$helper" -S --needed --noconfirm "$p" || AUR_FAILED+=("$p")
  done
  return 0
}

# ── repo helpers ────────────────────────────────────────────────────────
add_pacman_repo() {
  local name="$1" server="$2"
  if grep -qE "^\[${name}\]" /etc/pacman.conf; then return 0; fi
  info "pacman repo যোগ: [$name]"
  printf '\n[%s]\nServer = %s\n' "$name" "$server" | sudo tee -a /etc/pacman.conf >/dev/null || return 1
  sudo pacman -Sy || return 1
}

# ── firmware / microcode ────────────────────────────────────────────────
setup_firmware() {
  if pacman -Qq linux-firmware >/dev/null 2>&1 || pacman -Qq linux-firmware-whence >/dev/null 2>&1; then
    return 0
  fi
  info "firmware install (linux-firmware)"
  pac_install linux-firmware
}

setup_microcode() {
  local vendor pkg=""
  vendor="$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}' || true)"
  case "$vendor" in
    GenuineIntel) pkg=intel-ucode ;;
    AuthenticAMD) pkg=amd-ucode ;;
    *) return 0 ;;
  esac
  pacman -Qq "$pkg" >/dev/null 2>&1 || { info "microcode: $pkg"; pac_install "$pkg"; }
}

# ── X server ────────────────────────────────────────────────────────────
setup_xserver() {
  if pacman -Qq xlibre-meta >/dev/null 2>&1; then ok "xlibre already installed"; return; fi
  if pacman -Qq xorg-server >/dev/null 2>&1; then ok "xorg-server already installed"; return; fi

  local use_xlibre=1
  if ((!ASSUME_YES)); then
    if ! ask_yes_no "Xlibre (আপনার এখনকার X server) ব্যবহার করবেন? না বললে xorg-server" y; then
      use_xlibre=0
    fi
  fi

  if ((use_xlibre)); then
    if ! pacman -Sl xlibre-stable >/dev/null 2>&1; then
      if ask_yes_no "xlibre repo (/etc/pacman.conf) যোগ করব?" y; then
        add_pacman_repo xlibre-stable 'https://packages.xlibre.net/arch/stable/$arch' \
          || warn "xlibre repo add/sync ব্যর্থ"
      fi
    fi
    pac_install xlibre-meta
    if ! pacman -Qq xlibre-meta >/dev/null 2>&1 && ! pacman -Qq xorg-server >/dev/null 2>&1; then
      warn "xlibre install হয়নি — xorg-server দিয়ে চালাচ্ছি"
      pac_install xorg-server
    fi
  else
    pac_install xorg-server
  fi
}

# ── CachyOS kernel ──────────────────────────────────────────────────────
setup_kernel() {
  if [[ "$DISTRO_ID" == "cachyos" ]]; then
    ok "CachyOS system — kernel আগেই CachyOS"
    return
  fi
  if ! ask_yes_no "CachyOS kernel (linux-cachyos) install করবেন? (plain Arch-এ repo/keyring দরকার)" n; then
    info "kernel: default linux থাকবে"
    return
  fi

  if ! pacman -Sl cachyos >/dev/null 2>&1; then
    info "CachyOS repo যোগ করা হচ্ছে..."
    if ! add_pacman_repo cachyos 'https://mirror.cachyos.org/repo/x86_64/cachyos'; then
      warn "CachyOS repo add ব্যর্থ — kernel install বাদ"
      return
    fi
    sudo pacman -S --needed --noconfirm cachyos-keyring cachyos-mirrorlist 2>/dev/null \
      || warn "cachyos-keyring install ব্যর্থ — signature error হলে ম্যানুয়ালি keyring লাগবে"
  fi

  if ! pac_install linux-cachyos linux-cachyos-headers; then
    warn "CachyOS kernel install ব্যর্থ। CachyOS ISO দিয়ে install করলে এটা লাগবে না।"
    return
  fi
  if ! pacman -Qq linux-cachyos >/dev/null 2>&1; then
    warn "linux-cachyos install হয়নি"
    return
  fi
  command -v mkinitcpio >/dev/null 2>&1 && { sudo mkinitcpio -P || warn "mkinitcpio -P ব্যর্থ"; }
  if [[ -d /boot/loader ]]; then
    sudo bootctl update 2>/dev/null || true
  elif [[ -f /boot/grub/grub.cfg ]]; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub-mkconfig ব্যর্থ"
  fi
  ok "CachyOS kernel installed — reboot করে boot entry দেখুন"
}

# ── network / DM / shell ────────────────────────────────────────────────
setup_network() {
  sudo systemctl enable NetworkManager 2>/dev/null || true
  sudo systemctl start  NetworkManager 2>/dev/null || true
}

handle_dm_conflict() {
  local dm
  for dm in gdm sddm; do
    if systemctl is-enabled "$dm" >/dev/null 2>&1; then
      warn "$dm enabled — LightDM-এর সাথে conflict করবে"
      if ask_yes_no "$dm disable করে LightDM enable করব?" y; then
        sudo systemctl disable "$dm" || warn "$dm disable ব্যর্থ"
      else
        warn "দুটো DM একসাথে চললে login সমস্যা হতে পারে"
      fi
    fi
  done
}

setup_shell() {
  local cur
  cur="$(getent passwd "$USER_NAME" | cut -d: -f7)"
  if [[ "$cur" != "/usr/bin/fish" ]]; then
    if ask_yes_no "fish কে default shell করব?" y; then
      chsh -s /usr/bin/fish "$USER_NAME" || warn "chsh ব্যর্থ — পরে নিজে 'chsh -s /usr/bin/fish' চালান"
    fi
  fi
}

# ── backup + deploy ─────────────────────────────────────────────────────
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

backup_path() {
  local p="$1" rel
  [[ -e "$p" ]] || return 0
  rel="${p#"$HOME"/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -a "$p" "$BACKUP_DIR/$rel" 2>/dev/null || true
}

deploy_file() {
  local src="$1" dst="$2" mode="${3:-644}"
  [[ -f "$src" ]] || return 0
  backup_path "$dst"
  install -Dm"$mode" "$src" "$dst"
}

deploy_file_sed() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  backup_path "$dst"
  mkdir -p "$(dirname "$dst")"
  sed "s|/home/jabir|$HOME|g" "$src" > "$dst"
  chmod 644 "$dst"
}

sync_dir() {
  local src="$1" dst="$2" sub="${3:-}"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    if [[ -n "$sub" ]]; then
      rsync -a --backup --backup-dir="$BACKUP_DIR/$sub" "$src" "$dst"
    else
      rsync -a "$src" "$dst"
    fi
  else
    cp -a "$src". "$dst"/
  fi
}

deploy_home() {
  info "home dotfiles deploy..."
  local f
  for f in .xprofile .profile .bash_profile .bashrc .zshrc .gtkrc-2.0 picom.conf; do
    deploy_file "$REPO_DIR/home/$f" "$HOME/$f" 644
  done

  mkdir -p "$HOME/.local/bin"
  for f in "$REPO_DIR"/home/.local/bin/*; do
    [[ -f "$f" ]] || continue
    deploy_file "$f" "$HOME/.local/bin/$(basename "$f")" 755
  done

  mkdir -p "$HOME/custom-scripts" "$HOME/user_scripts"
  sync_dir "$REPO_DIR/home/custom-scripts/" "$HOME/custom-scripts/" custom-scripts
  sync_dir "$REPO_DIR/home/user_scripts/" "$HOME/user_scripts/" user_scripts

  ln -sfn "$HOME/.local/share/dwm-titus/scripts/theme-apply.sh" "$HOME/.local/bin/theme-apply.sh"
  ln -sfn "$HOME/user_scripts/wayclick/wayclick-toggle.sh" "$HOME/.local/bin/wayclick"
  [[ -x "$HOME/.t3/bin/t3" ]] && ln -sfn "$HOME/.t3/bin/t3" "$HOME/.local/bin/t3"
  [[ -x "$HOME/.local/share/numes/current/numes" ]] && \
    ln -sfn "$HOME/.local/share/numes/current/numes" "$HOME/.local/bin/numes"

  chmod +x "$HOME"/custom-scripts/* "$HOME"/user_scripts/wayclick/*.sh 2>/dev/null || true
}

deploy_config_extras() {  info "top-level config files deploy..."
  local f
  for f in starship.toml mimeapps.list user-dirs.dirs xdg-terminals.list; do
    deploy_file "$REPO_DIR/config/$f" "$HOME/.config/$f" 644
  done
}

deploy_applications() {
  info "custom .desktop files deploy..."
  mkdir -p "$HOME/.local/share/applications"
  local f
  for f in "$REPO_DIR"/applications/*.desktop; do
    [[ -f "$f" ]] || continue
    deploy_file_sed "$f" "$HOME/.local/share/applications/$(basename "$f")"
  done
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
}

deploy_fonts() {
  [[ -d "$REPO_DIR/fonts" ]] || return 0
  info "fonts deploy..."
  sync_dir "$REPO_DIR/fonts/" "$HOME/.local/share/fonts/"
  command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true
}

deploy_wallpapers() {
  [[ -d "$REPO_DIR/wallpapers" ]] || return 0
  info "wallpapers deploy..."
  sync_dir "$REPO_DIR/wallpapers/" "$HOME/Pictures/backgrounds/"
  local first
  first="$(find "$HOME/Pictures/backgrounds" -maxdepth 1 -type f | sort | head -1 || true)"
  if [[ -n "$first" ]]; then
    backup_path "$HOME/.fehbg"
    printf '#!/bin/sh\nfeh --no-fehbg --bg-fill %q\n' "$first" > "$HOME/.fehbg"
    chmod +x "$HOME/.fehbg"
  fi
}

deploy_systemd_masks() {
  info "systemd user portal masks..."
  systemctl --user mask at-spi-dbus-bus.service 2>/dev/null || true
  systemctl --user mask xdg-desktop-portal-kde.service 2>/dev/null || true
  systemctl --user mask xdg-desktop-portal-wlr.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

fix_home_paths() {
  [[ "$HOME" == "/home/jabir" ]] && return 0
  info "path fix: /home/jabir → $HOME"
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] && sed -i "s|/home/jabir|$HOME|g" "$f"
  done < <(grep -rIl '/home/jabir' "$HOME/.config" "$HOME/.local/share/applications" 2>/dev/null || true)
}

# ── build + lightdm ─────────────────────────────────────────────────────
deploy_config_dirs() {
  local d b
  for d in "$REPO_DIR"/config/*/; do
    [[ -d "$d" ]] || continue
    b="$(basename "$d")"
    sync_dir "$d" "$HOME/.config/$b/" "config-$b"
  done
}

build_dwm() {
  command -v make >/dev/null 2>&1 || die "make নেই — base-devel install হয়নি"
  command -v cc   >/dev/null 2>&1 || die "C compiler নেই — base-devel install হয়নি"
  info "dwm build + install (sudo)..."
  if ! sudo make -C "$REPO_DIR" clean install; then
    die "dwm build/install ব্যর্থ — উপরের error দেখুন"
  fi
}

setup_lightdm() {
  info "LightDM config..."
  handle_dm_conflict
  if [[ -f "$REPO_DIR/lightdm/Makefile" ]]; then
    sudo make -C "$REPO_DIR/lightdm" install || warn "LightDM config install ব্যর্থ"
  fi
  sudo systemctl enable lightdm 2>/dev/null || warn "lightdm enable ব্যর্থ"
}

# ── system tuning (ask) ─────────────────────────────────────────────────
detect_gpu() {
  if command -v lspci >/dev/null 2>&1; then
    local v
    v="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
    case "$v" in
      *NVIDIA*|*nvidia*) echo nvidia ;;
      *AMD*|*amd*|*Radeon*) echo amd ;;
      *Intel*|*intel*) echo intel ;;
      *) echo unknown ;;
    esac
  else
    echo unknown
  fi
}

setup_system_config() {
  local etc="$REPO_DIR/system-config/etc"

  if [[ -f "$etc/X11/xorg.conf.d/30-pointer-touchpad.conf" ]]; then
    if ask_yes_no "Touchpad config (tapping, natural scroll, left-handed mouse) ব্যবহার করবেন?" n; then
      sudo install -Dm644 "$etc/X11/xorg.conf.d/30-pointer-touchpad.conf" \
        /etc/X11/xorg.conf.d/30-pointer-touchpad.conf
      ok "touchpad config installed"
    fi
  fi

  if [[ -f "$etc/keyd/default.conf" ]]; then
    if ask_yes_no "keyd keyboard remap (আপনার custom layout) ব্যবহার করবেন?" n; then
      pac_install keyd
      if pacman -Qq keyd >/dev/null 2>&1; then
        sudo install -Dm644 "$etc/keyd/default.conf" /etc/keyd/default.conf
        sudo systemctl enable --now keyd 2>/dev/null || warn "keyd service enable ব্যর্থ"
        ok "keyd config installed"
      else
        warn "keyd install হয়নি — config বাদ"
      fi
    fi
  fi

  if ask_yes_no "System tuning (sysctl, zram, udev, i915/tearfree) ব্যবহার করবেন?" n; then
    local f
    for f in "$etc"/sysctl.d/*.conf; do
      [[ -f "$f" ]] || continue
      sudo install -Dm644 "$f" "/etc/sysctl.d/$(basename "$f")"
    done
    for f in "$etc"/udev/rules.d/*.rules; do
      [[ -f "$f" ]] || continue
      sudo install -Dm644 "$f" "/etc/udev/rules.d/$(basename "$f")"
    done
    if [[ -f "$etc/systemd/zram-generator.conf" ]]; then
      sudo install -Dm644 "$etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
    fi
    sudo sysctl --system >/dev/null 2>&1 || true
    sudo udevadm control --reload-rules 2>/dev/null || true

    local gpu; gpu="$(detect_gpu)"
    if [[ "$gpu" == "intel" ]]; then
      [[ -f "$etc/modprobe.d/i915.conf" ]] && \
        sudo install -Dm644 "$etc/modprobe.d/i915.conf" /etc/modprobe.d/i915.conf
      [[ -f "$etc/X11/xorg.conf.d/20-tearfree.conf" ]] && \
        sudo install -Dm644 "$etc/X11/xorg.conf.d/20-tearfree.conf" /etc/X11/xorg.conf.d/20-tearfree.conf
      ok "Intel tuning installed"
    else
      info "GPU=$gpu — i915/tearfree বাদ"
    fi
  fi
}

check_critical() {
  local p missing=()
  for p in make gcc libx11 libxft libxinerama imlib2 polybar rofi lightdm lightdm-slick-greeter; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    die "critical package missing: ${missing[*]} — উপরের error দেখুন"
  fi
}

# ── main ────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║        dwm-jabir installer  (Arch)            ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

if ((DEPLOY_ONLY)); then
  warn "--deploy-only: package install + dwm build + system config বাদ"
elif ((NO_DEPS)); then
  warn "--no-deps: package install বাদ"
else
  if ask_yes_no "সিস্টেম update (pacman -Syu) করব?" y; then
    sudo pacman -Syu --noconfirm || warn "pacman -Syu ব্যর্থ — চলমান database দিয়ে চেষ্টা"
  fi

  setup_firmware
  setup_microcode
  setup_xserver

  mapfile -t CORE_OFF < <(read_list "$REPO_DIR/packages/core-official.txt")
  pac_install "${CORE_OFF[@]}"

  mapfile -t CORE_AUR < <(read_list "$REPO_DIR/packages/core-aur.txt")
  if ((${#CORE_AUR[@]})); then
    ensure_helper
    aur_install "$HELPER" "${CORE_AUR[@]}"
  fi

  setup_kernel
  setup_network
  check_critical
fi

info "config backup → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for d in "$REPO_DIR"/config/*/; do
  [[ -d "$d" ]] || continue
  backup_path "$HOME/.config/$(basename "$d")"
done
backup_path "$HOME/.config/starship.toml"
backup_path "$HOME/.config/mimeapps.list"

if ((DEPLOY_ONLY)); then
  deploy_config_dirs
else
  build_dwm
fi
deploy_config_extras
deploy_home
deploy_applications
deploy_fonts
deploy_wallpapers
fix_home_paths
if ((!DEPLOY_ONLY)); then
  setup_lightdm
  setup_system_config
fi
deploy_systemd_masks
((NO_DEPS || DEPLOY_ONLY)) || setup_shell

if [[ -x "$REPO_DIR/scripts/theme-apply.sh" ]]; then
  if ask_yes_no "থিম এখনই apply করব? (rofi/polybar/gtk/qt colors generate)" y; then
    "$REPO_DIR/scripts/theme-apply.sh" >/dev/null 2>&1 || warn "theme-apply ব্যর্থ — পরে নিজে চালান"
    ok "theme applied"
  fi
fi

if ((WITH_APPS)); then
  info "optional apps install..."
  "$REPO_DIR/install-apps.sh" || warn "install-apps.sh কিছু প্যাকেজে ব্যর্থ"
fi

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║          Installation Complete!               ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
if ((DEPLOY_ONLY)); then
  ok "config deployed (dwm build বাদ)।"
else
  ok "dwm installed. Logout → 'dwm' session নির্বাচন করুন (অথবা startx)।"
fi
echo ""
echo "  পরের ধাপ:"
echo "   1. ./setup-secrets.sh      → API token বসান (GitHub-এ নেই)"
echo "   2. logout → LightDM-এ dwm  → login"
echo "   3. চেক: polybar, rofi (SUPER+R), wallpaper, alacritty"
echo ""
echo "  Backup of old configs: $BACKUP_DIR"
if ((${#PAC_FAILED[@]})); then
  echo ""
  warn "install হয়নি (official): ${PAC_FAILED[*]}"
fi
if ((${#AUR_FAILED[@]})); then
  warn "install হয়নি (AUR): ${AUR_FAILED[*]}"
fi
echo ""
