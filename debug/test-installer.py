#!/usr/bin/env python3
"""Installer regressions with mocked privileged commands and an isolated home.

Run: python3 debug/test-installer.py
No packages, services, or files outside the temporary fixture are modified.
"""

import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / "install.sh").read_text()
FUNCTIONS, MAIN = SOURCE[SOURCE.index("ask_yes_no() {"):].split("# ── main", 1)
FULL_MAIN = MAIN[MAIN.index('echo ""'):]
MAIN = FULL_MAIN.split("\nprepare_user_paths\n", 1)[0]
# Simulate CPU capabilities without depending on the host CPU.
FUNCTIONS = FUNCTIONS.replace("/lib/ld-linux-x86-64.so.2 --help", "mock_loader")

MOCKS = r'''
mkdir -p "$TEST_ROOT/state" "$TMPDIR"
export TMPDIR
for state_name in PACMAN_KIND INSTALLED_X INSTALLED_KERNEL JACK_INSTALLED AUDIO_INSTALLED TRANSIENT_FAILURES; do
  printf '%s' "${!state_name}" > "$TEST_ROOT/state/$state_name"
done
state_get() { cat "$TEST_ROOT/state/$1"; }
state_set() { printf '%s' "$2" > "$TEST_ROOT/state/$1"; }
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
    cp|install|tee|chown|chmod|find)
      for argument in "$@"; do
        [[ "$argument" != /* || "$argument" == "$TEST_ROOT/"* ]] || return 1
      done
      command "$cmd" "$@"
      ;;
    *) return 1 ;;
  esac
}
pacman() {
  log "pacman $*"
  if [[ "$1" == --config ]]; then
    [[ "$KEY_READY" == 1 ]] || return 1
    ! grep -qE '^\[(core|extra|xlibre-stable)\]' "$2" || return 1
    grep -q '^SigLevel = Required DatabaseOptional$' "$2" || return 1
    if [[ "$*" == *cachyos/pacman* ]]; then
      [[ "$PACMAN_BOOTSTRAP_FAIL" == 0 ]] || return 1
      if [[ "$PACMAN_ARCH_FAIL" == 0 ]]; then state_set PACMAN_KIND cachyos; fi
      log pacman-bootstrap-verified
    else
      [[ "$BOOTSTRAP_FAIL" == 0 ]] || return 1
      log bootstrap-verified
    fi
  elif [[ "$1" == -Syu || "$1" == -Syyu ]]; then
    failures="$(state_get TRANSIENT_FAILURES)"
    if ((failures > 0)); then
      state_set TRANSIENT_FAILURES "$((failures - 1))"
      printf 'error: failed retrieving file: %s\n' "$TRANSIENT_ERROR" >&2
      return 1
    fi
    [[ "$UPGRADE_FAIL" == 0 ]] || return 1
    if [[ "$CPU_LEVEL" != generic ]] && grep -qE '^\[cachyos-(v3|v4|znver4)\]' "$PACMAN_CONF"; then
      [[ "$(state_get PACMAN_KIND)" == cachyos ]] || { printf 'invalid architecture\n' >&2; return 1; }
    fi
    if [[ "$*" == *pipewire-jack* ]]; then state_set AUDIO_INSTALLED 1; state_set JACK_INSTALLED 0; fi
  elif [[ "$1" == -S ]]; then
    if [[ -n "$PACKAGE_FAIL" && "$*" == *"$PACKAGE_FAIL"* ]]; then return 1; fi
    if [[ "$*" == *linux-cachyos* && "$KERNEL_FAIL" == 1 ]]; then return 1; fi
    if [[ "$*" == *xlibre-xserver* ]]; then state_set INSTALLED_X xlibre; fi
    if [[ "$*" == *xorg-server* ]]; then state_set INSTALLED_X xorg; fi
    if [[ "$*" == *linux-cachyos* ]]; then state_set INSTALLED_KERNEL 1; fi
    if [[ "$*" == *pipewire-jack* ]]; then state_set AUDIO_INSTALLED 1; state_set JACK_INSTALLED 0; fi
  elif [[ "$1" == -Qq ]]; then
    case "$2" in
      xorg-server) [[ "$(state_get INSTALLED_X)" == xorg ]] ;;
      xlibre-xserver) [[ "$(state_get INSTALLED_X)" == xlibre ]] ;;
      linux-cachyos|linux-cachyos-headers) [[ "$(state_get INSTALLED_KERNEL)" == 1 ]] ;;
      jack2) [[ "$(state_get JACK_INSTALLED)" == 1 ]] ;;
      jack|jack2-dbus|pulseaudio|pulseaudio-alsa|pulseaudio-bluetooth|pipewire-media-session) return 1 ;;
      pipewire|pipewire-audio|pipewire-alsa|pipewire-jack|pipewire-pulse|wireplumber) [[ "$(state_get AUDIO_INSTALLED)" == 1 ]] ;;
      *) return 0 ;;
    esac
  else
    return 1
  fi
}
pacman-conf() {
  log "pacman-conf $*"
  printf 'x86_64\n'
  if [[ "$(state_get PACMAN_KIND)" == cachyos ]]; then
    printf 'x86_64_v2\n'
    if [[ "$CPU_LEVEL" == v3 || "$CPU_LEVEL" == v4 ]]; then printf 'x86_64_v3\n'; fi
    if [[ "$CPU_LEVEL" == v4 ]]; then printf 'x86_64_v4\n'; fi
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
fc-cache() { :; }
sleep() { :; }
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

    def bash_script(self, body, **settings):
        values = dict(HOME=str(self.home), REPO_DIR=str(self.repo),
                      PACMAN_CONF=str(self.conf), EVENTS=str(self.events),
                      USER_NAME=os.environ.get("USER", "jabir"),
                      USER_GROUP=subprocess.check_output(["id", "-gn"], text=True).strip(),
                      DISTRO_ID="arch", CPU_LEVEL="v3", CPU_MARCH="x86-64",
                      INSTALLED_X="none", KEY_FAIL="0", BOOTSTRAP_FAIL="0",
                      UPGRADE_FAIL="0", KERNEL_FAIL="0", ASSUME_YES="1",
                      PACMAN_KIND="arch", PACMAN_BOOTSTRAP_FAIL="0", PACMAN_ARCH_FAIL="0",
                      INSTALLED_KERNEL="0",
                      WITH_APPS="0",
                      PACKAGE_FAIL="",
                      TEST_ROOT=str(self.root), TMPDIR=str(self.root / "tmp"),
                      JACK_INSTALLED="0", AUDIO_INSTALLED="0", TRANSIENT_FAILURES="0",
                      TRANSIENT_ERROR="404",
                      USE_CACHYOS="0", XSERVER="xorg", REPOS_CHANGED="0",
                      DEPLOY_ONLY="0", NO_DEPS="0")
        values.update(settings)
        declarations = "\n".join(f"{k}={shlex.quote(v)}" for k, v in values.items())
        return "set -Eeuo pipefail\n" + declarations + "\n" + MOCKS + "\n" + FUNCTIONS + "\n" + body

    def run_bash(self, body, **settings):
        return subprocess.run(["bash", "-c", self.bash_script(body, **settings)],
                              text=True, capture_output=True)

    def seed_deployment(self):
        for directory in ("config/fish", "home/.local/bin", "home/custom-scripts", "home/user_scripts", "applications"):
            (self.repo / directory).mkdir(parents=True)
        (self.repo / "config/fish/config.fish").write_text("set example /home/jabir/example\n")
        (self.repo / "config/starship.toml").write_text("format = 'default'\n")
        (self.repo / "home/.profile").write_text("# test profile\n")
        (self.repo / "home/.local/bin/example").write_text("#!/bin/sh\nexit 0\n")
        (self.repo / "applications/example.desktop").write_text("[Desktop Entry]\nName=Example\nExec=/home/jabir/.local/bin/example\n")
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/.xinitrc").write_text("#!/bin/sh\nexec dwm\n")
        (self.repo / "scripts/theme-apply.sh").write_text("#!/bin/sh\nexit 0\n")

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
                self.assertEqual(conf.count("Architecture = auto"), 1)
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
        for flag in ("KEY_FAIL", "BOOTSTRAP_FAIL", "PACMAN_BOOTSTRAP_FAIL", "PACMAN_ARCH_FAIL"):
            with self.subTest(flag=flag):
                result = self.run_bash("setup_cachyos_repos", **{flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.conf.read_text(), original)

    def test_stock_arch_pacman_is_replaced_before_optimized_upgrade(self):
        self.assert_success(self.run_bash(MAIN, DISTRO_ID="cachyos"))
        events = self.events.read_text()
        self.assertLess(events.index("pacman-bootstrap-verified"), events.index("sudo pacman -Syu"))
        bootstrap = next(line for line in events.splitlines() if line.startswith("sudo pacman ") and "cachyos/pacman" in line)
        self.assertNotIn("--needed", bootstrap)

    def test_ready_repositories_and_pacman_are_not_duplicated_on_rerun(self):
        self.assert_success(self.run_bash("setup_cachyos_repos\nsetup_cachyos_repos"))
        events = self.events.read_text()
        self.assertEqual(events.count("pacman-bootstrap-verified"), 1)
        self.assertEqual(events.count("sudo install -m644"), 1)
        self.assertEqual(len(list(self.root.glob("pacman.conf.dwm-backup-*"))), 1)

    def test_jack2_is_replaced_in_the_first_full_upgrade(self):
        self.assert_success(self.run_bash(MAIN, JACK_INSTALLED="1"))
        upgrade = next(line for line in self.events.read_text().splitlines() if line.startswith("sudo pacman -Syu"))
        self.assertIn("pipewire-jack", upgrade)
        self.assertNotIn("--noconfirm", upgrade)
        self.assertEqual((self.root / "state/JACK_INSTALLED").read_text(), "0")

    def test_stale_mirror_download_is_retried_with_database_refresh(self):
        self.assert_success(self.run_bash("pacman_run -Syu --noconfirm", TRANSIENT_FAILURES="1"))
        events = self.events.read_text()
        self.assertIn("sudo pacman -Syu --noconfirm", events)
        self.assertIn("sudo pacman -Syyu --noconfirm", events)

    def test_download_retries_are_bounded(self):
        result = self.run_bash("pacman_run -Syu --noconfirm", TRANSIENT_FAILURES="5", TRANSIENT_ERROR="HTTP2 PROTOCOL_ERROR")
        self.assertNotEqual(result.returncode, 0)
        calls = [line for line in self.events.read_text().splitlines() if line.startswith("sudo pacman")]
        self.assertEqual(len(calls), 3)

    def test_audio_stack_has_its_required_runtime_packages(self):
        self.assert_success(self.run_bash("setup_audio"))
        events = self.events.read_text()
        self.assertIn("pipewire-audio", events)
        self.assertIn("pipewire-jack", events)
        self.assertIn("wireplumber", events)

    def test_installation_log_is_private_and_retains_errors(self):
        result = self.run_bash(MAIN, UPGRADE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        logs = list((self.home / ".local/state/dwm-jabir").glob("install-*.log"))
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0].stat().st_mode & 0o777, 0o600)
        self.assertIn("System upgrade failed", logs[0].read_text())

    def test_previous_cachyos_selection_is_default_on_arch_rerun(self):
        self.conf.write_text(self.conf.read_text() + "[cachyos]\nServer = previous-run\n")
        self.assert_success(self.run_bash(MAIN))
        self.assertIn("sudo pacman -S --needed --noconfirm linux-cachyos", self.events.read_text())

    def test_retry_after_failed_upgrade_keeps_one_repository_configuration(self):
        result = self.run_bash(MAIN, DISTRO_ID="cachyos", UPGRADE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        failed_config = self.conf.read_text()
        self.assert_success(self.run_bash(MAIN, PACMAN_KIND="cachyos"))
        self.assertEqual(self.conf.read_text(), failed_config)
        self.assertEqual(len(list(self.root.glob("pacman.conf.dwm-backup-*"))), 1)

    def test_explicit_architecture_is_replaced_by_cpu_detection_once(self):
        self.conf.write_text(self.conf.read_text().replace("[options]", "[options]\nArchitecture = x86_64\nArchitecture = x86_64"))
        self.assert_success(self.run_bash("setup_cachyos_repos\nsetup_cachyos_repos"))
        self.assertEqual(self.conf.read_text().count("Architecture ="), 1)
        self.assertIn("Architecture = auto", self.conf.read_text())

    def test_completed_deployment_can_be_run_twice(self):
        self.seed_deployment()
        for _ in range(2):
            self.assert_success(self.run_bash(FULL_MAIN, DEPLOY_ONLY="1"))
        expected = f"set example {self.home}/example\n"
        self.assertEqual((self.home / ".config/fish/config.fish").read_text(), expected)
        self.assertFalse((self.home / ".config/fish/fish").exists())
        self.assertTrue((self.home / ".local/bin/example").is_file())
        self.assertTrue((self.home / ".local/bin/wayclick").is_symlink())
        self.assertEqual(len(list(self.home.glob(".config-backup-*"))), 2)

    def test_deployment_rerun_preserves_the_users_wallpaper_selection(self):
        self.seed_deployment()
        initial = self.repo / "home/.fehbg"
        initial.write_text('#!/bin/sh\n# saved Ristretto default\n')
        initial.chmod(0o755)
        self.assert_success(self.run_bash(FULL_MAIN, DEPLOY_ONLY="1"))
        saved = self.home / ".fehbg"
        self.assertEqual(saved.read_text(), initial.read_text())
        selected = '#!/bin/sh\n# user picked a different wallpaper\n'
        saved.write_text(selected)
        self.assert_success(self.run_bash(FULL_MAIN, DEPLOY_ONLY="1"))
        self.assertEqual(saved.read_text(), selected)

    def test_backups_keep_original_files_and_do_not_nest_directories(self):
        config = self.home / ".config/fish"
        config.mkdir(parents=True)
        (config / "config.fish").write_text("original\n")
        (self.home / ".profile").write_text("original profile\n")
        body = '''
