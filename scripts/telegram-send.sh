#!/usr/bin/env bash
# Send a message or file to Telegram via Sable's bot
# Usage:
#   ./scripts/telegram-send.sh "message text"           # send text
#   ./scripts/telegram-send.sh --file /path/to/file      # send file
#   ./scripts/telegram-send.sh --file /path/to/file "caption"  # send file with caption

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env not found at $ENV_FILE" >&2
  exit 1
fi

source "$ENV_FILE"

# File sending mode
if [ "${1:-}" = "--file" ]; then
  FILE_PATH="${2:?Usage: telegram-send.sh --file /path/to/file [caption]}"
  CAPTION="${3:-}"

  if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found at $FILE_PATH" >&2
    exit 1
  fi

  RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "document=@${FILE_PATH}" \
    -F "caption=${CAPTION}")

  if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "File sent to Telegram."
  else
    echo "Telegram file send failed:" >&2
    echo "$RESPONSE" >&2
    exit 1
  fi
  exit 0
fi

# Text sending mode
MESSAGE="${1:?Usage: telegram-send.sh \"message\" OR telegram-send.sh --file /path/to/file}"

# Telegram max message length is 4096 chars — truncate if needed
if [ ${#MESSAGE} -gt 4096 ]; then
  MESSAGE="${MESSAGE:0:4090}..."
fi

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}")

if echo "$RESPONSE" | grep -q '"ok":true'; then
  echo "Sent to Telegram."
else
  echo "Telegram send failed:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
