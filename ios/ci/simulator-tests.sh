#!/usr/bin/env bash
# Usage: simulator-tests.sh <simulator-udid> <path/to/FreeCountTraffic.app>
# Launches the app, takes screenshots, then runs a headless counting pass over ../ci/testdata/vehicles_short.mp4
# and collects the CSV/summary the app writes into its Documents folder.
set -u
UDID="$1"
APP="$2"
BUNDLE=com.freecount.traffic
# Boxes as "left,top,right,bottom,lengthMeters;..." in normalized coordinates. Override with ZONES=...
ZONES="${ZONES:-0.05,0.45,0.95,0.60,10}"
STATUS=0

mkdir -p screenshots
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location "$BUNDLE" 2>/dev/null || true

# ---------- launch screenshot ----------
xcrun simctl launch "$UDID" "$BUNDLE"
sleep 6
xcrun simctl io "$UDID" screenshot screenshots/00_launch.png
xcrun simctl terminate "$UDID" "$BUNDLE" || true

# ---------- headless counting pass ----------
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Documents"
cp ../ci/testdata/vehicles_short.mp4 "$DATA/Documents/v.mp4"
xcrun simctl launch "$UDID" "$BUNDLE" -autotest_video v.mp4 -autotest_zones "$ZONES"

done_flag=0
for i in $(seq 1 90); do   # up to ~15 minutes
  sleep 10
  xcrun simctl io "$UDID" screenshot "screenshots/run_$(printf '%02d' "$i").png" 2>/dev/null
  if [ -f "$DATA/Documents/autotest_done" ]; then done_flag=1; break; fi
done
xcrun simctl io "$UDID" screenshot screenshots/run_final.png 2>/dev/null

for f in autotest_result.csv autotest_summary.txt autotest_done; do
  cp "$DATA/Documents/$f" "screenshots/$f" 2>/dev/null || true
done
xcrun simctl spawn "$UDID" log show --last 20m --predicate 'process == "FreeCountTraffic"' --style compact > screenshots/app.log 2>/dev/null || true

echo "===== AUTOTEST SUMMARY (boxes: $ZONES) ====="
cat screenshots/autotest_summary.txt 2>/dev/null || echo "(no summary)"
echo "===== first rows ====="
head -20 screenshots/autotest_result.csv 2>/dev/null

if [ "$done_flag" != 1 ] || [ "$(cat screenshots/autotest_done 2>/dev/null)" != "ok" ]; then
  echo "Autotest did not finish correctly"
  STATUS=1
fi
[ "$STATUS" = 0 ] && echo "All simulator checks passed" || echo "Simulator checks failed"
exit $STATUS
