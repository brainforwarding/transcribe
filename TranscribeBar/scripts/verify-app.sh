#!/bin/bash
# Validate the actual packaged artifact, optionally launching it and checking notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: verify-app.sh path/to/Transcribe.app [--distribution] [--launch | --launch-fixture]}"
shift
DISTRIBUTION=false
LAUNCH=false
FIXTURE=false
for option in "$@"; do
    case "$option" in
        --distribution) DISTRIBUTION=true ;;
        --launch) LAUNCH=true ;;
        --launch-fixture) LAUNCH=true; FIXTURE=true ;;
        --fixture) FIXTURE=true ;;
        *) echo "Unknown option: $option" >&2; exit 1 ;;
    esac
done
APP="$(cd "$APP" && pwd -P)"
BIN="$APP/Contents/MacOS/Transcribe"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$BIN" | grep -qw arm64
python3 - "$APP" "$ROOT/scripts/updater-config.json" "$FIXTURE" <<'PY'
import json,os,plistlib,subprocess,sys
app=sys.argv[1]
with open(app+'/Contents/Info.plist','rb') as f: info=plistlib.load(f)
fixture=sys.argv[3]=='true'
if fixture:
    assert info.get('CFBundleIdentifier','').startswith('com.sebastianmarambio.transcribe.updatefixture.'), 'Fixture requires a separate bundle identity'
    assert info.get('TranscribeValidationFixture') is True, 'Fixture isolation marker missing'
    root=info.get('TranscribeValidationRoot','')
    assert os.path.isabs(root) and os.path.isdir(root) and not os.path.islink(root), 'Fixture data root missing'
else:
    assert info.get('CFBundleIdentifier')=='com.sebastianmarambio.transcribe', 'Unexpected bundle identity'
    assert 'TranscribeValidationFixture' not in info and 'TranscribeValidationRoot' not in info, 'Fixture configuration leaked into production'
    assert 'NSAppTransportSecurity' not in info, 'Fixture network exceptions leaked into production'
assert info.get('CFBundleExecutable')=='Transcribe', 'Unexpected executable'
assert info.get('NSMicrophoneUsageDescription'), 'Missing microphone purpose'
assert os.path.isfile(app+'/Contents/Resources/AppIcon.icns'), 'Missing app icon'
entitlements=subprocess.run(['codesign','-d','--entitlements','-', '--xml',app],capture_output=True,check=True).stdout
if entitlements.strip():
    claims=plistlib.loads(entitlements)
    assert 'keychain-access-groups' not in claims, 'Restricted Keychain entitlement requires a profile'
resource_bundle=app+'/Contents/Resources/TranscribeBar_TranscribeApp.bundle'
assert os.path.isdir(resource_bundle), 'Missing SwiftPM app resources'
for font in ['Urbanist-Regular.ttf','Urbanist-Medium.ttf','Urbanist-SemiBold.ttf','Urbanist-Bold.otf','Urbanist-ExtraBold.ttf']:
    path=os.path.join(resource_bundle,font)
    assert os.path.isfile(path) and os.path.getsize(path)>0, 'Missing bundled font: '+font
icons=[os.path.join(resource_bundle,p) for p in os.listdir(resource_bundle) if p.endswith('.pdf')]
assert len(icons)>=63, 'Missing approved Figma icon resources'
for path in icons:
    with open(path,'rb') as f: assert f.read(5)==b'%PDF-', 'Invalid icon PDF: '+os.path.basename(path)
with open(sys.argv[2]) as f: config=json.load(f)
assert info.get('SUPublicEDKey')==config['publicKey'], 'Wrong updater signing key'
if not fixture: assert info.get('SUFeedURL')==config['feedURL'], 'Wrong updater feed'
for key in ['SURequireSignedFeed','SUVerifyUpdateBeforeExtraction','SUEnableAutomaticChecks']:
    assert info.get(key) is True, 'Missing updater safety setting: '+key
