#!/usr/bin/env python3
"""Exercise actual provisioning mechanics with a public synthetic seed and fake op.

No real 1Password, Keychain, app preferences or owner files are accessed.
"""
import base64, json, os, pathlib, shutil, subprocess, tempfile

SOURCE=pathlib.Path(__file__).resolve().parent.parent
passed=0
with tempfile.TemporaryDirectory(prefix='transcribe-secrets-selftest-') as temporary:
    root=pathlib.Path(temporary); (root/'scripts').mkdir(); (root/'.dev-secrets').mkdir()
    (root/'TranscribeBar/scripts').mkdir(parents=True)
    shutil.copyfile(SOURCE/'scripts/dev-secrets',root/'scripts/dev-secrets')
    shutil.copyfile(SOURCE/'.dev-secrets/updater-signing.json',root/'.dev-secrets/updater-signing.json')
    (root/'.gitignore').write_text('TranscribeBar/.secrets/\n')
    subprocess.run(['git','init','--quiet',str(root)],check=True)
    # Intentionally public fixed test material. Never an application credential.
    seed=base64.b64encode(bytes(range(32))).decode()+'\n'
    probe=root/'public.swift'
    probe.write_text('import Foundation\nimport CryptoKit\nlet seed=Data(base64Encoded:String(data:FileHandle.standardInput.readDataToEndOfFile(),encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines))!\nprint(try Curve25519.Signing.PrivateKey(rawRepresentation:seed).publicKey.rawRepresentation.base64EncodedString())\n')
    public=subprocess.run(['swift',str(probe)],input=seed.encode(),capture_output=True,check=True).stdout.decode().strip()
    config=json.loads((SOURCE/'TranscribeBar/scripts/updater-config.json').read_text()); config['publicKey']=public
    (root/'TranscribeBar/scripts/updater-config.json').write_text(json.dumps(config))
    fake=root/'bin'; fake.mkdir()
    op=fake/'op'
    op.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(__file__).resolve().parent.parent
if os.environ.get('FIXTURE_DENY')=='yes': sys.exit(1)
if sys.argv[1]=='read': sys.stdout.write((root/'canonical.seed').read_text())
elif sys.argv[1:3]==['item','list']: print(json.dumps([{'title':'Transcribe — Update signing'}] if (root/'canonical.seed').exists() else []))
elif sys.argv[1:3]==['item','create']:
    payload=json.load(sys.stdin); value=next(f['value'] for f in payload['fields'] if f['id']=='credential')
    (root/'canonical.seed').write_text(value+'\\n'); print('{}')
else: sys.exit(1)
'''); op.chmod(0o700)
    environment=dict(os.environ,PATH=str(fake)+os.pathsep+os.environ['PATH'])
    def run(*arguments,expected=0,denied=False):
        env=dict(environment)
        if denied: env['FIXTURE_DENY']='yes'
        result=subprocess.run(['python3',str(root/'scripts/dev-secrets'),*arguments],env=env,capture_output=True)
        assert result.returncode==expected, 'Unexpected command result (output intentionally withheld)'
        assert seed.strip().encode() not in result.stdout+result.stderr, 'Fixture material appeared in output'
    run('status'); passed+=1
    private=root/'export'; private.mkdir(mode=0o700); export=private/'seed'; export.write_text(seed); export.chmod(0o600)
    run('canonicalize-new-updater',str(export)); passed+=1
    target=root/'TranscribeBar/.secrets/updater-signing.seed'
    assert target.read_text()==seed and target.stat().st_mode&0o777==0o600; passed+=1
    run('status'); passed+=1
    run('canonicalize-new-updater',str(export),expected=1); passed+=1
    original=target.read_bytes(); run('refresh',expected=1,denied=True); assert target.read_bytes()==original; passed+=1
    target.write_text('unmanaged-change\n'); run('refresh',expected=1); assert target.read_text()=='unmanaged-change\n'; passed+=1
    target.unlink(); target.symlink_to(export); run('refresh',expected=1); assert target.is_symlink(); passed+=1
print(f'{passed} updater-secrets fixture checks passed; no real credential services accessed')
