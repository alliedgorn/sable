#!/usr/bin/env python3
"""
Beast RAG — search the local vector index.

Generic: auto-detects db path from script location (two dirs up from scripts/rag/).
Works for any Beast — just copy scripts/rag/ into the Beast's repo.

Usage:
    ./search.py "limiz convo"
    ./search.py "Hotel Derby double" --top 5
    ./search.py "stew belly" --type brain
    ./search.py "fluff name birth" --top 10 --json
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

import numpy as np
from fastembed import TextEmbedding

# Auto-detect: this script lives at <repo>/scripts/rag/search.py
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DB_PATH = SCRIPT_DIR / "index.db"
MODEL_NAME = "BAAI/bge-small-en-v1.5"


def cosine_topk(query_vec, all_vecs, k):
    """Brute-force cosine similarity. Fast enough for our scale (~10k chunks)."""
    q = query_vec / (np.linalg.norm(query_vec) + 1e-12)
    norms = np.linalg.norm(all_vecs, axis=1) + 1e-12
    normed = all_vecs / norms[:, None]
    scores = normed @ q
    idx = np.argpartition(-scores, min(k, len(scores) - 1))[:k]
    idx = idx[np.argsort(-scores[idx])]
    return idx, scores[idx]


def main():
    parser = argparse.ArgumentParser(description="Beast RAG search")
    parser.add_argument("query", help="The text to search for")
    parser.add_argument("--top", type=int, default=10, help="Top N results")
    parser.add_argument("--type", choices=["brain", "session"], help="Filter by source type")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--max-chars", type=int, default=600, help="Max chars per chunk preview")
    parser.add_argument("--db", type=str, default=None,
                        help="Path to index.db (default: auto-detect from script location)")
    args = parser.parse_args()

    DB_PATH = Path(args.db) if args.db else DEFAULT_DB_PATH
    if not DB_PATH.exists():
        print(f"ERROR: index not built yet. Run build_index.py first.", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(DB_PATH)
    where = ""
    params = []
    if args.type:
        where = "WHERE source_type = ?"
        params.append(args.type)
    rows = conn.execute(
        f"SELECT id, source_type, source_path, chunk_idx, text, embedding FROM chunks {where}",
        params,
    ).fetchall()
    conn.close()

    if not rows:
        print("No chunks in index", file=sys.stderr)
        sys.exit(1)

    embeddings = np.array(
        [np.frombuffer(r[5], dtype=np.float32) for r in rows]
    )

    model = TextEmbedding(model_name=MODEL_NAME)
    q_vec = next(model.embed([args.query]))
    q_vec = np.asarray(q_vec, dtype=np.float32)

    idx, scores = cosine_topk(q_vec, embeddings, args.top)

    results = []
    for rank, (i, score) in enumerate(zip(idx, scores), 1):
        row = rows[i]
        snippet = row[4]
        if len(snippet) > args.max_chars:
            snippet = snippet[: args.max_chars] + "…"
        results.append(
            {
                "rank": rank,
                "score": float(score),
                "source_type": row[1],
                "source_path": row[2],
                "chunk_idx": row[3],
                "text": snippet,
            }
        )

    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return

    print(f"\nQuery: {args.query!r}")
    print(f"Top {len(results)} matches\n")
    for r in results:
        print(f"[{r['rank']:2d}] score={r['score']:.3f}  {r['source_type']}  {r['source_path']} #{r['chunk_idx']}")
        print(f"    {r['text']}")
        print()


if __name__ == "__main__":
    main()
