#!/bin/bash
# Packages build/TartUI.app into a drag-to-install DMG.
# Usage: ./scripts/make_dmg.sh [version]   -> build/TartUI-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
APP=build/TartUI.app
DMG="build/TartUI-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found, run ./scripts/bundle.sh first" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "TartUI ${VERSION}" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo "Built $DMG"