backup_path "$HOME/.config/fish"
printf 'changed\n' > "$HOME/.config/fish/config.fish"
backup_path "$HOME/.config/fish"
backup_path "$HOME/.profile"
printf 'changed profile\n' > "$HOME/.profile"
backup_path "$HOME/.profile"
printf '%s' "$BACKUP_DIR" > "$REPO_DIR/backup-location"
'''
        self.assert_success(self.run_bash(body))
        backup = Path((self.repo / "backup-location").read_text())
        self.assertEqual((backup / ".config/fish/config.fish").read_text(), "original\n")
        self.assertFalse((backup / ".config/fish/fish").exists())
        self.assertEqual((backup / ".profile").read_text(), "original profile\n")

    def test_backup_failure_prevents_overwrite(self):
        (self.home / ".profile").write_text("original\n")
        (self.repo / "new-profile").write_text("new\n")
        result = self.run_bash('cp() { return 1; }; deploy_file "$REPO_DIR/new-profile" "$HOME/.profile"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Backup failed", result.stderr)
        self.assertEqual((self.home / ".profile").read_text(), "original\n")

    def test_unwritable_user_owned_directory_has_clear_error(self):
        local = self.home / ".local"
        local.mkdir(mode=0o500)
        result = self.run_bash('ensure_user_dir "$HOME/.local"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not writable", result.stderr)
        self.assertFalse(self.events.exists())

    def test_directory_collision_is_reported(self):
        (self.home / ".local").write_text("file instead of directory\n")
        result = self.run_bash('ensure_user_dir "$HOME/.local/bin"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected a directory", result.stderr)

    def test_spaces_and_sed_metacharacters_in_home_are_supported(self):
        self.seed_deployment()
        unusual_home = self.root / "home with & and | characters"
        unusual_home.mkdir()
        self.assert_success(self.run_bash(FULL_MAIN, HOME=str(unusual_home), DEPLOY_ONLY="1"))
        content = (unusual_home / ".local/share/applications/example.desktop").read_text()
        self.assertIn(f"Exec={unusual_home}/.local/bin/example", content)
        self.assertIn(str(unusual_home), (unusual_home / ".config/fish/config.fish").read_text())

    def test_concurrent_installer_is_rejected(self):
        script = self.bash_script('acquire_install_lock; printf "lock-held\\n"; read -r release')
        holder = subprocess.Popen(["bash", "-c", script], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "lock-held")
            result = self.run_bash(MAIN)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already running", result.stderr)
            self.assertFalse(self.events.exists())
            holder.communicate(input="release\n", timeout=5)
            self.assertEqual(holder.returncode, 0)
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.communicate()
        self.assert_success(self.run_bash('acquire_install_lock'))

    def test_lock_symlink_is_rejected_without_truncating_its_target(self):
        target = self.root / "important-file"
        target.write_text("keep this\n")
        lock_dir = self.home / ".local/state/dwm-jabir"
        lock_dir.mkdir(parents=True)
        (lock_dir / "install.lock").symlink_to(target)
        result = self.run_bash("acquire_install_lock")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)
        self.assertEqual(target.read_text(), "keep this\n")

    def test_temp_directories_are_cleaned_after_failure(self):
        result = self.run_bash('trap cleanup_temp_dirs EXIT; new_temp_dir work; printf "%s" "$work" > "$REPO_DIR/temp-location"; false')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path((self.repo / "temp-location").read_text()).exists())

    def test_partial_package_failure_is_reported_for_retry(self):
        result = self.run_bash('pac_install working broken; [[ "${PAC_FAILED[*]}" == broken ]]', PACKAGE_FAIL="broken")
        self.assert_success(result)
        self.assertIn("Batch installation failed", result.stdout)
        self.assertIn("sudo pacman -S --needed --noconfirm working", self.events.read_text())

    def test_final_exit_status_reports_incomplete_installation(self):
        self.seed_deployment()
        result = self.run_bash('PAC_FAILED=(broken);\n' + FULL_MAIN, DEPLOY_ONLY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finished with errors", result.stdout)
        self.assertIn("broken", result.stdout)
        self.assertNotIn("Installation Complete!", result.stdout)

    def test_optional_apps_are_skipped_in_package_free_modes(self):
        self.seed_deployment()
        app_script = self.repo / "install-apps.sh"
        app_script.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(self.root / 'apps-called'))}\n")
        app_script.chmod(0o755)
        self.assert_success(self.run_bash(FULL_MAIN, WITH_APPS="1", DEPLOY_ONLY="1"))
        self.assertFalse((self.root / "apps-called").exists())

    def test_optional_app_failure_returns_failure(self):
        self.seed_deployment()
        app_script = self.repo / "install-apps.sh"
        app_script.write_text("#!/bin/sh\nexit 1\n")
        app_script.chmod(0o755)
        overrides = "build_dwm() { :; }; setup_lightdm() { :; }; setup_system_config() { :; }; setup_shell() { :; };\n"
        result = self.run_bash(overrides + FULL_MAIN, WITH_APPS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finished with errors", result.stdout)

    def test_package_lists_accept_crlf_spaces_and_comments(self):
        path = self.repo / "packages/sample.txt"
        path.write_bytes(b" # comment\r\n foo \r\nbar # inline\r\n\r\n")
        result = self.run_bash('read_list "$REPO_DIR/packages/sample.txt"')
        self.assert_success(result)
        self.assertEqual(result.stdout, "foo\nbar\n")

    def test_optional_app_skip_messages_do_not_become_packages(self):
        (self.repo / "packages/apps-official.txt").write_text("foo\nbar\n")
        (self.repo / "packages/apps-aur.txt").write_text("")
        (self.repo / "packages/skip.txt").write_text("foo\n")
        app_source = (REPO / "install-apps.sh").read_text()
        app_functions = app_source[app_source.index("read_list() {"):]
        self.assert_success(self.run_bash(app_functions))
        events = self.events.read_text()
        self.assertIn("sudo pacman -S --needed --noconfirm bar", events)
        self.assertNotIn("foo", events)
        self.assertNotIn("INFO", events)

    def test_broken_aur_helper_is_rebuilt_before_reuse(self):
        body = '''
