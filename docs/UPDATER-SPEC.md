# In-app updates

Status: independently reviewed and refined before implementation, 2026-10-11. Material review decisions are recorded below.

## Outcome

An available macOS update appears as a small primary button above the sidebar version. One click downloads, installs and relaunches Transcribe into the previously visible screen. No second install confirmation or separate app update window. Native macOS authorization is allowed when required by filesystem permissions.

Design: https://www.figma.com/design/501FiwrHn8ZJlwbgzjTDly?node-id=72-567 . Reuse Circles semantic colors and Urbanist. Fixed 148 × 32 points; Actualizar → Descargando → Instalando. A small progress indicator occupies a stable slot. Honor Reduce Motion; announce state changes to accessibility without announcing every downloaded byte. Completed updates remove the button and show the installed bundle version. No added explanatory paragraphs.

While app work is active, Actualizar is visible but disabled. A failed attempted download/install offers Reintentar in the same location, retains the working app and releases the app-work lock. Background check failures remain quiet and retry on the next scheduled check. No raw updater diagnostics in the interface. An actionable permission problem may use a short local message; native administrator prompts remain native.

## Existing behavior and constraints

2.0.8 has no updater or package dependencies. The sidebar version is read from Bundle.main. AppModel.isBusy excludes manual paste, key verification, imports and independently generated meeting notes. Imports currently have no tracked task; summaryStatus.processing indicates note generation. The ordinary keyed launch remains menu-bar-only, and openLibrary resets Dictation. make-app.sh copies the executable/resources and signs the outer bundle; it does not package external frameworks/helpers.

Existing capture, dictation formatting, paste, credential storage, recording files and menu behavior must be preserved. No live audio, model calls, clipboard or paste acceptance tests by agents; the owner retains those tests.

## Implementation baseline

Use the established Sparkle 2 framework, initially pin 2.10.0 after confirming SwiftPM and macOS 13 compatibility. Use SPUUpdater with a custom SPUUserDriver rather than replacing application bundles ourselves. Sparkle handles archive validation, extraction, installation, any required authorization, process handoff and relaunch.

Enable scheduled HTTPS update checks, with no automatic download/install before the user clicks. Disable system-profile reporting and ordinary release-note/update windows. Feed URL is ordinary public configuration: https://raw.githubusercontent.com/brainforwarding/transcribe/master/docs/updates/appcast.xml . Use Sparkle’s native scheduler as the only scheduler. A background found-update callback records availability and immediately replies dismiss. A click starts a fresh interactive check, after confirming Sparkle.canCheckForUpdates and synchronously acquiring the app latch. It then automatically replies Install only for that accepted user cycle. Do not retain a background reply or introduce a second polling timer. Set SUAllowsAutomaticUpdates=false; disable profiling and release-note downloads. Only actionable compatible full app updates are offered; never automatically install information-only or unsupported major/paid upgrades. Keep callback lifetimes and shutdown/cancellation explicit.

The driver maps download callbacks to Descargando, with real bounded progress when content length is usable and a spinner otherwise. Extraction/installation map to Instalando. Ready-to-install automatically proceeds after a fresh idle/saved-edit check under the same user-initiated update latch. A failed durable save replies skip at this stage, cancelling the staged installation; dismiss is insufficient because Sparkle may install on a later quit. Each driver reply and error acknowledgment must run exactly once. Automatic relaunch is part of that click. Do not label a transfer complete before verification/install success.

AppModel exposes a single updater eligibility predicate covering startup/capture/stop/transcribe/formatting, summaries, imports, pending paste, credential verification and pending file dialogs. Add explicit task tracking only where absent. Clicking atomically acquires an update-in-progress latch before answering Install; all relevant launch commands consult it, including shortcuts, menu commands, retries, summaries, imports and provider changes. Ordinary UI navigation remains possible; content edits are frozen after acquiring the latch. Imports and summary tasks have explicit tracking. Deferred command bodies also check the latch. Existing work is not cancelled to obtain eligibility.

