#!/usr/bin/env python3
"""Export shareable desktop configuration and scripts, never account data.

Run only when you want to update the repository snapshot:
    python3 scripts/snapshot-desktop.py --home /home/your-user
The source desktop is read only. Installer compatibility fixes already in the
repository are retained; the manifest records those portable overrides.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
from datetime import datetime, timezone


CONFIG_DIRS = {
    "CachyOS", "MangoHud", "QtProject", "Softdeluxe", "Thunar", "alacritty",
    "autostart", "btop", "cliamp", "cloudstream", "dunst", "dusky",
    "dwm-titus", "fastfetch", "fish", "flameshot", "fontconfig", "fresh",
    "ghostty", "git", "gridcraft", "gtk-3.0", "gtk-4.0", "hydra", "kitty",
    "l3afpad", "moviebox-tui", "mpv", "numes", "nwg-look", "opencode",
    "openspec", "pipewire", "plateflow", "portproton-patch", "qalculate",
    "qt6ct", "rofi", "systemd", "thefuck", "tuck", "wavemon", "wayclick",
    "wu", "xarchiver", "xdg-desktop-portal", "xfce4", "xsettingsd",
}
TOP_CONFIG_FILES = {
    "PortProton.conf", "QtProject.conf", "brave-origin-flags.conf",
    "chrome-flags.conf", "konsolerc", "konsolesshconfig", "krenamerc",
    "kritadisplayrc", "kritarc", "mimeapps.list", "pavucontrol.ini",
    "portproton-patch.conf", "starship.toml", "user-dirs.dirs",
    "user-dirs.locale", "xdg-terminals.list",
}
HOME_FILES = {
    ".bash_logout", ".bash_profile", ".bashrc", ".fehbg", ".gitconfig",
    ".gtkrc-2.0", ".lmmsrc.xml", ".npmrc", ".profile", ".xinitrc",
    ".xprofile", ".yarnrc", ".zshrc", "picom.conf",
}
# Keep the small, approved bundle when refreshing the desktop snapshot.
WALLPAPER_FILES = (
    "ristretto-3-industrial-moon.webp",
    "wallpaperflare.com_wallpaper.jpg",
    "ristretto-1-color-curves.webp",
    "ristretto-0-launch.webp",
    "1920x1080_anime_a_person_standing_on_a_broken_object_in_a_field_with_a_large_white_moon.jpg",
)
PORTABLE_OVERRIDES = {
    "config/fish/config.fish", "config/fish/conf.d/fnm.fish",
    "config/fish/conf.d/rustup.fish", "config/mpv/mpv.conf",
    "config/polybar/launch.sh", "config/polybar/themes/minimal/config.ini",
    "config/polybar/themes/minimal/modules/battery.ini",
    "config/polybar/themes/minimal/modules/brightnessctl.ini",
    "config/polybar/scripts/weather/main.py", "config/polybar/scripts/weather/weather.sh",
    "config/polybar/themes/minimal/modules/weather.ini",
    "config/pipewire/pipewire.conf.d/roc-sink.conf",
    "config/mimeapps.list",
    "home/.profile", "home/.xprofile", "home/.xinitrc",
    "home/.bashrc", "home/.zshrc", "home/.local/bin/codex",
    "home/.local/bin/app-manager",
    "home/.fehbg", "home/.local/bin/wallpaper-apply",
    "home/.local/bin/wallpaper-picker.sh", "home/.local/bin/wallpaper-random.sh",
    "home/.local/bin/wallpaper-carousel", "home/.local/bin/theme-set-dynamic",
    "home/user_scripts/wayclick/dusky_wayclick.sh",
    "applications/cineo.desktop", "applications/deepai-code.desktop",
    "applications/org.deepai.code.desktop", "applications/Opencode.desktop",
    "applications/Warp.desktop", "applications/Minitop.desktop",
    "applications/nsxiv.desktop", "applications/userapp-nsxiv -b %f-VDA9P3.desktop",
}
PRIVATE_COMPONENTS = {
    "auth", "authentication", "human-auth", "credentials", "secrets", "keys",
    "cache", "code cache", "gpucache", "local storage", "session storage",
    "indexeddb", "sessions", "session", "history", "logs", "log", "covers",
    "workspaceStorage", "globalStorage", "node_modules", ".git", "__pycache__",
    ".venv", "venv",
    "telemetry", "Crashpad", "blob_storage", "backups",
    "screenshots",
}
PRIVATE_NAMES = re.compile(
    r"(^|[._-])(auth|credentials?|cookies?|tokens?|secrets?|history|resume|ipc|"
    r"lock|session|storage|updaterid)([._-]|$)|\.bak(?:[-.]|$)|\.backup$|"
    r"\.log$|\.out$|\.tmp$|\.cache$|^\.tmp-|^\.last-|\.secret$|\.env$|"
    r"\.db$|\.redb$|\.vscdb|\.sqlite|\.count$|^fish_variables$|"
    r"^service\.json$|^\.build_marker_", re.I
)
SECRET_LITERAL = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|"
    r"\b(?:sk-[A-Za-z0-9_-]{18,}|gh[pousr]_[A-Za-z0-9]{20,}|"
    r"github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b|"
    r"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b|"
    r"\b(?:Bearer|Basic)\s+[A-Za-z0-9._=+-]{16,}|"
    r"https?://[^\s/@:]+:[^\s/@]+@|"
    r"https?://[^\s\"']+[?&](?:api_?key|token|access_token|auth|password|key)=[A-Za-z0-9_.+-]{12,}"
)
KEY_VALUE = re.compile(
    r"(?im)(?<![\w.-])(?:[\"']?)([\w.-]*(?:api[_-]?key|access[_-]?key|token|password|"
    r"secret|authorization|bearer|client[_-]?secret)|key)[\"']?\s*[:=]\s*[\"']([^\"'\n]+)[\"']"
)
UNQUOTED_SECRET = re.compile(
    r"(?im)^\s*(?:export\s+)?[\w.-]*(?:api[_-]?key|token|password|secret|authorization)\s*=\s*([^\s#;]+)"
)


def credential_reason(text):
    if SECRET_LITERAL.search(text):
        return "credential/private-key literal"
    for match in UNQUOTED_SECRET.finditer(text):
        raw_value = match.group(1)
        value = raw_value.strip("\"'")
        if value.upper().startswith(("YOUR", "REPLACE", "EXAMPLE", "CHANGEME")):
            continue
        if not raw_value.startswith(("\"", "'")) and (
            re.match(r"[A-Za-z_][\w.]*\(", value)
            or value.startswith(("os.environ", "process.env", "None"))
            or re.match(r"(?:args|options|namespace)\.[A-Za-z_]", value)
        ):
            continue
        if len(value) >= 8 and not any(marker in value for marker in ("$", "{env:", "REPLACE_", "YOUR_", "None")):
            return "credential-like unquoted assignment"
    for match in KEY_VALUE.finditer(text):
        value = match.group(2)
        if match.group(1).casefold() == "key" and not re.fullmatch(r"[0-9a-fA-F]{32,}", value):
            continue
        if any(marker in value for marker in ("${", "$HOME", "{env:", "getenv", "REPLACE_", "YOUR_")):
            continue
        if len(value) >= 16 and re.fullmatch(r"[A-Za-z0-9_+/=.-]+", value):
            return "credential-like configuration value"
    for line in text.splitlines():
        if re.search(r"^\s*(?:export\s+|set\s+-\w+\s+)[A-Z_]*(?:KEY|TOKEN|PASSWORD|SECRET)\s+", line):
            if "$" not in line and re.search(r"[A-Za-z0-9_-]{20,}", line.rsplit(" ", 1)[-1]):
                return "credential-like shell assignment"
    return ""


def parse_jsonc(text):
    output = []
    quoted = escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if quoted:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            output.append(char)
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
            continue
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise ValueError("Unterminated JSON comment")
            output.append("\n" * text[index:end + 2].count("\n"))
            index = end + 2
            continue
        else:
            output.append(char)
        index += 1
    text = "".join(output)
    output = []
    quoted = escaped = False
    for index, char in enumerate(text):
        if quoted:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            output.append(char)
        elif char == ",":
            following = index + 1
            while following < len(text) and text[following].isspace():
                following += 1
            if following >= len(text) or text[following] not in "}]":
                output.append(char)
        else:
            output.append(char)
    return json.loads("".join(output))


def sanitized_json(data):
    try:
        document = parse_jsonc(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    changed = False

    def clean(value, credential_context=False):
        nonlocal changed
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                normalized = re.sub(r"[^a-z]", "", key.casefold())
                sensitive = normalized.endswith(("apikey", "apikeys", "password", "passwords", "token", "tokens", "secret", "secrets", "authorization", "accesskey", "accesskeys"))
                if credential_context and normalized in {"env", "source", "type", "provider", "variable", "name"} and isinstance(item, str) and not SECRET_LITERAL.search(item):
                    result[key] = item
                else:
                    result[key] = clean(item, sensitive or credential_context)
            return result
        if isinstance(value, list):
            return [clean(item, credential_context) for item in value]
        placeholder = isinstance(value, str) and (
            re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\{env:[A-Za-z_][A-Za-z0-9_]*\}", value)
            or value.startswith(("YOUR_", "REPLACE_"))
        )
        if credential_context and value not in (None, "") and not isinstance(value, bool) and not placeholder:
            changed = True
            return ""
        if isinstance(value, str) and SECRET_LITERAL.search(value) and not placeholder:
            changed = True
            return ""
        return value

    result = clean(document)
    if not changed and not credential_reason(data.decode("utf-8")):
        return None
    return (json.dumps(result, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


class Snapshot:
    def __init__(self, home, repo):
        self.home = home.resolve()
        self.repo = repo.resolve()
        self.included = []
        self.excluded = []
        self.tracked = set(subprocess.run(["git", "-C", str(self.repo), "ls-files", "-z"], text=True, capture_output=True).stdout.split("\0"))

    def omit(self, source, reason):
        # Record filenames and reasons, never excluded contents or key values.
        self.excluded.append({"source": str(source), "reason": reason})

    def remove_generated(self, destination):
        relative = destination.relative_to(self.repo).as_posix()
        if relative in self.tracked:
            return
        if destination.is_dir() and not destination.is_symlink() and any(path.startswith(relative + "/") for path in self.tracked):
            for child in destination.iterdir():
                self.remove_generated(child)
            return
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        elif destination.is_dir():
            shutil.rmtree(destination)

    def copy(self, source, destination, force=False):
        relative = destination.relative_to(self.repo).as_posix()
        if source.is_symlink():
            target = os.readlink(source)
            if relative.startswith("home/.local/share/icons/") and target.startswith("/usr/share/icons/"):
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                destination.symlink_to(target)
                self.included.append({"source": str(source), "destination": relative, "symlink": target})
            else:
                self.omit(source, "runtime or machine-specific symlink")
            return
        if not source.is_file():
            return
        if PRIVATE_NAMES.search(source.name):
            self.omit(source, "account data, history, cache, backup, or runtime state")
            self.remove_generated(destination)
            return
        data = source.read_bytes()
        if data.startswith(b"\x7fELF") or source.suffix.lower() in {".so", ".node", ".wasm", ".pyc"}:
            self.omit(source, "binary supplied by an application/package")
            return
        if len(data) >= 95 * 1024 * 1024:
            self.omit(source, "exceeds repository asset size limit")
            return
        try:
            reason = credential_reason(data.decode("utf-8"))
        except UnicodeDecodeError:
            reason = "" if source.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".svg", ".ttf", ".otf", ".woff", ".woff2", ".mp3", ".wav", ".ogg", ".flac"} else "non-config application data"
        sanitized = False
        launcher_rewritten = False
        clean_data = sanitized_json(data) if source.suffix in {".json", ".jsonc"} else None
        if reason or clean_data is not None:
            if clean_data is not None and not credential_reason(clean_data.decode("utf-8")):
                self.omit(source, "raw credentials omitted; shareable JSON preferences retained")
                data = clean_data
                sanitized = True
            elif relative in PORTABLE_OVERRIDES and destination.is_file():
                self.omit(source, reason + "; existing credential-free portable template retained")
                self.included.append({"source": str(source), "destination": relative, "portable_override": True})
                return
            else:
                self.omit(source, reason)
                self.remove_generated(destination)
                return
        if source.suffix == ".desktop" and b"TryExec=" not in data:
            text = data.decode("utf-8")
            match = re.search(r"(?m)^Exec=(.*)$", text)
            if match:
                try:
                    command = shlex.split(match.group(1))
                    if command and command[0] == "env":
                        command = [arg for arg in command[1:] if not arg.startswith("-") and "=" not in arg]
                    if command:
                        data = (text.rstrip() + "\nTryExec=" + command[0] + "\n").encode("utf-8")
                        launcher_rewritten = True
                except ValueError:
                    pass
        record = {"source": str(source), "destination": relative, "sha256": hashlib.sha256(data).hexdigest()}
        if not force and relative in PORTABLE_OVERRIDES and destination.is_file():
            record["portable_override"] = True
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink():
                destination.unlink()
            if sanitized or launcher_rewritten:
                destination.write_bytes(data)
                destination.chmod(source.stat().st_mode & 0o777)
                if sanitized:
                    record["credentials_removed"] = True
                if launcher_rewritten:
                    record["launcher_check_added"] = True
            else:
                shutil.copy2(source, destination)
        self.included.append(record)

    def tree(self, source, destination):
        if not source.is_dir():
            return
        for base, dirs, files in os.walk(source, followlinks=False):
            kept = []
            for name in dirs:
                path = Path(base) / name
                if source.parent == self.home / ".config" and name == source.name:
                    self.omit(path, "legacy nested duplicate of the application configuration")
                    self.remove_generated(destination / path.relative_to(source))
                elif name.casefold() in {part.casefold() for part in PRIVATE_COMPONENTS} or PRIVATE_NAMES.search(name):
                    self.omit(path, "private account data, dependency tree, cache, or backup directory")
                    self.remove_generated(destination / path.relative_to(source))
                elif path.is_symlink():
                    self.copy(path, destination / path.relative_to(source))
                else:
                    kept.append(name)
            dirs[:] = kept
            for name in files:
                path = Path(base) / name
                self.copy(path, destination / path.relative_to(source))

    def export(self):
        config = self.home / ".config"
        for item in sorted(config.iterdir()):
            if item.name in CONFIG_DIRS and item.is_dir():
                self.tree(item, self.repo / "config" / item.name)
            elif item.name in TOP_CONFIG_FILES and item.is_file():
                self.copy(item, self.repo / "config" / item.name)
            elif item.name not in {"VSCodium", "Antigravity IDE"}:
                self.omit(item, "browser/account profile, private application data, or unclassified application storage")
        for editor in ("VSCodium", "Antigravity IDE"):
            for name in ("settings.json", "keybindings.json"):
                self.copy(config / editor / "User" / name, self.repo / "config" / editor / "User" / name)
            self.tree(config / editor / "User/snippets", self.repo / "config" / editor / "User/snippets")
        # Previous cp-based installers created nested Ghostty directories. Keep
        # the user's saved file in the location Ghostty actually reads.
        ghostty_config = config / "ghostty/config"
        if not ghostty_config.is_file():
            ghostty_config = config / "ghostty/ghostty/config"
        self.copy(ghostty_config, self.repo / "config/ghostty/config")
        for name in HOME_FILES:
            self.copy(self.home / name, self.repo / "home" / name)
        for item in self.home.iterdir():
            if item.is_file() and item.suffix in {".py", ".sh"}:
                self.copy(item, self.repo / "home" / item.name)
        for source, destination in (
            (".local/bin", "home/.local/bin"),
            ("custom-scripts", "home/custom-scripts"),
            ("user_scripts", "home/user_scripts"),
            ("contained_apps", "home/contained_apps"),
            (".local/share/applications", "applications"),
            (".local/share/icons", "home/.local/share/icons"),
            (".local/share/fonts", "fonts"),
        ):
            self.tree(self.home / source, self.repo / destination)
        backgrounds = self.home / "Pictures/backgrounds"
        if backgrounds.is_dir():
            for item in sorted(backgrounds.iterdir()):
                if item.name in WALLPAPER_FILES:
                    self.copy(item, self.repo / "wallpapers" / item.name)
                else:
                    self.omit(item, "outside the approved five-wallpaper bundle")
        # Preserve the separate /usr/local helpers; do not replace the newer
        # theme script in the DWM data directory with a different PATH copy.
        self.tree(Path("/usr/local/bin"), self.repo / "system-config/usr/local/bin")
        for group in ("X11/xorg.conf.d", "keyd", "sysctl.d", "udev/rules.d", "modprobe.d",
                      "brave/policies/managed", "opt/chrome/policies/managed", "chromium/policies/managed"):
            self.tree(Path("/etc") / group, self.repo / "system-config/reference/etc" / group)
        if (self.repo / "config.h").is_file():
            self.copy(self.repo / "config.h", self.repo / "config.def.h", force=True)
        variables = config / "fish/fish_variables"
        if variables.is_file():
            safe = [line for line in variables.read_text().splitlines() if re.match(r"SETUVAR (?:--export )?(?:fish_color_|fish_pager_color_|_fish_abbr_)", line)]
            if safe:
                destination = self.repo / "config/fish/fish_variables"
                destination.write_text("# Shareable appearance/abbreviation variables only\n" + "\n".join(safe) + "\n")
            self.omit(variables, "universal credentials, initialization state, and machine-specific PATH excluded")
        for query, filename in (("-Qqe", "reference-explicit.txt"), ("-Qq", "reference-installed.txt"), ("-Qmq", "reference-foreign.txt")):
            if shutil.which("pacman"):
                result = subprocess.run(["pacman", query], text=True, capture_output=True)
                if result.returncode == 0:
                    (self.repo / "packages" / filename).write_text("# Reference inventory; not installed automatically.\n" + result.stdout)
        if shutil.which("dconf"):
            result = subprocess.run(["dconf", "dump", "/org/gnome/desktop/interface/"], text=True, capture_output=True)
            if result.returncode == 0 and result.stdout.strip() and not credential_reason(result.stdout):
                destination = self.repo / "config/dconf/interface.ini"
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(result.stdout)
        manifest = {
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "source_home": str(self.home),
            "included": sorted(self.included, key=lambda row: row["destination"]),
            "excluded": sorted(self.excluded, key=lambda row: row["source"]),
            "policy": "Shareable settings/code/assets only; no credentials, browser profiles, account databases, histories, caches, or application binaries.",
        }
        (self.repo / "snapshot-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        print(f"Snapshot: {len(self.included)} files/links recorded; {len(self.excluded)} private/runtime items excluded.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    Snapshot(args.home, args.repo).export()


if __name__ == "__main__":
    main()
