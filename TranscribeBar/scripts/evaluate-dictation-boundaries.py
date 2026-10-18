#!/usr/bin/env python3
"""Run the signed, isolated benchmark and score a public synthetic manifest."""
import collections
import json
import pathlib
import re
import subprocess
import sys
import unicodedata

manifest_path, executable, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
root.mkdir(parents=True, exist_ok=True, mode=0o700)
manifest = json.loads(manifest_path.read_text())


def tokens(text):
    text = unicodedata.normalize('NFC', text).lower()
    # Explicit equivalents in these fixtures only; do not conceal lexical changes.
    for phrase, value in [('seventeen', '17'), ('diecisiete', '17'), ('seventy', '70'), ('setenta', '70')]:
        text = re.sub(r'\b'+phrase+r'\b', value, text)
    return re.findall(r"[\w]+(?:['’][\w]+)*", text, re.UNICODE)


def distance(a, b):
    row = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        nxt = [i]
        for j, y in enumerate(b, 1):
            nxt.append(min(nxt[-1]+1, row[j]+1, row[j-1]+(x != y)))
        row = nxt
    return row[-1]


rows = []
modes = sys.argv[4:] or ['standard', 'legacy', 'committed', 'live']
assert all(x in ['standard', 'legacy', 'committed', 'live'] for x in modes)
for case in manifest:
    for mode in modes:
        directory = root/case['name']/mode
        report_path = directory/'report.json'
        if not report_path.exists():
            process = subprocess.run([str(executable), case['audio'], str(directory), mode], check=False)
            if process.returncode:
                rows.append(dict(case=case['name'], mode=mode, failed=True))
                continue
        report = json.loads(report_path.read_text())
        reference, hypothesis = tokens(case['reference']), tokens(report['formattedTranscript'] if mode == 'committed' else report['rawTranscript'])
        protected = [phrase for phrase in case['protected']
                     if ' '.join(tokens(phrase)) not in ' '.join(hypothesis)]
        quantities_ok = collections.Counter(x for x in reference if x in ('17', '70')) == collections.Counter(x for x in hypothesis if x in ('17', '70'))
        row = dict(case=case['name'], mode=mode, errors=distance(reference, hypothesis), words=len(reference),
                   wer=distance(reference, hypothesis)/len(reference), protectedMissing=protected,
                   quantitiesCorrect=quantities_ok, ready=report['stopToReady'],
                   boundarySeconds=report.get('boundarySeconds', 0),
                   checkedJoins=report.get('boundaryCheckedJoins', 0), recheckedGroups=report.get('boundaryRecheckedGroups', 0),
                   audioSeconds=report['audioSeconds'], usedRecovery=report['usedRecovery'],
                   replayWall=report.get('replayWallSeconds'),
                   replayRatio=report.get('replayWallSeconds', 0)/report['audioSeconds'] if mode != 'standard' and 'replayWallSeconds' in report else None,
                   forcedCuts=[round(t['end'], 3) for t in report.get('turns', []) if t.get('endReason') == 'forced'])
        rows.append(row)
        print(case['name'], mode, 'WER %.1f%%' % (100*row['wer']), 'ready %.2fs' % row['ready'],
              'missing protected', len(protected), 'quantities', quantities_ok, 'cuts', row['forcedCuts'], flush=True)
        (root/'scores.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2)+'\n')
(root/'scores.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2)+'\n')
