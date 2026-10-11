#!/bin/bash
# Original follow policy/timing only. No apps, hardware, credentials or input.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-live-follow.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
swiftc -target arm64-apple-macosx13.0 \
    "$ROOT/Sources/TranscribeApp/LiveTranscriptFollow.swift" \
    "$ROOT/scripts/test-live-follow.swift" -o "$STAGE/follow-selftest"
"$STAGE/follow-selftest"
