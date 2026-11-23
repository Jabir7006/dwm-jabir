#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  setup-secrets.sh — API token/key আলাদা ফাইলে রাখে (chmod 600)
#  GitHub-এ কোনো secret যায় না।
#
#  লেখে:
#    ~/.config/dwm-titus/secrets.env   (bash/zsh)
#    ~/.config/dwm-titus/secrets.fish  (fish)
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dwm-titus"
ENV_FILE="$DIR/secrets.env"
FISH_FILE="$DIR/secrets.fish"
mkdir -p "$DIR"
touch "$ENV_FILE" "$FISH_FILE"
chmod 600 "$ENV_FILE" "$FISH_FILE"

ask() {
  local label="$1" val
  read -rsp "$label (খালি রাখলে আগেরটা থাকবে): " val || true
  echo >&2
  printf '%s' "$val"
}

write_var() {
  local var="$1" val="$2" file="$3" fmt="$4" pattern
  [[ -z "$val" ]] && return 0
  if [[ "$fmt" == "fish" ]]; then
    pattern="^[[:space:]]*set -gx ${var} "
  else
    pattern="^[[:space:]]*(export )?${var}="
  fi
  grep -vE "$pattern" "$file" > "$file.tmp" 2>/dev/null || true
  mv "$file.tmp" "$file"
  if [[ "$fmt" == "fish" ]]; then
    # fish-safe single quoting
    val="${val//\'/\\\'}"
    printf "set -gx %s '%s'\n" "$var" "$val" >> "$file"
  else
    printf 'export %s=%q\n' "$var" "$val" >> "$file"
  fi
}

echo "API token/key সেটআপ (Enter চাপলে skip)"
echo ""

V1="$(ask 'AgentRouter token')"
V2="$(ask 'OpenWeather API key')"

write_var AGENT_ROUTER_TOKEN "$V1" "$ENV_FILE" env
write_var OPENWEATHER_API_KEY "$V2" "$ENV_FILE" env
write_var AGENT_ROUTER_TOKEN "$V1" "$FISH_FILE" fish
write_var OPENWEATHER_API_KEY "$V2" "$FISH_FILE" fish

chmod 600 "$ENV_FILE" "$FISH_FILE"
echo ""
echo "✅ লেখা হয়েছে:"
echo "   $ENV_FILE"
echo "   $FISH_FILE"
echo ""
echo "নতুন shell খুললে token কাজ করবে।"
echo "এই ফাইলগুলো কখনো GitHub-এ push করবেন না।"
