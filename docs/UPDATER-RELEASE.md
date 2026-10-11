# macOS updater release tooling

Sparkle is pinned to 2.10.0 in `TranscribeBar/Package.swift` and `Package.resolved`. Public feed, public signing key and pinned tool checksum live in `TranscribeBar/scripts/updater-config.json`. The framework is embedded with preserved symlinks and an executable-relative loader path. Packaging signs its four helper components, the framework, then the hardened-runtime app with the same identity. It never disables library validation or adds a restricted Keychain entitlement.

## Signing environment

The private Ed25519 seed is canonical at `op://Sebastian Work/Transcribe — Update signing/credential`. The safe schema is `.dev-secrets/updater-signing.json`. A fresh authorized machine runs `scripts/dev-secrets provision`, then `scripts/dev-secrets status`. Provisioning privately validates the seed against the pinned public key and writes only ignored, untracked, owner-only files under `TranscribeBar/.secrets/`. Ordinary packaging and signing commands consume those files; they do not refresh 1Password or authorize it automatically. `status` is offline and checks metadata only.

Initial canonical creation is still pending write-capable 1Password access as of implementation. The known newly generated scoped key and protected export are preserved. `scripts/dev-secrets canonicalize-new-updater protected-export-path` is an explicit one-time creation command, not part of normal provisioning. It refuses an existing item, validates the public key, creates through private stdin, privately compares recovered material and then provisions. No existing signing, notarization or team credential is changed. Do not claim fresh-machine recovery until this command succeeds and canonical recovery is verified.

## Distribution and feed

After reviewed source freeze, build with `TranscribeBar/scripts/make-app.sh release`. `TranscribeBar/scripts/verify-app.sh app-path` performs static resources, loader, framework and signature checks. Run an immutable copy of `notarize.sh` from the same directory depth under `TranscribeBar/build/`; it notarizes/staples the app before constructing, signing and notarizing/stapling the DMG. These steps do not launch Transcribe or use its store. Launch checks are separate, explicit operations after an idle-safe owner handoff.

Publish the exact final DMG to the explicit macOS release first. Then run:

```sh
TranscribeBar/scripts/prepare-appcast.sh final/Transcribe.dmg 2.0.9 11
```

This downloads the public asset without printing redirect metadata, compares its bytes to the notarized artifact, uses pinned Sparkle tooling to generate signed XML, verifies both feed and archive signatures, and checks version/build, byte count, macOS minimum and arm64 hardware requirements. It retains existing feed entries and disables deltas. The candidate lives under ignored build output. Publish that exact XML to `docs/updates/appcast.xml` only after inspection and public-asset verification; subsequent edits invalidate its embedded signature. The helper does not publish or overwrite a checked-in feed.

## Isolated installation proof

Do not downgrade the owner's app to test updates. Build adjacent validation versions with `TRANSCRIBE_VALIDATION_FIXTURE=true`, explicit loopback HTTP `UPDATER_FIXTURE_FEED_URL`, a shared unique `UPDATER_FIXTURE_ID=com.sebastianmarambio.transcribe.updatefixture.uniqueid`, a protected absolute `TRANSCRIBE_VALIDATION_ROOT`, and different build numbers. Both fixtures share that dedicated identity and persistent root. The compile-time fixture bootstrap must use separate persistent defaults/support/export paths, fake credential access and offline feature operations across relaunch. Its app delegate skips shortcuts, permission prompts and capture UI. Only this fixture gets an ATS local-networking exception; production keeps its HTTPS feed and mandatory signatures. A temporary app path or environment override alone does not provide this isolation.

`verify-app.sh fixture-path --fixture` performs static validation; `notarize.sh fixture-path --fixture` performs distribution work without launching. `verify-app.sh fixture-path --distribution --launch-fixture` additionally requires the dedicated identity and persistent fixture marker. Only fixture processes are launched or stopped. An actual one-click update between notarized fixture versions must prove download, helper installation, target version, automatic relaunch, resume selection and removal of the update button. Preserve the working fixture on failures. Bad signatures and unsupported updates must preserve the old version. No microphone, model, clipboard or owner-history acceptance tests belong in this proof.
