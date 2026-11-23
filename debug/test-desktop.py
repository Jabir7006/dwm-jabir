#!/usr/bin/env python3
"""Desktop snapshot/launcher tests; optional GUI smoke tests use a private Xvfb.

Run only after approving test execution:
    python3 debug/test-desktop.py
Set DWM_TEST_XVFB to a temporary Xvfb binary when Xvfb is not installed.
No VM, real input device, user audio service, or system package is modified.
"""

import configparser
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("desktop_snapshot", REPO / "scripts/snapshot-desktop.py")
snapshot_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot_module)


class DesktopFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dwm-desktop-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C.UTF-8",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_RUNTIME_DIR": str(self.root / "runtime"), "SHELL": "/bin/bash",
            "LIBGL_ALWAYS_SOFTWARE": "1",
        }
        (self.root / "runtime").mkdir(mode=0o700)

    def command(self, name, text):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + text)
        path.chmod(0o755)
        return path

    def seed_config(self, name):
        target = self.home / ".config" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(REPO / "config" / name, target, dirs_exist_ok=True)
        return target


class DesktopTests(DesktopFixture):
    def test_snapshot_keeps_preferences_but_clears_credentials(self):
        repo = self.root / "repo"
        repo.mkdir()
        source = self.home / "settings.json"
        private = "sk-" + "x" * 32
        source.write_text(json.dumps({"theme": "ristretto", "apiKey": private, "password": 123456, "otherPassword": "p$ssword", "keyFromEnv": "{env:MY_KEY}"}))
        exporter = snapshot_module.Snapshot(self.home, repo)
        target = repo / "config/settings.json"
        exporter.copy(source, target)
        saved = json.loads(target.read_text())
        self.assertEqual(saved["theme"], "ristretto")
        self.assertEqual(saved["apiKey"], "")
        self.assertEqual(saved["password"], "")
        self.assertEqual(saved["otherPassword"], "")
        self.assertEqual(saved["keyFromEnv"], "{env:MY_KEY}")
        self.assertNotIn(private, target.read_text())

    def test_jsonc_comments_and_urls_do_not_break_safe_export(self):
        private = "sk-" + "a" * 32
        source = ('{\n// saved editor preferences\n"url": "https://example.com/a//b",\n'
                  '"theme": "ristretto",\n"apiKey": "' + private + '", // trailing comment\n}\n')
        saved = json.loads(snapshot_module.sanitized_json(source.encode()))
        self.assertEqual(saved["url"], "https://example.com/a//b")
        self.assertEqual(saved["theme"], "ristretto")
        self.assertEqual(saved["apiKey"], "")

    def test_scanner_distinguishes_key_literals_from_runtime_lookups(self):
        self.assertTrue(snapshot_module.credential_reason('API_KEY = "' + 'a' * 32 + '"'))
        self.assertFalse(snapshot_module.credential_reason('API_KEY = os.getenv("OPENWEATHER_API_KEY", "")'))
        self.assertFalse(snapshot_module.credential_reason('api_key = args.api_key if args.api_key else API_KEY'))
        self.assertFalse(snapshot_module.credential_reason('API_KEY = "your_api_key"'))

    def test_dependency_and_authentication_directories_are_excluded(self):
        repo = self.root / "repo"
        repo.mkdir()
        source = self.home / "custom-scripts"
        (source / ".venv").mkdir(parents=True)
        (source / ".venv/secret.json").write_text("private runtime\n")
        (source / "tool.py").write_text("print('public source')\n")
        (source / "auth.json").write_text("private login\n")
        exporter = snapshot_module.Snapshot(self.home, repo)
        exporter.tree(source, repo / "home/custom-scripts")
        self.assertTrue((repo / "home/custom-scripts/tool.py").is_file())
        self.assertFalse((repo / "home/custom-scripts/.venv").exists())
        self.assertFalse((repo / "home/custom-scripts/auth.json").exists())

    def test_required_desktop_source_and_assets_are_saved(self):
        for relative in ("config/fastfetch/config.jsonc", "config/dwm-titus/theme-env.sh",
                         "home/.fehbg", "home/minitop.py", "home/.local/bin/app-manager",
                         "home/contained_apps/uv/wayclick/runner.py",
                         "home/.local/share/icons/Papirus-Dynamic/index.theme"):
            self.assertTrue((REPO / relative).is_file(), relative)
        self.assertEqual((REPO / "config/polybar/profile").read_text().strip(), "laptop")

    def test_unwanted_rofi_entries_are_hidden(self):
        for filename in ("cineo.desktop", "deepai-code.desktop", "org.deepai.code.desktop",
                         "Opencode.desktop", "Warp.desktop", "ai.opencode.desktop.desktop",
                         "com.cloudflare.WarpTaskbar.desktop"):
            entry = configparser.ConfigParser(interpolation=None, strict=False)
            entry.read(REPO / "applications" / filename)
            self.assertTrue(entry.getboolean("Desktop Entry", "NoDisplay"), filename)

    def test_graphical_profile_exports_user_script_paths_once(self):
        target = self.home / ".profile"
        target.write_text((REPO / "home/.profile").read_text())
        result = subprocess.run(["bash", "-c", '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s" "$PATH"'], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = result.stdout.split(":")
        self.assertEqual(paths.count(str(self.home / ".local/bin")), 1)
        self.assertEqual(paths.count(str(self.home / "custom-scripts")), 1)

    def test_app_manager_uses_an_installed_browser_when_default_is_missing(self):
        self.command("xdg-settings", "printf 'missing-browser.desktop\\n'\n")
        self.command("google-chrome-stable", 'printf "%s\\n" "$@" > "$HOME/browser-args"\n')
        result = subprocess.run(["bash", str(REPO / "home/.local/bin/app-manager"), "--run-webapp", "https://example.com", "WebApp.float"], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--app=https://example.com", (self.home / "browser-args").read_text())

    def test_missing_fnm_does_not_print_startup_errors(self):
        fish = shutil.which("fish")
        if not fish:
            self.skipTest("fish is not installed")
        self.seed_config("fish")
        for optional in ("fnm", "thefuck", "fastfetch", "starship", "direnv", "zoxide"):
            self.command(optional, "exit 0\n")
        # Remove fnm from the fixture PATH; the source guard must also work when
        # the command is absent. --no-config plus an explicit source avoids host globals.
        (self.bin / "fnm").unlink()
        result = subprocess.run([fish, "--no-config", "-c", f'source "{REPO}/config/fish/conf.d/fnm.fish"'], env={**self.env, "PATH": str(self.bin)}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Unknown command", result.stderr)

    def test_native_mouse_and_touchpad_have_separate_button_mapping(self):
        marker = self.home / ".config/dwm-titus/input-settings-enabled"
        marker.parent.mkdir(parents=True)
        marker.write_text("yes\n")
        self.command("systemd-detect-virt", "exit 1\n")
        self.command("xinput", '''
case "$1" in
  list) printf 'Touchpad id=11 [slave pointer]\\nMouse id=12 [slave pointer]\\nTablet id=13 [slave pointer]\\n' ;;
  list-props)
    printf 'libinput Left Handed Enabled (300): 0\\n'
    [[ "$2" != 11 ]] || printf 'libinput Tapping Enabled (301): 1\\n'
    [[ "$2" != 13 ]] || printf 'libinput Calibration Matrix (302): 1\\n'
    ;;
  set-prop) printf '%s\\n' "$*" >> "$HOME/input-actions" ;;
esac
''')
        result = subprocess.run(["bash", str(REPO / "scripts/input-setup.sh")], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = (self.home / "input-actions").read_text()
        self.assertIn("set-prop 11 libinput Left Handed Enabled 0", actions)
        self.assertIn("set-prop 12 libinput Left Handed Enabled 1", actions)
        self.assertNotIn("set-prop 13", actions)

    def test_virtual_input_does_not_reverse_host_mapping_again(self):
        marker = self.home / ".config/dwm-titus/input-settings-enabled"
        marker.parent.mkdir(parents=True)
        marker.write_text("yes\n")
        self.command("systemd-detect-virt", "exit 0\n")
        self.command("xinput", 'touch "$HOME/input-was-changed"\n')
        result = subprocess.run(["bash", str(REPO / "scripts/input-setup.sh")], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "input-was-changed").exists())

    def test_saved_polybar_layout_survives_missing_vm_hardware(self):
        self.seed_config("polybar")
        fake_sys = self.root / "sys"
        (fake_sys / "class/power_supply").mkdir(parents=True)
        (fake_sys / "class/backlight").mkdir(parents=True)
        script = self.root / "launch.sh"
        script.write_text((REPO / "config/polybar/launch.sh").read_text().replace("/sys/class/", str(fake_sys / "class") + "/"))
        self.command("pgrep", "exit 1\n")
        self.command("xrandr", "printf 'Virtual-1 connected primary 1280x720\\n'\n")
        self.command("xdotool", "exit 0\n")
        self.command("polybar", 'printf "%s\\n" "$*" >> "$HOME/polybar-args"\n')
        result = subprocess.run(["bash", str(script)], env={**self.env, "DISPLAY": ":123"}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime = next((self.home / ".cache/dwm-jabir/polybar").glob("config-*.ini"))
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.read_string("[global]\n" + runtime.read_text())
        self.assertEqual(parser["bar/main"]["modules-center"].strip(), "date reminder")
        self.assertEqual(parser["bar/main"]["modules-right"].split(), ["pulseaudio", "warp", "sink-toggle", "tray", "powermenu"])


class WallpaperTests(DesktopFixture):
    def setUp(self):
        super().setUp()
        self.user_bin = self.home / ".local/bin"
        self.user_bin.mkdir(parents=True)
        for name in ("wallpaper-apply", "wallpaper-picker.sh", "wallpaper-random.sh"):
            shutil.copy2(REPO / "home/.local/bin" / name, self.user_bin / name)
        self.walls = self.home / "Pictures/backgrounds"
        self.walls.mkdir(parents=True)
        self.image = self.walls / "Jabir's wallpaper.webp"
        self.image.write_bytes(b"mock image")
        themes = self.home / ".config/dwm-titus/themes.toml"
        themes.parent.mkdir(parents=True)
        themes.write_text('[active]\ntheme = "ristretto"\n')
        self.command("notify-send", "exit 0\n")
        self.command("feh", '''
printf 'image %s\\n' "$2" >> "$HOME/apply-events"
printf '%s' "$2" > "$HOME/selected-image"
printf '#!/bin/sh\\nfeh --no-fehbg --bg-fill "%s"\\n' "$2" > "$HOME/.fehbg"
''')

    def palette_helper(self, body):
        helper = self.user_bin / "theme-set-dynamic"
        helper.write_text("#!/bin/bash\n" + body)
        helper.chmod(0o755)

    def apply(self):
        return subprocess.run([str(self.user_bin / "wallpaper-apply"), str(self.image)], env=self.env, text=True, capture_output=True, timeout=10)

    def test_palette_failure_still_applies_and_saves_the_image(self):
        self.palette_helper('printf "palette failed\\n"; exit 1\n')
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / "selected-image").read_text(), str(self.image))
        self.assertIn(str(self.image), (self.home / ".fehbg").read_text())
        self.assertIn("palette failed", (self.home / ".cache/wallpaper-picker/apply.log").read_text())
        self.assertIn("palette update failed", result.stderr)

    def test_static_and_dynamic_palettes_never_repaint_the_image(self):
        self.palette_helper('printf "palette %s\\n" "$*" >> "$HOME/apply-events"\n')
        for active in ("ristretto", "dynamic"):
            with self.subTest(active=active):
                (self.home / ".config/dwm-titus/themes.toml").write_text(f'[active]\ntheme = "{active}"\n')
                (self.home / "apply-events").unlink(missing_ok=True)
                result = self.apply()
                self.assertEqual(result.returncode, 0, result.stderr)
                events = (self.home / "apply-events").read_text().splitlines()
                self.assertEqual(events[0], "image " + str(self.image))
                self.assertIn("--no-wallpaper", events[1])
                self.assertEqual("--stage-only" in events[1], active != "dynamic")
                self.assertEqual(len(events), 2)

    def test_feh_failure_preserves_selection_and_reports_failure(self):
        previous = '#!/bin/sh\n# previous selection\n'
        (self.home / ".fehbg").write_text(previous)
        self.command("feh", "exit 9\n")
        self.palette_helper('touch "$HOME/palette-ran"\n')
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / ".fehbg").read_text(), previous)
        self.assertFalse((self.home / "palette-ran").exists())

    def test_rapid_selections_finish_with_the_newer_image(self):
        self.palette_helper('printf "palette start\\n" >> "$HOME/apply-events"; sleep 0.2; printf "palette end\\n" >> "$HOME/apply-events"\n')
        first = subprocess.Popen([str(self.user_bin / "wallpaper-apply"), str(self.image)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(GraphicalSmokeTests.stop_process, first)
        for _ in range(100):
            if (self.home / "apply-events").exists():
                break
            time.sleep(0.01)
        newer = self.walls / "newer.webp"
        newer.write_bytes(b"mock newer image")
        second = subprocess.run([str(self.user_bin / "wallpaper-apply"), str(newer)], env=self.env, capture_output=True, text=True, timeout=10)
        _, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        events = (self.home / "apply-events").read_text().splitlines()
        self.assertEqual(events, ["image " + str(self.image), "palette start", "palette end", "image " + str(newer), "palette start", "palette end"])
        self.assertEqual((self.home / "selected-image").read_text(), str(newer))

    def test_picker_and_random_use_the_same_apply_path(self):
        self.palette_helper('exit 1\n')
        self.command("rofi", 'printf "%s\\n" "Jabir\'s wallpaper.webp"\n')
        self.command("nsxiv", 'printf "%s\\n" "$HOME/Pictures/backgrounds/Jabir\'s wallpaper.webp"\n')
        self.command("magick", "exit 1\n")
        for name, args in (("wallpaper-picker.sh", []), ("wallpaper-picker.sh", ["--nsxiv"]), ("wallpaper-random.sh", [])):
            with self.subTest(name=name, args=args):
                (self.home / "selected-image").unlink(missing_ok=True)
                result = subprocess.run([str(self.user_bin / name), *args], env=self.env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.home / "selected-image").read_text(), str(self.image))

    def test_bundle_has_five_small_images_and_keeps_ristretto(self):
        images = list((REPO / "wallpapers").iterdir())
        self.assertEqual({path.name for path in images}, set(snapshot_module.WALLPAPER_FILES))
        self.assertEqual(len(images), 5)
        self.assertIn("ristretto-3-industrial-moon.webp", {path.name for path in images})
        self.assertLess(sum(path.stat().st_size for path in images), 600 * 1024)


class GraphicalSmokeTests(DesktopFixture):
    def setUp(self):
        super().setUp()
        xvfb = os.environ.get("DWM_TEST_XVFB") or shutil.which("Xvfb")
        if not xvfb or not shutil.which("xdotool"):
            self.skipTest("Private GUI smoke tests require Xvfb and xdotool")
        display_number = next((number for number in range(97, 117) if not Path(f"/tmp/.X{number}-lock").exists()), None)
        if display_number is None:
            self.skipTest("No private test display is available")
        self.env["DISPLAY"] = f":{display_number}"
        self.xlog = (self.root / "xvfb.log").open("w")
        # Keep root-window state between short-lived feh/xprop clients. Without
        # this Xvfb resets when its last client exits, unlike a desktop with DWM.
        self.server = subprocess.Popen([xvfb, self.env["DISPLAY"], "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-noreset", "-ac"], env=self.env, stdout=self.xlog, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_process, self.server)
        self.addCleanup(self.xlog.close)
        for _ in range(50):
            if self.server.poll() is not None:
                self.fail("Private Xvfb could not start: " + (self.root / "xvfb.log").read_text())
            if Path(f"/tmp/.X11-unix/X{display_number}").exists():
                break
            time.sleep(0.1)

    @staticmethod
    def stop_process(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def mapped_window(self, pattern):
        for _ in range(100):
            result = subprocess.run(["xdotool", "search", "--onlyvisible", "--class", pattern], env=self.env, text=True, capture_output=True)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.splitlines()[0]
            time.sleep(0.1)
        self.fail("No visible test window mapped for " + pattern)

    def test_mpv_opens_a_visible_idle_window_with_saved_ui(self):
        mpv = shutil.which("mpv")
        if not mpv:
            self.skipTest("mpv is not installed")
        self.seed_config("mpv")
        log = (self.root / "mpv.log").open("w")
        self.addCleanup(log.close)
        player = subprocess.Popen([mpv, "--no-audio", "--no-terminal"], env=self.env, stdout=log, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_process, player)
        window = self.mapped_window("mpv")
        geometry = subprocess.check_output(["xdotool", "getwindowgeometry", "--shell", window], env=self.env, text=True)
        dimensions = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
        self.assertGreaterEqual(int(dimensions["WIDTH"]), 200)
        self.assertGreaterEqual(int(dimensions["HEIGHT"]), 150)
        self.assertIsNone(player.poll())

    def test_app_manager_opens_from_graphical_session_path(self):
        if not shutil.which("rofi"):
            self.skipTest("rofi is not installed")
        self.seed_config("rofi")
        user_bin = self.home / ".local/bin"
        user_bin.mkdir(parents=True)
        shutil.copy2(REPO / "home/.local/bin/app-manager", user_bin / "app-manager")
        (self.home / ".profile").write_text((REPO / "home/.profile").read_text())
        log = (self.root / "app-manager.log").open("w")
        self.addCleanup(log.close)
        manager = subprocess.Popen(["bash", "-c", '. "$HOME/.profile"; exec app-manager'], env=self.env, stdout=log, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_process, manager)
        window = self.mapped_window("Rofi")
        # Rofi closes on key-down; a synthetic key-up sent to the destroyed
        # window produces BadWindow even though the launcher worked correctly.
        subprocess.run(["xdotool", "keydown", "--window", window, "Escape"], env=self.env, check=True, capture_output=True)
        manager.wait(timeout=5)
        self.assertNotEqual(manager.returncode, 127)

    def test_carousel_selection_reaches_the_desktop_after_the_preview_closes(self):
        if not shutil.which("feh") or not shutil.which("xprop"):
            self.skipTest("Wallpaper GUI test requires feh and xprop")
        user_bin = self.home / ".local/bin"
        user_bin.mkdir(parents=True)
        shutil.copy2(REPO / "home/.local/bin/wallpaper-apply", user_bin / "wallpaper-apply")
        palette = user_bin / "theme-set-dynamic"
        palette.write_text("#!/bin/sh\necho 'mock palette failure' >&2\nexit 1\n")
        palette.chmod(0o755)
        self.command("notify-send", "exit 0\n")
        walls = self.home / "Pictures/backgrounds"
        walls.mkdir(parents=True)
        first = walls / "a.webp"
        second = walls / "b.webp"
        shutil.copy2(REPO / "wallpapers/ristretto-0-launch.webp", first)
        shutil.copy2(REPO / "wallpapers/ristretto-3-industrial-moon.webp", second)
        state = self.home / ".local/state/wallpaper-carousel/state"
        state.parent.mkdir(parents=True)
        for animations in ("off", "on"):
            with self.subTest(animations=animations):
                state.write_text(animations)
                subprocess.run(["feh", "--bg-fill", str(first)], env=self.env, check=True, capture_output=True)
                before = subprocess.check_output(["xprop", "-root", "_XROOTPMAP_ID"], env=self.env, text=True)
                failing_feh = self.command("feh", 'printf "%s" "$2" > "$HOME/attempted-image"; exit 9\n')
                log = (self.root / f"carousel-{animations}.log").open("w")
                self.addCleanup(log.close)
                carousel = subprocess.Popen(["/usr/bin/python3", str(REPO / "home/.local/bin/wallpaper-carousel")], env={**self.env, "GSK_RENDERER": "cairo"}, stdout=log, stderr=subprocess.STDOUT)
                self.addCleanup(self.stop_process, carousel)
                window = self.mapped_window("wallpaper-carousel")
                subprocess.run(["xdotool", "windowfocus", "--sync", window], env=self.env, check=True, capture_output=True)
                subprocess.run(["xdotool", "key", "End"], env=self.env, check=True, capture_output=True)
                subprocess.run(["xdotool", "key", "Return"], env=self.env, check=True, capture_output=True)
                for _ in range(100):
                    if "wallpaper-carousel: Could not apply" in (self.root / f"carousel-{animations}.log").read_text():
                        break
                    time.sleep(0.05)
                self.assertIsNone(carousel.poll(), "Carousel closed despite the failed wallpaper update")
                self.assertEqual((self.home / "attempted-image").read_text(), str(second))
                self.assertIn(str(first), (self.home / ".fehbg").read_text())
                failing_feh.unlink()
                subprocess.run(["xdotool", "key", "Return"], env=self.env, check=True, capture_output=True)
                carousel.wait(timeout=15)
                self.assertEqual(carousel.returncode, 0, (self.root / f"carousel-{animations}.log").read_text())
                time.sleep(0.3)
                self.assertIn(str(second), (self.home / ".fehbg").read_text())
                after = subprocess.check_output(["xprop", "-root", "_XROOTPMAP_ID"], env=self.env, text=True)
                self.assertNotEqual(before, after)


if __name__ == "__main__":
    unittest.main(verbosity=2)
