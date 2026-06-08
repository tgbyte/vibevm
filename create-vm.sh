#!/usr/bin/env bash
# Creates + provisions the vibevm sandbox. Run as your normal user AFTER
# bootstrap.sh and a re-login (so you're in the incus-admin group). Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

VM=vibevm
IMG="images:ubuntu/26.04"
CPU=8
MEM=16GiB
DISK=40GiB

if ! incus info >/dev/null 2>&1; then
  echo "Can't reach the incus daemon. Run ./bootstrap.sh first, then start a new shell." >&2
  exit 1
fi

mkdir -p "$HERE/project"

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
incus file push "$HERE/guest/devtools.sh"      "$VM/usr/local/bin/devtools.sh"      --mode 0755
incus file push "$HERE/guest/docker.sh"        "$VM/usr/local/bin/docker.sh"        --mode 0755
incus file push "$HERE/guest/init-firewall.sh" "$VM/usr/local/bin/init-firewall.sh" --mode 0755

echo "== Provisioning (installs tooling, creates vibe user, enables firewall) =="
incus exec "$VM" --env HOST_UID="$(id -u)" --env HOST_GID="$(id -g)" -- bash /root/provision.sh

echo "== Sharing $HERE/project -> /home/vibe/project (virtiofs) =="
incus config device get "$VM" project source >/dev/null 2>&1 || \
  incus config device add "$VM" project disk source="$HERE/project" path=/home/vibe/project

echo "== Baseline snapshot 'clean' =="
incus snapshot show "$VM" clean >/dev/null 2>&1 || incus snapshot create "$VM" clean

cat <<EOF

VM '$VM' is ready.

Next:
  1. (optional) put a SCOPED key in secrets.env:   echo 'ANTHROPIC_API_KEY=sk-ant-...' > secrets.env
  2. start vibe-coding in auto mode:               ./vibe
     or get a plain shell in the VM:               ./vibe shell

Your code lives in ./project (shared live with the VM at /home/vibe/project).
EOF
