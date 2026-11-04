#!/usr/bin/env python3
"""Validate the pilot matrix before aggregating it; --partial permits missing rows."""
import argparse
import json
import os
from pathlib import Path
import re
import sys

p = argparse.ArgumentParser()
p.add_argument('--partial', action='store_true')
args = p.parse_args()
root = Path('bench/pilot/results')
expected = {}
for cond in (1, 2, 3, 6):
    for upgrade in ('payouts', 'settlements'):
        for repeat in range(1, 6):
            expected[f'condition-{cond}-{upgrade}-r{repeat}.json'] = (cond, upgrade, None)
for upgrade, behaviours in (('payouts', ('B1','B2','B4')), ('settlements', ('B1','B2','B3'))):
    for behaviour in behaviours:
        for repeat in range(1, 6):
            expected[f'behaviour-{upgrade}-{behaviour}-r{repeat}.json'] = (3, upgrade, behaviour)
errors = []
files = {p.name:p for p in root.glob('*.json')}
for name in sorted(set(files) - set(expected)): errors.append(f'unexpected result {name}')
if not args.partial:
    for name in sorted(set(expected) - set(files)): errors.append(f'missing result {name}')
key = os.environ.get('VULTR_INFERENCE_API_KEY', '')
owned_guests = set()
for name, path in sorted(files.items()):
    if name not in expected: continue
    try:
        text = path.read_text()
        if re.search(r'\b(?:\d{1,3}\.){3}\d{1,3}\b',text): raise ValueError('contains address')
        if key and key in text: raise ValueError('contains inference key')
        row = json.loads(text)
        cond, upgrade, behaviour = expected[name]
        if (row.get('condition'), row.get('upgrade'), row.get('behaviour')) != (cond, upgrade, behaviour): raise ValueError('wrong row identity')
        if behaviour and row.get('sandbox_setup') != 'isolated pilot adapter; restricted tool surface and network': raise ValueError('missing isolated provenance')
        if behaviour and row.get('repeat') != int(re.search(r'-r([1-5])\.json$',name).group(1)): raise ValueError('wrong repeat metadata')
        if behaviour and row.get('setup') != 'OpenCode 2.2.5 with isolated pilot MCP adapter, no Kalari tools': raise ValueError('incorrect setup provenance')
        if row.get('arm') != 'reference' or '2.2.5' not in row.get('opencode_version',''): raise ValueError('wrong arm or OpenCode version')
        if behaviour and (row.get('prompt') != 'upgrade.txt' or row.get('session_continued') or row.get('notes_attached')): raise ValueError('variant is not a fresh condition 3 session')
        if behaviour and (row.get('live_port'), row.get('grading_port')) != (19121, 19122): raise ValueError('wrong variant endpoints')
        m = row['measures']
        for field in ('verdict','right_first_time','sandbox_runs','wall_time_s','time_stuck_s','tokens_input','tokens_output','records_lost','records_duplicated'):
            if field not in m: raise ValueError(f'missing measure {field}')
        if m['verdict'] not in ('PASS','FAIL') or type(m['right_first_time']) is not bool: raise ValueError('invalid verdict')
        if row['grade']['verdict'] != m['verdict']: raise ValueError('grade/verdict disagree')
        if (m['records_lost'], m['records_duplicated']) != (row['grade'].get('missing'), row['grade'].get('duplicates')): raise ValueError('grade counts disagree')
        for field in ('sandbox_runs','wall_time_s','time_stuck_s','tokens_input','tokens_output'):
            if not isinstance(m[field], (int,float)) or isinstance(m[field], bool) or m[field] < 0: raise ValueError(f'invalid {field}')
        for field in ('records_lost','records_duplicated'):
            if m[field] is not None and (type(m[field]) is not int or m[field] < 0): raise ValueError(f'invalid {field}')
        if not isinstance(row['cost_usd'],(int,float)) or row['cost_usd'] < 0: raise ValueError('invalid cost')
        if behaviour:
            tokens = row['opencode_tokens']
            if (m['tokens_input'], m['tokens_output']) != (tokens['input'] + tokens['cache_read'], tokens['output'] + tokens['reasoning']): raise ValueError('usage delta disagrees with OpenCode token totals')
        calculated = round(m['tokens_input'] * 0.15 / 1_000_000 + m['tokens_output'] * 0.60 / 1_000_000, 6)
        if abs(row['cost_usd'] - calculated) > 0.000001: raise ValueError('cost and token counts disagree')
        clean = row['cleanup']
        if clean['sandboxes_left'] or clean['processes_left']: raise ValueError('cleanup incomplete')
        if behaviour:
            repeat = int(re.search(r'-r([1-5])\.json$', name).group(1))
            older = upgrade == 'payouts' and (behaviour == 'B1' or (behaviour == 'B2' and repeat <= 4))
            if clean.get('scope_verified') is not (not older): raise ValueError('incorrect process cleanup provenance')
            guests = [n for n in clean.get('owned_names',[]) if re.fullmatch(r'kalari-pilot-[a-f0-9]{12}', n)]
            if len(guests) != 1 or guests[0] in owned_guests: raise ValueError('missing or repeated guest identity')
            owned_guests.add(guests[0])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as e:
        errors.append(f'{name}: {e}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'validated {len(files)} of {len(expected)} expected pilot rows')
