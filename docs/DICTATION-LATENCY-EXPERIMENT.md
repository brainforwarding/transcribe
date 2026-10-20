# Dictation speed experiment

Historical experiment. Superseded by the [continuous dictation decision](DICTATION-DECISION.md) for 2.1.0.

**Current design, after the 18 October owner trial:** Background is the only fast
mode. Forced chunks carry two seconds of overlap. One final GPT-6 Luna text request
receives the ordered chunks, timings and overlap durations and performs assembly
and punctuation together. The audio boundary-recheck stage has been removed.
The older comparisons below are historical. Settings has one switch and an
approximate 1.1× audio-cost estimate; diagnostics remain local metadata, not history UI.

18 October 2026. Local experiment only. Public release is held for the owner's trial.
The missing-microphone, failed-history, spinner and measured-volume-history fixes
are included in the pending build.

## Decision

Keep normal dictation as the default. Settings → Dictation speed has an opt-in
**Faster dictation (experimental)** switch and two methods. **Background** is the
initial experiment: it uses the current recognition model on committed audio turns
while the user speaks. **Live** is a comparison using continuous recognition.
Audio checks can add recognition requests, waiting time and cost. Turning the switch off restores the original upload-after-stop path. A recording
snapshots its method, so changing the preference cannot change its recovery path.

The experiment currently requires the OpenAI connection. The first Team relay test
fell back for all audio and was slower. Team keeps standard dictation until its
relay is separately validated; no production relay change was made.

## Measured comparison

One run per language and method, on the same Mac through the configured direct
OpenAI connection. Public synthetic phrases were generated with macOS speech,
converted to 16 kHz mono WAV, and replayed at capture speed for streaming methods.
Timing starts after the final audio frame and ends after formatting, before paste.
These are smoke measurements from the initial implementation, before boundary checks.
They are not median/tail latency or proof of microphone accuracy. Current boundary
checks have a separate measured comparison below.

| Sample | Method | Recognition after stop | Formatting | Ready after stop | Recovery |
| --- | --- | ---: | ---: | ---: | --- |
| English, 15.10 s | Standard | 2.77 s | 1.32 s | 4.09 s | No |
| English, 15.10 s | Background | 0.60 s | 1.85 s | 2.45 s | No |
| English, 15.10 s | Live | 0.67 s | 1.46 s | 2.13 s | No |
| Spanish, 16.96 s | Standard | 1.25 s | 2.27 s | 3.52 s | No |
| Spanish, 16.96 s | Background | 0.66 s | 1.50 s | 2.16 s | No |
| Spanish, 16.96 s | Live | 0.66 s | 1.93 s | 2.59 s | No |

Background reduced total waiting by about 40% in English and 39% in Spanish in
these runs. The recognition tail was similar across the two streaming methods;
formatter variability accounts for much of the difference between them. All
direct streaming runs covered the complete file without recovery. Live's first
English partial appeared about 2.10 s after replay began, but partial words are
never pasted. The sample includes numbers, a date, a currency amount and a negation.
All retained the negation and quantities on inspection. Number presentation varies
between models/turns, and the unhinted Spanish pronunciation of “Circles” was
misspelled in every method. This is not a broad quality evaluation.

The initial Team comparison measured 5.35 s standard and 18.87 s live, with no
live-confirmed coverage. It is recorded as a failed candidate, not omitted from
the evaluation. Direct OpenAI measurements above use fresh caches and the correct
provider. Raw reports/audio remain under ignored build output.

## Boundary follow-up, 18 October

[Boundary evaluation](DICTATION-BOUNDARY-EVALUATION.md) records 20 accuracy runs plus
10 deadline-paced Standard/Background repeats. The protected paths matched Standard's
0.58% WER on this small synthetic corpus, compared with 2.03% for the original chunking
policy. All checked quantities, negations and repetitions were retained. The known-pause
repeat improved from 2.87 s to 1.93 s after stop. Whole-passage fallback made three forced-cut
cases slower than Standard, so these results do not justify a default rollout.

