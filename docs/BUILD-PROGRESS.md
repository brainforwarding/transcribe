# Transcribe app — build progress (COMPLETE through the credential-free scope)

Built autonomously per the v4 spec (`docs/menubar-app-spec.md`). The Python CLI
(`meetrec.py`) is untouched and still works. Finish steps for you: **`FINISH.md`**.

## Status
- [x] **§13.1 Core** — Segment/Merge/Render/Transcriber/Segmenter/Pipeline. Merge port
      validated (`swift run transcribe-core selftest`). GO/NO-GO gate PASSED (AVFoundation
      16 kHz mono m4a accepted by Whisper; full transcribe→merge validated on real tracks).
- [x] **§13.2 Native capture** — SystemAudioCapture (folded SCK) + MicCapture
      (AVCaptureSession by uniqueID, format-drift guarded) + CaptureController. Validated:
      6 s capture → system.wav + mic.caf, sample-accurate **micOffset 0.295 s** from PTS.
- [x] **§13.3 App UI** — SwiftUI MenuBarExtra (AppModel state machine; permission pills with
      SCShareableContent probe + CGRequestScreenCaptureAccess + relaunch; mic/language
      pickers; Keychain key; consent onboarding; record→transcribe→reveal; error states;
      summary). Bundles into **Transcribe.app**, ad-hoc signed, **launches as a menu-bar app**
      (verified) — built entirely with Command Line Tools, no Xcode.
- [x] **§13.4 Proxy** — `proxy/worker.js` (allowlist, per-user rate-limit, header-strip, no
      audio logging, sanitized errors) + `wrangler.toml` + deploy runbook. Optional; the app
      defaults to per-user Keychain key (proxy seam wired via `Config.proxyBaseURL`).
- [x] **§13.5 Package** — generated `AppIcon.icns`; `scripts/make-app.sh` (ad-hoc + Developer
      ID), `scripts/notarize.sh` (DMG + notarytool + staple), `FINISH.md`.

## Remaining = your async finish steps (see FINISH.md)
1. Create the Developer ID Application cert + `notarytool store-credentials`, then
   `make-app.sh release` + `notarize.sh` → `build/Transcribe.dmg` to share.
2. (Optional) deploy the Cloudflare proxy for shared-key SSO.
3. First-run eyeball test: grant the 2 permissions, relaunch, Record.

## Known notes
- Mic list uses AVCaptureDevice discovery (listed 7 real devices; your Logi headset was
  unplugged during testing). If a plugged device is ever missing, add a Core Audio fallback.
- The proxy's SSO sign-in flow (ASWebAuthenticationSession) is the one piece left for the
  shared-key mode; per-user-key mode is complete.
