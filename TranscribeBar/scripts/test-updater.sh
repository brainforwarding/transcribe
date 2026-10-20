#!/bin/bash
# Production updater logic with fake check transport and isolated local saves only.
# No application launch, credentials, permissions, audio, clipboard or HTTP requests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != "--skip-build" ]; then
    swift build --package-path "$ROOT" --product TranscribeApp --arch arm64
fi
BIN_DIR="$(swift build --package-path "$ROOT" --show-bin-path --arch arm64)"
# Link only current sources; SwiftPM can leave removed source objects behind.
CORE_OBJECTS=()
for source in "$ROOT/Sources/TranscribeCore/"*.swift; do
    CORE_OBJECTS+=("$BIN_DIR/TranscribeCore.build/$(basename "$source").o")
done
FRAMEWORKS="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-updater-tests.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
swiftc -target arm64-apple-macosx13.0 -I "$BIN_DIR/Modules" -F "$FRAMEWORKS" \
    "$ROOT/Sources/TranscribeApp/AppModel.swift" \
    "$ROOT/Sources/TranscribeApp/PasteService.swift" \
    "$ROOT/Sources/TranscribeApp/Permissions.swift" \
    "$ROOT/Sources/TranscribeApp/Keychain.swift" \
    "$ROOT/Sources/TranscribeApp/Config.swift" \
    "$ROOT/Sources/TranscribeApp/DesignSystem.swift" \
    "$ROOT/Sources/TranscribeApp/UpdateController.swift" \
    "$BIN_DIR/TranscribeApp.build/DerivedSources/resource_bundle_accessor.swift" \
    "$ROOT/scripts/test-updater.swift" \
    "${CORE_OBJECTS[@]}" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -o "$STAGE/updater-selftest"
"$STAGE/updater-selftest"
