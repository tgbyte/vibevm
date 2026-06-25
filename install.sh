#!/usr/bin/env bash
# One-time host installer for vibevm (re-runnable). It:
#   1. sets up the incus daemon (needs sudo),
#   2. puts `vibe` on your PATH (symlink into ~/.local/bin),
#   3. installs bash + zsh shell completion.
# incus itself must already be installed — see the README "Prerequisites".
#
# After it runs, open a NEW shell (and re-login so the incus-admin group
# applies), then: vibe create  &&  vibe
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BINDIR="${VIBE_BINDIR:-$HOME/.local/bin}"

# ── incus must already be installed (we only start/configure the daemon) ──────
if ! command -v incus >/dev/null 2>&1; then
  cat >&2 <<'MSG'
incus is not installed. Install it on the host first (see README "Prerequisites"):
  Ubuntu (24.04+):  sudo apt install incus qemu-system
  Arch Linux:       sudo pacman -S incus qemu-base edk2-ovmf dnsmasq
Then re-run ./install.sh.
MSG
  exit 1
fi

echo "== incus: enabling the daemon =="
sudo systemctl enable --now incus.socket incus.service

echo "== incus: adding $USER to the incus-admin group =="
sudo usermod -aG incus-admin "$USER"

echo "== incus: minimal init (storage pool + bridge network) =="
if ! sudo incus storage list --format csv 2>/dev/null | grep -q .; then
  sudo incus admin init --minimal
else
  echo "   (already initialized)"
fi

# ── put `vibe` on PATH ────────────────────────────────────────────────────────
mkdir -p "$BINDIR"
ln -sf "$HERE/vibe" "$BINDIR/vibe"
echo "== linked $BINDIR/vibe -> $HERE/vibe =="

# ── shell integration: PATH + completion (idempotent, marked block per rc) ────
MARK_BEGIN="# >>> vibevm >>>"
MARK_END="# <<< vibevm <<<"
PATH_LINE='case ":$PATH:" in *":'"$BINDIR"':"*) ;; *) export PATH="'"$BINDIR"':$PATH" ;; esac'

add_block() {  # $1=rc file  $2=block body
  local rc="$1" body="$2"
  [ -e "$rc" ] || : >"$rc"
  if grep -qF "$MARK_BEGIN" "$rc" 2>/dev/null; then
    echo "   $rc already configured — leaving it."
  else
    printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >>"$rc"
    echo "   configured $rc"
  fi
}

if command -v bash >/dev/null 2>&1; then
  echo "== bash: PATH + completion in ~/.bashrc =="
  add_block "$HOME/.bashrc" "$PATH_LINE
[ -r \"$HERE/completions/vibe.bash\" ] && . \"$HERE/completions/vibe.bash\""
fi

if command -v zsh >/dev/null 2>&1; then
  echo "== zsh: PATH + completion in ~/.zshrc =="
  add_block "$HOME/.zshrc" "$PATH_LINE
fpath=(\"$HERE/completions\" \$fpath)
autoload -Uz compinit && compinit"
fi

cat <<EOF

vibevm is installed.

Next:
  1. Open a NEW shell (for the PATH + completions), and re-login if needed —
     the incus-admin group only applies to new sessions.
  2. vibe create           # build + provision the VM (a few minutes)
  3. vibe                  # vibe-code in auto mode

To undo: remove the "$MARK_BEGIN" … "$MARK_END" block from ~/.bashrc / ~/.zshrc
and delete $BINDIR/vibe.
EOF
