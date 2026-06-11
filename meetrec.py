#!/usr/bin/env python3
"""
meetrec — a lightweight, headless meeting recorder + transcriber for macOS 13+.

What it does, in one command:
  1. Records SYSTEM audio (the other participants) via the bundled Swift
     ScreenCaptureKit binary  — no BlackHole, no virtual device.
  2. Records your MIC in parallel via ffmpeg's avfoundation input.
  3. On stop (press Enter), transcribes the two tracks SEPARATELY (mic = "You",
     system = "Them"), merges them on a shared timeline, and writes one
     chronological, speaker-labelled transcript (+ optional summary). `--mix`
     restores the older single mixed-track behaviour.

Output lands in ./recordings/<timestamp>/transcript.md

Prereqs:  macOS 13+, ffmpeg (`brew install ffmpeg`), `pip install -r requirements.txt`,
          a built SystemAudioRecorder binary, and OPENAI_API_KEY in your env
          (or in a local `.env` file next to this script — see load_env_file).

NOTE ON CONSENT / PRIVACY: this records other people, and uploads audio (in
separate-track mode, BOTH the mic and the system streams) to OpenAI for
transcription. Tell participants and get agreement, the same way the commercial
tools show a "this call is being recorded" banner. Consent rules vary by
jurisdiction. For a fully local alternative, see --backend local / the README.
"""

import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SWIFT_BIN = HERE / "SystemAudioRecorder" / ".build" / "release" / "SystemAudioRecorder"

# OpenAI's transcription endpoint accepts files up to 25 MB. We segment by time to
# stay well under that; 20 min of mono AAC @ 64 kbps is ~9-10 MB.
CHUNK_SECONDS = 20 * 60

# A finalized .m4a with a moov atom is at least a few hundred bytes even for a
# fraction of a second of audio; anything smaller than this is effectively empty.
MIN_CHUNK_BYTES = 1024
# A WAV with only a header (~44 bytes) and no/near-no samples is "silent/empty".
MIN_TRACK_BYTES = 1024

# ffmpeg's avfoundation input takes a small, roughly-constant time to open the device
# after launch. We gate the mic start on the system tap going live (the Swift binary's
# READY line), so the residual inter-track offset is just this open lag.
FFMPEG_OPEN_LAG = 0.15
# Same-speaker segments closer than this (seconds) are coalesced into one block.
COALESCE_GAP = 1.5
# The only OpenAI model that returns per-segment timestamps (needed to interleave).
TIMESTAMP_MODEL = "whisper-1"
DIARIZE_MODEL = "gpt-4o-transcribe-diarize"


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def load_env_file():
    """If OPENAI_API_KEY isn't already in the environment, load it from a local
    `.env` (next to this script) or ~/.config/meetrec/env. Lines look like
    `OPENAI_API_KEY=sk-...` (an optional leading `export ` is tolerated). This is
    the recommended place to keep the key out of your shell history."""
    if os.environ.get("OPENAI_API_KEY"):
        return
    for candidate in (HERE / ".env", Path.home() / ".config" / "meetrec" / "env"):
        if not candidate.exists():
            continue
        for line in candidate.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if key.startswith("export "):
                key = key[len("export "):].strip()
            val = val.strip().strip('"').strip("'")
            os.environ.setdefault(key, val)
        break


def ensure_swift_binary():
    if SWIFT_BIN.exists():
        return
    print("Building the system-audio recorder (one-time)…", file=sys.stderr)
    run(["swift", "build", "-c", "release"], cwd=SWIFT_BIN.parents[2])
    if not SWIFT_BIN.exists():
        sys.exit("Build did not produce the expected binary. Build it manually with:\n"
                 f"  cd {SWIFT_BIN.parents[2]} && swift build -c release")


# ---------------------------------------------------------------------------
# Microphone discovery
# ---------------------------------------------------------------------------

def _query_avfoundation_stderr():
    # avfoundation prints its device list to stderr (and exits non-zero with the
    # empty input "", which is expected — we don't use check=True here).
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation",
         "-list_devices", "true", "-i", ""],
        capture_output=True, text=True)
    return p.stderr


