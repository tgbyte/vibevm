#!/usr/bin/env bash
# Runs INSIDE the VM as root (invoked by create-vm.sh). Installs tooling +
# Claude Code, creates the unprivileged `vibe` user, and installs the egress
# firewall as a boot service. Network is still open while this runs; the
# firewall is enabled at the very end.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
# Configurable dev packages (forwarded from config.sh / vibevm.conf by
# create-vm.sh). The essential core below is always installed regardless; this
# list is the conveniences on top — extend or trim it. Keep in sync with the
# default in config.sh.
APT_PACKAGES="${APT_PACKAGES:-git-filter-repo ripgrep python3 python3-venv python3-pip python3-pil build-essential iproute2 dnsutils less vim nano btop zsh}"

# Re-provision case: when the VM's egress firewall is already enforcing, this
# script runs via `incus exec` (a NON-login shell), so it doesn't inherit the
# proxy from /etc/profile.d/proxy.sh — raw curl/npm would then hit the default-drop
# firewall and hang (apt is fine; it has its own 01proxy config). If tinyproxy is
# already listening, route outbound HTTP(S) through it; every download host below
# is on the allowlist. On a first build the proxy isn't up yet and the network is
# still open, so this stays unset and we connect directly, as before.
if (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null; then
  exec 3>&-
  echo "== Egress proxy already up — routing provisioning downloads through it =="
  export http_proxy=http://127.0.0.1:8888  https_proxy=http://127.0.0.1:8888
  export HTTP_PROXY="$http_proxy"          HTTPS_PROXY="$https_proxy"
  export no_proxy=localhost,127.0.0.1      NO_PROXY=localhost,127.0.0.1
  # harden.sh installs the (possibly updated) allowlist only at the very end, but
  # download steps below may need a host that was just added to ./allowlist. Refresh
  # the live allowlist now (mirrors harden.sh) so the proxy honours those additions
  # before the steps that depend on them run.
  if [ -f /root/allowlist ]; then
    install -m 0644 /root/allowlist /etc/tinyproxy/allowlist
    systemctl reload tinyproxy 2>/dev/null || systemctl restart tinyproxy 2>/dev/null || true
  fi
fi

echo "== Disabling IPv6 (so the IPv4 egress allowlist is total) =="
cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || true

echo "== Enabling the 'universe' component (ripgrep, tinyproxy live there) =="
apt-get update
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y universe || true
apt-get update

echo "== Installing essential tooling (required; always installed) =="
# What the VM needs to function: TLS roots, downloads (curl is used throughout
# provisioning), git for commits, nftables for the firewall, jq for the status
# line. These are not configurable so a trimmed APT_PACKAGES can't break the VM.
apt-get install -y --no-install-recommends ca-certificates curl git nftables jq

echo "== Installing configurable dev packages (APT_PACKAGES) =="
echo "   packages: ${APT_PACKAGES:-(none)}"
if [ -n "$APT_PACKAGES" ]; then
  # shellcheck disable=SC2086  # intentional word-splitting of the package list
  apt-get install -y --no-install-recommends $APT_PACKAGES
fi

echo "== Installing Node.js 22 + Claude Code =="
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g @anthropic-ai/claude-code

echo "== Creating unprivileged 'vibe' user (uid=$HOST_UID, NO sudo) =="
# Ubuntu images ship a default 'ubuntu' user at uid 1000; free that uid/gid so
# 'vibe' can take it (keeps virtiofs ownership aligned with the host user).
existing_user="$(getent passwd "$HOST_UID" | cut -d: -f1 || true)"
if [ -n "$existing_user" ] && [ "$existing_user" != vibe ]; then
  userdel -r "$existing_user" 2>/dev/null || userdel "$existing_user" || true
fi
existing_group="$(getent group "$HOST_GID" | cut -d: -f1 || true)"
if [ -n "$existing_group" ] && [ "$existing_group" != vibe ]; then
  groupdel "$existing_group" 2>/dev/null || true
fi
getent group vibe >/dev/null || groupadd -g "$HOST_GID" vibe 2>/dev/null || groupadd vibe
id vibe >/dev/null 2>&1 || useradd -m -u "$HOST_UID" -g vibe -s /bin/bash vibe
mkdir -p /home/vibe/workspace
chown vibe:vibe /home/vibe/workspace

echo "== Setting up clock sync from the host (chrony + KVM PTP, no network) =="
bash /usr/local/bin/timesync.sh

echo "== Installing developer runtimes (chrome, nvm/node, sdkman/java) =="
bash /usr/local/bin/devtools.sh

echo "== Installing Docker (rootful) =="
bash /usr/local/bin/docker.sh

echo "== Applying network egress policy (tinyproxy + firewall) =="
bash /usr/local/bin/harden.sh

echo "== Provisioning complete =="
