# Free Count Traffic (Android)

On-device vehicle counter inspired by *AI Traffic Count*. Draw counting boxes on a camera, video or RTSP image;
vehicles that cross a box are counted by class and direction, and their speed is estimated. No video is stored or uploaded.

- **Sources:** live camera (CameraX), video file, RTSP stream (Media3).
- **Detection:** EfficientDet-Lite0 (COCO) through MediaPipe Tasks; car, truck, bus, motorcycle, bicycle, person.
- **Tracking / counting / speed:** pure Kotlin in `app/src/main/java/com/freecount/traffic/core` (unit-tested on the JVM).
- **Speed:** set the real length (m) of a zone's long side; speed = length x fraction travelled / time inside.
  Video frames are read at exact timestamps (10 fps), so speed does not depend on device performance.
- **Results:** per-zone totals by class and direction, average/max speed, history in Room, export CSV and PDF.

## Build without Android Studio

Push to GitHub. The workflow in `.github/workflows/android.yml`:

1. runs the unit tests and builds the debug APK (artifact `FreeCountTraffic-debug-apk`);
2. boots an Android emulator, installs the app, runs the instrumented smoke tests (model loads and runs on x86_64,
   screens render, RTSP URL validation) and uploads screenshots (artifact `emulator-screenshots-and-logs`).

The detection model is downloaded by Gradle on the first build (`downloadModel` task in `app/build.gradle.kts`).

## Limits to know

- The 640 px, 10 fps pipeline with a small model undercounts at night, in heavy rain or with heavy occlusion.
- Speed accuracy depends on how well the zone length matches the real distance and on the camera angle
  (best: camera looking along or across the road, zone drawn on the road plane).
- The emulator tests do not use real traffic footage, so counting accuracy is validated only by the JVM unit tests.