def parse_audio_devices(stderr_text):
    """Return [(index, name), ...] for AVFoundation *audio* devices only.
    The device list is printed in two independently-numbered sections (video
    then audio); --mic refers to the audio numbering, so we ignore video."""
    devices, in_audio = [], False
    for line in stderr_text.splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
            continue
        if "AVFoundation video devices" in line:
            in_audio = False
            continue
        if in_audio:
            m = re.search(r"\[(\d+)\]\s+(.+?)\s*$", line)
            if m:
                devices.append((int(m.group(1)), m.group(2)))
    return devices


def list_mics():
    raw = _query_avfoundation_stderr()
    devices = parse_audio_devices(raw)
    if not devices:
        sys.stderr.write(raw)
        print("\nCould not parse the audio device list; raw ffmpeg output is above.")
        return
    print("Audio input devices (pass the index — or a name substring — to --mic):\n")
    for idx, name in devices:
        print(f"  [{idx}] {name}")
    print('\nExample:  python3 meetrec.py --mic 0        '
          '# or  python3 meetrec.py --mic "MacBook"')


def resolve_mic(arg):
    """Map a --mic argument (an index OR a case-insensitive name substring) to a
    concrete avfoundation audio index. Robust to the index not being 0."""
    devices = parse_audio_devices(_query_avfoundation_stderr())
    if arg.isdigit():
        idx = int(arg)
        known = [d[0] for d in devices]
        if devices and idx not in known:
            print(f"WARNING: no audio device with index {idx} (have: {known}). "
                  f"Run `python3 meetrec.py --list-mics`.", file=sys.stderr)
        return str(idx)
    matches = [d for d in devices if arg.lower() in d[1].lower()]
    if not matches:
        names = ", ".join(f"[{i}] {n}" for i, n in devices) or "(none found)"
        sys.exit(f"No audio input device matching '{arg}'. Available: {names}\n"
                 f"Run `python3 meetrec.py --list-mics`.")
    if len(matches) > 1:
        print(f"Multiple mics match '{arg}'; using the first.", file=sys.stderr)
    idx, name = matches[0]
    print(f"Using mic [{idx}] {name}", file=sys.stderr)
    return str(idx)


def default_output_looks_like_speakers():
    """Best-effort: is the default OUTPUT device built-in speakers? On a headset
    there's no acoustic bleed between tracks; on speakers the mic also captures the
    remote audio (duplicated in both tracks). Name-based heuristic — reliable for the
    common 'MacBook Pro Speakers' case; a USB device literally named '…Speakers' will
    also (correctly) warn, since it bleeds too."""
    try:
        raw = subprocess.run(["system_profiler", "SPAudioDataType", "-json"],
                             capture_output=True, text=True, timeout=10).stdout
        data = json.loads(raw)
        for item in data.get("SPAudioDataType", []):
            for dev in item.get("_items", []):
                if dev.get("coreaudio_default_audio_output_device") == "spaudio_yes":
                    return "speaker" in (dev.get("_name") or "").lower()
    except Exception:
        pass
    return False


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

def record(session: Path, mic_index: str):
    """Record system + mic simultaneously. Returns (system_wav, mic_wav, mic_offset),
    where mic_offset is how many seconds the mic track started AFTER the system track
    (used to align the two on one timeline). We start the mic only once the system tap
    is live (the Swift binary prints READY on stdout), so the offset is small."""
    system_wav = session / "system.wav"
    mic_wav = session / "mic.wav"

    # stdout is the READY handshake; stderr (diagnostics) still flows to the terminal.
    sys_proc = subprocess.Popen([str(SWIFT_BIN), str(system_wav)],
                                stdout=subprocess.PIPE, text=True)

    t_ready = None
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        line = sys_proc.stdout.readline()
        if line == "":            # EOF — binary exited early (e.g. permission failure)
            break
        if line.strip() == "READY":
            t_ready = time.monotonic()
            break
    if t_ready is None:
        print("WARNING: system recorder never signalled READY — inter-track timing may be "
              "off (and system audio may be empty; check permissions).", file=sys.stderr)

    mic_proc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "avfoundation", "-i", f":{mic_index}",
         "-ac", "1", "-ar", "48000", str(mic_wav)],
        stdin=subprocess.PIPE)
    mic_offset = (time.monotonic() - t_ready) + FFMPEG_OPEN_LAG if t_ready else 0.0

    print("\n● Recording. Press Enter to stop.", flush=True)
    try:
        input()
    except (KeyboardInterrupt, EOFError):
        pass

    # Stop the mic cleanly (ffmpeg finalizes on 'q'); stop system audio via SIGINT.
    try:
        mic_proc.communicate(input=b"q", timeout=5)
    except Exception:
        mic_proc.send_signal(signal.SIGINT)
    sys_proc.send_signal(signal.SIGINT)
    for p in (sys_proc, mic_proc):
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()

    return system_wav, mic_wav, mic_offset


