#!/usr/bin/env bash
# sessions-sync.sh — gzip Claude session jsonls into sessions/ for backup.
#
# Canonical source: ~/.claude/projects/<repo-path-with-slashes-as-dashes>/*.jsonl
# Destination:      sessions/<basename>.jsonl.gz inside the Beast's repo
#
# Why: session jsonls are the canonical source for long-term memory (RAG
# ingests them alongside brain files). They live ONLY at the Claude projects
# path on a single machine. Without sessions-sync, a disk loss wipes
# most of the long-term memory — only brain files survive.
#
# Idempotent: skips files already gzipped unless --force. Re-gzips when source
# is newer than destination (catches active session growth).
#
# Usage:
#   bash scripts/sessions-sync.sh         # incremental, skip up-to-date
#   bash scripts/sessions-sync.sh --force # rebuild every gz file
#   bash scripts/sessions-sync.sh --quiet # suppress per-file output
#
# Run this BEFORE /rest, then run scripts/rag/rag-reindex, then commit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Compute Claude project dir name from repo absolute path.
# Convention: /home/gorn/workspace/foo -> -home-gorn-workspace-foo
CLAUDE_PROJECT_NAME="$(echo "$REPO_ROOT" | tr / -)"
SOURCE_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_NAME"
DEST_DIR="$REPO_ROOT/sessions"

FORCE=false
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --quiet) QUIET=true ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
  esac
done

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: Claude project source dir not found: $SOURCE_DIR" >&2
  echo "       (computed from repo path: $REPO_ROOT)" >&2
  echo "       If this Beast's Claude project lives elsewhere, set SOURCE_DIR manually." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

added=0
skipped=0
updated=0
for src in "$SOURCE_DIR"/*.jsonl; do
  [ -f "$src" ] || continue
  base="$(basename "$src")"
  dest="$DEST_DIR/${base}.gz"

  if [ -f "$dest" ] && [ "$FORCE" = false ]; then
    # If source is newer than destination, re-gzip (catches active session growth)
    if [ "$src" -nt "$dest" ]; then
      gzip -c "$src" > "$dest"
      updated=$((updated + 1))
      $QUIET || echo "  upd $base ($(du -h "$dest" | cut -f1))"
    else
      skipped=$((skipped + 1))
    fi
  else
    gzip -c "$src" > "$dest"
    added=$((added + 1))
    $QUIET || echo "  add $base ($(du -h "$dest" | cut -f1))"
  fi
done

total_size="$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)"
echo
echo "sessions-sync done."
echo "  source:  $SOURCE_DIR"
echo "  added:   $added"
echo "  updated: $updated"
echo "  skipped: $skipped"
echo "  dest:    $DEST_DIR ($total_size total)"
