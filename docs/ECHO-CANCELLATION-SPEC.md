# Echo cancellation for online meetings

Status: reviewed by Codex (gpt-6.1-sol, high), refined and implemented, 2026-10-14. Awaiting the owner test. Review decisions are recorded at the end.

## Problem

In an online meeting played through the Mac's speakers, the microphone also picks up the other participants. Transcribe records the microphone raw (`AVCaptureSession`), so their speech is transcribed twice: once as **System audio** and again, about 2 s later, as **You**. In the 2026-10-14 meeting (55 min, built-in speakers), 123 of 329 "You" passages (37 %) were near-copies of a System audio passage. Meet and similar apps cancel echo only in what they send; our separate capture still hears the speakers.

## Outcome

During an **online meeting**, the microphone track contains the user's voice, not the speaker playback. Labels become trustworthy, and the live transcript, final transcript and notes stop duplicating the other side. Everything else is unchanged: files, timing, levels, health, the live pipeline, device choice and the UI.

## Approach

Use Apple's voice-processing I/O (the echo canceller FaceTime uses) on the microphone input: `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`. macOS uses the engine's output device (the system default output) as the reference and removes what it plays from the input before the app sees it. Cancellation is therefore route-dependent: it works when the meeting plays through the default output, which is the normal case, and may not when a meeting app is pointed at a different output device. Each session records the reference output so this is visible when debugging.

Scope it to the case that has the problem:

| Recording | Microphone path |
|---|---|
| Online meeting (mic + Mac audio) | Voice processing (new) |
| In-person meeting, dictation | Current `AVCaptureSession` path (unchanged) |

Dictation and in-person meetings have nothing to cancel. Keeping them on the current path avoids voice processing's AGC/noise-suppression side effects where they bring no benefit.

Requires macOS 14 or later, which is needed to minimize voice processing's ducking (lowering) of other apps' audio, i.e. the meeting itself. On macOS 13 online meetings keep the current path.

## Design

`MicCapture` keeps its public API and its responsibilities: track writing, liveness watchdog, levels, health, frames. Only *how buffers arrive* changes. The input becomes a small internal protocol with two implementations:

```swift
/// Delivers microphone buffers with host-clock timestamps (seconds) on the capture queue.
protocol MicInput: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)? { get set }
    var onInterruption: ((String) -> Void)? { get set }
    func start(device: AVCaptureDevice, explicitlySelected: Bool) throws  // leaves nothing running on failure
    func stop()                                                            // idempotent
}
```

- `CaptureSessionMicInput` (`MicInput.swift`): the existing `AVCaptureSession` code moved as-is, including the `runtimeError` / `wasInterrupted` observers and the sample-buffer conversion. One small difference: a dropped sample buffer now goes through the same once-per-capture interruption report as the other microphone failures.
- `VoiceProcessingMicInput` (new file, `VoiceProcessingMicInput.swift`), started on the caller's thread while the engine is stopped:
  1. `try inputNode.setVoiceProcessingEnabled(true)`, then `voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`.
  2. Only if the user chose a specific microphone: after enabling voice processing, resolve its UID to an `AudioDeviceID` (`kAudioHardwarePropertyTranslateUIDToDevice`; `AVCaptureDevice.uniqueID` is the Core Audio device UID on macOS), set `kAudioOutputUnitProperty_CurrentDevice` (global scope, element 0) on the re-fetched `inputNode.audioUnit`, check the `OSStatus`, and read the property back. A mismatch throws, which triggers the raw fallback with the same microphone.
  3. Read `inputNode.outputFormat(forBus: 0)` after selection. Require a non-interleaved Float32 format with a positive rate and channel count. Install a tap in that format.
  4. The tap copies channel 0 (the processed voice) into a new mono buffer at the native rate, never a downmix. It requires `when.isHostTimeValid` and converts with `AVAudioTime.seconds(forHostTime:)`, the host clock the capture epoch uses. It then dispatches the copy asynchronously to the capture queue. A buffer without valid host time is dropped and reported once as undecodable.
  5. Register for `AVAudioEngineConfigurationChange` before starting. The handler only dispatches an interruption report to the capture queue ("Microphone capture was interrupted. The saved audio is preserved."). Nothing is torn down inside the notification, and there is no automatic rebuild in this version.
  6. `engine.prepare(); try engine.start()`. On any failure the input tears itself down completely before throwing.
  7. `stop()` is idempotent: remove the tap, stop the engine, disable voice processing, unregister the observer.

