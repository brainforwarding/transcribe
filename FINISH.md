# Operating and shipping Transcribe

The native two-mode implementation is tracked in [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md). The Python CLI and Windows distribution are separate.

## Current release

The Developer ID identity available on this Mac is **Developer ID Application: ED4.ONE SpA (K542ZFQH6B)**. The existing Team token is provisioned and the owner reports working dictation and paragraph formatting. Apple notarization credentials are canonical in **Sebastian Work → Transcribe — Apple notarization**, username/password fields. The local `meetrec-notary` profile is provisioned and validated. [Mac 2.0.9 is published](https://github.com/brainforwarding/transcribe/releases/tag/v2.0.9), with source freeze `7270b2248da56ffb476978f73c0edddb962f49c4`. The app and installer passed signing, notarization, stapling and Gatekeeper. A fresh unauthenticated download matches the notarized artifact and passes mounted-app startup. The exact2.0.9 app is installed locally with history/settings preserved; the previous app is backed up. Actual isolated Sparkle installation and automatic relaunch passed, including bad-signature rejection and retry; history and navigation survived. The production signed feed is verified at `docs/updates/appcast.xml`. Subsequent versions require their own distribution checks. The owner handles real audio, formatting and paste acceptance; agents must not resume those tests without further instruction.

Development secrets are canonical in 1Password. App tokens go into the existing macOS Keychain service/account through Settings. Do not copy plaintext environment files between computers or replace production worker secrets to create a test token. Existing credential rotation, scope changes or production changes require explicit human approval.

## Authentication

Settings offers **OpenAI** for a person's own API key and **Team** for the existing Cloudflare proxy. Fresh installs default to OpenAI; existing installations retain Team. Credentials use separate Keychain accounts and fixed provider endpoints defined in `TranscribeBar/Sources/TranscribeApp/Config.swift`. The legacy Team account is preserved. Checking a direct key establishes dictation-model access only; exercise transcription, diarization and summaries with an actual authorized OpenAI account before claiming full direct-provider verification.

The proxy's OpenAI API key remains server-side. Its default rate is 120 requests/person/hour. Version 2.0.6 adds `gpt-6-luna` to its chat-model allowlist for native dictation formatting; existing models, credentials, bindings and the rate limit remain unchanged. A dictation normally uses one transcription request and one formatting request.

## Local validation

From `TranscribeBar`:

```bash
swift run transcribe-core selftest
./scripts/test-native.sh
./scripts/test-coordinator.sh
SIGN_IDENTITY="Developer ID Application: ED4.ONE SpA (K542ZFQH6B)" ./scripts/make-app.sh release
./scripts/verify-app.sh build/Transcribe.app --launch
```

Quit other Transcribe instances before the isolated launch check. Verify the app again after relocating it away from the SwiftPM build tree so missing bundled fonts/icons cannot be masked by development resources. The launch check uses Launch Services, requires completed AppKit startup and confirms the process belongs to the tested app.

The unnecessary restricted `keychain-access-groups` entitlement has been removed. The existing bundle ID, Keychain service/account, Hardened Runtime and microphone entitlement remain. No provisioning profile is needed for these file-based Keychain operations.

## Future public releases

1. Coordinate owner-controlled workflow acceptance for future releases. Verify real dictation pasting into the editable field focused when transcription completes, Escape recovery, paste-last, a controlled online/in-person meeting, notes generation and retry behavior. The existing Team token is already provisioned. Verify the direct OpenAI workflows separately when a real authorized key is available. Grant macOS recording/Accessibility permissions where needed. Do not print tokens or recorded private speech in logs.
2. On this Mac, `meetrec-notary` is already provisioned and validated. On a fresh Mac, provision it from the canonical Apple credentials through the secure interactive prompt. Do not pass passwords in shell history or store them in Git.
3. Run the local checks above against the final source revision, then notarize the explicit production app path. The default build folder may contain an isolated updater fixture.

   ```bash
   cd TranscribeBar
   NOTARY_PROFILE="meetrec-notary" ./scripts/notarize.sh /absolute/path/to/production/Transcribe.app
   ```

   The script notarizes/staples the app first, creates and Developer ID signs the DMG containing that stapled app, notarizes/staples the DMG, and assesses both and the mounted contained app without launching. Accepted status and all gates are required. Actual startup is a separate check after proving the owner's app is idle and quitting it normally.
4. Publish the exact final production DMG to an explicit Mac tag matching the packaged app version, with release notes describing the two modes, connection options and permissions. Use a body file for the exact multiline notes. Do not use `/releases/latest` for Mac installation: Windows tags share this repository.
5. Download the published asset, compare its bytes, mount it read-only and validate staples/signatures/Gatekeeper. Perform idle-safe contained-app startup, then unmount and restore the canonical app. Update installation links only once the release exists. Confirm fonts/icons without the build resources available.
6. Follow [the updater release instructions](docs/UPDATER-RELEASE.md): generate the signed feed only after public asset verification, copy its exact signed bytes to Git, push and verify the public feed. Preserve the canonical signing key in 1Password; do not rotate it during ordinary releases.

The app version/build can be set with non-secret `APP_VERSION` / `APP_BUILD_NUMBER` when packaging. Distribution requires the explicit Developer ID identity. Do not ship an ad-hoc build as a notarized installer.
