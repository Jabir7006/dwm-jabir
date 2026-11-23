#!/usr/bin/env python3
"""Installer regressions with mocked privileged commands and an isolated home.

Run: python3 debug/test-installer.py
No packages, services, or files outside the temporary fixture are modified.
"""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / "install.sh").read_text()
FUNCTIONS, MAIN = SOURCE[SOURCE.index("ask_yes_no() {"):].split("# ── main", 1)
MAIN = MAIN[MAIN.index('echo ""'):].split("\nprepare_user_paths\n", 1)[0]
# Simulate CPU capabilities without depending on the host CPU.
FUNCTIONS = FUNCTIONS.replace("/lib/ld-linux-x86-64.so.2 --help", "mock_loader")

MOCKS = r'''
info() { printf 'INFO %s\n' "$*"; }
ok() { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >> "$EVENTS"; }
KEY_READY=0
sudo() {
  log "sudo $*"
  local cmd="$1"; shift
  case "$cmd" in
    pacman-key)
      [[ "$*" != *--recv-keys* || "$KEY_FAIL" == 0 ]] || return 1
      [[ "$*" != *--lsign-key* ]] || KEY_READY=1
      ;;
    pacman) pacman "$@" ;;
    cp|install|tee|chown|chmod|find) command "$cmd" "$@" ;;
    *) return 1 ;;
  esac
}
pacman() {
  log "pacman $*"
  if [[ "$1" == --config ]]; then
    [[ "$KEY_READY" == 1 ]] || return 1
    ! grep -qE '^\[(core|extra|xlibre-stable)\]' "$2" || return 1
    grep -q '^SigLevel = Required DatabaseOptional$' "$2" || return 1
    [[ "$BOOTSTRAP_FAIL" == 0 ]] || return 1
    log bootstrap-verified
  elif [[ "$1" == -Syu ]]; then
    [[ "$UPGRADE_FAIL" == 0 ]] || return 1
  elif [[ "$1" == -S ]]; then
    if [[ "$*" == *linux-cachyos* && "$KERNEL_FAIL" == 1 ]]; then return 1; fi
    if [[ "$*" == *xlibre-xserver* ]]; then INSTALLED_X=xlibre; fi
    if [[ "$*" == *xorg-server* ]]; then INSTALLED_X=xorg; fi
  elif [[ "$1" == -Qq ]]; then
    case "$2" in
      xorg-server) [[ "$INSTALLED_X" == xorg ]] ;;
      xlibre-xserver) [[ "$INSTALLED_X" == xlibre ]] ;;
      *) return 0 ;;
    esac
  else
    return 1
  fi
}
curl() {
  log "curl $*"
  local prev="" arg
  for arg in "$@"; do
    if [[ "$prev" == -o ]]; then printf 'mock signing key\n' > "$arg"; fi
    prev="$arg"
  done
}
mock_loader() {
  printf 'x86-64-v2 (supported, searched)\n'
  if [[ "$CPU_LEVEL" == v3 || "$CPU_LEVEL" == v4 ]]; then printf 'x86-64-v3 (supported, searched)\n'; fi
  if [[ "$CPU_LEVEL" == v4 ]]; then printf 'x86-64-v4 (supported, searched)\n'; fi
}
gcc() { printf '  -march=                     %s\n' "$CPU_MARCH"; }
systemctl() { log "systemctl $*"; }
mkinitcpio() { :; }
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dwm-installer-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.conf = self.root / "pacman.conf"
        self.conf.write_text("[options]\nSigLevel = Required DatabaseOptional\n"
                             "[core]\nServer = https://arch.invalid/core\n"
                             "[extra]\nServer = https://arch.invalid/extra\n")
        self.repo = self.root / "repo"
        (self.repo / "packages").mkdir(parents=True)
        (self.repo / "packages/core-official.txt").write_text("desktop-test-package\n")
        (self.repo / "packages/core-aur.txt").write_text("")
        self.events = self.root / "events"

    def run_bash(self, body, **settings):
        values = dict(HOME=str(self.home), REPO_DIR=str(self.repo),
                      PACMAN_CONF=str(self.conf), EVENTS=str(self.events),
                      USER_NAME=os.environ.get("USER", "jabir"),
                      USER_GROUP=subprocess.check_output(["id", "-gn"], text=True).strip(),
                      DISTRO_ID="arch", CPU_LEVEL="v3", CPU_MARCH="x86-64",
                      INSTALLED_X="none", KEY_FAIL="0", BOOTSTRAP_FAIL="0",
                      UPGRADE_FAIL="0", KERNEL_FAIL="0", ASSUME_YES="1",
                      USE_CACHYOS="0", XSERVER="xorg", REPOS_CHANGED="0",
                      DEPLOY_ONLY="0", NO_DEPS="0")
        values.update(settings)
        declarations = "\n".join(f"{k}={shlex.quote(v)}" for k, v in values.items())
        result = subprocess.run(["bash", "-c", "set -Eeuo pipefail\n" + declarations
                                 + "\n" + MOCKS + "\n" + FUNCTIONS + "\n" + body],
                                text=True, capture_output=True)
        return result

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_repo_priority_cpu_selection_and_reruns(self):
        for level, march, expected in (("generic", "x86-64", "cachyos"),
                                       ("v3", "x86-64", "cachyos-v3"),
                                       ("v4", "x86-64", "cachyos-v4"),
                                       ("v4", "znver4", "cachyos-znver4"),
                                       ("v4", "znver5", "cachyos-znver4")):
            with self.subTest(level=level, march=march):
                self.assert_success(self.run_bash("setup_cachyos_repos\nsetup_cachyos_repos",
                                                  CPU_LEVEL=level, CPU_MARCH=march))
                conf = self.conf.read_text()
                sections = [line for line in conf.splitlines() if line.startswith("[")]
                self.assertEqual(sections[1], f"[{expected}]")
                self.assertEqual(sections.count("[cachyos]"), 1)
                self.assertLess(sections.index("[cachyos]"), sections.index("[core]"))
                self.assertIn("Server = https://arch.invalid/extra", conf)
                if level != "generic":
                    self.assertLess(sections.index(f"[cachyos-extra-{expected.removeprefix('cachyos-')}]") ,
                                    sections.index("[extra]"))

    def test_recovers_from_partial_repo_configuration(self):
        self.conf.write_text(self.conf.read_text() + "[cachyos]\nServer = broken\n"
                             "[cachyos-v4]\nServer = stale\n"
                             "[cachyos-testing-v3]\nServer = custom-testing\n"
                             "[xlibre-stable]\nServer = keep-this\n")
        self.assert_success(self.run_bash("setup_cachyos_repos"))
        conf = self.conf.read_text()
        self.assertNotIn("broken", conf)
        self.assertNotIn("stale", conf)
        self.assertIn("Server = keep-this", conf)
        self.assertIn("[cachyos-testing-v3]\nServer = custom-testing", conf)
        self.assertIn("bootstrap-verified", self.events.read_text())

    def test_failed_key_or_bootstrap_preserves_configuration(self):
        original = self.conf.read_text()
        for flag in ("KEY_FAIL", "BOOTSTRAP_FAIL"):
            with self.subTest(flag=flag):
                result = self.run_bash("setup_cachyos_repos", **{flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.conf.read_text(), original)

    def test_kernel_question_and_repos_precede_package_installation(self):
        self.assert_success(self.run_bash(MAIN, DISTRO_ID="cachyos"))
        events = self.events.read_text().splitlines()
        bootstrap = events.index("bootstrap-verified")
        upgrade = next(i for i, line in enumerate(events) if line == "sudo pacman -Syu --noconfirm")
        kernel = next(i for i, line in enumerate(events) if line.startswith("sudo pacman -S ") and "linux-cachyos " in line)
        desktop = next(i for i, line in enumerate(events) if line.startswith("sudo pacman -S ") and "desktop-test-package" in line)
        self.assertLess(bootstrap, upgrade)
        self.assertLess(upgrade, kernel)
        self.assertLess(kernel, desktop)
        self.assertLess(MAIN.index("select_kernel"), MAIN.index("select_xserver"))

    def test_upgrade_and_kernel_failures_stop_desktop_installation(self):
        for flag in ("UPGRADE_FAIL", "KERNEL_FAIL"):
            with self.subTest(flag=flag):
                self.events.write_text("")
                result = self.run_bash(MAIN, DISTRO_ID="cachyos", **{flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("desktop-test-package", self.events.read_text())

    def test_new_arch_install_defaults_to_xorg(self):
        self.assert_success(self.run_bash(MAIN))
        events = self.events.read_text()
        self.assertIn("sudo pacman -S --needed --noconfirm xorg-server xf86-input-libinput", events)
        self.assertNotIn("sudo pacman-key", events)
        self.assertNotIn("linux-cachyos", events)

    def test_xlibre_key_is_trusted_before_sync(self):
        self.conf.write_text(self.conf.read_text() + "[xlibre-stable]\nServer = existing\n")
        self.assert_success(self.run_bash(MAIN))
        events = self.events.read_text()
        self.assertLess(events.index("sudo pacman-key --lsign-key 0C92313001CFCA27627B9098B97F7C613F359424"),
                        events.index("sudo pacman -Syu"))
        self.assertEqual(self.conf.read_text().count("[xlibre-stable]"), 1)

    def test_xlibre_switch_allows_conflict_confirmation(self):
        self.assert_success(self.run_bash("setup_xserver", XSERVER="xlibre", INSTALLED_X="xorg"))
        events = self.events.read_text()
        self.assertIn("sudo pacman -S --needed xlibre-xserver xlibre-input-libinput", events)
        self.assertNotIn("--noconfirm", events)
        self.assertNotIn("xlibre-meta", events)

    def test_root_owned_parent_is_repaired_before_mkdir(self):
        local = self.home / ".local"
        local.mkdir(mode=0o500)
        body = r'''
