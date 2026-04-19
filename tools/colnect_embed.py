"""Compute CLIP embeddings for Colnect catalogue thumbnails and build a
vector index for nearest-neighbor stamp matching.

Embeds all thumbnails that haven't been processed yet (incremental).
Stores vectors in a numpy .npy file alongside a sorted list of item_ids
so vector[i] corresponds to item_ids[i].

Usage:
    .venv/bin/python tools/colnect_embed.py             # embed all pending
    .venv/bin/python tools/colnect_embed.py --query <crop.png>  # test lookup
    .venv/bin/python tools/colnect_embed.py --stats     # show index size
"""
from __future__ import annotations

import argparse
import logging
import os
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

MIRROR_ROOT = Path.home() / ".stamp-scanner" / "colnect"
CATALOGUE_DB = MIRROR_ROOT / "catalogue.sqlite"
THUMBS_DIR = MIRROR_ROOT / "thumbs"
EMBEDDINGS_FILE = MIRROR_ROOT / "embeddings.npy"
ITEM_IDS_FILE = MIRROR_ROOT / "item_ids.npy"

log = logging.getLogger("colnect_embed")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")

# Lazy-loaded model.
_model = None
_preprocess = None
_device = None


def load_clip():
    global _model, _preprocess, _device
    if _model is not None:
        return
    try:
        import torch
        import clip
        _device = "mps" if torch.backends.mps.is_available() else "cpu"
        _model, _preprocess = clip.load("ViT-B/32", device=_device)
        _model.eval()
        log.info("CLIP ViT-B/32 loaded on %s", _device)
    except ImportError:
        log.error("pip install git+https://github.com/openai/CLIP.git torch")
        sys.exit(1)


def embed_image(pil: Image.Image) -> np.ndarray:
    """Return a 512-dim L2-normalised embedding for a PIL image."""
    import torch
    load_clip()
    with torch.no_grad():
        tensor = _preprocess(pil).unsqueeze(0).to(_device)
        features = _model.encode_image(tensor)
        features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().flatten().astype(np.float32)


def embed_file(path: Path) -> np.ndarray | None:
    try:
        pil = Image.open(path).convert("RGB")
        return embed_image(pil)
    except Exception as e:
        log.warning("failed to embed %s: %s", path.name, e)
        return None


def build_embeddings(conn: sqlite3.Connection, batch_size: int = 100):
    """Embed all thumbnails not yet marked `embedded = 1`."""
    rows = conn.execute("""
        SELECT item_id, thumb_path FROM stamps
        WHERE embedded = 0 AND thumb_path IS NOT NULL
        ORDER BY item_id
    """).fetchall()

    if not rows:
        log.info("all thumbnails already embedded")
        return

    # Load existing embeddings if any.
    existing_ids = np.array([], dtype=np.int64)
    existing_vecs = np.empty((0, 512), dtype=np.float32)
    if EMBEDDINGS_FILE.exists() and ITEM_IDS_FILE.exists():
        existing_vecs = np.load(EMBEDDINGS_FILE)
        existing_ids = np.load(ITEM_IDS_FILE)
        log.info("loaded %d existing embeddings", len(existing_ids))

    log.info("embedding %d new thumbnails...", len(rows))
    load_clip()

    new_ids = []
    new_vecs = []
    t0 = time.time()
    for i, (item_id, thumb_rel) in enumerate(rows):
        path = THUMBS_DIR / thumb_rel
        if not path.exists():
            continue
        vec = embed_file(path)
        if vec is not None:
            new_ids.append(item_id)
            new_vecs.append(vec)

        if (i + 1) % batch_size == 0 or i + 1 == len(rows):
            elapsed = time.time() - t0
            rate = (i + 1) / max(elapsed, 0.01)
            eta = (len(rows) - i - 1) / max(rate, 0.01)
            log.info("  %d/%d (%.0f/s, ETA %.0fs)", i + 1, len(rows), rate, eta)

    if not new_vecs:
        log.info("no new embeddings produced")
        return

    new_vecs_arr = np.array(new_vecs, dtype=np.float32)
    new_ids_arr = np.array(new_ids, dtype=np.int64)

    # Merge with existing.
    all_ids = np.concatenate([existing_ids, new_ids_arr])
    all_vecs = np.vstack([existing_vecs, new_vecs_arr]) if len(existing_vecs) else new_vecs_arr

    # Sort by item_id for deterministic ordering.
    order = np.argsort(all_ids)
    all_ids = all_ids[order]
    all_vecs = all_vecs[order]

    np.save(ITEM_IDS_FILE, all_ids)
    np.save(EMBEDDINGS_FILE, all_vecs)
    log.info("saved %d embeddings (%.1f MB)",
             len(all_ids), all_vecs.nbytes / 1e6)

    # Mark as embedded in the catalogue DB.
    conn.executemany(
        "UPDATE stamps SET embedded = 1 WHERE item_id = ?",
        [(int(iid),) for iid in new_ids_arr]
    )
    conn.commit()