## Other approaches

| Approach | What it could improve | Decision |
| --- | --- | --- |
| Background recognition with the existing model | Moves most recognition into recording time; retains the current model/rate | Implemented as the initial experiment |
| Continuous live recognition | Earlier partial text | Implemented as the higher-cost comparison |
| Streaming a completed audio file | Earlier preview after stop; still requires the stopped recording | Does not remove the main sequential dependency |
| Format completed paragraphs while speaking | Could overlap the remaining 1–2 s formatting work | Follow-up; needs tests for later corrections and paragraph context |
| Return raw recognized text immediately | Removes formatting wait | Possible separate preference, but changes output quality |
| Predicted output for formatting | Could accelerate small edits on a supported model | Current formatter model is not listed as supported; no model migration made |

OpenAI documents both live deltas and committed-turn recognition, and states that
earlier committed turns provide context for the latter. [Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription).
Current audio rates are $0.0045/min for [GPT Transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe)
and $0.017/min for [GPT Live Transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe),
before formatting and any recovery. [Predicted Outputs](https://developers.openai.com/api/docs/guides/predicted-outputs)
lists support for GPT-4o/4.1 model families, not the current GPT-6 Luna formatter.
These are independent architecture experiments; the internal implementation of
Willow or Wispr Flow has not been established.

## Content and cancellation guarantees

- Canonical microphone audio is written locally before frames are offered to the network.
- Only confirmed, saved turns become raw text. Recognition gaps retain their owned audio.
- At stop, drain pending results for at most two seconds, then recover missing coverage.
- Dictation waits for pauses, with a 10 s target and 20 s forced ceiling. A short 0.3 s
  quiet period is sufficient after the target; earlier commits still require 0.7 s.
- Forced and unknown joins are checked against crossing audio before formatting/delivery.
  Ambiguous alignment or lexical disagreement causes whole-passage audio recognition,
  rather than a text-only splice. See [boundary evaluation](DICTATION-BOUNDARY-EVALUATION.md).
- Failed/cancelled/unsaved boundary checks retain audio and cannot deliver automatically.
  Audio coverage alone is not proof of word accuracy.
- Raw dictation remains plain text. Meeting timestamps/labels never enter dictated output.
- Both methods share the existing punctuation formatter and its word/number fidelity guard.
- Formatting finishes and text is saved before the existing guarded current-caret paste.
- Escape retains audio/text, blocks late insertion and cleanup, and skips recovery on cancel.
- Historical recovery works from the stored recording mode even after the experiment is off.
- Timing stays in the local session record; no analytics service or new credentials are added.

## Reproduce and test locally

`TranscribeBar/scripts/benchmark-dictation.sh synthetic-16k-mono.wav` builds a
separate signed app with `TRANSCRIBE_DICTATION_BENCHMARK` as a compile-only flag.
It uses the app's configured provider/credential without interaction, never creates
AppModel, and never touches capture, shortcuts, clipboard or owner history. Reports
contain the supplied audio's text and are private local files. The normal packaging
command rebuilds without this flag; the benchmark entry point is absent from normal releases.

The regular regression checks cover default/off behavior, each stored mode,
confirmed-text durability, missing-tail/full-connection recovery, formatting and
current-caret delivery, cancellation during capture/formatting, restart recovery,
short finalization deadlines, and unchanged meeting behavior. Visual renders verify
that spinner pixels change, voice history moves, and silence stays still.

For the owner trial, compare the same real utterances with the switch off, Background,
and Live. Include short/long dictation, English, Spanish and code-switching; names,
dates, amounts, email addresses, corrections and negations; quiet speech/noise;
network failure and reconnect; and Escape while finishing. History shows each
method's measured time after stopping and whether saved-audio recovery was needed.
Do not publish the new version before this trial is assessed.
