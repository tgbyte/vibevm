# bash completion for vibevm's `vibe` launcher.
#
# Install: source this from your ~/.bashrc, e.g.
#     source /path/to/vibevm/completions/vibe.bash
# or copy it into a bash-completion directory (e.g. /etc/bash_completion.d/).
#
# Completes subcommands, `firewall` modes, and your mounted project names
# (from ./workspace/* and ./workspaces.conf). Works for both `vibe` (on PATH)
# and `./vibe` run from the repo.

# Resolve the directory of the invoked `vibe` script, following symlinks, so we
# can read ./workspace and ./workspaces.conf even when vibe is a PATH symlink.
_vibe_repo_dir() {
    local exe="$1" resolved
    case "$exe" in
        */*) : ;;                                      # a path was typed (./vibe, /abs/vibe)
        *)   exe="$(command -v "$exe" 2>/dev/null)" || return 0 ;;
    esac
    resolved="$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")"
    (cd "$(dirname "$resolved")" 2>/dev/null && pwd)
}

# Print one project name per line (./workspace/* basenames + workspaces.conf names).
_vibe_projects() {
    local repo="$1" d line
    [ -n "$repo" ] || return 0
    if [ -d "$repo/workspace" ]; then
        for d in "$repo"/workspace/*/; do [ -d "$d" ] && basename "$d"; done
    fi
    if [ -f "$repo/workspaces.conf" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
            [ -z "$line" ] && continue
            if [[ "$line" == *=* ]]; then printf '%s\n' "${line%%=*}"; else basename "$line"; fi
        done < "$repo/workspaces.conf"
    fi
}

_vibe() {
    local cur cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    cword=$COMP_CWORD
    local subcmds="claude shell mounts statusline persist firewall stop restore help"
    local repo; repo="$(_vibe_repo_dir "${COMP_WORDS[0]}")"

    # `vibe firewall <on|off|status>`
    if [ "$cword" -ge 2 ] && [ "${COMP_WORDS[1]}" = firewall ]; then
        [ "$cword" -eq 2 ] && COMPREPLY=( $(compgen -W "on off status" -- "$cur") )
        return
    fi

    # First argument: a subcommand, a project, or '.'
    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$subcmds . $(_vibe_projects "$repo")" -- "$cur") )
        return
    fi

    # `vibe claude|shell <project>`
    if [ "$cword" -eq 2 ] && { [ "${COMP_WORDS[1]}" = claude ] || [ "${COMP_WORDS[1]}" = shell ]; }; then
        COMPREPLY=( $(compgen -W ". $(_vibe_projects "$repo")" -- "$cur") )
        return
    fi
}

complete -F _vibe vibe ./vibe
