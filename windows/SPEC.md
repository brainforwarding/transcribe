# Transcribe for Windows — build spec

A Windows port of the macOS Transcribe menu-bar app. Same purpose, same proxy, same
transcript format. Native C#/.NET 8 system-tray app.

## What ports for free (do NOT redesign these — match exactly)

- **Proxy & auth**: identical. The app talks to the same Cloudflare Worker, base URL
  `https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1`, with `Authorization: Bearer <team-token>`.
  Token verification: POST `chat/completions` with `{"model":"__verify__"}` → HTTP 401 = token
  rejected, any other status = recognized (mirrors the macOS app).
- **Transcript format**: must be byte-compatible with the macOS output so the team's downstream
  tooling (and `/curso` debrief) treats Mac and Windows transcripts identically.

Behavioral source of truth: `meetrec.py` (Python reference) and the Swift `TranscribeBar/Sources/TranscribeCore/`.
Read both before porting the pipeline.

## Transcription pipeline (replicate exactly)

1. **Capture** two tracks to WAV:
   - **Mic** (always): default or selected input device.
   - **System audio** (Meeting mode only): WASAPI **loopback** capture of the default render
     device (`NAudio.CoreAudioApi.WasapiLoopbackCapture`). No virtual cable. In "Just me" mode,
     do not open loopback at all (no extra permission, no device needed).
2. **Segment** each track: downmix to mono, resample to **16 kHz**, split into chunks under the
   25 MiB Whisper limit. WAV 16 kHz mono 16-bit ≈ 32 KB/s → cap each chunk at **≤ 8 minutes**
   (well under 25 MiB), or AAC/m4a via `MediaFoundationEncoder` if smaller files are preferred.
   Each chunk records its time offset from the track start.
3. **Transcribe** each chunk → POST multipart to `{base}/audio/transcriptions`:
   - fields: `model=whisper-1`, `response_format=verbose_json`,
     `timestamp_granularities[]=segment` (literal brackets, sent as one field),
     `language=<es|en|pt>` only when not auto, and the `file`.
   - Per-chunk failure **continues** (best-effort partial transcript), logs to stderr/console.
   - Drop hallucinated-silence segments: `no_speech_prob > 0.6 && avg_logprob < -1.0`.
   - Each kept segment: `{start+offset, end (≥start), label, text, source, idx}` where `idx` is a
     **global input-order counter** — assign the mic track's segments first, then system, so the
     merge tiebreak is deterministic.
4. **Merge** (`mergeSegments`): drop empty; clamp `end<start`; sort by `(start, source, end, idx)`
   with **mic source ordering before system**; then coalesce SORTED-ADJACENT same-label segments
   whose gap ≤ **1.5 s** (an interposed other-speaker segment breaks the run). Returns ordered blocks.
5. **Render**:
   - **Meeting**: `[mm:ss] **You:** text` and `[mm:ss] **Them:** text`, blocks separated by a blank
     line. `mm:ss` uses **banker's rounding** (round half to even) on seconds. Mic = `You`,
     system = `Them`.
   - **Just me**: plain flowing paragraphs, one per merged block, **no labels, no timestamps**.
   - File body = the rendered conversation. Optionally append a verbatim per-track appendix
     (`### You (mic)` / `### Them (system)`) as the macOS app does — keep it, gated by the same
     setting if present, else include it.
