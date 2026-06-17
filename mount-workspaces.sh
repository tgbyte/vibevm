#!/usr/bin/env bash
# Mount host project directories into the VM under ~/workspace
# (/home/vibe/workspace/<name>), shared live via virtiofs. Re-runnable: it syncs
# the VM's mounts to match the sources below (adding new, removing gone ones).
#
# Sources (both optional, combined):
#   1. each immediate subdirectory of ./workspace/   -> ~/workspace/<subdir>
#   2. each line of ./workspaces.conf:
#        /abs/host/path          -> ~/workspace/<basename>
#        name=/abs/host/path     -> ~/workspace/<name>
#      (~ is expanded; blank lines and # comments are ignored)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VM=vibevm
BASE=/home/vibe/workspace

incus info "$VM" >/dev/null 2>&1 || { echo "VM '$VM' not found — run ./create-vm.sh first." >&2; exit 1; }

devname() { printf 'ws-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-')"; }

declare -A WANT=()   # name -> absolute host source path
add_want() {
  local name="$1" path="${2/#\~/$HOME}"
  if [ ! -d "$path" ]; then echo "  ! skip '$name': not a directory: $path" >&2; return; fi
  WANT["$name"]="$(cd "$path" && pwd)"
}

# 1) local ./workspace/* subdirectories
if [ -d "$HERE/workspace" ]; then
  for d in "$HERE"/workspace/*/; do
    [ -d "$d" ] && add_want "$(basename "$d")" "$d"
  done
fi
# 2) ./workspaces.conf entries
if [ -f "$HERE/workspaces.conf" ]; then
  while IFS= read -r raw; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    if [[ "$line" == *=* ]]; then add_want "${line%%=*}" "${line#*=}"
    else add_want "$(basename "$line")" "$line"; fi
  done < "$HERE/workspaces.conf"
fi

# Desired device-name set
declare -A WANTDEV=()
for n in "${!WANT[@]}"; do WANTDEV["$(devname "$n")"]=1; done

vm_running() { [ "$(incus info "$VM" | awk '/Status/{print $2}')" = RUNNING ]; }

# Add one disk device to the VM config. On a running VM this also hot-plugs it
# live, but Incus only wires up ~8-10 hot-plug PCI slots per boot, so a large
# mount set overflows them ("No available PCI hotplug slots"). Exit status:
#   0 added · 2 slots exhausted (caller re-adds it cold) · 1 other failure.
try_add() {
  local n="$1" out
  if out="$(incus config device add "$VM" "$(devname "$n")" disk \
              source="${WANT[$n]}" path="$BASE/$n" 2>&1)"; then return 0; fi
  printf '%s\n' "$out" | grep -qi 'hotplug slot' && return 2
  printf '%s\n' "$out" >&2; return 1
}

# Remove stale ws-* mounts (no longer wanted).
while read -r dev; do
  [[ "$dev" == ws-* ]] || continue
  [ -z "${WANTDEV[$dev]:-}" ] && { echo "- unmount: $dev"; incus config device remove "$VM" "$dev" >/dev/null; }
done < <(incus config device list "$VM")

# Work out which mounts still need attaching; drop any whose source changed.
declare -a ADD=()
for n in "${!WANT[@]}"; do
  dev="$(devname "$n")"
  if incus config device get "$VM" "$dev" source >/dev/null 2>&1; then
    [ "$(incus config device get "$VM" "$dev" source)" = "${WANT[$n]}" ] && { echo "= $n  (${WANT[$n]})"; continue; }
    incus config device remove "$VM" "$dev" >/dev/null
  fi
  ADD+=("$n")
done

# Parent dir, owned by vibe, while the VM is up. Per-mount targets are created
# by the incus agent on attach/boot, so cold-added mounts need no pre-made dir.
if vm_running; then incus exec "$VM" -- install -d -o vibe -g vibe "$BASE"; fi

# Attach wanted mounts. Hot-plug while the VM runs; whatever overflows the PCI
# hot-plug slots is queued and re-added cold after a restart, which resets the
# boot device set — the only way past Incus's per-boot slot ceiling.
declare -a COLD=()
for n in "${ADD[@]}"; do
  echo "+ mount: $n  <-  ${WANT[$n]}"
  if vm_running; then
    incus exec "$VM" -- install -d -o vibe -g vibe "$BASE/$n"
    try_add "$n" && rc=0 || rc=$?
    case "$rc" in 0) ;; 2) COLD+=("$n") ;; *) exit 1 ;; esac
  else
    COLD+=("$n")
  fi
done

if [ "${#COLD[@]}" -gt 0 ]; then
  echo "  hot-plug slots full — attaching ${#COLD[@]} more cold (the VM restarts)…"
  if vm_running; then incus stop "$VM" --timeout 60; fi
  for n in "${COLD[@]}"; do
    incus config device add "$VM" "$(devname "$n")" disk \
      source="${WANT[$n]}" path="$BASE/$n" >/dev/null
  done
  incus start "$VM"
  until incus exec "$VM" -- true 2>/dev/null; do sleep 2; done
fi

# Wait for hotplugged virtiofs mounts to settle, so callers see them immediately
# and the prune below doesn't race a not-yet-mounted target.
for n in "${!WANT[@]}"; do
  for _ in $(seq 1 30); do
    incus exec "$VM" -- findmnt -rno TARGET "$BASE/$n" >/dev/null 2>&1 && break
    sleep 0.3
  done
done

# Prune empty leftover mountpoints (rmdir refuses busy mounts and non-empty dirs)
incus exec "$VM" -- bash -c "for d in $BASE/*/; do rmdir \"\$d\" 2>/dev/null || true; done" 2>/dev/null || true

echo "Synced ${#WANT[@]} workspace mount(s). In the VM:  ls ~/workspace"
