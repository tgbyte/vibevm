#!/usr/bin/env bash
# Network egress policy for the vibe VM (runs as ROOT; re-runnable):
#   - tinyproxy: a forward proxy that allows only an allowlist of DOMAINS
#   - nftables : forces all web egress through tinyproxy (see init-firewall.sh)
#   - points apt / git / npm / pip / curl at the proxy
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== Installing tinyproxy =="
dpkg -s tinyproxy >/dev/null 2>&1 || apt-get install -y --no-install-recommends tinyproxy

echo "== Domain allowlist =="
install -d /etc/tinyproxy
# The allowlist is a HOST file (./allowlist, copied from allowlist.example),
# pushed to /root/allowlist by create-vm.sh and installed here — so editing the
# allowlist never means editing this script. If it's absent (harden.sh run
# standalone on a VM that never received one), keep any existing list; failing
# that, write a minimal bootstrap list sufficient to reach the API + core repos.
# To change the allowlist: edit ./allowlist on the host and run `vibe config`
# (pushes it + reloads tinyproxy, no rebuild); create-vm.sh also re-pushes it.
if [ -f /root/allowlist ]; then
  install -m 0644 /root/allowlist /etc/tinyproxy/allowlist
elif [ ! -s /etc/tinyproxy/allowlist ]; then
  cat >/etc/tinyproxy/allowlist <<'EOF'
(^|\.)anthropic\.com$
(^|\.)claude\.com$
(^|\.)github\.com$
(^|\.)ubuntu\.com$
(^|\.)npmjs\.org$
(^|\.)npmjs\.com$
(^|\.)pypi\.org$
(^|\.)pythonhosted\.org$
EOF
fi
chmod 0644 /etc/tinyproxy/allowlist

echo "== AppArmor: let tinyproxy read the allowlist filter file =="
# The shipped tinyproxy profile only permits tinyproxy.conf; custom files go in
# the local override it includes. Without this, enforcing mode fails to start.
install -d /etc/apparmor.d/local
cat >/etc/apparmor.d/local/tinyproxy <<'EOF'
# vibevm: permit tinyproxy to read the egress allowlist filter file
/etc/tinyproxy/allowlist r,
EOF
apparmor_parser -r /etc/apparmor.d/tinyproxy 2>/dev/null || systemctl reload apparmor 2>/dev/null || true

systemctl enable tinyproxy
# tinyproxy.conf is written by the vibe-firewall control script, which is
# on/off aware (it includes the Filter directives only when enforcing).

echo "== Pointing tools at the proxy =="
cat >/etc/profile.d/proxy.sh <<'EOF'
export http_proxy=http://127.0.0.1:8888
export https_proxy=http://127.0.0.1:8888
export HTTP_PROXY=$http_proxy
export HTTPS_PROXY=$https_proxy
export no_proxy=localhost,127.0.0.1
export NO_PROXY=$no_proxy
EOF
cat >/etc/apt/apt.conf.d/01proxy <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:8888";
Acquire::https::Proxy "http://127.0.0.1:8888";
EOF

echo "== Installing egress firewall service =="
chmod +x /usr/local/bin/init-firewall.sh /usr/local/sbin/vibe-firewall
mkdir -p /etc/vibe
[ -f /etc/vibe/firewall ] || echo on >/etc/vibe/firewall   # default: enforced
cat >/etc/systemd/system/vibe-firewall.service <<'EOF'
[Unit]
Description=vibe egress allowlist firewall
After=network-online.target tinyproxy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vibe-firewall apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vibe-firewall.service
/usr/local/sbin/vibe-firewall "$(cat /etc/vibe/firewall)"

echo "== Firewall status =="
/usr/local/sbin/vibe-firewall status