# ---------------------------------------------------------------------------
# Segmenting (per-track and mixed)
# ---------------------------------------------------------------------------

def _track_ok(path: Path):
    try:
        return path.exists() and path.stat().st_size > MIN_TRACK_BYTES
    except OSError:
        return False


def _parse_segment_offsets(listfile: Path, chunks):
    """Map chunk filename -> exact start offset (s) from ffmpeg's segment list CSV
    (`filename,start,end`). Falls back to n*CHUNK_SECONDS if the list is missing."""
    starts = {}
    try:
        for line in listfile.read_text().splitlines():
            parts = line.split(",")
            if len(parts) >= 2:
                try:
                    starts[Path(parts[0].strip()).name] = float(parts[1])
                except ValueError:
                    pass
    except OSError:
        pass
    return [starts.get(c.name, i * CHUNK_SECONDS) for i, c in enumerate(chunks)]


def segment_track(src_wav: Path, session: Path, prefix: str):
    """Downmix one track to mono 16 kHz m4a and split into <=CHUNK_SECONDS chunks.
    Returns (chunk_paths, chunk_offsets_seconds)."""
    if not _track_ok(src_wav):
        return [], []
    pattern = str(session / f"{prefix}_chunk_%03d.m4a")
    listfile = session / f"{prefix}_segments.csv"
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src_wav), "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "64k",
        "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
        "-segment_list", str(listfile), "-segment_list_type", "csv",
        pattern,
    ])
    chunks = sorted(session.glob(f"{prefix}_chunk_*.m4a"))
    return chunks, _parse_segment_offsets(listfile, chunks)


def mix_and_segment(session: Path, system_wav: Path, mic_wav: Path):
    """(--mix path) Mix mic + system to mono 16 kHz AAC and split into chunks.
    Single-track fallback if only one side is usable."""
    chunk_pattern = str(session / "chunk_%03d.m4a")
    have_mic, have_sys = _track_ok(mic_wav), _track_ok(system_wav)
    if not have_mic and not have_sys:
        return []

    tail = ["-ac", "1", "-c:a", "aac", "-b:a", "64k",
            "-f", "segment", "-segment_time", str(CHUNK_SECONDS), chunk_pattern]

    if have_mic and have_sys:
        run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(mic_wav), "-i", str(system_wav),
            "-filter_complex",
            "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
            "alimiter=limit=0.95,aresample=16000",
            *tail,
        ])
    else:
        src = mic_wav if have_mic else system_wav
        which = "microphone" if have_mic else "system"
        print(f"Note: only the {which} track was usable — transcribing it alone.",
              file=sys.stderr)
        run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(src), "-af", "aresample=16000", *tail,
        ])
    return sorted(session.glob("chunk_*.m4a"))


# ---------------------------------------------------------------------------
# Transcription — separate-track (timestamped) + diarize, and the legacy mix path
# ---------------------------------------------------------------------------

def _usable_chunks(chunks):
    for i, chunk in enumerate(chunks):
        size = chunk.stat().st_size
        if size < MIN_CHUNK_BYTES:
            print(f"  skip {chunk.name} (empty: {size} bytes)", file=sys.stderr)
            continue
        yield i, chunk


