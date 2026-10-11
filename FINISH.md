# Operating and shipping Transcribe

The native two-mode implementation is tracked in [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md). The Python CLI and Windows distribution are separate.

## Current release readiness

The Developer ID identity available on this Mac is **Developer ID Application: ED4.ONE SpA (K542ZFQH6B)**. The existing Team token is provisioned and the owner reports working transcription and paragraph formatting. Apple notarization credentials are canonical in **Sebastian Work → Transcribe — Apple notarization**, username/password fields. The local `meetrec-notary` profile is provisioned and validated. Do not publish this version before final workflow verification and notarization. The owner handles real audio, formatting and paste acceptance; agents must not resume those tests without further instruction.

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

## Complete release when credentials are available

1. Verify real dictation pasting into the editable field focused when transcription completes, Escape recovery, paste-last, a controlled online/in-person meeting, notes generation and retry behavior. The existing Team token is already provisioned. Verify the direct OpenAI workflows separately when a real authorized key is available. Grant macOS recording/Accessibility permissions where needed. Do not print tokens or recorded private speech in logs.
2. Provision the existing `meetrec-notary` Keychain profile from the canonical Apple credentials. Do not pass passwords in shell history or store them in Git.
3. Run the local checks above against the final source revision, then:

   ```bash
   cd TranscribeBar
   NOTARY_PROFILE="meetrec-notary" ./scripts/notarize.sh
   ```

   The script notarizes/staples the app first, creates the DMG containing that stapled app, notarizes/staples the DMG, assesses both and launches the contained app from the mounted final installer. Accepted status and all gates are required.
4. Publish `TranscribeBar/build/Transcribe.dmg` to an explicit Mac tag matching the packaged app version, with release notes describing the two modes, connection options and permissions. Use a body file for the exact multiline notes. Do not use `/releases/latest` for Mac installation: Windows tags share this repository.
5. Download the published asset, mount it read-only, validate staples/signatures/Gatekeeper and launch the contained app. Update installation links to that explicit tag only once the release exists. Confirm fonts/icons without the build resources available.

The app version/build can be set with non-secret `APP_VERSION` / `APP_BUILD_NUMBER` when packaging. Distribution requires the explicit Developer ID identity. Do not ship an ad-hoc build as a notarized installer.
