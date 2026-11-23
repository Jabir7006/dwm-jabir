# dwm-jabir — install guide

minimal **Arch** বা **CachyOS** install করে এক কমান্ডে আপনার preconfigured
DWM desktop ফিরিয়ে আনার জন্য।

---

## ১. যা লাগবে

- Arch Linux বা CachyOS (fresh minimal install)
- ইন্টারনেট
- একটা sudo--capable user (root হিসেবে স্ক্রিপ্ট চালাবেন না)
- `git` (fresh install-এ না থাকলে: `sudo pacman -S git`)

---

## ২. এক কমান্ডে install

```bash
git clone https://github.com/Jabir7006/dwm-jabir.git ~/dwm-jabir
cd ~/dwm-jabir
./install.sh
```

শেষে:

```bash
./setup-secrets.sh     # API token বসান (GitHub-এ নেই)
```

তারপর logout → LightDM-এ **dwm** session → login।

### অপশন

```bash
./install.sh --with-apps   # core + আপনার সব optional app
./install.sh --no-deps     # package install বাদ, শুধু config + dwm build
./install.sh -y            # সব prompt-এ default উত্তর
```

---

## ৩. install.sh যা জিজ্ঞেস করবে

| প্রশ্ন | ডিফল্ট | মানে |
|---|---|---|
| CachyOS kernel + optimized repos? (প্রথম প্রশ্ন) | fresh Arch: no; CachyOS বা আগে বাছা থাকলে: yes | keyring ও compatible pacman আগে প্রস্তুত করে CPU-সমর্থিত repo Arch repo-র উপরে বসায় |
| XLibre instead of Xorg? | no | নতুন install-এ Xorg; আগে থেকে XLibre থাকলে সেটি রাখে |
| সিস্টেম update করব? | yes | `pacman -Syu`; repo প্রস্তুত/পরিবর্তন হলে update বাধ্যতামূলক |
| paru নাকি yay-bin? | paru | AUR helper না থাকলে |
| Touchpad config? | no | tapping, natural scroll, left-handed mouse |
| keyd keyboard remap? | no | আপনার custom key layout |
| System tuning? | no | sysctl, zram, udev, Intel i915/tearfree |
| fish default shell? | yes | `chsh -s /usr/bin/fish` |
| থিম apply করব? | yes | rofi/polybar/gtk/qt colors regenerate |

স্ক্রিপ্টের সব prompt ও message ইংরেজিতে। CachyOS বেছে নিলে kernel এবং
desktop package install-এর আগে signing key, keyring ও mirrorlist প্রস্তুত হয়।
সাধারণ Arch pacman optimized architecture গ্রহণ না করলে generic CachyOS repo
থেকে CachyOS pacman install করে support যাচাই করে; `Architecture = auto` রাখে।
CPU অনুযায়ী generic, v3, v4 বা (শনাক্ত হলে) Zen 4/5 repo অগ্রাধিকার পায়।
CachyOS repo-তে পাওয়া package সেখান থেকে আসে; বাকিগুলো Arch/AUR থেকে আসে।
Repo bootstrap বা system upgrade ব্যর্থ হলে installer থামে।

### মাঝপথে ব্যর্থ হলে বা আবার install করতে চাইলে

```bash
git pull --ff-only
./install.sh
```

- আগে CachyOS repo/kernel বাছা থাকলে rerun-এ সেটিই default। Existing optimized
  repo-র pacman compatibility kernel prompt-এ no দিলেও যাচাই/repair হয়।
- Installed package `--needed` দিয়ে skip হয়; working AUR helper আবার build হয় না।
  Repo section duplicate হয় না, একই config হলে আবার repo backup তৈরি হয় না।
- Config আবার apply হয়; প্রতিবার আলাদা backup directory-তে আগের config থাকে।
  একই path-এর backup দ্বিতীয়বার overwrite হয় না এবং config directory nested হয় না।
- একসঙ্গে একই user-এর দুটি installer run চলবে না। Failed run-এর temporary
  directory cleanup হয়; পরের run-এ আবার চেষ্টা করা যায়।
- Backup failure হলে overwrite থামে। Package/app install অসম্পূর্ণ হলে installer
  error status দেয়; error ঠিক করে আবার চালান। Signature check চালু থাকে।
- `--no-deps` বা `--deploy-only`-এর সঙ্গে `--with-apps` দিলে app install-ও skip হয়।

---

## ৪. core-এ যা install হয়

পুরো লিস্ট: `packages/core-official.txt` + `packages/core-aur.txt`

- **DWM build:** base-devel, libx11, libxft, libxinerama, imlib2, libxcb, xcb-util
- **X:** xorg-server + xf86-input-libinput (অথবা xlibre-xserver + xlibre-input-libinput), xorg-xinit/xrandr/xsetroot/xset/xprop/xrdb
- **Desktop:** polybar, rofi, dunst, feh, flameshot, dex, mate-polkit, clipmenu
- **Files:** thunar, gvfs, tumbler, thunar-archive-plugin, xarchiver
- **Theming:** nwg-look, qt6ct, dconf, papirus-icon-theme, matugen
- **Audio:** pipewire, wireplumber, pavucontrol, alsa-utils
- **Network:** networkmanager, network-manager-applet, gnome-keyring
- **Fonts:** noto-fonts (+cjk/emoji), ttf-meslo-nerd, ttf-jetbrains-mono-nerd
- **Shell:** fish, starship, fastfetch, btop, eza, fzf, zoxide
- **Terminal:** alacritty
- **DM:** lightdm, lightdm-slick-greeter
- **Extra:** mpv, nsxiv, localsend, gum, zram-generator, reflector, ntfsprogs
- **AUR:** google-chrome, fresh-editor-bin

