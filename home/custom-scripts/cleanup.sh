#!/bin/bash

echo -e "\n🧹 Starting Ultimate System Cleanup...\n"

# ---------- helpers ----------
# Pull the executable out of an "Exec=" line, unquoting only the leading path
desktop_exec_target() {
    local exec_line=${1#Exec=}
    exec_line=${exec_line#"${exec_line%%[![:space:]]*}"}
    if [[ "$exec_line" == \"* ]]; then
        exec_line=${exec_line#\"}
        printf '%s\n' "${exec_line%%\"*}"
    else
        printf '%s\n' "${exec_line%% *}"
    fi
}

# Calculate used space before cleanup for all local file systems (in KB)
USED_BEFORE=$(df -kl --total | grep 'total' | awk '{print $3}')

# 1. Clear Pacman cache completely
echo "📦 Clearing Pacman cache..."
sudo pacman -Scc --noconfirm > /dev/null 2>&1

# 2. Check and remove Orphan packages safely (Moved up to fix the counter)
echo "🗑️ Checking for pacman orphan packages..."
ORPHANS=$(pacman -Qdtq)
if [[ -n "$ORPHANS" ]]; then
    ORPHAN_COUNT=$(echo "$ORPHANS" | wc -l)
    sudo pacman -Rns $ORPHANS --noconfirm > /dev/null 2>&1
else
    ORPHAN_COUNT=0
fi

# 3. Clear Yay (AUR) cache
echo "📦 Clearing Yay cache..."
yay -Scc --noconfirm > /dev/null 2>&1

# 4. Clean unused Flatpak packages (If installed)
if command -v flatpak &> /dev/null; then
    echo "📦 Removing unused Flatpak runtimes..."
    flatpak uninstall --unused -y > /dev/null 2>&1
    FLATPAK_STATUS="Cleaned"
else
    FLATPAK_STATUS="Not Installed"
fi

# 5. Clear old systemd journal logs (keeps only last 1 week for better space saving)
echo "📓 Clearing old systemd journal logs..."
sudo journalctl --vacuum-time=1weeks > /dev/null 2>&1

# 6. Clear system coredumps (Crash logs)
echo "🛑 Clearing coredump/crash logs..."
sudo rm -rf /var/lib/systemd/coredump/* > /dev/null 2>&1

# 7. Clear system-wide leftovers (.pacsave files)
echo "🔍 Removing system-wide leftover configs (.pacsave)..."
LEFT_OVERS=$(sudo find /etc -type f -name "*.pacsave")
if [[ -n "$LEFT_OVERS" ]]; then
    sudo find /etc -type f -name "*.pacsave" -delete
    LEFTOVER_COUNT=$(echo "$LEFT_OVERS" | wc -l)
else
    LEFTOVER_COUNT=0
fi

# 8. Empty User Trash
echo "🗑️ Emptying Trash..."
rm -rf ~/.local/share/Trash/* > /dev/null 2>&1

# 9. Remove dead desktop entries (app was deleted or moved)
echo "🖥️  Checking desktop entries..."
DEAD_DESKTOP=0
if [[ -d "$HOME/.local/share/applications" ]]; then
    while IFS= read -r -d '' f; do
        exec_line=$(grep -m1 '^Exec=' -- "$f" 2>/dev/null) || continue
        target=$(desktop_exec_target "$exec_line")
        [[ -z "$target" ]] && continue
        case "$target" in
            *%*|env|sh|bash|flatpak|snap) continue ;;
        esac
        if [[ "$target" == /* ]]; then
            [[ -x "$target" ]] && continue
        else
            command -v -- "$target" > /dev/null 2>&1 && continue
            [[ -x "$HOME/.local/bin/$target" ]] && continue
        fi
        rm -f -- "$f" 2>/dev/null && DEAD_DESKTOP=$(( DEAD_DESKTOP + 1 ))
    done < <(find "$HOME/.local/share/applications" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    # appimaged registers AppImages as symlinks here; drop the ones pointing nowhere
    while IFS= read -r -d '' l; do
        rm -f -- "$l" 2>/dev/null && DEAD_DESKTOP=$(( DEAD_DESKTOP + 1 ))
    done < <(find "$HOME/.local/share/applications" -maxdepth 1 -xtype l -print0 2>/dev/null)
    command -v update-desktop-database > /dev/null 2>&1 && \
        update-desktop-database "$HOME/.local/share/applications" > /dev/null 2>&1
fi

# 10. Remove broken symlinks in ~/.local/bin
echo "🔗 Checking broken symlinks..."
BROKEN_LINKS=0
if [[ -d "$HOME/.local/bin" ]]; then
    while IFS= read -r -d '' l; do
        rm -f -- "$l" 2>/dev/null && BROKEN_LINKS=$(( BROKEN_LINKS + 1 ))
    done < <(find "$HOME/.local/bin" -maxdepth 1 -xtype l -print0 2>/dev/null)
fi

# 11. Remove installer scripts left in /tmp (older than a day)
echo "🗂️  Checking /tmp for leftover installers..."
INSTALLER_TMP=0
while IFS= read -r -d '' f; do
    rm -f -- "$f" 2>/dev/null && INSTALLER_TMP=$(( INSTALLER_TMP + 1 ))
done < <(find /tmp -maxdepth 1 -type f -user "$(id -u)" -mtime +0 \
            \( -name 'install*.sh' -o -name 'get-*.sh' -o -name '*-install.sh' \) -print0 2>/dev/null)

# 12. Clear user cache directory safely (WITH PROMPT)
echo -e "\n---------------------------------------------"
read -p "❓ Do you want to clear the User Cache (~/.cache/)? [y/N]: " CLEAR_CACHE
if [[ "$CLEAR_CACHE" =~ ^[Yy]$ ]]; then
    echo "🧹 Clearing user cache (~/.cache/)..."
    rm -rf ~/.cache/* > /dev/null 2>&1
    CACHE_STATUS="Cleared"
else
    echo "⏩ Skipping user cache cleanup."
    CACHE_STATUS="Skipped"
fi
echo -e "---------------------------------------------"

# Calculate used space after cleanup
USED_AFTER=$(df -kl --total | grep 'total' | awk '{print $3}')

# Calculate freed space
FREED_KB=$((USED_BEFORE - USED_AFTER))
if [ "$FREED_KB" -lt 0 ]; then
    FREED_KB=0 # Failsafe
fi
FREED_MB=$((FREED_KB / 1024))

# --- OVERVIEW SUMMARY ---
echo -e "\n============================================="
echo -e "         ✨ CLEANUP OVERVIEW ✨              "
echo -e "============================================="
echo -e "📦 Pacman & AUR Cache   : Cleared"
echo -e "🗑️ Orphan Packages      : $ORPHAN_COUNT removed"
echo -e "📦 Flatpak Leftovers    : $FLATPAK_STATUS"
echo -e "📓 Journal & Crash Logs : Vacuumed & Cleared"
echo -e "🔍 Leftover (.pacsave)  : $LEFTOVER_COUNT removed"
echo -e "🖥️  Dead .desktop        : $DEAD_DESKTOP removed"
echo -e "🔗 Broken Symlinks      : $BROKEN_LINKS removed"
echo -e "🗂️  Installer Temp Files : $INSTALLER_TMP removed"
echo -e "🗑️ User Trash           : Cleared"
echo -e "🧹 User Cache           : $CACHE_STATUS"
echo -e "---------------------------------------------"
if [ "$FREED_MB" -ge 1024 ]; then
    FREED_GB=$(echo "scale=2; $FREED_MB / 1024" | bc)
    echo -e "💾 Total Space Freed    : **$FREED_GB GB**"
else
    echo -e "💾 Total Space Freed    : **$FREED_MB MB**"
fi
echo -e "=============================================\n"