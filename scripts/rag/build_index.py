#!/usr/bin/env python3
"""
Beast RAG — build the local vector index from brain files + conversation jsonls.

Generic: auto-detects repo root from script location (two dirs up from scripts/rag/).
Works for any Beast — just copy scripts/rag/ into the Beast's repo.

Indexes:
  - All .md and .jsonl files under ψ/ (resonance, learnings, retros, life, voice)
  - Conversation jsonl files in ~/.claude/projects/<project-slug>/

Storage:
  - SQLite database at scripts/rag/index.db (chmod 600)
  - Embeddings stored as raw bytes (numpy arrays)
  - One row per chunk with: source_path, chunk_idx, text, embedding

Embedding:
  - fastembed BAAI/bge-small-en-v1.5 (384-dim, ONNX, no PyTorch)
  - Local only — no data leaves the machine

Run: ./build_index.py [--rebuild] [--beast-root /path/to/repo]
"""

import os
import sys
import json
import gzip
import sqlite3
import argparse
import time
import tempfile
import shutil
from pathlib import Path

import numpy as np
from fastembed import TextEmbedding

# Auto-detect repo root: this script lives at <repo>/scripts/rag/build_index.py
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_REPO_ROOT = SCRIPT_DIR.parent.parent

# Allowed file extensions for indexing (security: whitelist only)
ALLOWED_EXTENSIONS = {".md", ".jsonl"}

MODEL_NAME = "BAAI/bge-small-en-v1.5"
CHUNK_SIZE_CHARS = 1500  # ~300-400 tokens
CHUNK_OVERLAP = 200


def resolve_paths(beast_root=None):
    """Derive all paths from the beast repo root."""
    repo_root = Path(beast_root) if beast_root else DEFAULT_REPO_ROOT
    repo_root = repo_root.resolve()

    psi_dir = repo_root / "ψ"
    sessions_backup_dir = repo_root / "sessions"
    db_path = repo_root / "scripts/rag/index.db"

    # Claude project dir: derived from repo path
    # /home/gorn/workspace/karo -> -home-gorn-workspace-karo
    slug = str(repo_root).replace("/", "-")
    sessions_raw_dir = Path.home() / f".claude/projects/{slug}"

    return repo_root, psi_dir, sessions_backup_dir, sessions_raw_dir, db_path


def chunk_text(text, size=CHUNK_SIZE_CHARS, overlap=CHUNK_OVERLAP):
    """Simple character-based chunker with overlap. Good enough for our scale."""
    if len(text) <= size:
        return [text]
    chunks = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        chunks.append(text[start:end])
        if end == len(text):
            break
        start = end - overlap
    return chunks


def open_jsonl(path):
    """Open a .jsonl or .jsonl.gz file for reading."""
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="ignore")
    return open(path, encoding="utf-8", errors="ignore")


def extract_jsonl_text(path):
    """Extract human-readable conversation text from a Claude session jsonl (.gz supported)."""
    parts = []
    with open_jsonl(path) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            ts = obj.get("timestamp", "")
            msg = obj.get("message", {})
            role = msg.get("role", obj.get("type", "?"))
            content = msg.get("content", "")
            text = ""
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                bits = []
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "text":
                        bits.append(item.get("text", ""))
                    elif item.get("type") == "tool_use":
                        name = item.get("name", "")
                        inp = item.get("input", {})
                        if name == "Bash" and "command" in inp:
                            cmd = inp["command"]
                            if "discord-send" in cmd or "telegram-send" in cmd or "/api/dm" in cmd:
                                bits.append(f"[OUTBOUND] {cmd[:1500]}")
                text = "\n".join(b for b in bits if b)
            if text and text.strip():
                parts.append(f"[{ts}] [{role}] {text}")
    return "\n\n".join(parts)


def collect_documents(repo_root, psi_dir, sessions_backup_dir, sessions_raw_dir):
    """Yield (source_id, source_path, full_text) for every document to index."""
    skip_names = {"CLAUDE.md", ".gitkeep"}
    for md in psi_dir.rglob("*"):
        # Security: only index whitelisted file types
        if md.suffix not in ALLOWED_EXTENSIONS:
            continue
        if md.name in skip_names:
            continue
        try:
            text = md.read_text(encoding="utf-8", errors="ignore")
        except Exception as e:
            print(f"  skip {md}: {e}", file=sys.stderr)
            continue
        if text.strip():
            rel = str(md.relative_to(repo_root))
            yield ("brain", rel, text)

    # Sessions: prefer the gzipped backup inside the repo (durable),
    # fall back to raw Claude project dir for files not yet backed up.
    seen_sessions = set()
    if sessions_backup_dir.exists():
        for gz in sorted(sessions_backup_dir.glob("*.jsonl.gz")):
            try:
                text = extract_jsonl_text(gz)
            except Exception as e:
                print(f"  skip {gz.name}: {e}", file=sys.stderr)
                continue
            if text.strip():
                base = gz.name.removesuffix(".gz")
                seen_sessions.add(base)
                yield ("session", base, text)

    if sessions_raw_dir.exists():
        for jsonl in sorted(sessions_raw_dir.glob("*.jsonl")):
            if jsonl.name in seen_sessions:
                continue  # already covered by gzipped backup
            try:
                text = extract_jsonl_text(jsonl)
            except Exception as e:
                print(f"  skip {jsonl.name}: {e}", file=sys.stderr)
                continue
            if text.strip():
                yield ("session", jsonl.name, text)


