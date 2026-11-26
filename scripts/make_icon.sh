#!/bin/bash
# Regenerates the app icon resources:
#   Resources/AppIcon.icon  (Icon Composer document, source of the macOS 26+ Liquid Glass icon)
#     -> Resources/Assets.car            compiled with actool (needs Xcode 26 or later)
#   Resources/AppIcon.svg   (flat icon, source of the classic icon)
#     -> Resources/AppIcon.icns, AppIcon.png  rendered with WebKit via scripts/render_icon.swift
# The built app ships both: CFBundleIconName picks Assets.car, CFBundleIconFile the .icns fallback.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Classic .icns from the SVG.
swift scripts/render_icon.swift Resources/AppIcon.svg "$WORK/AppIcon-1024.png" 1024
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

# Asset catalog from the Icon Composer document.
mkdir -p "$WORK/car"
if xcrun actool Resources/AppIcon.icon --compile "$WORK/car" --platform macosx \
     --minimum-deployment-target 14.0 --app-icon AppIcon --include-all-app-icons \
     --output-partial-info-plist "$WORK/car/partial.plist" >"$WORK/actool.log" 2>&1 \
   && [ -f "$WORK/car/Assets.car" ]; then
  cp "$WORK/car/Assets.car" Resources/Assets.car
  echo "Built Resources/Assets.car"
else
  cat "$WORK/actool.log" >&2
  echo "warning: actool could not compile Resources/AppIcon.icon (needs Xcode 26+); Assets.car not updated" >&2
fi
