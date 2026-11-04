#!/usr/bin/env python3
"""Summarize OpenCode JSON events without echoing tool content or secrets."""
import json
import sys
from collections import Counter

if len(sys.argv) != 2:
    raise SystemExit('usage: summarize.py EVENTS_JSONL')
names = Counter()
usage = Counter()
bad = 0
for line in open(sys.argv[1], encoding='utf-8'):
    try:
        event = json.loads(line)
    except ValueError:
        bad += 1
        continue
    if not isinstance(event, dict):
        bad += 1
        continue
    part = event.get('part') or {}
    if not isinstance(part, dict):
        continue
    name = part.get('tool') or part.get('name')
    if isinstance(name, str) and name.startswith('kalari_'):
        names[name] += 1
    tokens = part.get('tokens') or {}
    if isinstance(tokens, dict):
        for key in ('input', 'output', 'reasoning'):
            if isinstance(tokens.get(key), int) and tokens[key] >= 0:
                usage[key] += tokens[key]
print(json.dumps({'tool_calls': dict(names), 'tokens': dict(usage), 'invalid_lines': bad}, sort_keys=True))
