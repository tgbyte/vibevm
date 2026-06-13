#!/usr/bin/env bash
# Developer runtimes for the vibe VM (runs as ROOT; idempotent / re-runnable):
#   - Google Chrome (headless) for Lighthouse
#   - nvm + a default Node LTS (per-user, in /home/vibe)
#   - SDKMAN + a default Temurin JDK, Maven and Gradle (per-user)
#   - Maven/Gradle wired to resolve every dependency through the Nexus mirror
#   - lighthouse (global, via nvm's npm)
#
# Downloads go DIRECT during the first provision (firewall not up yet), or
# through tinyproxy if it's already running (when re-applied to a hardened VM).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

VIBE_HOME=/home/vibe
NVM_VERSION="${NVM_VERSION:-v0.40.1}"   # nvm release tag
NODE_DEFAULT="${NODE_DEFAULT:-24.16.0}" # nvm default Node (major or full version)
JAVA_VERSION="${JAVA_VERSION:-}"        # sdkman id e.g. 21.0.7-tem; empty = SDKMAN default (becomes default)
JAVA_EXTRA_MAJORS="${JAVA_EXTRA_MAJORS:-21}"  # extra Temurin majors to also install (newest patch each); space-separated
MAVEN_VERSION="${MAVEN_VERSION:-}"      # sdkman id e.g. 3.9.9;  empty = SDKMAN default (latest)
GRADLE_VERSION="${GRADLE_VERSION:-}"    # sdkman id e.g. 8.10;   empty = SDKMAN default (latest)
# Every Maven/Gradle repository request is mirrored through this Nexus group, so
# builds never need direct egress to Maven Central / the Gradle Plugin Portal.
NEXUS_MAVEN_URL="${NEXUS_MAVEN_URL:-https://nexus.example.com/repository/maven-all/}"

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

echo "== SDKMAN + Temurin JDK + Maven + Gradle (as vibe) =="
as_vibe '
  set -e
  export SDKMAN_DIR="$HOME/.sdkman"
  [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] || curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash
  sed -i "s/^sdkman_auto_answer=.*/sdkman_auto_answer=true/" "$SDKMAN_DIR/etc/config" 2>/dev/null || true
  set +e; . "$SDKMAN_DIR/bin/sdkman-init.sh"; set -e
  if [ -n "'"$JAVA_VERSION"'" ];   then sdk install java   "'"$JAVA_VERSION"'";   else sdk install java;   fi
  # Keep the version installed above as the default, then add extra Temurin
  # majors (newest patch of each, resolved from the live list) alongside it.
  primary="$(sdk current java 2>/dev/null | grep -oE "[0-9][0-9.]*-tem")"
  for major in '"$JAVA_EXTRA_MAJORS"'; do
    id="$(sdk list java | grep -oE "${major}\.[0-9.]+-tem" | sort -uV | tail -1)"
    if [ -n "$id" ]; then sdk install java "$id"; else echo "devtools: no Temurin $major found"; fi
  done
  [ -n "$primary" ] && sdk default java "$primary"
  if [ -n "'"$MAVEN_VERSION"'" ];  then sdk install maven  "'"$MAVEN_VERSION"'";  else sdk install maven;  fi
  if [ -n "'"$GRADLE_VERSION"'" ]; then sdk install gradle "'"$GRADLE_VERSION"'"; else sdk install gradle; fi
'

echo "== Routing Maven/Gradle repositories through Nexus ($NEXUS_MAVEN_URL) =="
# The JVM ignores the http_proxy env vars the rest of the VM uses, so Maven and
# Gradle are pointed at the egress proxy explicitly; and every repository is
# mirrored to the Nexus group so resolution never needs direct egress.
install -d -o vibe -g vibe "$VIBE_HOME/.m2" "$VIBE_HOME/.gradle"

cat >"$VIBE_HOME/.m2/settings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <!-- vibevm: tunnel outbound requests through the egress proxy and mirror every
       repository to Nexus. Credentials are read from the session env (forwarded
       from host secrets.env by ./vibe), so no secret is written to the VM disk.
       nexus.example.com requires auth — set NEXUS_USERNAME / NEXUS_PASSWORD. -->
  <servers>
    <server>
      <id>nexus</id>
      <username>\${env.NEXUS_USERNAME}</username>
      <password>\${env.NEXUS_PASSWORD}</password>
    </server>
  </servers>
  <proxies>
    <proxy>
      <id>egress</id>
      <active>true</active>
      <protocol>http</protocol>
      <host>127.0.0.1</host>
      <port>8888</port>
      <nonProxyHosts>localhost|127.0.0.1</nonProxyHosts>
    </proxy>
  </proxies>
  <mirrors>
    <mirror>
      <id>nexus</id>
      <name>nexus.example.com</name>
      <mirrorOf>*</mirrorOf>
      <url>$NEXUS_MAVEN_URL</url>
    </mirror>
  </mirrors>
</settings>
EOF

cat >"$VIBE_HOME/.gradle/gradle.properties" <<'EOF'
# vibevm: tunnel Gradle's outbound HTTP(S) through the egress proxy (the JVM
# ignores the http_proxy env vars the rest of the VM uses). Repositories are
# pinned to Nexus by ~/.gradle/init.gradle.
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=8888
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=8888
systemProp.http.nonProxyHosts=localhost|127.0.0.1
systemProp.https.nonProxyHosts=localhost|127.0.0.1
EOF

cat >"$VIBE_HOME/.gradle/init.gradle" <<EOF
// vibevm: force all Gradle dependency, plugin, and buildscript resolution
// through the Nexus mirror. Direct egress to other repositories is firewalled,
// so every declared repository is replaced with Nexus. Credentials come from the
// session env (forwarded from host secrets.env by ./vibe) — nexus.example.com
// requires auth, so set NEXUS_USERNAME / NEXUS_PASSWORD.
def nexus = '$NEXUS_MAVEN_URL'

// Stored on the script binding (no 'def') so the deferred closures below see it.
pinToNexus = { repos ->
    repos.clear()
    repos.maven {
        url nexus
        credentials {
            username = System.getenv('NEXUS_USERNAME') ?: ''
            password = System.getenv('NEXUS_PASSWORD') ?: ''
        }
    }
}

gradle.settingsEvaluated { settings ->
    settings.pluginManagement { pinToNexus(repositories) }
    try {
        settings.dependencyResolutionManagement { pinToNexus(repositories) }
    } catch (ignored) { }
}

gradle.allprojects { project ->
    project.buildscript { pinToNexus(repositories) }
    pinToNexus(project.repositories)
}
EOF

chown vibe:vibe "$VIBE_HOME/.m2/settings.xml" \
                "$VIBE_HOME/.gradle/gradle.properties" \
                "$VIBE_HOME/.gradle/init.gradle"

echo "== Login-shell env (node/java/maven/gradle/chrome on PATH for every session) =="
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
