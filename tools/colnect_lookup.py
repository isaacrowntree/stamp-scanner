"""Colnect API lookup — matches VLM-identified stamps to entries in
Colnect's catalogue (https://colnect.com). Requires an API key.

Apply for a free key: https://colnect.com/en/help/collecting/colnect_api
(email them with your use case, they reply with a key).

Set the key in .env.local:
    COLNECT_API_KEY=your_key_here

Usage:
    .venv/bin/python tools/colnect_lookup.py              # all unmatched stamps
    .venv/bin/python tools/colnect_lookup.py --id <stamp_id>   # single stamp
    .venv/bin/python tools/colnect_lookup.py --dry-run    # show queries, don't write
"""
from __future__ import annotations

import argparse
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

# Colnect's API path format:
#   https://api.colnect.net/{lang}/api/{API_KEY}/{endpoint}
# Endpoints (from community forum posts and public examples):
#   /countries/{category}                    → list all countries for category
#   /years/{category}/{country_id}           → valid years for country
#   /list/{category}/country/{country_id}    → paginated list of items
#   /item/{category}/{item_id}               → full item detail
# Category for stamps is "stamps".
COLNECT_API_BASE = "https://api.colnect.net"
COLNECT_LANG = "en"
CATEGORY = "stamps"

# Rate limiting — Colnect asks nicely, we throttle to 1 req/sec by default.
REQUEST_INTERVAL_SEC = 1.0

log = logging.getLogger("colnect_lookup")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


def _api_key() -> str | None:
    return os.environ.get("COLNECT_API_KEY")


def _api_secret() -> str | None:
    """Separate secret for the HMAC signature. Colnect issues both a key
    (goes in URL path) and a secret (used to sign requests). If the user
    only has one credential, we try signing with the key itself as a
    fallback — some APIs work that way."""
    return os.environ.get("COLNECT_API_SECRET") or os.environ.get("COLNECT_API_KEY")


class ColnectClient:
    """Colnect CAPI client with HMAC-SHA256 request signing.

    Auth model per colnect.com/en/help/collecting/colnect_api:
      - URL path includes {API_KEY}
      - Each request sends Capi-Timestamp (Unix seconds) + Capi-Hash headers
      - Capi-Hash is an HMAC computed over the canonical request string
        using your secret

    The exact canonical-string format is in the downloadable API Spec
    (only available after key issuance). We default to HMAC-SHA256 over
    "{timestamp}{path}" — the most common recipe. If the spec differs,
    override `_compute_hash` accordingly.
    """

    def __init__(self, api_key: str, api_secret: str):
        self.api_key = api_key
        self.api_secret = api_secret
        self.session = requests.Session()
        self._last_call = 0.0

    def _throttle(self):
        elapsed = time.time() - self._last_call
        if elapsed < REQUEST_INTERVAL_SEC:
            time.sleep(REQUEST_INTERVAL_SEC - elapsed)
        self._last_call = time.time()

    def _compute_hash(self, timestamp: str, path: str) -> str:
        """HMAC-SHA256(secret, timestamp + path) → hex. Adjust to match
        the exact recipe in your Colnect API Spec if they differ."""
        import hmac, hashlib
        msg = f"{timestamp}{path}".encode()
        return hmac.new(self.api_secret.encode(), msg, hashlib.sha256).hexdigest()

    def _get(self, endpoint: str) -> object | None:
        self._throttle()
        path = f"/{COLNECT_LANG}/api/{self.api_key}/{endpoint}"
        url = f"{COLNECT_API_BASE}{path}"
        timestamp = str(int(time.time()))
        headers = {
            "Capi-Timestamp": timestamp,
            "Capi-Hash": self._compute_hash(timestamp, path),
        }
        try:
            r = self.session.get(url, timeout=15, headers=headers)
            if r.status_code == 404:
                return None
            if r.status_code == 401 or r.status_code == 403:
                log.error("Colnect auth rejected (%s): check COLNECT_API_SECRET "
                          "and _compute_hash() matches the API spec. Response: %s",
                          r.status_code, r.text[:200])
                return None
            if r.status_code != 200:
                log.warning("Colnect %s returned %s", endpoint, r.status_code)
                return None
            return r.json()
        except Exception as e:
            log.warning("Colnect %s failed: %s", endpoint, e)
            return None

    # Cache frequently-used reference data in memory.
    _countries_cache: dict | None = None

    def country_id(self, country_name: str) -> int | None:
        """Look up Colnect's numeric country_id by name (case-insensitive,
        with some common aliasing)."""
        if self._countries_cache is None:
            data = self._get(f"countries/{CATEGORY}")
            if not isinstance(data, list):
                return None
            # Response shape (expected): [[id, name, code, …], …]
            self._countries_cache = {}
            for row in data:
                if not isinstance(row, list) or len(row) < 2:
                    continue
                cid, name = row[0], str(row[1])
                self._countries_cache[name.lower()] = cid
        q = country_name.strip().lower()
        aliases = {
            "usa": "united states", "us": "united states",
            "u.s.": "united states", "u.s.a.": "united states",
            "great britain": "united kingdom", "britain": "united kingdom",
            "ussr": "soviet union", "deutschland": "germany",
        }
        q = aliases.get(q, q)
        return self._countries_cache.get(q)

    def search_stamp(self, country_id: int, year: int | None,
                      denomination: str | None, subject: str | None) -> list:
        """Return candidate stamp items. The Colnect API's exact search
        shape is key-dependent; we use the item-list endpoint and filter
        client-side since that's guaranteed to work with any key tier."""
        # Try year-scoped list first (cheaper).
        candidates = []
        if year is not None:
            data = self._get(
                f"list/{CATEGORY}/country/{country_id}/year/{year}")
            if isinstance(data, list):
                candidates = data
        if not candidates:
            data = self._get(f"list/{CATEGORY}/country/{country_id}")
            if isinstance(data, list):
                candidates = data

        # Response row shape (expected): [id, name, year, face_value, …]
        # Filter by denomination + subject text match. Conservative — we'd
        # rather return nothing than a wrong match.
        scored = []
        denom = (denomination or "").lower().replace(" ", "")
        subj = (subject or "").lower()
        for row in candidates:
            if not isinstance(row, list) or len(row) < 4:
                continue
            row_face = str(row[3] if len(row) > 3 else "").lower().replace(" ", "")
            row_name = str(row[1] if len(row) > 1 else "").lower()
            score = 0
            if denom and denom in row_face:
                score += 2
            if subj and any(w for w in subj.split() if len(w) > 3 and w in row_name):
                score += 1
            if score > 0:
                scored.append((score, row))
        scored.sort(key=lambda x: -x[0])
        return [row for _, row in scored[:5]]

    def item(self, item_id: int) -> dict | None:
        data = self._get(f"item/{CATEGORY}/{item_id}")
        # Response: a single list/dict describing the item.
        if isinstance(data, list) and data:
            return {"raw": data}
        if isinstance(data, dict):
            return data
        return None


