#!/usr/bin/env bash
# Pre-Compact Notification Hook — Spec #53 (Graceful-rest pattern)
# Stop hook: detects imminent auto-compact and NOTIFIES the Beast to fire /rest.
#
# Registered at user-level ~/.claude/settings.json as a Stop hook.
# Reads transcript usage to estimate context fill. At threshold crossing,
# sends a notification via Beast-sovereign notify.sh telling the Beast to
# wrap up current task + fire /rest. One-shot latch via lockfile.
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

if [ -f "$LOCK_FILE" ]; then
  exit 0
fi

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

THRESHOLD_PCT=75

if [ -f "$beast_dir/beast.yaml" ]; then
  pct=$(grep '^precompact_threshold_pct:' "$beast_dir/beast.yaml" 2>/dev/null | awk '{print $2}')
  if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -gt 0 ] && [ "$pct" -lt 100 ]; then
    THRESHOLD_PCT=$pct
  fi
fi

threshold=$((CONTEXT_WINDOW * THRESHOLD_PCT / 100))

if [ "$read_tokens" -lt "$threshold" ] 2>/dev/null; then
  exit 0
fi

umask 0077
mkdir -p "$LOCK_DIR"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) threshold=$threshold tokens=$read_tokens model=$model beast=$beast" > "$LOCK_FILE"
chmod 0600 "$LOCK_FILE" 2>/dev/null || true

LOG_FILE="/tmp/precompact-ceremony-$beast.log"

# Notify the Beast via sovereign notify.sh (Spec #54 pattern).
# The Beast's CLAUDE.md standing order handles the rest:
# wrap up current task → write handoff → fire /rest → wake fresh.
NOTIFY_SCRIPT="$beast_dir/scripts/notify.sh"
NOTIFY_MSG="[Pre-compact] Context at ${THRESHOLD_PCT}% ($read_tokens tokens / $threshold threshold). Finish your current task or find a checkpoint, then fire /rest. Do NOT start new work — wrap up and rest."

{
  echo "=== Pre-compact notification fired: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "Beast: $beast | Model: $model | Tokens: $read_tokens / $threshold ($THRESHOLD_PCT%)"

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
