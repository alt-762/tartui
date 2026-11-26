#!/bin/bash
# Regenerates Resources/AppIcon.icns (and AppIcon.png) from Resources/AppIcon.svg.
# Rendering uses WebKit via scripts/render_icon.swift, so it needs no extra tools.
set -euo pipefail
cd "$(dirname "$0")/.."

SVG=Resources/AppIcon.svg
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/render_icon.swift "$SVG" "$WORK/AppIcon-1024.png" 1024

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/AppIcon-1024.png" Resources/AppIcon.png
echo "Built Resources/AppIcon.icns and Resources/AppIcon.png"
