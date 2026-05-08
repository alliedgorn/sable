#!/usr/bin/env bash
# Pre-Compact Notification Hook — Spec #53 + Spec #58 (Escalating thresholds)
# Stop hook: detects imminent auto-compact and NOTIFIES the Beast to fire /rest.
#
# Registered at user-level ~/.claude/settings.json as a Stop hook.
# Reads transcript usage to estimate context fill. At threshold crossing,
# sends a notification via Beast-sovereign notify.sh telling the Beast to
# wrap up current task + fire /rest.
#
# Spec #58: Escalating tiers (75/85/92%) replace one-shot latch. Each tier
# fires independently — if Beast misses 75%, it fires again at 85%, then 92%.
#
# The Beast handles the actual rest cycle — this hook only detects + notifies.
#
# Input (stdin JSON): {transcript_path, session_id, hook_event_name}
# Exit 0 always — must not block turn-close.

set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
# Bertus C3 / C2-new: realpath validation — transcript must resolve under $HOME/.claude/
transcript=$(realpath "$transcript" 2>/dev/null) || exit 0
[[ "$transcript" == "$HOME/.claude/"* ]] || exit 0
[ -n "$session_id" ] || exit 0

LOCK_DIR="/tmp/precompact"
LOCK_FILE="$LOCK_DIR/$session_id.lock"

last_usage=$(tac "$transcript" 2>/dev/null | grep -m1 '"usage"') || exit 0
[ -n "$last_usage" ] || exit 0

read_tokens=$(printf '%s' "$last_usage" | jq -r '
  .message.usage // empty |
  ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
' 2>/dev/null)
[ -n "$read_tokens" ] && [ "$read_tokens" != "null" ] || exit 0

model=$(printf '%s' "$last_usage" | jq -r '.message.model // "unknown"' 2>/dev/null)

project_dir=$(dirname "$transcript")
beast=$(basename "$project_dir" | sed 's/^-home-gorn-workspace-//')
[ -n "$beast" ] || exit 0
beast_dir="$HOME/workspace/$beast"
[ -d "$beast_dir" ] || exit 0

# Detect context window from model string + settings.
# Usage logs report "claude-opus-4-6" without the [1m] suffix.
# Check user/project settings for [1m] suffix to distinguish 200k vs 1M.
CONTEXT_WINDOW=200000
if [[ "$model" == *opus* ]]; then
  for cfg in "$HOME/.claude/settings.json" "$beast_dir/.claude/settings.json" "$beast_dir/.claude/settings.local.json"; do
    if [ -f "$cfg" ]; then
      cfg_model=$(jq -r '.model // empty' "$cfg" 2>/dev/null)
      if [[ "$cfg_model" == *"[1m]"* ]]; then
        CONTEXT_WINDOW=1048576
        break
      fi
    fi
  done
fi

# Spec #58: Escalating threshold tiers (replaces one-shot latch).
# Read tiers from beast.yaml or use defaults: 75, 85, 92.
TIERS=(75 85 92)
if [ -f "$beast_dir/beast.yaml" ]; then
  custom_tiers=$(grep '^precompact_tiers:' "$beast_dir/beast.yaml" 2>/dev/null | sed 's/^precompact_tiers:\s*//')
  if [ -n "$custom_tiers" ]; then
    read -ra TIERS <<< "$(echo "$custom_tiers" | tr ',' ' ' | tr -d '[]')"
  fi
  pct=$(grep '^precompact_threshold_pct:' "$beast_dir/beast.yaml" 2>/dev/null | awk '{print $2}')
  if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -gt 0 ] && [ "$pct" -lt 100 ]; then
    TIERS[0]=$pct
  fi
fi

# Read fired_pct from lockfile (0 if no lockfile = nothing fired yet).
fired_pct=0
if [ -f "$LOCK_FILE" ]; then
  fired_pct=$(grep -oP 'fired_pct=\K[0-9]+' "$LOCK_FILE" 2>/dev/null || echo 0)
  [ -n "$fired_pct" ] || fired_pct=0
fi

# Find the current usage percentage.
current_pct=$((read_tokens * 100 / CONTEXT_WINDOW))

# Find the highest tier that current usage exceeds AND is above fired_pct.
fire_tier=0
for tier in "${TIERS[@]}"; do
  if [ "$current_pct" -ge "$tier" ] && [ "$tier" -gt "$fired_pct" ]; then
    fire_tier=$tier
  fi
done

if [ "$fire_tier" -eq 0 ]; then
  exit 0
fi

# Determine tier level for message escalation.
tier_level=1
for i in "${!TIERS[@]}"; do
  if [ "${TIERS[$i]}" -eq "$fire_tier" ]; then
    tier_level=$((i + 1))
  fi
done

umask 0077
mkdir -p "$LOCK_DIR"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) fired_pct=$fire_tier tokens=$read_tokens model=$model beast=$beast tier=$tier_level" > "$LOCK_FILE"
chmod 0600 "$LOCK_FILE" 2>/dev/null || true

LOG_FILE="/tmp/precompact-ceremony-$beast.log"

# Tier-appropriate messages (Spec #58).
NOTIFY_SCRIPT="$beast_dir/scripts/notify.sh"
if [ "$tier_level" -eq 1 ]; then
  NOTIFY_MSG="[Pre-compact] Context at ${fire_tier}% ($read_tokens tokens). Finish your current task or find a checkpoint, then fire /rest. Do NOT start new work — wrap up and rest."
elif [ "$tier_level" -eq 2 ]; then
  NOTIFY_MSG="[Pre-compact — WARNING] Context at ${fire_tier}% ($read_tokens tokens). STOP new work NOW. Fire /rest. This is the second warning — you missed the first at ${TIERS[0]}%."
else
  NOTIFY_MSG="[Pre-compact — EMERGENCY] Context at ${fire_tier}% ($read_tokens tokens). Auto-compact IMMINENT. Fire /rest IMMEDIATELY. Last warning before context loss."
fi

{
  echo "=== Pre-compact notification fired: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "Beast: $beast | Model: $model | Tokens: $read_tokens (${current_pct}%) | Tier $tier_level fired at ${fire_tier}%"

  if [ -x "$NOTIFY_SCRIPT" ]; then
    echo "--- notify via $NOTIFY_SCRIPT ---"
    bash "$NOTIFY_SCRIPT" "$NOTIFY_MSG" --from "precompact" 2>&1 || echo "notify.sh failed (non-fatal)"
    echo "--- notification sent ---"
  else
    echo "--- WARN: notify.sh not found at $NOTIFY_SCRIPT, falling back to tmux ---"
    # Fallback: send directly to tmux session if notify.sh is missing
    TMUX_SESSION=$(echo "$beast" | sed 's/./\U&/' | sed 's/-.*//')
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      tmux send-keys -l -t "$TMUX_SESSION" "$NOTIFY_MSG" 2>/dev/null && tmux send-keys -t "$TMUX_SESSION" Enter 2>/dev/null
      echo "--- tmux fallback sent to $TMUX_SESSION ---"
    else
      echo "--- WARN: tmux session $TMUX_SESSION not found, notification dropped ---"
    fi
  fi

  echo "=== Notification complete: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
} >> "$LOG_FILE" 2>&1

exit 0
