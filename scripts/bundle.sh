#!/bin/bash
# Builds a release binary and wraps it in TartUI.app so it can live in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
APP=build/TartUI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/TartUI "$APP/Contents/MacOS/TartUI"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
