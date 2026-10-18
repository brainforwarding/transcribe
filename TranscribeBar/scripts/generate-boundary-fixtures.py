#!/usr/bin/env python3
"""Public synthetic boundary corpus. macOS say/afconvert; Python standard library only."""
import array
import json
import math
import pathlib
import subprocess
import sys
import wave

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True, mode=0o700)
rate = 16000


def speech(name, text, voice):
    aiff, wav = root / (name + '.aiff'), root / (name + '.source.wav')
    subprocess.run(['say', '-v', voice, '-r', '175', '-o', str(aiff), text], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
    with wave.open(str(wav)) as f:
        samples = array.array('h', f.readframes(f.getnframes()))
    # Limit synthetic pauses to 80 ms to exercise the forced-cut path, not just VAD.
    blocks = [samples[i:i+160] for i in range(0, len(samples), 160)]
    output, quiet = array.array('h'), 0
    for block in blocks:
        rms = math.sqrt(sum(x*x for x in block) / max(1, len(block)))
        quiet = quiet + 1 if rms < 50 else 0
        if quiet <= 8:
            output.extend(block)
    while len(output) > 160 and max(abs(x) for x in output[:160]) < 50:
        del output[:160]
    return output


def stretch(samples, count):
    step = (len(samples) - 1) / (count - 1)
    out = array.array('h')
    for i in range(count):
        pos = i * step
        lo = min(len(samples) - 2, int(pos))
        fraction = pos - lo
        out.append(round(samples[lo] * (1 - fraction) + samples[lo+1] * fraction))
    return out


def write(name, samples):
    path = root / (name + '.wav')
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate); f.writeframes(samples.tobytes())
    return str(path)


english = ('Please read this message carefully before making any changes to the account because '
           'I want to preserve the original instructions and all of the details that follow '
           'including the date the amount and the people involved in this request '
           'so listen to the complete sentence before deciding what to send and keep all the')
spanish = ('Por favor escucha este mensaje completo antes de modificar la cuenta porque quiero '
           'conservar todas las instrucciones originales y los detalles de esta solicitud '
           'incluyendo la fecha el monto y los nombres de las personas que participan '
           'y recuerda que primero debemos revisar el documento y confirmar los datos antes de enviar los')
cases = [
    ('english-midword', english, 'information',
     'to Claudia and Jorge but do not send the invitation yet. Keep seventeen teachers and seventy seats. This is very very important.',
     'Samantha', 'Samantha', 'Samantha', ['do not send', 'very very important']),
    ('spanish-midword', spanish, 'diecisiete',
     'profesores y setenta asientos. No envíes la invitación todavía. Mantén a Claudia y Jorge en la copia. Esto es muy muy importante.',
     'Paulina', 'Paulina', 'Paulina', ['no envíes', 'muy muy importante']),
    ('repetition-correction', english, 'seventeen',
     'no seventy seats. I said seventeen teachers and seventy seats. Do not remove anyone. No no keep both names. This is very very important.',
     'Samantha', 'Samantha', 'Samantha', ['no no', 'very very important', 'do not remove']),
    ('language-switch-negation', english, 'no',
     'envíes la invitación todavía. Son diecisiete profesores y setenta asientos. Mantén a Claudia y Jorge en la copia.',
     'Samantha', 'Paulina', 'Paulina', ['no envíes']),
]
manifest = []
for name, prefix, target, tail, pv, tv, sv, protected in cases:
    pre, word, post = speech(name+'-prefix', prefix, pv), speech(name+'-target', target, tv), speech(name+'-tail', tail, sv)
    target_start = 20 * rate - len(word) // 2
    adjusted = stretch(pre, target_start)
    samples = adjusted + word + post
    manifest.append(dict(name=name, audio=write(name, samples), reference=prefix+' '+target+' '+tail,
                         protected=protected, forcedBoundary=20,
                         target=target, targetStart=target_start/rate, targetEnd=(target_start+len(word))/rate,
                         prefixStretch=target_start/len(pre), duration=len(samples)/rate))
    print(name, '%.2fs' % (len(samples)/rate), '20s crosses', target, flush=True)
# Known-pause control: a pause at 10 s should avoid any forced-boundary upload.
prefix = 'Please keep all the original instructions and the names in this message while we review the document and confirm the details.'
tail = 'Do not send the invitation yet. There are seventeen teachers and seventy seats. This is very very important.'
pre = speech('pause-prefix', prefix, 'Samantha')
post = speech('pause-tail', tail, 'Samantha')
samples = stretch(pre, 10*rate) + array.array('h', [0])*(rate) + post
manifest.append(dict(name='pause-control', audio=write('pause-control', samples), reference=prefix+' '+tail,
                     protected=['do not send', 'very very important'], duration=len(samples)/rate))
(root/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
