# Spec v4: Transcribe — native menu-bar app (definitive)

Status: REVIEWED ×2, ready to build · Date: 2026-06-05 · Supersedes all prior drafts.

## 0. Decisions locked
- **Fully native Swift** app. No bundled Python, no ffmpeg. (Signing = the app's own 1
  binary.)
- **Auth default = shared-key proxy** behind Cloudflare Access SSO. The OpenAI org key
  lives only in the Worker; coworkers sign in, no key on their machine. (Per-user key is a
  later optional fallback, not in v1.)
- **Diarize is CUT from v1.** Mic = "You", system = "Them", plain whisper-1 both tracks,
  merged. (Diarize + its guards return post-v1.)
- **The Python CLI (`meetrec.py` + SystemAudioRecorder) is UNCHANGED and keeps working.**
  This app is a new, separate, additive artifact that re-implements the proven logic in
  Swift. Same OpenAI account.

## 1. Goal
A `.app` a coworker double-clicks → sign in (company SSO) → grant 2 permissions → pick mic
+ language → Record → `transcript.md` (merged **You/Them** conversation + verbatim
appendix). Codesigned + notarized.

## 2. Architecture (all Swift)
```
Transcribe.app  (SwiftUI MenuBarExtra, LSUIElement)
 ├─ AppModel (@MainActor ObservableObject): state machine, timer, settings  [owns state, not the popover view]
 ├─ Capture:  SystemAudioRecorder (SCK, folded from main.swift) + MicRecorder (AVCaptureSession)
 ├─ Segmenter (AVAssetReader → AVAssetWriter): mono 16 kHz m4a chunks + PTS offsets
 ├─ Transcriber (URLSession multipart → proxy → OpenAI whisper-1 verbose_json)
 ├─ Merge (pure Swift port of merge_segments) → transcript.md
 └─ Auth: Cloudflare Access SSO → short-lived JWT (Keychain); proxy injects the org key
```
Only Mach-O to sign: the app.

## 3. Behaviour contract — port from meetrec.py (match exactly; NO diarize in v1)
Reference functions are the spec:
- **Per-track** (`transcribe_track_whisper`): whisper-1, `response_format=verbose_json`,
  `timestamp_granularities=["segment"]`, `language` (omit if nil). Keep `{start,end,text}`;
  drop empty text; drop silence-hallucinations (`no_speech_prob>0.6 && avg_logprob<-1`;
  both fields optional → default 0.0, so a missing field KEEPS the segment). Global time =
  `base_offset + chunk_offset + seg.start` (mic `base_offset = mic_offset`, system `0`),
  all in **Double**, same op-order as Python, no pre-compare rounding.
- **Merge** (`merge_segments`): drop empties, clamp `end≥start`, sort by
  `(start, source, end, idx)` where **idx is an input-order tiebreak** appended when
  building `mic_segs ++ sys_segs` (Swift sort is NOT stable — this makes it deterministic);
  `source` compared as enum rank (mic=0, system=1), not localized strings. Coalesce
  **sorted-adjacent** same-label when `next.start − cur.end ≤ 1.5` (inclusive); join text
  with single space; never group-by-label.
- **Render:** `[mm:ss] **Label:** text`, blocks joined by `\n\n`; `_mmss` uses
  round-half-to-even (`t.rounded(.toNearestOrEven)`). Appendix = verbatim per-track text,
  always present when both tracks exist. Single track present → render that track only.
- **Chunking:** mono 16 kHz m4a, ≤`CHUNK_SECONDS` (20 min); skip chunks below a re-tuned
  empty threshold (check asset frame count/duration, not the ffmpeg-tuned 1 KB byte size);
  25 MB cap (assert).
- **Per-chunk failure = continue** (log, keep going, partial transcript) — match the Python
  whisper path exactly.
