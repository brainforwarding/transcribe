#!/bin/bash
# Signed, compile-only comparison. Never launches the normal app or touches its history.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 && $# -le 2 && -f "$1" ]] || { echo "Usage: $0 synthetic-16k-mono.wav [build-only]" >&2; exit 2; }
[[ $# == 1 || "$2" == "build-only" ]] || { echo "Second argument must be build-only" >&2; exit 2; }
AUDIO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$ROOT/build"
STAGE="$(mktemp -d "$ROOT/build/dictation-benchmark.XXXXXX")"
chmod 700 "$STAGE"
python3 - "$ROOT" "$STAGE" <<'PY'
import pathlib,shlex,sys
root,stage=map(pathlib.Path,sys.argv[1:])
source=(root/'scripts/make-app.sh').read_text()
source=source.replace('ROOT="$(cd "$(dirname "$0")/.." && pwd)"','ROOT='+shlex.quote(str(root)),1)
source=source.replace('APP="$ROOT/build/Transcribe.app"','APP='+shlex.quote(str(stage/'Transcribe.app')),1)
source=source.replace('swift "${SWIFT_OPTIONS[@]}"','SWIFT_OPTIONS+=(-Xswiftc -DTRANSCRIBE_DICTATION_BENCHMARK)\nswift "${SWIFT_OPTIONS[@]}"',1)
(stage/'make-benchmark-app.sh').write_text(source)
PY
echo "Comparison artifacts → $STAGE"
if ! bash "$STAGE/make-benchmark-app.sh" debug >"$STAGE/build.log" 2>&1; then
    echo "Benchmark build failed; see $STAGE/build.log" >&2
    exit 1
fi
echo "Benchmark executable → $STAGE/Transcribe.app/Contents/MacOS/Transcribe"
if [[ "${2:-}" == "build-only" ]]; then exit 0; fi
for mode in standard committed live; do
    "$STAGE/Transcribe.app/Contents/MacOS/Transcribe" "$AUDIO" "$STAGE/$mode" "$mode"
done
echo "Comparison complete. Reports contain the supplied sample's transcript; keep private audio private."
