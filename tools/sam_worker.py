"""SAM 3 worker — watches .run/sam_inbox/ for images, runs SAM 3
segmentation, deduplicates via perceptual hash, and writes directly
into ~/Library/Application Support/StampScanner/library.sqlite.

The Swift Mac app simply observes the DB via GRDB's @Query — zero
ingest logic on the Swift side.

Run:
    .venv/bin/python tools/sam_worker.py --daemon
    .venv/bin/python tools/sam_worker.py --one-shot
"""
from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import shutil
import signal
import sqlite3
import sys
import time
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN = ROOT / ".run"
INBOX = RUN / "sam_inbox"
INBOX_PROCESSING = RUN / "sam_processing"
OUTBOX = RUN / "sam_outbox"
LOG_PATH = RUN / "sam_worker.log"
PID_PATH = RUN / "sam_worker.pid"
HEARTBEAT_PATH = RUN / "sam_worker.heartbeat"

def _resolve_app_support() -> Path:
    """Resolve the library root. STAMP_APP_SUPPORT overrides the default
    so tests can point at a scratch directory without polluting prod."""
    env = os.environ.get("STAMP_APP_SUPPORT")
    if env:
        return Path(env)
    return Path.home() / "Library" / "Application Support" / "StampScanner"

APP_SUPPORT = _resolve_app_support()
DB_PATH = APP_SUPPORT / "library.sqlite"
CAPTURES_DIR = APP_SUPPORT / "captures"
SOURCES_DIR = CAPTURES_DIR / "_sources"

DEFAULT_MODEL = str(ROOT / "sam3.pt")
DEFAULT_PROMPT = "perforated postage stamp"
DEFAULT_NEGATIVES = ["envelope", "printed text", "paper fragment"]
DEFAULT_CONF = 0.5
DEFAULT_IOU = 0.6
POLL_SEC = 0.25
HEARTBEAT_SEC = 2.0
MAX_HAMMING = 6

log = logging.getLogger("sam_worker")


# ---------- DB ----------

def ensure_db() -> sqlite3.Connection:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    CAPTURES_DIR.mkdir(parents=True, exist_ok=True)
    SOURCES_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), timeout=5.0)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=3000")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS stamps (
            id TEXT PRIMARY KEY NOT NULL,
            capturedAt DATETIME NOT NULL,
            cropPath TEXT NOT NULL,
            sourceFramePath TEXT,
            confidence REAL NOT NULL,
            cropW INTEGER NOT NULL,
            cropH INTEGER NOT NULL,
            quadFlat TEXT NOT NULL,
            country TEXT,
            year INTEGER,
            denomination TEXT,
            notes TEXT,
            colour TEXT,
            subject TEXT,
            series TEXT,
            used INTEGER,
            cancelType TEXT,
            printing TEXT,
            overprint TEXT,
            description TEXT,
            perfGauge TEXT,
            watermark TEXT,
            gum TEXT,
            condition TEXT,
            catalogueRef TEXT,
            flagged INTEGER NOT NULL DEFAULT 0,
            jobId TEXT NOT NULL DEFAULT '',
            perceptualHash INTEGER,
            oriented INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_stamps_capturedAt ON stamps(capturedAt)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_stamps_jobId ON stamps(jobId)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_stamps_flagged ON stamps(flagged)")
    conn.commit()
    return conn


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def phash_int(pil_img) -> int:
    """64-bit perceptual hash as a signed int64 (SQLite-compatible)."""
    import imagehash
    h = imagehash.phash(pil_img, hash_size=8)
    val = int(str(h), 16)
    if val >= (1 << 63):
        val -= (1 << 64)
    return val


def hamming(a: int, b: int) -> int:
    return bin((a & 0xFFFFFFFFFFFFFFFF) ^ (b & 0xFFFFFFFFFFFFFFFF)).count("1")


