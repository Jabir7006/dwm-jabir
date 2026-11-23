#!/usr/bin/env bash
# =====================================================================
#  purge.sh — Arch Linux এর জন্য "A to Z" আনইনস্টলার
#
#  যা করে:
#   1. প্যাকেজ খুঁজে বের করে (-bin/-git ইত্যাদি ভ্যারিয়েন্টসহ)
#   2. প্যাকেজের ফাইল-লিস্ট থেকে অ্যাপের আসল নাম (binary, .desktop id,
#      /opt /usr/share ফোল্ডার) বের করে — যাতে কনফিগের নাম মিলে যায়
#      (প্যাকেজ আগেই আনইনস্টল করা থাকলে pacman/AUR ক্যাশের .pkg.tar থেকে নেয়)
#   3. pacman -Rns + Flatpak + Snap আনইনস্টল করে
#   4. ~/.config ~/.cache ~/.local ~/.java ইত্যাদি + /etc /opt /var থেকে
#      ফাইল ও ফোল্ডার — দুটোই — খুঁজে দেখায়, তারপর আপনার কনফার্মেশনে মোছে
#   5. mimeapps.list থেকে ডিফল্ট-অ্যাপ এন্ট্রি, খালি parent ফোল্ডার ও
#      AUR build ক্যাশ পরিষ্কার করে
#
#  ব্যবহার:  ./purge.sh [options] <app> [app2 ...]
# =====================================================================
set -u

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'; C=$'\e[1;36m'; N=$'\e[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${R}❌ $*${N}" >&2; exit 1; }

usage() {
cat <<EOF
ব্যবহার: ${0##*/} [options] <app> [app2 ...]

Options:
  -n, --dry-run        কিছুই মুছবে না, শুধু কী কী মোছা হতো তা দেখাবে
  -y, --yes            কোনো প্রশ্ন ছাড়াই সব মুছবে (সাবধান!)
  -a, --all-variants   -bin / -git ইত্যাদি সব ভ্যারিয়েন্ট একসাথে মুছবে
  -d, --deep           ফাইলের ভেতরের লেখাতেও অ্যাপের নাম খুঁজবে (ধীর)
  -h, --help           এই সাহায্য

উদাহরণ:
  ${0##*/} cloudstream-desktop-bin
  ${0##*/} -n discord            # আগে dry-run দিয়ে দেখে নিন
  ${0##*/} -d obsidian spotify
EOF
}

# ---------------------------------------------------------------------
# আর্গুমেন্ট পার্সিং
# ---------------------------------------------------------------------
DRY=0; YES=0; ALLVAR=0; DEEP=0; APPS=()
while (($#)); do
    case "$1" in
        -n|--dry-run)      DRY=1 ;;
        -y|--yes)          YES=1 ;;
        -a|--all-variants) ALLVAR=1 ;;
        -d|--deep)         DEEP=1 ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; APPS+=("$@"); break ;;
        -*)                usage; die "Unknown option: $1" ;;
        *)                 APPS+=("$1") ;;
    esac
    shift
done

((${#APPS[@]})) || { usage; exit 1; }
((EUID == 0)) && die "root হিসেবে চালাবেন না — \$HOME ভুল হবে। সাধারণ ইউজার হিসেবে চালান (sudo স্ক্রিপ্ট নিজেই চাইবে)।"
command -v pacman >/dev/null 2>&1 || die "pacman পাওয়া যায়নি — এটি শুধু Arch-based সিস্টেমের জন্য।"

ask() { # $1 = প্রশ্ন; yes হলে 0 রিটার্ন করে
    ((YES)) && return 0
    local a
    read -r -p "$1 [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------
# গ্লোবাল ডেটা
# ---------------------------------------------------------------------
declare -A STOP=() KW=() PRIM=() SEEN_PKG=() KIND=() DEEPTAG=() DESK=() PROT=() ROOTSET=() SEEN_FP=()
PKGS=(); BINS=(); FLATPAKS=(); SNAPS=(); DEEPNOTES=(); FOUND=(); NAMEARGS=()

# খুব সাধারণ শব্দ — এগুলো কখনো কিওয়ার্ড হবে না (ভুল করে অন্য কিছু মোছা ঠেকাতে)
for w in app apps bin cache config configs data desktop dev doc docs etc gtk gtk2 gtk3 gtk4 \
         icon icons java lib lib32 libs linux local log logs node nodejs opt pacman python \
         python2 python3 qt qt5 qt6 run share snap src state sys system systemd test tmp usr \
         util utils var xorg base glibc bash sh dbus applications pixmaps theme themes font \
         fonts mime locale licenses man metainfo hicolor autostart keyrings trash dconf wayland \
         x11 user users default plugin plugins extension extensions module modules tools home root; do
    STOP[$w]=1
done

# এই নামের এন্ট্রি কখনো মোছা হবে না
for w in .config .cache .local .java .var snap share bin lib state icons applications autostart \
         mimeapps.list mimeinfo.cache hicolor trash systemd user flatpak keyrings dconf .ssh .gnupg; do
    PROT[$w]=1
done

# খালি parent ফোল্ডার মোছার সময় এই ফোল্ডারগুলোর ওপরে যাওয়া হবে না
for w in "$HOME" "$HOME/.config" "$HOME/.cache" "$HOME/.local" "$HOME/.local/share" \
         "$HOME/.local/state" "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.config/systemd" \
         "$HOME/.config/systemd/user" "$HOME/.java" "$HOME/.java/.userPrefs" "$HOME/.var" \
         "$HOME/.var/app" "$HOME/snap" "$HOME/.cache/paru" "$HOME/.cache/paru/clone" "$HOME/.cache/yay"; do
    ROOTSET["$w"]=1
done

VARIANT_SUF=(-bin -git -svn -hg -stable -beta -nightly -dev -debug -appimage -preview -latest)
EXTRA_SUF=(-desktop -gui -cli -qt -qt5 -qt6 -gtk -electron -app -client)

USER_SPECS=(
    "$HOME:1"
    "$HOME/.config:2" "$HOME/.cache:2" "$HOME/.local/share:2" "$HOME/.local/state:2"
    "$HOME/.local/bin:1" "$HOME/.local/lib:1"
    "$HOME/.local/share/icons:6"
    "$HOME/.config/systemd/user:2"
    "$HOME/.var/app:1" "$HOME/snap:1"
    "$HOME/.java/.userPrefs:5"
    "$HOME/.cache/paru/clone:1" "$HOME/.cache/yay:1"
)
SYS_SPECS=(
    "/etc:1" "/etc/systemd/system:2" "/opt:1" "/var/lib:1" "/var/cache:1" "/var/log:1"
    "/usr/local/bin:1" "/usr/local/share:1" "/usr/local/lib:1"
)

# ---------------------------------------------------------------------
# হেল্পার ফাংশন
# ---------------------------------------------------------------------
kw_ok() { # কিওয়ার্ড নিরাপদ কি না
    local k="$1" re='^[a-z0-9][a-z0-9._+-]*$'
    ((${#k} >= 3 && ${#k} <= 64)) || return 1
    [[ "$k" =~ $re ]] || return 1
    [[ -z "${STOP[$k]:-}" ]]
}

expand_add() { # $1 = নাম, $2 = "prim" হলে primary কিওয়ার্ড
    local k="${1,,}" v t
    k="${k#.}"
    local -a vars=("$k" "${k//-/}" "${k//-/_}" "${k//_/-}")
    t="$k"
    while [[ "$t" == *[0-9] ]]; do t="${t%?}"; done   # cloudstream3 -> cloudstream
    [[ -n "$t" ]] && vars+=("$t")
    for v in "${vars[@]}"; do
        kw_ok "$v" || continue
        KW["$v"]=1
        [[ "${2:-}" == prim ]] && PRIM["$v"]=1
    done
    return 0
}

strip_with() { # $1 = নাম, বাকিগুলো = সাফিক্স লিস্ট; ফলাফল $REPLY তে
    local s="${1,,}" suf ch=1
    shift
    while ((ch)); do
        ch=0
        for suf in "$@"; do
            if [[ "$s" == *"$suf" && "$s" != "$suf" ]]; then
                s="${s%"$suf"}"; ch=1
            fi
        done
    done
    REPLY="$s"
}

safe_name() { [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]; }

related() { # n কি কোনো primary কিওয়ার্ডের সাথে সম্পর্কিত?
    local n="$1" p
    ((${#n} >= 4)) || return 1
    for p in "${!PRIM[@]}"; do
        [[ "$n" == *"$p"* || "$p" == *"$n"* ]] && return 0
    done
    return 1
}

find_pkgs() { # $1 = ইনপুট নাম; ফলাফল FOUND অ্যারেতে
    local in="$1" p base
    FOUND=()
    if pacman -Qq -- "$in" &>/dev/null; then
        FOUND+=("$in")
        pacman -Qq -- "$in-debug" &>/dev/null && FOUND+=("$in-debug")
        ((ALLVAR)) || return 0
    fi
    strip_with "$in" "${VARIANT_SUF[@]}"; base="$REPLY"
    while IFS= read -r p; do
        [[ "$p" == "$in" || "$p" == "$in-debug" ]] && continue
        strip_with "$p" "${VARIANT_SUF[@]}"
        [[ "$REPLY" == "$base" ]] && FOUND+=("$p")
    done < <(pacman -Qq)
    return 0
}

tarball_for() { # প্যাকেজ আগেই মোছা থাকলে ক্যাশ থেকে .pkg.tar খোঁজে
    local n f
    for n in "$@"; do
        f=$(ls -t /var/cache/pacman/pkg/"$n"-[0-9]*.pkg.tar.* \
                  "$HOME/.cache/paru/clone/$n/$n"-[0-9]*.pkg.tar.* \
                  "$HOME/.cache/yay/$n/$n"-[0-9]*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -n1)
        if [[ -n "$f" ]]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

derive_from_paths() { # stdin: প্যাকেজের ফাইল পাথ — থেকে কিওয়ার্ড বের করে
    local -a lines=() dirs=() bins=()
    local f id n b
    mapfile -t lines
    for f in "${lines[@]}"; do
        case "$f" in
            /usr/bin/?*|/usr/local/bin/?*)
                [[ "$f" == */ ]] && continue
                b="${f##*/}"; safe_name "$b" && bins+=("$b") ;;
            /usr/share/applications/*.desktop)
                id="${f##*/}"; id="${id%.desktop}"
                safe_name "$id" || continue
                DESK["$id"]=1
                expand_add "$id"
                [[ "$id" == *.* ]] && expand_add "${id##*.}" ;;
            /opt/*/|/usr/share/*/|/usr/lib/*/|/usr/lib32/*/)
                dirs+=("$f") ;;
        esac
    done
    if ((${#bins[@]} > 0 && ${#bins[@]} <= 3)); then
        for b in "${bins[@]}"; do expand_add "$b"; BINS+=("$b"); done
    fi
    local re='^/(opt|usr/share|usr/lib|usr/lib32)/([^/]+)/$'
    for f in "${dirs[@]}"; do
        [[ "$f" =~ $re ]] || continue
        n="${BASH_REMATCH[2]}"; n="${n,,}"
        safe_name "$n" || continue
        if [[ -n "${KW["$n"]:-}" ]] || related "$n"; then expand_add "$n"; fi
    done
    return 0
}

name_args() { # $1 = wide|strict ; বাকিগুলো = কিওয়ার্ড; ফলাফল NAMEARGS এ
    local mode="$1" k pat first=1
    shift
    NAMEARGS=('(')
    for k in "$@"; do
        local -a pats=()
        if [[ "$mode" == wide ]] && ((${#k} >= 6)); then
            pats=("*${k}*")
        else
            pats=("$k" "${k}.*" "${k}-*" "${k}_*" ".${k}" ".${k}.*" ".${k}-*" ".${k}_*")
        fi
        for pat in "${pats[@]}"; do
            ((first)) || NAMEARGS+=(-o)
            NAMEARGS+=(-iname "$pat"); first=0
        done
    done
    NAMEARGS+=(')')
}

is_protected() {
    local p="$1" b="${1##*/}"
    [[ "$p" == "$HOME" || "$p" == "/" ]] && return 0
    [[ -n "${PROT["${b,,}"]:-}" ]]
}

add_found() { # $1 = user|root ; $2 = path ; $3 = deep (ঐচ্ছিক)
    local k="$1" p="$2"
    is_protected "$p" && return 0
    if [[ -z "${KIND["$p"]:-}" ]]; then
        KIND["$p"]="$k"
        [[ "${3:-}" == deep ]] && DEEPTAG["$p"]=1
    elif [[ "${3:-}" != deep ]]; then
        unset 'DEEPTAG["$p"]' 2>/dev/null
    fi
    return 0
}

scan_user() {
    local spec dir depth m
    local -a extra=() ks=("${!KW[@]}")
    ((${#ks[@]})) || return 0
    name_args wide "${ks[@]}"
    for spec in "${USER_SPECS[@]}"; do
        dir="${spec%:*}"; depth="${spec##*:}"
        [[ -d "$dir" ]] || continue
        extra=()
        [[ "$dir" == "$HOME" ]] && extra=(-name '.*')
        while IFS= read -r -d '' m; do
            add_found user "$m"
        done < <(find "$dir" -mindepth 1 -maxdepth "$depth" "${extra[@]}" "${NAMEARGS[@]}" -print0 2>/dev/null)
    done
}

scan_system() {
    local spec dir depth m
    local -a ks=("${!PRIM[@]}")
    ((${#ks[@]})) || return 0
    name_args strict "${ks[@]}"
    for spec in "${SYS_SPECS[@]}"; do
        dir="${spec%:*}"; depth="${spec##*:}"
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' m; do
            pacman -Qoq -- "$m" &>/dev/null && continue   # অন্য প্যাকেজের ফাইল হলে ছোঁবে না
            add_found root "$m"
        done < <(find "$dir" -mindepth 1 -maxdepth "$depth" "${NAMEARGS[@]}" -print0 2>/dev/null)
    done
}

is_shared_file() {
    case "${1,,}" in
        mimeapps.list|mimeinfo.cache|*.xbel|*history*|*bookmark*|*rc|user-dirs.*|dconf*|*.pacnew) return 0 ;;
    esac
    return 1
}

scan_deep() { # ফাইলের ভেতরের লেখায় নাম খোঁজে (ব্রাউজার প্রোফাইল বাদ)
    local k f r
    local -a ga=() roots=()
    for k in "${!PRIM[@]}"; do ((${#k} >= 5)) && ga+=(-e "$k"); done
    ((${#ga[@]})) || return 0
    for r in "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state" "$HOME/.java"; do
        [[ -d "$r" ]] && roots+=("$r")
    done
    ((${#roots[@]})) || return 0
    while IFS= read -r -d '' f; do
        if is_shared_file "${f##*/}"; then DEEPNOTES+=("$f"); continue; fi
        add_found user "$f" deep
    done < <(
        find "${roots[@]}" -maxdepth 5 \
            \( -type d \( -iname '*chrom*' -o -iname '*mozilla*' -o -iname '*firefox*' \
                -o -iname 'BraveSoftware' -o -iname '*vivaldi*' -o -iname '*opera*' \
                -o -iname 'Trash' -o -iname '.git' -o -iname 'node_modules' \
                -o -iname 'flatpak' -o -iname 'Steam' -o -iname 'pacman' \) -prune \) -o \
            -type f -size -1024k -print0 2>/dev/null |
        xargs -0 -r grep -IlsiFZ "${ga[@]}" -- 2>/dev/null
    )
}

hs() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

safe_to_delete() { # $1 = user|root ; $2 = path
    local k="$1" p="$2"
    [[ -n "$p" && "$p" == /* && "$p" != "/" && "$p" != *"/../"* && "$p" != */.. ]] || return 1
    if [[ "$k" == user ]]; then
        [[ "$p" == "$HOME"/?* ]]
    else
        case "$p" in
            /etc/?*|/opt/?*|/var/lib/?*|/var/cache/?*|/var/log/?*|/usr/local/?*) return 0 ;;
        esac
        return 1
    fi
}

prune_empty_parents() {
    local d="${1%/*}"
    while [[ "$d" == "$HOME"/* && -z "${ROOTSET["$d"]:-}" && "$d" != "$HOME/.local/share/icons"* ]]; do
        rmdir -- "$d" 2>/dev/null || break
        d="${d%/*}"
    done
}

cleanup_mimeapps() {
    local f id k esc
    local -a ids=()
    for id in "${!DESK[@]}"; do ids+=("$id"); done
    for k in "${!PRIM[@]}"; do ((${#k} >= 4)) && ids+=("$k"); done
    for f in "$HOME/.config/mimeapps.list" "$HOME/.local/share/applications/mimeapps.list"; do
        [[ -f "$f" ]] || continue
        for id in "${ids[@]}"; do
            if grep -qiF -- "$id.desktop" "$f"; then
                [[ -f "$f.bak-purge" ]] || cp -- "$f" "$f.bak-purge"
                esc="${id//./\\.}"
                sed -i "s/${esc}\.desktop;\{0,1\}//Ig" "$f"
                sed -i '/^[^=#[][^=]*=[[:space:]]*$/d' "$f"
                say "  🧽 Removed default-app entry: $id (backup: ${f##*/}.bak-purge)"
            fi
        done
    done
}

# =====================================================================
#  ধাপ ১: বিশ্লেষণ
# =====================================================================
say "=============================================="
say " 🧹 Arch Purge — complete uninstaller"
((DRY)) && say " ${Y}(dry-run: কিছুই মোছা হবে না)${N}"
say "=============================================="

for app in "${APPS[@]}"; do
    a="${app,,}"
    say "\n--- Analyzing: ${B}${a}${N} ---"

    strip_with "$a" "${VARIANT_SUF[@]}"; vbase="$REPLY"
    strip_with "$vbase" "${EXTRA_SUF[@]}"; xbase="$REPLY"
    for k in "$a" "$vbase" "$xbase"; do expand_add "$k" prim; done

    find_pkgs "$a"
    if ((${#FOUND[@]})); then
        for p in "${FOUND[@]}"; do
            [[ -n "${SEEN_PKG["$p"]:-}" ]] && continue
            SEEN_PKG["$p"]=1; PKGS+=("$p")
            say "📦 Installed package: ${G}${p}${N}"
            derive_from_paths < <(pacman -Ql "$p" 2>/dev/null | sed 's/^[^ ]* //')
        done
    else
        say "⚠️  '$a' নামে কোনো ইনস্টল্ড প্যাকেজ নেই — শুধু leftover খোঁজা হবে।"
        if tb=$(tarball_for "$a" "$a-bin" "$a-git" "$vbase" "$vbase-bin" "$vbase-git" \
                            "$xbase" "$xbase-bin" "$xbase-git"); then
            say "🗃️  ক্যাশে প্যাকেজ পাওয়া গেছে: ${tb##*/} — এর ফাইল-লিস্ট থেকে নাম বের করছি"
            derive_from_paths < <(pacman -Qlp "$tb" 2>/dev/null | sed 's/^[^ ]* //')
        fi
    fi

    # Flatpak
    if command -v flatpak >/dev/null 2>&1; then
        while IFS= read -r id; do
            [[ -n "$id" && -z "${SEEN_FP["$id"]:-}" ]] || continue
            lc="${id,,}"
            for k in "${!PRIM[@]}"; do
                if ((${#k} >= 5)) && [[ "$lc" == *"$k"* ]]; then
                    SEEN_FP["$id"]=1; FLATPAKS+=("$id"); break
                fi
            done
        done < <(flatpak list --app --columns=application 2>/dev/null)
    fi

    # Snap
    if command -v snap >/dev/null 2>&1; then
        while IFS= read -r s; do
            [[ -n "$s" && -n "${PRIM["${s,,}"]:-}" ]] && SNAPS+=("$s")
        done < <(snap list 2>/dev/null | awk 'NR>1{print $1}')
    fi
done

((${#PRIM[@]})) || die "নামটি খুব সাধারণ/ছোট — নিরাপত্তার জন্য কিওয়ার্ড বানানো গেল না।"

say "\n🎯 Keywords: ${C}$(printf '%s\n' "${!KW[@]}" | sort | paste -sd' ' -)${N}"

# চলমান প্রসেস
declare -A PSEEN=()
RUNNING=()
for n in "${BINS[@]}" "${!PRIM[@]}"; do
    [[ -n "${PSEEN["$n"]:-}" ]] && continue
    PSEEN["$n"]=1
    pgrep -xi -- "$n" >/dev/null 2>&1 && RUNNING+=("$n")
done

# =====================================================================
#  ধাপ ২: আনইনস্টল (pacman / flatpak / snap)
# =====================================================================
if ((${#PKGS[@]} + ${#FLATPAKS[@]} + ${#SNAPS[@]})); then
    say "\n📋 ${Y}Uninstall plan:${N}"
    ((${#PKGS[@]}))     && say "   pacman : ${PKGS[*]}"
    ((${#FLATPAKS[@]})) && say "   flatpak: ${FLATPAKS[*]}"
    ((${#SNAPS[@]}))    && say "   snap   : ${SNAPS[*]}"

    if ((DRY)); then
        say "   ${Y}[dry-run] উপরের প্যাকেজগুলো মোছা হতো${N}"
    else
        ask "এগিয়ে যাবেন?" || { say "❌ Aborted."; exit 0; }

        if ((${#RUNNING[@]})); then
            say "⚙️  চলমান প্রসেস: ${RUNNING[*]}"
            if ask "এগুলো kill করবেন?"; then
                for n in "${RUNNING[@]}"; do pkill -xi -- "$n" 2>/dev/null; done
                sleep 1
            fi
        fi

        if ((${#PKGS[@]})); then
            pargs=(-Rns)
            ((YES)) && pargs+=(--noconfirm)
            sudo pacman "${pargs[@]}" -- "${PKGS[@]}" \
                || die "pacman রিমুভ ব্যর্থ বা বাতিল হয়েছে — তাই ইউজার ডেটা ছোঁয়া হয়নি।"
        fi
        for id in "${FLATPAKS[@]}"; do flatpak uninstall -y --delete-data "$id"; done
        for s in "${SNAPS[@]}"; do sudo snap remove --purge "$s"; done
    fi
fi

# =====================================================================
#  ধাপ ৩: leftover স্ক্যান
# =====================================================================
say "\n🔍 Scanning leftovers (ইউজার + সিস্টেম)..."
scan_user
scan_system
if ((DEEP)); then
    say "🔬 Deep scan চলছে (ফাইলের ভেতরে খোঁজা)..."
    scan_deep
fi

KEEP=(); SORTED=()
if ((${#KIND[@]})); then
    mapfile -d '' -t SORTED < <(printf '%s\0' "${!KIND[@]}" | LC_ALL=C sort -z)
fi
for p in "${SORTED[@]}"; do
    skip=0
    for q in "${KEEP[@]}"; do
        [[ "$p" == "$q"/* ]] && { skip=1; break; }
    done
    ((skip)) || KEEP+=("$p")
done

if ((${#KEEP[@]} == 0)); then
    ((DRY)) || cleanup_mimeapps
    say "\n✅ ${G}কোনো leftover পাওয়া যায়নি — সিস্টেম পরিষ্কার!${N}"
    if ((${#DEEPNOTES[@]})); then
        say "\nℹ️  এই শেয়ার্ড ফাইলগুলোর ভেতরে নামটি আছে (নিজে থেকে মোছা হয়নি):"
        printf '   %s\n' "${DEEPNOTES[@]}"
    fi
    exit 0
fi

say "\n🗑️  ${R}নিচের leftover পাওয়া গেছে:${N}"
SIZES=(); total=0
for i in "${!KEEP[@]}"; do
    p="${KEEP[i]}"
    sz=$(du -sb -- "$p" 2>/dev/null | cut -f1); sz="${sz:-0}"
    SIZES[i]="$sz"; total=$((total + sz))
    tag="${KIND["$p"]}"; [[ -n "${DEEPTAG["$p"]:-}" ]] && tag="$tag,deep"
    printf ' %3d) [%-9s] %s  (%s)\n' "$((i + 1))" "$tag" "$p" "$(hs "$sz")"
done
say "------------------------------------------"
say "📊 ${Y}Total: $(hs "$total") — ${#KEEP[@]} টি আইটেম${N}"
say "------------------------------------------"
if ((${#DEEPNOTES[@]})); then
    say "ℹ️  শেয়ার্ড ফাইল (ভেতরে নাম আছে, মোছা হবে না): ${#DEEPNOTES[@]} টি"
    printf '     %s\n' "${DEEPNOTES[@]}"
fi

if ((DRY)); then
    say "\n${Y}[dry-run] কিছুই মোছা হয়নি।${N}"
    exit 0
fi

# =====================================================================
#  ধাপ ৪: নির্বাচন ও মোছা
# =====================================================================
declare -A EXC=()
if ((!YES)); then
    say ""
    read -r -p "Enter = সব মুছবে | বাদ দিতে নম্বর দিন (যেমন: 2 5) | n = বাতিল: " ans
    case "${ans,,}" in n|no|q) say "❌ Aborted. কিছু মোছা হয়নি."; exit 0 ;; esac
    for t in $ans; do
        if [[ "$t" =~ ^[0-9]+$ ]]; then
            EXC["$t"]=1
        elif [[ "${t,,}" == y || "${t,,}" == a ]]; then
            :
        else
            say "❌ অবৈধ ইনপুট '$t' — কিছু মোছা হয়নি."; exit 1
        fi
    done
fi

deleted=0; freed=0; failed=0
for i in "${!KEEP[@]}"; do
    [[ -n "${EXC["$((i + 1))"]:-}" ]] && continue
    p="${KEEP[i]}"; k="${KIND["$p"]}"
    if ! safe_to_delete "$k" "$p"; then
        say "  ⛔ Skipped (unsafe path): $p"; continue
    fi
    if [[ "$k" == user ]]; then
        rm -rf -- "$p" 2>/dev/null
        prune_empty_parents "$p"
    else
        sudo rm -rf -- "$p"
    fi
    if [[ -e "$p" || -L "$p" ]]; then
        failed=$((failed + 1)); say "  ⚠️  মোছা যায়নি: $p"
    else
        deleted=$((deleted + 1)); freed=$((freed + SIZES[i]))
    fi
done

cleanup_mimeapps
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
hash -r 2>/dev/null

say "\n✅ ${G}Cleanup complete!${N} Deleted ${deleted} items, freed ~$(hs "$freed")."
((failed)) && say "⚠️  ${failed} টি আইটেম মোছা যায়নি (পারমিশন/ব্যবহারে থাকতে পারে)।"
exit 0