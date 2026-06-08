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

# Remove stale ws-* mounts
while read -r dev; do
  [[ "$dev" == ws-* ]] || continue
  [ -z "${WANTDEV[$dev]:-}" ] && { echo "- unmount: $dev"; incus config device remove "$VM" "$dev" >/dev/null; }
done < <(incus config device list "$VM")

incus exec "$VM" -- install -d -o vibe -g vibe "$BASE"

# Add / update wanted mounts
for n in "${!WANT[@]}"; do
  src="${WANT[$n]}"; dev="$(devname "$n")"; gpath="$BASE/$n"
  incus exec "$VM" -- install -d -o vibe -g vibe "$gpath"
  if incus config device get "$VM" "$dev" source >/dev/null 2>&1; then
    [ "$(incus config device get "$VM" "$dev" source)" = "$src" ] && { echo "= $n  ($src)"; continue; }
    incus config device remove "$VM" "$dev" >/dev/null
  fi
  echo "+ mount: $n  <-  $src"
  incus config device add "$VM" "$dev" disk source="$src" path="$gpath" >/dev/null
done

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