stat() {
  if [[ "${*: -1}" == "$HOME/.local" ]]; then printf '0\n'; else command stat "$@"; fi
}
ensure_user_dir "$HOME/.local/bin"
'''
        self.assert_success(self.run_bash(body))
        self.assertTrue((local / "bin").is_dir())
        self.assertTrue(local.stat().st_mode & 0o200)
        self.assertIn(f"sudo chown {os.environ.get('USER', 'jabir')}:", self.events.read_text())

    def test_external_symlinks_are_rejected_without_changes(self):
        external = self.root / "external"
        external.mkdir()
        (self.home / ".local").symlink_to(external, target_is_directory=True)
        result = self.run_bash('ensure_user_dir "$HOME/.local/bin"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside your home", result.stderr)
        self.assertFalse((external / "bin").exists())
        self.assertFalse(self.events.exists())

    def test_skip_modes_do_not_modify_repositories(self):
        for mode in ("NO_DEPS", "DEPLOY_ONLY"):
            with self.subTest(mode=mode):
                self.assert_success(self.run_bash(MAIN, **{mode: "1"}))
                self.assertFalse(self.events.exists())

    def test_installer_text_is_english_and_bash_syntax_is_valid(self):
        for filename in ("install.sh", "install-apps.sh"):
            text = (REPO / filename).read_text()
            self.assertFalse(any("\u0980" <= char <= "\u09ff" for char in text))
            subprocess.run(["bash", "-n", str(REPO / filename)], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
