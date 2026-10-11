#!/bin/bash
# Generate a signed publication candidate only after exact public asset verification.
# This does not publish, modify the checked-in feed, launch apps, or authorize 1P.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DMG="${1:?Usage: prepare-appcast.sh notarized-dmg version build-number}"
VERSION="${2:?Usage: prepare-appcast.sh notarized-dmg version build-number}"
BUILD_NUMBER="${3:?Usage: prepare-appcast.sh notarized-dmg version build-number}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number" >&2; exit 1; }
"$REPO/scripts/dev-secrets" status
KEY="$ROOT/.secrets/updater-signing.seed"
[ -f "$KEY" ] || { echo "Explicitly provision updater signing first" >&2; exit 1; }
TOOLS="$("$ROOT/scripts/sparkle-tools.sh")"
OUTPUT="$ROOT/build/update-publication/$VERSION"
[ ! -e "$OUTPUT" ] || { echo "Publication stage already exists; preserved" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "$ROOT/build/update-publication/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
URL="https://github.com/brainforwarding/transcribe/releases/download/v$VERSION/Transcribe.dmg"
codesign --verify --strict "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
# Do not print redirect URLs, tokens or other HTTP response metadata.
curl --fail --location --silent --show-error "$URL" --output "$STAGE/download.dmg"
cmp -s "$DMG" "$STAGE/download.dmg" || { echo "Public release bytes differ from notarized artifact" >&2; exit 1; }
mv "$STAGE/download.dmg" "$STAGE/Transcribe.dmg"
if [ -f "$REPO/docs/updates/appcast.xml" ]; then ditto "$REPO/docs/updates/appcast.xml" "$STAGE/appcast.xml"; fi
"$TOOLS/bin/generate_appcast" --ed-key-file "$KEY" --maximum-deltas 0 --maximum-versions 0 \
    --download-url-prefix "https://github.com/brainforwarding/transcribe/releases/download/v$VERSION/" \
    -o "$STAGE/appcast.xml" "$STAGE"
"$TOOLS/bin/sign_update" --ed-key-file "$KEY" --verify "$STAGE/appcast.xml"
python3 - "$STAGE/appcast.xml" "$URL" "$VERSION" "$STAGE/Transcribe.dmg" "$STAGE/signature.txt" "$BUILD_NUMBER" <<'PY'
import os,sys,xml.etree.ElementTree as ET
ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items=ET.parse(sys.argv[1]).getroot().findall('./channel/item')
matching=[item for item in items if (item.find('enclosure') is not None and item.find('enclosure').get('url')==sys.argv[2])]
assert len(matching)==1, 'Published asset must occur exactly once'
item=matching[0]; enclosure=item.find('enclosure')
assert enclosure.get(ns+'shortVersionString', item.findtext(ns+'shortVersionString'))==sys.argv[3], 'Wrong marketing version'
assert enclosure.get(ns+'version', item.findtext(ns+'version'))==sys.argv[6], 'Wrong build version'
assert int(enclosure.get('length','0'))==os.path.getsize(sys.argv[4]), 'Wrong archive byte length'
assert item.findtext(ns+'minimumSystemVersion') in ('13.0','13.0.0'), 'Wrong minimum OS'
hardware=item.findtext(ns+'hardwareRequirements','')
assert 'arm64' in hardware, 'Missing Apple Silicon hardware requirement'
signature=enclosure.get(ns+'edSignature')
assert signature, 'Missing archive signature'
open(sys.argv[5],'w').write(signature+'\n')
PY
SIGNATURE="$(cat "$STAGE/signature.txt")" # public signature, never the private key
"$TOOLS/bin/sign_update" --ed-key-file "$KEY" --verify "$STAGE/Transcribe.dmg" "$SIGNATURE"
rm "$STAGE/signature.txt"
shasum -a 256 "$STAGE/Transcribe.dmg" > "$STAGE/SHA256.txt"
mv "$STAGE" "$OUTPUT"
trap - EXIT
echo "Verified signed appcast candidate (not published) → $OUTPUT/appcast.xml"
