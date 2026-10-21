#!/bin/bash
# Builds "Download Switch.app" (universal, ad-hoc signed) into ./build.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Download Switch.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DownloadSwitch" "$APP/Contents/MacOS/DownloadSwitch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x DownloadSwitch || true
    rm -rf "/Applications/Download Switch.app"
    cp -R "$APP" /Applications/
    open "/Applications/Download Switch.app"
    echo "Installed to /Applications"
fi
