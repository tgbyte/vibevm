#!/usr/bin/env bash
# ONE-TIME host setup. Needs root (will prompt for sudo). After it runs you must
# start a NEW shell (or restart Claude Code) so the new group membership applies.
set -euo pipefail

echo "== Starting + enabling the incus daemon =="
sudo systemctl enable --now incus.socket incus.service

echo "== Adding $USER to the incus-admin group =="
sudo usermod -aG incus-admin "$USER"

echo "== Minimal incus init (storage pool + bridge network) =="
if ! sudo incus storage list --format csv 2>/dev/null | grep -q .; then
  sudo incus admin init --minimal
else
  echo "   (already initialized, skipping)"
fi

cat <<'EOF'

Bootstrap done.

IMPORTANT: the incus-admin group only applies to NEW sessions. Either:
  - open a new terminal, or
  - restart Claude Code,
then run:  ./create-vm.sh
EOF
