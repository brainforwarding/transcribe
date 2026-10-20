# Continuous dictation local trial

Historical experiment. Superseded by the [continuous dictation decision](DICTATION-DECISION.md) for 2.1.0.

19 October 2026. Local 2.0.12/build 14 only. Public 2.0.11 is unchanged.

Settings has one Fix grammar switch, replacing the Faster dictation control.
It defaults on. On an OpenAI connection, on selects committed overlapping
background transcription and the existing Luna Fast assembly/cleanup request.
Off selects `gpt-live-transcribe` with `delay=minimal`, streams the full recording
as one open item, commits at stop and skips both assembly and formatting.
There are no scheduled cuts, pause cuts or replayed overlap in the continuous
path. Actual capture discontinuities and connection failures remain explicit.

The choice is saved on each SessionRecord as optional `fixGrammar`. Historical
records without it keep cleanup enabled. Continuous records use live dictation
version 4. Later preference changes cannot change an active recording, saved-audio
fallback or historical retry. The Team relay keeps its existing ordinary mode;
its bounded unacknowledged-audio window is incompatible with an uncommitted
five-minute stream, so this trial's switch requires a direct OpenAI connection.

Live drafts appear in dictation History while speaking. They stay provisional;
only a saved completed transcript is eligible for automatic delivery. There is
no incremental typing into the focused external app. Original capture and the
existing seven-day retention/recovery behavior are unchanged. If the live service
fails, saved-audio fallback still honors Fix grammar off and does not run an editor.
Historical retry never inserts automatically.

The continuous connection uses a 330-second request timeout, a bounded ten-second
startup PCM buffer and a ten-second final completion deadline. The old two-second
startup limit dropped prefixes when session configuration took longer, and the
short transport timeout interrupted an otherwise active continuous connection.
The continuous outbound queue also holds up to ten seconds of audio, with a
bounded event queue, to absorb short upload stalls. A first 115-second network
trial overflowed the old two-second queue and safely fell back to the saved
recording; this took 8.615 seconds after stop. Other recording modes retain their
existing two-second upload limit.
Longer trials also exposed an existing 2,048-append-event bookkeeping limit at
102.4 seconds. Continuous input does not retain append event IDs: generation
guards already associate errors, and the only commit occurs at stop. The normal
chunked path retains its existing bound. A 6,000-frame, five-minute core regression
verifies that continuous capture remains one item and never hits that old cutoff.
Before commit acknowledgment, draft deltas are aggregated with bounded text/item
limits rather than retaining every delta event. This supports long streams without
the former 128-event cap. Final completed text replaces the provisional draft.

The official [OpenAI live transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
documents ongoing deltas, explicit end-of-turn commit, `turn_detection=null` and
the `minimal` delay setting. Finalization still takes provider/network time.
[Live transcription](https://developers.openai.com/api/docs/models/gpt-live-transcribe)
is listed at $0.017/min and [committed/file transcription](https://developers.openai.com/api/docs/models/gpt-transcribe)
at $0.0045/min as checked for this trial. Audio overlap and the cleanup model are
additional in the background path. Turning cleanup off changes the ASR model;
it does not imply lower total cost.

Synthetic public-fixture network replays, using one actual model item and no
editor, completed 27.84 seconds of English in 1.673 seconds after stop and 28.87
seconds of Spanish in 0.575 seconds after stop, without recovery. First live
drafts appeared 3.58 and 2.94 seconds after start, including connection setup.
These are small synthetic tests, not guaranteed timings for the owner's speech.
Reports and safe wire metadata are under ignored
`TranscribeBar/build/continuous-evaluation/minimal-*`.

After correcting the append-event limit, a 107.02-second mixed English/Spanish
replay completed in 0.714 seconds after stop, with its first draft at 3.15 seconds.
It produced exactly one confirmed item covering the entire recording, with no
recovery, no editor call, and identical raw/final text. The report is under
`TranscribeBar/build/continuous-evaluation/final-varied-long/report.json`.
The final installed build was verified in Settings as 2.0.12, Fix grammar off,
OpenAI connection, and seven-day audio retention. All 53 source hashes match
the packaged build and the installed executable matches the staged artifact.

Core tests cover a 30-second stream spanning old cut boundaries and pauses with
zero intermediate commits, more than 200 pre-commit deltas, one final item,
delayed-start prefix preservation, actual final text, and backward-compatible
record snapshots. Coordinator checks cover live History drafts, no editor calls,
durable insertion, changed preferences, cancellation and historical fallback.
Core, lifecycle, updater and signed-package checks passed. The normal app excludes
the compile-only benchmark and its wire diagnostic transport. Existing 68 record
JSON files were byte-identical after installation. The previous app is privately
backed up under Documents/Transcribe Builds; no public release/feed was changed.
