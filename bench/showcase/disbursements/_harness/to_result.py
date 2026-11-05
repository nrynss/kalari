#!/usr/bin/env python3
"""Build one bench-style Kalari result file from a finished session directory.

Inputs (all on the VM, inside one run directory):
  measures.json, transcript.jsonl, evidence.jsonl, grader-output.jsonl,
  usage-before.json, retry-agent.json, retry-grading.json
Plus --meta JSON: condition, upgrade, repeat, run_id, opencode_version,
live_port, grade_port, prompt, repo_scope, session_cap_s.

Output: result JSON on stdout. Never prints the key or the public address;
both arrive redacted or replaced by the caller.
"""
import argparse
import json
import sys
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--run-dir', type=Path, required=True)
p.add_argument('--meta', type=Path, required=True)
a = p.parse_args()

run = a.run_dir
meta = json.loads(a.meta.read_text())
measures = json.loads((run / 'measures.json').read_text())
evidence = []
ev = run / 'evidence.jsonl'
if ev.exists():
    for line in ev.read_text(errors='replace').splitlines():
        if line.strip():
            try:
                evidence.append(json.loads(line))
            except ValueError:
                pass

run_records = [r for r in evidence if r.get('kind') == 'run']
lesson_records = [r for r in evidence if r.get('kind') == 'lesson']
page_records = [r for r in evidence if r.get('kind') == 'page-observation']

# Transcript: first run_in_sandbox outcome, recall outcomes, tool counts.
first_run_passed, first_run_id, n_runs_completed = None, None, 0
recall_required, recall_advice = [], []
tool_events = 0
tr = run / 'transcript.jsonl'
if tr.exists():
    for line in tr.read_text(errors='replace').splitlines():
        if not line.strip():
            continue
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        part = doc.get('part') or {}
        name = part.get('tool')
        state = part.get('state') or {}
        if not isinstance(name, str) or not name.startswith('kalari_'):
            continue
        if state.get('status') != 'completed':
            continue
        tool_events += 1
        try:
            payload = json.loads((state.get('output') or '') if isinstance(state.get('output'), str) else 'null')
        except ValueError:
            payload = None
        if name == 'kalari_run_in_sandbox' and isinstance(payload, dict):
            n_runs_completed += 1
            if first_run_passed is None:
                first_run_passed = bool(payload.get('passed'))
                first_run_id = payload.get('run_id')
        if name == 'kalari_recall_lessons' and isinstance(payload, list):
            for entry in payload:
                if not isinstance(entry, dict):
                    continue
                check = ((entry.get('lesson') or {}).get('check') or {}).get('id')
                if entry.get('status') == 'required':
                    recall_required.append(check)
                else:
                    recall_advice.append(check)

if first_run_passed is None:
    if run_records:
        first = run_records[0].get('payload') or {}
        first_run_passed = bool(first.get('passed'))
        first_run_id = first.get('run_id')
    else:
        first_run_passed = False
        first_run_id = None

def run_passed(payload):
    if not isinstance(payload, dict):
        return False
    verdict = payload.get('verdict') or {}
    if verdict.get('verdict') != 'exited' or verdict.get('exit_code') != 0:
        return False
    checks = payload.get('check_results') or []
    return bool(checks) and all(c.get('passed') for c in checks if isinstance(c, dict))

run_payloads = [r.get('payload') or {} for r in run_records]
run_pass_list = [run_passed(p) for p in run_payloads]
if first_run_passed is None:
    if run_records:
        first_run_passed = run_pass_list[0]
        first_run_id = run_records[0].get('run_id')
    else:
        first_run_passed = False
        first_run_id = None

def verdict_name(payload):
    return ((payload or {}).get('verdict') or {}).get('verdict')

killed = sum(1 for p in run_payloads if verdict_name(p) == 'killed_timeout')
stuck_ms = sum(int((p.get('timings') or {}).get('wall_ms') or 0) for p in run_payloads
               if verdict_name(p) == 'killed_timeout')
n_evidence_runs = len(run_records)
sandbox_runs = 2 * n_evidence_runs
time_stuck_s = round(stuck_ms / 1000.0, 3)
first_request = (run_payloads[0].get('request') or {}) if run_payloads else {}
first_allowlist = (first_request.get('allowlist') or [])
first_caps = (first_request.get('caps') or {})

grade = measures.get('grade') or {'verdict': 'NOT_RUN'}
verdict = grade.get('verdict')
lost = grade.get('missing')
duplicated = grade.get('duplicates')

# List prices per million tokens (cached input counted as input, no cache discount).
PRICES = {'mimo-v2.6-flash': (0.10, 0.25), 'qwen3.8-27b': (0.15, 1.00), 'glm-5.3-flash': (0.10, 0.35),
          'muse-glimmer-30b': (0.25, 1.00), 'qwen3.8-flash-next': (0.10, 0.20), 'deepseek-v4.1-flash-1017': (0.15, 0.60)}

usage_path = run / 'usage-after.json'
usage_delta = None
cost = None
if usage_path.exists():
    try:
        after = json.loads(usage_path.read_text())
        before = json.loads((run / 'usage-before.json').read_text())
        # before/after hold {model: {input_tokens, output_tokens}}
        deltas = {}
        for model in sorted(set(before) | set(after)):
            bi = int((before.get(model) or {}).get('input_tokens') or 0)
            bo = int((before.get(model) or {}).get('output_tokens') or 0)
            ai = int((after.get(model) or {}).get('input_tokens') or 0)
            ao = int((after.get(model) or {}).get('output_tokens') or 0)
            deltas[model] = {'input': ai - bi, 'output': ao - bo}
        usage_delta = deltas
        model = meta.get('model')
        rates = PRICES.get(model)
        deep = deltas.get(model, {'input': 0, 'output': 0})
        if rates:
            cost = round(deep['input'] * rates[0] / 1_000_000 + deep['output'] * rates[1] / 1_000_000, 6)
    except (ValueError, KeyError, TypeError):
        pass

