#!/usr/bin/env bash
# Network egress policy for the vibe VM (runs as ROOT; re-runnable):
#   - tinyproxy: a forward proxy that allows only an allowlist of DOMAINS
#   - nftables : forces all web egress through tinyproxy (see init-firewall.sh)
#   - points apt / git / npm / pip / curl at the proxy
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== Installing tinyproxy =="
apt-get install -y --no-install-recommends tinyproxy

echo "== Domain allowlist =="
install -d /etc/tinyproxy
# Add what your workflow needs (POSIX extended regex on the request host),
# then: systemctl restart tinyproxy
cat >/etc/tinyproxy/allowlist <<'EOF'
(^|\.)anthropic\.com$
(^|\.)github\.com$
(^|\.)githubusercontent\.com$
(^|\.)githubassets\.com$
(^|\.)npmjs\.org$
(^|\.)npmjs\.com$
(^|\.)nodejs\.org$
(^|\.)nodesource\.com$
(^|\.)ubuntu\.com$
(^|\.)pypi\.org$
(^|\.)pythonhosted\.org$
(^|\.)sdkman\.io$
^dl\.google\.com$
(^|\.)docker\.io$
(^|\.)docker\.com$
(^|\.)ghcr\.io$
EOF

cat >/etc/tinyproxy/tinyproxy.conf <<'EOF'
User tinyproxy
Group tinyproxy
Port 8888
Listen 127.0.0.1
Timeout 600
LogLevel Warning
Allow 127.0.0.1
FilterDefaultDeny Yes
FilterExtended On
FilterCaseSensitive Off
Filter "/etc/tinyproxy/allowlist"
ConnectPort 443
ConnectPort 80
EOF
systemctl enable tinyproxy
systemctl restart tinyproxy

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
chmod +x /usr/local/bin/init-firewall.sh
cat >/etc/systemd/system/vibe-firewall.service <<'EOF'
[Unit]
Description=vibe egress allowlist firewall
After=network-online.target tinyproxy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/init-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vibe-firewall.service
systemctl restart vibe-firewall.service

echo "== Active ruleset =="
nft list ruleset
