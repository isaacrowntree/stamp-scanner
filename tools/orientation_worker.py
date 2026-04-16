"""VLM pass — on-demand orientation fix + stamp identification via Qwen3-VL.

Called from the Swift UI toolbar button. Processes all rows where
oriented=0, sending each crop to Qwen3-VL via Ollama for:
  1. Rotation detection (0/90/180/270)
  2. Stamp identification (country, year, denomination, colour, subject,
     series, used/mint, cancel type, printing method, overprints)

Single VLM call per task per stamp. Unloads the model when done so SAM
can reclaim GPU memory.

Usage:
    .venv/bin/python tools/orientation_worker.py              # both passes
    .venv/bin/python tools/orientation_worker.py --orient-only
    .venv/bin/python tools/orientation_worker.py --id-only
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import logging
import os
import sqlite3
import sys
import time
from pathlib import Path

import requests
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP_SUPPORT = Path(os.environ.get(
    "STAMP_APP_SUPPORT",
    str(Path.home() / "Library" / "Application Support" / "StampScanner")
))
DB_PATH = APP_SUPPORT / "library.sqlite"
CAPTURES_DIR = APP_SUPPORT / "captures"

OLLAMA_URL = "http://localhost:11434"
MODEL = "qwen3-vl"

log = logging.getLogger("vlm_pass")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


def warm_model() -> bool:
    try:
        log.info("loading %s...", MODEL)
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL, "prompt": "hi",
            "stream": False, "keep_alive": "30m",
        }, timeout=120)
        log.info("model warm")
        return r.status_code == 200
    except Exception as e:
        log.error("ollama not reachable: %s", e)
        return False


def unload_model():
    try:
        requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL, "prompt": "",
            "stream": False, "keep_alive": "0",
        }, timeout=10)
    except Exception:
        pass


def vlm_query(crop_path: Path, prompt: str, *,
              max_side: int = 384, num_predict: int = 2048,
              retries: int = 1) -> str:
    """Send a crop + prompt to Ollama. `max_side` controls vision encoder
    cost. Use num_predict=-1 or a large number (>=1024) — Qwen3-VL returns
    empty output when num_predict is small or temperature is 0 (observed
    Ollama quirk, likely sampling-related)."""
    img = Image.open(crop_path).convert("RGB")
    img.thumbnail((max_side, max_side), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=80)
    b64 = base64.b64encode(buf.getvalue()).decode()

    # NOTE: Qwen3-VL via Ollama returns empty output when temperature=0
    # (reproducible on multiple models). Use the default temperature and
    # rely on num_predict alone to cap generation.
    body = {
        "model": MODEL,
        "prompt": prompt,
        "images": [b64],
        "stream": False,
        "keep_alive": "30m",
        "options": {"num_predict": num_predict},
    }

    for attempt in range(retries + 1):
        try:
            resp = requests.post(f"{OLLAMA_URL}/api/generate", json=body,
                                  timeout=180)
            if resp.status_code == 200:
                return resp.json().get("response", "").strip()
        except requests.exceptions.Timeout:
            if attempt < retries:
                log.warning("    timeout, retrying...")
                continue
            log.warning("    timeout after %d attempts", retries + 1)
            return ""
        except Exception as e:
            log.warning("    request failed: %s", e)
            return ""
    return ""


# ---------- Orientation ----------

def detect_rotation(crop_path: Path) -> int:
    """DEPRECATED — orientation is now handled via manual rotation buttons
    in the Mac UI. VLM-based orientation was too slow/unreliable on local
    hardware. Kept for reference and CLI --orient-only usage."""
    text = vlm_query(
        crop_path,
        "What rotation in degrees clockwise makes this stamp upright? "
        "Answer ONLY: 0, 90, 180, or 270",
    )
    for token in text.replace(",", " ").replace(".", " ").split():
        token = token.strip("°*")
        if token in ("0", "90", "180", "270"):
            return int(token)
    return 0


def apply_rotation(crop_path: Path, angle: int) -> None:
    img = Image.open(crop_path)
    rotated = img.rotate(-angle, expand=True)
    rotated.save(crop_path)


def process_orientation(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        "SELECT id, cropPath FROM stamps WHERE oriented = 0"
    ).fetchall()
    if not rows:
        log.info("no unoriented stamps")
        return 0

    log.info("orienting %d stamp(s)...", len(rows))
    fixed = 0
    for stamp_id, crop_rel in rows:
        crop_path = CAPTURES_DIR / crop_rel
        if not crop_path.exists():
            conn.execute("UPDATE stamps SET oriented=1 WHERE id=?", (stamp_id,))
            conn.commit()
            continue
        t0 = time.time()
        angle = detect_rotation(crop_path)
        dt = time.time() - t0
        if angle != 0:
            apply_rotation(crop_path, angle)
            log.info("  %s: rotated %d° (%.1fs)", stamp_id, angle, dt)
            fixed += 1
        else:
            log.info("  %s: ok (%.1fs)", stamp_id, dt)
        conn.execute("UPDATE stamps SET oriented=1 WHERE id=?", (stamp_id,))
        conn.commit()
    return fixed


# ---------- Identification ----------

IDENTIFY_PROMPT = (
    'Identify this postage stamp. Reply ONLY as JSON:\n'
    '{"country":"...","year":NNNN,"denomination":"...",'
    '"colour":"...","subject":"...","series":"...",'
    '"used":true/false,"cancel_type":"CDS/machine/pen/null",'
    '"printing":"engraved/lithograph/photogravure/offset/...",'
    '"overprint":"text or null","description":"brief free text"}'
)


def _int_or_none(v):
    if v is None:
        return None
    try:
        return int(v)
    except (ValueError, TypeError):
        return None


def _str_or_none(v):
    if v is None or v == "null" or v == "":
        return None
    return str(v).strip()


def _bool_or_none(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v.lower() in ("true", "yes", "1")
    return bool(v)


VLM_FIELDS = [
    ("country", _str_or_none),
    ("year", _int_or_none),
    ("denomination", _str_or_none),
    ("colour", _str_or_none),
    ("subject", _str_or_none),
    ("series", _str_or_none),
    ("used", _bool_or_none),
    ("cancel_type", _str_or_none),
    ("printing", _str_or_none),
    ("overprint", _str_or_none),
    ("description", _str_or_none),
]

# Map JSON keys to DB column names (cancel_type → cancelType).
JSON_TO_COL = {
    "country": "country",
    "year": "year",
    "denomination": "denomination",
    "colour": "colour",
    "subject": "subject",
    "series": "series",
    "used": "used",
    "cancel_type": "cancelType",
    "printing": "printing",
    "overprint": "overprint",
    "description": "description",
}


def identify_stamp(crop_path: Path) -> dict:
    text = vlm_query(crop_path, IDENTIFY_PROMPT)
    try:
        start = text.index("{")
        end = text.rindex("}") + 1
        data = json.loads(text[start:end])
        result = {}
        for json_key, converter in VLM_FIELDS:
            col = JSON_TO_COL[json_key]
            val = converter(data.get(json_key))
            if val is not None:
                result[col] = val
        return result
    except (ValueError, json.JSONDecodeError) as e:
        log.warning("JSON parse failed: %s — raw: %s", e, text[:200])
        return {}


def process_identification(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        "SELECT id, cropPath FROM stamps WHERE country IS NULL AND year IS NULL"
    ).fetchall()
    if not rows:
        log.info("no unidentified stamps")
        return 0

    log.info("identifying %d stamp(s)...", len(rows))
    identified = 0
    for stamp_id, crop_rel in rows:
        crop_path = CAPTURES_DIR / crop_rel
        if not crop_path.exists():
            continue
        t0 = time.time()
        meta = identify_stamp(crop_path)
        dt = time.time() - t0
        if meta:
            sets = []
            params = []
            for col, val in meta.items():
                sets.append(f"{col} = ?")
                params.append(val)
            if sets:
                params.append(stamp_id)
                conn.execute(
                    f"UPDATE stamps SET {', '.join(sets)} WHERE id = ?",
                    params)
                conn.commit()
                identified += 1
            log.info("  %s: %s %s %s (%.1fs)", stamp_id,
                     meta.get("country", "?"),
                     meta.get("year", ""),
                     meta.get("denomination", ""), dt)
        else:
            log.info("  %s: no ID (%.1fs)", stamp_id, dt)
    return identified


# ---------- Main ----------

def ensure_columns(conn: sqlite3.Connection):
    """Add any missing columns so the worker is resilient to schema drift."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(stamps)").fetchall()}
    additions = [
        ("colour", "TEXT"), ("subject", "TEXT"), ("series", "TEXT"),
        ("used", "INTEGER"), ("cancelType", "TEXT"), ("printing", "TEXT"),
        ("overprint", "TEXT"), ("description", "TEXT"),
        ("perfGauge", "TEXT"), ("watermark", "TEXT"), ("gum", "TEXT"),
        ("condition", "TEXT"), ("catalogueRef", "TEXT"),
        ("oriented", "INTEGER NOT NULL DEFAULT 0"),
    ]
    for name, typedef in additions:
        if name not in cols:
            try:
                conn.execute(f"ALTER TABLE stamps ADD COLUMN {name} {typedef}")
            except sqlite3.OperationalError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orient-only", action="store_true")
    ap.add_argument("--id-only", action="store_true")
    args = ap.parse_args()

    if not DB_PATH.exists():
        log.error("DB not found at %s", DB_PATH)
        sys.exit(1)

    conn = sqlite3.connect(str(DB_PATH), timeout=5.0)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=3000")
    ensure_columns(conn)

    if not warm_model():
        sys.exit(1)

    try:
        if not args.id_only:
            fixed = process_orientation(conn)
            log.info("orientation: %d fixed", fixed)
        if not args.orient_only:
            identified = process_identification(conn)
            log.info("identification: %d identified", identified)
    finally:
        conn.close()
        unload_model()
        log.info("done, model unloaded")


if __name__ == "__main__":
    main()
