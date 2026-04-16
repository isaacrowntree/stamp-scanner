# Stamp Scanner

Two-device workflow for cataloguing stamp collections:

- **iPhone** acts as a tethered scanner — macro-lens captures of stamps.
- **Mac** runs SAM 3 segmentation, deduplication, rotation, and a local VLM (Qwen3-VL) for identification. Hosts a queryable SQLite library you can point external tools at.
- **Colnect catalogue lookup** (optional) matches identified stamps to official Colnect IDs.

## Architecture

```
iPhone (ios-app/)                    Mac (mac-app/)                 Python (tools/)
┌───────────────────┐   HTTP over    ┌───────────────────┐   file   ┌─────────────────┐
│ Capture (HEIC)    ├───LAN+Bonjour─▶│ PhoneIngestServer ├──drop───▶│ sam_worker.py   │
│ MotionGate        │                │ (accepts uploads) │          │ SAM 3 + dedup   │
│ Lens picker       │                └───────────────────┘          │ + white balance │
└───────────────────┘                         │                     └────────┬────────┘
                                              │                              │ writes
                                              │                              ▼
                                     ┌────────────────────┐         ┌─────────────────────┐
                                     │ SwiftUI library UI │◀──GRDB──│ library.sqlite      │
                                     │ — grid, detail,    │         │ (~/Library/App Sup.)│
                                     │   rotate, ident-   │         └──────────▲──────────┘
                                     │   ify, colnect     │                    │
                                     └────────────────────┘                    │ writes
                                                │                              │
                                                │ spawns                       │
                                                ▼                              │
                                     ┌────────────────────┐                    │
                                     │ orientation_worker │───── Ollama ───────┤
                                     │   (Qwen3-VL)       │                    │
                                     │ colnect_lookup.py  │───── HTTP ─────────┘
                                     └────────────────────┘
```

**Data flow:**

1. iPhone captures HEIC → uploads to paired Mac over Bonjour/LAN
2. Mac HTTP listener drops the file into `.run/sam_inbox/`
3. Python `sam_worker.py` segments via SAM 3, deduplicates via pHash, warps + white-balances, writes to `library.sqlite`
4. Swift library UI updates live via GRDB `@Query`
5. User triggers **Identify** (Qwen3-VL) or **Colnect** (catalogue match) from toolbar
6. Manual rotation buttons on each cell correct SAM's orientation mistakes

## Repository layout

```
mac-app/           SwiftUI library + ingest server
  Sources/StampScanner/
    App/              @main + filesystem paths
    Network/          HTTP listener, pairing, keychain
    Store/            GRDB schema, queries, NSImage rotation
    UI/               Welcome, Library window, sidebar, grid, detail panel, toolbar
    Library/          filter + sort models
  Tests/              GRDB contract tests + fixture images

ios-app/           SwiftUI iOS scanner (Xcode project via xcodegen)
  project.yml       XcodeGen config — run `xcodegen` to produce .xcodeproj
  StampScannerIOS/
    App.swift       Pairing gate → CaptureView
    Capture/        AVCapture pipeline + MotionGate port
    Pairing/        Bonjour discovery + handshake
    Upload/         HEIC upload queue with offline retry
    UI/             Camera preview, sharpness HUD

tools/             Python workers (one process per lifecycle stage)
  sam_worker.py          --daemon | --one-shot    SAM 3 segmentation + dedup
  orientation_worker.py  --id-only | --orient-only VLM identification via Qwen3-VL
  colnect_lookup.py       (no flags needed)        Catalogue match via Colnect API
  run_fixture_pipeline.sh                          E2E fixture test w/ scratch DB

run.sh             Main launcher — starts Mac app, auto-downloads SAM 3 weights
```

## Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15+ (for Swift compilation)
- Python 3.12+
- [Ollama](https://ollama.com/) with `qwen3-vl` pulled
- ~25GB free disk (SAM 3: 3.4GB, Qwen3-VL: 6GB, Python deps: ~5GB)
- HuggingFace account with access to `facebook/sam3` (gated, free)

## Setup

```bash
# 1. Python venv
python3 -m venv .venv
.venv/bin/pip install ultralytics pillow numpy torch scipy opencv-python \
                     huggingface_hub pillow-heif imagehash requests

# 2. Environment
cp .env.example .env.local
# Edit .env.local — add your HF_TOKEN and (optionally) COLNECT_API_KEY

# 3. Ollama models
brew install ollama
ollama pull qwen3-vl

# 4. SAM 3 weights — request access at https://huggingface.co/facebook/sam3
./run.sh download   # downloads sam3.pt (3.4GB) using HF_TOKEN from .env.local

# 5. iOS project generation (only if you want to use the iPhone)
brew install xcodegen
cd ios-app && xcodegen && open StampScannerIOS.xcodeproj
```

## Running

```bash
./run.sh            # launches Mac app; SAM worker starts automatically
./run.sh stop       # kills all running workers
./run.sh download   # just downloads SAM 3 weights
```

### First-run pairing

On first launch the Mac shows a 6-digit code. Open the iOS app, tap your Mac in the Bonjour list, enter the code. The iPhone caches the bond in Keychain — subsequent launches skip pairing.

### Scanning workflow

1. iPhone points at stamps, tap preview to fire manual capture (or auto-fires on sharp, stable frames)
2. HEIC uploads to Mac, SAM segments, grid fills
3. Hover a cell → rotate buttons appear for quick orientation fixes
4. Toolbar **Identify** button runs Qwen3-VL to fill country/year/denomination/etc (~1min per stamp)
5. Toolbar **Colnect** button (needs `COLNECT_API_KEY`) matches identified stamps to catalogue numbers

## Database

`~/Library/Application Support/StampScanner/library.sqlite` — plain SQLite, WAL mode, queryable by any external tool while the app is running.

```sql
SELECT country, COUNT(*) FROM stamps GROUP BY country;
UPDATE stamps SET flagged = 1 WHERE confidence < 0.7;
```

Test runs use `STAMP_APP_SUPPORT=<tmpdir>` to redirect to a scratch DB; see `tools/run_fixture_pipeline.sh`.

## Tests

```bash
cd mac-app && swift test                    # GRDB contract tests
./tools/run_fixture_pipeline.sh             # SAM pipeline on bundled fixtures
./tools/run_fixture_pipeline.sh --identify  # + VLM identification (slow)
```

Fixtures in `mac-app/Tests/StampScannerTests/Fixtures/` cover single stamps, multi-stamp grids, envelope scenes, real iPhone snaps, and a negative control (selfie).

## License

MIT — see [LICENSE](./LICENSE).
