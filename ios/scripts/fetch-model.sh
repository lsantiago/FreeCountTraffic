#!/usr/bin/env bash
# Downloads Apple's YOLOv3-Tiny Core ML model (COCO, 80 classes, built-in NMS) once. ~35 MB.
set -euo pipefail
DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/FreeCountTraffic/Resources/YOLOv3Tiny.mlmodel"
if [ -s "$DEST" ]; then echo "model already present"; exit 0; fi
mkdir -p "$(dirname "$DEST")"
curl -fL "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel" -o "$DEST"
echo "downloaded $(wc -c < "$DEST") bytes"
