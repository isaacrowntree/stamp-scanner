#!/usr/bin/env bash
# Launch the v2 stack. See .run/CONTRACT.md for the IPC contract.
#
# Usage:
#   ./run.sh              # launch scanner app (kills stale workers first)
#   ./run.sh stop         # kill leftover workers
#   ./run.sh download     # download weights only

set -e
cd "$(dirname "$0")"
RUN_DIR=".run"
mkdir -p "$RUN_DIR"

# Auto-load .env.local so the SAM download + child worker see HF_TOKEN etc.
if [ -f ".env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.local
  set +a
  [ -n "$HF_TOKEN" ] && echo "[env] HF_TOKEN loaded from .env.local"
fi

if [ ! -x ".venv/bin/python" ]; then
  echo "error: .venv not found. Create it with:"
  echo "  python3 -m venv .venv"
  echo "  .venv/bin/pip install ultralytics pillow numpy torch scipy opencv-python huggingface_hub"
  exit 1
fi

# Nuke any leftover SAM workers and stale lock/PID files. Surviving workers
# from a previous ./run.sh session run OLD code (no single-instance lock)
# and will silently race the inbox with the current worker — observed as
# duplicate-processing + FileNotFoundError spam.
kill_stale_workers() {
  local killed=0
  local pids
  pids=$(pgrep -f "tools/sam_worker.py" || true)
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    echo "[cleanup] killing stale sam_worker pids: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 0.5
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
    killed=1
  fi
  rm -f "$RUN_DIR/sam_worker.pid" "$RUN_DIR/sam_worker.heartbeat"
  # Flush any mid-flight claim dir so the fresh worker starts clean.
  rm -rf "$RUN_DIR/sam_processing" "$RUN_DIR/sam_inbox"/*.processing 2>/dev/null || true
  return 0
}

case "${1:-}" in
  stop)
    kill_stale_workers
    echo "done"
    exit 0
    ;;
  download)
    need_download="1"
    ;;
esac

# Always start from a clean slate.
kill_stale_workers

# Download weights on demand if missing.
if [ ! -f "sam3.pt" ]; then
  if [ -z "$HF_TOKEN" ]; then
    echo "error: sam3.pt missing and HF_TOKEN not set."
    echo "  1. Request access at https://huggingface.co/facebook/sam3"
    echo "  2. Put HF_TOKEN=hf_... in .env.local"
    echo "  3. Re-run ./run.sh"
    exit 1
  fi
  echo "[sam3] sam3.pt missing — downloading with HF_TOKEN"
  if ! .venv/bin/hf download facebook/sam3 --include "*.pt" --local-dir .; then
    echo "[sam3] download failed. Ensure your token has public-gated-repo access"
    echo "        (https://huggingface.co/settings/tokens → Edit → enable gated)"
    exit 1
  fi
fi

if [ "${1:-}" = "download" ]; then
  echo "[sam3] weights ready at $(pwd)/sam3.pt"
  exit 0
fi

# Kill the worker on any exit path — Ctrl-C, app crash, normal quit. Without
# this the Python worker orphans and survives into the next session.
trap kill_stale_workers EXIT INT TERM

echo "[start] swift app (foreground; SAM 3 worker spawned by app)"
cd mac-app
swift build

# Codesign the built binary with a stable identity so the keychain ACL
# (see PairingStore) persists across rebuilds. Ad-hoc signatures change
# CDHash every build, which invalidates "Always Allow" on the keychain
# prompt. Signing with an Apple Development cert pins the designated
# requirement to (leaf cert + identifier), both of which are stable.
BIN=".build/debug/StampScanner"
SIGN_ID="${STAMP_SIGNING_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -p codesigning -v \
    | awk -F\" '/Apple Development/ {print $2; exit}')
fi
if [ -n "$SIGN_ID" ] && [ -x "$BIN" ]; then
  if codesign --force --sign "$SIGN_ID" \
      --identifier com.triptech.StampScanner \
      "$BIN" >/dev/null 2>&1; then
    echo "[sign] signed with: $SIGN_ID"
  else
    echo "[sign] warning: codesign failed; keychain will re-prompt"
  fi
else
  echo "[sign] no Apple Development identity found; keychain will re-prompt"
fi

STAMP_PROJECT_ROOT="$(cd .. && pwd)" "$BIN"
