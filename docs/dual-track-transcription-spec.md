# Spec v2: dual-track transcription → single merged transcript

Status: IMPLEMENTED (Phase 1 + Phase 2 diarize) · Date: 2026-06-05 · Target: meetrec.py + main.swift (macOS 13–26)

> Implementation notes: Phase 1 (separate-track merge, READY-gated offset, mandatory
> appendix, `--mix`/local fallback) and Phase 2 (`--diarize-remote` with fragmentation +
> speaker-count + Spanish-translation fallback guards) are built and tested — merge unit
> tests pass, and the full transcribe+merge ran live on real recorded tracks. Phase 3
> (sub-100 ms sync, `known_speaker_references`, gpt-4o fixed-window mode) remains deferred.

## 1. Motivation
meetrec mixes mic + system into one mono track, so on crosstalk the model follows the
louder voice and loses the other, with no attribution. The two physical tracks already
are ground-truth speaker separation (mic = local user "You"; system = remote
participants "Them"). Transcribing them **separately** and merging on a shared timeline
gives clean attribution **without diarization** and never drops a side. Ideal for
**headset** users (primary user runs a Logi USB headset — no acoustic bleed). On
speakers the system bleeds into the mic; that case is guarded (warn + `--mix`).

## 2. Verified facts (live API + SDK 2.31.0, 2026-06-05)
- **Shared t=0 clock confirmed.** Same file via whisper-1 `verbose_json` and diarize
  `diarized_json` returned segment times on the same file-start clock (0.00→52.5 vs
  0.92→52.2) → cross-model/cross-track merge on one clock is valid.
- **Diarize misbehaves on single-speaker / Spanish:** invented a 2nd speaker,
  hallucinated an English opening, translated Spanish→English, fragmented into 0.1 s
  segments. ⇒ never diarize the mic; diarize is system-only, opt-in, guarded, fallback.
- **Timestamps:** ONLY `whisper-1` (`verbose_json`, `timestamp_granularities=["segment"]`)
  returns usable per-segment times. `gpt-4o-transcribe`/`-mini` support only `json`
  (no timestamps). diarize `diarized_json` has segment start/end (no granularities, **no
  `.language` field**). whisper transcriptions never translate (that's a separate
  endpoint); whisper `verbose_json` DOES expose `.language`, `.segments[].no_speech_prob`,
  `.avg_logprob`. `language` is a valid param for both models.
- **whisper-1 is NOT on OpenAI's retirement schedule** (the "June 2026" date is *Azure
  OpenAI's*, a different platform). It is the only OpenAI model with timestamps. Keep it;
  handle model-not-found as a soft error.
- **Pricing/accuracy (approx, 2026-06):** whisper-1 $0.006/min, gpt-4o-transcribe
  $0.006, mini $0.003, diarize token-billed (~$0.015/min, compute from `usage`). WER
  clean/noisy: gpt-4o 4.1/8.7, mini 4.8/10.1, whisper 5.3/11.2; multilingual gpt-4o 6.2
  vs whisper 8.1.
- **diarize SDK extras:** `chunking_strategy` required >30 s; `known_speaker_names[]` +
  `known_speaker_references[]` (≤4 speakers, 2–10 s clips) exist and could stitch
  speaker identity across chunks (Phase 3). diarize has a ~16k-token context → cap
  diarize chunk *duration*, not just the 25 MB file size.

## 3. Decisions from panel review (what changed from v1)
1. **Offset is fixed at the source, not accepted.** ffmpeg's mic start is **gated on the
   SCK recorder's first-audio-buffer**: `main.swift` prints `READY` to stdout on its
   first buffer; `record()` waits for it, then launches ffmpeg. This collapses the
   inter-track offset from SCK's ~1–2 s warmup to ffmpeg's small, ~constant open lag
   (~0.15–0.3 s) — below typical turn gaps. The residual is **measured** in Python
   (monotonic delta between seeing `READY` and ffmpeg launch + a small open-lag constant)
   and applied to mic segment times. The **two-section raw appendix is mandatory** ground
   truth; the `## Conversation` header notes ordering is turn-level.