A Swift unit-test suite mirrors the Python `merge_segments` tests (incl. ties, equal-start
mic-before-system, 1.5 s boundary inclusive, x.5 banker's rounding).

## 4. Auth + proxy (default path)
- **App side:** on first run / token expiry, open `ASWebAuthenticationSession` to the
  Cloudflare Access login (company OIDC) → obtain a short-lived JWT → store in **Keychain**
  (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`,
  **`…ThisDeviceOnly`**); send as `Authorization: Bearer <JWT>` to the proxy. `baseURL` is a
  **hardcoded build constant** (not user-editable).
- **Worker (Cloudflare):** behind Cloudflare Access (OIDC, company domain). Allowlist
  exactly `POST /v1/audio/transcriptions` (multipart, model=whisper-1) and
  `POST /v1/chat/completions` (json, model allowlist, for the summary). Verify the Access
  JWT; per-user rate-limit (Workers KV); **strip all inbound headers**, inject the org key
  server-side; **never log audio**; sanitized errors (never echo the key); ~25 MB body cap.
  Offboard = remove from Access policy; rotate = `wrangler secret put`. Apply OpenAI **ZDR**.
- Net layer is a single `(baseURL, authHeader)` provider so a per-user-key build is a later
  drop-in.

## 5. Capture (native; panel must-fixes baked in)
- **System:** fold `main.swift`'s SCK recorder into the app target. One process owns Screen
  Recording; `await recorder.stop()` finalises; the first-buffer signal is an in-process
  callback (drop the stdout READY line). Keep the buffers/non-silent diagnostics.
- **Mic:** **AVCaptureSession** (NOT AVAudioEngine — it can't select a non-default device
  without fragile AUHAL reach-around). `AVCaptureDeviceInput(device:)` resolved from the
  stored **`uniqueID`** + `AVCaptureAudioDataOutput` → `AVAssetWriter`. Enumerate with
  `AVCaptureDevice.DiscoverySession`; show `localizedName`; fall back to default + warn if
  the device vanished. ⚠️ **First-buffer format drift:** AVCaptureSession's first
  CMSampleBuffer can be 24-bit then 32-bit later → set `AVAssetWriterInput(sourceFormatHint:)`
  explicitly or discard buffers until the format stabilizes (else silent corruption).
- **Offset (sample-accurate):** `mic_offset = micFirstBufferPTS − systemFirstBufferPTS` on
  the **host-time clock** (`CMClockGetHostTimeClock`); compare PTS-to-PTS only (don't mix
  `CACurrentMediaTime`). Retires the CLI's `FFMPEG_OPEN_LAG` fudge.
- **Raw format:** capture to **CAF** (crash-resilient header, no 4 GB WAV cap), not WAV.
- **Segmenting:** **AVAssetReader → AVAssetWriter** (NOT AVAssetExportSession — preset-locked,
  can't do 16 kHz mono). Reader = LinearPCM; writer input =
  `{kAudioFormatMPEG4AAC, 16000 Hz, 1 ch, 64 kbps}` (AudioConverter does SRC+downmix; set
  high-quality SRC). Rotate to a new writer every `CHUNK_SECONDS` of PTS; chunk offset =
  first buffer PTS of each chunk (exact, not `n×CHUNK_SECONDS`). Output `.m4a` (MPEG-4),
  never raw `.aac`.

## 6. Transcription net layer (URLSession)
- Multipart `POST /v1/audio/transcriptions`: parts `model=whisper-1`,
  `response_format=verbose_json`, **`timestamp_granularities[]=segment`** (literal brackets,
  one part), `language=<lang>` (only if set), `file` (`filename="chunk_000.m4a"`,
  `Content-Type: audio/mp4`). Body in memory (≤~10 MB/chunk).
- **Codable (verbose_json):** `segments: [Seg]?` (nil→[]); `Seg{start:Double, end:Double,
  text:String?, avg_logprob:Double?, no_speech_prob:Double?}` (optionals → 0.0). `language`,
  `duration` optional.
- **Errors:** 401 → terminal "key/login invalid" (don't retry); 429 → honor `Retry-After`,
  backoff; timeout/5xx → per-chunk continue (§3). On the proxy path, error bodies may be
  plain text — decode defensively.
- Summary: `POST /v1/chat/completions` (gpt-4o), `content or ""`.

## 7. UI (MenuBarExtra; state in AppModel, not the view)
```
 ● Transcribe
 │ Screen & System Audio   ● Granted / ✗ [Grant → relaunch]
 │ Microphone              ● Granted / ✗ [Grant]
 │ Mic       [ Logi USB Headset ▾ ]   (note: "Best results with a headset")
 │ Language  [ Auto ▾ ]               (Auto · English · Spanish · Portuguese)
 │ [ ● Record ]   00:00   status: idle/recording/transcribing/✅done/⚠︎error→Retry
 │ ⚠︎ Records everyone — get consent.   · Open folder · Sign out
```
- Permission **pills** (§8). **Mic** dropdown (uniqueID). **Language** dropdown (4 presets).
  **Record/Stop** + timer. **Status** with explicit error states ("Sign-in expired",
  "transcription failed → Retry / Open folder to recover audio", "No system audio — check
  Screen Recording").
- **Mid-session zero-buffer monitor:** if system buffers stop arriving during recording
  (Sequoia re-prompt / sleep), show a banner immediately — don't let a 90-min meeting go
  silent unnoticed.
- **First-run onboarding** (one-time): consent screen (acknowledge) → **SSO sign-in**. No
  key paste in the default build. Static "use a headset for best results" note.
- **Cut from v1:** diarize, recents list, Sparkle/auto-update, You/Them label edits,
  conditional bleed-detection (static note instead), settings beyond output-folder + sign-out.

## 8. Permission flow (verified correct by panel)
- **Status:** probe via `SCShareableContent.excludingDesktopWindows` (success vs TCC-denied).
  Don't use `CGPreflightScreenCaptureAccess()` (15.1+ shows a "bypass" warning).
- **Trigger:** `CGRequestScreenCaptureAccess()` (old API, reliable at 13+). ⚠️ **The grant
  needs an app relaunch** → show a prominent **"Quit & Reopen"** CTA and **auto-relaunch**
  (`NSWorkspace.open(Bundle.main.bundleURL)` + `exit(0)`) to remove the biggest UX bail
  point.
- **Mic:** pre-call `AVCaptureDevice.requestAccess(for:.audio)` before any capture.
- **Re-check on every foreground.** Handle Sequoia **"Allow for One Session"**: a cold-start
  probe failure = neutral "Screen Recording needed" (Grant), not "revoked".
- Settings deep-links best-effort on 15/26 → fall back to Privacy root.

## 9. Lifecycle / robustness
- **Sleep:** `NSProcessInfo.beginActivity(.userInitiated)` does NOT prevent sleep — add
  `.idleSystemSleepDisabled` (or `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep)`)
  while recording. Implement SCStream `didStopWithError` recovery (finalize partial, surface
  "interrupted — Retry").
- **Quit:** wire `applicationShouldTerminate`/`willTerminate` → `await recorder.stop()` +
  finalize segments before exit (works under LSUIElement).
- **Data safety:** raw CAF files are **never deleted before transcription succeeds**; "Open
  folder" reveals the session. Output to **`~/Documents/Transcribe/<timestamp>/`** (visible),
  configurable.
- **Cost guard:** soft warning if a recording passes ~3 h ("~$X to transcribe — continue?").
- App Nap token + sleep assertion held across the whole record→transcribe span.

## 10. Signing / notarization (own code only)
- Entitlements (minimal, Hardened Runtime): `com.apple.security.device.audio-input`
  (+ `.microphone`), **`keychain-access-groups`** (`$(AppIdentifierPrefix)$(CFBundleIdentifier)`
  — without it `SecItemAdd` fails -34018). Info.plist: `NSMicrophoneUsageDescription`,
  `LSUIElement=YES`. **No** `allow-jit`/`disable-library-validation`; **`get-task-allow`
  absent**.
- `codesign --force --options runtime --timestamp --entitlements … --sign "Developer ID
  Application: … (TEAMID)"` (no `--deep` to sign). `notarytool store-credentials` (API key)
  → `ditto -c -k --keepParent` → `submit --wait` → `stapler staple` **app and dmg**. Gate on
  `codesign --verify --deep --strict` + `spctl -a -t exec`.

## 11. Min macOS = 13 (SCK floor). `CG*ScreenCaptureAccess` (10.15+, reliable ≥11),
`SCShareableContent`, `MenuBarExtra`, `AVCaptureDevice.DiscoverySession` all fine at 13.
Enforce at launch with a readable message. (Earlier panel's "macOS 15" claim was wrong.)

## 12. ⛔ Validate-first GO/NO-GO gate (before any UI)
Prove **AVFoundation-encoded 16 kHz mono m4a is accepted by the Whisper API and yields a
correct transcript** on the real `/tmp/meetrec_real` tracks. If the AVFoundation AAC
container is rejected/garbled, fall back to `AudioToolbox`/`ExtAudioFile` encoding (+~1 wk).
This is a decision point, not a TODO.

## 13. Phased build plan
1. **Validate-first (§12)** + headless core: Swift `transcribe_track_whisper` + `merge_segments`
   + renderers; **unit-test merge**; run the real tracks through transcribe→merge (proxy or a
   dev key) and compare structure to the Python output. No UI.
2. **Capture:** fold SCK recorder; AVCaptureSession mic by uniqueID (+ format-drift guard);
   PTS offset; AVAssetReader/Writer segmenting (CAF→m4a).
3. **App shell:** MenuBarExtra + AppModel state machine; permission pills + relaunch/auto-relaunch;
   pickers; Record/Stop+timer; status/error states; mid-session zero-buffer monitor;
   onboarding (consent + SSO); sleep assertion; quit-finalize.
4. **Proxy:** deploy the Cloudflare Worker + Access; point the app at it.
5. **Package:** entitlements, codesign, notarize, staple, `.dmg`; 1-page coworker install doc.

## 14. Build-now vs needs-owner
- **Buildable without your credentials:** the headless core (§13.1) + merge unit tests; the
  capture + segmenter code; the SwiftUI shell; the Worker code + `wrangler.toml`. Compiles
  and is logic-testable; UI/permissions need interactive testing on your Mac.
- **Needs you:** Apple Developer membership + Developer ID cert + Team ID (signing/notarize);
  a Cloudflare account + Access/OIDC + `wrangler` deploy (the proxy is now a hard v1
  dependency); bundle id / app name / icon; OpenAI ZDR application.

## 15. Open items
- Confirm §12 gate result (AVFoundation m4a ↔ Whisper) once buildable.
- Cloudflare Access identity provider (Google/GitHub/Okta?) + which email domain.
- Bundle id, app name, icon; Team ID.
- Language presets beyond Auto/English/Spanish/Portuguese?
