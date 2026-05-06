#!/bin/bash
# Beast Sleep Script — exit and restart Claude Code in a tmux session.
# Usage: bash ~/.claude/scripts/sleep.sh <BeastName>
# Example: bash ~/.claude/scripts/sleep.sh Karo
#
# Lifecycle:
#   1. Send /exit via notification queue.
#   2. Poll for clean exit, up to EXIT_TIMEOUT_SEC (default 300s = 5 min).
#      This is long enough to cover pre-rest rituals (sessions-sync, rag-reindex,
#      handoff writes, commits) that legitimately take minutes.
#   3. If still running: escalate — send Ctrl-C + Enter to interrupt any hung
#      stop-hook, give INTERRUPT_GRACE_SEC (default 30s) to clean up.
#   4. If STILL running: force-kill the claude process in that pane, log the
#      incident to ~/.claude/data/sleep-log.md + ψ/data/blackouts.log.
#   5. Always proceed to wake step — never leave the Beast in zombie rest state.
#      The 04-16 Mara incident + 04-18 Bertus 31h stall traced to the old script
#      exiting on timeout without recovery.

set -u  # unset-var guard; do NOT use -e so we always reach the wake step

BEAST="${1:-}"

if [ -z "$BEAST" ]; then
  echo "Usage: bash ~/.claude/scripts/sleep.sh <BeastName>"
  echo "Example: bash ~/.claude/scripts/sleep.sh Karo"
  exit 1
fi

if ! tmux has-session -t "$BEAST" 2>/dev/null; then
  echo "Error: No tmux session named '$BEAST'"
  exit 1
fi

BEAST_LOWER=$(echo "$BEAST" | tr '[:upper:]' '[:lower:]')
# Spec #54 sovereignty: use target Beast's own notify.sh (not legacy denbook path)
NOTIFY="/home/gorn/workspace/$BEAST_LOWER/scripts/notify.sh"
WORKSPACE="/home/gorn/workspace/$BEAST_LOWER"
SLEEP_LOG="$HOME/.claude/data/sleep-log.md"
BLACKOUT_LOG="$WORKSPACE/ψ/data/blackouts.log"

EXIT_TIMEOUT_SEC=${EXIT_TIMEOUT_SEC:-300}
INTERRUPT_GRACE_SEC=${INTERRUPT_GRACE_SEC:-30}

mkdir -p "$(dirname "$SLEEP_LOG")"

log_sleep_event() {
  local ts outcome detail
  ts=$(date '+%Y-%m-%d %H:%M:%S %z')
  outcome="$1"
  detail="${2:-}"
  echo "[$ts] $BEAST_LOWER $outcome${detail:+ — $detail}" >> "$SLEEP_LOG"
  # Also mirror force-kill incidents into the Beast's blackout journal so they
  # see it on wake. Silent success stays out of the Beast's journal.
  if [ "$outcome" = "force-killed" ] || [ "$outcome" = "interrupted" ]; then
    if [ -d "$(dirname "$BLACKOUT_LOG")" ]; then
      echo "[$ts] sleep.sh $outcome${detail:+ — $detail}" >> "$BLACKOUT_LOG"
    fi
  fi
}

pane_is_claude() {
  local cmd
  cmd=$(tmux display-message -t "$BEAST" -p '#{pane_current_command}' 2>/dev/null)
  [ "$cmd" = "claude" ] || [ "$cmd" = "node" ]
}

pane_pid() {
  tmux display-message -t "$BEAST" -p '#{pane_pid}' 2>/dev/null
}

echo "Putting $BEAST to sleep..."

# Phase 1: graceful /exit via queue, poll up to EXIT_TIMEOUT_SEC
bash "$NOTIFY" "/exit" --from "sleep"
echo "Waiting up to ${EXIT_TIMEOUT_SEC}s for Claude to exit cleanly..."

poll_until=$((SECONDS + EXIT_TIMEOUT_SEC))
exit_outcome="clean"
while [ $SECONDS -lt $poll_until ]; do
  sleep 2
  if ! pane_is_claude; then
    echo "$BEAST session ended cleanly."
    break
  fi
done

if pane_is_claude; then
  exit_outcome="interrupted"
  echo "Claude still running after ${EXIT_TIMEOUT_SEC}s — sending interrupt..."
  # Send Ctrl-C to break out of any hung stop-hook or long operation
  tmux send-keys -t "$BEAST" C-c 2>/dev/null
  sleep 1
  # Send /exit again after interrupt
  bash "$NOTIFY" "/exit" --from "sleep"

  poll_until=$((SECONDS + INTERRUPT_GRACE_SEC))
  while [ $SECONDS -lt $poll_until ]; do
    sleep 2
    if ! pane_is_claude; then
      echo "$BEAST session ended after interrupt."
      break
    fi
  done
fi

if pane_is_claude; then
  # Phase 3: force-kill. Beast could not shut down gracefully even after interrupt.
  exit_outcome="force-killed"
  pid=$(pane_pid)
  echo "Claude still running after interrupt grace — force-killing pane pid ${pid:-unknown}..."
  if [ -n "${pid:-}" ]; then
    # Kill the full process tree rooted at the pane (claude + children).
    # First pass: TERM children so well-behaved ones get a chance to cleanup,
    # TERM parent. Second pass: KILL everything that survived.
    # Belt-and-suspenders per Pip's T#680 smoke-test: SIGTERM can be trapped,
    # so we explicitly SIGKILL any orphans that remain after the parent dies.
    pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
    sleep 1
    # Orphan scan: any claude/node process still rooted in this Beast's
    # workspace after the parent is gone gets SIGKILL'd directly.
    #
    # INVARIANT (do NOT relax — Bertus T#680 QA note): the pattern MUST be
    # scoped by "$WORKSPACE" so it only matches claude processes running in
    # THIS Beast's workspace. A pattern like "claude" (no workspace anchor)
    # would sweep every Beast's claude process on the box — including any
    # secondary sessions outside the sleep flow. Keep the $WORKSPACE segment.
    if [ -n "${WORKSPACE:-}" ]; then
      pgrep -f "claude.*${WORKSPACE}" 2>/dev/null | xargs -r kill -KILL 2>/dev/null
    fi
  fi
  # Send Ctrl-C to clean up the tmux pane shell state
  tmux send-keys -t "$BEAST" C-c 2>/dev/null
  sleep 1
fi

log_sleep_event "$exit_outcome"

# Small pause before restart
sleep 3

echo "Waking $BEAST up..."

if [ -d "$WORKSPACE" ]; then
  bash "$NOTIFY" "cd $WORKSPACE && claude --dangerously-skip-permissions" --from "sleep"
else
  bash "$NOTIFY" "claude --dangerously-skip-permissions" --from "sleep"
fi

# Wait for Claude to start, then send /recap via queue
sleep 5
bash "$NOTIFY" "/recap" --from "sleep"

# Wake the Beast via API — resumes scheduler
sleep 3
curl -s -X POST "http://localhost:47778/api/beast/$BEAST_LOWER/wake?as=$BEAST_LOWER" > /dev/null 2>&1

echo "$BEAST is waking up with /recap and scheduler resumed. Exit outcome: $exit_outcome."
