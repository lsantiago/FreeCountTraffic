#!/usr/bin/env bash
# Runs on the already-booted emulator:
#  1. instrumented smoke tests (+ screenshots)
#  2. a headless counting run over ci/testdata/vehicles_short.mp4, with results and screenshots pulled back.
# The APK is installed with adb (not via Gradle) so the app and its private files survive until we pull them.
set -u
PKG=com.freecount.traffic
# Boxes as "left,top,right,bottom,lengthMeters;..." in normalized coordinates. These two vertical boxes (one per carriageway)
# fit vehicles_short.mp4, where traffic moves toward/away from the camera. Lengths (25 m) are placeholders. Override with ZONES=...
ZONES="${ZONES:-0.25,0.40,0.44,0.80,25;0.52,0.40,0.72,0.80,25}"
STATUS=0

adb install -r apks/debug/app-debug.apk
adb install -r apks/androidTest/debug/app-debug-androidTest.apk
for p in android.permission.CAMERA android.permission.ACCESS_COARSE_LOCATION android.permission.ACCESS_FINE_LOCATION; do
  adb shell pm grant "$PKG" "$p"
done

mkdir -p screenshots

# ---------- 1. smoke tests ----------
adb shell am instrument -w "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | tee instrument.log

# The app is debuggable, so run-as can read its private files dir (the external one is not readable by adb on API 30).
for f in $(adb shell run-as "$PKG" ls files/screenshots | tr -d '\r'); do
  adb exec-out run-as "$PKG" cat "files/screenshots/$f" > "screenshots/$f"
done

if grep -q "FAILURES!!!" instrument.log || ! grep -q "OK (" instrument.log; then
  echo "Instrumented tests failed"
  STATUS=1
fi

# ---------- 2. headless run over the test video ----------
adb shell am force-stop "$PKG"
adb logcat -c
adb push ci/testdata/vehicles_short.mp4 /data/local/tmp/v.mp4
adb shell "run-as $PKG cp /data/local/tmp/v.mp4 files/v.mp4"
adb shell am start -n "$PKG/.MainActivity" --es autotest_video v.mp4 --es autotest_zones "$ZONES"

done_flag=0
for i in $(seq 1 450); do   # up to ~15 minutes; a screenshot every 20 s
  sleep 2
  if adb shell "run-as $PKG ls files" | tr -d '\r' | grep -q '^autotest_done$'; then done_flag=1; break; fi
  if [ $((i % 10)) = 0 ]; then
    adb exec-out screencap -p > "screenshots/run_$(printf '%02d' $((i / 10))).png"
  fi
done
adb exec-out screencap -p > screenshots/run_final.png
# the app then shows results (+1 s), the graph (+6 s) and the validation grid (+13 s)
if [ "$done_flag" = 1 ]; then
  sleep 3; adb exec-out screencap -p > screenshots/results.png
  sleep 5; adb exec-out screencap -p > screenshots/graph.png
  sleep 8; adb exec-out screencap -p > screenshots/validate.png
fi

for f in autotest_result.csv autotest_summary.txt autotest_done; do
  adb exec-out run-as "$PKG" cat "files/$f" > "screenshots/$f" 2>/dev/null
done
adb logcat -d -s AutoTest:I AndroidRuntime:E > logcat_autotest.txt

echo "===== AUTOTEST SUMMARY (zones: $ZONES) ====="
cat screenshots/autotest_summary.txt 2>/dev/null || echo "(no summary)"
echo "===== first rows ====="
head -20 screenshots/autotest_result.csv 2>/dev/null

if [ "$done_flag" != 1 ]; then
  echo "Autotest did not finish in time"
  STATUS=1
fi

# Plain launch screenshot, independent of the tests.
adb shell am force-stop "$PKG"
adb shell am start -n "$PKG/.MainActivity"
sleep 5
adb exec-out screencap -p > screenshots/00_launch.png

[ "$STATUS" = 0 ] && echo "All emulator checks passed" || echo "Emulator checks failed"
exit $STATUS
