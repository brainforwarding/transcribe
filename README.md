# meetrec — meeting recorder + transcriber (macOS 13+)

> **Two ways to use this:**
> - **[Transcribe — the menu-bar app](TranscribeBar/README.md)** (fully native Swift, click-to-record). Best for most people and for sharing with coworkers.
> - **the `meetrec.py` CLI below** — the same capture/transcribe pipeline from the terminal.
>
> Both produce the same **You / Them** transcript. The app is the recommended path; the CLI is great for scripting.

---

A no-GUI alternative to OBS. A tiny Swift binary captures **system audio** via
ScreenCaptureKit (no BlackHole, no virtual device, negligible footprint), a Python
script records your **mic** alongside it, then transcribes the two tracks through the
OpenAI API. By default it transcribes them **separately** and merges them on a shared
timeline into one chronological, speaker-labelled transcript — **You** (your mic) vs
**Them** (the remote participants) — so attribution is exact and nothing is lost to
crosstalk. One command, runs in your terminal, nothing to keep open in the background.

> Separate-track works best on a **headset** (no acoustic bleed between mic and
> system). On speakers it warns you and you can fall back to `--mix` (one mixed track,
> the original behaviour).

Works on macOS 13 through 26 (tested target: Sequoia 15.x and Tahoe 26.x).

---

## 1. Install prerequisites

```bash
brew install ffmpeg            # mic capture + mixing + chunking
xcode-select --install         # Swift toolchain, if you don't have it
pip install -r requirements.txt
export OPENAI_API_KEY="sk-..."  # add to your ~/.zshrc to persist
```

**Where to put the API key.** Any of these works (checked in this order):
1. `OPENAI_API_KEY` already in your environment (e.g. exported from `~/.zshrc`).
2. A `.env` file next to `meetrec.py` containing `OPENAI_API_KEY=sk-...`
   (one `KEY=value` per line; a leading `export ` is fine). This keeps the key
   out of your shell history — it's the easiest option and is git-ignored.
3. `~/.config/meetrec/env`, same format.

(`--backend local` needs no key at all — see Notes.)

## 2. Build the system-audio binary (one time)

```bash
cd SystemAudioRecorder
swift build -c release
cd ..
```

`meetrec.py` will also build it automatically on first run if it's missing.

## 3. Grant permissions (the one real gotcha)

ScreenCaptureKit audio needs **Screen Recording** permission, and the mic needs
**Microphone** permission. Because this runs from the terminal, macOS attributes
those permissions to your **terminal app**, not to the script or the binaries. So:

System Settings → Privacy & Security →
  - **Screen & System Audio Recording** → enable your terminal (Terminal / iTerm / Ghostty / etc.)
  - **Microphone** → enable your terminal

You may be prompted automatically the first time. **Quit and reopen the terminal
(Cmd-Q, not just close the window) after granting** — a running process caches the
old "denied" state until it restarts. A full reboot is occasionally needed if the
toggle seems stuck.

Version-specific gotchas worth knowing:
- **Grant the full "Screen & System Audio Recording", not "System Audio Only"**
  (macOS 14.4+ splits them). This tool builds a display content filter, which the
  audio-only grant doesn't satisfy.
- **macOS 15 (Sequoia)** shows a re-consent prompt roughly monthly — click *Allow*.
  If you accidentally deny it, re-enable your terminal in the settings pane above.
- **macOS 26 (Tahoe)** has a known quirk: the `SystemAudioRecorder` binary itself
  won't appear in the Screen-Recording list — only your *terminal* does, which is
  the thing that actually needs the grant. If audio is still silent after granting
  to the terminal, run `tccutil reset ScreenCapture` in another terminal and re-grant.
- If you switch terminal apps, you must grant permissions to the new one.
- Launching via **Raycast / Alfred / skhd / launchd** instead of from a terminal can
  break permission attribution (those launchers, not your terminal, become
  responsible). Trigger an actual terminal command if capture comes back empty.