`MicCapture.init(outputURL:epoch:echoCancellation:)` picks the input. `MicCapture` resolves the device first, so an unavailable microphone still fails exactly as today and is never masked by a fallback. If voice processing then fails, the voice-processing input has already torn itself down and `MicCapture` starts `CaptureSessionMicInput` on the same device, recording the failure reason. Cancellation is checked before and after each start. Recording is never blocked by echo cancellation. Buffers that reach the queue after `stop()` are dropped by the existing `isStopped` guard, so `PCMTrackWriter` is finalized exactly once and stays queue-confined. The unused `MicCapture.firstSamplePTS` is removed.

`CaptureController` passes `echoCancellation: !micOnly`. It is the only call-site change, and it also covers the CLI's online recordings.

## Debuggability

- `capture.json` gains `micProcessing` (`"voice"` or `"raw"`), `micProcessingNote` (why raw was used, if voice processing was requested), and `referenceOutput` (the default output device name), written once the microphone has started. This shows which path was taken; whether cancellation actually worked is judged from the transcript.
- The existing liveness watchdog already reports a microphone that starts but delivers no buffers.
- Environment variable `TRANSCRIBE_MIC_PROCESSING=raw` forces the current path. This allows an A/B comparison from the same build (CLI or app launched from a terminal) without a settings toggle.
- No new UI, settings or user-facing messages.

## Out of scope

- Transcript-level dedup of residual echo (option C). Revisit after measuring real meetings.
- Echo cancellation for dictation and in-person meetings.
- Automatic engine rebuild after a device change.
- The audio-gap banner (separate change).

## Risks

- **Voice quality:** voice processing applies AGC and noise suppression, which may slightly change how the user's voice is transcribed. Accepted for online meetings; measured in the owner test.
- **Device selection:** some USB/Bluetooth inputs may not accept voice processing. They fall back to raw automatically, and `micProcessing` records it.
- **Bluetooth headsets:** voice processing may switch AirPods to the hands-free profile. Users of headphones have no echo problem; if this proves disruptive, skip voice processing when the default output is a headset. Not built now.
- **Interaction with the meeting app's own voice processing:** both apps can run voice-processing I/O at once; this is the normal situation for FaceTime/Meet alongside other apps.

## Verification

Agents: build, existing selftests, and a new selftest for channel-0 extraction and unknown-UID resolution. No live audio by agents.

Owner (online meeting or YouTube through built-in speakers, 2 minutes, speaking occasionally):
1. Record with the new build. Check `capture.json` shows `"micProcessing": "voice"`, and count "You" passages that duplicate System audio.
2. Repeat with `TRANSCRIBE_MIC_PROCESSING=raw` and compare.
3. Confirm the meeting audio is at most slightly lowered, both while listening and in the Mac audio track; the selected microphone is used; and dictation is unchanged.
4. Once with a Bluetooth headset and once after switching output devices mid-meeting: recording continues, and `referenceOutput` and the result are noted.

Pass: duplicates fall from about a third of "You" passages to rare, with the user's own speech intact, including when talking over the other side.

## Review decisions

Codex (gpt-6.1-sol, high) reviewed the draft. Adopted:
- Enable voice processing before choosing the device, then verify the device actually in use. Fall back to raw on the same microphone.
- Describe cancellation as route-dependent and record the reference output.
- "Minimize" ducking rather than "stop" it, and test the audible level and the Mac audio track.
- Transactional fallback: the failed input tears down fully; device-unavailable and cancellation errors are never masked.
- Copy samples and the timestamp before dispatch. Late buffers are dropped by the existing stop guard.
- The configuration-change handler only dispatches to the capture queue.
- Require valid host time. Validate the format and copy channel 0 at the native rate.
- Record why raw was used; rely on the existing liveness watchdog for a silent start.

Not adopted, to keep the change small:
- Re-normalizing `AVCaptureSession` PTS through its synchronization clock. The raw path is unchanged and already aligned in practice.
- Per-route validation logic or a startup first-buffer gate that triggers a fallback. The watchdog and the recorded fields make these cases visible; revisit if owner tests show a need.
