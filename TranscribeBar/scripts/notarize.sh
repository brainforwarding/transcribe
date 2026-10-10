#!/bin/bash
# Explicit distribution step. Credentials stay in the existing notarytool Keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Transcribe.app"
DMG="$ROOT/build/Transcribe.dmg"
PROFILE="${NOTARY_PROFILE:-meetrec-notary}"
[ -d "$APP" ] || { echo "Signed app not found. Run make-app.sh release first." >&2; exit 1; }

SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<< "$SIGNATURE" || { echo "Developer ID signature required" >&2; exit 1; }
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || { echo "Hardened Runtime required" >&2; exit 1; }
"$ROOT/scripts/verify-app.sh" "$APP" --launch

STAGE="$(mktemp -d "$ROOT/build/notarize.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Notarize and staple the app before copying it into the final disk image.
ditto -c -k --keepParent "$APP" "$STAGE/Transcribe.zip"
xcrun notarytool submit "$STAGE/Transcribe.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGE/app-result.json"
python3 - "$STAGE/app-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status')!='Accepted': raise SystemExit('App notarization was not accepted')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
"$ROOT/scripts/verify-app.sh" "$APP" --distribution

mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/Transcribe.app"
ln -s /Applications "$STAGE/image/Applications"
hdiutil create -volname "Transcribe" -srcfolder "$STAGE/image" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGE/dmg-result.json"
python3 - "$STAGE/dmg-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status')!='Accepted': raise SystemExit('DMG notarization was not accepted')
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

MOUNT="$STAGE/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT
"$ROOT/scripts/verify-app.sh" "$MOUNT/Transcribe.app" --distribution --launch
hdiutil detach "$MOUNT"
trap 'rm -rf "$STAGE"' EXIT
echo "Verified notarized app and installer → $DMG"
