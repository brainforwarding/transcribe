# Installation and dictation usability

Status: design drawn before implementation, 2026-10-20. Reviewed by GPT-6.1 Sol at high reasoning effort before implementation.

## Outcome

A new user can install Transcribe, find it through the Dock and Command–Tab, test a shortcut, and verify a sentence appears in another app. Failed delivery explains the next action while preserving the transcript. The brother's installed version, target editor and permission state are unknown; no root cause is claimed from his screenshot.

## Design

Editable Circles/Urbanist proposal in the existing Figma file: [light](https://www.figma.com/design/501FiwrHn8ZJlwbgzjTDly?node-id=117-212), [dark](https://www.figma.com/design/501FiwrHn8ZJlwbgzjTDly?node-id=117-319). Existing preference rows, picker, switch, buttons and 34-point chips are reused with semantic theme bindings. Proposal examples show mutually exclusive runtime states together. Existing shipped designs and unrelated pending changes remain intact.

## Installation

README begins with the existing signed Mac download, minimum OS/hardware and drag-to-Applications instruction. Above demos, expose two secondary copyable blocks: a Bash command invoking the repository installer and an agent instruction linking to public installation documentation. GitHub Markdown code blocks supply native copy affordances; no website or additional product UI is needed.

Installer uses the explicit Mac release, never GitHub's ambiguous latest release (the repository also ships Windows). Require Apple Silicon and macOS 13+, download to a private temporary directory, mount the DMG read-only, verify bundle identity, Developer ID signature and Gatekeeper acceptance before installation. Install into ~/Applications without sudo. Pin release SHA256 2683c0c38f62fd510f86eb62df9aad92a03e865c9a7e42794d50c661d16aafcb and publisher Team ID K542ZFQH6B. Refuse an existing app or symlink in either /Applications or ~/Applications, and a symlinked destination parent; direct existing users to the app's updater. Copy and reverify in a private staging directory on the destination filesystem, then publish with a no-overwrite move. Clean only owned staging paths. On failed detach, preserve the mount directory and report its path rather than recursively deleting mounted content. Success prints the installed path and a user-controlled open instruction. Never bypass quarantine, grant permissions, read credentials, or launch a source build. Agent instructions use the same installer and stop at user-controlled connection/permission setup. Publication is separate; local verification must not install over or launch the owner's app.

## Dock

Default Show in Dock to true, including existing users without a saved preference. Persist the explicit choice. Use regular activation policy when true and accessory when false; keep menu-bar controls in both modes. Retain reopening the existing library window and background operation after closing the window. Do not activate Transcribe when a global dictation shortcut runs. Change bundle metadata consistently with the default and test that window reopening still works.

## Shortcuts and permission recovery

Retain double Option to start, single Option to finish the current dictation, Escape to cancel, and optional Option–Shift–V to paste last. Fn is unsupported and must not be presented as supported. Add an Additional shortcut picker with Control–Option–Space (default), Control–Shift–Space and Off. The same chord starts from idle and finishes the exact capturing session. Ignore repeats, consume its matching key-up, require exact modifiers, respect disabled/busy contexts, invalidate pending Option taps when configuration or context changes, and bind queued actions to their original session. Recognized additional chords consume their key events to avoid modifying the target app.

Check dictation appears in setup and Settings using the same view. Model-owned Test shortcut arms a bounded ten-second listener; intercept only double Option or the selected chord before production callbacks, not Escape or paste-last; successful detection shows Shortcut detected without recording or pasting. Repeated clicks replace the prior timeout, navigation/disappearance, permission loss, configuration changes and recording/update work cancel testing and invalidate pending recognizers. An epoch rejects queued actions crossing test or configuration boundaries. Permission granted with no listener displays Shortcuts unavailable and offers Retry shortcuts. Timeout explains that the shortcut was not detected and points to permission setup. Permission and listener readiness remain separate from observed key detection. Reconcile the event tap after app activation and permission changes, invalidate it on revoked access, and retry when access returns. Do not automatically request permission in a loop.

The next instruction asks users to open a text field in another app, dictate a sentence and return. Text appeared records the user's explicit confirmation as Dictation checked. This confirmation persists across relaunch and resets when shortcut configuration changes. Return explicitly to Settings → Check dictation because setup may disappear after completing connection or recording. This is an optional manual check, never a claim that permission toggles prove delivery, and never a setup blocker.

## Paste behavior and feedback

Preserve durable-save-before-delivery, current completion-time caret targeting, cancellation/session checks, secure/read-only field exclusions, clipboard ownership preservation, terminal newline sanitization and no Return key. Do not loosen target validation or introduce blind retries based on this screenshot. Extend clearly supported editable roles only with positive editability evidence and regression tests.

Represent UI delivery feedback independently of free-form reason wording: permission needed, select a field, unconfirmed paste, other saved-text failure. Keep original detailed reason for history and hover/accessibility help. The existing ready chip shows Enable Accessibility (292 pt; clicking opens Accessibility settings), Select a text field (264 pt), Check paste (216 pt), or Ready (152 pt). All remain 34 pt tall with explicit Copy. Check paste means a shortcut was sent but insertion is unverified; never retry/copy automatically. Other saved-text failures use Ready with their detailed reason. Reset feedback on new capture and successful paste. Permission loss detected before dispatch produces permission feedback; after dispatch any unverified result stays unconfirmed. Copy targets the saved record associated with the displayed chip, including manual delivery. No additional modal, banner or automatic focus switching.

## Validation and limits

Run native recognizer/paste tests and coordinator tests against production sources, compile the actual app, and test installer failure/cleanup behavior using controlled fixtures. Cover chord modifiers, repeats/releases, session transitions, dry-run detection, preference defaults, permission-recovery logic, feedback distinctions and clipboard/cancellation regressions. Visually inspect light/dark Figma proposals and native views in an isolated fixture if available. Do not alter the owner's permission database, history, credentials, installed application or production release/feed. Document any interactive shortcut/paste matrix that could not be exercised; pure tests do not prove operation in the brother's specific editor.

## Review

GPT-6.1 Sol high reviewed the spec against production sources. Accepted all six findings: stable Settings destination and model state; precise dry-run interception with queued-action epochs; duplicate-install and publisher checks; destination-filesystem staging and interruption handling; actual listener validity/readiness; typed feedback and record-bound Copy. Also specified persistent manual confirmation/reset and that the installer initially downloads released 2.1.0 behavior. Publishing the installer and a new signed app release remains separate from local implementation.

## Implementation and verification

Implemented in the working tree. A follow-up review by the same model found one mount-cleanup edge case; cleanup now checks actual mount evidence, with fixtures for both an unattached image and a partial attachment that cannot unmount. No other concrete issues were reported in the bounded implementation review.

Passed on 2026-10-20:

- Native app build with the current production sources.
- 113 native shortcut, dry-run, clipboard and paste checks, without creating a system event tap or posting synthetic keys.
- All coordinator lifecycle checks, including preferences, manual confirmation, typed feedback, capture/update cancellation and session-bound Copy.
- 30 offline updater state, callback, save-gate and resume checks.
- 19 installer fixtures, including checksum/signature rejection, existing app/symlink, destination race, interrupted copy, failed mount, partial attachment, failed detach and the stdin entry point.
- The actual installer publisher-requirement expression, pinned version and Gatekeeper assessment against the downloaded public DMG, mounted read-only. No installation or app launch.
- Editable light/dark Figma compositions, Urbanist assertions, zero complete-UI images; native offscreen Settings, check and chip renders inspected in both themes.
- Git whitespace validation.

Existing Keychain and Sparkle deprecation warnings remain. No new release, appcast change, owner installation replacement, permission grant, live transcription call or interactive editor insertion was performed. Actual Command–Tab/Dock behavior, fresh TCC grant/revoke recovery and the brother's exact editor remain manual integration checks; the automated checks and offscreen renders do not establish those outcomes. Public installation links to the new script/instructions become usable after these repository changes are published. The existing direct DMG link remains usable now.
