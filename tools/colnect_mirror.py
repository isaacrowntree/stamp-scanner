"""Mirror Colnect catalogue data + thumbnail images for local vector search.

Downloads stamp metadata via CAPI and thumbnail images from Colnect's CDN.
Stores everything under ~/.stamp-scanner/colnect/ so it's separate from
the user's library and easy to nuke/rebuild.

Usage:
    .venv/bin/python tools/colnect_mirror.py --country Australia
    .venv/bin/python tools/colnect_mirror.py --country "United States"
    .venv/bin/python tools/colnect_mirror.py --all          # every country
    .venv/bin/python tools/colnect_mirror.py --stats         # show mirror size
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import logging
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

import requests

# Reuse the auth client from colnect_lookup.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from colnect_lookup import ColnectClient

MIRROR_ROOT = Path.home() / ".stamp-scanner" / "colnect"
CATALOGUE_DB = MIRROR_ROOT / "catalogue.sqlite"
THUMBS_DIR = MIRROR_ROOT / "thumbs"
CDN_BASE = "https://i.colnect.net/images/t"

log = logging.getLogger("colnect_mirror")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


# ---- DB ----

def ensure_db() -> sqlite3.Connection:
    MIRROR_ROOT.mkdir(parents=True, exist_ok=True)
    THUMBS_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(CATALOGUE_DB), timeout=5.0)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS stamps (
            item_id INTEGER PRIMARY KEY,
            series_id INTEGER,
            producer_id INTEGER,
            front_picture_id INTEGER,
            back_picture_id INTEGER,
            description TEXT,
            catalog_codes TEXT,
            name TEXT,
            country TEXT,
            country_id INTEGER,
            thumb_path TEXT,
            embedded INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_country ON stamps(country)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_embedded ON stamps(embedded)
    """)
    conn.commit()
    return conn


# ---- URLize (from Colnect spec appendix) ----

def urlize(name: str) -> str:
    """Replicate Colnect's PHP urlize() for building image URLs."""
    # Strip HTML entities.
    name = re.sub(r"&[^;]+;", "_", name)
    # Remove invalid chars.
    for ch in '."><\\:/?#[]@!$&\'()*+,;=':
        name = name.replace(ch, "")
    # Collapse whitespace/underscores.
    name = re.sub(r"[\s_]+", "_", name)
    return name.strip("_")


def thumb_url(picture_id: int, item_name: str) -> str:
    """Build the CDN thumbnail URL from a picture_id and item name."""
    thousands = picture_id // 1000
    remainder = picture_id % 1000
    slug = urlize(item_name)
    return f"{CDN_BASE}/{thousands}/{remainder}/{slug}.jpg"


# ---- Mirror logic ----

def mirror_country(client: ColnectClient, conn: sqlite3.Connection,
                    country_name: str, country_id: int,
                    download_thumbs: bool = True,
                    max_concurrent: int = 20) -> int:
    """Download all stamp metadata for one country, optionally fetch thumbs.
    Returns the number of new stamps added."""
    log.info("mirroring %s (id=%d)...", country_name, country_id)

    data = client.list_stamps(country_id)
    if not isinstance(data, list):
        log.warning("  list returned non-list: %s", type(data))
        return 0

    log.info("  %d stamps in catalogue", len(data))
    new = 0
    rows_to_insert = []
    for row in data:
        if not isinstance(row, list) or len(row) < 8:
            continue
        item_id = int(row[0])
        front_pic = int(row[3]) if row[3] else 0
        name = str(row[7]) if len(row) > 7 else ""
        thumb = f"{item_id}.jpg" if front_pic else None
        rows_to_insert.append((
            item_id,
            int(row[1]) if row[1] else None,  # series_id
            int(row[2]) if row[2] else None,  # producer_id
            front_pic,
            int(row[4]) if row[4] else 0,     # back_picture_id
            str(row[5]) if len(row) > 5 else "",  # description
            str(row[6]) if len(row) > 6 else "",  # catalog_codes
            name,
            country_name,
            country_id,
            thumb,
        ))

    # Bulk upsert.
    conn.executemany("""
        INSERT OR REPLACE INTO stamps
        (item_id, series_id, producer_id, front_picture_id,
         back_picture_id, description, catalog_codes, name,
         country, country_id, thumb_path)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    """, rows_to_insert)
    conn.commit()
    new = len(rows_to_insert)
    log.info("  upserted %d rows", new)

    if download_thumbs and new > 0:
        download_missing_thumbs(conn, country_name, max_concurrent)

    return new