def content_hash(text):
    """SHA-256 hash of document text for change detection."""
    import hashlib
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def init_db(conn):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_type TEXT NOT NULL,
            source_path TEXT NOT NULL,
            chunk_idx INTEGER NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_source ON chunks(source_path);
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS file_hashes (
            source_path TEXT PRIMARY KEY,
            hash TEXT NOT NULL,
            indexed_at INTEGER NOT NULL
        );
        """
    )
    conn.commit()


def main():
    parser = argparse.ArgumentParser(description="Beast RAG index builder")
    parser.add_argument("--rebuild", action="store_true", help="Drop and rebuild the index")
    parser.add_argument("--beast-root", type=str, default=None,
                        help="Beast repo root (default: auto-detect from script location)")
    args = parser.parse_args()

    repo_root, psi_dir, sessions_backup_dir, sessions_raw_dir, db_path = resolve_paths(args.beast_root)
    beast_name = repo_root.name

    print(f"Beast RAG index builder — {beast_name}")
    print(f"  repo root: {repo_root}")
    print(f"  brain dir: {psi_dir}")
    print(f"  sessions backup dir: {sessions_backup_dir}")
    print(f"  sessions raw dir: {sessions_raw_dir}")
    print(f"  db: {db_path}")
    print(f"  model: {MODEL_NAME}")
    print(f"  allowed extensions: {ALLOWED_EXTENSIONS}")

    if args.rebuild and db_path.exists():
        db_path.unlink()
        print("  rebuilt: dropped old db")

    # Atomic write: build into the db path directly (sqlite handles WAL),
    # but set restrictive permissions on creation
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    init_db(conn)

    # Security: restrict db file permissions (owner read/write only)
    os.chmod(db_path, 0o600)

    print("Loading embedding model (first run downloads ~80MB)...")
    t0 = time.time()
    model = TextEmbedding(model_name=MODEL_NAME)
    print(f"  loaded in {time.time() - t0:.1f}s")

    print("Chunking + embedding (streaming, one doc at a time)...")
    total_chunks = 0
    total_docs = 0
    t_start = time.time()
    EMBED_BATCH_SIZE = 32  # embed in small batches to cap memory

    skipped = 0
    updated = 0
    for source_type, source_path, text in collect_documents(repo_root, psi_dir, sessions_backup_dir, sessions_raw_dir):
        total_docs += 1
        doc_hash = content_hash(text)

        if not args.rebuild:
            stored = conn.execute(
                "SELECT hash FROM file_hashes WHERE source_path = ?", (source_path,)
            ).fetchone()
            if stored and stored[0] == doc_hash:
                skipped += 1
                continue  # unchanged — skip

        # File is new or modified — delete old chunks and re-index
        conn.execute("DELETE FROM chunks WHERE source_path = ?", (source_path,))

        chunks = chunk_text(text)
        if not chunks:
            continue

        # Embed in small batches to keep memory flat
        doc_chunks = 0
        for batch_start in range(0, len(chunks), EMBED_BATCH_SIZE):
            batch = chunks[batch_start:batch_start + EMBED_BATCH_SIZE]
            embeddings = list(model.embed(batch))
            for idx, (chunk, emb) in enumerate(zip(batch, embeddings), start=batch_start):
                arr = np.asarray(emb, dtype=np.float32)
                conn.execute(
                    "INSERT INTO chunks (source_type, source_path, chunk_idx, text, embedding) VALUES (?, ?, ?, ?, ?)",
                    (source_type, source_path, idx, chunk, arr.tobytes()),
                )
            doc_chunks += len(batch)
            del embeddings  # free memory between batches

        # Store the hash for next incremental run
        conn.execute(
            "INSERT OR REPLACE INTO file_hashes (source_path, hash, indexed_at) VALUES (?, ?, ?)",
            (source_path, doc_hash, int(time.time())),
        )
        conn.commit()
        total_chunks += doc_chunks
        updated += 1
        print(f"  +{doc_chunks:4d} chunks  {source_path}")
        del text, chunks  # free document text before loading next

    elapsed = time.time() - t_start
    print(f"\nDone. {total_chunks} new chunks from {updated} changed docs ({skipped} unchanged skipped) in {elapsed:.1f}s")
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
        ("last_built_at", str(int(time.time()))),
    )
    conn.commit()
    conn.close()

    # Ensure permissions after all writes
    os.chmod(db_path, 0o600)


if __name__ == "__main__":
    main()
