#!/usr/bin/env bash
# Exports Ultralytics YOLO11 n / s to TensorFlow Lite (float32, 640x640, no NMS: the app decodes and runs NMS)
# into app/src/main/assets. They back the "Fastest / Balanced" detection models (same family as the iOS app).
# Needs Python 3.10-3.12 and a few GB of disk for the temporary virtualenv (PyTorch + TensorFlow).
# CI caches the result, so this only runs when the script changes.
#
# License note: Ultralytics YOLO weights are AGPL-3.0. Fine for personal use and for an open-source repo; check
# the terms (or use an Ultralytics enterprise licence) before distributing the app commercially.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/app/src/main/assets"
mkdir -p "$OUT"

missing=0
for n in n s; do [ -f "$OUT/yolo11$n.tflite" ] || missing=1; done
if [ "$missing" = 0 ]; then echo "models already present"; exit 0; fi

WORK="$(mktemp -d)"
python3 -m venv "$WORK/venv"
# shellcheck disable=SC1091
source "$WORK/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet ultralytics

cd "$WORK"
for n in n s; do
  # Recent Ultralytics exports TFLite through LiteRT and only supports FP32 / INT8 (no FP16).
  yolo export model="yolo11$n.pt" format=tflite imgsz=640
  # the output folder / file name changed across versions: take the (non-INT8) .tflite produced for this model
  f="$(find . -name "*.tflite" -path "*yolo11${n}*" ! -iname "*int8*" ! -iname "*int16*" | head -1)"
  if [ -z "$f" ]; then echo "no .tflite found for yolo11$n"; find . -maxdepth 3 | grep -v venv; exit 1; fi
  echo "using $f"
  cp "$f" "$OUT/yolo11$n.tflite"
done
ls -la "$OUT"
