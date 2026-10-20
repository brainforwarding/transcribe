#!/bin/bash
# Compile the actual coordinator with standalone native dependencies. No XCTest or TCC grants.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --product transcribe-core --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT" --show-bin-path --arch arm64)"
# Link only current sources; SwiftPM can leave removed source objects behind.
CORE_OBJECTS=()
for source in "$ROOT/Sources/TranscribeCore/"*.swift; do
    CORE_OBJECTS+=("$BIN_DIR/TranscribeCore.build/$(basename "$source").o")
done
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-coordinator-tests.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
swiftc -target arm64-apple-macosx13.0 -I "$BIN_DIR/Modules" \
    "$ROOT/Sources/TranscribeApp/AppModel.swift" \
    "$ROOT/Sources/TranscribeApp/PasteService.swift" \
    "$ROOT/Sources/TranscribeApp/Permissions.swift" \
    "$ROOT/Sources/TranscribeApp/Keychain.swift" \
    "$ROOT/Sources/TranscribeApp/Config.swift" \
    "$ROOT/scripts/test-coordinator.swift" \
    "${CORE_OBJECTS[@]}" \
    -o "$STAGE/coordinator-selftest"
"$STAGE/coordinator-selftest"
