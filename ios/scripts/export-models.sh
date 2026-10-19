#!/usr/bin/env bash
# Exports Ultralytics YOLO11 n / s / m to Core ML (with built-in NMS) into Sources/FreeCountTraffic/Resources.
# They back the "Fastest / Balanced / High Accuracy" detection models. Needs Python 3.10-3.12 and ~3 GB of disk
# for the temporary virtualenv (PyTorch). The result is cached by CI, so this only runs when the script changes.
#
# License note: Ultralytics YOLO weights are AGPL-3.0. Fine for personal use and for an open-source repo; check
# the terms (or use an Ultralytics enterprise licence) before distributing the app commercially.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/Sources/FreeCountTraffic/Resources"
mkdir -p "$OUT"

missing=0
for n in n s m; do [ -d "$OUT/yolo11$n.mlpackage" ] || missing=1; done
if [ "$missing" = 0 ]; then echo "models already present"; exit 0; fi

WORK="$(mktemp -d)"
python3 -m venv "$WORK/venv"
# shellcheck disable=SC1091
source "$WORK/venv/bin/activate"
pip install --quiet --upgrade pip
# numpy 2.4+ breaks coremltools int-op conversion ("only 0-dimensional arrays can be converted to Python scalars").
pip install --quiet ultralytics coremltools "numpy>=1.23,<=2.3.5"

cd "$WORK"
for n in n s m; do
  yolo export model="yolo11$n.pt" format=coreml nms=True imgsz=640 half=True
  rm -rf "$OUT/yolo11$n.mlpackage"
  mv "yolo11$n.mlpackage" "$OUT/"
done
ls -la "$OUT"
du -sh "$OUT"/*.mlpackage
