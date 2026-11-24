#!/usr/bin/env python3
"""Bounded, read-only context for Jabir's desktop; JSON defaults to compact output."""
from __future__ import annotations

import argparse
import configparser
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import subprocess
import tomllib

HOME = Path.home()
CONFIG = HOME / '.config'
DATA = HOME / '.local/share'
REPO = HOME / 'dwm-jabir'
PROCESS_CACHE = None


def text(path: Path, limit: int = 131072) -> str:
    try:
        with path.open('r', encoding='utf-8', errors='replace') as stream:
            return stream.read(limit)
    except OSError:
        return ''


def run(argv: list[str], limit: int = 1800) -> str:
    if not shutil.which(argv[0]):
        return f'unavailable: {argv[0]}'
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=4,
                                check=False, errors='replace')
    except (OSError, subprocess.TimeoutExpired) as error:
        return f'unavailable: {type(error).__name__}'
    output = result.stdout.strip()
    if not output and result.returncode:
        return f'unavailable: exit {result.returncode}'
    return output[:limit] + (' [truncated]' if len(output) > limit else '')


def processes() -> dict[str, list[int]]:
    global PROCESS_CACHE
    if PROCESS_CACHE is None:
        PROCESS_CACHE = {}
        for line in run(['ps', '-u', str(os.getuid()), '-o', 'pid=,comm='], 65536).splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                PROCESS_CACHE.setdefault(parts[1], []).append(int(parts[0]))
    return PROCESS_CACHE


def selected_processes() -> dict[str, int]:
    names = ('dwm', 'polybar', 'dunst', 'picom', 'nm-applet', 'flameshot')
    result = {name: len(processes().get(name, [])) for name in names}
    # Onboard's process name is Python; count its anchored command pattern only.
    count = run(['pgrep', '-u', str(os.getuid()), '-c', '-f',
                 '^/usr/bin/python[0-9.]* /usr/bin/onboard'], 40)
    result['onboard'] = int(count) if count.isdigit() else None
    return result


def short_path(path: Path) -> str:
    value = str(path)
    return '~' + value[len(str(HOME)):] if value.startswith(str(HOME) + '/') else value


def command_paths(names: tuple[str, ...]) -> dict[str, str | None]:
    return {name: short_path(Path(value)) if (value := shutil.which(name)) else None
            for name in names}


def toml(path: Path) -> dict:
    try:
        return tomllib.loads(text(path))
    except tomllib.TOMLDecodeError:
        return {'parse_error': short_path(path)}