---

## ৫. optional apps

```bash
./install-apps.sh
```

লিস্ট: `packages/apps-official.txt` + `packages/apps-aur.txt`
(brave, helium, vscodium, opencode, claude-code, t3code, antigravity, portproton,
telegram, yt-dlp, gamemode, mangohud, bibata cursor, ইত্যাদি)

কোনো প্যাকেজ নতুন সিস্টেমে না চাইলে `packages/skip.txt`-এ নাম লিখুন।
নিজের প্যাকেজ যোগ করতে list ফাইলে নাম লিখুন।

---

## ৬. যা GitHub-এ নেই (ইচ্ছাকৃত)

| জিনিস | কেন |
|---|---|
| API token/key | `./setup-secrets.sh` → `~/.config/dwm-titus/secrets.env` |
| Browser profile/login | নতুন সিস্টেমে re-login |
| App auth (opencode/claude/codex/t3) | নতুন সিস্টেমে re-login |
| Projects / Documents / Downloads / Pictures | আলাদা backup |
| Games / PortProton / .wine | বিশাল |
| `fstab`, `grub`, `mkinitcpio`, hostname | নতুন disk-এ আলাদা |
| বড় binary (`gh`, `cineo`, `moviebox-tui`) | নিজে install করবেন |

---

## ৭. install-এর পরে

1. `./setup-secrets.sh` — AgentRouter/OpenWeather key
2. logout → LightDM → **dwm**
3. চেক:
   - polybar উপরে আছে?
   - `SUPER+R` → rofi
   - `SUPER+Return` → terminal (alacritty)
   - wallpaper ঠিক আছে?
   - touchpad/keyd চাইলে install-এর সময় yes দিয়েছিলেন?
4. browser-এ আবার login করুন

---

## ৮. সমস্যা হলে

**AUR build fail**
```bash
sudo pacman -S --needed base-devel git
./install.sh --no-deps   # শুধু config/dwm
```

**LightDM-এ login loop**
- `.profile`-এ কোনো ভাঙা `source` লাইন আছে কি? (`[ -f ... ] &&` guard)
- `~/.xsession-errors` দেখুন

**touchpad কাজ করছে না**
```bash
sudo install -Dm644 system-config/etc/X11/xorg.conf.d/30-pointer-touchpad.conf \
  /etc/X11/xorg.conf.d/30-pointer-touchpad.conf
# logout/login
```

**keyd উল্টো behavior**
```bash
sudo systemctl disable --now keyd
```

**Xlibre repo signature error**
- `./install.sh` আবার চালান; installer XLibre-এর নিজস্ব signing key trust করে
  তারপর repo sync করে। `archlinux-keyring` একা এই third-party key দেয় না।
- Xorg থেকে XLibre বেছে নিলে pacman-এর package replacement prompt confirm করুন।

**CachyOS package signature error**
- `./install.sh` চালিয়ে প্রথম prompt-এ CachyOS বেছে নিন। Installer CachyOS
  signing key trust করে signed keyring/mirrorlist install করে, তারপর full update করে।
- system clock ও ইন্টারনেট ঠিক আছে কি দেখুন। Signature checking বন্ধ করবেন না।

**`x86_64_v3 ... does not have a valid architecture`**
- Updated script pull করে আবার `./install.sh` চালান। Installer optimized repo
  থেকে upgrade করার আগে CachyOS pacman bootstrap করে architecture support যাচাই করে।
- Bootstrap dependency/conflict error হলে সেটি আগে ঠিক করুন; installer error দেখিয়ে
  থামবে। `--ignorearch` দিয়ে CPU-অসামঞ্জস্যপূর্ণ package install করবেন না।

**Cannot create `~/.local/bin`: Permission denied**
- Installer তার ব্যবহৃত home directory ও deployment file-গুলো আগে থেকে
  root-owned থাকলে ownership ঠিক করে। `make install`-ও নতুন parent directory-র
  ownership user-কে দেয়। নিজের user দিয়ে `./install.sh` চালান।

**CachyOS kernel boot entry নেই**
- `sudo mkinitcpio -P`
- systemd-boot: `sudo bootctl update`
- GRUB: `sudo grub-mkconfig -o /boot/grub/grub.cfg`

---

## ৯. repo structure

```
dwm-jabir/
├── install.sh              # core installer
├── install-apps.sh         # optional apps
├── setup-secrets.sh        # API token/key
├── packages/               # package lists
├── config/                 # → ~/.config/
├── home/                   # → ~/ (dotfiles + scripts)
├── applications/           # → ~/.local/share/applications/
├── fonts/                  # → ~/.local/share/fonts/
├── wallpapers/             # → ~/Pictures/backgrounds/
├── scripts/                # dwm scripts → /usr/local/bin
├── lightdm/                # LightDM config
├── system-config/etc/      # /etc reference (ask করে install)
├── dwm.c, drw.c, ...       # dwm source
└── Makefile
```

---

## ১০. পুরোনো config

install.sh কিছু overwrite করার আগে backup রাখে:

```
~/.config-backup-YYYYmmdd-HHMMSS-PID/
```

কিছু না হারিয়ে ফিরে যেতে চাইলে ওই ফোল্ডার থেকে কপি করুন।