def download_missing_thumbs(conn: sqlite3.Connection, country: str,
                              max_concurrent: int = 20):
    """Fetch thumbnails we don't have on disk yet."""
    rows = conn.execute("""
        SELECT item_id, front_picture_id, name, thumb_path
        FROM stamps
        WHERE country = ? AND front_picture_id > 0
    """, (country,)).fetchall()

    to_download = []
    for item_id, pic_id, name, thumb_rel in rows:
        if not thumb_rel:
            continue
        dest = THUMBS_DIR / thumb_rel
        if dest.exists():
            continue
        url = thumb_url(pic_id, name)
        to_download.append((url, dest))

    if not to_download:
        log.info("  all %d thumbnails already cached", len(rows))
        return

    log.info("  downloading %d thumbnails (%d already cached)...",
             len(to_download), len(rows) - len(to_download))

    session = requests.Session()
    session.headers["User-Agent"] = "StampScanner/1.0.0"
    downloaded = 0
    failed = 0

    def fetch(url_dest):
        url, dest = url_dest
        try:
            r = session.get(url, timeout=10)
            if r.status_code == 200 and len(r.content) > 100:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(r.content)
                return True
            return False
        except Exception:
            return False

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_concurrent) as pool:
        futures = {pool.submit(fetch, item): item for item in to_download}
        for i, future in enumerate(concurrent.futures.as_completed(futures)):
            if future.result():
                downloaded += 1
            else:
                failed += 1
            if (i + 1) % 500 == 0:
                log.info("    %d/%d downloaded (%d failed)",
                         downloaded, i + 1, failed)

    log.info("  thumbnails: %d downloaded, %d failed, %d total on disk",
             downloaded, failed,
             sum(1 for _ in THUMBS_DIR.glob("*.jpg")))


def show_stats(conn: sqlite3.Connection):
    total = conn.execute("SELECT COUNT(*) FROM stamps").fetchone()[0]
    countries = conn.execute(
        "SELECT country, COUNT(*) FROM stamps GROUP BY country ORDER BY COUNT(*) DESC"
    ).fetchall()
    embedded = conn.execute(
        "SELECT COUNT(*) FROM stamps WHERE embedded = 1"
    ).fetchone()[0]
    thumbs = sum(1 for _ in THUMBS_DIR.glob("*.jpg")) if THUMBS_DIR.exists() else 0
    thumb_size = sum(f.stat().st_size for f in THUMBS_DIR.glob("*.jpg")) if THUMBS_DIR.exists() else 0

    print(f"Mirror: {MIRROR_ROOT}")
    print(f"  Catalogue: {total} stamps across {len(countries)} countries")
    print(f"  Thumbnails: {thumbs} on disk ({thumb_size / 1e6:.1f} MB)")
    print(f"  Embedded: {embedded}/{total}")
    print()
    if countries:
        print("  Top countries:")
        for name, count in countries[:15]:
            print(f"    {name}: {count}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--country", help="mirror a single country (e.g. 'Australia')")
    ap.add_argument("--all", action="store_true", help="mirror every country")
    ap.add_argument("--no-thumbs", action="store_true", help="skip thumbnail download")
    ap.add_argument("--stats", action="store_true", help="show mirror stats")
    ap.add_argument("--concurrent", type=int, default=20,
                     help="max concurrent thumbnail downloads (default 20)")
    args = ap.parse_args()

    conn = ensure_db()

    if args.stats:
        show_stats(conn)
        return

    key = os.environ.get("COLNECT_API_KEY")
    secret = os.environ.get("COLNECT_API_SECRET") or key
    if not key:
        log.error("COLNECT_API_KEY not set. Add to .env.local")
        sys.exit(1)

    client = ColnectClient(key, secret)

    if args.country:
        cid = client.country_id(args.country)
        if cid is None:
            log.error("country '%s' not found in Colnect", args.country)
            # Show close matches.
            countries = client.countries()
            q = args.country.lower()
            close = [n for n in countries if q in n]
            if close:
                log.info("did you mean: %s", ", ".join(close[:10]))
            sys.exit(1)
        mirror_country(client, conn, args.country, cid,
                        download_thumbs=not args.no_thumbs,
                        max_concurrent=args.concurrent)
    elif args.all:
        countries = client.countries()
        log.info("mirroring %d countries", len(countries))
        for name, cid in sorted(countries.items()):
            mirror_country(client, conn, name, cid,
                            download_thumbs=not args.no_thumbs,
                            max_concurrent=args.concurrent)
    else:
        ap.print_help()
        return

    show_stats(conn)
    conn.close()


if __name__ == "__main__":
    main()
