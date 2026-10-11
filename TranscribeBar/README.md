# Transcribe

Native macOS dictation and meeting notes, using the Circles interface. Apple Silicon, macOS 13 or later.

## Install

[Download Transcribe 2.0.8](https://github.com/brainforwarding/transcribe/releases/download/v2.0.8/Transcribe.dmg), open the disk image and drag Transcribe into Applications. The published download was checked against the notarized artifact, including signatures, staples, Gatekeeper and startup from the mounted installer. [Release notes and checksum](https://github.com/brainforwarding/transcribe/releases/tag/v2.0.8).

## Run from source

The published installer is signed and notarized. Building from source uses the current code on your checkout; public release validation is recorded in [the implementation state](../docs/IMPLEMENTATION.md).
```bash
cd TranscribeBar
./scripts/make-app.sh release
open build/Transcribe.app
```

The app lives in the menu bar. Open Transcribe opens Dictation history. Meetings,
Dictionary and Settings are available in the sidebar.

## Connect

Open **Settings → Connection** and choose **OpenAI** to enter your own OpenAI API key. No shared account, team invitation or environment file is required. OpenAI charges your API account for usage. Connection checking verifies access to the dictation model; meeting transcription and summaries also require access to their respective models.

If you already have a personal token for this app's shared proxy, choose **Team** instead. Existing installations retain their Team connection. The app stores each credential separately in the macOS Keychain and sends it only to its selected provider. Switching connections preserves both saved credentials. Development credentials remain canonical in 1Password.

Allow Microphone for recording and Accessibility for double Option and cursor insertion. Online meetings additionally need Screen & System Audio Recording. macOS may require quitting and reopening after granting that permission. In-person meetings and dictation only use the microphone.

Audio and text needed for transcription, dictation formatting and meeting notes are sent to OpenAI. Recordings and history are stored on this Mac. Let participants know before recording.

## Dictation

- Double-tap Option to start. Tap Option once to finish. A small chip at the bottom left of the screen shows input and elapsed time.
- At 4:30 the chip shows the 30-second warning. Recording stops at five minutes.
- When transcription finishes, the app pastes into the currently focused editable field using Command–V. Keep the intended field focused until it finishes. Secure fields are excluded.
- In recognized terminal apps, automatic paste and Paste last replace line breaks and control characters with spaces. The app never sends Return. Your original paragraphs remain in history; the explicit Copy action retains them.
- Your previous clipboard is restored after insertion is confirmed, unless you changed it in the meantime. An unconfirmed paste keeps the delivered text on the clipboard unless you copy something else. Terminal paste sends the shortcut without inspecting scrollback or claiming confirmed insertion. History always retains the original text; check the field before pasting again.
- Escape cancels insertion and keeps the captured audio. Recover in the chip or history to transcribe it; recovery never inserts automatically.
- Option–Shift–V pastes the last dictation at the current editable cursor. Disable this shortcut in Settings if needed. The menu and history also provide copy actions.

Dictation uses `gpt-transcribe`, with its existing conservative transcription prompt.
After saving the raw transcript, the native app uses `gpt-6-luna` with
`reasoning_effort: none` for paragraphs, punctuation and quotation marks around clear
direct speech. An ordered fidelity check rejects changed words, accents, numbers or
technical symbols. Provider failures and timeouts keep the original text. Accepted
formatting is saved before insertion; the raw transcript remains in the local record.
The owner verified natural paragraph formatting with real dictation; broader formatting quality remains owner-tested. Dictionary terms
remain optional recognition hints. Meetings and CLI transcription do not use this second pass.

Dictation history shows full selectable text grouped by day, with each recording's
time and a compact Copy control that briefly confirms successful copying. Direct Retry or Recover appears only when applicable. Dictation has no Export/Rename menu.
Empty inactive recordings with no recovery or account action are hidden from the view;
stored history and audio are retained.

Service failures show one brief message with a useful action. Explicitly exhausted
credits open OpenAI billing; spend/usage limits direct to billing, and Team account
issues direct to Settings and the team administrator. Rate limits and temporary
failures offer Retry. A transcription retry uses saved audio and cached successful
chunks. A formatting retry uses only the saved raw text, preserves the previous text
until the result is saved, and never inserts again automatically. Copy remains
available when text was recognized. Escape cancels a formatting retry without
discarding the saved transcript.

## Meetings

Choose **Online meeting** for microphone plus all audio playing on the Mac, or **In person** for microphone only. Meetings have no five-minute limit. Use a headset for online meetings to reduce acoustic duplication.

Write personal notes beside the live transcript. New meetings use `gpt-live-transcribe`, with separate microphone and Mac-audio connections. Draft words may change while they arrive. Confirmed passages are saved before appearing and stay unchanged, including after you finish recording. The time labels mark captured audio intervals, rather than individual word timestamps. Labels describe audio sources: You / System audio online, Microphone in person. They do not identify individual participants.

If a connection fails, capture continues locally. When you finish, the app transcribes only missing audio intervals with `gpt-transcribe`; it does not rerun or reformat confirmed passages. Retry resumes missing intervals using saved audio and successful cached results. Account problems show a short message with the relevant action. Historical meetings retain their existing transcription and recovery behavior.

Generated notes remain separate from the transcript. They use the existing `gpt-4o` summary route and include validated links to transcript turns or the personal-note snapshot. A summary made before missing passages arrive is marked for review and can be regenerated. Unknown action owners remain unassigned. Original notes and edited generated notes are stored separately.

Incomplete meetings retain audio for recovery. Complete transcripts are saved before audio cleanup; Keep audio in Settings retains successful raw tracks too. History is in `~/Library/Application Support/Transcribe/Sessions`; meeting Markdown exports use the selected save folder. Import existing Markdown through **Settings → Import recordings…**. Originals remain unchanged and are not imported again after export.

## Updates

Starting with 2.0.9, an available update shows a small **Actualizar** button at the bottom of the sidebar. Click it to download, install and restart. The button changes to **Descargando** and **Instalando** while it works. Active recordings and other ongoing work finish before an update can start. Unsaved edits must be saved before restart; failures offer **Reintentar**.

Install 2.0.9 manually once to receive future updates this way. Updates use signed archives and a signed feed, and each production app is Developer ID signed and notarized. [Updater release instructions](../docs/UPDATER-RELEASE.md).

## Validate and release

```bash
swift run transcribe-core selftest
./scripts/test-native.sh
./scripts/test-coordinator.sh
./scripts/verify-app.sh build/Transcribe.app --launch
```

The checks use Command Line Tools without XCTest or network credentials. A local launch is not a notarization check.

For public distribution, follow [the implementation state](../docs/IMPLEMENTATION.md) and [release instructions](../FINISH.md). The release script notarizes and staples the app before creating and signing the installer, then notarizes/staples the DMG and verifies its contained app. Publish the Mac version through its explicit release URL and verify the downloaded artifact.

The Python command-line recorder is a separate entry point.
