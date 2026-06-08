#!/usr/bin/env bash
# Install the Claude status line into the running VM for the vibe user.
#
# Source of truth is guest/statusline-command.sh (committed, so builds are
# reproducible). By default this first refreshes that vendored copy from your
# host's live status line (~/.claude/statusline-command.sh) if it differs, then
# installs it into the VM. Pass --no-host-refresh to install the vendored copy
# as-is (used by create-vm.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VM=vibevm
SRC="$HERE/guest/statusline-command.sh"
HOST_SL="$HOME/.claude/statusline-command.sh"

refresh=1
[ "${1:-}" = "--no-host-refresh" ] && refresh=0

incus info "$VM" >/dev/null 2>&1 || { echo "VM '$VM' not found — run ./create-vm.sh first." >&2; exit 1; }

if [ "$refresh" = 1 ] && [ -f "$HOST_SL" ] && ! cmp -s "$HOST_SL" "$SRC" 2>/dev/null; then
  cp "$HOST_SL" "$SRC"
  echo "Refreshed guest/statusline-command.sh from $HOST_SL — commit it to keep builds in sync."
fi
[ -f "$SRC" ] || { echo "No status line script at $SRC." >&2; exit 1; }

incus exec "$VM" -- install -d -o vibe -g vibe /home/vibe/.claude
incus file push "$SRC" "$VM/home/vibe/.claude/statusline-command.sh" \
  --uid "$(id -u)" --gid "$(id -g)" --mode 0755
incus exec "$VM" -- bash -c 'S=/home/vibe/.claude/settings.json; t=$(mktemp); { [ -f "$S" ] && cat "$S" || echo "{}"; } | jq ".statusLine={type:\"command\",command:\"bash ~/.claude/statusline-command.sh\"}" > "$t" && install -o vibe -g vibe -m 0644 "$t" "$S" && rm -f "$t"'

echo "Status line installed in the VM (re-open ./vibe to see changes)."
