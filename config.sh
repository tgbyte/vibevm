#!/usr/bin/env bash
# Shared host-side configuration for vibevm. SOURCED (not executed) by the host
# scripts (vibe, create-vm.sh, mount-workspaces.sh, persist-claude.sh,
# sync-statusline.sh) so the VM name, resources, and build knobs live in one place.
#
# Precedence: a gitignored ./vibevm.conf (copy from vibevm.conf.example) overrides
# the defaults below. Everything has a sane default, so the repo runs unmodified
# with no config file present.
#
# shellcheck disable=SC2034  # vars are consumed by the scripts that source this

# Resolve our own directory so this works regardless of the caller's $PWD/$HERE.
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# User overrides first (so the := defaults below skip anything it sets).
if [ -f "$CONF_DIR/vibevm.conf" ]; then
  set -a; . "$CONF_DIR/vibevm.conf"; set +a
fi

# VM identity + resources.
: "${VM_NAME:=vibevm}"
: "${VM_IMAGE:=images:ubuntu/26.04}"
: "${VM_CPU:=8}"
: "${VM_MEM:=32GiB}"
: "${VM_DISK:=40GiB}"

# Tool version pins (forwarded into provisioning by create-vm.sh). Empty values
# mean "let the installer pick its default": SDKMAN latest for Java/Maven/Gradle.
: "${NVM_VERSION:=v0.40.1}"
: "${NODE_DEFAULT:=24.16.0}"
: "${JAVA_VERSION:=}"
: "${JAVA_EXTRA_MAJORS:=21}"
: "${MAVEN_VERSION:=}"
: "${GRADLE_VERSION:=}"

# Optional mirrors. Empty = use public sources directly (Maven Central + Gradle
# Plugin Portal for the JVM, upstream registries for Docker). Set these to a
# private mirror to route through it — and add the mirror's host to ./allowlist.
: "${NEXUS_MAVEN_URL:=}"
: "${REGISTRY_MIRROR:=}"
