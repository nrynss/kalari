#!/usr/bin/env python3
"""Insert count summaries for the completed single-behaviour matrix."""
import json
from pathlib import Path
import subprocess
import sys

subprocess.run([sys.executable, 'bench/pilot/validate.py'], check=True)
p = Path('bench/pilot/SUMMARY.md')
text = p.read_text()
stale = 'The 30 single-behaviour sessions were not run, because the harness has no server switch and a behaviour `--run` still exits 2. There is no behaviour column in this table.'
text = text.replace(stale, 'The 30 single-behaviour sessions use the isolated adapter described in [ISOLATED.md](ISOLATED.md); its narrower sandbox and network surface differs from the condition sessions.')
start = '<!-- behaviour-counts:start -->'
end = '<!-- behaviour-counts:end -->'
if start in text:
    a, rest = text.split(start, 1)
    _, b = rest.split(end, 1)
    text = a + b
rows = [start, '## Single-behaviour counts', '',
        '| Upgrade | Behaviour | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Cost (USD) | Results |',
        '|---|---|---:|---:|---:|---:|---:|---:|---:|---|']
for upgrade, behaviours in (('payouts',('B1','B2','B4')),('settlements',('B1','B2','B3'))):
    for behaviour in behaviours:
        paths = [Path(f'bench/pilot/results/behaviour-{upgrade}-{behaviour}-r{i}.json') for i in range(1,6)]
        docs = [json.loads(p.read_text()) for p in paths]
        ms = [d['measures'] for d in docs]
        def total(field):
            vals = [m[field] for m in ms]
            return 'unknown' if any(v is None for v in vals) else str(sum(vals))
        links = ', '.join(f'[{i}](results/{p.name})' for i,p in enumerate(paths,1))
        rows.append(f"| {upgrade} | {behaviour} | 5 | {sum(m['verdict']=='PASS' for m in ms)} | {sum(m['right_first_time'] for m in ms)} | {total('sandbox_runs')} | {total('records_lost')} | {total('records_duplicated')} | {sum(d['cost_usd'] for d in docs):.6f} | {links} |")
variant_cost = sum(json.loads(p.read_text())['cost_usd'] for p in Path('bench/pilot/results').glob('behaviour-*.json'))
total_cost = sum(json.loads(p.read_text())['cost_usd'] for p in Path('bench/pilot/results').glob('*.json'))
rows += ['', f'Single-behaviour list-price spend: ${variant_cost:.6f}; all 70 pilot rows: ${total_cost:.6f}.', '', '## Condition counts', '',
         '| Condition | Upgrade | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Results |',
         '|---:|---|---:|---:|---:|---:|---:|---:|---|']
for cond in (1,2,3,6):
    for upgrade in ('payouts','settlements'):
        paths = [Path(f'bench/pilot/results/condition-{cond}-{upgrade}-r{i}.json') for i in range(1,6)]
        docs = [json.loads(p.read_text()) for p in paths]
        ms = [d['measures'] for d in docs]
        def total(field):
            vals = [m[field] for m in ms]
            return 'unknown' if any(v is None for v in vals) else str(sum(vals))
        links = ', '.join(f'[{i}](results/{p.name})' for i,p in enumerate(paths,1))
        rows.append(f"| {cond} | {upgrade} | 5 | {sum(m['verdict']=='PASS' for m in ms)} | {sum(m['right_first_time'] for m in ms)} | {total('sandbox_runs')} | {total('records_lost')} | {total('records_duplicated')} | {links} |")
rows += ['', end, '']
text = text.replace('## Condition 1', '\n'.join(rows) + '\n## Condition 1', 1)
p.write_text(text)

# The runner's sanitized result summaries are the live-run transcript.
transcript = ['# Single-behaviour pilot transcript', '',
    'No-inference preflight: all six variants passed their characteristic consumer checks on both dedicated endpoints. The fixed guest reached its allowed endpoint, was denied a shared endpoint, and ran a copied workspace file. The adapter refused a foreign sandbox and restore request. A user-scope probe captured and stopped a detached descendant.', '',
    'Each line below records the sanitized summary fields emitted by the runner, plus cleanup scope provenance added for the first nine sessions, which used a process group; see [ISOLATED.md](ISOLATED.md).', '', '```jsonl']
for upgrade, behaviours in (('payouts',('B1','B2','B4')),('settlements',('B1','B2','B3'))):
    for behaviour in behaviours:
        for repeat in range(1,6):
            path=Path(f'bench/pilot/results/behaviour-{upgrade}-{behaviour}-r{repeat}.json')
            d=json.loads(path.read_text()); m=d['measures']
            transcript.append(json.dumps({'result':str(path), 'verdict':m['verdict'], 'right_first_time':m['right_first_time'], 'sandbox_runs':m['sandbox_runs'], 'wall_time_s':m['wall_time_s'], 'time_stuck_s':m['time_stuck_s'], 'tokens_input':m['tokens_input'], 'tokens_output':m['tokens_output'], 'cost_usd':d['cost_usd'], 'records_lost':m['records_lost'], 'records_duplicated':m['records_duplicated'], 'session_capped':d['session_capped'], 'cleanup':d['cleanup']}, separators=(',',':')))
transcript += ['```', '']
Path('bench/pilot/TRANSCRIPT.md').write_text('\n'.join(transcript))
