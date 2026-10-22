#!/usr/bin/env bash
# Usage: simulator-tests.sh <simulator-udid> <path/to/FreeCountTraffic.app>
# Launches the app, takes screenshots, then runs a headless counting pass over ../ci/testdata/vehicles_short.mp4
# and collects the CSV/summary the app writes into its Documents folder. If mediamtx and ffmpeg are installed, a
# second pass counts the same video served as an RTSP stream (rtsp_* files).
set -u
UDID="$1"
APP="$2"
BUNDLE=com.freecount.traffic
# Boxes as "left,top,right,bottom,lengthMeters;..." in normalized coordinates. Override with ZONES=...
ZONES="${ZONES:-0.25,0.40,0.44,0.80,25;0.52,0.40,0.72,0.80,25}"
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
for i in $(seq 1 450); do   # up to ~15 minutes; a screenshot every 20 s
  sleep 2
  if [ -f "$DATA/Documents/autotest_done" ]; then done_flag=1; break; fi
  if [ $((i % 10)) = 0 ]; then
    xcrun simctl io "$UDID" screenshot "screenshots/run_$(printf '%02d' $((i / 10))).png" 2>/dev/null
  fi
done
xcrun simctl io "$UDID" screenshot screenshots/run_final.png 2>/dev/null
# the app then shows results (+1 s), the graph (+6 s) and the validation grid (+13 s)
if [ "$done_flag" = 1 ]; then
  sleep 3; xcrun simctl io "$UDID" screenshot screenshots/results.png 2>/dev/null
  sleep 5; xcrun simctl io "$UDID" screenshot screenshots/graph.png 2>/dev/null
  sleep 8; xcrun simctl io "$UDID" screenshot screenshots/validate.png 2>/dev/null
fi

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
# ---------- RTSP pass: the test video looped through a local RTSP server ----------
if command -v mediamtx >/dev/null && command -v ffmpeg >/dev/null; then
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  rm -f "$DATA/Documents/autotest_done" "$DATA/Documents/autotest_result.csv" "$DATA/Documents/autotest_summary.txt"
  # without a config file MediaMTX accepts no path: allow publishing and reading any path
  printf 'paths:
  all_others:
' > "${TMPDIR:-/tmp}/mediamtx.yml"
  mediamtx "${TMPDIR:-/tmp}/mediamtx.yml" > screenshots/rtsp_server.log 2>&1 &
  MTX=$!
  sleep 3
  ffmpeg -nostdin -loglevel warning -re -stream_loop -1 -i ../ci/testdata/vehicles_short.mp4 -an     -c:v libx264 -preset veryfast -tune zerolatency -bf 0 -g 25     -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/test > screenshots/rtsp_ffmpeg.log 2>&1 &
  FF=$!
  sleep 4
  xcrun simctl launch "$UDID" "$BUNDLE" -autotest_rtsp rtsp://127.0.0.1:8554/test -autotest_seconds 40 -autotest_zones "$ZONES"
  rtsp_flag=0
  for i in $(seq 1 90); do
    sleep 2
    if [ -f "$DATA/Documents/autotest_done" ]; then rtsp_flag=1; break; fi
    [ "$i" = 15 ] && xcrun simctl io "$UDID" screenshot screenshots/rtsp_run.png 2>/dev/null
  done
  xcrun simctl io "$UDID" screenshot screenshots/rtsp_final.png 2>/dev/null
  kill "$FF" "$MTX" 2>/dev/null || true
  for f in autotest_result.csv autotest_summary.txt autotest_done; do
    cp "$DATA/Documents/$f" "screenshots/rtsp_$f" 2>/dev/null || true
  done
  echo "===== RTSP AUTOTEST SUMMARY ====="
  cat screenshots/rtsp_autotest_summary.txt 2>/dev/null || echo "(no summary)"
  if [ "$rtsp_flag" != 1 ] || [ "$(cat screenshots/rtsp_autotest_done 2>/dev/null)" != "ok" ]; then
    echo "RTSP autotest did not finish correctly: $(cat screenshots/rtsp_autotest_done 2>/dev/null)"
    STATUS=1
  elif grep -q '^unique=0$' screenshots/rtsp_autotest_summary.txt; then
    echo "RTSP autotest counted no vehicles"
    STATUS=1
  fi
else
  echo "mediamtx/ffmpeg not installed: RTSP pass skipped"
fi

[ "$STATUS" = 0 ] && echo "All simulator checks passed" || echo "Simulator checks failed"
exit $STATUS