Before accepting the update and again at the install safe point, end editing and commit any pending title changes with an explicit durable-success result. A void updateTitle or status text is not a save acknowledgment. If a save cannot complete, do not close the app or overwrite its working bundle; return actionable local retry state. After the final save gate, record a small one-shot nonsecret resume marker for window visibility, sidebar and selected session UUID, expected target build and timestamp. Validate the UUID and target build on consumption, clear it once, and clear it on failed installation. Meeting-tab restoration is deferred. Do not serialize transcript text or credentials into the marker. On updater relaunch, consume the marker and reopen through the shared showLibraryWindow path, preserving the selected screen instead of the default-dictation menu action.

Bundle Sparkle's framework and required helpers into the installed application with correct loader paths. Preserve bundle ID, Developer ID identity, microphone entitlement and Keychain access. Sign nested executable code and the outer hardened-runtime bundle; notarize/staple the complete result and its DMG. Sparkle's Ed25519 archive signature and pinned public key supplement Developer ID verification. Do not disable signing validation, Gatekeeper or library validation.

## Secrets and publication

Generate a new update-signing key only if no established Transcribe key exists. The private key is a secret and must be canonical in Sebastian Work in a dedicated Transcribe updater signing item; only its public key, safe item/field references and feed configuration enter Git. Follow the repository's development-secrets policy; no private key in arguments, logs, fixtures or commits. Existing notarization profile and credentials remain unchanged. Verify fresh-machine recovery without plaintext copies.

Publish versioned notarized DMG and checksum to an explicit Mac GitHub release. Sign the exact final downloadable bytes for the appcast. Update docs/updates/appcast.xml only after the release asset exists and fresh public-download verification passes. The appcast contains macOS version/build/minimum OS, HTTPS asset URL, exact byte length and archive signature. Retain prior valid entries where useful. No dependency on Windows latest-release selection. Use build 11 as sparkle:version, marketing version separately, macOS minimum 13.0.0 and arm64 hardware requirements. Enable SUVerifyUpdateBeforeExtraction. Sign the feed with Sparkle’s established tools if supported by the pinned version; archive signatures and Developer ID validation remain mandatory.

2.0.8 needs one manual upgrade to acquire this updater. Subsequent updater-capable releases must be verified via a controlled actual update between isolated notarized fixtures or adjacent signed versions, using a dedicated temporary app/support/preferences environment. Never exercise an update by downgrading the owner's canonical app or altering its history. Separate static notarization from launch validation: current notarize.sh invokes owner-store launch checks twice. The test fixture must use a dedicated bundle identity, defaults/support/export directories and fake credential access, not merely a temporary bundle path. Validate only fixture processes. Offline fixtures alone cannot prove helper installation/relaunch.

## Acceptance

- No update: no button; scheduled failures do not interrupt normal work.
- Available: primary footer button in light/dark, stable layout, keyboard and accessibility support.
- One click drives download, validation, installation and automatic relaunch; repeated clicks do not duplicate a cycle.
- Every active-work guard disables installation; new work cannot race an accepted update.
- Failed download, bad signature, unsupported OS and cancellation preserve the previous working app and saved records, with one useful retry route when appropriate.
- After successful relaunch, the prior visible screen/selection is restored, old callback/session state is cleared, the version is correct and the button disappears for that release.
- Offline state/guard/callback tests, actual native compile, signed-framework resource verification, notarization/Gatekeeper, controlled installer/relaunch test and fresh production feed/asset checks pass.

References: https://sparkle-project.org/documentation/ , https://sparkle-project.github.io/documentation/custom-user-interfaces/ , https://sparkle-project.github.io/documentation/api-reference/Protocols/SPUUserDriver.html .

## Independent review decisions

Accepted the staged-save veto, native single scheduler, Sparkle readiness gate, explicit task tracking, mutation freeze, exactly-once callback ownership and genuinely isolated installer test. Resume metadata contains target build and a short validity window. Sparkle owns post-termination installation recovery; no bespoke rollback machinery. Deferred delta updates, channels, updater settings, persistent download recovery and meeting-tab restoration. Signed-feed support is verified against the pinned tools rather than introducing a custom signature format.
