# Single-prompt dictation

18 October 2026. Included as an optional setting in release 2.0.11,
following the owner's local trial and approval to publish.

The owner's 252.95 s recording used Background, with 13 confirmed turns. Of its
41.118 s stop-to-ready time, 34.592 s was audio boundary review, 5.688 s formatting,
and about 0.834 s the final recognition tail. The amplitude threshold never found
a pause in that recording, so every intermediate turn hit the forced cutoff.
A disagreement on the second short crossing window caused recognition of the
entire connected four-minute passage. This defeated the purpose of doing ASR
while the user was speaking. That design is removed from the running pipeline.

Background now sends captured audio on one persistent recognition connection,
committing near pauses or at a 20 s ceiling. A forced cut retains two seconds of
actual PCM context and sends it at the beginning of the next turn. That means
20-second turns progress by about 18 seconds during uninterrupted speech. The
maximum normal long-recording audio overhead is about 20/18 = 1.11, shown compactly
as approximately 1.1× audio cost. Short or pause-separated speech can use less.
Failures requiring audio recovery can add cost; this estimate is not a billing cap.

With complete recognition, stop uses ONE text request, using GPT-6 Luna without
reasoning on the Fast tier, for assembly and punctuation together. The payload contains every chunk
in time order, start/end seconds, the true overlap duration and its transcript.
The prompt removes overlap once, prefers interior wording over clipped edges,
keeps genuine repetition, corrections, quantities, negations and language switches,
and treats dictated instructions as content. There is no audio rechecking stage,
full-passage retranscription, or additional punctuation request in normal completion.
If background recognition is incomplete, dictation instead uses the established
whole-recording transcription and ordinary formatting path. The original turns remain
stored. This exceptional fallback avoids retrying a tiny missing fragment whose edge
can cut a number in half. Meetings retain their separate missing-only recovery behavior.
Historical formatting retry uses this same assembly path and never inserts text.
If assembly fails or is cancelled, original chunks and audio remain saved and
provisional overlapping text is not automatically pasted. A prompt cannot guarantee
recognition accuracy; the original capture and chunks remain available for review.

Sending the owner's 13 saved chunks through one assembly request took 6.754 s
without failure. This measured the editing request using the saved transcripts,
not an end-to-end replay of that recording: its audio had already been deleted by
the previous Keep audio=off setting. The existing saved transcription was not changed.

The history timing/method/recheck footer is removed. Settings offers one Faster
dictation switch with a compact approximate audio-cost label; the Live selector
and explanatory paragraph are removed. The recording chip no longer stretches a
spacer after the timer and reserves space for a maximum five-minute dictation timer.
Existing live history preview stays visible while recording.

Original capture is saved independently of ASR as canonical 16 kHz mono WAV files,
rotated every 45 seconds, plus exact time-offset manifests. Those files collectively
contain the entire captured recording, including failed recognition regions; they
are not just successfully transcribed chunks. Actual capture gaps stay explicit.
The full recording can be reconstructed from those files without relying on the
recognized text. New successful recordings retain audio for seven days by default;
30 days or Forever are the other settings. Expiry uses a saved completion timestamp
and runs on launch and hourly while idle. Failed, partial, cancelled, formatting-failed
and older unmanaged recordings are not expired. Expiry removes owned audio/cache,
never the transcript. The earlier successful four-minute test's deleted audio cannot
be recovered by changing this preference now.

Core tests cover exact two-second replay overlap, ordered timestamped prompt payload,
one text request, immutable captured coverage, restart and expiry safety. Actual
AppModel tests cover one assembly call with no ASR review, delivery only after durable
assembly, failed assembly preserving audio, cancellation and history retry, plus the
seven-day default. Normal packaged builds exclude benchmark entry points.

Final prompt tests reused the actual overlapping English, Spanish and spoken-correction
chunks from the network replay. Each used exactly one editing request and no further
recognition. English and correction had zero normalized word errors; Spanish retained
the same two orthographic word-splitting differences as whole-recording transcription.
All checked quantities, negations and intentional repetitions were retained. The editing
requests took 1.85 s, 1.70 s and 2.35 s respectively. A first prompt version had repeated
one overlapping phrase; explicit overlap examples fixed that observed regression before
local installation. AppModel lifecycle checks, core contracts including raw
coverage/overlap and expiry safety, and signed-package verification passed.

See [editor model measurements](DICTATION-EDITOR-MODELS.md) for the controlled
plain-versus-assembly comparison, Fast-tier and Groq results, and the observed
connection-failure case that motivated whole-recording fallback.