def lookup_and_update(conn: sqlite3.Connection, client: ColnectClient,
                       row: dict, dry_run: bool) -> bool:
    """Returns True if we matched and (would have) updated the row."""
    country = row["country"]
    year = row["year"]
    denomination = row["denomination"]
    subject = row["subject"]

    if not country:
        log.info("  %s: skip (no country)", row["id"]); return False

    cid = client.country_id(country)
    if cid is None:
        log.info("  %s: unknown country '%s'", row["id"], country); return False

    candidates = client.search_stamp(cid, year, denomination, subject)
    if not candidates:
        log.info("  %s: no Colnect match", row["id"]); return False

    best = candidates[0]
    # Row shape from list endpoint: [id, name, year, face_value, …]
    catalogue_ref = f"Colnect {best[0]}"
    log.info("  %s: → %s (%s)", row["id"], catalogue_ref,
             str(best[1]) if len(best) > 1 else "?")

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
    ap.add_argument("--id", help="only process this stamp id")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = _api_key()
    secret = _api_secret()
    if not key:
        log.error("COLNECT_API_KEY not set. Add to .env.local:")
        log.error("    COLNECT_API_KEY=your_key_here")
        log.error("    COLNECT_API_SECRET=your_secret_here  # if issued separately")
        log.error("Apply: https://colnect.com/en/help/collecting/colnect_api")
        sys.exit(1)

    if not DB_PATH.exists():
        log.error("DB not found at %s", DB_PATH); sys.exit(1)

    conn = sqlite3.connect(str(DB_PATH), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=3000")

    # Pick stamps that have been VLM-identified (country set) but haven't
    # been matched to Colnect yet.
    if args.id:
        rows = conn.execute(
            "SELECT id, country, year, denomination, subject FROM stamps WHERE id = ?",
            (args.id,)).fetchall()
    else:
        rows = conn.execute("""
            SELECT id, country, year, denomination, subject
            FROM stamps
            WHERE country IS NOT NULL AND catalogueRef IS NULL
        """).fetchall()

    if not rows:
        log.info("nothing to match"); return

    log.info("matching %d stamp(s) via Colnect%s",
             len(rows), " (dry run)" if args.dry_run else "")
    client = ColnectClient(key, secret)
    matched = 0
    for row in rows:
        if lookup_and_update(conn, client, dict(row), args.dry_run):
            matched += 1

    log.info("done: %d/%d matched", matched, len(rows))
    conn.close()


if __name__ == "__main__":
    main()