paru() { return 1; }
yay() { return 1; }
build_aur_pkg() { log "rebuilt $1"; paru() { return 0; }; }
ensure_helper
[[ "$HELPER" == paru ]]
'''
        self.assert_success(self.run_bash(body))
        self.assertIn("rebuilt paru-bin", self.events.read_text())

    def test_repository_helper_is_preferred_when_available(self):
        body = '''
paru() { [[ -f "$REPO_DIR/helper-fixed" ]]; }
yay() { return 1; }
pacman() {
  log "pacman $*"
  if [[ "$1" == -Si && "$2" == paru ]]; then return 0; fi
  if [[ "$1" == -S ]]; then touch "$REPO_DIR/helper-fixed"; return 0; fi
  return 1
}
build_aur_pkg() { die "Should use the repository helper"; }
ensure_helper
[[ "$HELPER" == paru ]]
'''
        self.assert_success(self.run_bash(body))
        self.assertIn("sudo pacman -S --noconfirm paru", self.events.read_text())

    def test_make_install_can_be_repeated_without_nested_config_directories(self):
        if not shutil.which("make"):
            self.skipTest("Requires make")
        self.seed_deployment()
        (self.repo / "Makefile").write_text((REPO / "Makefile").read_text())
        (self.repo / "config.mk").write_text("PREFIX=/usr/local\nMANPREFIX=/usr/local/share/man\nVERSION=test\nCC=true\n")
        (self.repo / "scripts").mkdir(exist_ok=True)
        (self.repo / "scripts/.xinitrc").write_text("exec dwm\n")
        (self.repo / "dwm").write_text("test binary\n")
        (self.repo / "dwm.1").write_text("VERSION\n")
        (self.repo / "dwm.desktop").write_text("[Desktop Entry]\nName=dwm\n")
        (self.repo / "config/dwm-titus").mkdir()
        for name in ("hotkeys.toml", "themes.toml", "window-rules.toml"):
            (self.repo / "config/dwm-titus" / name).write_text("# test\n")
        helper_bin = self.root / "helper-bin"
        helper_bin.mkdir()
        (helper_bin / "fc-cache").write_text("#!/bin/sh\nexit 0\n")
        (helper_bin / "fc-cache").chmod(0o755)
        env = {**os.environ, "HOME": str(self.home), "PATH": f"{helper_bin}:{os.environ['PATH']}"}
        command = ["make", "-C", str(self.repo), "install", "SRC=", "OBJ=",
                   f"USER_HOME={self.home}", f"OWNER={os.environ.get('USER', 'jabir')}",
                   f"DESTDIR={self.root / 'system'}"]
        for _ in range(2):
            self.assert_success(subprocess.run(command, env=env, text=True, capture_output=True))
        self.assertTrue((self.home / ".config/dwm-titus/themes.toml").exists())
        self.assertFalse((self.home / ".config/dwm-titus/dwm-titus").exists())
        self.assertFalse((self.home / ".config/fish/fish").exists())

    def test_existing_optimized_repos_are_repaired_when_kernel_is_declined(self):
        self.conf.write_text(self.conf.read_text() + "[cachyos-v3]\nServer = previous-run\n")
        body = '''
