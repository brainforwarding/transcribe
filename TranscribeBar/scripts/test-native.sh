#!/bin/bash
# Test production recognizers with the installed Command Line Tools; XCTest is not needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-native-tests.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
swiftc -target arm64-apple-macosx13.0 \
    "$ROOT/Sources/TranscribeApp/ShortcutService.swift" \
    "$ROOT/Sources/TranscribeApp/Keychain.swift" \
    "$ROOT/scripts/test-native.swift" -o "$STAGE/native-selftest"
"$STAGE/native-selftest"