def retry_summary(name):
    path = run / f'retry-{name}.json'
    if not path.exists():
        return {'phase': name, 'status': 'unknown', 'reason': 'no retry summary',
                'b5_429_responses': None, 'matching_retry_attempts': None,
                'successful_matching_retries': None}
    try:
        return json.loads(path.read_text())
    except ValueError:
        return {'phase': name, 'status': 'unknown', 'reason': 'unreadable retry summary',
                'b5_429_responses': None, 'matching_retry_attempts': None,
                'successful_matching_retries': None}

retry_agent = retry_summary('agent')
retry_grading = retry_summary('grading')

if verdict == 'PASS' and first_run_passed:
    right, basis = True, 'first trusted run passed (candidate-truth and differential checks)'
elif n_evidence_runs == 0:
    right, basis = False, 'no consumer run against v2'
elif verdict == 'PASS':
    right, basis = False, 'first trusted run did not pass'
else:
    right, basis = False, 'final grade did not pass'

tokens = (measures.get('tokens') or {})
cleanup_doc = None
cleanup_path = run / 'cleanup.json'
if cleanup_path.exists():
    try:
        cleanup_doc = json.loads(cleanup_path.read_text())
    except ValueError:
        cleanup_doc = {'error': 'unreadable cleanup.json'}
result = {
    'condition': meta['condition'],
    'upgrade': meta['upgrade'],
    'repeat': meta['repeat'],
    'arm': 'kalari',
    'setup': 'OpenCode 2.2.5 with kalari serve MCP (5 tools), no shell, no microsandbox-mcp',
    'api_base': 'the VM\'s public address',
    'live_port': meta['live_port'],
    'grading_port': meta['grading_port'],
    'prompt': meta['prompt'],
    'opencode_version': meta.get('opencode_version'),
    'run_id': meta['run_id'],
    'repo_scope': meta.get('repo_scope'),
    'session_cap_s': meta.get('session_cap_s', 600),
    'session_capped': measures.get('cutoff_reason') == 'watchdog',
    'cutoff_reason': measures.get('cutoff_reason'),
    'consumer_exit': grade.get('consumer_exit') if isinstance(grade, dict) else None,
    'output_present': grade.get('output_present') if isinstance(grade, dict) else None,
    'measures': {
        'verdict': verdict,
        'right_first_time': right,
        'sandbox_runs': sandbox_runs,
        'wall_time_s': measures.get('elapsed_seconds'),
        'time_stuck_s': time_stuck_s,
        'tokens_input': tokens.get('input'),
        'tokens_output': tokens.get('output'),
        'containment': 'kalari-aashaan microsandbox guests, --no-net with allow rules for the live API only during the agent phase and the grading API only during grading; host shell and web access denied; the key never enters a guest',
    },
    'sandbox_runs_against_v2': None,
    'sandbox_runs_detail': 'two consumer runs per trusted run record (candidate against v2 plus baseline against v1); trusted check and grading guests excluded',
    'evidence_runs': n_evidence_runs,
    'evidence_first_run_id': first_run_id,
    'evidence_run_verdicts': [verdict_name(p) for p in run_payloads],
    'evidence_run_passed': run_pass_list,
    'evidence_run_wall_ms': [((p.get('timings') or {}).get('wall_ms')) for p in run_payloads],
    'evidence_run_checks': [[(c.get('check_id'), c.get('passed')) for c in (p.get('check_results') or [])] for p in run_payloads],
    'evidence_request_allowlist': first_allowlist,
    'evidence_request_caps': first_caps,
    'killed_timeout_runs': killed,
    'http_retries': {'agent': retry_agent, 'grading': retry_grading},
    'retry_measure': {
        'source': 'API retry journals, truncated at each phase start and read at each phase end',
        'note': 'an HTTP retry inside one consumer process is not a sandbox run',
    },
    'records_lost': lost,
    'records_duplicated': duplicated,
    'records_extra': grade.get('extra') if isinstance(grade, dict) else None,
    'records_mismatched': grade.get('mismatched') if isinstance(grade, dict) else None,
    'grade': grade,
    'grader_status': measures.get('grader_status'),
    'right_first_time_basis': basis,
    'lessons_published': [ (r.get('payload') or {}).get('observation') for r in lesson_records ],
    'page_observations': [ (r.get('payload') or {}).get('behaviors') for r in page_records ],
    'recall_required_checks': sorted(set(c for c in recall_required if c)),
    'recall_advice_checks': sorted(set(c for c in recall_advice if c)),
    'cost_usd': cost,
    'cost_note': 'List price for the session model, cached input counted as input, no cache discount; null when no price is recorded',
    'usage_delta': usage_delta,
    'usage_error': measures.get('usage_error'),
    'opencode_tokens': measures.get('tokens'),
    'tool_calls': measures.get('tool_calls'),
    'completed_steps': measures.get('completed_steps'),
    'estimated_step_cost_usd': measures.get('estimated_step_cost_usd'),
    'exit_code': measures.get('exit_code'),
    'invalid_event_lines': measures.get('invalid_event_lines'),
    'interrupted_signal': measures.get('interrupted_signal'),
    'cleanup': cleanup_doc,
    'cleanup_error': measures.get('cleanup_error'),
    'process_elapsed_s': measures.get('elapsed_seconds'),
    'opencode_exit': measures.get('exit_code'),
}
print(json.dumps(result, indent=2))
