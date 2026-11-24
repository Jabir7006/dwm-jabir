# Host services, packages and hardware

Run the helper's services section for a bounded inventory. Inspect only the affected unit/log interval for a focused issue; the helper deliberately does not dump secrets, full logs, addresses or wireless SSIDs.

| Topic | Relevant controls/sources |
|---|---|
| Login/session | LightDM, /etc/lightdm/, /usr/share/xsessions/, graphical.target |
| Network/DNS | NetworkManager, nmcli, systemd-resolved; nm-applet is only the tray UI |
| WARP | warp-cli/warp-svc where installed; warp_toggle.py and warp_state supply the desktop indicator |
| Audio | PipeWire, pipewire-pulse, WirePlumber; pactl/wpctl and sound/toggle-sink helpers |
| Bluetooth/devices | bluez/bluetooth.service, udev and device permissions |
| Storage/memory | findmnt/lsblk, ext4/NTFS mounts, zram generator, swap and /etc/fstab |
| Power/GPU | kernel/driver, brightnessctl, power-management helpers, i915/X11 configuration |
| Security/access | polkit, keyring, SSH, actual firewall stack and relevant systemd drop-ins |
| Packages/boot | /etc/pacman.conf and pacman.d/, bootloader files, kernel/initramfs tooling |

The OS identifies as Arch with CachyOS components; determine actual installed kernel/server/package versions. Never transplant this laptop's disks, machine identifiers, GPU/input configuration or SSH keys into another host. Use the repository installer for a requested portable deployment and read its current prompts/compatibility logic.

Check whether a component is a system service, user service or autostart process before restarting/adding it. Dunst/PipeWire/portals can already be owned by systemd. Restarting nm-applet reloads artwork without restarting NetworkManager; verify active connections when making networking changes.

The baseline laptop has modest RAM. Prefer existing event-driven interfaces for desktop indicators; add a daemon only when the requested feature needs one. Separate resident overhead from one-time theme/icon generation. A single ps CPU figure is a snapshot, not a benchmark or a zero-impact guarantee.

Keep boot persistence and runtime effects aligned. For privileged system work, preserve the targeted files/ownership and a viable rollback/access path within the user's authorization; do not weaken security or reset unrelated services as a troubleshooting shortcut.
