#!/usr/bin/env python3
"""
mechvibes2wayclick.py — turn a Mechvibes sound-pack config.json into a
Wayclick-compatible config.json.

Why Python instead of bash:
  * config.json is nested JSON (defines / definitions / timing arrays)
  * V1 and V2 packs use different schemas and key naming
  * single-sound packs need precise audio slicing with ffmpeg

Supported input:
  * Mechvibes V1 "multi"    defines: {keycode: "file.ogg"}
  * Mechvibes V1 "single"   defines: {keycode: [start_ms, end_ms]}, sound: "file.ogg"
  * Mechvibes V2 "multi"    definitions: {KeyA: {audio_file, timing}}
  * Mechvibes V2 "single"   definitions: {KeyA: {timing}}, audio_file: "file.ogg"
  * An already-Wayclick config (mappings/defaults) is passed through

Mouse packs:
  MouseLeft/Right/Middle/4-8 become Linux BTN_* codes 272-279.
  Mouse-wheel sounds are skipped because Wayclick ignores wheel events.
  Use --merge-mouse to add a mouse pack's buttons to an existing keyboard
  pack, so you do not have to switch packs to get both sounds.

Output keeps the original Mechvibes fields and adds Wayclick's
top-level "mappings" and "defaults" keys, so the pack stays usable in
both apps.

Examples:
  python3 mechvibes2wayclick.py ~/Downloads/TypeWriter/config.json
  python3 mechvibes2wayclick.py ~/Downloads/TypeWriter/config.json --in-place
  python3 mechvibes2wayclick.py ~/Downloads/TypeWriter/config.json \\
      -o ~/.config/wayclick/TypeWriter/config.json
  python3 mechvibes2wayclick.py pack/config.json --allow-missing

Requires: python3, and ffmpeg only for packs that use timed slices.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any, NoReturn

# --- Linux evdev key codes used by Wayclick --------------------------------

W3C_TO_EVDEV: dict[str, int] = {
    "Escape": 1,
    "Digit1": 2, "Digit2": 3, "Digit3": 4, "Digit4": 5, "Digit5": 6,
    "Digit6": 7, "Digit7": 8, "Digit8": 9, "Digit9": 10, "Digit0": 11,
    "Minus": 12, "Equal": 13, "Backspace": 14, "Tab": 15,
    "KeyQ": 16, "KeyW": 17, "KeyE": 18, "KeyR": 19, "KeyT": 20,
    "KeyY": 21, "KeyU": 22, "KeyI": 23, "KeyO": 24, "KeyP": 25,
    "BracketLeft": 26, "BracketRight": 27, "Enter": 28, "ControlLeft": 29,
    "KeyA": 30, "KeyS": 31, "KeyD": 32, "KeyF": 33, "KeyG": 34,
    "KeyH": 35, "KeyJ": 36, "KeyK": 37, "KeyL": 38,
    "Semicolon": 39, "Quote": 40, "Backquote": 41, "ShiftLeft": 42,
    "Backslash": 43,
    "KeyZ": 44, "KeyX": 45, "KeyC": 46, "KeyV": 47, "KeyB": 48,
    "KeyN": 49, "KeyM": 50, "Comma": 51, "Period": 52, "Slash": 53,
    "ShiftRight": 54, "NumpadMultiply": 55, "AltLeft": 56, "Space": 57,
    "CapsLock": 58,
    "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64,
    "F7": 65, "F8": 66, "F9": 67, "F10": 68, "NumLock": 69,
    "ScrollLock": 70,
    "Numpad7": 71, "Numpad8": 72, "Numpad9": 73, "NumpadSubtract": 74,
    "Numpad4": 75, "Numpad5": 76, "Numpad6": 77, "NumpadAdd": 78,
    "Numpad1": 79, "Numpad2": 80, "Numpad3": 81, "Numpad0": 82,
    "NumpadDecimal": 83, "IntlBackslash": 86, "F11": 87, "F12": 88,
    "IntlRo": 89, "Convert": 92, "KanaMode": 93, "NonConvert": 94,
    "NumpadEnter": 96, "ControlRight": 97, "NumpadDivide": 98,
    "PrintScreen": 99, "AltRight": 100, "Home": 102, "ArrowUp": 103,
    "PageUp": 104, "ArrowLeft": 105, "ArrowRight": 106, "End": 107,
    "ArrowDown": 108, "PageDown": 109, "Insert": 110, "Delete": 111,
    "AudioVolumeMute": 113, "AudioVolumeDown": 114, "AudioVolumeUp": 115,
    "Power": 116, "NumpadEqual": 117, "Pause": 119, "NumpadComma": 121,
    "Lang1": 122, "Lang2": 123, "IntlYen": 124,
    "MetaLeft": 125, "MetaRight": 126, "ContextMenu": 127,
    # Mouse buttons (Linux BTN_* codes)
    "MouseLeft": 272, "MouseRight": 273, "MouseMiddle": 274,
    "Mouse4": 275, "Mouse5": 276, "Mouse6": 277, "Mouse7": 278, "Mouse8": 279,
}
_W3C_LOOKUP = {name.casefold(): code for name, code in W3C_TO_EVDEV.items()}

# Main alphanumeric rows. Used to pick pleasant defaults for unmapped keys.
_TYPING_CODES = set(range(2, 14)) | set(range(16, 28)) | set(range(30, 54))

# Linux BTN_* codes: left, right, middle, side, extra, forward, back, task.
MOUSE_CODES = set(range(272, 280))

# Wayclick listens to EV_KEY only, so wheel codes can never fire.
_WHEEL_KEYS = {"mousewheelup", "mousewheeldown", "mousewheelleft", "mousewheelright"}


class ConversionError(Exception):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr, flush=True)


def fail(message: str) -> NoReturn:
    print(f"[ERROR] {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def clean_audio_name(value: Any) -> str | None:
    """Normalise a Mechvibes audio path for Wayclick."""
    if not isinstance(value, str):
        return None
    name = value.strip().replace("\\", "/")
    if not name or name.casefold() in {"null", "none"}:
        return None
    if name.startswith("./"):
        name = name[2:]
    return name


def parse_keycode(value: Any) -> int | None:
    try:
        code = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return code if code >= 0 else None


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def parse_timing(value: Any) -> list[tuple[float, float]]:
    """Return [start_ms, end_ms] pairs from any supported timing shape."""
    if value is None:
        return []

    if (
        isinstance(value, (list, tuple))
        and len(value) == 2
        and _is_number(value[0])
        and _is_number(value[1])
    ):
        return [(float(value[0]), float(value[1]))]

    if isinstance(value, dict):
        start = value.get("start")
        end = value.get("end")
        if _is_number(start) and _is_number(end):
            return [(float(start), float(end))]
        value = value.get("timing")

    if isinstance(value, (list, tuple)):
        pairs: list[tuple[float, float]] = []
        for item in value:
            if (
                isinstance(item, (list, tuple))
                and len(item) == 2
                and _is_number(item[0])
                and _is_number(item[1])
            ):
                pairs.append((float(item[0]), float(item[1])))
        return pairs

    return []


def first_press_segment(timing: Any) -> tuple[float, float] | None:
    """Wayclick has no key-release event: use the first (press) segment."""
    pairs = parse_timing(timing)
    if not pairs:
        return None
    start, end = pairs[0]
    if start < 0 or end <= start:
        return None
    return start, end


def choose_defaults(mappings: dict[str, str], limit: int) -> list[str]:
    """Pick a few typing sounds for keys the pack does not define."""
    ordered: list[str] = []
    typing = [
        value
        for key, value in sorted(mappings.items(), key=lambda kv: int(kv[0]))
        if int(key) in _TYPING_CODES
    ]
    pool = typing or [value for _, value in sorted(mappings.items(), key=lambda kv: int(kv[0]))]
    for value in pool:
        if value not in ordered:
            ordered.append(value)
            if len(ordered) >= limit:
                break
    return ordered


def detect_format(config: dict[str, Any]) -> str:
    if isinstance(config.get("mappings"), dict) and not config.get("defines"):
        return "wayclick"
    if isinstance(config.get("definitions"), dict) or isinstance(config.get("defs"), dict):
        return "v2"
    if isinstance(config.get("defines"), dict):
        return "v1"
    if config.get("sound") or config.get("audio_file"):
        return "v1"
    return "unknown"


class Converter:
    def __init__(
        self,
        config: dict[str, Any],
        config_path: Path,
        asset_dir: Path,
        args: argparse.Namespace,
    ):
        self.config = config
        self.source_dir = config_path.parent  # where the pack's audio lives
        self.asset_dir = asset_dir            # where the new config.json will live
        self.args = args
        self.slices_dir = self.asset_dir / "wayclick_slices"
        self.slice_cache: dict[tuple[str, float, float], str] = {}
        self.made_slices: list[str] = []
        self.skipped_sources: list[str] = []

    # -- audio helpers ------------------------------------------------------

    def _slice_path(self, source: str, start: float, end: float) -> Path:
        key = (source, start, end)
        cached = self.slice_cache.get(key)
        if cached:
            return self.asset_dir / cached

        stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(source).stem) or "clip"
        tag = f"{start:g}_{end:g}".replace(".", "p").replace("-", "m")
        digest = hashlib.sha1(f"{source}:{start}:{end}".encode()).hexdigest()[:8]
        name = f"{stem}__{tag}__{digest}.wav"
        out = self.slices_dir / name
        rel = out.relative_to(self.asset_dir).as_posix()
        self.slice_cache[key] = rel
        return out

    def slice_audio(self, source: str, start: float, end: float) -> str | None:
        src = self.source_dir / source
        if not src.is_file():
            warn(f"source audio not found: {source}")
            if source not in self.skipped_sources:
                self.skipped_sources.append(source)
            return None

        dst = self._slice_path(source, start, end)
        if dst.is_file() and dst.stat().st_size > 0:
            return dst.relative_to(self.asset_dir).as_posix()

        if not self.args.allow_missing and shutil.which("ffmpeg") is None:
            fail(
                "ffmpeg is required to slice timed Mechvibes sounds. "
                "Install it (sudo apt install ffmpeg) and retry."
            )
        if shutil.which("ffmpeg") is None:
            warn(f"ffmpeg missing, cannot slice {source} [{start:g}, {end:g}] ms")
            return None

        self.slices_dir.mkdir(parents=True, exist_ok=True)
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(src),
            "-ss", f"{start / 1000:.6f}",
            "-t", f"{(end - start) / 1000:.6f}",
            "-vn", "-c:a", "pcm_s16le",
            str(dst),
        ]
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            warn(f"ffmpeg failed for {source} [{start:g}, {end:g}] ms: {exc}")
            dst.unlink(missing_ok=True)
            return None

        if dst.is_file() and dst.stat().st_size > 0:
            rel = dst.relative_to(self.asset_dir).as_posix()
            if rel not in self.made_slices:
                self.made_slices.append(rel)
            return rel
        return None

    # -- Mechvibes V1 -------------------------------------------------------

    def convert_v1(self) -> tuple[dict[str, str], list[str]]:
        defines = self.config.get("defines") or {}
        values = [v for v in defines.values() if v not in (None, "", [])]
        method = str(self.config.get("key_define_type", "")).lower()
        values_are_strings = bool(values) and all(isinstance(v, str) for v in values)
        values_are_timings = bool(values) and all(
            isinstance(v, (list, tuple)) for v in values
        )

        # Trust the actual value type first: some old packs mislabel the method.
        if values_are_strings:
            multi = True
        elif values_are_timings:
            multi = False
        elif method == "single":
            multi = False
        else:
            multi = True  # safest fallback for old multi packs

        mappings: dict[str, str] = {}
        default_audio = clean_audio_name(self.config.get("sound"))

        for raw_code, value in defines.items():
            code = parse_keycode(raw_code)
            if code is None:
                warn(f"skipping non-numeric V1 key code: {raw_code!r}")
                continue

            if multi:
                audio = clean_audio_name(value)
                if audio is None:
                    continue  # null = intentionally silent
                mappings[str(code)] = audio
                continue

            segment = first_press_segment(value)
            if segment is None:
                warn(f"skipping key {code}: invalid timing {value!r}")
                continue
            if not default_audio:
                warn(f"skipping key {code}: single pack has no 'sound' file")
                continue
            sliced = self.slice_audio(default_audio, *segment)
            if sliced:
                mappings[str(code)] = sliced

        defaults = choose_defaults(mappings, self.args.max_defaults)
        if not defaults and default_audio:
            defaults = [default_audio]
            if not mappings:
                warn(
                    "no timed definitions found; every key will play the whole "
                    f"'{default_audio}' file"
                )
        return mappings, defaults

    # -- Mechvibes V2 -------------------------------------------------------

    def convert_v2(self) -> tuple[dict[str, str], list[str]]:
        definitions = self.config.get("definitions") or self.config.get("defs") or {}
        default_audio = clean_audio_name(
            self.config.get("audio_file") or self.config.get("sound")
        )
        method = str(self.config.get("definition_method", "")).lower()

        mappings: dict[str, str] = {}
        unknown: list[str] = []
        wheels: list[str] = []

        for key_name, entry in definitions.items():
            folded = str(key_name).strip().casefold()

            if folded in _WHEEL_KEYS:
                wheels.append(str(key_name))
                continue

            code = _W3C_LOOKUP.get(folded)
            if code is None:
                unknown.append(str(key_name))
                continue

            audio: str | None = None
            timing: Any = None

            if isinstance(entry, dict):
                audio = clean_audio_name(entry.get("audio_file")) or default_audio
                timing = entry.get("timing")
            elif isinstance(entry, (list, tuple)):
                audio = default_audio
                timing = entry
            elif isinstance(entry, str):
                audio = clean_audio_name(entry)
            else:
                warn(f"skipping {key_name}: unsupported definition {entry!r}")
                continue

            if not audio:
                warn(f"skipping {key_name}: no audio_file and no pack audio_file")
                continue

            segment = first_press_segment(timing)
            if segment:
                sliced = self.slice_audio(audio, *segment)
                if sliced:
                    mappings[str(code)] = sliced
            else:
                # multi packs often map straight to a file; single packs with
                # no timing for this key play the whole file.
                mappings[str(code)] = audio

        if unknown:
            warn(
                "skipped key names I do not know how to map to Linux key codes: "
                + ", ".join(sorted(unknown)[:12])
                + (" ..." if len(unknown) > 12 else "")
            )
        if wheels:
            warn(
                "Wayclick only reads key events, so mouse-wheel sounds are skipped: "
                + ", ".join(sorted(wheels))
            )

        if method not in {"single", "multi"} and not default_audio and not mappings:
            warn("could not infer V2 definition method")

        defaults = choose_defaults(mappings, self.args.max_defaults)
        if not defaults and default_audio:
            defaults = [default_audio]
        return mappings, defaults

    # -- already Wayclick ---------------------------------------------------

    def convert_wayclick(self) -> tuple[dict[str, str], list[str]]:
        raw = self.config.get("mappings") or {}
        mappings: dict[str, str] = {}
        for raw_code, value in raw.items():
            code = parse_keycode(raw_code)
            audio = clean_audio_name(value)
            if code is None or audio is None:
                warn(f"skipping invalid Wayclick mapping: {raw_code!r} -> {value!r}")
                continue
            mappings[str(code)] = audio
        defaults = [
            audio
            for value in (self.config.get("defaults") or [])
            if (audio := clean_audio_name(value))
        ]
        return mappings, defaults


def resolve_output(config_path: Path, args: argparse.Namespace) -> Path:
    if args.in_place:
        if args.output:
            fail("--in-place and --output cannot be used together")
        return config_path

    if args.output:
        out = Path(args.output).expanduser()
        if out.is_dir() or args.output.endswith(os.sep):
            out = out / "config.json"
        return out

    return config_path.with_name("config.wayclick.json")


def backup_existing(path: Path) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.bak-{stamp}")
    counter = 1
    while backup.exists():
        backup = path.with_name(f"{path.name}.bak-{stamp}-{counter}")
        counter += 1
    shutil.copy2(path, backup)
    return backup


def write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
    )
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def merge_mouse_into_pack(
    source_dir: Path,
    mappings: dict[str, str],
    target_dir: Path,
    args: argparse.Namespace,
) -> tuple[Path, list[str]]:
    """Copy mouse-button audio into an existing Wayclick pack and merge codes."""
    target_cfg = target_dir / "config.json"
    if not target_dir.is_dir():
        fail(f"target pack folder does not exist: {target_dir}")
    if not target_cfg.is_file():
        fail(f"target pack has no config.json: {target_cfg}")
    if target_dir.resolve() == source_dir.resolve():
        fail("--merge-mouse target must be a different pack folder")

    try:
        with target_cfg.open("r", encoding="utf-8-sig") as handle:
            target = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read target config {target_cfg}: {exc}")

    if not isinstance(target, dict) or not isinstance(target.get("mappings"), dict):
        fail(
            f"{target_cfg} is not Wayclick-ready (it has no 'mappings'). "
            "Convert that pack with this script first."
        )

    mouse = {
        str(code): rel
        for code, rel in mappings.items()
        if int(code) in MOUSE_CODES
    }
    if not mouse:
        fail(
            "this pack defines no mouse-button sounds (MouseLeft, MouseRight, "
            "MouseMiddle, Mouse4-Mouse8). Mouse-wheel-only packs cannot work "
            "because Wayclick ignores wheel events."
        )

    copied: list[str] = []
    for code, rel in sorted(mouse.items(), key=lambda item: int(item[0])):
        rel_path = Path(rel)
        if rel_path.is_absolute() or ".." in rel_path.parts:
            warn(f"skipping unsafe audio path for mouse code {code}: {rel}")
            continue
        src = source_dir / rel_path
        if not src.is_file():
            warn(f"mouse audio not found, skipping code {code}: {rel}")
            continue
        dst = target_dir / "mouse" / rel_path
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        target["mappings"][code] = (Path("mouse") / rel_path).as_posix()
        copied.append(code)

    if not copied:
        fail("no mouse sounds could be copied into the target pack")

    backup = backup_existing(target_cfg)
    write_json_atomic(target_cfg, target)
    if not args.quiet:
        warn(f"target config backup: {backup}")
    return target_dir, copied


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a Mechvibes sound-pack config.json to Wayclick format.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  %(prog)s ~/Downloads/TypeWriter/config.json\n"
            "  %(prog)s ~/Downloads/TypeWriter --in-place\n"
            "  %(prog)s ~/Downloads/TypeWriter/config.json --in-place\n"
            "  %(prog)s pack/config.json -o ~/.config/wayclick/MyPack/config.json\n"
            "  %(prog)s ~/Downloads/MousePack --merge-mouse \\\n"
            "      ~/.config/wayclick/MyKeyboardPack\n"
            "\n"
            "The output keeps the original Mechvibes fields and adds the\n"
            "'mappings' and 'defaults' keys Wayclick needs, so nothing is lost."
        ),
    )
    parser.add_argument(
        "config",
        type=Path,
        help="path to the Mechvibes config.json (or its containing folder)",
    )
    parser.add_argument(
        "-o", "--output",
        help="output file (or an existing directory, which gets config.json); "
             "default: config.wayclick.json next to the input",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="overwrite the input config.json (a timestamped backup is made)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output file (a timestamped backup is made)",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="write the config even if referenced audio files are missing",
    )
    parser.add_argument(
        "--merge-mouse",
        metavar="TARGET_PACK_DIR",
        help="merge only this pack's mouse-button sounds into an existing "
             "Wayclick pack folder (implies --in-place for this pack)",
    )
    parser.add_argument(
        "--max-defaults",
        type=int,
        default=8,
        metavar="N",
        help="maximum fallback sounds for unmapped keys (default: 8)",
    )
    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        help="only print warnings and errors",
    )
    args = parser.parse_args(argv)

    if args.max_defaults < 0:
        parser.error("--max-defaults must be 0 or greater")
    if args.merge_mouse:
        if args.output:
            parser.error("--merge-mouse cannot be combined with --output")
        args.in_place = True
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    config_path = args.config.expanduser().resolve()
    if config_path.is_dir():
        config_path = config_path / "config.json"

    if not config_path.is_file():
        fail(f"no such config file: {config_path}")

    merge_target_path: Path | None = None
    if args.merge_mouse:
        merge_target_path = Path(args.merge_mouse).expanduser().resolve()
        if merge_target_path == config_path.parent:
            fail("--merge-mouse target must be a different pack folder")
        if not (merge_target_path / "config.json").is_file():
            fail(
                f"target pack has no config.json: {merge_target_path / 'config.json'}"
            )

    try:
        with config_path.open("r", encoding="utf-8-sig") as handle:
            config = json.load(handle)
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {config_path}: line {exc.lineno}, column {exc.colno}: {exc.msg}")
    except OSError as exc:
        fail(f"cannot read {config_path}: {exc}")

    if not isinstance(config, dict):
        fail("the top-level JSON value must be an object")

    fmt = detect_format(config)
    if fmt == "unknown":
        fail(
            "unrecognised sound-pack format: expected 'defines' (V1), "
            "'definitions'/'defs' (V2), or 'mappings' (Wayclick)"
        )

    output_path = resolve_output(config_path, args)
    converter = Converter(config, config_path, output_path.parent, args)

    if fmt == "v1":
        mappings, defaults = converter.convert_v1()
    elif fmt == "v2":
        mappings, defaults = converter.convert_v2()
    else:
        mappings, defaults = converter.convert_wayclick()

    if not mappings and not defaults:
        fail("conversion produced no playable sounds; check the pack's config.json")

    # Reference check: mappings/defaults are resolved from the config's folder.
    referenced = set(mappings.values()) | set(defaults)
    missing = sorted(
        name for name in referenced
        if not (output_path.parent / name).is_file()
    )
    if missing:
        for name in missing:
            warn(f"referenced audio is missing: {name}")
        if not args.allow_missing:
            fail(
                f"{len(missing)} referenced audio file(s) are missing. "
                "Fix the pack, or pass --allow-missing to write it anyway."
            )
    if converter.skipped_sources:
        for name in sorted(set(converter.skipped_sources)):
            warn(f"source audio missing, keys using it were skipped: {name}")

    output_is_elsewhere = output_path.parent.resolve() != config_path.parent.resolve()
    if output_is_elsewhere and not args.quiet:
        warn(
            f"output is outside the source pack folder ({config_path.parent}); "
            "only sliced audio is written there, so copy the pack's other audio "
            "files next to the output config (or use --in-place)."
        )

    if output_path.exists():
        if not (args.in_place or args.force):
            fail(
                f"output already exists: {output_path}\n"
                "Use --force, --in-place, or -o with a different path."
            )
        backup = backup_existing(output_path)
        if not args.quiet:
            log(f"Backup:  {backup}")

    # Keep every original Mechvibes field and add Wayclick's two keys.
    output = dict(config)
    output["mappings"] = mappings
    output["defaults"] = defaults
    write_json_atomic(output_path, output)

    merged_target: Path | None = None
    merged_codes: list[str] = []
    if merge_target_path is not None:
        merged_target, merged_codes = merge_mouse_into_pack(
            output_path.parent,
            mappings,
            merge_target_path,
            args,
        )

    if not args.quiet:
        labels = {
            "v1": "Mechvibes V1",
            "v2": "Mechvibes V2",
            "wayclick": "Wayclick (already compatible)",
        }
        pack_name = config.get("name") or config_path.parent.name
        log(f"Format:  {labels[fmt]}")
        log(f"Pack:    {pack_name}")
        log(f"Mapped:  {len(mappings)} key(s)")
        log(f"Defaults:{' ' + str(len(defaults)) + ' sound(s)' if defaults else ' none'}")
        if defaults:
            shown = ", ".join(defaults[:6])
            log(f"         {shown}{' ...' if len(defaults) > 6 else ''}")
        log(f"Slices:  {len(converter.made_slices)} created")
        if converter.made_slices:
            log(f"         keep 'wayclick_slices/' next to config.json")
        log(f"Output:  {output_path}")
        log("")
        if merged_target is not None:
            log(f"Mouse:   merged {len(merged_codes)} button(s) into {merged_target}")
            log("If that pack is active:  wayclick reload")
            log("Otherwise select it in the Wayclick TUI (Audio Pack).")
        elif output_path.name == "config.json" and "wayclick" in output_path.parts:
            log("Apply it with:  wayclick reload")
        else:
            log("To install this pack in Wayclick, keep the whole folder:")
            log(f'  cp -r "{output_path.parent}" ~/.config/wayclick/<PACK_FOLDER>')
            log("  wayclick reload")
            log("(config.json must sit next to the audio files and wayclick_slices/)")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)
