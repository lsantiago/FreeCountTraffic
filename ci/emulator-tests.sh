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
adb pull "/sdcard/Android/data/$PKG/files/screenshots/." screenshots/ || echo "no screenshots pulled"

# Plain launch screenshot, independent of the tests.
adb shell am start -n "$PKG/.MainActivity"
sleep 5
adb exec-out screencap -p > screenshots/00_launch.png

if grep -q "FAILURES!!!" instrument.log || ! grep -q "OK (" instrument.log; then
  echo "Instrumented tests failed"
  exit 1
fi
echo "Instrumented tests passed"
