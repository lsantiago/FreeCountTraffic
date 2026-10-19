#!/usr/bin/env bash
# Runs the instrumented smoke tests on the already-booted emulator and pulls screenshots.
# The APK is installed with adb (not via Gradle) so the app and its screenshots survive until we pull them.
set -u
PKG=com.freecount.traffic

adb install -r apks/debug/app-debug.apk
adb install -r apks/androidTest/debug/app-debug-androidTest.apk
for p in android.permission.CAMERA android.permission.ACCESS_COARSE_LOCATION android.permission.ACCESS_FINE_LOCATION; do
  adb shell pm grant "$PKG" "$p"
done

adb shell am instrument -w "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | tee instrument.log

mkdir -p screenshots
# The app is debuggable, so run-as can read its private files dir (the external one is not readable by adb on API 30).
for f in $(adb shell run-as "$PKG" ls files/screenshots | tr -d '\r'); do
  adb exec-out run-as "$PKG" cat "files/screenshots/$f" > "screenshots/$f"
done

# Plain launch screenshot, independent of the tests.
adb shell am start -n "$PKG/.MainActivity"
sleep 5
adb exec-out screencap -p > screenshots/00_launch.png

if grep -q "FAILURES!!!" instrument.log || ! grep -q "OK (" instrument.log; then
  echo "Instrumented tests failed"
  exit 1
fi
echo "Instrumented tests passed"
