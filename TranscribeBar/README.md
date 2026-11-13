# Transcribe

Native macOS dictation and meeting notes, using the Circles interface. Apple Silicon, macOS 13 or later.

## Install

[Download Transcribe 2.2.0](https://github.com/brainforwarding/transcribe/releases/download/v2.2.0/Transcribe.dmg), open the disk image and drag Transcribe into Applications. The installer is signed, notarized and stapled. Public distribution checks are recorded in [the implementation state](../docs/IMPLEMENTATION.md). [Release notes and checksum](https://github.com/brainforwarding/transcribe/releases/tag/v2.2.0).

## Run from source

The published installer is signed and notarized. Building from source uses the current code on your checkout; public release validation is recorded in [the implementation state](../docs/IMPLEMENTATION.md).
```bash
cd TranscribeBar
./scripts/make-app.sh release
open build/.app-staging.noindex/Transcribe.app
```

The app lives in the menu bar. Open Transcribe opens Dictation history. Meetings,
Dictionary and Settings are available in the sidebar.

### Dock, shortcuts and paste feedback

- Transcribe appears in the Dock and Command–Tab by default. Settings → Show in Dock enables menu-bar-only use when switched off. Closing the window keeps dictation running.
- Double Option remains available. Settings → Additional shortcut also offers Control–Option–Space (default), Control–Shift–Space, or Off. The selected chord starts and finishes dictation. Fn is unsupported.
- Setup and Settings share Check dictation. Test shortcut detects your gesture without recording. Then dictate into another app and return to Settings → Check dictation to confirm Text appeared.
- The floating chip distinguishes Enable Accessibility, Select a text field and Check paste. Hover for the detailed reason. Copy stays available; an unconfirmed paste never retries automatically.

The [installation guide](../docs/INSTALL.md) provides download, Bash and agent instructions. The Bash installer currently installs the signed 2.2.0 release and refuses an existing app in either Applications folder.

## Connect

Open **Settings → Connection** and choose **OpenAI** to enter your own OpenAI API key. No shared account, team invitation or environment file is required. OpenAI charges your API account for usage. Connection checking verifies access to the dictation model; meeting transcription and summaries also require access to their respective models.

If you already have a personal token for this app's shared proxy, choose **Team** instead. Existing installations retain their Team connection. The app stores each credential separately in the macOS Keychain and sends it only to its selected provider. Switching connections preserves both saved credentials. Development credentials remain canonical in 1Password.

Recording checks the selected connection first. Missing keys or tokens open Settings with the relevant credential named; blocked Keychain access offers Unlock. Fixing a credential lets you retry previously saved audio.

Allow Microphone for recording and Accessibility for double Option and cursor insertion. Online meetings additionally need Screen & System Audio Recording. macOS may require quitting and reopening after granting that permission. In-person meetings and dictation only use the microphone.

Audio and text needed for transcription and meeting notes are sent to OpenAI. Recordings and history are stored on this Mac. Let participants know before recording.

## Dictation

- Double-tap Option to start. Tap Option once to finish. A small chip at the bottom left of the screen shows input and elapsed time.
- At 4:30 the chip shows the 30-second warning. Recording stops at five minutes.
- When transcription finishes, the app pastes into the currently focused editable field using Command–V. Keep the intended field focused until it finishes. Secure fields are excluded.
- In recognized terminal apps, automatic paste and Paste last replace line breaks and control characters with spaces. The app never sends Return. Your original paragraphs remain in history; the explicit Copy action retains them.
- Your previous clipboard is restored after insertion is confirmed, unless you changed it in the meantime. An unconfirmed paste keeps the delivered text on the clipboard unless you copy something else. Terminal paste sends the shortcut without inspecting scrollback or claiming confirmed insertion. History always retains the original text; check the field before pasting again.
- Escape cancels insertion and keeps the captured audio. Recover in the chip or history to transcribe it; recovery never inserts automatically.
- Option–Shift–V pastes the last dictation at the current editable cursor. Disable this shortcut in Settings if needed. The menu and history also provide copy actions.

Dictation uses `gpt-live-transcribe` continuously while you speak. There is one
mode, with no grammar/style toggle, timed transcription chunks, overlap assembly,
or final editing request. Draft words appear in History; only the completed,
saved transcript can be pasted when you stop. Dictionary terms remain recognition
hints. OpenAI and Team connections use the same dictation model.

If recognition fails, the retained audio can be replayed through the same live
model. Adjacent capture files share one continuous transcription item; file
rotation is storage only. Recovery runs at recording pace to keep uploads and
memory bounded, so retrying a long recording takes time. Historical retries never
paste automatically. Meetings retain their separate transcript and notes flow.

[The dictation decision record](../docs/DICTATION-DECISION.md) explains the retired
experiments, measured timings, and the choice of one continuous model.

Audio is kept for seven days after successful completion by default, with 30 days
or Forever also available. Failed/cancelled/partial attempts remain recoverable and
are not expired. Raw capture files cover the entire recording independently of ASR.

Dictation history shows full selectable text grouped by day, with each recording's
time and a compact Copy control that briefly confirms successful copying. Direct Retry or Recover appears only when applicable. Dictation has no Export/Rename menu.
Failed and empty attempts remain visible in history with an explanation. Starting
checks that the selected device is a connected input and waits up to three seconds
for audio to be saved before showing Recording. Missing audio stops capture and
directs you to check the microphone; Retry appears only when saved audio can be recovered.

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

New meetings use `gpt-live-transcribe`, with separate microphone and Mac-audio connections. Each passage keeps the place where it first appeared: grey while it is being transcribed, final in the same place. Your passages end at your pauses (a 2 s minimum), or after 10 s of continuous speech. Confirmed passages are saved before appearing and stay unchanged. Speakers are audio sources: You and Others online, none in person. They do not identify individual participants. If Mac audio stops, it restarts by itself every 5 s and shows Interrupted meanwhile. **Settings → Languages** limits recognition to the languages you choose, starting with your Mac's; without it, short or noisy passages can come back in unrelated languages. With two or more, **New meeting** offers them together or one alone; the choice is kept for the next meeting and can't change once it starts. The microphone is chosen in Settings; New meeting only asks for Mac audio permission when an online meeting needs it.

The live transcript follows new text with short, smooth movements. Scroll up to read earlier passages without being pulled back; return to the bottom to resume following. Reduce Motion disables the animation.

If a connection fails, capture continues locally. When you finish, the app transcribes only missing audio intervals with `gpt-transcribe`; it does not rerun or reformat confirmed passages. Audio that could not be transcribed appears in the transcript at its time with Retry, which resumes from saved audio and cached results. Account problems show a short message with the relevant action.

When a transcript finishes, one `gpt-4o` request writes a 40–80 word paragraph and, unless you typed a title, a title of up to six words. Transcripts under 100 words get a title only. Failures leave the transcript alone. **Copy transcript** copies `You: …` / `Others: …` paragraphs without timestamps; the Markdown export keeps them. Notes from earlier versions stay in their exports and are no longer shown.

Drop audio or video files on the window: the left half makes a meeting, the right half a dictation. **File › Open…** and the Dock icon use the open section (Meetings from Dictionary or Settings). A meeting is transcribed in person with the diarized model; a dictation is one plain transcript with your languages and Dictionary, never pasted. Files go one at a time; dictation waits until they finish. WhatsApp and Telegram voice notes (Ogg) are uploaded as they are, up to the 24 MB limit. WebM is not supported.

Incomplete meetings retain audio for recovery. Complete transcripts are saved before audio cleanup; Keep audio in Settings retains successful raw tracks too. History is in `~/Library/Application Support/Transcribe/Sessions`; each meeting is also exported as Markdown to the **Meeting exports** folder in Settings. Dictations are not exported. Import existing Markdown through **File › Import Recordings…**. Originals remain unchanged and are not imported again after export.

## Deleting

Right-click a dictation, or hover it and click **Delete**: it goes at once, with **Undo** in the corner for a few seconds. Delete a meeting from its **⋯** menu or by right-clicking it in the list, after a confirmation. Both move the whole record, audio included, to the macOS Trash, where Finder can put it back. Meeting exports are kept. Nothing can be deleted while it is being recorded or transcribed.

## Updates

Starting with 2.0.9, an available update shows a small **Actualizar** button at the bottom of the sidebar. Click it to download, install and restart. The button changes to **Descargando** and **Instalando** while it works. Active recordings and other ongoing work finish before an update can start. Unsaved edits must be saved before restart; failures offer **Reintentar**.

If you have 2.0.8 or earlier, install the current Mac download once to receive future updates this way. Updates use signed archives and a signed feed, and each production app is Developer ID signed and notarized. [Updater release instructions](../docs/UPDATER-RELEASE.md).

## Validate and release

```bash
swift run transcribe-core selftest
./scripts/test-native.sh
./scripts/test-coordinator.sh
./scripts/verify-app.sh build/.app-staging.noindex/Transcribe.app --launch
```

The checks use Command Line Tools without XCTest or network credentials. A local launch is not a notarization check.

For public distribution, follow [the implementation state](../docs/IMPLEMENTATION.md) and [release instructions](../FINISH.md). The release script notarizes and staples the app before creating and signing the installer, then notarizes/staples the DMG and verifies its contained app. Publish the Mac version through its explicit release URL and verify the downloaded artifact.

The Python command-line recorder is a separate entry point.
