# Transcribe

A Mac app that turns speech into text. Use it to dictate into any app, or to record a meeting and get a transcript and notes.

**[Download Transcribe 2.0.8 for Mac](https://github.com/brainforwarding/transcribe/releases/download/v2.0.8/Transcribe.dmg)** · Apple Silicon, macOS 13 or later · signed and notarized

## Dictation

Double-tap Option and talk. Tap Option once to finish, and the text is pasted where your cursor is: an email, a chat, a document, a terminal.

<img src="docs/assets/dictation.svg" alt="Double-tap Option, speak, tap Option again, and the text is pasted into an email at the cursor." width="100%">

A dictation can last up to five minutes. If a paste goes wrong, Option–Shift–V pastes the last one again, and every dictation stays in the history.

## Meetings

Record an online call (your microphone plus the audio playing on your Mac) or an in-person conversation (microphone only). You can write your own notes while it records. When you finish, you get the full transcript and a summary with decisions and next steps, each linked to the moment in the transcript where it came up.

<img src="docs/assets/meetings.svg" alt="A meeting is recorded with a live transcript beside your notes, then becomes a summary with decisions and next steps linked to the transcript." width="100%">

## Get started

1. Open the disk image and drag Transcribe into Applications.
2. Open **Settings → Connection**, choose **OpenAI** and paste your [OpenAI API key](https://platform.openai.com/api-keys). OpenAI bills your account for what you use.
3. Allow the permissions macOS asks for:
   - **Microphone**, to record.
   - **Accessibility**, for the Option shortcut and for pasting.
   - **Screen & System Audio Recording**, only for online meetings. You may need to quit and reopen Transcribe after granting it.

Audio is sent to OpenAI to be transcribed. Recordings, notes and history stay on your Mac. Tell people before you record them.

## More

- [App guide](TranscribeBar/README.md): every feature in detail, and how to build from source.
- [Windows version](windows/README.md): a tray app that records meetings or your own voice into a Markdown transcript.
- [Command-line recorder](docs/cli.md): `meetrec.py`, the same meeting capture from the terminal.
