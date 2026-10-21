#!/bin/bash
# Builds PirateSwitch.app (universal, ad-hoc signed) into ./build.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/PirateSwitch.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PirateSwitch" "$APP/Contents/MacOS/PirateSwitch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/MenuBarFlag.pdf Resources/MenuBarFlagSlash.pdf "$APP/Contents/Resources/"

# Liquid Glass app icon (Assets.car), plus AppIcon.icns for macOS before 26.
# Needs Xcode 26 or later; without it the app gets the generic icon.
xcrun actool "$PWD/Icon/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 13.0 \
    --output-partial-info-plist "$PWD/build/AppIcon.plist" \
    --output-format human-readable-text --errors --warnings >&2 || true
if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "warning: couldn't compile the app icon (needs Xcode 26 or later)" >&2
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Replace any previous copy, including the one from before the rename.
    pkill -x PirateSwitch || true
    pkill -x DownloadSwitch || true
    rm -rf /Applications/PirateSwitch.app "/Applications/Download Switch.app"
    cp -R "$APP" /Applications/
    open /Applications/PirateSwitch.app
    echo "Installed to /Applications"
fi