def find_duplicate(conn: sqlite3.Connection, phash: int, quality: float):
    """Returns (action, existing_row_or_None).
    action: 'unique' | 'better' | 'worse'
    """
    rows = conn.execute(
        "SELECT id, confidence, cropW, cropH, perceptualHash, cropPath "
        "FROM stamps WHERE perceptualHash IS NOT NULL"
    ).fetchall()
    for row in rows:
        existing_hash = row[4]
        if hamming(phash, existing_hash) <= MAX_HAMMING:
            existing_quality = row[1] * row[2] * row[3]
            if quality > existing_quality:
                return "better", row
            else:
                return "worse", row
    return "unique", None


def white_balance(rgb):
    """Auto white-balance by sampling the border pixels (stamp paper /
    perforations). Assumes the border should be near-white. Takes the
    top 5% brightest border pixels as the white reference, then scales
    each channel so that reference maps to 255."""
    import numpy as np
    h, w = rgb.shape[:2]
    border_width = max(3, min(h, w) // 15)
    # Collect border pixels: top, bottom, left, right strips.
    strips = [
        rgb[:border_width, :],         # top
        rgb[-border_width:, :],        # bottom
        rgb[:, :border_width],         # left
        rgb[:, -border_width:],        # right
    ]
    border = np.concatenate([s.reshape(-1, 3) for s in strips], axis=0).astype(np.float32)
    # Use the brightest pixels (top 5% by luminance) as the white ref.
    luma = 0.299 * border[:, 0] + 0.587 * border[:, 1] + 0.114 * border[:, 2]
    threshold = np.percentile(luma, 95)
    bright = border[luma >= threshold]
    if len(bright) < 10:
        return rgb
    ref = bright.mean(axis=0)
    # Only correct if the reference is reasonably bright (>100 per channel)
    # — a dark border (e.g. black-bordered stamps) shouldn't be whitened.
    if ref.min() < 100:
        return rgb
    scale = np.clip(245.0 / ref, 0.8, 1.5)
    corrected = np.clip(rgb.astype(np.float32) * scale, 0, 255).astype(np.uint8)
    return corrected


    # Orientation is handled by a separate worker (orientation_worker.py)
    # so SAM and Gemma 4 never compete for GPU memory.


def ingest_stamp(conn: sqlite3.Connection, *,
                  stamp_id: str, job_id: str, crop_rgb, quad,
                  conf: float, bbox, source_frame_data: bytes | None,
                  pil_img) -> str | None:
    """Save a single stamp crop to disk + DB. Returns the record ID if
    saved, None if skipped as a lower-quality duplicate."""
    from PIL import Image
    import numpy as np

    crop_pil = Image.fromarray(crop_rgb)
    phash = phash_int(crop_pil)
    quality = conf * crop_rgb.shape[1] * crop_rgb.shape[0]

    action, existing = find_duplicate(conn, phash, quality)
    if action == "worse":
        log.info("  %s: skip (dup of %s, lower quality)", stamp_id, existing[0])
        return None
    if action == "better":
        old_id = existing[0]
        old_crop = existing[5]
        log.info("  %s: replacing %s (higher quality)", stamp_id, old_id)
        old_dir = CAPTURES_DIR / old_id
        if old_dir.exists():
            shutil.rmtree(old_dir, ignore_errors=True)
        conn.execute("DELETE FROM stamps WHERE id = ?", (old_id,))

    # Write crop to disk.
    stamp_dir = CAPTURES_DIR / stamp_id
    stamp_dir.mkdir(parents=True, exist_ok=True)
    crop_path = stamp_dir / "crop.png"
    crop_pil.save(crop_path)

    # Shared source frame (one per job).
    source_rel = None
    if source_frame_data is not None:
        src_file = SOURCES_DIR / f"{job_id}.jpg"
        if not src_file.exists():
            src_file.write_bytes(source_frame_data)
        source_rel = f"_sources/{job_id}.jpg"

    quad_json = json.dumps(
        [coord for pt in quad for coord in pt] if quad else []
    )
    conn.execute("""
        INSERT OR REPLACE INTO stamps
        (id, capturedAt, cropPath, sourceFramePath, confidence,
         cropW, cropH, quadFlat, flagged, jobId, perceptualHash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
    """, (
        stamp_id, now_iso(), f"{stamp_id}/crop.png", source_rel,
        conf, crop_rgb.shape[1], crop_rgb.shape[0],
        quad_json, job_id, phash,
    ))
    conn.commit()
    return stamp_id


# ---------- Logging ----------

def setup_logging() -> None:
    RUN.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(LOG_PATH, maxBytes=10_000_000, backupCount=3)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    handler.setFormatter(fmt)
    log.addHandler(handler)
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(fmt)
    log.addHandler(stream)
    log.setLevel(logging.INFO)


# ---------- SAM 3 ----------

_predictor = None


def load_predictor(model_path: str, conf: float, iou: float):
    global _predictor
    if _predictor is not None:
        return _predictor
    if not Path(model_path).exists():
        raise SystemExit(
            f"SAM 3 weights missing at {model_path}. Download via:\n"
            f"  HF_TOKEN=<your_token> .venv/bin/hf download facebook/sam3 "
            f"--include '*.pt' --local-dir {ROOT}"
        )
    import logging as _lg
    _lg.getLogger("ultralytics").setLevel(_lg.ERROR)
    from ultralytics.models.sam import SAM3SemanticPredictor
    log.info("loading SAM 3 weights from %s", model_path)
    _predictor = SAM3SemanticPredictor(overrides=dict(
        conf=conf, iou=iou, task="segment", mode="predict",
        model=model_path, half=False, save=False, verbose=False,
        device="mps", imgsz=644,
    ))
    return _predictor


def filter_and_dedup(raw, img_w: int, img_h: int):
    import numpy as np
    from scipy.ndimage import binary_fill_holes, binary_closing
    frame = img_w * img_h
    cands = []
    for item in raw:
        mask = item["mask"]
        filled = binary_fill_holes(binary_closing(mask, iterations=2))
        ys, xs = np.where(filled)
        if len(xs) == 0:
            continue
        x0, x1 = int(xs.min()), int(xs.max())
        y0, y1 = int(ys.min()), int(ys.max())
        w = x1 - x0 + 1
        h = y1 - y0 + 1
        area = int(filled.sum())
        density = area / max(w * h, 1)
        short, long_ = min(w, h), max(w, h)
        aspect = short / max(long_, 1)
        frac = area / frame
        if aspect < 0.30 or density < 0.45 or frac < 0.003 or frac > 0.95:
            continue
        cands.append({
            "mask": filled, "x0": x0, "y0": y0, "x1": x1, "y1": y1,
            "area": area, "aspect": aspect, "density": density,
            "conf": float(item["conf"]),
        })
    cands.sort(key=lambda c: c["area"])
    kept: list = []
    for c in cands:
        drop_c = False
        to_drop_kept: list[int] = []
        for i, k in enumerate(kept):
            ix = max(0, min(c["x1"], k["x1"]) - max(c["x0"], k["x0"]) + 1)
            iy = max(0, min(c["y1"], k["y1"]) - max(c["y0"], k["y0"]) + 1)
            inter = ix * iy
            if inter == 0:
                continue
            contains_c_in_k = inter / c["area"] > 0.80
            contains_k_in_c = inter / k["area"] > 0.80
            iou = inter / (c["area"] + k["area"] - inter)
            if contains_c_in_k and c["area"] < k["area"] * 0.60:
                drop_c = True; break
            if contains_k_in_c and k["area"] < c["area"] * 0.66:
                drop_c = True; break
            if iou > 0.55:
                c_score = c["density"] + c["aspect"] + c["conf"]
                k_score = k["density"] + k["aspect"] + k["conf"]
                if c_score > k_score:
                    to_drop_kept.append(i)
                else:
                    drop_c = True; break
        if not drop_c:
            for i in sorted(to_drop_kept, reverse=True):
                kept.pop(i)
            kept.append(c)
    return kept


def warp_stamp(pil, mask, pad_pct: float = 0.08):
    import cv2
    import numpy as np
    m8 = (mask.astype("uint8") * 255)
    contours, _ = cv2.findContours(m8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None, None
    cnt = max(contours, key=cv2.contourArea)
    rect = cv2.minAreaRect(cnt)
    box = cv2.boxPoints(rect).astype("float32")
    s = box.sum(axis=1); d = np.diff(box, axis=1).ravel()
    ordered = np.array([
        box[np.argmin(s)], box[np.argmin(d)],
        box[np.argmax(s)], box[np.argmax(d)],
    ], dtype="float32")
    cx, cy = ordered.mean(axis=0)
    pad = 1.0 + pad_pct
    padded = np.array([[cx + (p[0] - cx) * pad, cy + (p[1] - cy) * pad]
                       for p in ordered], dtype="float32")
    side_a = float(np.linalg.norm(padded[1] - padded[0]))
    side_b = float(np.linalg.norm(padded[3] - padded[0]))
    dst_w = int(round(max(side_a, 60)))
    dst_h = int(round(max(side_b, 60)))
    if dst_w > dst_h * 1.05:
        padded = np.roll(padded, -1, axis=0)
        dst_w, dst_h = dst_h, dst_w
    dst = np.array([[0, 0], [dst_w - 1, 0],
                    [dst_w - 1, dst_h - 1], [0, dst_h - 1]], dtype="float32")
    M = cv2.getPerspectiveTransform(padded, dst)
    src_bgr = cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)
    warped = cv2.warpPerspective(src_bgr, M, (dst_w, dst_h),
                                  flags=cv2.INTER_LINEAR,
                                  borderMode=cv2.BORDER_REPLICATE)
    rgb = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    return rgb, padded.tolist()


# ---------- Process ----------

def process(job_path: Path, args, conn: sqlite3.Connection,
            real_stem: str | None = None) -> int:
    from PIL import Image, ImageFile
    ImageFile.LOAD_TRUNCATED_IMAGES = True
    try:
        from pillow_heif import register_heif_opener
        register_heif_opener()
    except ImportError:
        pass
    import numpy as np

    job_id = real_stem if real_stem is not None else job_path.stem
    t0 = time.time()

    sidecar = INBOX / f"{job_id}.json"
    prompt = args.prompt
    conf = args.conf
    if sidecar.exists():
        try:
            over = json.loads(sidecar.read_text())
            prompt = over.get("prompt", prompt)
            conf = float(over.get("conf", conf))
        except Exception as e:
            log.warning("bad sidecar %s: %s", sidecar, e)

    try:
        pil = Image.open(job_path).convert("RGB")
    except Exception as e:
        log.error("job %s: can't open image: %s", job_id, e)
        sidecar.unlink(missing_ok=True)
        return 0

    # Convert HEIC → temp JPEG for SAM (Ultralytics uses OpenCV which
    # doesn't support HEIC).
    feed_path = job_path
    tmp_jpg: Path | None = None
    if job_path.suffix.lower() in (".heic", ".heif"):
        tmp_jpg = job_path.with_suffix(".jpg")
        pil.save(tmp_jpg, "JPEG", quality=95)
        feed_path = tmp_jpg

    # Save source frame as JPEG bytes for the library.
    import io
    source_buf = io.BytesIO()
    pil.save(source_buf, "JPEG", quality=90)
    source_bytes = source_buf.getvalue()

    saved = 0
    try:
        predictor = load_predictor(args.model, conf, args.iou)
        predictor.set_image(str(feed_path))
        classes = [prompt] + args.negatives
        results = predictor(text=classes)
        r0 = results[0] if results else None

        raw = []
        if r0 is not None and r0.masks is not None and r0.boxes is not None:
            cls_arr = r0.boxes.cls.cpu().numpy()
            conf_arr = r0.boxes.conf.cpu().numpy()
            for i, m in enumerate(r0.masks.data):
                if int(cls_arr[i]) != 0:
                    continue
                raw.append({
                    "mask": m.cpu().numpy().astype(bool),
                    "conf": float(conf_arr[i]),
                })
        kept = filter_and_dedup(raw, pil.width, pil.height)

        for idx, c in enumerate(kept):
            rgb, quad = warp_stamp(pil, c["mask"])
            if rgb is None:
                continue
            rgb = white_balance(rgb)
            stamp_id = f"{job_id}-{idx}"
            result = ingest_stamp(
                conn,
                stamp_id=stamp_id,
                job_id=job_id,
                crop_rgb=rgb,
                quad=quad,
                conf=c["conf"],
                bbox=[c["x0"], c["y0"], c["x1"] - c["x0"] + 1, c["y1"] - c["y0"] + 1],
                source_frame_data=source_bytes,
                pil_img=pil,
            )
            if result:
                saved += 1

        dt = int((time.time() - t0) * 1000)
        log.info("job %s: %d/%d stamps saved in %dms", job_id, saved, len(kept), dt)
    except Exception as e:
        log.exception("job %s failed", job_id)
    finally:
        if tmp_jpg is not None:
            tmp_jpg.unlink(missing_ok=True)
        sidecar.unlink(missing_ok=True)
    return saved


def touch_heartbeat() -> None:
    HEARTBEAT_PATH.touch()


def drain(args, conn: sqlite3.Connection) -> int:
    n = 0
    INBOX_PROCESSING.mkdir(parents=True, exist_ok=True)
    for ext in ("*.jpg", "*.png", "*.jpeg", "*.heic", "*.heif"):
        for p in sorted(INBOX.glob(ext)):
            if p.name.endswith(".tmp"):
                continue
            claimed = INBOX_PROCESSING / p.name
            try:
                os.rename(p, claimed)
            except FileNotFoundError:
                continue
            try:
                process(claimed, args, conn, real_stem=p.stem)
            finally:
                claimed.unlink(missing_ok=True)
            n += 1
    return n


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--daemon", action="store_true", help="watch + loop")
    ap.add_argument("--one-shot", action="store_true", help="drain + exit")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--negatives", nargs="*", default=DEFAULT_NEGATIVES)
    ap.add_argument("--conf", type=float, default=DEFAULT_CONF)
    ap.add_argument("--iou", type=float, default=DEFAULT_IOU)
    args = ap.parse_args()

    setup_logging()
    INBOX.mkdir(parents=True, exist_ok=True)
    INBOX_PROCESSING.mkdir(parents=True, exist_ok=True)
    OUTBOX.mkdir(parents=True, exist_ok=True)

    pid_fd = os.open(str(PID_PATH), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(pid_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        existing = ""
        try:
            with open(PID_PATH) as f: existing = f.read().strip()
        except Exception:
            pass
        print(f"[sam_worker] another instance is running (pid {existing}), exiting",
              file=sys.stderr)
        sys.exit(0)
    os.ftruncate(pid_fd, 0)
    os.write(pid_fd, str(os.getpid()).encode())

    for stuck in INBOX_PROCESSING.iterdir():
        try:
            os.rename(stuck, INBOX / stuck.name)
        except OSError:
            pass

    conn = ensure_db()

    stop = {"now": False}
    def _stop(_sig, _frm):
        stop["now"] = True
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        if args.one_shot:
            drain(args, conn)
            return
        load_predictor(args.model, args.conf, args.iou)
        log.info("worker ready, watching %s", INBOX)
        last_hb = 0.0
        while not stop["now"]:
            drain(args, conn)
            now = time.time()
            if now - last_hb > HEARTBEAT_SEC:
                touch_heartbeat()
                last_hb = now
            time.sleep(POLL_SEC)
    finally:
        conn.close()
        try:
            fcntl.flock(pid_fd, fcntl.LOCK_UN)
            os.close(pid_fd)
        except Exception:
            pass
        PID_PATH.unlink(missing_ok=True)
        log.info("worker exiting")


if __name__ == "__main__":
    main()
