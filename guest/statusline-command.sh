#!/usr/bin/env bash
# Claude Code status line — vibevm brand (minimal).
# The [∿] mark, then accent-colored segments (no backgrounds) joined by muted
# dots. Palette from branding/README.md:
#   Teal  #2DD4BF — the walls / location (where you are)
#   Coral #FF7A5C — the wave, the "vibe" / activity
#   Muted #8B98A5 — secondary text + separators
#   Light #E6EDF3 — the model name

input=$(cat)

cwd=$(echo "$input"  | jq -r '.workspace.current_dir // .cwd')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
limit_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
limit_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Git branch from cwd
git_branch=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" -c core.fsmonitor=false rev-parse --short HEAD 2>/dev/null)
fi

# Truncate path similar to starship (up to 3 path components)
short_cwd="${cwd/#$HOME/~}"
IFS='/' read -ra _parts <<< "$short_cwd"
if [ "${#_parts[@]}" -gt 3 ]; then
    short_cwd="…/${_parts[-3]}/${_parts[-2]}/${_parts[-1]}"
fi

# Kubernetes current context (best-effort; empty string if kubectl unavailable)
k8s_ctx=""
if command -v kubectl >/dev/null 2>&1; then
    k8s_ctx=$(kubectl config current-context 2>/dev/null || true)
fi

# ── Brand palette (true-color escapes; emitted once via printf '%b') ────────────
RESET='\033[0m'
TEAL='\033[38;2;45;212;191m'     # walls / location
CORAL='\033[38;2;255;122;92m'    # the "vibe" / activity
MUTED='\033[38;2;139;152;165m'   # secondary / separators
LIGHT='\033[38;2;230;237;243m'   # model

# ── vibevm mark — [∿]: teal sandbox walls around a coral wave (the "vibe") ──────
mark="${TEAL}[${CORAL}∿${TEAL}]${RESET}"

# ── Collect active segments (accent-colored text, no backgrounds) ───────────────
seg=()
seg+=("${TEAL}${short_cwd}${RESET}")                          # directory  (teal)
[ -n "$git_branch" ] && seg+=("${CORAL}${git_branch}${RESET}")   # branch (coral)
[ -n "$model" ]      && seg+=("${LIGHT}${model}${RESET}")        # model  (light)
[ -n "$k8s_ctx" ]    && seg+=("${TEAL}☸ ${k8s_ctx}${RESET}")     # k8s    (teal)

if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct")
    seg+=("${MUTED}ctx:${used_int}%${RESET}")                    # context window (muted)
fi

if [ -n "$limit_5h" ] || [ -n "$limit_7d" ]; then
    joined=""
    [ -n "$limit_5h" ] && joined=$(LC_ALL=C printf '5h:%.0f%%' "$limit_5h")
    if [ -n "$limit_7d" ]; then
        rest=$(LC_ALL=C printf '7d:%.0f%%' "$limit_7d")
        joined="${joined:+$joined / }$rest"
    fi
    seg+=("${CORAL}${joined}${RESET}")                           # rate limits (coral)
fi

# ── Render: mark + segments joined by muted dots ────────────────────────────────
out="$mark  "
for i in "${!seg[@]}"; do
    [ "$i" -gt 0 ] && out+=" ${MUTED}·${RESET} "
    out+="${seg[$i]}"
done

printf '%b\n' "$out"
