# One continuous dictation model

Decision made 19 October 2026. Released 20 October 2026 as 2.1.0, build 15.

The owner tested continuous dictation and chose its speed and direct output over
additional grammar/style processing. Native Mac dictation now has one path:
`gpt-live-transcribe`, `delay: minimal`, one open item while speaking, explicit
commit at stop, then durable save and guarded paste. There is no grammar or speed
switch, timed dictation segmentation, replayed overlap, stitching request, final
editor, or formatting retry. Old preference values cannot select another path.
This decision applies to dictation. Meeting transcripts, separate audio sources,
notes generation, and missing-interval recovery retain their existing behavior.

## What was tried

- Full-recording transcription followed by a conservative punctuation editor.
- Background committed transcription with pause-aware cuts, two-second overlaps
  at forced boundaries, and one assembly/editor request.
- Audio boundary rechecks. These added 34.592 seconds to one 252.95-second owner
  recording; the total stop-to-ready time was 41.118 seconds. They were removed.
- A single assembly pass on Luna Fast. A replay of the saved owner chunks measured
  3.241 seconds median, versus 5.248 without Fast. Groq 20B and 120B were faster
  (1.159 and 2.661 seconds), but repeated overlap phrases in public fixtures.
- Continuous live transcription with no final text request. Public synthetic
  English and Spanish recordings finished in 1.673 and 0.575 seconds after stop.
  A 107.02-second mixed-language stream finished in 0.714 seconds, one confirmed
  item, no recovery and no editor. These are sample timings, not guarantees or a
  controlled comparison of the same input across every approach. The owner's
  subsequent real dictation confirmed that speed and output suited their workflow.

The detailed experiments remain in the linked historical documents:
[latency](DICTATION-LATENCY-EXPERIMENT.md),
[boundaries](DICTATION-BOUNDARY-EVALUATION.md),
[single pass](DICTATION-SINGLE-PASS.md),
[editor models](DICTATION-EDITOR-MODELS.md), and
[continuous trial](DICTATION-CONTINUOUS-TRIAL.md).
Implementations are recoverable from Git history, including public tag v2.0.11.
The compiled editor, assembly code, benchmark entry point and overlapping-dictation
controller branches have been removed rather than left behind a hidden flag.

## Audio and recovery

Canonical 16 kHz mono capture remains independent of transcription. Rotation into
45-second WAV files is storage only; sequential files represent the full original
recording with exact offsets. Successfully completed audio is retained seven days
by default, with 30 days and Forever available. Failed, partial and cancelled audio
is preserved. Input validation, capture health, five-minute limit, cancellation,
durable save-before-paste and historical retry without insertion remain enforced.

Recovery of dictation uses the same live model, replaying saved audio at recording
pace with bounded buffers. It can therefore take roughly the recording duration
plus connection/finalization time. It does not call file transcription or a text
editor. Adjacent storage files remain one open item. Real capture discontinuities
and transport failures are still explicit and cannot be presented as complete
coverage. Original recordings remain available after a failed or cancelled retry.
Legacy transcript and diagnostic fields remain decodable; existing text is not
rewritten when opening old history. Obsolete formatting failures no longer produce
an unusable formatting-retry control.

## Connections, cost and packaging

Direct OpenAI and Team dictation use the same live configuration. The Team relay
accepts minimal delay and bounds unacknowledged audio to 20 MiB for that mode,
covering five minutes of 24 kHz PCM16 encoded as base64. Existing low-delay meeting
connections retain their 2 MiB window. Frame/rate, session, credential and protocol
validation remain in place. The server change must be deployed before public app
publication so Team users do not receive a rejected configuration.

As checked in the trial, [live transcription](https://developers.openai.com/api/docs/models/gpt-live-transcribe)
is $0.017 per audio minute, versus $0.0045 for the previous committed/file model.
There is no dictation editor charge or overlapping-audio overhead now. Faster
completion does not mean a cheaper audio model.

App packaging now stages bundles inside `.app-staging.noindex`; notarization uses
a `.noindex` work directory. Install the final app in `/Applications/Transcribe.app`.
Keep rollback artifacts compressed or in Trash rather than leaving launchable
backup bundles in indexed Documents folders. The owner requested a single visible
installed copy after old test artifacts filled the app launcher.

## Verification

Core tests exercise a 6,000-frame five-minute stream with one commit, accumulated
live deltas, startup buffering, upload stalls, exact resampler coverage, and live
replay across adjacent saved WAV files. Replay cancellation must close transport
and preserve audio. Coordinator tests cover the sole mode for both connections,
ignored old switches, provisional History drafts, exact durable delivery, partial
recovery and historical retries. Existing meeting, microphone, cancellation,
credential, paste, native shortcut and updater checks remain applicable. The relay
suite covers a full five-minute open item, its final completion, the bounded
continuous cap and unchanged limits for existing meeting clients.
