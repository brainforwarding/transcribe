#!/bin/bash
# Explicit distribution step. Credentials stay in the existing notarytool Keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/.app-staging.noindex/Transcribe.app}"
APP="$(cd "$APP" && pwd -P)"
DMG="$(dirname "$APP")/Transcribe.dmg"
FIXTURE=false
if [ "${2:-}" = "--fixture" ]; then FIXTURE=true
elif [ -n "${2:-}" ]; then echo "Usage: notarize.sh [app-path] [--fixture]" >&2; exit 1; fi
verify_app() {
    if $FIXTURE; then "$ROOT/scripts/verify-app.sh" "$@" --fixture
    else "$ROOT/scripts/verify-app.sh" "$@"; fi
}
PROFILE="${NOTARY_PROFILE:-meetrec-notary}"
RECEIPTS="$(dirname "$APP")/notarization-results"
[ -d "$APP" ] || { echo "Signed app not found. Run make-app.sh release first." >&2; exit 1; }

SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<< "$SIGNATURE" || { echo "Developer ID signature required" >&2; exit 1; }
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || { echo "Hardened Runtime required" >&2; exit 1; }
IDENTITY="$(sed -n 's/^Authority=//p' <<< "$SIGNATURE" | head -n 1)"
# Static distribution work does not start the app or touch the owner's store.
# Explicit isolated launch validation happens separately, after notarization.
verify_app "$APP"

mkdir -p "$ROOT/build/.notarization.noindex"
STAGE="$(mktemp -d "$ROOT/build/.notarization.noindex/notarize.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$RECEIPTS"

submit_artifact() {
    local kind="$1" path="$2" submission_exit=0
    echo "Submitting $kind for notarization (bounded to 20 minutes)"
    xcrun notarytool submit "$path" --keychain-profile "$PROFILE" --wait --timeout 20m --output-format json > "$STAGE/$kind-result.json" || submission_exit=$?
    python3 - "$STAGE/$kind-result.json" "$RECEIPTS/$kind.json" "$kind" "$submission_exit" <<'PY'
import json,sys
try: result=json.load(open(sys.argv[1]))
except (OSError, ValueError): raise SystemExit('Notarization response unavailable; submission was not verified')
receipt={key:result[key] for key in ['id','status'] if key in result}
with open(sys.argv[2],'w') as f: json.dump(receipt,f,indent=2); f.write('\n')
print(f"{sys.argv[3]} submission {receipt.get('id','unknown')}: {receipt.get('status','unknown')}")
if result.get('status')!='Accepted' or sys.argv[4]!='0': raise SystemExit('Notarization was not accepted within the bounded wait')
PY
}

# Notarize and staple the app before copying it into the final disk image.
ditto -c -k --keepParent "$APP" "$STAGE/Transcribe.zip"
submit_artifact app "$STAGE/Transcribe.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
verify_app "$APP" --distribution

mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/Transcribe.app"
ln -s /Applications "$STAGE/image/Applications"
hdiutil create -volname "Transcribe" -srcfolder "$STAGE/image" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
submit_artifact dmg "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

MOUNT="$STAGE/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT
verify_app "$MOUNT/Transcribe.app" --distribution
hdiutil detach "$MOUNT"
trap 'rm -rf "$STAGE"' EXIT
echo "Verified notarized app and installer → $DMG"