for key in ['SUAllowsAutomaticUpdates','SUAutomaticallyUpdate','SUSendProfileInfo']:
    assert info.get(key) is False, 'Unexpected updater automation/profile setting: '+key
framework=app+'/Contents/Frameworks/Sparkle.framework'
assert os.path.islink(framework+'/Versions/Current'), 'Framework symlinks were not preserved'
with open(framework+'/Versions/B/Resources/Info.plist','rb') as f: sparkle=plistlib.load(f)
assert sparkle.get('CFBundleShortVersionString')==config['sparkleVersion'], 'Wrong Sparkle version'
outer_signature=subprocess.run(['codesign','-dv','--verbose=4',app],capture_output=True,check=True).stderr.decode()
team=next((line for line in outer_signature.splitlines() if line.startswith('TeamIdentifier=')),None)
for relative in ['XPCServices/Installer.xpc','XPCServices/Downloader.xpc','Autoupdate','Updater.app','']:
    child=framework+'/Versions/B/'+relative if relative else framework
    assert os.path.exists(child), 'Missing Sparkle helper: '+relative
    subprocess.run(['codesign','--verify','--strict',child],check=True)
    signature=subprocess.run(['codesign','-dv','--verbose=4',child],capture_output=True,check=True).stderr.decode()
    assert team in signature.splitlines(), 'Nested Sparkle signing team differs'
linked=subprocess.run(['otool','-L',app+'/Contents/MacOS/Transcribe'],capture_output=True,check=True).stdout.decode()
assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in linked, 'Sparkle is not linked'
load_commands=subprocess.run(['otool','-l',app+'/Contents/MacOS/Transcribe'],capture_output=True,check=True).stdout.decode()
assert '@executable_path/../Frameworks' in load_commands, 'Missing bundled framework loader path'
PY
if $DISTRIBUTION; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
fi
if $LAUNCH; then
    if ! $FIXTURE && { pgrep -x Transcribe >/dev/null || pgrep -x TranscribeApp >/dev/null; }; then
        echo "Quit existing Transcribe instances before the isolated launch check." >&2
        exit 1
    fi
    tested_pid() {
        python3 - "$BIN" <<'PY'
import subprocess,sys
for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
    parts=line.strip().split(None,1)
    if len(parts)==2 and parts[1]==sys.argv[1]: print(parts[0])
PY
    }
    [ -z "$(tested_pid)" ] || { echo "The exact tested artifact is already running; preserved" >&2; exit 1; }
    # Exercise Launch Services as the user does, including launchd/Gatekeeper.
    # A direct executable launch would miss the original RBS launch failure.
    open -n "$APP"
    sleep 3
    PROBE_PID="$(tested_pid)"
    [ -n "$PROBE_PID" ] || { echo "Launch Services did not start the app" >&2; exit 1; }
    [[ "$PROBE_PID" =~ ^[0-9]+$ ]] || { echo "Multiple tested-artifact processes; preserved" >&2; exit 1; }
    [ "$(ps -p "$PROBE_PID" -o comm=)" = "$BIN" ] || {
        echo "The running process does not belong to the tested artifact" >&2; exit 1;
    }
    trap 'kill "$PROBE_PID" >/dev/null 2>&1 || true' EXIT
    kill -0 "$PROBE_PID" 2>/dev/null || { echo "Packaged app failed launch survival check" >&2; exit 1; }
    # A process can survive while its main thread is stuck before AppKit startup.
    # Require launch completion, not just an executable that remains alive.
    swift - "$PROBE_PID" <<'SWIFT'
import AppKit
guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid),
      app.isFinishedLaunching else {
    fputs("Packaged app did not finish AppKit startup\n", stderr)
    exit(1)
}
SWIFT
    kill -TERM "$PROBE_PID"
    trap - EXIT
fi
echo "App artifact checks passed → $APP"
