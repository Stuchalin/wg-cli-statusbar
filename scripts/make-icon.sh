#!/bin/bash
# Regenerates Assets/AppIcon.icns from scripts/generate-icon.swift.
# The .icns is committed; a designer-made replacement can simply overwrite it.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$WORK"

swift scripts/generate-icon.swift "$WORK/icon_512x512@2x.png"

for pair in "16:1" "16:2" "32:1" "32:2" "128:1" "128:2" "256:1" "256:2" "512:1" "512:2"; do
    base="${pair%%:*}"
    scale="${pair##*:}"
    side=$((base * scale))
    # sips writes an extra copy for @1x sizes of the same pixel side only once
    if [ "$scale" = "2" ]; then
        out="icon_${base}x${base}@2x.png"
    else
        out="icon_${base}x${base}.png"
    fi
    sips -z "$side" "$side" "$WORK/icon_512x512@2x.png" --out "$WORK/$out" >/dev/null
done

mkdir -p Assets
iconutil -c icns -o Assets/AppIcon.icns "$WORK"
echo "Built Assets/AppIcon.icns"
