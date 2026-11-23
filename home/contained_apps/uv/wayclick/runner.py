import asyncio
import gc
import os
import sys
import signal
import random
import json

# === FAST EVENT LOOP ===
try:
    import uvloop
    _UVLOOP = True
except ImportError:
    _UVLOOP = False

# === ENVIRONMENT ===
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
os.environ['SDL_AUDIODRIVER'] = 'pipewire,pulseaudio,alsa'
os.environ['SDL_APP_NAME'] = 'WayClick'
os.environ['PULSE_PROP'] = 'application.name="WayClick"'

import pygame
import evdev

C_GREEN  = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_BLUE   = "\033[1;34m"
C_RED    = "\033[1;31m"
C_DIM    = "\033[2m"
C_RESET  = "\033[0m"

# === CONFIGURATION FROM ENVIRONMENT / ARGS ===
CONFIG_DIR  = sys.argv[1]
PACK_NAME   = sys.argv[2]
ASSET_DIR   = os.path.join(CONFIG_DIR, PACK_NAME)
CONFIG_FILE = os.path.join(ASSET_DIR, "config.json")

ENABLE_TRACKPADS = os.environ.get('ENABLE_TRACKPADS', 'false').lower() == 'true'
AUTO_DETECT      = os.environ.get('WC_AUTO_DETECT', 'true').lower() == 'true'
DEBUG            = os.environ.get('WC_DEBUG', 'false').lower() == 'true'
BUFFER_SIZE      = int(os.environ.get('WC_AUDIO_BUFFER', '512'))
SAMPLE_RATE      = int(os.environ.get('WC_AUDIO_RATE', '48000'))
MIX_CHANNELS     = int(os.environ.get('WC_MIX_CHANNELS', '16'))
POLL_INTERVAL    = float(os.environ.get('WC_POLL_INTERVAL', '1.0'))

raw_keywords = os.environ.get('WC_EXCLUDED_KEYWORDS', 'touchpad,trackpad')
EXCLUDED_KEYWORDS = [x.strip().lower() for x in raw_keywords.split(',') if x.strip()]

# === TOUCHPAD CAPABILITY CONSTANTS ===
_EV_ABS = 3
_ABS_MT_POSITION_X = 0x35
_BTN_TOOL_FINGER = 0x145

# === AUDIO INIT ===
try:
    pygame.mixer.pre_init(frequency=SAMPLE_RATE, size=-16, channels=2, buffer=BUFFER_SIZE)
    pygame.mixer.init()
    pygame.mixer.set_num_channels(MIX_CHANNELS)
except pygame.error as e:
    sys.exit(f"{C_RED}[AUDIO ERROR]{C_RESET} {e}")

latency_ms = BUFFER_SIZE / SAMPLE_RATE * 1000
print(f"{C_BLUE}[AUDIO]{C_RESET} Buffer={BUFFER_SIZE} samples (~{latency_ms:.1f}ms) | "
      f"Rate={SAMPLE_RATE}Hz | Channels={MIX_CHANNELS}")

# === DISABLE GARBAGE COLLECTOR ===
# (100% safe here as our runloop generates zero cyclic references. Prevents latency spikes).
gc.disable()

# === CONFIG LOADING ===
print(f"{C_BLUE}[INFO]{C_RESET}  Config: {CONFIG_FILE}")
print(f"{C_BLUE}[INFO]{C_RESET}  Pack:   {ASSET_DIR}")

try:
    with open(CONFIG_FILE, 'r') as f:
        config_data = json.load(f)
        RAW_KEY_MAP = {int(k): v for k, v in config_data.get("mappings", {}).items()}
        DEFAULTS = config_data.get("defaults", [])
except Exception as e:
    sys.exit(f"{C_RED}[CONFIG ERROR]{C_RESET} Failed to load {CONFIG_FILE}: {e}")

# === SOUND LOADING ===
SOUND_FILES = set(RAW_KEY_MAP.values()) | set(DEFAULTS)
SOUNDS = {}

for filename in SOUND_FILES:
    path = os.path.join(ASSET_DIR, filename)
    if os.path.exists(path):
        try:
            snd = pygame.mixer.Sound(path)
            snd.set_volume(1.0)
            SOUNDS[filename] = snd
        except pygame.error:
            print(f"{C_YELLOW}[WARN]{C_RESET} Failed to load wav: {filename}")
    else:
        print(f"{C_YELLOW}[WARN]{C_RESET} File not found in pack: {filename}")

if not SOUNDS:
    sys.exit(f"ERROR: No sounds loaded! Check config.json mappings and .wav files in '{PACK_NAME}'.")

print(f"{C_BLUE}[INFO]{C_RESET}  Loaded {len(SOUNDS)} sound(s) from pack '{PACK_NAME}'")

# === PERFORMANCE: FLAT ARRAY CACHE ===
MAX_KEYCODE = 1024
SOUND_CACHE = [None] * MAX_KEYCODE
DEFAULT_SOUND_OBJS = tuple(SOUNDS[f] for f in DEFAULTS if f in SOUNDS)

