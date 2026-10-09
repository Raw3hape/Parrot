"""Bounded A/B using only the three synthetic fixtures in fixtures.json.

The test bundle has the production executable with outbound/inbound network
entitlements set to false. It must successfully load its existing local cache.
"""
import json, pathlib, re, statistics, subprocess, sys, time, unicodedata

root = pathlib.Path(__file__).resolve().parents[2]
evidence = pathlib.Path(__file__).resolve().parent / 'evidence'
target = sys.argv[1]
work = root / '.tmp/parakeet-ultra-resume'
ssh = ['ssh', '-B', 'en5', '-b', '169.254.214.129', '-o', 'BatchMode=yes',
       '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlias=100.121.242.34',
       '-o', 'ConnectTimeout=5', 'nikita@169.254.212.174']
binary = (str(work / 'Parrot-offline-test.app/Contents/MacOS/Parrot') if target == 'primary'
          else '/Users/nikita/Library/Caches/Parrot-ultra-resume-20261006/Parrot-offline-test.app/Contents/MacOS/Parrot')
fixtures = json.loads((evidence.parent / 'fixtures.json').read_text())

def words(text):
    return re.findall(r'\w+', unicodedata.normalize('NFKC', text).lower())

def distance(left, right):
    row = list(range(len(right)+1))
    for i, a in enumerate(left, 1):
        previous, row = row, [i]
        for j, b in enumerate(right, 1):
            row.append(min(row[-1]+1, previous[j]+1, previous[j-1]+(a != b)))
    return row[-1]

results = []
for repeat in range(2):
    for fixture in fixtures:
        for model in ['v3', 'ultra']:
            name = f'{target}-{model}-{fixture["language"]}-{repeat+1}'
            command = [binary, '--parakeet-test', '/Users/nikita/Library/Containers/com.uygar.parrot/Data/tmp/ParrotUltraFixtures-20261006/'+fixture['file'], '--print-fixture-transcript']
            if model == 'v3': command.append('--legacy-v3')
            if target != 'primary': command = ssh + command
            started = time.monotonic()
            with (evidence / (name+'.log')).open('wb') as log:
                proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                ledger = {'name': name, 'pid': proc.pid, 'cwd': str(root), 'stop_condition': 'completion or 240 seconds', 'finished': False}
                ledger_file = work / f'{target}-benchmark-resource.json'
                ledger_file.write_text(json.dumps(ledger, indent=2))
                try: code = proc.wait(timeout=240)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    try: proc.wait(timeout=10)
                    except subprocess.TimeoutExpired: proc.kill(); proc.wait()
                    code = 124
                ledger.update(finished=True, exit_code=code)
                ledger_file.write_text(json.dumps(ledger, indent=2))
            output = (evidence / (name+'.log')).read_text(errors='replace')
            fields = dict(re.findall(r'^([a-z_]+): (.*)$', output, re.MULTILINE))
            transcript = fields.get('fixture_transcript', '')
            reference = words(fixture['reference_text'])
            entry = {'target': target, 'model': model, 'language': fixture['language'], 'repeat': repeat+1,
                     'exit_code': code, 'wall_seconds': round(time.monotonic()-started,3), 'transcript': transcript,
                     'word_errors': distance(reference,words(transcript)), 'reference_words': len(reference),
                     'network_entitlements': False, 'log': name+'.log'}
            for key in ['load_seconds', 'decode_seconds', 'real_time_factor', 'audio_seconds', 'preparation_launches']:
                if key in fields: entry[key] = float(fields[key])
            results.append(entry)
            (evidence / f'{target}-ab.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
            print(json.dumps({k:v for k,v in entry.items() if k not in ['transcript','log']},ensure_ascii=False), flush=True)
            if code != 0 or not transcript: raise SystemExit(f'Failed {name}; inspect its log')
summary = {}
for model in ['v3','ultra']:
    rows = [r for r in results if r['model']==model]
    summary[model] = {'median_decode_seconds':statistics.median(r['decode_seconds'] for r in rows),
                      'word_errors':sum(r['word_errors'] for r in rows), 'reference_words':sum(r['reference_words'] for r in rows)}
(evidence / f'{target}-ab-summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps({'target':target,'summary':summary}),flush=True)
