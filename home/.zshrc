
# PortProton patches: re-apply if a PortProton update/reinstall wiped them
if ! grep -q "pp_patch: DXVK matches DXVK_FILTER_DEVICE_NAME" "$HOME/PortProton/data/scripts/functions_helper" 2>/dev/null ; then
    "$HOME/.local/share/portproton-patch/install.sh" >/dev/null 2>&1 || true
fi

# Codex (AgentRouter) API key — install.sh runs: setup-secrets.sh
[ -f "$HOME/.config/dwm-titus/secrets.env" ] && . "$HOME/.config/dwm-titus/secrets.env"
export AGENT_ROUTER_TOKEN="${AGENT_ROUTER_TOKEN:-}"
