#!/usr/bin/env bash
# End-to-end pipeline test against bundled fixtures. Uses a scratch
# STAMP_APP_SUPPORT so it never touches the real prod library.
#
# Usage:
#   tools/run_fixture_pipeline.sh            # SAM only (fast)
#   tools/run_fixture_pipeline.sh --identify # also run VLM identification
#   tools/run_fixture_pipeline.sh --keep     # don't delete the scratch dir
set -e
cd "$(dirname "$0")/.."

SCRATCH="$(mktemp -d -t stamp-fixture-XXXXXX)"
export STAMP_APP_SUPPORT="$SCRATCH"

IDENTIFY=""
KEEP=""
for arg in "$@"; do
  case "$arg" in
    --identify) IDENTIFY=1 ;;
    --keep)     KEEP=1 ;;
  esac
done

cleanup() {
  if [ -z "$KEEP" ]; then
    rm -rf "$SCRATCH"
  else
    echo ""
    echo "scratch kept: $SCRATCH"
  fi
}
trap cleanup EXIT

echo "[fixture] scratch dir: $SCRATCH"
echo

# Fresh inbox for the worker
pkill -f sam_worker 2>/dev/null || true
rm -f .run/sam_worker.pid
rm -rf .run/sam_inbox/* .run/sam_processing/* .run/sam_outbox/* 2>/dev/null || true

for f in mac-app/Tests/StampScannerTests/Fixtures/*.{jpg,jpeg,png}; do
  [ -f "$f" ] || continue
  cp "$f" ".run/sam_inbox/fx_$(basename "$f")"
done

echo "[fixture] running SAM worker..."
.venv/bin/python tools/sam_worker.py --one-shot 2>&1 | grep -E "INFO job|INFO  "

echo
echo "[fixture] DB contents:"
.venv/bin/python -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['STAMP_APP_SUPPORT'] + '/library.sqlite')
n = conn.execute('SELECT COUNT(*) FROM stamps').fetchone()[0]
print(f'  {n} stamps')
"

if [ -n "$IDENTIFY" ]; then
  echo
  echo "[fixture] running Qwen3-VL identification..."
  .venv/bin/python tools/orientation_worker.py --id-only 2>&1 | grep -E "INFO|WARN" | tail -40
fi
