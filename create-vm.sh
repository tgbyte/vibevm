#!/usr/bin/env bash
# Creates + provisions the vibevm sandbox. Run as your normal user AFTER
# bootstrap.sh and a re-login (so you're in the incus-admin group). Idempotent;
# pass --rebuild to delete the existing VM and recreate it from scratch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/config.sh"

VM="$VM_NAME"
IMG="$VM_IMAGE"
CPU="$VM_CPU"
MEM="$VM_MEM"
DISK="$VM_DISK"

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
  # host-backed (claude-home device attached) or the VM has no ~/.claude to rescue.
  # The empty-check matters when a previous run was interrupted before provision.sh
  # created the 'vibe' user: such a VM has no vibe user and an empty ~/.claude, so
  # persist-claude.sh would die on 'install -o vibe' and abort every rebuild — yet
  # there's nothing to capture (the host claude-home, preserved across rebuilds,
  # already holds the real state). persist-claude.sh refuses while a claude session
  # is running, which aborts the rebuild here — by design.
  if ! incus config device get "$VM" claude-home source >/dev/null 2>&1 \
     && incus exec "$VM" -- sh -c '[ -n "$(ls -A /home/vibe/.claude 2>/dev/null)" ]'; then
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

# The egress allowlist is a host file pushed into the VM (harden.sh installs it as
# /etc/tinyproxy/allowlist). Seed the gitignored working copy from the example on
# first run so a fresh clone has a non-empty list (default-deny needs one).
[ -f "$HERE/allowlist" ] || cp "$HERE/allowlist.example" "$HERE/allowlist"

echo "== Pushing provisioning scripts =="
incus file push "$HERE/guest/provision.sh"     "$VM/root/provision.sh"              --mode 0755
incus file push "$HERE/guest/harden.sh"        "$VM/usr/local/bin/harden.sh"        --mode 0755
incus file push "$HERE/guest/timesync.sh"      "$VM/usr/local/bin/timesync.sh"      --mode 0755
incus file push "$HERE/guest/devtools.sh"      "$VM/usr/local/bin/devtools.sh"      --mode 0755
incus file push "$HERE/guest/docker.sh"        "$VM/usr/local/bin/docker.sh"        --mode 0755
incus file push "$HERE/guest/init-firewall.sh" "$VM/usr/local/bin/init-firewall.sh" --mode 0755
incus file push "$HERE/guest/firewall.sh"      "$VM/usr/local/sbin/vibe-firewall"   --mode 0755
incus file push "$HERE/allowlist"              "$VM/root/allowlist"                 --mode 0644

echo "== Provisioning (installs tooling, creates vibe user, enables firewall) =="
# Forward the configured build knobs (from config.sh / vibevm.conf) so devtools.sh
# and docker.sh — run as children of provision.sh — see them. Only non-empty ones
# are passed, so each installer falls back to its own default when unset.
PROV_ENV=(--env HOST_UID="$(id -u)" --env HOST_GID="$(id -g)")
for k in NVM_VERSION NODE_DEFAULT JAVA_VERSION JAVA_EXTRA_MAJORS MAVEN_VERSION \
         GRADLE_VERSION NEXUS_MAVEN_URL REGISTRY_MIRROR APT_PACKAGES; do
  [ -n "${!k:-}" ] && PROV_ENV+=(--env "$k=${!k}")
done
incus exec "$VM" "${PROV_ENV[@]}" -- bash /root/provision.sh

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
