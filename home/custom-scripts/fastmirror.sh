#!/bin/bash

echo "=========================================="
echo " 🚀 Arch Mirror Optimizer (Measured Speed)"
echo "=========================================="

# ---- tunables -------------------------------------------------------------
COUNTRIES="${COUNTRIES:-Bangladesh,India,Singapore}"   # reflector --country value
TOP_N="${TOP_N:-5}"            # mirrors kept in the final list
CANDIDATES="${CANDIDATES:-15}" # mirrors benchmarked (reflector prefilter)
BENCH_SECONDS="${BENCH_SECONDS:-5}"
BENCH_BYTES="${BENCH_BYTES:-8388608}"   # 8 MiB range request on extra.db
MIN_BYTES="${MIN_BYTES:-131072}"        # a mirror must deliver at least this much
MIRRORLIST_TARGET="${MIRRORLIST_TARGET:-/etc/pacman.d/mirrorlist}"
LOCK_FILE="${LOCK_FILE:-/tmp/fastmirror.lock}"
TIMER_MODE=""
DO_SYNC=1
DO_UPGRADE=0

usage() {
    cat <<'EOF'
Usage: fastmirror.sh [options]

  --install-timer daily|weekly   install a systemd timer using the current settings
  --countries LIST               reflector country filter (names or ISO codes,
                                 e.g. "Bangladesh,India,Singapore" or "BD,IN,SG")
  --top N                        mirrors kept in the final list (default 5)
  --candidates N                 mirrors benchmarked (default 15)
  --no-sync                      skip the database refresh afterwards
  --upgrade                      run pacman -Syu after the database refresh
  -h, --help                     this text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-timer)
            TIMER_MODE="${2:-weekly}"
            [[ "$TIMER_MODE" == "daily" ]] || TIMER_MODE="weekly"
            shift; [[ $# -gt 0 ]] && shift
            ;;
        --countries)  COUNTRIES="$2";  shift 2 ;;
        --top)        TOP_N="$2";      shift 2 ;;
        --candidates) CANDIDATES="$2"; shift 2 ;;
        --no-sync)    DO_SYNC=0;       shift ;;
        --upgrade)    DO_UPGRADE=1;    shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

for n in TOP_N CANDIDATES BENCH_SECONDS MIN_BYTES; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || { echo "❌ $n must be a number (got: ${!n})"; exit 2; }
done
(( TOP_N > 0 && CANDIDATES > 0 )) || { echo "❌ --top and --candidates must be > 0"; exit 2; }

# ---- Dependencies ---------------------------------------------------------
MISSING_PKGS=()
require_cmd() {
    command -v "$1" > /dev/null 2>&1 && return 0
    MISSING_PKGS+=("$2")
    return 1
}

require_cmd reflector reflector
require_cmd curl curl
require_cmd flock util-linux

