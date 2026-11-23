#!/usr/bin/env bash
# The only steps that need root. Run once, then logout/login.
set -euo pipefail

echo "== [1/1] Adding $USER to the 'input' group (keystroke read permission)"
sudo usermod -aG input "$USER"

echo
echo "Done. IMPORTANT: full logout/login is required for the group to apply."
echo "Verify after login with:  id -nG | grep -w input"
echo "Then test with:           wayclick on"