def transcribe_track_whisper(chunks, offsets, base_offset, label, source, lang, client):
    """whisper-1 verbose_json → list of global-timed Segment dicts for one track."""
    segs = []
    for i, chunk in _usable_chunks(chunks):
        print(f"Transcribing {source} chunk {i + 1}/{len(chunks)}…", file=sys.stderr)
        try:
            with open(chunk, "rb") as f:
                kw = dict(model=TIMESTAMP_MODEL, file=f,
                          response_format="verbose_json",
                          timestamp_granularities=["segment"])
                if lang:
                    kw["language"] = lang
                resp = client.audio.transcriptions.create(**kw)
        except Exception as e:
            print(f"  {source} chunk {i + 1} failed: {e}", file=sys.stderr)
            continue
        off = base_offset + (offsets[i] if i < len(offsets) else i * CHUNK_SECONDS)
        for s in (getattr(resp, "segments", None) or []):
            txt = (getattr(s, "text", "") or "").strip()
            if not txt:
                continue
            # Drop whisper's classic silence-hallucinations.
            nsp = getattr(s, "no_speech_prob", 0.0) or 0.0
            alp = getattr(s, "avg_logprob", 0.0) or 0.0
            if nsp > 0.6 and alp < -1.0:
                continue
            st = float(getattr(s, "start", 0.0)) + off
            en = float(getattr(s, "end", st)) + off
            segs.append({"start": st, "end": max(en, st),
                         "label": label, "text": txt, "source": source})
    return segs


