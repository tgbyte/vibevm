#!/usr/bin/env bash
# Claude Code status line — Powerline style matching Starship Gruvbox Rainbow config
# Segment colors from starship.toml:
#   opening cap : #9A348E (purple)
#   directory   : #DA627D (pink)
#   git branch  : #FCA17D (orange)
#   model       : #86BBD8 (blue)
#   kubernetes  : #06969A (teal)
#   context %   : #33658A (dark blue)

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

# ── ANSI helpers ──────────────────────────────────────────────────────────────
RESET='\033[0m'
# Background (true-color)
bg() { printf '\033[48;2;%d;%d;%dm' "$1" "$2" "$3"; }
# Foreground (true-color)
fg() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
# White foreground for segment text
FG_WHITE=$(fg 248 248 248)
# Powerline glyphs
SEP=$''      # filled right-arrow
OPEN=$''     # left half-circle  (opening cap)
CLOSE=$''    # right half-circle (closing cap)

# Segment color components (R G B)
C_PURPLE=(154  52 142)
C_PINK=(218  98 125)
C_ORANGE=(252 161 125)
C_BLUE=(134 187 216)
C_TEAL=(  6 150 154)
C_DBLUE=( 51 101 138)
C_GOLD=(218 165  32)

# ── Collect active segments ───────────────────────────────────────────────────
# Each entry: "R G B|text"
seg_colors=()
seg_texts=()

# 1. Directory (always present)
seg_colors+=("${C_PINK[*]}")
seg_texts+=(" $short_cwd ")

# 2. Git branch (conditional)
if [ -n "$git_branch" ]; then
    seg_colors+=("${C_ORANGE[*]}")
    seg_texts+=("  $git_branch ")
fi

# 3. Model name (conditional)
if [ -n "$model" ]; then
    seg_colors+=("${C_BLUE[*]}")
    seg_texts+=("  $model ")
fi

# 4. Kubernetes context (conditional)
if [ -n "$k8s_ctx" ]; then
    seg_colors+=("${C_TEAL[*]}")
    seg_texts+=(" ☸ $k8s_ctx ")
fi

# 5. Context window usage (conditional)
if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct")
    seg_colors+=("${C_DBLUE[*]}")
    seg_texts+=(" ctx:${used_int}% ")
fi

# 6. Rate limits (5h / 7d), conditional
if [ -n "$limit_5h" ] || [ -n "$limit_7d" ]; then
    joined=""
    if [ -n "$limit_5h" ]; then
        joined=$(LC_ALL=C printf '5h:%.0f%%' "$limit_5h")
    fi
    if [ -n "$limit_7d" ]; then
        rest=$(LC_ALL=C printf '7d:%.0f%%' "$limit_7d")
        joined="${joined:+$joined / }$rest"
    fi
    seg_colors+=("${C_GOLD[*]}")
    seg_texts+=(" ${joined} ")
fi

# ── Render powerline bar ──────────────────────────────────────────────────────
n=${#seg_colors[@]}

# vibevm mark — teal sandbox walls [ ] around a coral wave ∿ (the "vibe"),
# matching branding/logo-mark.svg. Leads the bar so every prompt is branded.
out=$(printf '%b' "$(fg 45 212 191)[$(fg 255 122 92)∿$(fg 45 212 191)]${RESET} ")

if [ "$n" -eq 0 ]; then
    printf '%b\n' "$out"
    exit 0
fi

# Opening half-circle: fg=purple, no background
read -r pr pg pb <<< "${C_PURPLE[*]}"
read -r r0 g0 b0 <<< "${seg_colors[0]}"
out+=$(printf '%b' "$(fg "$pr" "$pg" "$pb")$(bg "$r0" "$g0" "$b0")${OPEN}")

for (( i=0; i<n; i++ )); do
    read -r ri gi bi <<< "${seg_colors[$i]}"
    # Segment text on its background
    out+=$(printf '%b' "$(bg "$ri" "$gi" "$bi")${FG_WHITE}${seg_texts[$i]}")

    if [ $((i+1)) -lt "$n" ]; then
        # Transition arrow: fg=current bg, bg=next bg
        read -r rn gn bn <<< "${seg_colors[$((i+1))]}"
        out+=$(printf '%b' "$(fg "$ri" "$gi" "$bi")$(bg "$rn" "$gn" "$bn")${SEP}")
    fi
done

# Closing half-circle: fg=last segment color, no background
read -r rl gl bl <<< "${seg_colors[$((n-1))]}"
out+=$(printf '%b' "${RESET}$(fg "$rl" "$gl" "$bl")${RESET}${CLOSE}${RESET}")

printf '%b\n' "$out"