6. **Write** `<title-or-timestamp>.md` = `# <title or human timestamp>\n\n<body>` to the save
   folder (default `%USERPROFILE%\Documents\Transcribe\`). Slug rule for titled files:
   `YYYY-MM-DD-<slug>` (lowercase, diacritics folded, non-alphanumeric → single hyphen, ≤60 chars,
   collision-safe `-2`). Untitled = timestamp name. Raw WAV deleted on success unless **Keep audio**;
   on transcription failure, keep the raw audio so nothing is lost.
7. **Summary** (optional, off by default): POST `chat/completions` `model=gpt-4o` with the
   meetrec summary prompt; best-effort, append under a `## Summary` heading.

## UI (system tray)

A tray app (NotifyIcon), no taskbar window for the main controls — a small popup/flyout, mirroring
the macOS popover. Controls:

- **Mic** picker (input devices) · **Language** picker (Auto, English, **Spanish**, Portuguese —
  default **Spanish**, persisted) · **Mode** segmented/toggle **Meeting | Just me** (default Meeting).
- **Record / Stop**. On Stop: optional **name** dialog (single field, Enter saves, Esc/empty skips),
  transcription starts in the background first so the prompt never blocks it.
- **Settings**: save folder, Keep audio, Add summary, **Replace token** (with the same
  verify-on-save UX — paste token → "verifying…" → "✓ verified" / "✗ not recognized", show last-4
  fingerprint, never prompt for a name), and the **app version** shown subtly.
- Token stored in **Windows Credential Manager** (not a file, not registry plaintext).
- First run: consent note, then paste team token, then it's ready (mic permission is implicit on
  Windows; Meeting mode just needs the loopback device, no special grant).

Match the quiet visual tone where reasonable, but native Windows controls are fine — do not fight
the platform.

## Project layout & build

- Put everything under `windows/` in this repo: `windows/Transcribe.sln`,
  `windows/Transcribe/` (the app), `windows/Transcribe.Core/` (portable pipeline, unit-testable),
  `windows/Transcribe.Tests/` (xUnit).
- **.NET 8**, `net8.0-windows`. WinForms for the tray (lightest), or WPF if cleaner. NAudio for all
  audio (mic `WasapiCapture`/`WaveInEvent`, system `WasapiLoopbackCapture`, resample via
  `MediaFoundationResampler`, optional AAC via `MediaFoundationEncoder`).
- Config constant `ProxyBaseUrl` in one place (mirror `Config.swift`), default = the Worker URL;
  `null`/empty falls back to `https://api.openai.com/v1` + a pasted OpenAI key.

## Verification (this is the honest part)

Neither the author's machine nor the requester's Mac can compile or run a WinForms/WASAPI app.
Therefore:

1. **Unit tests** (`Transcribe.Tests`, xUnit) for everything platform-independent — and this is
   where correctness is pinned: `mergeSegments` (ordering, tiebreak, coalesce, the You/Them
   interleave), `mmss` banker's rounding, the slug/filename rules, the silence-hallucination filter,
   the verbose_json parsing, the clipboard/markdown render for both modes. Port the macOS Selftest
   cases as xUnit tests so Mac and Windows outputs are provably identical on the same inputs.
2. **CI build** — a GitHub Actions workflow (`windows-latest` runner) that restores, builds the
   solution, runs the tests, and `dotnet publish`es a **single-file, self-contained** `Transcribe.exe`.
   On a `win-vX.Y.Z` tag, it uploads the exe (zipped) as a GitHub Release asset. This is the only
   way the build is verified without a local Windows box.
3. **Live testing needs a human on Windows**: actual mic + loopback capture, the tray UX, and a real
   end-to-end recording. The report must say plainly what was and wasn't verified.

## Distribution & signing

- Windows code signing needs a separate (paid OV/EV) cert we don't have yet. Ship **unsigned** first;
  document that users click "More info → Run anyway" past SmartScreen the first time (acceptable for
  an internal team). Note in the README how to add Authenticode signing later (a `signtool` step in
  the CI workflow gated on a secret cert).
- Releases: same model as macOS — GitHub Releases, tagged `win-v1.0.0`, with install + token
  instructions in the notes. The macOS DMG keeps its own `v*` tags; Windows uses `win-v*` so the two
  platforms' "latest" don't collide.

## Out of scope (v1)

- Auto-update (manual download, like macOS).
- The `meetrec.py` CLI is untouched.
- Real-time/streaming transcription.
