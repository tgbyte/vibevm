#!/usr/bin/env bash
# Egress firewall (runs as ROOT at boot via vibe-firewall.service).
# Default-DROP on OUTPUT. Only the tinyproxy service user may open outbound web
# connections, so all web egress is forced through tinyproxy's DOMAIN allowlist
# (see /etc/tinyproxy/allowlist) instead of a brittle IP list. A direct-IP path
# to api.anthropic.com is kept as a fallback so Claude always reaches the API.
# The unprivileged `vibe` user has no sudo and cannot change any of this.
set -euo pipefail

TPUID="$(id -u tinyproxy 2>/dev/null || echo 0)"

# DNS resolvers (classic file + systemd-resolved's real upstreams).
declare -A RES=()
for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
  [ -f "$f" ] || continue
  while read -r kw ns _; do
    [ "$kw" = nameserver ] && [ -n "$ns" ] && RES["$ns"]=1
  done < "$f"
done

# Resolve api.anthropic.com now (stable IPs) for the direct fallback path.
declare -A ANT=()
while read -r ip _; do
  [ -n "$ip" ] && ANT["$ip"]=1
done < <(getent ahostsv4 api.anthropic.com 2>/dev/null | awk '{print $1}' | sort -u)

nft flush ruleset
nft add table inet vibe
nft add chain inet vibe output '{ type filter hook output priority 0 ; policy drop ; }'

nft add rule inet vibe output oif lo accept
nft add rule inet vibe output ct state established,related accept

# DNS only to the VM's own resolvers
for ns in "${!RES[@]}"; do
  case "$ns" in *:*) continue ;; esac   # IPv6 is disabled in the VM
  nft add rule inet vibe output ip daddr "$ns" udp dport 53 accept
  nft add rule inet vibe output ip daddr "$ns" tcp dport 53 accept
done

# DHCP lease renewal
nft add rule inet vibe output udp dport 67 accept

# Only tinyproxy may reach the wider web; it enforces the domain allowlist.
nft add rule inet vibe output meta skuid "$TPUID" tcp dport '{ 80, 443 }' accept

# Direct fallback to Anthropic (in case Claude ignores the proxy env).
nft add set inet vibe anthropic '{ type ipv4_addr ; }'
for ip in "${!ANT[@]}"; do
  nft add element inet vibe anthropic "{ $ip }"
done
nft add rule inet vibe output ip daddr @anthropic tcp dport 443 accept

echo "vibe-firewall: proxy uid=$TPUID, anthropic direct=${#ANT[@]} IP(s), DNS resolvers=${#RES[@]}."
