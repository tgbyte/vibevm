#!/usr/bin/env bash
# Creates + provisions the vibevm sandbox. Run as your normal user AFTER
# bootstrap.sh and a re-login (so you're in the incus-admin group). Idempotent;
# pass --rebuild to delete the existing VM and recreate it from scratch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

VM=vibevm
IMG="images:ubuntu/26.04"
CPU=8
MEM=16GiB
DISK=40GiB

REBUILD=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -r|--rebuild) REBUILD=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--rebuild] [--yes]"
      echo "  --rebuild  delete the existing VM and recreate it (host-backed"
      echo "             ./claude-home and ./workspace mounts are preserved)"
      echo "  --yes      skip the delete confirmation prompt"
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if ! incus info >/dev/null 2>&1; then
  echo "Can't reach the incus daemon. Run ./bootstrap.sh first, then start a new shell." >&2
  exit 1
fi

mkdir -p "$HERE/workspace"

if [ "$REBUILD" = 1 ] && incus info "$VM" >/dev/null 2>&1; then
  # Capture ~/.claude to the host before wiping the VM disk, unless it's already
  # host-backed (claude-home device attached). persist-claude.sh refuses while a
  # claude session is running, which aborts the rebuild here — by design.
  if ! incus config device get "$VM" claude-home source >/dev/null 2>&1; then
    echo "== ~/.claude not yet persisted — capturing it to the host first =="
    bash "$HERE/persist-claude.sh"
  fi
  echo "Rebuilding: this DELETES the VM '$VM' and its snapshots."
  echo "Preserved (host-backed): ./claude-home (~/.claude), ./workspace + workspaces.conf mounts, secrets.env."
  echo "Anything stored only on the VM disk is lost."
  if [ "$ASSUME_YES" != 1 ]; then
    printf "Proceed? [y/N] "; read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
  fi
  echo "== Deleting VM '$VM' =="
  incus delete --force "$VM"
fi

if ! incus info "$VM" >/dev/null 2>&1; then
  echo "== Launching VM '$VM' ($IMG, ${CPU} vCPU / ${MEM} / ${DISK}) =="
  incus launch "$IMG" "$VM" --vm \
    -c limits.cpu="$CPU" -c limits.memory="$MEM" \
    -d root,size="$DISK"
else
  echo "== VM '$VM' already exists =="
  [ "$(incus info "$VM" | awk '/Status/{print $2}')" = RUNNING ] || incus start "$VM"
fi

echo "== Waiting for the VM agent =="
until incus exec "$VM" -- true 2>/dev/null; do sleep 2; done

echo "== Waiting for network/DNS =="
until incus exec "$VM" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; do sleep 2; done

echo "== Pushing provisioning scripts =="
incus file push "$HERE/guest/provision.sh"     "$VM/root/provision.sh"              --mode 0755
incus file push "$HERE/guest/harden.sh"        "$VM/usr/local/bin/harden.sh"        --mode 0755
incus file push "$HERE/guest/timesync.sh"      "$VM/usr/local/bin/timesync.sh"      --mode 0755
incus file push "$HERE/guest/devtools.sh"      "$VM/usr/local/bin/devtools.sh"      --mode 0755
incus file push "$HERE/guest/docker.sh"        "$VM/usr/local/bin/docker.sh"        --mode 0755
incus file push "$HERE/guest/init-firewall.sh" "$VM/usr/local/bin/init-firewall.sh" --mode 0755
incus file push "$HERE/guest/firewall.sh"      "$VM/usr/local/sbin/vibe-firewall"   --mode 0755

echo "== Provisioning (installs tooling, creates vibe user, enables firewall) =="
incus exec "$VM" --env HOST_UID="$(id -u)" --env HOST_GID="$(id -g)" -- bash /root/provision.sh

echo "== Mounting workspace directories (virtiofs) =="
bash "$HERE/mount-workspaces.sh"

echo "== Persisting ~/.claude across rebuilds =="
bash "$HERE/persist-claude.sh"

echo "== Installing the Claude status line for vibe =="
bash "$HERE/sync-statusline.sh" --no-host-refresh

echo "== Baseline snapshot 'clean' (VM stopped to avoid the fsfreeze hang) =="
if ! incus snapshot show "$VM" clean >/dev/null 2>&1; then
  incus stop "$VM" --timeout 60
  incus snapshot create "$VM" clean
  incus start "$VM"
  until incus exec "$VM" -- true 2>/dev/null; do sleep 2; done
fi

cat <<EOF

VM '$VM' is ready.

Next:
  1. (optional) put a SCOPED key in secrets.env:   echo 'ANTHROPIC_API_KEY=sk-ant-...' > secrets.env
  2. start vibe-coding in auto mode:               ./vibe
     or get a plain shell in the VM:               ./vibe shell

Mount projects under ~/workspace: drop/clone them into ./workspace/<name>/ or list
host paths in ./workspaces.conf, then run ./vibe mounts (see workspaces.conf.example).
EOF
