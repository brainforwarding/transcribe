# Install Transcribe for Mac

Transcribe requires Apple Silicon and macOS 13 or later. Use the signed, notarized release binary. A source checkout is unnecessary.

[Download Transcribe 2.1.0](https://github.com/brainforwarding/transcribe/releases/download/v2.1.0/Transcribe.dmg), open the disk image, drag Transcribe to Applications, then open it.

For terminal installation:

```bash
curl -fsSL --proto '=https' https://raw.githubusercontent.com/brainforwarding/transcribe/master/scripts/install-mac.sh | /bin/bash
```

The installer checks the release checksum, publisher signature and Gatekeeper, then installs into `~/Applications`. It needs no administrator password and prints the command to open the app. It refuses existing copies in `/Applications` or `~/Applications`; open the existing copy and use its in-app updater. The installer currently pins released version 2.1.0. Changes in a source checkout are included only after a new signed app release.

If an agent is installing for you, share this:

```text
Install Transcribe for Mac using the signed release and instructions at https://github.com/brainforwarding/transcribe/blob/master/docs/INSTALL.md
```

Agents should read these instructions and use the same installer. Leave existing app installations, history, credentials and macOS permission settings intact. Never bypass Gatekeeper or quarantine. Report the installed path and let the user open the app to complete setup. If installation cannot proceed, explain the installer error and provide the direct download link.

In Transcribe, select your connection in Settings and enter your own API key or authorized team token. Allow Microphone and Accessibility when requested. Online meetings also require Screen & System Audio Recording. API keys belong in the app's secure connection field, never in an install command or a chat with an agent.

Double-tap Option to start dictation, then tap Option once to finish. Keep the intended text field focused until the transcript arrives. The released 2.1.0 app supports Option; Fn is not a Transcribe shortcut.
