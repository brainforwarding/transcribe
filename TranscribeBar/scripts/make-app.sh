#!/bin/bash
# Build current sources, assemble resources, and sign a native Apple Silicon app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Transcribe.app"
IDENTITY="${SIGN_IDENTITY:-}"
VERSION="${APP_VERSION:-2.0.10}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-12}"
FIXTURE="${TRANSCRIBE_VALIDATION_FIXTURE:-false}"
SWIFT_OPTIONS=(build -c "$CONFIG" --package-path "$ROOT" --product TranscribeApp --arch arm64)
case "$FIXTURE" in
    false) ;;
    true)
        SWIFT_OPTIONS+=(-Xswiftc -DTRANSCRIBE_VALIDATION_FIXTURE)
        [ -n "${UPDATER_FIXTURE_FEED_URL:-}" ] && [ -n "${UPDATER_FIXTURE_ID:-}" ] && [ -n "${TRANSCRIBE_VALIDATION_ROOT:-}" ] || { echo "Fixture requires explicit feed, unique identity and protected root" >&2; exit 1; }
        python3 - "$UPDATER_FIXTURE_FEED_URL" "$UPDATER_FIXTURE_ID" "$TRANSCRIBE_VALIDATION_ROOT" <<'PY'
import os,re,stat,sys,urllib.parse
url=urllib.parse.urlsplit(sys.argv[1])
assert url.scheme=='http' and url.hostname in ('localhost','127.0.0.1','::1') and not url.username and not url.password, 'Fixture feed must be loopback HTTP'
assert re.fullmatch(r'com\.sebastianmarambio\.transcribe\.updatefixture\.[a-zA-Z0-9-]+',sys.argv[2]), 'Wrong fixture identity'
root=sys.argv[3]
assert os.path.isabs(root) and not os.path.islink(root), 'Fixture root must be an absolute nonsymlink path'
metadata=os.stat(root)
assert stat.S_ISDIR(metadata.st_mode) and metadata.st_uid==os.getuid() and stat.S_IMODE(metadata.st_mode)==0o700, 'Fixture root must be a private owned directory'
PY
        ;;
    *) echo "TRANSCRIBE_VALIDATION_FIXTURE must be true or false" >&2; exit 1 ;;
esac
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APP_VERSION must be major.minor.patch" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "APP_BUILD_NUMBER must be numeric" >&2; exit 1; }

if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
    [ -n "$IDENTITY" ] || IDENTITY="-"
fi

# Never package a cached executable without first letting SwiftPM rebuild changed sources.
swift "${SWIFT_OPTIONS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path --arch arm64)"
BIN="$BIN_DIR/TranscribeApp"
[ -f "$BIN" ] || { echo "Built executable not found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN" "$APP/Contents/MacOS/Transcribe"
# SwiftPM links the binary framework but does not package it into an app bundle.
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "Pinned Sparkle framework not found: resolve package dependencies first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
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
python3 - "$APP/Contents/Info.plist" "$ROOT/scripts/updater-config.json" "$FIXTURE" "${UPDATER_FIXTURE_FEED_URL:-}" "${UPDATER_FIXTURE_ID:-}" "${TRANSCRIBE_VALIDATION_ROOT:-}" <<'PY'
import json,plistlib,sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
with open(sys.argv[2]) as f: config=json.load(f)
info.update(SUFeedURL=config['feedURL'], SUPublicEDKey=config['publicKey'],
            SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
            SUEnableAutomaticChecks=True, SUAllowsAutomaticUpdates=False,
            SUAutomaticallyUpdate=False, SUSendProfileInfo=False)
if sys.argv[3]=='true':
    info.update(CFBundleIdentifier=sys.argv[5], TranscribeValidationFixture=True,
                TranscribeValidationRoot=sys.argv[6], SUFeedURL=sys.argv[4],
                NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
swift "$ROOT/scripts/make-icon.swift"
[ -f "$ROOT/build/AppIcon.icns" ] || { echo "App icon generation failed" >&2; exit 1; }
ditto "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign executable children before their enclosing framework and app. Downloader
# keeps its own sandbox entitlements; outer app entitlements are never reused.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
NESTED_SIGN=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    NESTED_SIGN+=(--options runtime --timestamp)
fi
codesign "${NESTED_SIGN[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${NESTED_SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${NESTED_SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${NESTED_SIGN[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${NESTED_SIGN[@]}" "$FRAMEWORK"
case "$IDENTITY" in
    "-") codesign --force --sign - "$APP" ;;
    "Developer ID Application"*)
        codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/Transcribe.entitlements" --sign "$IDENTITY" "$APP" ;;
    *) codesign --force --sign "$IDENTITY" "$APP" ;;
esac
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $VERSION ($BUILD_NUMBER) → $APP"
