# Dictation boundary checks

Historical experiment. Superseded by the [continuous dictation decision](DICTATION-DECISION.md) for 2.1.0.

**Retired after the 18 October real-voice trial.** Its audio rechecks caused 34.6 s
of a 41.1 s completion. The app now uses overlapping chunks and one text assembly
prompt. The measurements below document the retired experiment, not the active design.

18 October 2026. Local experiment, off by default. Public release remains held.

## Implementation

The earlier experiment committed at 10 s even in the middle of speech. Experimental
dictation now targets a pause after 10 s and only forces a cut at 20 s. It accepts
0.3 s of quiet after the target, or 0.7 s before it. This is amplitude-based pause
detection, not sentence recognition. The existing meeting policy remains unchanged.
The stop path also finalizes the actual remaining audio; it does not invent padding.

Every persisted turn records why it ended. At stop, after missing-coverage recovery,
forced or unknown adjacent cuts are checked against a six-second window, three seconds
on each side (clipped to actual audio). Three-word anchors must be unique in both the
window transcript and the original adjacent transcripts. The words between anchors
must agree exactly, ignoring ordinary punctuation/capitalization. Accents, quantities,
signs and negations remain significant. Repeated/short/ambiguous anchors fail this check.

When that check fails, the whole connected passage is recognized from the saved audio
as one file. Its response owns that complete time interval and replaces its text once.
There is no text-only deduplication and no instruction to the final editor to invent
missing words. Multiple forced joins in one continuous passage collapse into the same
whole-passage check; actual capture gaps never become padded, supposedly complete audio.
A continuous group over six minutes fails instead of introducing another unverified cut.
This leaves headroom beyond the app’s five-minute recording cap, within the upload limit.

Confirmed original turns remain immutable evidence. The separate reviewed assembly is
bound to their exact snapshot and persisted before punctuation formatting or delivery.
Successful audio requests are cached by audio digest and recognition configuration for
retry. Cancellation, provider failure or save failure retains audio, prevents automatic
insertion/cleanup and permits explicit historical recovery. Historical retry never pastes.
Turning the experiment off restores standard capture, while existing attempts retain their
stored recovery method. Older experimental turns without cut metadata receive conservative
checks. No production relay, credential, appcast or public release was changed.

Agreement is evidence, not an accuracy guarantee. Both recognitions can make the same
mistake; errors away from the checked boundary remain ordinary ASR errors. This approach
specifically reduces boundary risk without making the punctuation editor a second ASR.
Whole-passage fallback may give up much of the speed benefit after uninterrupted speech.

## Reproduction

The corpus is public synthetic speech, generated locally using macOS Samantha and Paulina.
It contains English midword cuts, Spanish midword cuts, quantities, negation, repetition,
spoken corrections, a language switch, and a known-pause control. Forced fixtures place a
specified spoken word across exactly 20 s. Long synthetic silences are capped at 80 ms,
and the prefix is resampled to position the target. This intentionally artificial stress
test is not a substitute for natural voices, accents, noise or microphone evaluation.

```sh
python3 TranscribeBar/scripts/generate-boundary-fixtures.py /private/tmp/boundary-audio
bash TranscribeBar/scripts/benchmark-dictation.sh /private/tmp/boundary-audio/english-midword.wav build-only
python3 TranscribeBar/scripts/evaluate-dictation-boundaries.py \
  /private/tmp/boundary-audio/manifest.json \
  /absolute/path/printed/by/build/Transcribe.app/Contents/MacOS/Transcribe \
  /private/tmp/boundary-results
```

The separate signed benchmark uses the configured app credential without interaction or
changes. It does not instantiate AppModel, access history, record the microphone, paste,
or change owner preferences. Each fixture runs serially through whole-recording Standard,
the original 10 s Background policy (Legacy), protected Background and protected Live.
The current harness replays streaming audio against absolute monotonic deadlines,
prevents App Nap during evaluation and records replay wall time. Each method has a fresh cache. Existing reports
are reused on an evaluator rerun; use a new output directory for independent repetitions.

Word error rate folds case/punctuation and maps only seventeen/diecisiete to 17 and
seventy/setenta to 70. It preserves other lexical differences. The report separately
checks expected negations/repetitions and exact counts of those quantities. API responses
and formatting time vary, so a single run per fixture/method cannot establish tail latency.
The initial accuracy batch used relative per-frame sleeps; a separate serial
Standard/Background repeat verifies pacing and stop-to-ready timing with the improved
harness. The raw transcript is scored; formatter fidelity is independently guarded in production.

