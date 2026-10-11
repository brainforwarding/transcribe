#!/bin/bash
# Build current sources, assemble resources, and sign a native Apple Silicon app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Transcribe.app"
IDENTITY="${SIGN_IDENTITY:-}"
VERSION="${APP_VERSION:-2.0.7}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-9}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APP_VERSION must be major.minor.patch" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "APP_BUILD_NUMBER must be numeric" >&2; exit 1; }

if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
    [ -n "$IDENTITY" ] || IDENTITY="-"
fi

# Never package a cached executable without first letting SwiftPM rebuild changed sources.
swift build -c "$CONFIG" --package-path "$ROOT" --product TranscribeApp --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path --arch arm64)"
BIN="$BIN_DIR/TranscribeApp"
[ -f "$BIN" ] || { echo "Built executable not found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN" "$APP/Contents/MacOS/Transcribe"
shopt -s nullglob
for resource in "$BIN_DIR"/*.bundle; do
    ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
shopt -u nullglob

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Transcribe</string>
    <key>CFBundleDisplayName</key><string>Transcribe</string>
    <key>CFBundleIdentifier</key><string>com.sebastianmarambio.transcribe</string>
    <key>CFBundleExecutable</key><string>Transcribe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Transcribe records your microphone for dictation and meeting notes.</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
swift "$ROOT/scripts/make-icon.swift"
[ -f "$ROOT/build/AppIcon.icns" ] || { echo "App icon generation failed" >&2; exit 1; }
ditto "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

case "$IDENTITY" in
    "-") codesign --force --sign - "$APP" ;;
    "Developer ID Application"*)
        codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/Transcribe.entitlements" --sign "$IDENTITY" "$APP" ;;
    *) codesign --force --sign "$IDENTITY" "$APP" ;;
esac
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $VERSION ($BUILD_NUMBER) → $APP"
