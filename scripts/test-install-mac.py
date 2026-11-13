#!/usr/bin/env python3
"""Exercise the actual shell installer with fake OS/download/signature tools."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap

INSTALLER = Path(__file__).with_name("install-mac.sh").resolve()
SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
state=pathlib.Path(os.environ['INSTALL_FIXTURE_STATE'])
config=json.loads((state/'config.json').read_text())
with (state/'calls').open('a') as f: f.write(name+' '+json.dumps(args)+'\n')
failure=config.get('failure')
if name=='uname': print(config.get('arch','arm64') if '-m' in args else 'Darwin')
elif name=='sw_vers': print(config.get('os','13.0'))
elif name=='curl':
 if failure=='download': sys.exit(1)
 pathlib.Path(args[args.index('-o')+1]).write_text('fixture image')
elif name=='shasum':
 print(('bad' if failure=='checksum' else '2683c0c38f62fd510f86eb62df9aad92a03e865c9a7e42794d50c661d16aafcb')+'  '+args[-1])
elif name=='hdiutil':
 if args[0]=='attach':
  if failure=='mount': sys.exit(1)
  mount=pathlib.Path(args[args.index('-mountpoint')+1]); (state/'mounted').write_text(str(mount))
  if failure=='partial-mount': sys.exit(1)
  app=mount/'Transcribe.app'/'Contents'; app.mkdir(parents=True); (app/'fixture').write_text('signed fixture')
 elif failure in ('detach','partial-mount') or not (state/'mounted').exists(): sys.exit(1)
 else: (state/'mounted').unlink()
elif name=='mount':
 if (state/'mounted').exists(): print('/dev/fixture on '+(state/'mounted').read_text()+' (hfs, read-only)')
elif name=='codesign':
 assert args[args.index('--test-requirement')+1].startswith('=anchor apple generic')
 assert 'K542ZFQH6B' in args[args.index('--test-requirement')+1]
 if failure=='signature': sys.exit(1)
elif name=='defaults': print('9.9.9' if failure=='version' else '2.1.0')
elif name=='spctl':
 if failure=='gatekeeper': sys.exit(1)
elif name=='ditto':
 target=pathlib.Path(args[1])
 if failure=='copy': target.mkdir(); (target/'partial').write_text('partial'); sys.exit(1)
 if failure=='interrupt':
  target.mkdir(); os.kill(os.getppid(),15); sys.exit(1)
 shutil.copytree(args[0],target)
elif name=='mv':
 if failure=='race':
  target=pathlib.Path(args[-1])/'Transcribe.app'; target.mkdir(); (target/'original').write_text('keep')
 sys.exit(subprocess.run(['/bin/mv']+args).returncode)
else: raise AssertionError(name)
'''


def run_case(name, config=None, existing=None, succeeds=False, stdin=False):
    with tempfile.TemporaryDirectory(prefix="transcribe-installer-test-") as directory:
        root = Path(directory)
        user, system, temporary, tools = (root / part for part in ("user", "system", "temp", "tools"))
        for path in (user, system, temporary, tools):
            path.mkdir()
        (root / "config.json").write_text(json.dumps(config or {}))
        shim = tools / "shim"
        shim.write_text(textwrap.dedent(SHIM))
        shim.chmod(0o700)
        for command in ("uname", "sw_vers", "curl", "shasum", "hdiutil", "mount", "codesign", "defaults", "spctl", "ditto", "mv"):
            (tools / command).symlink_to(shim)
        target = user / "Applications" / "Transcribe.app"
        if existing == "system":
            (system / "Transcribe.app").mkdir()
        elif existing == "user":
            target.mkdir(parents=True)
            (target / "original").write_text("keep")
        elif existing == "app-symlink":
            target.parent.mkdir()
            target.symlink_to(root / "missing")
        elif existing == "parent-symlink":
            (user / "Applications").symlink_to(system)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(temporary), INSTALL_FIXTURE_STATE=str(root))
        # Source the installer and supply fixture application folders; never repurpose HOME.
        command = ["/bin/bash"] if stdin else ["/bin/bash", "-c", 'source "$1"; install_transcribe "$2" "$3"',
                                                "fixture", str(INSTALLER), str(user), str(system)]
        result = subprocess.run(command, input=INSTALLER.read_text() if stdin else None,
                                env=env, text=True, capture_output=True, timeout=20)
        assert "unbound variable" not in result.stderr, (name, result.stderr)
        if stdin:
            assert "requires an Apple Silicon Mac" in result.stderr
        assert (result.returncode == 0) == succeeds, (name, result.stdout, result.stderr)
        calls = (root / "calls").read_text() if (root / "calls").exists() else ""
        if succeeds:
            assert (target / "Contents" / "fixture").exists()
            assert "Installed at" in result.stdout and "open " in result.stdout
            assert calls.count("codesign ") == 2 and calls.count("spctl ") == 2
        elif not existing and (config or {}).get("failure") != "race":
            assert not target.exists(), (name, "Partial installation remained")
        if existing:
            assert "curl " not in calls, "Existing apps must be detected before download"
        if existing == "user" or (config or {}).get("failure") == "race":
            assert (target / "original").read_text() == "keep"
        assert not list(user.glob("Applications/.transcribe-install.*")), ("Destination staging leaked", result.stderr)
        leftovers = list(temporary.iterdir())
        if (config or {}).get("failure") in ("detach", "partial-mount"):
            assert leftovers and "preserved" in result.stderr
        else:
            assert not leftovers, (name, "Temporary files leaked")
        print("PASS", name)


if __name__ == "__main__":
    run_case("verified fresh installation", succeeds=True)
    for existing in ("system", "user", "app-symlink", "parent-symlink"):
        run_case("refuse " + existing, existing=existing)
    run_case("unsupported hardware", {"arch": "x86_64"})
    run_case("unsupported OS", {"os": "12.7"})
    for failure in ("download", "checksum", "mount", "partial-mount", "signature", "version", "gatekeeper", "copy", "interrupt", "race", "detach"):
        run_case(failure, {"failure": failure})
    # The documented curl | bash entry point must not silently become a no-op.
    run_case("stdin entry point", {"arch": "x86_64"}, stdin=True)
    print("Installer fixtures passed without touching installed apps.")
