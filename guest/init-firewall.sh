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

# Hosts reachable DIRECTLY on 443. Claude Code connects to its API endpoint
# directly (not through the proxy), so the endpoint must be allowed here.
# Always api.anthropic.com, plus any extra endpoints listed in /etc/vibe/api-hosts
# (e.g. an ANTHROPIC_BASE_URL gateway — the launcher adds it from secrets.env).
API_HOSTS=(api.anthropic.com)
if [ -f /etc/vibe/api-hosts ]; then
  while read -r h; do
    h="${h%%#*}"; h="${h//[[:space:]]/}"
    [ -n "$h" ] && API_HOSTS+=("$h")
  done < /etc/vibe/api-hosts
fi
declare -A ANT=()
for host in "${API_HOSTS[@]}"; do
  while read -r ip _; do
    [ -n "$ip" ] && ANT["$ip"]=1
  done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
done

# Only reset OUR table — never `nft flush ruleset`, which would wipe Docker's
# NAT/filter tables and break container networking on every reapply.
nft delete table inet vibe 2>/dev/null || true
nft add table inet vibe
nft add chain inet vibe output '{ type filter hook output priority 0 ; policy drop ; }'

nft add rule inet vibe output oif lo accept
nft add rule inet vibe output ct state established,related accept

# Host -> container delivery for PUBLISHED PORTS. Reaching a published port
# (e.g. testcontainers connecting to localhost:<port>) makes docker-proxy / a
# hairpin DNAT open the host->container leg, which leaves via the docker bridge.
# That packet is locally generated, so it hits this OUTPUT chain and the
# default-drop kills it — breaking port mapping whenever the firewall is on.
# Allow output onto the docker bridges (docker0 + user networks br-*). This is
# NOT internet egress: container egress is the FORWARD path (masqueraded out the
# WAN by Docker's own NAT) and never traverses this OUTPUT chain.
nft add rule inet vibe output oifname "docker0" accept
nft add rule inet vibe output oifname "br-*" accept

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

# Direct 443 egress to the API hosts (Claude reaches its endpoint directly).
nft add set inet vibe api '{ type ipv4_addr ; }'
for ip in "${!ANT[@]}"; do
  nft add element inet vibe api "{ $ip }"
done
nft add rule inet vibe output ip daddr @api tcp dport 443 accept

echo "vibe-firewall: proxy uid=$TPUID, direct API IPs=${#ANT[@]} (${API_HOSTS[*]}), DNS resolvers=${#RES[@]}."
