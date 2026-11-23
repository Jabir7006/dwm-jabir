#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  dwm-jabir installer
#  minimal Arch / CachyOS → preconfigured DWM desktop
#
#  Usage:
#    ./install.sh                 # core install (interactive)
#    ./install.sh --with-apps     # core + optional apps
#    ./install.sh --no-deps       # skip packages, deploy config/dwm only
#    ./install.sh -y              # use the default answer for every prompt
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

trap 's=$?; err "Failed (line $LINENO, exit $s): $BASH_COMMAND"; exit $s' ERR

WITH_APPS=0
NO_DEPS=0
ASSUME_YES=0
DEPLOY_ONLY=0
USER_NAME="$(id -un)"
USER_GROUP="$(id -gn)"
USE_CACHYOS=0
XSERVER="xorg"
REPOS_CHANGED=0
PACMAN_CONF=/etc/pacman.conf

usage() {
  cat <<'EOF'
dwm-jabir installer

  ./install.sh                core install (interactive)
  ./install.sh --with-apps    core + optional apps (install-apps.sh)
  ./install.sh --no-deps      skip packages, deploy config + build dwm
  ./install.sh --deploy-only  deploy config/scripts only (skip build/system changes)
  ./install.sh -y             use the default answer for every prompt
  ./install.sh -h             show this help

Core package list:  packages/core-official.txt + packages/core-aur.txt
Optional apps:      packages/apps-official.txt + packages/apps-aur.txt
Skip packages:      packages/skip.txt
EOF
}

while (($#)); do
  case "$1" in
    --with-apps) WITH_APPS=1 ;;
    --no-deps)   NO_DEPS=1 ;;
    --deploy-only) DEPLOY_ONLY=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ── basic checks ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Do not run as root. Run as your own user; the installer uses sudo when needed."
command -v pacman >/dev/null 2>&1 || die "pacman was not found; this installer requires Arch/CachyOS."
command -v sudo   >/dev/null 2>&1 || die "sudo is missing. As root, install sudo with pacman and configure access with visudo."

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

# Authenticate sudo once
sudo -v || die "sudo authentication failed"

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
  warn "Batch installation failed; retrying packages individually."
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
  command -v "$bin" >/dev/null 2>&1 || die "$bin build failed"
}

ensure_helper() {
  HELPER=""
  if command -v paru >/dev/null 2>&1; then HELPER=paru; return 0; fi
  if command -v yay  >/dev/null 2>&1; then HELPER=yay;  return 0; fi

  local choice="paru"
  if ((!ASSUME_YES)); then
    echo ""
    echo "No AUR helper found. Which one should be installed?"
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
  command -v "$HELPER" >/dev/null 2>&1 || die "AUR helper installation failed"
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
  warn "Batch installation failed; retrying packages individually."
  for p in "${pkgs[@]}"; do
    "$helper" -S --needed --noconfirm "$p" || AUR_FAILED+=("$p")
  done
  return 0
}

# ── repository preparation (before any desktop packages) ────────────────
select_kernel() {
  local default=n
  [[ "$DISTRO_ID" == "cachyos" ]] && default=y
  if ask_yes_no "Install CachyOS kernel and prioritize CPU-optimized CachyOS repositories?" "$default"; then
    [[ "$(uname -m)" == "x86_64" ]] || die "CachyOS repositories require x86_64."
    USE_CACHYOS=1
  else
    info "Keeping the current kernel and repository choices."
  fi
}

select_xserver() {
  # Keep an existing server by default; new installations default to Xorg.
  if pacman -Qq xlibre-xserver >/dev/null 2>&1; then
    XSERVER=xlibre
    info "Keeping the installed XLibre server."
  elif ask_yes_no "Use XLibre instead of Xorg?" n; then
    XSERVER=xlibre
  fi
}

setup_xlibre_repo() {
  local tmp fingerprint=0C92313001CFCA27627B9098B97F7C613F359424
  command -v curl >/dev/null 2>&1 || die "curl is required to download the XLibre signing key."
  tmp="$(mktemp -d)"
  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
      https://packages.xlibre.net/arch/xlibre-archlinux.asc -o "$tmp/xlibre.asc"; then
    rm -rf "$tmp"
    die "Could not download the XLibre signing key."
  fi
  # Signing by the full fingerprint also rejects an unexpected downloaded key.
  if ! sudo pacman-key --init || ! sudo pacman-key --add "$tmp/xlibre.asc" || \
      ! sudo pacman-key --lsign-key "$fingerprint"; then
    rm -rf "$tmp"
    die "Could not trust the XLibre signing key."
  fi
  rm -rf "$tmp"
  if ! grep -qE '^\[xlibre-stable\][[:space:]]*$' "$PACMAN_CONF"; then
    sudo cp -a "$PACMAN_CONF" "$PACMAN_CONF.dwm-backup-$(date +%Y%m%d-%H%M%S)"
    printf '\n[xlibre-stable]\nSigLevel = Required DatabaseOptional\nServer = https://packages.xlibre.net/arch/stable/$arch\n' \
      | sudo tee -a "$PACMAN_CONF" >/dev/null
  fi
  REPOS_CHANGED=1
}