for code, filename in RAW_KEY_MAP.items():
    if code < MAX_KEYCODE and filename in SOUNDS:
        SOUND_CACHE[code] = SOUNDS[filename]

# === HOT PATH PRE-BINDING ===
_random_choice = random.choice
_sound_cache   = SOUND_CACHE
_defaults      = DEFAULT_SOUND_OBJS
_has_defaults  = bool(DEFAULT_SOUND_OBJS)

# === PLAY FUNCTION ===
if DEBUG:
    import time
    _perf = time.perf_counter_ns

    def play_sound(code):
        t0 = _perf()
        try:
            sound = _sound_cache[code]
            if sound is not None:
                sound.play()
            elif _has_defaults:
                _random_choice(_defaults).play()
        except IndexError:
            pass # Silently drop absurd out-of-bounds keycodes
            
        elapsed_us = (_perf() - t0) / 1000
        print(f"  \u23f1 {elapsed_us:.1f}\u00b5s [code={code}]")
else:
    def play_sound(code):
        try:
            # EAFP (Easier to Ask for Forgiveness) - Try block executes faster 
            # than evaluating an `if code < MAX` branch check in Python.
            sound = _sound_cache[code]
            if sound is not None:
                sound.play()
            elif _has_defaults:
                _random_choice(_defaults).play()
        except IndexError:
            pass

# === DEVICE READER ===
async def read_device(dev):
    _play = play_sound

    print(f"{C_GREEN}[+] Connected:{C_RESET} {dev.name} {C_DIM}({dev.path}){C_RESET}")
    try:
        async for event in dev.async_read_loop():
            # Stripped the manual stop check here for micro-optimization. 
            # Task cancellation handles the shutdown sequence natively.
            if event.type == 1 and event.value == 1:
                _play(event.code)
    except (OSError, IOError):
        print(f"{C_YELLOW}[-] Disconnected:{C_RESET} {dev.path}")
    except asyncio.CancelledError:
        pass
    finally:
        try:
            dev.close()
        except (OSError, IOError):
            pass

# === MAIN LOOP ===
async def main():
    loop = asyncio.get_running_loop()
    loop_type = "uvloop (native)" if _UVLOOP else "asyncio (standard)"
    print(f"{C_BLUE}[CORE]{C_RESET}  Engine started | Event loop: {loop_type}")

    filter_mode = "disabled (all devices play sounds)" if ENABLE_TRACKPADS else \
                  f"keyword blacklist ({len(EXCLUDED_KEYWORDS)} entries)" + \
                  (" + auto-detect" if AUTO_DETECT else " only")
    print(f"{C_BLUE}[CORE]{C_RESET}  Filtering: {filter_mode}")
    print(f"{C_BLUE}[CORE]{C_RESET}  Monitoring devices (poll: {POLL_INTERVAL}s)...")

    stop = asyncio.Event()

    # Thread-safe asyncio signal handling
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    monitored_tasks = {}
    skipped_paths = set()
    _list_devices = evdev.list_devices

    while not stop.is_set():
        try:
            all_paths = _list_devices()
            current_set = set(all_paths)

            skipped_paths &= current_set

            for path in all_paths:
                if path in monitored_tasks or path in skipped_paths:
                    continue

                try:
                    dev = evdev.InputDevice(path)
                    caps = dev.capabilities(absinfo=False)

                    if not ENABLE_TRACKPADS:
                        name_lower = dev.name.lower()
                        keyword_match = any(k in name_lower for k in EXCLUDED_KEYWORDS)

                        if keyword_match:
                            print(f"{C_DIM}[~] Skipped: {dev.name} ({dev.path}) [keyword]{C_RESET}")
                            dev.close()
                            skipped_paths.add(path)
                            continue

                        if AUTO_DETECT:
                            abs_codes = caps.get(_EV_ABS, [])
                            key_codes = caps.get(1, [])
                            has_mt = _ABS_MT_POSITION_X in abs_codes
                            has_finger = _BTN_TOOL_FINGER in key_codes

                            if has_mt or has_finger:
                                print(f"{C_DIM}[~] Skipped: {dev.name} ({dev.path}) [auto-detected touchpad]{C_RESET}")
                                dev.close()
                                skipped_paths.add(path)
                                continue

                    if 1 in caps:
                        task = asyncio.create_task(read_device(dev))
                        monitored_tasks[path] = task
                    else:
                        dev.close()
                        skipped_paths.add(path)
                except (OSError, IOError):
                    continue

        except Exception as e:
            print(f"Discovery Loop Error: {e}")

        dead_paths = [p for p, t in monitored_tasks.items() if t.done()]
        for p in dead_paths:
            del monitored_tasks[p]

        try:
            await asyncio.wait_for(stop.wait(), timeout=POLL_INTERVAL)
        except asyncio.TimeoutError:
            continue

    print("\nStopping...")
    for t in monitored_tasks.values():
        t.cancel()
    if monitored_tasks:
        await asyncio.gather(*monitored_tasks.values(), return_exceptions=True)
    pygame.mixer.quit()

if __name__ == "__main__":
    try:
        if _UVLOOP:
            uvloop.install()
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