if (( ${#MISSING_PKGS[@]} > 0 )); then
    mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
    echo "❌ Missing required package(s): ${MISSING_PKGS[*]}"
    echo "   Install with: sudo pacman -S ${MISSING_PKGS[*]}"
    exit 1
fi

# ---- One run at a time ----------------------------------------------------
exec 9> "$LOCK_FILE" || { echo "❌ Cannot open lock file $LOCK_FILE"; exit 1; }
if ! flock -n 9; then
    echo "❌ Another fastmirror run is in progress ($LOCK_FILE). Nothing changed."
    exit 1
fi

ARCH="$(uname -m)"
TMP_CANDIDATES=$(mktemp /tmp/fastmirror-candidates.XXXXXX)
TMP_BENCH=$(mktemp /tmp/fastmirror-bench.XXXXXX)
TMP_FINAL=$(mktemp /tmp/fastmirror-final.XXXXXX)

# ---- Privileges -----------------------------------------------------------
# Ask once, up front: the ranking takes a minute or two, and a password
# prompt landing in the middle of it throws the measurement away.
SUDO_KEEPALIVE_PID=""
# ---- Privileges -----------------------------------------------------------
# Ask once, up front: the ranking takes a minute or two, and a password
# prompt landing in the middle of it throws the measurement away.
SUDO_KEEPALIVE_PID=""

cleanup() {
    rm -f "$TMP_CANDIDATES" "$TMP_BENCH" "$TMP_FINAL"
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        pkill -P "$SUDO_KEEPALIVE_PID" 2>/dev/null
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

if (( EUID != 0 )); then
    echo "🔐 Root is needed to write mirrorlists and refresh databases."
    if ! sudo -v; then
        echo "❌ sudo authentication failed. Nothing changed."
        exit 1
    fi
    # stdout/stderr closed: this loop must never hold the caller's pipe open
    ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) > /dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
fi

if [[ "$MIRRORLIST_TARGET" != "/etc/pacman.d/mirrorlist" ]]; then
    echo "ℹ️  Writing to $MIRRORLIST_TARGET; cachyos-rate-mirrors still writes /etc/pacman.d/mirrorlist."
fi

# ---- CachyOS mirrors ------------------------------------------------------
# CachyOS lists are rewritten only when the running kernel is the CachyOS
# build. linux-cachyos installed but not booted is left alone.
KERNEL_RELEASE="$(uname -r)"
IS_CACHYOS=0
[[ "$KERNEL_RELEASE" == *cachyos* ]] && IS_CACHYOS=1

if (( IS_CACHYOS )); then
    echo "🐧 CachyOS kernel active ($KERNEL_RELEASE)."
    if command -v cachyos-rate-mirrors > /dev/null 2>&1; then
        echo "🔄 Ranking CachyOS mirrors (cachyos-rate-mirrors)..."
        # Writes cachyos-mirrorlist, cachyos-v3/v4-mirrorlist and the Arch
        # mirrorlist. Arch is re-written below with the measured list.
        if sudo cachyos-rate-mirrors; then
            CACHYOS_STATUS="ranked"
        else
            CACHYOS_STATUS="failed"
        fi
    else
        echo "⚠️  cachyos-rate-mirrors not found: sudo pacman -S cachyos-rate-mirrors"
        CACHYOS_STATUS="not installed"
    fi
else
    CACHYOS_STATUS="not cachyos"
    if pacman -Qq linux-cachyos > /dev/null 2>&1; then
        CACHYOS_STATUS="installed, not active"
        echo "ℹ️  linux-cachyos is installed but $KERNEL_RELEASE is running — CachyOS lists left untouched."
    fi
fi

# ---- Arch candidate mirrors ----------------------------------------------
echo "🌍 Querying Arch mirrors ($COUNTRIES, https, latest 50)..."
echo "⏳ reflector: 5s connection timeout, 5s download timeout..."

reflector --protocol https \
          --country "$COUNTRIES" \
          --latest 50 \
          --sort rate \
          --number "$CANDIDATES" \
          --threads 6 \
          --connection-timeout 5 \
          --download-timeout 5 \
          --save "$TMP_CANDIDATES" > /dev/null 2>&1

if ! grep -q '^Server = ' "$TMP_CANDIDATES" 2>/dev/null; then
    echo "↩️  No candidate matched $COUNTRIES — retrying worldwide."
    reflector --protocol https \
              --latest 50 \
              --sort rate \
              --number "$CANDIDATES" \
              --threads 6 \
              --connection-timeout 5 \
              --download-timeout 5 \
              --save "$TMP_CANDIDATES" > /dev/null 2>&1
fi

if ! grep -q '^Server = ' "$TMP_CANDIDATES" 2>/dev/null; then
    echo "❌ Error: no mirror responded. Current mirrorlist left untouched."
    exit 1
fi

# ---- Real throughput benchmark -------------------------------------------
# reflector scores on core.db (131 KB), where TLS handshake dominates. Pull
# an 8 MiB slice of extra.db from each candidate and verify the response
# before ranking: a fast error page is not a usable mirror.
echo "=========================================="
echo " 📊 Measuring real throughput (${BENCH_SECONDS}s per mirror)"
echo "=========================================="

: > "$TMP_BENCH"
VALID=0
while IFS= read -r line; do
    server=${line#Server = }
    url=${server//\$repo/extra}
    url=${url//\$arch/$ARCH}
    test_url="${url}/extra.db"

    read -r speed code bytes < <(
        curl -sfL --max-time "$BENCH_SECONDS" --range "0-$BENCH_BYTES" \
             -o /dev/null \
             -w '%{speed_download} %{http_code} %{size_download}' \
             "$test_url" 2>/dev/null
    )
    speed=${speed:-0}
    code=${code:-000}
    bytes=${bytes:-0}

    reason=""
    [[ "$code" == "200" || "$code" == "206" ]] || reason="http $code"
    (( bytes >= MIN_BYTES )) || reason="${reason:-short} ${bytes}B"
    awk -v s="$speed" 'BEGIN { exit !(s > 0) }' || reason="${reason:-no-speed}"

    if [[ -n "$reason" ]]; then
        printf '   %9s  %s  (rejected: %s)\n' "-" "$server" "$reason"
        continue
    fi

    mbps=$(awk -v s="$speed" 'BEGIN { printf "%.2f", s / 1048576 }')
    printf '   %9s MB/s  %s\n' "$mbps" "$server"
    printf '%s|%s\n' "$speed" "$server" >> "$TMP_BENCH"
    VALID=$(( VALID + 1 ))
done < <(grep '^Server = ' "$TMP_CANDIDATES")

if (( VALID == 0 )); then
    echo "=========================================="
    echo "❌ Every candidate failed validation."
    echo "   Current mirrorlist left untouched. Nothing was written."
    echo "=========================================="
    exit 1
fi

mapfile -t RANKED < <(sort -t'|' -k1,1 -gr "$TMP_BENCH" \
                        | head -n "$TOP_N" \
                        | cut -d'|' -f2-)
mapfile -t RANKED < <(printf '%s\n' "${RANKED[@]}" | grep -v '^$')

if (( ${#RANKED[@]} == 0 )); then
    echo "❌ Error: benchmark produced no usable mirror. Nothing written."
    exit 1
fi

# ---- Write mirrorlist ----------------------------------------------------
{
    echo "##"
    echo "## Arch Linux repository mirrorlist"
    echo "## Generated by fastmirror.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "## Ranked by measured download throughput from this host."
    echo "##"
    echo
    for s in "${RANKED[@]}"; do
        echo "Server = $s"
    done
} > "$TMP_FINAL"

echo "=========================================="
echo " 💾 Writing ${#RANKED[@]} mirror(s) to $MIRRORLIST_TARGET"
echo "=========================================="

TARGET_DIR=$(dirname "$MIRRORLIST_TARGET")
STAGE="${TARGET_DIR}/.mirrorlist.new.$$"

if [[ -f "$MIRRORLIST_TARGET" ]]; then
    if ! sudo cp -a "$MIRRORLIST_TARGET" "${MIRRORLIST_TARGET}.bak-$(date +%Y%m%d-%H%M%S)"; then
        echo "❌ Backup failed. Nothing changed."
        exit 1
    fi
    ls -1t "${MIRRORLIST_TARGET}".bak-* 2>/dev/null | tail -n +4 | xargs -r sudo rm -f
fi

# Same-directory rename: pacman never sees a half-written mirrorlist.
if ! sudo cp -- "$TMP_FINAL" "$STAGE"; then
    echo "❌ Could not stage the new list in $TARGET_DIR. Nothing changed."
    exit 1
fi
sudo chmod 644 "$STAGE"
if ! sudo mv -f -- "$STAGE" "$MIRRORLIST_TARGET"; then
    sudo rm -f -- "$STAGE"
    echo "❌ Could not replace $MIRRORLIST_TARGET. Previous list intact."
    exit 1
fi

APPLIED=1
echo "✅ Mirror list applied."

# ---- Database refresh (separate step, separate failure) -----------------
RC=0
SYNC_STATUS="skipped (--no-sync)"
UPGRADE_STATUS="not requested"

if (( DO_SYNC )); then
    echo "🔄 Refreshing package databases (every repo listed in pacman.conf)..."
    if sudo pacman -Syy; then
        SYNC_STATUS="refreshed"
    else
        echo "⚠️  Database refresh failed. Mirrorlist is applied; run: sudo pacman -Syy"
        SYNC_STATUS="failed"
        RC=1
    fi
fi

if (( DO_UPGRADE )); then
    echo "⬆️  Full system upgrade (pacman -Syu)..."
    if sudo pacman -Syu; then
        UPGRADE_STATUS="done"
    else
        echo "⚠️  Upgrade failed or was interrupted. Mirrorlist is applied."
        UPGRADE_STATUS="failed"
        RC=1
    fi
fi

# ---- Summary -------------------------------------------------------------
echo "=========================================="
echo " ✅ Done"
echo "=========================================="
top_mirror=${RANKED[0]}
top_speed=$(grep -F "|$top_mirror" "$TMP_BENCH" | head -n1 | cut -d'|' -f1)
echo "🥇 Primary : $top_mirror"
echo "   Speed   : $(awk -v s="$top_speed" 'BEGIN { printf "%.2f", s / 1048576 }') MB/s (measured)"
echo "🔢 Kept    : ${#RANKED[@]} of $VALID working candidate(s)"
echo "🐧 CachyOS : $CACHYOS_STATUS"
echo "💾 Written : $MIRRORLIST_TARGET (applied=$APPLIED)"
echo "🗃️  Databases: $SYNC_STATUS"
(( DO_UPGRADE )) && echo "⬆️  Upgrade  : $UPGRADE_STATUS"
if systemctl is-enabled reflector.timer > /dev/null 2>&1; then
    echo "ℹ️  reflector.timer is enabled and rewrites this file: sudo systemctl disable --now reflector.timer"
fi

# ---- Optional timer ------------------------------------------------------
# Ranking decays: the fastest mirror at 03:00 is congested at 15:00. The timer
# carries this run's settings so the automated pass does not silently reset
# them to defaults.
if [[ -n "$TIMER_MODE" ]]; then
    SELF=$(readlink -f "$0")

    sudo tee /etc/systemd/system/fastmirror.service > /dev/null <<EOF
[Unit]
Description=Rank Arch mirrors by measured throughput
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="COUNTRIES=$COUNTRIES"
Environment="TOP_N=$TOP_N"
Environment="CANDIDATES=$CANDIDATES"
Environment="BENCH_SECONDS=$BENCH_SECONDS"
Environment="MIN_BYTES=$MIN_BYTES"
Environment="MIRRORLIST_TARGET=$MIRRORLIST_TARGET"
ExecStart=$SELF$([[ $DO_SYNC -eq 0 ]] && echo " --no-sync")
EOF

    sudo tee /etc/systemd/system/fastmirror.timer > /dev/null <<EOF
[Unit]
Description=Refresh Arch mirror ranking ($TIMER_MODE)

[Timer]
OnCalendar=$TIMER_MODE
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now fastmirror.timer
    echo "⏱️  Timer installed: fastmirror.timer ($TIMER_MODE)"
    echo "=========================================="
fi

exit "$RC"
