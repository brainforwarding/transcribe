# Live meetings implementation proposal

Status: independently reviewed and refined before implementation, 2026-10-11. Root accepted the material corrections below; the owner has authorized the feature and deployment.

## Product contract

New meetings stream through `gpt-live-transcribe`. Draft text may change while a passage is being recognized. Once a completed passage is saved, its words and ID remain permanent. Stopping finishes outstanding passages and generates a separate summary; it does not run Luna or replace the transcript with a second full-recording transcription.

Online meetings use two independent transcription connections, microphone labeled **You** and Mac audio labeled **System audio**. In-person meetings use one microphone connection labeled **Microphone**. These identify physical sources, not individual speakers. Several remote people can share System audio; several people in a room can share Microphone.

Time labels describe the captured **audio interval submitted for a passage**. They do not claim word timestamps or identified speaker turns. Missing passages can be filled later from saved audio without changing already confirmed passages. Existing dictation formatting, insertion, old meeting records, imports, and legacy CLI behavior remain compatible.

## Evidence and API contract

The current [Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription) specifies the live model, 24 kHz PCM input, client commits, delta/completed events, optional context hints, and `turn_detection: null`. The model does not support server or semantic VAD and supplies neither word timestamps nor speaker labels. `delay: "low"` is a proposed starting choice, not a latency guarantee. Actual microphones, accents, noise, and mixed languages need owner acceptance.

