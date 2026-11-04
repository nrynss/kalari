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
rows += ['', end, '']
text = text.replace('## Condition 1', '\n'.join(rows) + '\n## Condition 1', 1)
p.write_text(text)
