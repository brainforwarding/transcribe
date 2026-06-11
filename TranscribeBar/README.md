# Transcribe

A tiny **macOS menu-bar app** that records a meeting — the other people's audio **and** your
mic — transcribes both with OpenAI Whisper, and saves a clean, speaker-labelled Markdown
transcript. No Dock icon, no window, no fuss.

- **System audio via ScreenCaptureKit** (the remote participants) — no BlackHole / virtual device.
- **Your mic via AVFoundation**, captured in parallel and merged on a shared timeline → a
  **You / Them** transcript.
- **Fully native Swift** — no Python, no ffmpeg. macOS 13+ (tested on Sequoia 15.x & Tahoe 26.x).

> ⚠️ It records other people. Tell them and get their consent.

## Install

**A — the built app:** open `Transcribe.dmg` → drag to Applications → open it.
(To produce the notarized DMG yourself, see [`../FINISH.md`](../FINISH.md).)

**B — from source** (needs the Swift toolchain / Command Line Tools — **no Xcode**):
```bash
cd TranscribeBar
./scripts/make-app.sh        # builds + signs build/Transcribe.app
open build/Transcribe.app
```

## First run
1. Find the **waveform** icon in the **menu bar** (top-right, left of the system icons); click it.
2. Accept the consent note, then paste your **OpenAI API key** (stored in your Keychain).
3. Click **Grant** for **Screen & System Audio** and **Microphone**.
4. **Quit & Reopen** once — Screen Recording only activates after a relaunch (a macOS rule).

## Use
Pick your **Mic** and **Language**, click **Record**, talk / let the call play, click **Stop**.
On stop you can give the recording an optional **title** — Enter saves it, Escape (or leaving it
empty) skips with no fuss; transcription is already running either way. A transcript lands in
`~/Documents/Transcribe/` — one file per recording: `2026-06-05-weekly-sync.md` with a title
(it also becomes the transcript's heading), `2026-06-05_21-52-17.md` without.
**Use a headset** for best results (speakers echo into both tracks).

**Mic only** (the toggle under the pickers) records just your own voice — voice notes, thinking
out loud, self-interviews. No system audio is captured, so it needs no Screen & System Audio
permission, and the transcript is plain flowing paragraphs instead of You/Them turns. The
headset advice doesn't apply there either.

## What you get
A title + the merged **Conversation** (You = your mic, Them = the call). Raw audio is deleted
after a successful transcript — kept in `_unfinished/` only if transcription fails (so nothing
is lost), or in `audio/` if you enable **Keep audio**. An optional **Summary** (a second
`gpt-4o` call) is off by default.

## Settings (⚙)
Save folder · Keep audio files · Add summary · Replace key · Quit.
(**Mic only** lives in the menu itself, next to the Mic/Language pickers — Keep audio and the
summary work in both modes.)

## How it works
Capture (ScreenCaptureKit + AVCaptureSession) → segment to 16 kHz mono m4a → **OpenAI Whisper**
per track → merge by timestamp **locally, no AI** → write Markdown. The optional summary is a
`gpt-4o` call. Audio is uploaded to OpenAI; for shared-key, single-sign-on billing (so coworkers
need no key), deploy the proxy in [`../proxy/`](../proxy/README.md).

## Troubleshooting
- **No menu-bar icon?** It's the waveform, just left of Wi-Fi/battery/Control Center.
- **Permission still red after granting?** Quit & Reopen — Screen Recording needs the relaunch.
- **"Transcribe wants to use your Keychain"?** Click **Always Allow** — it's reading the key you saved.
- **"…bypass the private window picker"?** Click **Allow** — that's the normal macOS 15+/Tahoe
  system-audio consent (it re-asks roughly monthly; can't be suppressed without a special entitlement).
- **Transcript is gibberish / "thank you for watching"?** The audio was silent — Whisper invents
  phrases on silence. Make sure audio is actually playing and you're on a headset.

## Develop
```bash
swift run transcribe-core selftest          # merge unit tests (no network)
swift run transcribe-core capture <dir> 8   # headless capture + transcribe test
```
Targets: **TranscribeCore** (capture / segment / transcribe / merge), **transcribe-core** (CLI),
**TranscribeApp** (the menu-bar UI). Design notes: [`../docs/menubar-app-spec.md`](../docs/menubar-app-spec.md).
Release & notarization: [`../FINISH.md`](../FINISH.md).

There's also a terminal-only sibling — the `meetrec.py` CLI in the repo root — that does the same
capture/transcribe pipeline without the app.
