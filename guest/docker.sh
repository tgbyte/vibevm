#!/usr/bin/env bash
# Docker (ROOTFUL) for the vibe VM (runs as root; re-runnable).
#
# Security note: rootful Docker means the `vibe` user is in the `docker` group,
# which is root-equivalent inside the VM, and container egress leaves via
# Docker's own NAT (the nftables FORWARD path), which the tinyproxy allowlist
# does NOT cover. The VM itself remains the hard isolation boundary.
#
# The Docker *daemon's* image pulls ARE locally-generated traffic, so they hit
# the egress allowlist — we route them through tinyproxy and allowlist the
# registries (see harden.sh) so `docker pull` works.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== Installing Docker engine + compose + buildx =="
apt-get install -y docker.io docker-compose-v2 docker-buildx \
  || apt-get install -y docker.io docker-compose-v2

echo "== Adding vibe to the docker group =="
usermod -aG docker vibe

echo "== Routing daemon image pulls through tinyproxy =="
install -d /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:8888"
Environment="HTTPS_PROXY=http://127.0.0.1:8888"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF

systemctl daemon-reload
systemctl enable docker
systemctl restart docker
echo "docker: install complete."