The current [official Node SDK URL builder](https://github.com/openai/openai-node/blob/master/src/realtime/internal-base.ts) explicitly supports transcription intent and constructs `wss://api.openai.com/v1/realtime?intent=transcription`, without a model query. Native header authentication is supported by the [WebSocket guide](https://developers.openai.com/api/docs/guides/voice-websockets) and [official Python connection code](https://github.com/openai/openai-python/blob/main/src/openai/resources/realtime/realtime.py). Use the normal Bearer header, not an archived beta header or credentials in a URL. This is distinct from the GPT-Live voice-agent API at `/v1/live/sessions`.

After connection creation, send and await successful session configuration before appending audio:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": { "input": {
      "format": { "type": "audio/pcm", "rate": 24000 },
      "transcription": {
        "model": "gpt-live-transcribe",
        "delay": "low"
      },
      "turn_detection": null
    } }
  }
}
```

Snapshot the selected provider, credential, languages, and dictionary when the meeting starts. Add validated `languages` and `keywords` when present; omit dictation formatting instructions. Send base64 PCM16 through `input_audio_buffer.append`, then `input_audio_buffer.commit`. Do not send `response.create`, tools, voice settings, or assistant-generation requests. The [client-event reference](https://developers.openai.com/api/reference/resources/realtime/client-events) documents that append has no acknowledgment and empty commits fail. The [committed-event schema](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/input_audio_buffer_committed_event.py) provides `item_id` and `previous_item_id` for association. Completion order must not determine transcript order.

## Current code and bounded changes

`PCMTrackWriter.swift` already writes separate mono 16 kHz float WAV parts, retains host-clock gaps, and persists capture manifests. `CaptureController.swift` shares one host epoch and starts the microphone independently. The current preview mixes finalized 45-second files. `Pipeline.swift` currently retranscribes entire sources using diarized file output. `Segment.turnID` already supports evidence references. `AppModel.process` currently replaces the complete meeting text at stop. `proxy/worker.js` accepts only POST file transcription and chat; it has no WebSocket upgrade route.

Keep those durable raw tracks. Add an optional capture-frame callback for meetings after a successful raw write, carrying owned PCM data, source, shared-epoch offset, duration, and RMS. A dedicated converter produces mono 24 kHz signed PCM16; do not relabel existing 16 kHz bytes. Converter state resets at actual capture discontinuities. No AVAudio buffer escapes its capture queue.

The callback performs a nonblocking offer into a bounded queue, approximately two seconds per source. Network work and transcript saving execute elsewhere. Overflow, encoder failure, or disconnection marks the entire affected unconfirmed interval for recovery. A partial upload must never be accepted as if it covered the whole planned interval. Capture continues and retains audio even if live transcription becomes unavailable.

## Turns, durable text, and time

Initial boundary policy: stream all captured audio in roughly 100 ms batches; use RMS only to choose a commit boundary after about 700 ms quiet following signal, with a hard maximum of 10 seconds. This is a pause heuristic, not semantic VAD. It does not suppress soft speech or remove silence. Quiet-only intervals are bounded too; a successful empty completion records coverage without displaying an empty transcript row. Thresholds are named internal constants requiring offline boundary fixtures and owner microphone acceptance.

Allocate a stable per-source ordinal before sending each commit. Persist its local ID and exact start/end from the audio frames. Suggested `MeetingTurn` fields are ordinal/segment index, source, start, end, state (`pending`, `confirmed`, `needsRecovery`), origin (`live`, `recovered`), text, and optional safe failure category. The record has a versioned live-meeting marker and backward-compatible optional turns. Existing records without that marker retain their existing behavior.

Associate each server commit acknowledgment with the next queued local commit on that connection. Keep a generation-scoped item-ID map; buffer early deltas/completions until association is known. Never infer an ID from completion arrival order. Limit uncompleted commits, for example four per source; exceeding the bound closes that connection and retains affected intervals for recovery instead of growing memory indefinitely.

On completion, atomically save the confirmed turn and its projected Segment/transcript together, then publish it as confirmed. Ignore duplicate or stale completions. An already confirmed local ID cannot be overwritten by reconnects, retries, or delayed events. Drafts are separate ephemeral state, throttled for UI updates. Reuse stable Segment IDs for summary evidence; never renumber when an earlier missing turn is filled. Mark new segment timing as application audio intervals, preserving legacy model timing on old records.

For an actual audio discontinuity, end the old interval at its last real frame and open another at the next real offset. Never bridge the gap with invented speech timing. A crash recovers manifests and compares recorded spans against sealed turn coverage; remaining actual captured ranges become pending recovery intervals. Confirmed empty turns count as coverage. Truly uncaptured gaps remain unrecoverable and receive one concise notice.

## Disconnect, stop, and recovery

Use bounded reconnect delays and fresh connection generations. Authentication, billing, or access failures stop automatic reconnect attempts and use the existing safe classified notice. New captured audio can resume live on a new connection; prior unfinished intervals remain explicitly pending. Do not replay already confirmed text or audio.

At stop, close capture first, finish each nonempty open buffer, and allow a bounded completion drain, proposed 10 seconds. Retain every unfinished interval as `needsRecovery`. If network access is available, recover only those intervals with the existing file `gpt-transcribe` provider and cache, without a formatting prompt or Luna. Extract exact source ranges from retained tracks into stable files; never include confirmed neighbors as recognized output. A successful missing-interval response fills that same ID, preserving application interval timing. Ordinary failures preserve saved audio and offer manual Retry. Historical Retry never inserts text into another app.

Never-submitted contiguous coverage is split into at most 300-second recovery intervals, keeping 16 kHz float WAV payloads below the provider and relay upload limit. Previously assigned interval IDs are preserved. Recovery requests and successful caches must remain stable across retries. Persist range identity and extracted-file digest before the request. A successful empty response seals that interval. Failed or unreadable ranges remain partial. Cancellation or quit preserves unfinished work; late results must match the meeting/task generation before saving.

The transcript is complete only when all captured intervals are sealed and no capture gap remains. Retain audio for partial/recoverable meetings regardless of the cleanup preference. Complete-meeting cleanup follows the existing preference only after all text is durable. Audio deletion cannot run while pending intervals still need it.

## Separate summary and UI

Reuse structured `generateNotes` with confirmed Segment text and the original-notes snapshot. Preserve evidence IDs. A summary can be generated from confirmed partial content with an honest incomplete label; filling missing turns makes that summary stale, rather than changing its citations or silently claiming it covered new content. Regeneration updates only summary fields.

The UI shows source states, provisional live text, durable passages, and one human recovery notice. Stop drains/recoveries are distinct from live recording. No meeting text is automatically pasted. Source/time labels explain their limits without exposing protocol details.

## Team relay

Add one GET Upgrade route at `/v1/realtime?intent=transcription`, authenticated by the existing personal Team token. Forward to a fixed OpenAI transcription endpoint using the existing server-side credential. Preserve all current POST routing and credential isolation.

Permit only bounded JSON `session.update`, audio append, commit, and clear frames. Rebuild session configuration from allowed language/dictionary fields with a fixed live model, PCM format, null turn detection, and no assistant/voice/tool fields. Reject arbitrary queries, models, nested settings, invalid base64, oversized frames, and excessive audio/event rate. Return sanitized errors and close both sockets together. Never log frame bodies, audio, transcripts, credentials, or upstream error bodies.

Count authenticated upgrades against the existing per-person hourly rate policy; bound each connection's lifetime and byte rate as well. Existing KV counters are best-effort and must not be described as strict global concurrency enforcement. Handle advertised session expiration when supplied; otherwise use a conservative boundary rotation before 50 minutes. Long meetings keep the same host epoch and local IDs across rotations. Rotation failures follow the same missing-interval recovery path. The exact dedicated-session maximum is not assumed from older voice-session guides.

## Ownership and verification

Core/coordinator owner: new `RealtimeTranscriber.swift`, `LiveMeeting.swift`, and offline live selftests; minimal capture callback wiring in PCMTrackWriter/MicCapture/SystemAudioCapture/CaptureController; missing-range extraction in Pipeline; additive Segment/SessionRecord schema; AppModel start/stop/retry and coordinator fixtures. Reuse the existing file provider and error mapper.

Root owns Config fixed WS URL selection, proxy route/tests/deployment, review, Git, and product decisions. UI agent owns meeting view state and source/time wording. Native agent owns packaging and platform integration. Agree exact structs/callbacks before parallel edits; no two agents edit AppModel or schema concurrently.

Offline tests must cover configuration and PCM conversion, boundary intervals, source overlap, reordered/early/duplicate completions, queue overflow and partial sends, disk-save failure, reconnect generations, cancellation/quit, crash tail coverage, empty completions, stable cached missing-range recovery, immutable confirmed text/IDs, summary citation stability, provider isolation, and proxy frame rejection. Existing dictation/core/coordinator checks must pass. No live API/audio/paste/UI tests are part of this implementation verification; the owner evaluates actual latency, Spanish/Portuguese code-switching, long meetings, and microphone echo.

Tradeoffs requiring acceptance: two full audio streams cost more than one mix; source labels preserve useful provenance but do not diarize remote participants. Laptop-speaker sound can also enter the microphone, causing duplicates; this proposal does not pretend RMS or text deduplication is acoustic echo cancellation. Headphones reduce that overlap. Continuous silence is initially sent for faithful coverage; any later silence gating needs separate acceptance. Network recovery may incur an additional file-transcription request for a turn the server processed but the client never durably received. Live timing is interval-level, not word-level. None of these limitations permits rewriting confirmed passages.

## Accepted independent review corrections

New live records have dedicated stop/retry handling outside AppModel.process’s legacy wholesale replacement path. Recovery calls cachedAudioTranscript(model: .text, prompt: nil) directly. Existing legacy meeting processing remains compatible.

Outgoing events carry unique event_id values. A rejected/ambiguous append or commit invalidates the connection generation and marks every affected unconfirmed interval for recovery. Validate previous_item_id chains; never shift a later ACK onto a rejected ordinal. Keep early item storage bounded. Provisional per-source/item drafts may display before ACK without durable timing claims. Very short stop/discontinuity tails below the server’s commit minimum are retained for file recovery instead of forcing rejected empty/short commits.

Emit callbacks only from successfully written canonical mono portions and derive offset/duration from those exact spans/frame counts. Reset live conversion on actual discontinuities. Coverage is captured ranges minus sealed ranges, including empty confirmed turns. Do not claim writeAlignedAudio silence padding as recovered capture. Live network failure never sets captureIncomplete; true unavailable/unreadable capture remains incomplete. Distinguish a system source that emitted no buffers from proven capture loss.

Use one meeting-wide stop/drain deadline for both sources. Coalesce contiguous never-submitted raw coverage into bounded file-recovery intervals before assigning persistent retry identity, while preserving existing commit IDs. Bound recovery concurrency and circuit-break account/access/billing failures. Explicit live task ownership participates in cancel/quit/updater safety; close old generations before recovery. Cleanup additionally requires sealed coverage. Summary provenance includes transcript revision/basis beyond cited IDs and becomes stale after new confirmed passages.

Deferred acoustic echo cancellation, speculative deduplication, participant diarization and silence suppression. No bespoke per-word alignment. The relay must bound client input and forwarding queues and preserve safe classified errors.