2. **Merge = sort by `(start, source)` then coalesce on sorted-ADJACENCY** (same label,
   gap ≤ 1.5 s) — NOT group-by-label (which would destroy chronology). Drop empty
   segments; clamp non-monotonic. Overlap tagging is **cut from v1** (simple interleave-
   by-start; both sides kept).
3. **`--model` governs ONLY `--mix`/local** (keeps `gpt-4o-transcribe` default there). In
   separate-track mode the timestamped model is fixed to **whisper-1**; passing a
   non-timestamp model with separate-track is a **hard error** with a clear message (no
   silent degradation). Separate-track is the **default**; `--mix` is the opt-out.
4. **`--backend local` ⇒ forces `--mix` semantics** (no timestamps/diarize possible);
   incompatible with `--diarize-remote`/separate-track (warn + fall back).
5. **Per-track segmentation:** rewrite `mix_and_segment` so each track is downmixed to
   **mono 16 kHz m4a** and segmented independently, into **per-track-namespaced** chunk
   files (`mic_chunk_*`, `sys_chunk_*`) with an exact **`-segment_list … -segment_list_type
   csv`** for chunk offsets (only matters for >20-min meetings; ≤1 chunk ⇒ offset 0).
6. **Diarize fallback (Phase 2) uses concrete signals**, since `diarized_json` has no
   language: (a) implausible distinct-speaker count vs audio length; (b) micro-segment
   fragmentation (median seg <0.5 s or >30% sub-0.3 s); (c) **language cross-check via the
   whisper `.language` field** (run whisper on the system track too, which you need for
   fallback anyway); (d) coverage vs `resp.duration`. On any fail → use whisper "Them".
   Print a **Spanish hallucination warning** when `--diarize-remote` + Spanish.
7. **UTF-8 explicit** on file writes (Spanish). **Consent/privacy note updated**: two
   audio streams are uploaded, not one. Summary runs on the **merged conversation text
   only** (never the appendix — avoids double tokens).

## 4. Design

### 4.1 Capture (main.swift + record())
- `main.swift`: on the first audio buffer, write `READY\n` to **stdout** once (unbuffered),
  in addition to existing stderr diagnostics.
- `record()`: start SCK with `stdout=PIPE`; read until `READY` (timeout ~10 s) → record
  `t_ready` (monotonic); launch ffmpeg mic → record `t_ffmpeg`. `mic_offset =
  (t_ffmpeg - t_ready) + FFMPEG_OPEN_LAG (≈0.15)`. On timeout/EOF (e.g. permission
  failure) → `mic_offset = 0` + warn. Stop unchanged (Enter → q + SIGINT).

### 4.2 Per-track transcription → segments
- `transcribe_track(chunks, model, label, lang, chunk_offsets, base_offset) -> list[Segment]`:
  whisper-1 `verbose_json` + `timestamp_granularities=["segment"]` (+ `language` if set);
  for each chunk parse `.segments[].start/.end/.text`; drop `text.strip()==""`; drop
  likely-hallucinated silence (`no_speech_prob>0.6 and avg_logprob<-1`); global time =
  `base_offset + chunk_offsets[i] + seg.start`. mic uses `base_offset = mic_offset`;
  system uses `0`. Reuses the existing chunk loop (extract `_iter_chunks`).
- Diarize path (`--diarize-remote`, system only): `gpt-4o-transcribe-diarize`,
  `diarized_json`, `chunking_strategy="auto"`, duration-capped chunks; labels
  "Them — Speaker {A…}"; validated against §3.6 signals → fallback to whisper "Them".

