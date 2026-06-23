#!/usr/bin/env bash
# Persist the VM's ~/.claude (history, sessions, file-based memory, plans, tasks,
# auth) on the host so it survives VM rebuilds (incus delete + ./create-vm.sh).
# Mounts host ./claude-home -> /home/vibe/.claude via virtiofs.
#
# Idempotent: if not yet attached, it first migrates any existing in-VM ~/.claude
# to the host dir (when the host dir is still empty), then attaches the mount.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/config.sh"
VM="$VM_NAME"
HOST_DIR="$HERE/claude-home"
GUEST=/home/vibe/.claude

incus info "$VM" >/dev/null 2>&1 || { echo "VM '$VM' not found — run ./create-vm.sh first." >&2; exit 1; }
mkdir -p "$HOST_DIR"

if incus config device get "$VM" claude-home source >/dev/null 2>&1; then
  echo "~/.claude already persisted (device 'claude-home' attached)."
  exit 0
fi

# Don't clobber a live session — adding the mount would yank ~/.claude out from
# under a running claude.
if incus exec "$VM" -- pgrep -x claude >/dev/null 2>&1; then
  echo "A claude process is running in the VM. Close it (exit ./vibe), then re-run." >&2
  exit 1
fi

# Migrate existing in-VM state to the host dir, but only if the host dir is empty
# (so we never overwrite an already-populated claude-home).
if [ -z "$(ls -A "$HOST_DIR" 2>/dev/null)" ] \
   && incus exec "$VM" -- sh -c "[ -d $GUEST ] && [ -n \"\$(ls -A $GUEST 2>/dev/null)\" ]"; then
  echo "Migrating $GUEST from the VM into $HOST_DIR ..."
  incus exec "$VM" -- tar -C "$GUEST" -cf - . | tar -C "$HOST_DIR" -xpf - --no-same-owner
fi

incus exec "$VM" -- install -d -o vibe -g vibe "$GUEST"
echo "Attaching $HOST_DIR -> $GUEST (virtiofs)"
incus config device add "$VM" claude-home disk source="$HOST_DIR" path="$GUEST" >/dev/null
for _ in $(seq 1 30); do
  incus exec "$VM" -- findmnt -rno TARGET "$GUEST" >/dev/null 2>&1 && break
  sleep 0.3
done

echo "Done. ~/.claude is now backed by $HOST_DIR and survives VM rebuilds."