ask_yes_no() { [[ "$1" != "Install CachyOS kernel"* && "$1" != "Use XLibre"* ]]; }
''' + MAIN
        self.assert_success(self.run_bash(body))
        events = self.events.read_text()
        self.assertIn("pacman-bootstrap-verified", events)
        self.assertNotIn("sudo pacman -S --needed --noconfirm linux-cachyos", events)

    def test_real_pacman_rejects_generic_arch_and_accepts_supported_v3(self):
        pacman = shutil.which("pacman")
        pacman_conf = shutil.which("pacman-conf")
        if not pacman or not pacman_conf:
            self.skipTest("Requires pacman and pacman-conf for read-only transaction previews")
        arch_conf = self.root / "architecture.conf"
        arch_conf.write_text("[options]\nArchitecture = auto\n")
        arches = subprocess.check_output([pacman_conf, "--config", str(arch_conf), "Architecture"], text=True).splitlines()
        if "x86_64_v3" not in arches:
            self.skipTest("Requires CachyOS pacman on a v3-capable CPU for the post-bootstrap preview")
        self.assert_success(self.run_bash("setup_cachyos_repos"))
        config = "[options]\nArchitecture = auto\n" if "Architecture = auto" in self.conf.read_text() else "[options]\nArchitecture = x86_64\n"
        arch_conf.write_text(config + "SigLevel = Never\n")
        # Only these locally generated unsigned test fixtures disable signatures.
        # -Up prepares and prints a transaction; it does not install anything.
        info = b"pkgname = dwm-architecture-test\npkgver = 1.0-1\npkgdesc = Test fixture\nsize = 0\narch = x86_64_v3\n"
        package = self.root / "dwm-architecture-test-1.0-1-x86_64_v3.pkg.tar.gz"
        with tarfile.open(package, "w:gz") as archive:
            entry = tarfile.TarInfo(".PKGINFO")
            entry.size = len(info)
            archive.addfile(entry, io.BytesIO(info))
        (self.root / "db/local").mkdir(parents=True)
        command = [pacman, "--config", str(arch_conf), "--dbpath", str(self.root / "db"),
                   "--logfile", str(self.root / "pacman.log"), "-Up", str(package)]
        generic_conf = self.root / "generic.conf"
        generic_conf.write_text("[options]\nArchitecture = x86_64\nSigLevel = Never\n")
        rejected_command = command.copy()
        rejected_command[2] = str(generic_conf)
        rejected = subprocess.run(rejected_command, text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("valid architecture", rejected.stderr + rejected.stdout)
        self.assert_success(subprocess.run(command, text=True, capture_output=True))

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
        self.assertNotIn("sudo pacman -S --needed --noconfirm linux-cachyos", events)

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
