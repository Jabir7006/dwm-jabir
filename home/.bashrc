#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

# Run fastfetch on shell initialization
command -v fastfetch &>/dev/null && fastfetch
command -v fnm &>/dev/null && eval "$(fnm env --use-on-cd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# PortProton patches: re-apply if a PortProton update/reinstall wiped them
if ! grep -q "pp_patch: DXVK matches DXVK_FILTER_DEVICE_NAME" "$HOME/PortProton/data/scripts/functions_helper" 2>/dev/null ; then
    "$HOME/.local/share/portproton-patch/install.sh" >/dev/null 2>&1 || true
fi

# Codex (AgentRouter) API key — install.sh runs: setup-secrets.sh
# (এই ফাইলে আসল token রাখবেন না; GitHub-এ যাবে)
[ -f "$HOME/.config/dwm-titus/secrets.env" ] && . "$HOME/.config/dwm-titus/secrets.env"
export AGENT_ROUTER_TOKEN="${AGENT_ROUTER_TOKEN:-}"
