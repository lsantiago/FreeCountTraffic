# Free Count Traffic (iOS)

Native SwiftUI port of the Android app: camera and video sources, counting boxes, per-class / per-direction counts,
speed estimation, history, CSV and PDF export. Everything runs on-device.

- **Detection:** Ultralytics YOLO11 (n / s / m = Fastest / Balanced / High Accuracy, selectable in Settings) exported to Core ML
  and run through Vision. `scripts/export-models.sh` generates them (CI caches the result); they are not committed.
  YOLO weights are AGPL-3.0: fine for personal / open-source use, check the licence before commercial distribution.
- **Core logic:** `Sources/TrafficCore` is a Swift port of the Android Kotlin core, tested with the same cases
  (`Tests/TrafficCoreTests`).
- **Not on iOS yet:** RTSP streams (iOS has no built-in RTSP; it needs a third-party player).

## Get an installable app without a Mac (recommended)

GitHub Actions builds it on a macOS runner (see `../.github/workflows/ios.yml`):

1. Push to `main`, open the run in the **Actions** tab and download the artifact `FreeCountTraffic-unsigned-ipa`.
2. Unzip it to get `FreeCountTraffic-unsigned.ipa`.
3. Sign and install it from Windows with a sideloading tool such as Sideloadly, using your Apple ID and your iPhone
   connected by USB. With a free Apple ID the app expires after 7 days and must be reinstalled.

The same run also executes the unit tests, launches the app in an iPhone simulator, takes screenshots and runs a
headless counting pass over `../ci/testdata/vehicles_short.mp4` (artifact `ios-simulator-screenshots-and-logs`).

## Build with xtool (optional, needs WSL/Linux or a Mac)

This folder is a SwiftPM package with an `xtool.yml`, so [xtool](https://github.com/xtool-org/xtool) can build, sign
and install it:

```bash
./scripts/export-models.sh # once (needs Python 3.10-3.12)
xtool dev                  # build, sign with your Apple ID, install and launch on the connected iPhone
```

The Core ML models are compiled on the device at first launch in this mode (xtool has no `coremlc`).
The xtool path is set up from the docs but has not been run yet; CI uses XcodeGen + xcodebuild (`project.yml`).
