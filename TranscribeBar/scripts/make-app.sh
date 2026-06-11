#!/bin/bash
# Assemble Transcribe.app from the SwiftPM build and sign it.
#   ./scripts/make-app.sh [debug|release]
# Ad-hoc signs by default (for running on THIS Mac). For a notarizable build, set:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/make-app.sh release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Transcribe.app"
BIN="$ROOT/.build/$CONFIG/TranscribeApp"
IDENTITY="${SIGN_IDENTITY:-}"
# No identity given: prefer a STABLE local cert (Apple Development) so TCC grants persist
# across rebuilds; fall back to ad-hoc only if no codesigning cert exists.
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
    [ -z "$IDENTITY" ] && IDENTITY="-"
fi

[ -f "$BIN" ] || swift build -c "$CONFIG" --package-path "$ROOT" --product TranscribeApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transcribe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Transcribe</string>
    <key>CFBundleDisplayName</key><string>Transcribe</string>
    <key>CFBundleIdentifier</key><string>com.sebastianmarambio.transcribe</string>
    <key>CFBundleExecutable</key><string>Transcribe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Transcribe records your microphone to transcribe your meetings.</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

[ -f "$ROOT/build/AppIcon.icns" ] && cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" || true

case "$IDENTITY" in
    "-")
        # Ad-hoc fallback (TCC grants won't persist across rebuilds — last resort).
        codesign --force --sign - "$APP"
        echo "Built (ad-hoc) → $APP" ;;
    "Developer ID Application"*)
        # Distribution: Hardened Runtime + entitlements + secure timestamp (notarizable).
        codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/Transcribe.entitlements" \
            --sign "$IDENTITY" "$APP"
        codesign --verify --deep --strict --verbose=2 "$APP"
        echo "Built (Developer ID) → $APP" ;;
    *)
        # Local stable identity (e.g. Apple Development): no Hardened Runtime / entitlements
        # so it runs without a provisioning profile, but the team-based identity makes TCC
        # grants STICK across rebuilds.
        codesign --force --sign "$IDENTITY" "$APP"
        echo "Built (signed: $IDENTITY) → $APP" ;;
esac
