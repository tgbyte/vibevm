#!/usr/bin/env bash
# vibe-firewall — toggle the VM's egress allowlist (root only).
#   vibe-firewall on        enforce the domain allowlist (default; secure)
#   vibe-firewall off       open egress (allowlist not enforced)
#   vibe-firewall status    show the current mode
#   vibe-firewall apply     (re)apply the saved mode  [used by the boot service]
#
# ON  = nftables default-drop on OUTPUT forcing web traffic through tinyproxy,
#       which filters by /etc/tinyproxy/allowlist.
# OFF = the nftables table is removed (egress open) and tinyproxy stops filtering
#       (traffic still routed through it just passes through).
#
# The unprivileged `vibe` user cannot run this (nftables needs root), so a
# runaway/injected agent can't silently disable it — only the host operator can.
set -euo pipefail

STATE_DIR=/etc/vibe
STATE_FILE="$STATE_DIR/firewall"
TPCONF=/etc/tinyproxy/tinyproxy.conf

write_tinyproxy() {  # $1 = on|off
  cat >"$TPCONF" <<'EOF'
User tinyproxy
Group tinyproxy
Port 8888
Listen 127.0.0.1
Timeout 600
LogLevel Warning
Allow 127.0.0.1
ConnectPort 443
ConnectPort 80
EOF
  if [ "$1" = on ]; then
    cat >>"$TPCONF" <<'EOF'
FilterDefaultDeny Yes
FilterExtended On
FilterCaseSensitive Off
Filter "/etc/tinyproxy/allowlist"
EOF
  fi
  systemctl restart tinyproxy
}

apply() {
  local mode; mode="$(cat "$STATE_FILE" 2>/dev/null || echo on)"
  if [ "$mode" = off ]; then
    write_tinyproxy off
    nft delete table inet vibe 2>/dev/null || true
    echo "vibe-firewall: OFF — egress is open (allowlist NOT enforced)."
  else
    write_tinyproxy on
    bash /usr/local/bin/init-firewall.sh
    echo "vibe-firewall: ON — domain allowlist enforced."
  fi
}

case "${1:-status}" in
  on)    mkdir -p "$STATE_DIR"; echo on  >"$STATE_FILE"; apply ;;
  off)   mkdir -p "$STATE_DIR"; echo off >"$STATE_FILE"; apply ;;
  apply) apply ;;
  status)
    mode="$(cat "$STATE_FILE" 2>/dev/null || echo on)"
    if nft list table inet vibe >/dev/null 2>&1; then nftstate="lockdown active"; else nftstate="open"; fi
    echo "mode=$mode (nftables: $nftstate)"
    ;;
  *) echo "usage: vibe-firewall {on|off|status}" >&2; exit 1 ;;
esac
