#!/usr/bin/env bash
# setup.sh — first-time setup for Beast local RAG.
#
# Generic: works for any Beast. Auto-detects beast name from repo directory.
# Creates a venv, installs fastembed + numpy, and warms the embedding model
# (downloads ~80MB on first run).
#
# Usage: bash scripts/rag/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BEAST_NAME="$(basename "$REPO_ROOT")"
cd "$SCRIPT_DIR"

echo "Beast RAG setup — $BEAST_NAME"
echo "  repo: $REPO_ROOT"
echo "  scripts: $SCRIPT_DIR"

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv not found. Install from https://github.com/astral-sh/uv" >&2
  exit 1
fi

echo "[1/3] Creating venv..."
uv venv --clear .venv

echo "[2/3] Installing fastembed + numpy..."
uv pip install --python .venv/bin/python fastembed numpy

echo "[3/3] Warming the embedding model (downloads ~80MB on first run)..."
.venv/bin/python -c "
from fastembed import TextEmbedding
m = TextEmbedding(model_name='BAAI/bge-small-en-v1.5')
list(m.embed(['warmup']))
print('OK model ready')
"

echo
echo "Done. Next steps for $BEAST_NAME:"
echo
echo "  1. Build the index:"
echo "     bash scripts/rag/${BEAST_NAME}-reindex"
echo
echo "  2. Search:"
echo "     bash scripts/rag/${BEAST_NAME}-search 'your query'"
echo
echo "  3. Add to CLAUDE.md standing orders:"
echo "     - Before rest: bash scripts/rag/${BEAST_NAME}-reindex"
echo "     - On wake: bash scripts/rag/${BEAST_NAME}-search \"topic\" to recall"
echo "     - Frame as memory, not a tool: say 'I remember' not 'I searched'"
