#!/bin/bash
# Notarize the signed Transcribe.app and build a stapled DMG for distribution.
# Prereqs:
#   1) SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/make-app.sh release
#   2) notarytool credentials stored as a profile:
#        xcrun notarytool store-credentials "meetrec-notary" --apple-id … --team-id … --password …
# Run: NOTARY_PROFILE="meetrec-notary" ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Transcribe.app"
DMG="$ROOT/build/Transcribe.dmg"
PROFILE="${NOTARY_PROFILE:-meetrec-notary}"

[ -d "$APP" ] || { echo "Signed app not found. Run:"; \
  echo "  SIGN_IDENTITY='Developer ID Application: … (47SAXBXKHA)' ./scripts/make-app.sh release"; exit 1; }

# The app must be Developer-ID signed with Hardened Runtime (not ad-hoc) to notarize.
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "ERROR: app is ad-hoc signed. Re-run make-app.sh with SIGN_IDENTITY set."; exit 1
fi

echo "Building DMG…"
rm -f "$DMG"
hdiutil create -volname "Transcribe" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "Stapling…"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
echo "✅ Distributable, notarized: $DMG"
