#!/usr/bin/env bash
# Developer runtimes for the vibe VM (runs as ROOT; idempotent / re-runnable):
#   - Google Chrome (headless) for Lighthouse
#   - nvm + a default Node LTS (per-user, in /home/vibe)
#   - SDKMAN + a default Temurin JDK (per-user)
#   - lighthouse (global, via nvm's npm)
#
# Downloads go DIRECT during the first provision (firewall not up yet), or
# through tinyproxy if it's already running (when re-applied to a hardened VM).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

VIBE_HOME=/home/vibe
NVM_VERSION="${NVM_VERSION:-v0.40.1}"   # nvm release tag
NODE_DEFAULT="${NODE_DEFAULT:-22}"      # nvm default Node (major or full version)
JAVA_VERSION="${JAVA_VERSION:-}"        # sdkman id e.g. 21.0.7-tem; empty = SDKMAN default

# Route installs through tinyproxy iff it's already active (hardened VM).
if systemctl is-active --quiet tinyproxy; then
  export http_proxy=http://127.0.0.1:8888  https_proxy=http://127.0.0.1:8888
  export HTTP_PROXY=$http_proxy            HTTPS_PROXY=$https_proxy
  export no_proxy=localhost,127.0.0.1      NO_PROXY=localhost,127.0.0.1
fi

as_vibe() {  # run a command as vibe, from vibe's HOME, carrying the proxy env
  runuser -u vibe -- env HOME="$VIBE_HOME" \
    http_proxy="${http_proxy:-}"   https_proxy="${https_proxy:-}" \
    HTTP_PROXY="${HTTP_PROXY:-}"   HTTPS_PROXY="${HTTPS_PROXY:-}" \
    no_proxy="${no_proxy:-}"       NO_PROXY="${NO_PROXY:-}" \
    bash -c "cd \"$VIBE_HOME\"; $1"
}

echo "== Google Chrome (headless, for Lighthouse) =="
apt-get install -y --no-install-recommends unzip zip fonts-liberation ca-certificates
if ! command -v google-chrome-stable >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y "$tmp/chrome.deb"
  rm -rf "$tmp"
fi
# Allow Chrome's namespace sandbox to work for the unprivileged vibe user.
echo "kernel.apparmor_restrict_unprivileged_userns = 0" >/etc/sysctl.d/99-userns.conf
sysctl --system >/dev/null 2>&1 || true

echo "== nvm + Node $NODE_DEFAULT + lighthouse (as vibe) =="
as_vibe '
  set -e
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] || curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/'"$NVM_VERSION"'/install.sh" | bash
  set +e; . "$NVM_DIR/nvm.sh"; set -e
  nvm install '"$NODE_DEFAULT"'
  nvm alias default '"$NODE_DEFAULT"'
  npm install -g lighthouse
'

echo "== SDKMAN + Temurin JDK (as vibe) =="
as_vibe '
  set -e
  export SDKMAN_DIR="$HOME/.sdkman"
  [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] || curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash
  sed -i "s/^sdkman_auto_answer=.*/sdkman_auto_answer=true/" "$SDKMAN_DIR/etc/config" 2>/dev/null || true
  set +e; . "$SDKMAN_DIR/bin/sdkman-init.sh"; set -e
  if [ -n "'"$JAVA_VERSION"'" ]; then sdk install java "'"$JAVA_VERSION"'"; else sdk install java; fi
'

echo "== Login-shell env (node/java/chrome on PATH for every session) =="
cat >/etc/profile.d/vibe-tools.sh <<EOF
# nvm (default Node)
export NVM_DIR=$VIBE_HOME/.nvm
if [ -s "\$NVM_DIR/nvm.sh" ]; then . "\$NVM_DIR/nvm.sh"; nvm use default >/dev/null 2>&1 || true; fi
# SDKMAN (Java)
export SDKMAN_DIR=$VIBE_HOME/.sdkman
[ -s "\$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "\$SDKMAN_DIR/bin/sdkman-init.sh"
# Chrome for Lighthouse / chrome-launcher
export CHROME_PATH=/usr/bin/google-chrome-stable
EOF

echo "devtools: install complete."
