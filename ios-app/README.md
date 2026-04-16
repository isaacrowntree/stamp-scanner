# Stamp Scanner — iOS scanner app

Thin capture client for the Mac app. Pairs over local Wi-Fi; every HEIC it
captures goes straight to the Mac's SAM 3 pipeline and into your library.

## Setup

```bash
brew install xcodegen          # once
cd ios-app
xcodegen                       # generates StampScannerIOS.xcodeproj
open StampScannerIOS.xcodeproj
```

In Xcode:

1. Select the `StampScannerIOS` target → Signing & Capabilities → set your
   personal team. Xcode will auto-provision a development profile.
2. Plug in your iPhone, pick it as the run destination, press ⌘R.

## Using it

1. Open the Mac app. In the menu bar choose **Scan → Pair iPhone…** (⌘P).
   A 6-digit code appears.
2. On the phone the app shows a list of nearby Macs (Bonjour discovery).
   Tap yours.
3. Type the code. The app stores the bearer secret in Keychain and flips to
   the camera view.
4. Point at stamps. When the sharpness HUD goes green and the scene is
   still, a 48MP HEIC uploads to the Mac. No further input.

The Mac-side pipeline (SAM 3 → SwiftData library → filmstrip) is unchanged.
