#!/usr/bin/env bash
# ONE-TIME host setup. Needs root (will prompt for sudo). After it runs you must
# start a NEW shell (or restart Claude Code) so the new group membership applies.
set -euo pipefail

# incus must already be installed (this script only starts/inits the daemon).
if ! command -v incus >/dev/null 2>&1; then
  cat >&2 <<'MSG'
incus is not installed. Install it on the host first (see README "Prerequisites"):
  Ubuntu (24.04+):  sudo apt install incus qemu-system
  Arch Linux:       sudo pacman -S incus qemu-base edk2-ovmf dnsmasq
Then re-run ./bootstrap.sh.
MSG
  exit 1
fi

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
