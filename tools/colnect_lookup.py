"""Colnect API lookup — matches VLM-identified stamps to entries in
Colnect's catalogue via their CAPI. Requires API key + secret.

Set in .env.local:
    COLNECT_API_KEY=your_app_id
    COLNECT_API_SECRET=your_secret

Usage:
    .venv/bin/python tools/colnect_lookup.py              # all unmatched
    .venv/bin/python tools/colnect_lookup.py --id <stamp_id>
    .venv/bin/python tools/colnect_lookup.py --search "Australia 1985 30c"
    .venv/bin/python tools/colnect_lookup.py --dry-run
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import logging
import os
import sqlite3
import sys
import time
import urllib.parse
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
APP_SUPPORT = Path(os.environ.get(
    "STAMP_APP_SUPPORT",
    str(Path.home() / "Library" / "Application Support" / "StampScanner")
))
DB_PATH = APP_SUPPORT / "library.sqlite"

COLNECT_BASE = "https://api.colnect.net"
LANG = "en"
CATEGORY = "stamps"
REQUEST_INTERVAL_SEC = 1.0

log = logging.getLogger("colnect")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


class ColnectClient:
    """Colnect CAPI client per the official API Specification.

    Auth: HMAC-SHA256(secret, "{path}>|<{timestamp}") in Capi-Hash header.
    User-Agent must be >15 chars and identify the app.
    """

    def __init__(self, app_id: str, secret: str):
        self.app_id = app_id
        self.secret = secret
        self.session = requests.Session()
        self.session.headers["User-Agent"] = "StampScanner/1.0.0 (github.com/isaacrowntree/stamp-scanner)"
        self._last_call = 0.0
        self._countries_cache: dict[str, int] | None = None

    def _throttle(self):
        elapsed = time.time() - self._last_call
        if elapsed < REQUEST_INTERVAL_SEC:
            time.sleep(REQUEST_INTERVAL_SEC - elapsed)
        self._last_call = time.time()

    def _compute_hash(self, timestamp: str, path: str) -> str:
        msg = f"{path}>|<{timestamp}".encode()
        return hmac.new(self.secret.encode(), msg, hashlib.sha256).hexdigest()

    def _get(self, path: str) -> object | None:
        self._throttle()
        url = f"{COLNECT_BASE}{path}"
        ts = str(int(time.time()))
        headers = {
            "Capi-Timestamp": ts,
            "Capi-Hash": self._compute_hash(ts, path),
        }
        try:
            r = self.session.get(url, timeout=15, headers=headers)
            if r.status_code in (401, 403):
                log.error("auth rejected (%s): %s", r.status_code, r.text[:200])
                return None
            if r.status_code == 404:
                return None
            if r.status_code != 200:
                log.warning("%s returned %s: %s", path, r.status_code, r.text[:200])
                return None
            return r.json()
        except Exception as e:
            log.warning("request failed: %s", e)
            return None

    def _action(self, action: str, **filters) -> object | None:
        """Build a category-specific path:
        /{lang}/api/{app_id}/{action}/cat/{category}/key1/val1/key2/val2
        """
        path = f"/{LANG}/api/{self.app_id}/{action}/cat/{CATEGORY}"
        for k, v in filters.items():
            path += f"/{k}/{v}"
        return self._get(path)

    # ---- Reference data (cached) ----

    def countries(self) -> dict[str, int]:
        """Name → Colnect country_id. Cached in memory."""
        if self._countries_cache is not None:
            return self._countries_cache
        data = self._action("countries")
        if not isinstance(data, list):
            return {}
        mapping: dict[str, int] = {}
        for row in data:
            if isinstance(row, list) and len(row) >= 2:
                cid, name = int(row[0]), str(row[1])
                mapping[name.lower()] = cid
        self._countries_cache = mapping
        log.info("loaded %d countries from Colnect", len(mapping))
        return mapping

    def country_id(self, name: str) -> int | None:
        aliases = {
            "usa": "united states", "us": "united states",
            "u.s.": "united states", "u.s.a.": "united states",
            "great britain": "united kingdom", "britain": "united kingdom",
            "ussr": "soviet union", "deutschland": "germany",
        }
        q = aliases.get(name.strip().lower(), name.strip().lower())
        return self.countries().get(q)

    # ---- Search ----

    def search(self, query: str, page: int = 1) -> dict | None:
        """Global search. Returns {page, last_page, total_items, items:[]}."""
        path = (f"/{LANG}/api/{self.app_id}/search"
                f"/collectibles/{CATEGORY}"
                f"/q/{urllib.parse.quote(query, safe='')}")
        if page > 1:
            path += f"/page/{page}"
        return self._get(path)

    # ---- Item detail ----

    def item(self, item_id: int) -> list | None:
        """Full item detail. Returns a flat array whose field order is
        defined by the `fields` action. Call `fields()` first to know
        which index is which."""
        return self._action("item", id=item_id)

    def fields(self) -> list | None:
        """Ordered list of field names for the `item` action."""
        return self._action("fields")

    # ---- List ----

    def list_stamps(self, country_id: int, year: int | None = None) -> list | None:
        filters = {"country": country_id}
        if year is not None:
            filters["year"] = year
        return self._action("list", **filters)

    # ---- Image search (paid, disabled by default) ----

    def image_search(self, image_path: Path, **filters) -> dict | None:
        """POST image_search. Requires payment plan. Returns {distances, best_matches}."""
        import base64
        data = Path(image_path).read_bytes()
        b64 = base64.b64encode(data).decode()
        path = f"/{LANG}/api/{self.app_id}/image_search/cat/{CATEGORY}"
        for k, v in filters.items():
            path += f"/{k}/{v}"
        ts = str(int(time.time()))
        headers = {
            "Capi-Timestamp": ts,
            "Capi-Hash": self._compute_hash(ts, path),
        }
        try:
            r = self.session.post(
                f"{COLNECT_BASE}{path}",
                data={"picture_base64": b64},
                headers=headers,
                timeout=30,
            )
            if r.status_code == 200:
                return r.json()
            log.warning("image_search %s: %s", r.status_code, r.text[:200])
        except Exception as e:
            log.warning("image_search failed: %s", e)
        return None


# ---- DB integration ----

def lookup_and_update(conn: sqlite3.Connection, client: ColnectClient,
                       row: dict, dry_run: bool) -> bool:
    """Search Colnect for a stamp using VLM-provided metadata. Returns
    True if a match was found."""
    country = row.get("country")
    year = row.get("year")
    denomination = row.get("denomination") or ""

    # Build a search query from whatever metadata we have.
    parts = [p for p in [country, str(year) if year else None, denomination]
             if p]
    if not parts:
        log.info("  %s: skip (no metadata)", row["id"]); return False

    query = " ".join(parts)
    result = client.search(query)
    if not result or not result.get("items"):
        log.info("  %s: no match for '%s'", row["id"], query); return False

    best = result["items"][0]
    # items: [cat_id, item_id, series_id, producer_id, front_pic_id,
    #         back_pic_id, description, catalog_codes, name]
    item_id = best[1] if len(best) > 1 else "?"
    item_name = best[8] if len(best) > 8 else "?"
    catalogue_ref = f"Colnect {item_id}"
    log.info("  %s: → %s (%s)", row["id"], catalogue_ref, item_name)

    if dry_run:
        return True

    conn.execute(
        "UPDATE stamps SET catalogueRef = ? WHERE id = ?",
        (catalogue_ref, row["id"])
    )
    conn.commit()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", help="process single stamp id")
    ap.add_argument("--search", help="raw search query (skips DB)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("COLNECT_API_KEY")
    secret = os.environ.get("COLNECT_API_SECRET") or key
    if not key:
        log.error("COLNECT_API_KEY not set. Add to .env.local:")
        log.error("    COLNECT_API_KEY=your_app_id")
        log.error("    COLNECT_API_SECRET=your_secret")
        log.error("Apply: https://colnect.com/en/help/collecting/colnect_api")
        sys.exit(1)

    client = ColnectClient(key, secret)

    # Ad-hoc search mode (no DB).
    if args.search:
        result = client.search(args.search)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    if not DB_PATH.exists():
        log.error("DB not found at %s", DB_PATH); sys.exit(1)

    conn = sqlite3.connect(str(DB_PATH), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=3000")

    if args.id:
        rows = conn.execute(
            "SELECT id, country, year, denomination FROM stamps WHERE id = ?",
            (args.id,)).fetchall()
    else:
        rows = conn.execute("""
            SELECT id, country, year, denomination
            FROM stamps
            WHERE country IS NOT NULL AND catalogueRef IS NULL
        """).fetchall()

    if not rows:
        log.info("nothing to match"); return

    log.info("matching %d stamp(s) via Colnect%s",
             len(rows), " (dry run)" if args.dry_run else "")
    matched = 0
    for row in rows:
        if lookup_and_update(conn, client, dict(row), args.dry_run):
            matched += 1

    log.info("done: %d/%d matched", matched, len(rows))
    conn.close()


if __name__ == "__main__":
    main()
