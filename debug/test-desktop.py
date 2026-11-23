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
        self.server = subprocess.Popen([xvfb, self.env["DISPLAY"], "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-ac"], env=self.env, stdout=self.xlog, stderr=subprocess.STDOUT)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
