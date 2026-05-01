#!/bin/bash
# Den notification queue — enqueue a message for THIS beast's queue
# Usage: notify.sh <message> [--from <sender>]
# Beast-owned. Per Spec #54 sovereignty pattern.

set -euo pipefail

# Derive THIS beast's name from script location: <beast>/scripts/notify.sh
SELF_BEAST="$(basename "$(dirname "$(dirname "$(readlink -f "$0")")")")"

MESSAGE=""
SENDER="server"  # default for backward compat with legacy server-adaptor calls

while [ $# -gt 0 ]; do
  case "$1" in
    --from) SENDER="$2"; shift 2 ;;
    *) MESSAGE="$1"; shift ;;
  esac
done

if [ -z "$MESSAGE" ]; then
  echo "Usage: notify.sh <message> [--from <sender>]" >&2
  exit 1
fi

# Validate sender — alphanumeric only, length <= 32 (anti-injection)
if ! [[ "$SENDER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
  echo "FATAL: invalid sender '$SENDER'" >&2
  exit 2
fi

QUEUE_DIR="/tmp/den-notify"
QUEUE_FILE="$QUEUE_DIR/$SELF_BEAST.queue"
LOCK_FILE="$QUEUE_DIR/$SELF_BEAST.lock"

mkdir -p "$QUEUE_DIR"
chmod 700 "$QUEUE_DIR" 2>/dev/null || true
umask 0077

# Format: [YYYY-MM-DD HH:MM:SS UTC+7] [from <sender>] <message>
TS=$(TZ=Asia/Bangkok date '+[%Y-%m-%d %H:%M:%S UTC+7]')
STAMPED="$TS [from $SENDER] $MESSAGE"

# Base64 encode to safely handle newlines, quotes, special chars
ENCODED=$(echo -n "$STAMPED" | base64 -w 0)

# Atomic append with flock
flock "$LOCK_FILE" bash -c "echo '$ENCODED' >> '$QUEUE_FILE'"