## Initial measured accuracy

Twenty serial API runs: five synthetic fixtures through four methods, using the
configured direct OpenAI connection and separate fresh caches. Each method saw the
same 344 reference words across the five files. WER is measured before punctuation
formatting and is normalized only as described above.

| Fixture | Whole recording | Earlier 10 s chunks | Protected Background | Protected Live |
| --- | ---: | ---: | ---: | ---: |
| English midword | 0.0% | 0.0% | 0.0% | 0.0% |
| Spanish midword | 2.6% | 6.6% | 2.6% | 2.6% |
| Repetition and correction | 0.0% | 1.3% | 0.0% | 0.0% |
| Language switch and negation | 0.0% | 1.4% | 0.0% | 0.0% |
| Known pause | 0.0% | 0.0% | 0.0% | 0.0% |
| Combined WER | 0.58% | 2.03% | 0.58% | 0.58% |

The earlier Spanish cut produced “dieciséis. Siete” instead of “diecisiete”. The
correction fixture lost a spoken quantity, and the language-switch fixture dropped
“no”. Both protected modes retained all checked quantities, negations and repetitions.
They used whole-passage fallback for those three difficult cases. English's crossing
window agreed without full-passage fallback. The known-pause control made no boundary
recognition requests. The Spanish reference had an orthographic word-splitting difference
in every otherwise successful method; matching WER is not a claim of perfect recognition.

These are five designed synthetic cases, with one run per method, not evidence of
population-level accuracy, accent robustness or recognition confidence. Four of the five
fixtures intentionally force a cut, so their latency distribution is also stress-biased.

## Paced timing repeat

Ten additional serial runs repeated Standard and protected Background with absolute
deadlines and App Nap disabled. Playback wall time, including controller startup,
stayed within 0.6% of audio duration. Each output again retained all checked
quantities, negations and repetitions.

| Fixture | Standard ready after stop | Protected Background | Whole-passage recheck |
| --- | ---: | ---: | --- |
| english-midword | 4.54 s | 4.34 s | No |
| spanish-midword | 5.40 s | 8.62 s | Yes |
| repetition-correction | 5.27 s | 9.32 s | Yes |
| language-switch-negation | 4.04 s | 7.35 s | Yes |
| pause-control | 2.87 s | 1.93 s | No |

The correction repeat also needed saved-audio recovery after a live connection
problem, and its first forced cut occurred at 24 s after reconnecting. Its 9.32 s
includes that recovery; it is retained in the results. The initial run for that
fixture forced the intended 20 s boundary without connection recovery.

The pause control improved from 2.87 s to 1.93 s (about 33%) in this repeat.
Forced-cut fallback was slower than Standard in three cases. This experiment is
therefore ready for a reversible owner trial, not a claim of uniformly faster
dictation or a reason to enable it for all users. Future latency work should move
audio checks into recording time while retaining the content checks.

Raw public fixtures, reports, scores and verification logs are under ignored local
`TranscribeBar/build/boundary-evaluation-2026-10-18/`. The app at
`TranscribeBar/build/Transcribe.app` was updated locally and relaunched idle. The
experiment preference remains off. A rollback bundle and session metadata copy
were preserved under `~/Documents/Transcribe Builds/Transcribe-before-boundary-checks-wpvc2_ig/`.

## Verification

Deterministic tests cover unique/ambiguous anchors, deliberate repetition, missing
negation, changed quantities, code switching, split words, pause preference, forced-cut
metadata, complete-group fallback, cache reuse, capture gaps, restart and stale assemblies.
All core checks, 66 actual AppModel lifecycle checks, 94 native shortcut/cache/paste
checks and signed-package verification passed. Actual AppModel tests cover review before
formatting, delivery and cleanup; provider and
save failures; cancellation during review; and historical retry with the experiment off.

## Release gate

Keep the experiment off by default and hold public release until the boundary measurements
are assessed and a natural-voice owner trial is reviewed. Include long continuous speech,
soft speech, noise, names, dates, amounts and code switching. Measure both critical content
errors and median/tail stop-to-ready latency with repeated trials. Do not describe audio
coverage or agreement between two recognitions as proof of word accuracy.