### 4.3 Data model
```
Segment = {start, end, label, text, source}   # start/end: seconds on global clock
                                               # label: "You"|"Them"|"Them — Speaker A"
                                               # source: "mic"|"system" (tiebreak/provenance)
```
Layers: `transcribe_track()` (new, I/O) → `merge_segments()` (pure, unit-tested) →
`render_conversation()` / `render_appendix()` (pure). `transcribe_openai()` kept for `--mix`.

### 4.4 merge_segments() — pure
1. drop empty text; clamp `end=max(end,start)`.
2. stable-sort by `(start, source, end)`.
3. coalesce on **sorted adjacency**: merge next into cur iff `next.label==cur.label` AND
   `next.start - cur.end <= 1.5`; then `cur.end=max(...)`, `cur.text+=" "+next.text`. An
   interposed opposite-label segment breaks the run (preserves chronology).
4. return ordered blocks. (No overlap tagging in v1.)

### 4.5 Output (`transcript.md`, UTF-8)
```
# Meeting transcript — <stamp>
_Ordering is turn-level; within ~1 s exchanges may be approximate — see appendix._
## Summary            (LLM, on merged conversation text only)
## Conversation
[00:00] You:  …
[00:05] Them: …
## Appendix — raw per-track transcripts   (ground truth, always present)
### You (mic) …   ### Them (system) …
```
`--no-timestamps` drops the `[mm:ss]`. Single track present ⇒ render that track only
(no appendix split). `--mix`/local ⇒ existing single-transcript output.

### 4.6 Flags
| Flag | Default | Notes |
|---|---|---|
| `--mix` | off | legacy mixed-track path; implied by `--backend local` |
| `--diarize-remote` | off | system track only; whisper fallback; Spanish warning (Phase 2) |
| `--me NAME` / `--them NAME` | You / Them | labels |
| `--lang CODE` | auto | language hint to whisper/diarize |
| `--timestamps/--no-timestamps` | on | ignored in `--mix`/local |
| `--model` | gpt-4o-transcribe | **only governs `--mix`/local**; separate-track fixes whisper-1; hard-error if a non-timestamp model is named with separate-track |
| `--backend {openai,local}` | openai | local ⇒ forces `--mix` |
| `--keep-audio`,`--summary-model`,`--no-summary` | — | unchanged; cleanup handles per-track chunks |

### 4.7 Edge cases / guardrails
- Headset vs speakers: separate-track default; **warn if default output device transport
  is Built-in speakers** (heuristic via `system_profiler SPAudioDataType -json`; USB/BT/
  Virtual treated safe; document USB-external-speaker false-negative). Optional post-hoc
  bleed check (mic⨯system correlation) deferred.
- Empty/silent track → single-track render (existing fallback). Failed chunk → `_(chunk N
  failed)_` marker (existing), leaving a labelled gap (acceptable).
- diarize degradation → whisper fallback (never emit hallucinated text silently).

### 4.8 Cost (approx/hr): whisper both ≈ $0.72; `--diarize-remote` ≈ $1.26 (compute from
`usage`). Current `--mix` ≈ $0.36.

## 5. Phasing
- **Phase 1 (this iteration):** READY-gated capture + offset; per-track mono segmentation;
  whisper both tracks; Segment model; `merge_segments`; Conversation + mandatory appendix;
  flags; `--mix`/local fallback; UTF-8; consent update. Unit-test merge; validate the
  full transcribe+merge on the existing real `/tmp/meetrec_real` tracks.
- **Phase 2:** `--diarize-remote` with the §3.6 fallback + duration-capped diarize chunks
  + Spanish warning.
- **Phase 3 (deferred):** `known_speaker_references` cross-chunk identity; sub-100 ms sync;
  gpt-4o fixed-window accuracy mode; speaker name map; bleed cross-correlation.

## 6. Cut from v1 (anti-gold-plating): overlap `[overlap]` tags, `--speakers` map,
configurable coalesce threshold (hardcode 1.5 s), fixed-window gpt-4o mode, precise sync
calibration beyond the READY gate.