setup_cachyos_repos() {
  local tmp level="" mirror fingerprint=882DCFE48E2051D48E2562ABF3B607488DB35A47
  info "Preparing CachyOS signing keys and optimized repositories..."
  sudo pacman-key --init
  sudo pacman-key --populate archlinux
  sudo pacman-key --recv-keys "$fingerprint" --keyserver hkps://keyserver.ubuntu.com \
    || die "Could not import the CachyOS signing key. Check your connection and system clock."
  sudo pacman-key --lsign-key "$fingerprint" \
    || die "Could not trust the CachyOS signing key."

  # Bootstrap only the signed keyring/mirrorlists, even if a previous run left
  # broken third-party repositories in pacman.conf. No hardcoded package versions.
  tmp="$(mktemp -d)"
  awk '/^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\[options\]/ { exit } { print }' \
    "$PACMAN_CONF" > "$tmp/pacman.conf"
  printf '\n[cachyos]\nSigLevel = Required DatabaseOptional\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >> "$tmp/pacman.conf"
  if ! sudo pacman --config "$tmp/pacman.conf" -Sy --needed --noconfirm \
      cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist; then
    rm -rf "$tmp"
    die "CachyOS keyring/mirrorlist installation failed; desktop packages have not been installed."
  fi
  sudo pacman-key --populate cachyos

  # The loader checks both CPU and OS support for the instruction set.
  if /lib/ld-linux-x86-64.so.2 --help | grep -F 'x86-64-v4 (supported, searched)' >/dev/null; then
    level=v4
    if command -v gcc >/dev/null 2>&1 && \
        gcc -march=native -Q --help=target 2>/dev/null | grep -E '^[[:space:]]*-march=[[:space:]]+znver[45][[:space:]]*$' >/dev/null; then
      level=znver4
    fi
  elif /lib/ld-linux-x86-64.so.2 --help | grep -F 'x86-64-v3 (supported, searched)' >/dev/null; then
    level=v3
  fi
  mirror="${level:-generic}"
  info "CachyOS repository optimization: $mirror"
  : > "$tmp/repos.conf"
  if [[ -n "$level" ]]; then
    mirror=v3; [[ "$level" == v4 || "$level" == znver4 ]] && mirror=v4
    printf '[cachyos-%s]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$mirror" >> "$tmp/repos.conf"
    printf '[cachyos-core-%s]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$mirror" >> "$tmp/repos.conf"
    printf '[cachyos-extra-%s]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$mirror" >> "$tmp/repos.conf"
  fi
  printf '[cachyos]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n' >> "$tmp/repos.conf"
  # Replace stable CachyOS sections and place them BEFORE Arch repositories.
  # Keep separately configured testing/custom repositories intact.
  awk -v repos="$tmp/repos.conf" '
    /^[[:space:]]*\[/ {
      skip = ($0 ~ /^[[:space:]]*\[(cachyos|cachyos(-core|-extra)?-(v3|v4|znver4))\]/)
      if (!inserted && $0 !~ /^[[:space:]]*\[options\]/) {
        while ((getline line < repos) > 0) print line
        close(repos); inserted = 1
      }
    }
    !skip { print }
    END { if (!inserted) while ((getline line < repos) > 0) print line }
  ' "$PACMAN_CONF" > "$tmp/updated.conf"
  sudo cp -a "$PACMAN_CONF" "$PACMAN_CONF.dwm-backup-$(date +%Y%m%d-%H%M%S)"
  sudo install -m644 "$tmp/updated.conf" "$PACMAN_CONF"
  rm -rf "$tmp"
  REPOS_CHANGED=1
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
  local -a flags=(-S --needed --noconfirm)
  if [[ "$XSERVER" == xlibre ]]; then
    if pacman -Qq xorg-server >/dev/null 2>&1; then
      info "Switching from Xorg to XLibre; confirm the conflicting package replacements in pacman."
      flags=(-S --needed)
    fi
    # Server + libinput avoids pulling every legacy driver through xlibre-meta.
    sudo pacman "${flags[@]}" xlibre-xserver xlibre-input-libinput \
      || die "XLibre installation failed. Resolve the package conflict before retrying."
    pacman -Qq xlibre-xserver >/dev/null 2>&1 || die "XLibre server is missing."
  else
    sudo pacman -S --needed --noconfirm xorg-server xf86-input-libinput \
      || die "Xorg installation failed."
    pacman -Qq xorg-server >/dev/null 2>&1 || die "Xorg server is missing."
  fi
}

# ── CachyOS kernel ──────────────────────────────────────────────────────
setup_kernel() {
  ((USE_CACHYOS)) || return 0
  sudo pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers \
    || die "CachyOS kernel installation failed. Check the signature/conflict error above."
  pacman -Qq linux-cachyos >/dev/null 2>&1 || die "linux-cachyos is missing."
  pacman -Qq linux-cachyos-headers >/dev/null 2>&1 || die "linux-cachyos-headers is missing."
  command -v mkinitcpio >/dev/null 2>&1 && { sudo mkinitcpio -P || warn "mkinitcpio -P failed"; }
  if [[ -d /boot/loader ]]; then
    sudo bootctl update 2>/dev/null || true
  elif [[ -f /boot/grub/grub.cfg ]]; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub-mkconfig failed"
  fi
  ok "CachyOS kernel installed; reboot and check the boot entry."
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
      warn "$dm is enabled and conflicts with LightDM."
      if ask_yes_no "Disable $dm and enable LightDM?" y; then
        sudo systemctl disable "$dm" || warn "Could not disable $dm"
      else
        warn "Running two display managers can cause login problems."
      fi
    fi
  done
}

setup_shell() {
  local cur
  cur="$(getent passwd "$USER_NAME" | cut -d: -f7)"
  if [[ "$cur" != "/usr/bin/fish" ]]; then
    if ask_yes_no "Set fish as the default shell?" y; then
      chsh -s /usr/bin/fish "$USER_NAME" || warn "chsh failed; run 'chsh -s /usr/bin/fish' later."
    fi
  fi
}

# ── backup + deploy ─────────────────────────────────────────────────────
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

ensure_user_dir() {
  local path="$1" parent resolved home_root
  home_root="$(realpath "$HOME")"
  resolved="$(realpath -m "$path")"
  [[ "$resolved" == "$home_root" || "$resolved" == "$home_root/"* ]] \
    || die "Deployment directory points outside your home: $path"
  if [[ "$path" != "$HOME" ]]; then
    parent="$(dirname "$path")"
    ensure_user_dir "$parent"
  fi
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || die "Expected a directory: $path"
    if [[ "$(stat -Lc %u "$path")" == 0 ]]; then
      info "Repairing root-owned directory: $path"
      sudo chown "$USER_NAME:$USER_GROUP" "$resolved"
      sudo chmod u+rwx "$resolved"
    fi
  else
    mkdir "$path"
  fi
  [[ -w "$path" && -x "$path" ]] \
    || die "Directory is not writable by $USER_NAME: $path (check ownership, ACLs, or a read-only filesystem)."
}

prepare_user_paths() {
  local path name resolved home_root
  home_root="$(realpath "$HOME")"
  for path in "$HOME/.local/bin" "$HOME/.local/share/applications" \
      "$HOME/.local/share/fonts" "$HOME/.local/share/dwm-titus" \
      "$HOME/.config" "$HOME/custom-scripts" "$HOME/user_scripts" \
      "$HOME/Pictures/backgrounds"; do
    ensure_user_dir "$path"
  done
  # Repair only installer destinations left root-owned by a previous sudo build.
  local -a targets=("$HOME/.local/bin" "$HOME/.local/share/dwm-titus" \
    "$HOME/.local/share/applications" "$HOME/.local/share/fonts" \
    "$HOME/custom-scripts" "$HOME/user_scripts" "$HOME/Pictures/backgrounds")
  for path in "$REPO_DIR"/config/*/; do
    [[ -d "$path" ]] || continue
    name="$(basename "$path")"
    ensure_user_dir "$HOME/.config/$name"
    targets+=("$HOME/.config/$name")
  done
  for name in .xinitrc .xprofile .profile .bash_profile .bashrc .zshrc .gtkrc-2.0 picom.conf .fehbg; do
    targets+=("$HOME/$name")
  done
  for name in starship.toml mimeapps.list user-dirs.dirs xdg-terminals.list; do
    targets+=("$HOME/.config/$name")
  done
  for path in "${targets[@]}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    resolved="$(realpath -m "$path")"
    [[ "$resolved" == "$home_root/"* ]] || die "Deployment target points outside your home: $path"
    if [[ -L "$path" ]]; then
      # chown the link only; never traverse a linked directory tree.
      [[ "$(stat -c %u "$path")" != 0 ]] || sudo chown -h "$USER_NAME:$USER_GROUP" "$path"
    elif find "$path" -xdev -uid 0 -print -quit | grep . >/dev/null; then
      info "Repairing root-owned deployment files: $path"
      sudo find "$path" -xdev -uid 0 -exec chown -h "$USER_NAME:$USER_GROUP" {} +
    fi
  done
}

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
  command -v make >/dev/null 2>&1 || die "make is missing; install base-devel."
  command -v cc   >/dev/null 2>&1 || die "C compiler is missing; install base-devel."
  info "dwm build + install (sudo)..."
  if ! make -C "$REPO_DIR" clean all; then
    die "dwm build failed; see the error above."
  fi
  if ! sudo make -C "$REPO_DIR" install USER_HOME="$HOME" OWNER="$USER_NAME"; then
    die "dwm installation failed; see the error above."
  fi
}

setup_lightdm() {
  info "LightDM config..."
  handle_dm_conflict
  if [[ -f "$REPO_DIR/lightdm/Makefile" ]]; then
    sudo make -C "$REPO_DIR/lightdm" install || warn "LightDM configuration installation failed"
  fi
  sudo systemctl enable lightdm 2>/dev/null || warn "Could not enable lightdm"
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
    if ask_yes_no "Apply touchpad configuration (tapping, natural scroll, left-handed mouse)?" n; then
      sudo install -Dm644 "$etc/X11/xorg.conf.d/30-pointer-touchpad.conf" \
        /etc/X11/xorg.conf.d/30-pointer-touchpad.conf
      ok "touchpad config installed"
    fi
  fi

  if [[ -f "$etc/keyd/default.conf" ]]; then
    if ask_yes_no "Apply the bundled keyd keyboard remapping?" n; then
      pac_install keyd
      if pacman -Qq keyd >/dev/null 2>&1; then
        sudo install -Dm644 "$etc/keyd/default.conf" /etc/keyd/default.conf
        sudo systemctl enable --now keyd 2>/dev/null || warn "Could not enable the keyd service"
        ok "keyd config installed"
      else
        warn "keyd is not installed; skipping its configuration."
      fi
    fi
  fi

  if ask_yes_no "Apply system tuning (sysctl, zram, udev, i915/tearfree)?" n; then
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
      info "GPU=$gpu; skipping i915/tearfree."
    fi
  fi
}

check_critical() {
  local p missing=()
  for p in make gcc libx11 libxft libxinerama imlib2 polybar rofi lightdm lightdm-slick-greeter; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    die "Critical packages missing: ${missing[*]}; see the errors above."
  fi
}

# ── main ────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║        dwm-jabir installer  (Arch)            ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

if ((DEPLOY_ONLY)); then
  warn "--deploy-only: skipping packages, dwm build, and system configuration."
elif ((NO_DEPS)); then
  warn "--no-deps: skipping package installation."
else
  select_kernel
  select_xserver
  ((USE_CACHYOS)) && setup_cachyos_repos
  # Existing XLibre repositories need their key repaired before the first sync,
  # including on reruns that keep Xorg as the selected server.
  if [[ "$XSERVER" == xlibre ]] || grep -qE '^\[xlibre(-stable|-oldstable|-beta)?\]' "$PACMAN_CONF"; then
    setup_xlibre_repo
  fi
  if ((REPOS_CHANGED)); then
    info "Repositories prepared; a full system upgrade is required before installing packages."
    sudo pacman -Syu --noconfirm || die "System upgrade failed; resolve the error before retrying."
  elif ask_yes_no "Update the system (pacman -Syu)?" y; then
    sudo pacman -Syu --noconfirm || die "System upgrade failed; resolve the error before retrying."
  fi

  setup_kernel
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

  setup_network
  check_critical
fi

prepare_user_paths
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
  if ask_yes_no "Apply the theme now (generate rofi/polybar/gtk/qt colors)?" y; then
    "$REPO_DIR/scripts/theme-apply.sh" >/dev/null 2>&1 || warn "theme-apply failed; run it manually later."
    ok "theme applied"
  fi
fi

if ((WITH_APPS)); then
  info "optional apps install..."
  "$REPO_DIR/install-apps.sh" || warn "install-apps.sh failed to install some packages."
fi

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║          Installation Complete!               ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
if ((DEPLOY_ONLY)); then
  ok "Configuration deployed (dwm build skipped)."
else
  ok "dwm installed. Log out and select the 'dwm' session (or run startx)."
fi
echo ""
echo "  Next steps:"
echo "   1. ./setup-secrets.sh      → configure API tokens (not stored in GitHub)"
echo "   2. log out → select dwm in LightDM → log in"
echo "   3. check: polybar, rofi (SUPER+R), wallpaper, alacritty"
echo ""
echo "  Backup of old configs: $BACKUP_DIR"
if ((${#PAC_FAILED[@]})); then
  echo ""
  warn "Not installed (official): ${PAC_FAILED[*]}"
fi
if ((${#AUR_FAILED[@]})); then
  warn "Not installed (AUR): ${AUR_FAILED[*]}"
fi
echo ""
