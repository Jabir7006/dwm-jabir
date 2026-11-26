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

system-config/etc holds installer inputs, not auto-applied state: touchpad mapping is prompted (default yes), keyd remapping and sysctl/zram/udev/i915/tearfree tuning default to no, and the installer filters browser policies to appearance keys only. system-config/reference/etc is a snapshot of live host files for reference. Never enable a prompted tuning set without the user's request.

Power/GPU helpers are hardware-specific: power-management.sh is a read-only report without flags (--apply writes sysfs, --apply-tlp writes TLP config; both need root), and its header targets a different laptop than the observed EliteBook, so inspect before applying. nvidia-gpu and nvidia-temp are nvidia-smi readouts only; disable-powersaving just runs xset -dpms and is already reflected in autostart. PortProton gets a 6-hour user timer plus a launch-time patch hook (automation.md).

Desktop network/VM extras: localsend-toggle drives hostapd + dnsmasq on `ap0` 10.42.0.1/24 with sudo and a pidfile under /run; vmtoggle owns libvirtd and the default libvirt network; KDE Connect starts from autostart. Check their state instead of restarting the underlying service.

The baseline laptop has modest RAM. Prefer existing event-driven interfaces for desktop indicators; add a daemon only when the requested feature needs one. Separate resident overhead from one-time theme/icon generation. A single ps CPU figure is a snapshot, not a benchmark or a zero-impact guarantee.

Keep boot persistence and runtime effects aligned. For privileged system work, preserve the targeted files/ownership and a viable rollback/access path within the user's authorization; do not weaken security or reset unrelated services as a troubleshooting shortcut.