def _diarize_looks_sane(dsegs, duration, lang=None):
    """Concrete degradation signals (diarize hallucinated/translated/over-segmented in
    testing). Returns False → caller falls back to plain whisper for the remote track.
    `diarized_json` has no language field, so the translation check is heuristic."""
    if not dsegs:
        return False
    durs = [max(0.0, float(getattr(s, "end", 0)) - float(getattr(s, "start", 0))) for s in dsegs]
    n = len(dsegs)
    tiny = sum(1 for d in durs if d < 0.3)
    median = sorted(durs)[n // 2]
    if n >= 5 and (tiny / n > 0.30 or median < 0.5):
        print("  diarize output is micro-fragmented — falling back to whisper.", file=sys.stderr)
        return False
    speakers = {getattr(s, "speaker", None) for s in dsegs}
    span = max((float(getattr(s, "end", 0)) for s in dsegs), default=0.0)
    audio_len = duration or span
    if audio_len and len(speakers) > max(2, audio_len / 5.0):
        print(f"  diarize found {len(speakers)} speakers in ~{audio_len:.0f}s — implausible; "
              f"falling back to whisper.", file=sys.stderr)
        return False
    # Diarize has been observed translating Spanish → English. If a Spanish hint was given
    # but the text carries almost no Spanish markers, assume it translated and fall back.
    if lang and lang.lower().startswith("es"):
        text = " ".join((getattr(s, "text", "") or "") for s in dsegs).lower()
        words = len(text.split())
        markers = (len(re.findall(r"[áéíóúñ¿¡]", text))
                   + len(re.findall(r"\b(que|de|la|el|los|las|en|por|con|una?|para|se|su)\b", text)))
        if words > 20 and markers / words < 0.05:
            print("  diarize output doesn't look like Spanish (likely translated) — "
                  "falling back to whisper.", file=sys.stderr)
            return False
    return True


def transcribe_system_diarized(chunks, offsets, them_label, lang, client):
    """gpt-4o-transcribe-diarize → (segments, ok). ok=False on degradation → fall back."""
    segs = []
    for i, chunk in _usable_chunks(chunks):
        print(f"Diarizing system chunk {i + 1}/{len(chunks)}…", file=sys.stderr)
        try:
            with open(chunk, "rb") as f:
                kw = dict(model=DIARIZE_MODEL, file=f,
                          response_format="diarized_json", chunking_strategy="auto")
                if lang:
                    kw["language"] = lang
                resp = client.audio.transcriptions.create(**kw)
        except Exception as e:
            print(f"  diarize chunk {i + 1} failed: {e}", file=sys.stderr)
            return [], False
        dsegs = getattr(resp, "segments", None) or []
        if not _diarize_looks_sane(dsegs, getattr(resp, "duration", None), lang):
            return [], False
        off = offsets[i] if i < len(offsets) else i * CHUNK_SECONDS
        for s in dsegs:
            txt = (getattr(s, "text", "") or "").strip()
            if not txt:
                continue
            spk = getattr(s, "speaker", None) or "?"
            st = float(getattr(s, "start", 0.0)) + off
            en = float(getattr(s, "end", st)) + off
            segs.append({"start": st, "end": max(en, st),
                         "label": f"{them_label} — Speaker {spk}",
                         "text": txt, "source": "system"})
    return segs, True


def merge_segments(segments, coalesce_gap=COALESCE_GAP):
    """Pure: sort all segments on the global clock, then coalesce SORTED-ADJACENT
    same-label segments (an interposed other-speaker segment breaks the run, so
    chronology is preserved). Returns ordered blocks."""
    segs = [dict(s) for s in segments if s["text"].strip()]
    for s in segs:
        if s["end"] < s["start"]:
            s["end"] = s["start"]
    segs.sort(key=lambda s: (s["start"], s["source"], s["end"]))
    blocks = []
    for s in segs:
        last = blocks[-1] if blocks else None
        if last and last["label"] == s["label"] and (s["start"] - last["end"]) <= coalesce_gap:
            last["end"] = max(last["end"], s["end"])
            last["text"] = (last["text"] + " " + s["text"]).strip()
        else:
            blocks.append(dict(s))
    return blocks


def _mmss(t):
    t = max(0, int(round(t)))
    return f"{t // 60:02d}:{t % 60:02d}"


def render_conversation(blocks, timestamps=True):
    out = []
    for b in blocks:
        prefix = f"[{_mmss(b['start'])}] " if timestamps else ""
        out.append(f"{prefix}**{b['label']}:** {b['text']}")
    return "\n\n".join(out)


def render_appendix(track_segments):
    """Verbatim per-track text (ground truth, independent of the merge)."""
    out = []
    for heading, segs in track_segments:
        body = " ".join(s["text"] for s in segs).strip() or "_(no speech detected)_"
        out.append(f"### {heading}\n\n{body}")
    return "\n\n".join(out)


def render_diarized(resp):
    """(legacy --mix diarize path) speaker-labelled markdown from a diarized_json
    response, merging consecutive same-speaker segments."""
    segments = getattr(resp, "segments", None) or []
    if not segments:
        return (getattr(resp, "text", "") or "").strip()
    lines, cur_spk, cur_text = [], None, []

    def flush():
        if cur_spk is not None and cur_text:
            label = cur_spk if str(cur_spk).lower().startswith("speaker") else f"Speaker {cur_spk}"
            lines.append(f"**{label}:** {' '.join(cur_text)}")

    for seg in segments:
        spk = getattr(seg, "speaker", None) or "?"
        txt = (getattr(seg, "text", "") or "").strip()
        if not txt:
            continue
        if spk != cur_spk:
            flush()
            cur_spk, cur_text = spk, [txt]
        else:
            cur_text.append(txt)
    flush()
    return "\n\n".join(lines)


def transcribe_openai(chunks, model: str):
    """(--mix path) one mixed track → plain text (or diarized markdown)."""
    from openai import OpenAI
    client = OpenAI()
    is_diarize = "diarize" in model
    parts = []
    for i, chunk in _usable_chunks(chunks):
        print(f"Transcribing chunk {i + 1}/{len(chunks)}…", file=sys.stderr)
        try:
            with open(chunk, "rb") as f:
                if is_diarize:
                    resp = client.audio.transcriptions.create(
                        model=model, file=f, response_format="diarized_json",
                        chunking_strategy="auto")
                    parts.append(render_diarized(resp))
                else:
                    resp = client.audio.transcriptions.create(
                        model=model, file=f, response_format="text")
                    parts.append(str(resp).strip())
        except Exception as e:
            print(f"  chunk {i + 1} failed: {e}", file=sys.stderr)
            parts.append(f"_(chunk {i + 1} failed: {e})_")
    return "\n\n".join(p for p in parts if p)


def transcribe_local(chunks, model: str):
    """Fully-local backend seam (privacy). Not implemented here: fill this in with a
    whisper.cpp / faster-whisper call returning text. The capture/segmenting are
    identical; only this function changes. (Local has no timestamps, so it runs via
    the --mix path.) See README."""
    raise SystemExit(
        "The local transcription backend (--backend local) is a documented seam but "
        "is not implemented in this build.\n"
        "Fill in transcribe_local() with a whisper.cpp / faster-whisper call — the "
        "capture and segmenting stay identical; only this function changes.")


def transcribe(chunks, model: str, backend: str):
    if backend == "local":
        return transcribe_local(chunks, model)
    return transcribe_openai(chunks, model)


def summarize(transcript: str, model: str):
    from openai import OpenAI
    client = OpenAI()
    prompt = (
        "Summarize this meeting transcript. Return: a 3-5 sentence overview, "
        "then a bulleted list of decisions, then a bulleted list of action items "
        "with an owner if one is mentioned.\n\n" + transcript
    )
    resp = client.chat.completions.create(
        model=model, messages=[{"role": "user", "content": prompt}])
    return (resp.choices[0].message.content or "").strip()


# ---------------------------------------------------------------------------
# Pipelines
# ---------------------------------------------------------------------------

def run_separate(session, system_wav, mic_wav, mic_offset, args):
    """Transcribe each track separately and merge. Returns
    (conversation_md, appendix_md, summary_input, chunks_to_clean)."""
    from openai import OpenAI
    client = OpenAI()

    mic_chunks, mic_off = segment_track(mic_wav, session, "mic")
    sys_chunks, sys_off = segment_track(system_wav, session, "sys")

    mic_segs = (transcribe_track_whisper(mic_chunks, mic_off, mic_offset,
                                         args.me, "mic", args.lang, client)
                if mic_chunks else [])

    sys_segs = []
    if sys_chunks:
        if args.diarize_remote:
            if not args.lang or args.lang.lower().startswith("es"):
                print("WARNING: --diarize-remote has shown hallucination/translation issues on "
                      "Spanish audio in testing — verify the speaker labels.", file=sys.stderr)
            sys_segs, ok = transcribe_system_diarized(sys_chunks, sys_off, args.them,
                                                      args.lang, client)
            if not ok:
                print("Diarization degraded — using plain whisper for the remote track.",
                      file=sys.stderr)
                sys_segs = transcribe_track_whisper(sys_chunks, sys_off, 0.0,
                                                    args.them, "system", args.lang, client)
        else:
            sys_segs = transcribe_track_whisper(sys_chunks, sys_off, 0.0,
                                                args.them, "system", args.lang, client)

    blocks = merge_segments(mic_segs + sys_segs)
    conversation = render_conversation(blocks, timestamps=args.timestamps)

    appendix_tracks = []
    if mic_segs:
        appendix_tracks.append((f"{args.me} (mic)", mic_segs))
    if sys_segs:
        appendix_tracks.append((f"{args.them} (system)", sys_segs))
    appendix = render_appendix(appendix_tracks) if len(appendix_tracks) > 1 else ""

    # Summary reads the labelled conversation (without timestamp clutter), not the appendix.
    summary_input = render_conversation(blocks, timestamps=False)
    return conversation, appendix, summary_input, list(mic_chunks) + list(sys_chunks)


def run_mix(session, system_wav, mic_wav, args):
    """Legacy single mixed-track path. Returns (transcript, summary_input, chunks)."""
    chunks = mix_and_segment(session, system_wav, mic_wav)
    if not chunks:
        sys.exit("No audio chunks were produced — both tracks were empty/unusable.")
    model = args.model or "gpt-4o-transcribe"
    transcript = transcribe(chunks, model, args.backend)
    return transcript, transcript, chunks


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Headless meeting recorder + transcriber (macOS 13+).")
    ap.add_argument("--mic", default="0",
                    help="avfoundation audio device index OR a name substring (see --list-mics)")
    ap.add_argument("--list-mics", action="store_true", help="list audio input devices and exit")
    ap.add_argument("--mix", action="store_true",
                    help="legacy: transcribe ONE mixed track instead of separate You/Them tracks")
    ap.add_argument("--diarize-remote", action="store_true",
                    help="split the remote (system) track into Speaker A/B/C; system-only, opt-in")
    ap.add_argument("--me", default="You", help="label for your mic track")
    ap.add_argument("--them", default="Them", help="label for the remote/system track")
    ap.add_argument("--lang", default=None, help="language hint, e.g. es (improves accuracy)")
    ap.add_argument("--no-timestamps", dest="timestamps", action="store_false",
                    help="omit [mm:ss] prefixes in the conversation")
    ap.add_argument("--model", default=None,
                    help="transcription model for --mix/local (separate-track mode always uses "
                         "whisper-1, the only model with timestamps)")
    ap.add_argument("--backend", default="openai", choices=["openai", "local"],
                    help="transcription backend; 'local' is a stub (privacy) and implies --mix")
    ap.add_argument("--summary-model", default="gpt-4o", help="model used for the summary")
    ap.add_argument("--no-summary", action="store_true", help="skip the summary step")
    ap.add_argument("--keep-audio", action="store_true", help="keep intermediate audio files")
    ap.set_defaults(timestamps=True)
    args = ap.parse_args()

    if args.list_mics:
        list_mics()
        return

    # Local backend can't produce timestamps/diarization → it runs the mixed path.
    if args.backend == "local":
        args.no_summary = True
        if not args.mix:
            print("Note: --backend local has no timestamps; using mixed-track mode.", file=sys.stderr)
            args.mix = True
    if args.diarize_remote and args.mix:
        sys.exit("--diarize-remote applies to separate-track mode; it can't be combined with "
                 "--mix / --backend local.")
    if not args.mix and args.model is not None and args.model != TIMESTAMP_MODEL:
        sys.exit(f"Separate-track mode needs per-segment timestamps, which only {TIMESTAMP_MODEL} "
                 f"provides — '{args.model}' can't interleave. Use --mix to transcribe with "
                 f"'{args.model}', or omit --model.")

    load_env_file()
    if args.backend == "openai" and not os.environ.get("OPENAI_API_KEY"):
        sys.exit("Set OPENAI_API_KEY in your environment (or a local .env file) first.")

    ensure_swift_binary()
    mic_index = resolve_mic(args.mic)

    if not args.mix and default_output_looks_like_speakers():
        print("WARNING: your default output looks like built-in speakers — in separate-track "
              "mode the mic also captures the remote audio (duplicated in both tracks). Use a "
              "headset, or pass --mix.", file=sys.stderr)

    stamp = dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session = HERE / "recordings" / stamp
    session.mkdir(parents=True, exist_ok=True)

    system_wav, mic_wav, mic_offset = record(session, mic_index)

    for label, p in (("system", system_wav), ("mic", mic_wav)):
        if p.exists() and p.stat().st_size <= MIN_TRACK_BYTES:
            print(f"WARNING: the {label} track looks empty ({p.stat().st_size} bytes) — "
                  f"this is almost always a missing permission (see README §3).", file=sys.stderr)
    if not _track_ok(system_wav) and not _track_ok(mic_wav):
        sys.exit("No audio was captured — check the permission notes in the README (§3).")

    print("Transcribing…", file=sys.stderr)
    if args.mix:
        conversation, summary_input, chunks = run_mix(session, system_wav, mic_wav, args)
        appendix = ""
    else:
        conversation, appendix, summary_input, chunks = run_separate(
            session, system_wav, mic_wav, mic_offset, args)

    out = session / "transcript.md"
    with open(out, "w", encoding="utf-8") as f:
        f.write(f"# Meeting transcript — {stamp}\n\n")
        if not args.mix:
            f.write("_Ordering is turn-level; within ~1 s, exchanges may be approximate — "
                    "see the appendix for the verbatim per-track text._\n\n")
        if not args.no_summary:
            print("Summarizing…", file=sys.stderr)
            try:
                f.write("## Summary\n\n" + summarize(summary_input, args.summary_model) + "\n\n")
            except Exception as e:
                f.write(f"_(summary failed: {e})_\n\n")
        heading = "Full transcript" if args.mix else "Conversation"
        f.write(f"## {heading}\n\n" + conversation + "\n")
        if appendix:
            f.write("\n## Appendix — raw per-track transcripts\n\n" + appendix + "\n")

    if not args.keep_audio:
        for p in [system_wav, mic_wav, *chunks,
                  session / "mic_segments.csv", session / "sys_segments.csv"]:
            try:
                p.unlink()
            except FileNotFoundError:
                pass

    print(f"\n✓ Done → {out}")


if __name__ == "__main__":
    main()
