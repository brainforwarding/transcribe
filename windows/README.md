# Transcribe for Windows

A native Windows port of the macOS Transcribe menu-bar app. Same purpose, same Cloudflare
proxy, same transcript format — a system-tray recorder + transcriber that turns a meeting (or
just your own voice) into a speaker-labelled markdown transcript.

This is the Windows sibling of `TranscribeBar/` (Swift/macOS) and `meetrec.py` (the Python CLI).
The transcript output is **byte-compatible** with the macOS app on the same audio, so the team's
downstream tooling treats Mac and Windows transcripts identically.

## What it does

1. **Capture** — records your **mic** (always) and, in **Meeting** mode, the **system audio**
   (everyone else on the call) via WASAPI **loopback** of the default render device. No virtual
   cable. In **Just me** mode the loopback is never opened — mic only.
2. **Segment** — each track is downmixed to mono, resampled to **16 kHz** (NAudio
   `MediaFoundationResampler`), and split into ≤ 8-minute WAV chunks (well under the 25 MiB
   Whisper limit).
3. **Transcribe** — each chunk → `whisper-1` (`verbose_json`, segment timestamps) through the
   proxy. Silence-hallucinations are dropped (`no_speech_prob > 0.6 && avg_logprob < -1.0`).
   Per-chunk failures continue best-effort.
4. **Merge & render** — segments are merged on a shared timeline (mic = **You**, system =
   **Them**). Meeting mode renders `[mm:ss] **You:** …` / `**Them:** …`; Just me renders plain
   paragraphs with no labels or timestamps.
5. **Write** — `<title-or-timestamp>.md` to `%USERPROFILE%\Documents\Transcribe\`. Named files
   use a `YYYY-MM-DD-<slug>` stem with collision-safe `-2`, `-3`, … suffixes. Raw audio is
   deleted on success (unless **Keep audio**) and kept under `_unfinished/` on failure.

## Project layout

| Path | What |
| --- | --- |
| `Transcribe.sln` | Solution. |
| `Transcribe.Core/` | Portable, unit-tested pipeline: merge, render (`mmss` banker's rounding), naming/slug, Whisper HTTP client (exact multipart contract), `verbose_json` parsing, silence filter, token verification, summary, `OpenAIConfig`/`AppConfig`. **No WinForms / NAudio** — audio capture is behind `IAudioCapture` / `IAudioSegmenter`. Targets `net8.0`. |
| `Transcribe/` | The `net8.0-windows` tray app: WinForms `NotifyIcon` + popup flyout, NAudio capture (mic via `WasapiCapture`, system via `WasapiLoopbackCapture` gated by mode), the NAudio segmenter, Windows Credential Manager token store, settings persistence, name-on-stop dialog, token verify-on-save UX, version display. |
| `Transcribe.Tests/` | xUnit. Ports the macOS `Selftest` cases plus more (merge ordering/tiebreak/coalesce, You/Them interleave, `mmss` rounding, slug/collision rules, silence filter, `verbose_json` parsing, multipart contract, both render modes end-to-end, token verification). Targets `net8.0`, no Windows dependency. |

The config constant `AppConfig.ProxyBaseUrl` (in `Transcribe.Core/OpenAIConfig.cs`) mirrors
`Config.swift`: `https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1`. Set it to `null` to
fall back to `https://api.openai.com/v1` with a pasted OpenAI key.

## How CI builds it

`/.github/workflows/windows.yml` runs on `windows-latest`:

1. `actions/setup-dotnet` (8.x) → `dotnet restore` → `dotnet build -c Release` → `dotnet test`.
2. `dotnet publish` a **single-file, self-contained** `win-x64` `Transcribe.exe`.
3. Uploads the zipped exe as a build artifact on every run.
4. On a **`win-v*` tag** (e.g. `win-v1.0.0`), zips the exe and attaches it to a **GitHub
   Release** via `softprops/action-gh-release`.

This is the only place the Windows build is verified — there is intentionally no local Windows
box. The build runs on push to any branch touching `windows/`, on PRs, on `win-v*` tags, and via
manual dispatch.

To cut a release:

```bash
git tag win-v1.0.0
git push origin win-v1.0.0
```

(macOS uses `v*` tags; Windows uses `win-v*` so the two platforms' releases don't collide.)

## Install (unsigned)

The exe is **not code-signed** yet (signing needs a paid OV/EV cert we don't have). The first
time you run it, Windows SmartScreen will show a blue warning:

1. Download and unzip the release asset (`Transcribe-win-x64-<version>.zip`).
2. Double-click `Transcribe.exe`.
3. On the SmartScreen prompt, click **More info → Run anyway**.
4. The Transcribe icon appears in the system tray (bottom-right). Left-click it for the popup;
   right-click for Open / Settings / Quit.

This is acceptable for an internal team. See *Code signing* below to remove the warning later.

## Token setup

On first run the app walks you through:

1. **Consent** — a one-time note that recording captures everyone and uploads audio to OpenAI.
2. **Team token** — paste your personal team token (not an OpenAI key). On save it's verified
   against the proxy (`POST chat/completions {"model":"__verify__"}` → 401 means rejected,
   anything else means recognized) and stored in **Windows Credential Manager** — never a file,
   never registry plaintext. You'll see a `•••• 1234 stored` last-4 fingerprint.

Replace the token any time from **Settings → Replace…** (same verify-on-save flow).

## Usage

- **Mic** — pick an input device (or System default).
- **Language** — Auto / English / **Spanish** (default, persisted) / Portuguese.
- **Mode** — **Meeting** (you + everyone, You/Them transcript, records system audio) or **Just
  me** (your voice only, no labels). Default **Meeting**.
- **Record / Stop** — on Stop, transcription starts immediately in the background and a small
  "Name this recording" dialog appears (Enter saves, Esc or empty skips → timestamp name).
- **Settings** — save folder, Keep audio, Add summary, Replace token, and the subtle app version.

Transcripts land in `%USERPROFILE%\Documents\Transcribe\` (configurable). "Recordings" in the
popup opens that folder.

## Code signing (later)

To remove the SmartScreen warning, add an Authenticode signing step to the CI workflow, gated on
a certificate secret so it's a no-op until a cert exists:

```yaml
      - name: Sign exe (only if a cert secret is configured)
        if: ${{ secrets.WINDOWS_PFX_BASE64 != '' }}
        shell: pwsh
        run: |
          $pfx = "$env:RUNNER_TEMP\cert.pfx"
          [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_PFX_BASE64))
          & signtool sign /f $pfx /p $env:WINDOWS_PFX_PASSWORD `
            /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
            publish/Transcribe.exe
        env:
          WINDOWS_PFX_BASE64: ${{ secrets.WINDOWS_PFX_BASE64 }}
          WINDOWS_PFX_PASSWORD: ${{ secrets.WINDOWS_PFX_PASSWORD }}
```

Place it between *Publish* and *Stage and zip* so the zipped/released exe is the signed one. An
OV cert removes the "unknown publisher" warning; an EV cert additionally builds SmartScreen
reputation immediately.

## Verification status

What is verified by CI / unit tests vs. what still needs a human on a real Windows machine is
documented honestly in the build report. In short: the **transcript-format contract** (merge,
render, rounding, slug, silence filter, multipart, parsing, both modes) is pinned by xUnit tests
that mirror the macOS `Selftest`; the **live audio + tray UX** (mic capture, loopback capture of
a real call, the popup, an end-to-end recording) can only be confirmed on Windows.