**Telling silent-from-permission apart from silent-for-real:** on stop, the recorder
prints a one-line summary like `system audio: 142 buffers, 9.7s written — non-silent ✓`.
If it says `NO audio buffers` or `SILENT (all-zero)`, it's a permission/routing issue,
not the transcription model.

## 4. Find your mic, then record

```bash
python3 meetrec.py --list-mics          # lists AUDIO input devices + indices
python3 meetrec.py --mic 3              # records until you press Enter
python3 meetrec.py --mic "MacBook"     # …or pass a name substring instead of an index
```

The right index is **often not 0** (virtual devices, headsets, and meeting apps all
register inputs). `--list-mics` shows only the audio devices with their indices, and
`--mic` accepts either the number or a case-insensitive name substring so you don't
have to guess.

When you press Enter it stops, transcribes, and writes `recordings/<timestamp>/transcript.md`:

```markdown
## Summary
…overview, decisions, action items…
## Conversation
[00:00] You:  morning — can everyone hear me?
[00:03] Them: yep, loud and clear.
## Appendix — raw per-track transcripts
### You (mic) …        ### Them (system) …
```

The **Conversation** is the merged, time-ordered dialogue; the **Appendix** is the
verbatim per-track text (ground truth — ordering there is always exact). Because the
mic and system recorders start a fraction of a second apart, turn ordering in the
Conversation is *turn-level*: within ~1 s, two near-simultaneous turns may swap — check
the appendix if a fast exchange looks off.

### Useful flags
- `--me "Sebastian"` / `--them "Acme team"` — relabel the two sides (default You / Them).
- `--lang es` — language hint; improves accuracy and avoids mis-translation. Recommended
  if your meetings aren't in English.
- `--diarize-remote` — split the **remote** side into *Them — Speaker A/B/C* using the
  diarize model (system track only — your mic is always just "You"). Opt-in, ≈2.5× cost
  on that track, and **guarded**: if the model degrades (over-fragments, or translates
  away from `--lang`) it automatically falls back to plain transcription. Per-request
  labels can differ across 20-min chunks. Treat as experimental, especially non-English.
- `--no-timestamps` — drop the `[mm:ss]` prefixes.
- `--mix` — original behaviour: one mixed track, single transcript (use `--model …` to
  pick the model, e.g. `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`,
  `gpt-4o-transcribe-diarize`). Separate-track mode always uses `whisper-1` (the only
  model that returns the timestamps the merge needs).
- `--backend local` — privacy stub (see Notes); needs no API key, implies `--mix`.
- `--no-summary` — transcript only. `--keep-audio` — keep the intermediate audio.

## 5. Make it feel like a tool

Add an alias so it's a single word from anywhere:

```bash
echo 'alias rec="python3 ~/meetrec/meetrec.py --mic \"MacBook\""' >> ~/.zshrc
```

For a global hotkey, point a Raycast/Alfred command or an `skhd` binding at that
alias.

---

## Notes

- **Cost (approx, 2026):** separate-track transcribes both tracks with `whisper-1`
  ($0.006/min each) ≈ **$0.72/meeting-hour**; `--mix` is one track ≈ $0.36/hr;
  `--diarize-remote` adds the diarize premium (~2.5×) on the remote track. Tiny next to
  most meeting tools.
- **Privacy / consent:** this records other participants, and (in separate-track mode)
  uploads **both** the mic and system audio to OpenAI. Disclose it and get agreement;
  consent rules vary by jurisdiction.
- **Fully local option:** if you'd rather not send audio to a third party, run with
  `--backend local` and fill in `transcribe_local()` with a `whisper.cpp` /
  `faster-whisper` call. The flag and seam are already wired in (it currently exits with
  a "not implemented" note, and runs via `--mix` since local has no timestamps); the
  capture and segmenting stay identical, only that one function changes.
- **The Swift piece is the part most likely to need a tweak** for a given OS point
  release. If it ever returns silence, the maintained `audiotee` / ScreenCaptureKit
  CLI projects on GitHub are drop-in replacements that emit PCM you can pipe to ffmpeg.
