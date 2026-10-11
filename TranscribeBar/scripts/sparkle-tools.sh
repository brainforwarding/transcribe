#!/bin/bash
# Fetch pinned public tooling. No keys or app runtime are accessed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/sparkle-tools-2.10.0"
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
    mkdir -p "$ROOT/build"
    STAGE="$(mktemp -d "$ROOT/build/sparkle-tools.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    python3 - "$ROOT/scripts/updater-config.json" "$STAGE/archive.tar.xz" <<'PY'
import hashlib,json,sys,urllib.request
with open(sys.argv[1]) as f: config=json.load(f)
with urllib.request.urlopen(config['toolsURL']) as response, open(sys.argv[2],'wb') as output:
    while chunk:=response.read(1024*1024): output.write(chunk)
with open(sys.argv[2],'rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
if digest!=config['toolsSHA256']: raise SystemExit('Sparkle tools checksum mismatch')
PY
    mkdir "$STAGE/tools"
    tar -xJf "$STAGE/archive.tar.xz" -C "$STAGE/tools"
    codesign --verify --deep --strict "$STAGE/tools/Sparkle.framework"
    mv "$STAGE/tools" "$TOOLS"
fi
printf '%s\n' "$TOOLS"