def ini(path: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        config.read_string('[global]\n' + text(path))
    except configparser.Error:
        config.clear()
    return config


def active_bar_path() -> Path:
    # Read only Polybar's config argument; never emit the rest of a command line.
    for pid in processes().get('polybar', []):
        args = text(Path(f'/proc/{pid}/cmdline')).split('\0')
        for index, arg in enumerate(args):
            if arg in ('-c', '--config') and index + 1 < len(args):
                candidate = Path(args[index + 1])
            elif arg.startswith('--config='):
                candidate = Path(arg.split('=', 1)[1])
            else:
                continue
            if candidate.is_relative_to(CONFIG) or candidate.is_relative_to(REPO / 'config'):
                return candidate
    laptop = CONFIG / 'polybar/themes/minimal/laptop-config.ini'
    return laptop if laptop.exists() else CONFIG / 'polybar/themes/minimal/config.ini'


def repo_status() -> str:
    return run(['git', '--no-optional-locks', '-c', 'core.fsmonitor=false',
                '-C', str(REPO), 'status', '--short', '--branch'], 1400)


def os_identity() -> dict:
    values = {}
    for line in text(Path('/etc/os-release')).splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in ('ID', 'PRETTY_NAME'):
                values[key] = value.strip('"')
    return dict(values, kernel=platform.release(), architecture=platform.machine())


def summary() -> dict:
    theme = toml(CONFIG / 'dwm-titus/themes.toml').get('active', {}).get('theme')
    return {'os': os_identity(), 'processes': selected_processes(), 'theme': theme,
            'polybar_config': short_path(active_bar_path()),
            'repo': short_path(REPO), 'git': repo_status()}


def desktop() -> dict:
    hotkeys = toml(CONFIG / 'dwm-titus/hotkeys.toml')
    variables = hotkeys.get('vars', {})
    keys = hotkeys.get('keys', variables.get('keys', []))
    return {'session': {key: os.environ.get(key) for key in
                        ('DISPLAY', 'XDG_SESSION_TYPE', 'XDG_CURRENT_DESKTOP')},
            'login_shell': pwd.getpwuid(os.getuid()).pw_shell,
            'processes': selected_processes(),
            'commands': command_paths(('dwm', 'xrandr', 'xinput', 'xdotool', 'dwm-keybinds')),
            'terminal_variable': variables.get('terminal'), 'binding_count': len(keys),
            'monitors': run(['xrandr', '--listmonitors']),
            'current_desktop': run(['xprop', '-root', '_NET_CURRENT_DESKTOP']),
            'display_manager': str(Path('/etc/systemd/system/display-manager.service').resolve())}


def appearance() -> dict:
    themes = toml(CONFIG / 'dwm-titus/themes.toml')
    palette = ini(CONFIG / 'polybar/themes/minimal/colors.ini')
    bar_path = active_bar_path()
    bars = ini(bar_path)
    keep = ('height', 'dpi', 'dpi-x', 'dpi-y', 'border-bottom-size', 'modules-left',
            'modules-center', 'modules-right', 'separator')
    return {'active_theme': themes.get('active', {}).get('theme'),
            'available_themes': list(themes.get('theme', {})),
            'appearance': themes.get('appearance', {}),
            'palette': dict(palette['colors']) if palette.has_section('colors') else {},
            'bar_path': short_path(bar_path),
            'bars': {section: {key: bars[section][key] for key in keep if key in bars[section]}
                     for section in bars.sections() if section.startswith('bar/')},
            'font_patterns': re.findall(r'^font-\d+\s*=\s*.+$', text(CONFIG / 'polybar/fonts.ini'), re.M),
            'theme_helper': short_path((HOME / '.local/bin/theme-apply.sh').resolve()),
            'icon_theme': run(['gsettings', 'get', 'org.gnome.desktop.interface', 'icon-theme'])}


def apps() -> dict:
    names = ('alacritty', 'ghostty', 'kitty', 'fish', 'rofi', 'thunar', 'l3afpad',
             'nsxiv', 'btop', 'fastfetch', 'webapp-launch', 'webapp-create', 'protonrestart')
    types = ('text/plain', 'inode/directory', 'image/png', 'application/pdf')
    return {'commands': command_paths(names),
            'mime_defaults': {kind: run(['xdg-mime', 'query', 'default', kind], 240) for kind in types},
            'browser': run(['xdg-settings', 'get', 'default-web-browser'], 240)}


def input_context() -> dict:
    return {'commands': command_paths(('xinput', 'xrandr', 'brightnessctl', 'keyd', 'wayclick',
                                      'flameshot', 'dwm-screenshot', 'ffmpeg', 'i3lock', 'xss-lock')),
            'profile_exists': (HOME / '.xprofile').exists(),
            'session_setup': (DATA / 'dwm-titus/scripts/session-setup.sh').exists(),
            'input_setup': (DATA / 'dwm-titus/scripts/input-setup.sh').exists(),
            'persistent_config': {name: Path(name).exists() for name in
                                  ('/etc/keyd', '/etc/libinput', '/etc/X11/xorg.conf.d')}}


def unit_names(user: bool = False) -> list[str]:
    argv = ['systemctl'] + (['--user'] if user else [])
    output = run(argv + ['list-units', '--type=service', '--state=running',
                         '--no-legend', '--no-pager'], 12000)
    if output.startswith('unavailable:'):
        return [output]
    return [parts[0] for line in output.splitlines() if (parts := line.split())][:60]


def services() -> dict:
    cpu = next((line.split(':', 1)[1].strip() for line in text(Path('/proc/cpuinfo')).splitlines()
                if line.startswith('model name')), None)
    memory = re.search(r'^MemTotal:\s+(\d+)', text(Path('/proc/meminfo')), re.M)
    packages = ('linux', 'linux-cachyos', 'xorg-server', 'xlibre-xserver', 'lightdm',
                'networkmanager', 'pipewire', 'wireplumber', 'bluez', 'openssh', 'ufw', 'zram-generator')
    return {'os': os_identity(), 'hardware_model': text(Path('/sys/class/dmi/id/product_name')).strip(),
            'cpu': cpu, 'logical_cpus': os.cpu_count(),
            'ram_gib': round(int(memory[1]) / 1048576, 1) if memory else None,
            'uefi': Path('/sys/firmware/efi').exists(),
            'storage': run(['lsblk', '-o', 'NAME,TYPE,SIZE,FSTYPE'], 1500),
            'root_fstype': run(['findmnt', '-n', '-o', 'FSTYPE', '/'], 100),
            'system_services': unit_names(), 'user_services': unit_names(True),
            'selected_packages': run(['pacman', '-Q', *packages], 1200),
            'commands': command_paths(('nmcli', 'pactl', 'wpctl', 'warp-cli', 'ufw',
                                      'firewall-cmd', 'getenforce', 'nvidia-smi'))}


def automation() -> dict:
    folder = CONFIG / 'autostart'
    units = CONFIG / 'systemd/user'
    return {'user_services': unit_names(True),
            'xdg_autostart_files': sorted(p.name for p in folder.glob('*.desktop'))[:40],
            'user_unit_files': sorted(p.name for p in units.glob('*') if p.is_file())[:40],
            'autostart_source': short_path(DATA / 'dwm-titus/scripts/autostart.sh'),
            'reminder_source': short_path(CONFIG / 'polybar/themes/minimal/reminder.sh'),
            'note': 'Reminder status is not executed: it can heal/fire timers.'}


def repository() -> dict:
    return {'path': short_path(REPO), 'git': repo_status(),
            'live_config': short_path(CONFIG), 'deployed_scripts': short_path(DATA / 'dwm-titus/scripts'),
            'entrypoints': {name: (REPO / name).exists() for name in
                            ('install.sh', 'install-arm.sh', 'Makefile', 'SNAPSHOT.md', 'INSTALL.md')},
            'theme_helper_target': short_path((HOME / '.local/bin/theme-apply.sh').resolve())}


def main() -> None:
    global HOME, CONFIG, DATA, REPO
    collectors = {'summary': summary, 'desktop': desktop, 'appearance': appearance,
                  'apps': apps, 'input': input_context, 'services': services,
                  'automation': automation, 'repo': repository}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--section', action='append', choices=tuple(collectors))
    parser.add_argument('--all', action='store_true', help='Explicit broad inventory')
    parser.add_argument('--pretty', action='store_true')
    parser.add_argument('--home', type=Path, help='Alternate profile root; never changes HOME environment')
    parser.add_argument('--repo', type=Path)
    args = parser.parse_args()
    HOME = args.home.expanduser().resolve() if args.home else Path.home()
    CONFIG = HOME / '.config' if args.home else Path(os.environ.get('XDG_CONFIG_HOME', str(HOME / '.config')))
    DATA = HOME / '.local/share' if args.home else Path(os.environ.get('XDG_DATA_HOME', str(HOME / '.local/share')))
    candidates = [parent for parent in Path(__file__).resolve().parents if (parent / '.git').exists()]
    REPO = args.repo.expanduser().resolve() if args.repo else (candidates[0] if candidates else HOME / 'dwm-jabir')
    selected = list(collectors)[1:] if args.all else list(dict.fromkeys(args.section or ['summary']))
    output = {'captured_utc': datetime.now(timezone.utc).isoformat(timespec='seconds')}
    for section in selected:
        output[section] = collectors[section]()
    print(json.dumps(output, ensure_ascii=False, indent=2 if args.pretty else None,
                     separators=None if args.pretty else (',', ':')))


if __name__ == '__main__':
    main()