def query(crop_path: Path, top_k: int = 5):
    """Embed a crop and find nearest neighbours in the catalogue."""
    if not EMBEDDINGS_FILE.exists():
        log.error("no embeddings found — run without --query first")
        sys.exit(1)

    vecs = np.load(EMBEDDINGS_FILE)
    ids = np.load(ITEM_IDS_FILE)
    log.info("loaded %d catalogue embeddings", len(ids))

    q = embed_file(crop_path)
    if q is None:
        log.error("failed to embed query image")
        sys.exit(1)

    # Cosine similarity (vectors are already L2-normalised).
    sims = vecs @ q
    top_idx = np.argsort(-sims)[:top_k]

    conn = sqlite3.connect(str(CATALOGUE_DB))
    conn.row_factory = sqlite3.Row
    print(f"\nTop-{top_k} matches for {crop_path.name}:\n")
    for rank, idx in enumerate(top_idx, 1):
        item_id = int(ids[idx])
        sim = float(sims[idx])
        row = conn.execute(
            "SELECT name, country, catalog_codes, description FROM stamps WHERE item_id=?",
            (item_id,)).fetchone()
        if row:
            print(f"  {rank}. sim={sim:.3f}  Colnect {item_id}")
            print(f"     {row['name']}")
            print(f"     {row['country']} — {row['catalog_codes']}")
            print(f"     {row['description'][:100]}")
            print()
        else:
            print(f"  {rank}. sim={sim:.3f}  Colnect {item_id} (not in local DB)")
    conn.close()


def show_stats():
    if not CATALOGUE_DB.exists():
        print("No mirror found. Run colnect_mirror.py first.")
        return
    conn = sqlite3.connect(str(CATALOGUE_DB))
    total = conn.execute("SELECT COUNT(*) FROM stamps").fetchone()[0]
    embedded = conn.execute("SELECT COUNT(*) FROM stamps WHERE embedded=1").fetchone()[0]
    conn.close()
    thumbs = sum(1 for _ in THUMBS_DIR.glob("*.jpg")) if THUMBS_DIR.exists() else 0
    emb_size = EMBEDDINGS_FILE.stat().st_size / 1e6 if EMBEDDINGS_FILE.exists() else 0
    ids_count = len(np.load(ITEM_IDS_FILE)) if ITEM_IDS_FILE.exists() else 0
    print(f"Mirror:     {MIRROR_ROOT}")
    print(f"Catalogue:  {total} stamps")
    print(f"Thumbnails: {thumbs} on disk")
    print(f"Embeddings: {ids_count} vectors ({emb_size:.1f} MB)")
    print(f"Coverage:   {embedded}/{total} stamps embedded")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--query", type=Path, help="find nearest matches for a crop image")
    ap.add_argument("--top-k", type=int, default=5)
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()

    if args.stats:
        show_stats()
        return

    if args.query:
        query(args.query, top_k=args.top_k)
        return

    if not CATALOGUE_DB.exists():
        log.error("catalogue DB not found — run colnect_mirror.py first")
        sys.exit(1)

    conn = sqlite3.connect(str(CATALOGUE_DB), timeout=5.0)
    build_embeddings(conn)
    conn.close()
    show_stats()


if __name__ == "__main__":
    main()
